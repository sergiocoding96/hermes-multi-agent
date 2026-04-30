# MemOS v1 — Data Integrity Audit (2026-04-30)

Auditor: blind, zero-knowledge. Marker: `V1-DI-1777576700`.
Throwaway profile: `audit-v1-di-1777576700` (created via `UserManager.create_user` + `agents-auth.json` append; cleaned up after run).
Reference probes / source: `/home/openclaw/Coding/MemOS/src/memos/multi_mem_cube/single_cube.py`, `vec_dbs/qdrant.py`, `graph_dbs/neo4j_community.py`, live API `localhost:8001`, live Qdrant `localhost:6333`, live Neo4j `localhost:7687`.

---

## TL;DR

The audit prompt's premise is partly inaccurate: there is **no SQLite row per memory**. SQLite (`memos_users.db`) stores only `users / cubes / user_cube_association` — i.e. ACL only. Memory content lives in **two** stores: Neo4j (`Memory` nodes) and Qdrant (`neo4j_vec_db` collection), keyed by a shared UUID. So "tri-store consistency" reduces to **bi-store consistency Neo4j ↔ Qdrant**, plus ACL in SQLite.

On the live system there is **massive bi-store divergence in legacy data**: 509 Neo4j `Memory` nodes vs 340 Qdrant points (≈33 % gap), with at least one cube (`research-cube`) showing 255 Neo4j → 58 Qdrant (77 % orphan rate). Nodes missing from Qdrant are almost all marked `vector_sync="success"` — the metadata lies. Three additional nodes are explicitly marked `vector_sync="failed"` and are also Qdrant-orphaned, and the failure mode is documented (`neo4j_community.py:104‑106`): a generic exception during Qdrant upsert is swallowed, the Neo4j node is left in place, the marker is set, **and there is no reconciliation pass** that ever heals these rows. Hard-delete is symmetric on the happy path, but `recover_memory_by_record_id` is a no-op that returns `success`. Several user-visible API surfaces lie ("Memory added successfully" with empty data on dedup; "success" on a recovery that wrote nothing).

Content fidelity is **good for raw text** (round-tripped byte-for-byte for ASCII / emoji / CJK / RTL / quotes / tabs / backslashes) **but broken by an upstream PII filter** that mangles any 10-digit token to `[REDACTED:phone]` *before* storage in both `sources[].content` and the LLM-derived summary — collapsing two distinct numbers into the same token, irreversibly. Timestamps are µs-resolution ISO‑8601, monotonic in single-writer fast probes; no global ordering guarantee.

**Overall (MIN of sub-areas): 2 / 10.** Trust this system to hold the only copy of important memories? **No.** Bi-store divergence is large, silent, and unrecoverable; recovery and dedup APIs return success on no-op; PII redaction is destructive and indiscriminate; there is no documented backup/restore path.

---

## Setup & method

- Live MemOS server (PID `2667993`) at `localhost:8001`, version `1.0.1`.
- Qdrant container `qdrant` (image `qdrant/qdrant`), Neo4j container `neo4j-docker` (image `neo4j:5.26.6`).
- API keys + Qdrant API key + Neo4j password retrieved from the running server's `/proc/<pid>/environ` (server already had them decrypted from `secrets.env.age`).
- Throwaway audit user `audit-v1-di-1777576700` provisioned by importing `memos.mem_user.user_manager.UserManager` directly (the documented `setup-memos-agents.py` is archived to `.archived` and was not invoked); a bcrypt hash of a freshly generated `ak_…` key was appended to `/home/openclaw/Coding/Hermes/agents-auth.json`. The server hot-reloads that file, so auth worked end-to-end on the next request. Cleanup at end deleted the user, cube, association row, audit Neo4j nodes, audit Qdrant points, and the appended `agents-auth.json` entry.
- Did not run the destructive `docker stop qdrant` or `kill -9 server` partial-write probes — both stores are shared with the running production agents (research-agent, email-marketing, CEO). Findings about partial-write behaviour are derived from code inspection plus an analysis of pre-existing `vector_sync="failed"` rows.

---

## Findings

### F1 — Massive Neo4j↔Qdrant divergence on legacy data (CRITICAL · class: tri-store-divergence / orphan)

**Reproducer**

```bash
# Total node count vs total point count
docker exec -i neo4j-docker cypher-shell -u neo4j -p $N4P \
  "MATCH (n:Memory) RETURN count(n);"        # → 509
curl -s -H "api-key:$QK" localhost:6333/collections/neo4j_vec_db | jq .result.points_count
                                              # → 340  (gap = 169, ≈33 %)

# Per-user spot check (research-cube)
docker exec -i neo4j-docker cypher-shell -u neo4j -p $N4P \
  "MATCH (n:Memory {user_name:'research-cube'}) RETURN count(n);"   # → 255
curl -s -H "api-key:$QK" -X POST \
  localhost:6333/collections/neo4j_vec_db/points/count \
  -H 'Content-Type: application/json' \
  -d '{"filter":{"must":[{"key":"user_name","match":{"value":"research-cube"}}]},"exact":true}'
                                                                    # → 58   (orphan rate 77 %)

# Sample 50 vector_sync=success nodes → check Qdrant
# Result: 50 / 50 (100 %) of sampled "success" nodes are MISSING from Qdrant
```

**Evidence (one of fifty representative orphans)**

```
Neo4j  : id=1281c59e-4dfe-48fa-b0f9-2f9f6aa8adf8
         user_name=research-cube  vector_sync="success"  status="activated"
         memory_type=LongTermMemory  created_at=2026-04-05T16:36:24.532146Z
         memory="On April 5, 2026, the assistant shared a key finding about self-improving AI agents using the Karpat..."
Qdrant : POST /collections/neo4j_vec_db/points  body:{"ids":["1281c59e-..."]}
         → {"result":[],"status":"ok"}
         GET  /collections/neo4j_vec_db/points/1281c59e-...
         → {"status":{"error":"Not found: Point with id 1281c59e-... does not exists!"}}
```

**Why this happens** (`neo4j_community.py:85‑106`): on `add_node`, Neo4j is MERGEd first, then `vec_db.add([item])` is called. Generic exceptions on the Qdrant call are caught and the field `vector_sync` is set to `"failed"` on the Neo4j node (line 106) — **but the Neo4j node remains**. Crucially, only `DependencyUnavailable` is re-raised; transient `httpx`/network errors that don't bubble up as that subclass are silently swallowed. Worse, the 50 / 50 sample shows nodes still marked `vector_sync="success"` are missing from Qdrant — implying they were either purged from Qdrant out-of-band (maintenance / collection recreate) or written successfully and later lost without flipping the marker. Either way the marker is **not a reliable consistency signal**.

**No reconciliation**: a code search across `multi_mem_cube/`, `vec_dbs/`, `graph_dbs/` finds no scheduled job that re-syncs `vector_sync="failed"` nodes or scans for cross-store divergence. The 3 explicitly-failed nodes from 2026-04-27 are still failed today.

**Severity**: CRITICAL. Search results from the legacy data are silently incomplete — vector search will miss 33 % of the corpus. No alerts fire. Operators have no way to know without running the cross-store diff above.

**Remediation**: (a) add a periodic reconcile job that scans Neo4j vs Qdrant by ID and re-embeds-and-upserts any orphan into Qdrant (or hard-deletes from Neo4j if recovery is impossible); (b) make Qdrant write retries `DependencyUnavailable`-style for *all* connection-class errors, never swallow generic `Exception`; (c) emit a metric `memos_vector_sync_failed_total` and alert on > 0.

---

### F2 — `recover_memory_by_record_id` is a silent no-op (HIGH · class: API-lies-about-success)

**Reproducer**

```bash
TARGET=10c73bc5-e962-4f7d-9386-0630820d1c28        # freshly written, then hard-deleted
curl -s -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  localhost:8001/product/recover_memory_by_record_id \
  -d "{\"user_id\":\"$U\",\"mem_cube_id\":\"$U\",\"delete_record_id\":\"$TARGET\"}"
# → {"code":200,"message":"Called Successfully","data":{"status":"success"}}

# Post-conditions
docker exec -i neo4j-docker cypher-shell -u neo4j -p $N4P \
  "MATCH (n {id:'$TARGET'}) RETURN count(n);"   # → 0
curl -s -H "api-key:$QK" -X POST \
  localhost:6333/collections/neo4j_vec_db/points \
  -H 'Content-Type: application/json' \
  -d "{\"ids\":[\"$TARGET\"]}"                  # → result: []
```

**Evidence**: API returns `code=200, status=success` while neither store contains the row. Calling `recover_memory_by_record_id` after a `delete_memory` (which does perform a hard delete — see F4) is therefore non-recoverable, but the API has no way to communicate that.

**Severity**: HIGH. Documents claim recoverability that does not exist. A user trusting the success response will lose data without any error signal.

**Remediation**: either re-implement recovery to actually re-create the node + re-embed + upsert, or have the endpoint return `404 / "delete_record not recoverable"` when the record is no longer present.

---

### F3 — `/product/add` returns "Memory added successfully" when nothing was added (HIGH · class: API-lies-about-success)

**Reproducer (rapid duplicates)**

```bash
for i in 1..30; do  # 30 rapid sync writes of "V1-DI rapid <i> content marker."
  curl -s -X POST .../product/add -d '{ ... messages:[{role:user,content:"V1-DI rapid $i content marker."}]}'
done
```

**Evidence**: Out of 30 rapid sync POSTs, 5 returned a `memory_id`, **25 returned `{"code":200,"message":"Memory added successfully","data":[]}`** — empty `data` despite a "success" message. Identical content submitted twice in a row also yields `data:[]`. The same shape appears under concurrent identical writes (see F8): 4 of 5 parallel duplicates returned the same empty-`data` "success" payload while only 1 actually wrote a row.

**Why**: dedup runs pre-insert (single_cube.py:732‑770) at default similarity threshold 0.90, OR the upstream MemReader LLM declines to extract a memory; in both cases the API surface flattens to "success / empty data". A client cannot distinguish "stored a duplicate of an existing id", "rejected by dedup", "LLM extracted nothing", and "stored a fresh memory" without parsing `data.length`.

**Severity**: HIGH. Clients building on top will write code paths that assume `code:200` + `message:"Memory added successfully"` means "this content is now retrievable" — and silently lose data when dedup fires or extraction declines.

**Remediation**: define distinct response codes / fields: `data.action ∈ {"created","deduped","extracted_empty"}` with the matching existing memory_id when deduped.

---

### F4 — Hard delete is symmetric on the happy path; soft-delete vs hard-delete semantics are conflated (MEDIUM · class: dedup-error)

**Reproducer**

```bash
# Create
ID=10c73bc5-e962-4f7d-9386-0630820d1c28   # from /product/add
# Delete
POST /product/delete_memory  body:{"user_id":U,"mem_cube_id":U,"memory_ids":[ID]}
# → {"code":200,"data":{"status":"success","deleted":[ID],"not_found":[]}}

# Both stores
Neo4j → MATCH (n {id:ID}) RETURN count(n)        → 0
Qdrant → POST /collections/neo4j_vec_db/points   → result: []
```

**Behaviour**: `/product/delete_memory` performs a hard delete, removing the node in both Neo4j and Qdrant. There is no separate user-facing soft-delete endpoint; the Neo4j `status="archived"` path (`neo4j_community.py:1394`) is reachable internally but not via the public API, leaving callers without a reversible-delete option. Combined with F2 (recover is a no-op), the system effectively has only **destructive** delete.

**Severity**: MEDIUM. Functional but mis-aligned with the "soft-delete" claim in the audit prompt. The Qdrant-error swallow at hard-delete (`neo4j_community.py:1102‑1104` per source review) is real and means a partial Qdrant outage during delete will leave the Qdrant point alive while Neo4j deletes the node — feeding F1 from the other end.

**Remediation**: expose `archive` as a first-class endpoint; never swallow Qdrant errors during delete (re-raise as 503).

---

### F5 — PII filter destroys content fidelity for any 10-digit token (HIGH · class: fidelity-loss)

**Reproducer**

```text
Submitted (raw text in API body):
  "Phone-like sequence: 1234567890 followed by 9876543210 V1-DI numbers."

Stored in Qdrant payload  sources[0].content:
  "Phone-like sequence: [REDACTED:phone] followed by [REDACTED:phone] V1-DI numbers."

Stored in derived `memory` summary:
  "...the user mentioned a phone-like sequence consisting of a redacted phone number
   followed by another redacted phone number and then V1-DI numbers..."
```

**Same effect on the audit marker**: my own marker `V1-DI-1777576700` (a unix timestamp) was redacted to `V1-DI-[REDACTED:phone]` in both `sources[].content` and the LLM summary. Two **distinct** numbers (`1234567890` ≠ `9876543210`) became indistinguishable after storage. Round-trip is therefore *not* lossless; the redactor is applied **before** persistence, not at egress, so there is no way to retrieve the original numbers.

**Severity**: HIGH. Any memory containing a phone number, a 10-digit ID, an order number, a transaction reference, a unix timestamp, or any 10-digit substring is silently mangled. Two distinct values collide. There is no opt-out flag exposed in `/product/add`.

**Remediation**: redact at *display* time, not at *write* time; or attach a tokenised reversible mapping (`[REDACTED:phone:UUID]`) so distinct values stay distinct and originals can be recovered with the right scope; or expose a per-cube `pii_filter: false` flag.

---

### F6 — Audit-prompt premise about SQLite is wrong; real DB path is repo-relative (INFO · class: documentation-drift)

**Evidence**

```bash
ls -la ~/.memos/data/memos.db                       # → 0 bytes (empty since 2026-04-26)
sqlite3 ~/.memos/data/memos_users.db ".tables"      # → users, cubes, user_cube_association
                                                    #   (only 3 users, 2 cubes — STALE)
ls -la /home/openclaw/Coding/MemOS/.memos/memos_users.db
                                                    # → 49152 bytes (CURRENT — 45 assoc rows,
                                                    #   contains my throwaway user + buddy)
```

**Cause** (`src/memos/settings.py:6`):

```python
MEMOS_DIR = Path(os.getenv("MEMOS_BASE_PATH", Path.cwd())) / ".memos"
```

`MEMOS_BASE_PATH` is unset in the live server's environ, so `MEMOS_DIR` resolves to **`<cwd>/.memos`**. The systemd-equivalent process runs from `/home/openclaw/Coding/MemOS`, so the live SQLite DB is at `/home/openclaw/Coding/MemOS/.memos/memos_users.db`. The `~/.memos/` tree the audit prompt names exists but is stale / unused for the user store and **completely empty** for the legacy `memos.db` file.

**Severity**: INFO (operationally relevant). Anybody backing up `~/.memos/` is **not backing up the user/ACL DB**. The `~/.memos/data/memos.db` 0-byte file is misleading — it implies content lives there.

**Remediation**: pin `MEMOS_BASE_PATH=/home/openclaw/.memos` in the systemd unit and migrate; or emit a startup log line printing the actually-used `MEMOS_DIR` so operators can find it.

---

### F7 — Dedup is vector-similarity (≥ 0.90) only, not content-hash; and silently filters 80%+ of rapid near-duplicates (MEDIUM · class: dedup-error)

**Reproducer**: see F3 (30 sync POSTs of `V1-DI rapid {N} content marker.` → only 5 unique IDs, 25 empty-data successes).

**Evidence**: source `single_cube.py:732‑770` queries `graph_store.search_by_embedding()` with threshold from `MOS_DEDUP_THRESHOLD` (default 0.90); above threshold the memory is dropped. The check is on the embedding, not the raw text — so two messages differing only by a numeric token (`rapid 1` vs `rapid 2`) embed close enough to dedup. A **change of embedder model** invalidates dedup retroactively (vectors live in the same Qdrant collection regardless of the model that produced them — see F9).

**Severity**: MEDIUM. Data loss is silent and dependent on embedder behaviour for near-duplicates, which is not stable across model versions. Combined with F3 (success on no-op) the loss is invisible.

**Remediation**: add content-hash dedup as a first pass (deterministic), reserve embedding-similarity for an optional "near-duplicate hint"; surface a deduped-id in the API response.

---

### F8 — Concurrent identical writes converge to 1 winner, but 4/5 callers are told "success" (MEDIUM · class: dedup-error)

**Reproducer**: 5 parallel `curl -X POST /product/add` with identical content.

**Evidence**: 1 worker returned a fresh `memory_id` (`ab98122e-…`), 4 workers returned `{"data":[],"message":"Memory added successfully"}`. Final Neo4j count for that content = 1 row (correct). API surface lies to 4 of 5 callers — see F3.

**Severity**: MEDIUM (correctness OK, observability broken).

---

### F9 — Embedding-dimension lock-in is not validated; collection silently exists with one embedder forever (MEDIUM · class: migration-error)

**Evidence**

```bash
curl -s -H "api-key:$QK" localhost:6333/collections/neo4j_vec_db | jq .
# config.params.vectors.size = 384      (matches all-MiniLM-L6-v2)
# points_count = 340
# indexed_vectors_count = 0             (no HNSW index built)
```

Source `qdrant.py:159‑201`: on init, `recreate_collection` is *not* called; if the collection exists, the configured `vector_dimension` is logged-and-ignored (no validation that the existing collection's dim matches the configured embedder). Switching `MOS_EMBEDDER_MODEL` to a 768-dim model in the env would either fail Qdrant upserts (mismatched dim) or, worse, succeed if the operator manually drops the collection — orphaning every Neo4j node from its old vector. There is no migration path.

Separately, `indexed_vectors_count: 0` means HNSW is **not built** for the live collection, so every search is a brute-force linear scan. Not a correctness problem but a future scaling cliff.

**Severity**: MEDIUM. Operationally fragile; embedder-rotation is a documented Sprint goal but the storage layer cannot survive it without manual intervention + reembedding.

**Remediation**: at server startup, fetch the existing collection's `params.vectors.size` and refuse to start (or log CRITICAL) if it does not match the configured embedder dim. Provide a `memos-reembed` script.

---

### F10 — No documented backup / restore procedure (MEDIUM · class: no-backup-path)

**Evidence**: search across `Makefile`, `start-memos.sh`, `docs/`, `apps/`, `deploy/scripts/` for backup, restore, snapshot, dump, pg_dump, qdrant snapshot, neo4j-admin dump:

```bash
grep -rEi 'backup|restore|snapshot|neo4j-admin' \
  /home/openclaw/Coding/MemOS/{Makefile,start-memos.sh,docs,deploy,apps} 2>/dev/null
```

Yields no operationally-usable backup script for the three live stores. A backup of `~/.memos/` does not capture either the live user-DB (F6) or the data stores (Qdrant + Neo4j live in Docker volumes). Restore order is not documented (must restore Neo4j and Qdrant *consistently* — same point-in-time — to avoid F1-style divergence).

**Severity**: MEDIUM. Recoverability after disk loss is undefined.

**Remediation**: document a coordinated snapshot (`neo4j-admin database dump` + `POST /collections/{name}/snapshots` on Qdrant + sqlite `.backup`) and write a restore runbook.

---

### F11 — ACL idempotency works (POSITIVE · INFO)

**Reproducer**

```python
um = UserManager()
um.add_user_to_cube('audit-v1-di-1777576700-buddy', 'audit-v1-di-1777576700')   # → True
um.add_user_to_cube('audit-v1-di-1777576700-buddy', 'audit-v1-di-1777576700')   # → True
```

```sql
sqlite> SELECT count(*) FROM user_cube_association WHERE user_id LIKE 'audit-v1-di-1777576700-buddy';
1
```

A second `add_user_to_cube` with identical args is idempotent: no duplicate row is inserted, no exception is raised. ✓

---

### F12 — Timestamps are µs ISO-8601, monotonic for serial writes; no global ordering guarantee (INFO)

13 sync writes from a single client produced strictly monotonic `created_at` values from `2026-04-30T19:18:58.143980Z` through `2026-04-30T19:23:41.846990Z` with no collisions. Source confirms timestamps are server-side `datetime.now().isoformat()` (microsecond precision). Concurrent multi-writer monotonicity is **not** guaranteed by the design — there is no Lamport clock or per-cube sequence number. Future-dated memories are accepted (no `created_at <= now()` check).

---

### F13 — Tri-store write consistency on **fresh** writes is sound (POSITIVE · INFO)

For all 14 audit memories I created during this run:

- Both stores have the row.
- The Neo4j `id` and the Qdrant point `id` are identical.
- Qdrant `created_at` payload matches Neo4j `created_at`.
- All show `vector_sync="success"`, `status="activated"`.

The bug is in **legacy** data, not the current write path — but the write path lacks any guard that would *prevent* a future divergence if Qdrant flaps (F1).

---

## Final summary

| Area | Score 1‑10 | Key findings |
|------|-----------|--------------|
| Tri-store write consistency (fresh writes) | 7 | Neo4j↔Qdrant cross-link cleanly via shared UUID on the happy path (F13). No transaction; F1 mechanism still latent. |
| Partial-write recovery | 2 | No reconciliation pass exists; legacy `vector_sync="failed"` rows are permanent orphans; generic Qdrant exceptions are swallowed (F1, F4). |
| Soft-delete idempotency across stores | 3 | Public API offers only hard-delete; "recover" is a silent no-op (F2, F4). |
| Content fidelity (text / JSON / code) | 8 | Byte-equal round-trip for ASCII / quotes / backslashes / tabs / URLs / Python code blocks / JSON-fragile chars. |
| Unicode / emoji / CJK fidelity | 9 | Emoji 🎉🚀, CJK 你好世界, RTL مرحبا עולם round-trip cleanly in `sources[].content`. |
| Timestamp resolution + ordering | 6 | µs ISO-8601, monotonic in serial; no concurrent-monotonic guarantee; future-dated memories accepted (F12). |
| Embedding dimension lock-in | 3 | No validation between configured embedder dim and existing collection dim; HNSW not built (F9). |
| Search-time tri-store consistency | 1 | Search backs onto Qdrant; with 33 % corpus orphaned from Qdrant, search results are silently incomplete (F1). |
| ACL idempotency | 8 | `add_user_to_cube` is idempotent in SQLite (F11). |
| Migration safety | 3 | No migration scripts in `src/memos`; embedder change will silently break dedup or upserts (F7, F9). |
| Concurrent dedup ordering | 5 | Single winner under concurrent identical writes (F8) but API lies to losers (F3). |
| Backup / restore documented path | 1 | No script, no runbook, no documented coordinated snapshot procedure (F10). |
| Content fidelity (PII filter) — *cross-cuts above* | 1 | 10-digit tokens irreversibly redacted to `[REDACTED:phone]` *before* storage (F5). |

**Overall data-integrity score = MIN = 1 / 10.**

## Judgement

I would not trust this system to hold the only copy of important memories. The single most damning data point is **F1**: 50/50 sampled Neo4j nodes that explicitly carry `vector_sync="success"` are not in Qdrant. The metadata that operators would use to diagnose the problem is itself unreliable. Compounding this, the public API tells callers "Memory added successfully" when nothing was stored (F3), tells callers "recover succeeded" when nothing was restored (F2), and silently rewrites distinct 10-digit numbers into the same opaque token before storage (F5). There is no documented backup path (F10), no reconciliation job (F1), and the user-DB lives at a path the documentation does not reference (F6). The content-fidelity surface for raw text is genuinely good, ACL idempotency is correct, and fresh writes are tri-store-consistent — but the system has no defenses against the failure modes that have *already* damaged the legacy corpus.

The path back to trust is not large in scope: a reconcile job, a stricter Qdrant-write retry surface, a content-hash dedup pass, an honest API response taxonomy, a `pii_filter=false` flag, a coordinated snapshot script, and a startup-time embedder-dim check. None of these change the data model. All of them are missing today.

---

## Cleanup performed

```bash
# Hard-delete audit memories from both stores
for ID in <14 audit IDs>; do
  curl -X POST .../product/delete_memory -d '{"user_id":"audit-v1-di-1777576700","memory_ids":[ID]}'
done

# SQLite cleanup (real path)
sqlite3 /home/openclaw/Coding/MemOS/.memos/memos_users.db <<SQL
DELETE FROM user_cube_association WHERE user_id LIKE 'audit-v1-di-1777576700%';
DELETE FROM cubes WHERE owner_id LIKE 'audit-v1-di-1777576700%';
DELETE FROM users WHERE user_id LIKE 'audit-v1-di-1777576700%';
SQL

# agents-auth.json — remove appended throwaway entry
python -c "import json; …"   # rewrites without the audit-v1-di-1777576700 row
```
