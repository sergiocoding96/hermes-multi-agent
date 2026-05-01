# MemOS v1 — Resilience Audit

**Date:** 2026-04-30
**Marker:** `V1-RES-1777576080`
**Harness:** isolated; second MemOS instance on `127.0.0.1:8002` reading throwaway `MEMOS_HOME=/tmp/memos-v1-audit-resilience-2cd34b01-…`, throwaway Qdrant container `qdrant-audit-res` on `127.0.0.1:16333`, throwaway Neo4j 5.26.6 container `neo4j-audit-res` on `127.0.0.1:17687`. Live `:8001` MemOS, live `qdrant`/`neo4j-docker` containers, and live `agents-auth.json` were never touched.
**Stance:** chaos monkey — break every dependency, observe server behaviour, score 1–10 by area, take MIN.

> **Bootstrap note (separate finding):** `deploy/scripts/setup-memos-agents.py` is archived (`*.archived`) in this checkout, so the audit prompt's bootstrap command fails. Provisioning had to be improvised by calling `UserManager.create_user` and `create_cube` directly against a throwaway SQLite, then minting an agent key with `bcrypt`. PR #15 supposedly un-archived this script; on the current `tests/v1.0-audit-reports-2026-04-30` tree it is still archived. **Provisioning workflow blocked.** Out of scope to fix inside a blind audit; flagged here so the v1 fix sprint can address.

---

## Recon summary

- Qdrant client (`src/memos/vec_dbs/qdrant.py`) has a real retry path: `MEMOS_QDRANT_TIMEOUT_S=5.0`, `MEMOS_QDRANT_RETRY_ATTEMPTS=3`, exponential backoff (0.25 → 2 s), classifies connection-class errors via a frozen exception name set, escalates to `QdrantUnavailable` after exhaustion. 4xx propagates as a programming error. Reasonable.
- Neo4j (community) driver (`src/memos/graph_dbs/neo4j.py`) has `MEMOS_NEO4J_CONNECTION_TIMEOUT_S=5.0` and `MEMOS_NEO4J_MAX_TX_RETRY_TIME_S=10.0`. Sessions wrapped per-query; no per-call retry layer above the driver.
- `server_api.py` registers a chain of FastAPI exception handlers: `RequestValidationError`, `ValueError`, `HTTPException`, `DependencyUnavailable → 503`, and a global `Exception → 500` fallback that **also tries to classify Neo4j connection errors → 503** via `_classify_dependency_error` (`src/memos/api/exceptions.py:34`).
- `/health/deps` exists, requires auth, returns `{ok, deps:{qdrant, neo4j}}` with per-dep latency and error string. Useful for triage. (Verified live during probes — accurate.)
- Several silent-except paths in `multi_mem_cube/single_cube.py` (lines 215, 493, 535, 584, 655, 760, 827) catch `Exception as e` after `DependencyUnavailable` is handled; these convert dep failures into log-only no-ops in the multi-cube layer. This is the proximate cause of finding [F-2].
- Auth registry (`src/memos/api/middleware/agent_auth.py:255`): `except Exception as e: logger.error("Failed to load config: ...")` — malformed JSON does NOT prevent startup, the registry just stays empty and every request 401s.
- File-permission check on `agents-auth.json`: **none.** No `stat.S_IROTH` warning anywhere in the auth middleware.

---

## Findings

### F-1 Neo4j outage during write returns HTTP 200 with split-brain state

**Class:** silent-failure / data-loss
**Severity:** **Critical**

`docker stop neo4j-audit-res`; submit a sync write while Neo4j is down:

```
HTTP=200 TIME=3.45s
{"code":200,"message":"Memory added successfully",
 "data":[{"memory":"…neo4j down…","memory_id":"1d21dd1d-…","cube_id":"V1-RES-…"},
         {"memory":"…ack…","memory_id":"253aa71a-…"}]}
```

But meanwhile `GET /health/deps` says:

```
"neo4j":{"ok":false,"error":"ServiceUnavailable: Couldn't connect to 127.0.0.1:17687
         (Connection refused)"}
```

Backend reconciliation after Neo4j restart:

| Backend | Count |
|---|---|
| Qdrant `neo4j_vec_db` | **6 points** |
| Neo4j `:Memory` nodes | **4 nodes** |

Two memories persisted in Qdrant + were ack'd to the caller as `memory_id`s, but never reached the graph layer. **No retry queue replays them on Neo4j reconnect** (verified by counting after restart — delta stays at 2). The caller has no signal to detect this; `/product/get_memory/{memory_id}` would later return whatever the read path stitches together — likely a degraded view missing graph relationships.

Reproducer:
```bash
docker stop neo4j-audit-res
curl -H "Authorization: Bearer $KEY" http://127.0.0.1:8002/product/add \
  -d '{"user_id":"…","mem_cube_id":"V1-RES-…","messages":[…],"async_mode":"sync"}'
# → HTTP 200, memory_id returned
docker start neo4j-audit-res
# wait, then count
curl http://127.0.0.1:16333/collections/neo4j_vec_db/points/count -X POST -d '{"exact":true}'
docker exec neo4j-audit-res cypher-shell -u neo4j -p $PW \
  "MATCH (n:Memory) RETURN count(n);"
```

**Remediation:** classify Neo4j `ServiceUnavailable` as `DependencyUnavailable` at the multi-cube write layer (mirror Qdrant's `_with_retry → QdrantUnavailable → 503` chain), or write the failed graph mutation to a durable retry queue and surface the partial-write state on `/health/deps`.

Evidence: `evidence/p02-neo4j-outage.txt`, `evidence/p02b-neo4j-counts.txt`, `evidence/p02c-qdrant-count.txt`.

---

### F-2 Search degrades silently to empty results when Qdrant or Neo4j is down

**Class:** silent-failure
**Severity:** **High**

With Qdrant down (`docker stop qdrant-audit-res`):

```
POST /product/search → HTTP 200 (0.82s)
data: {"text_mem":[],"act_mem":[],"para_mem":[],
       "pref_mem":[{"memories":[],"total_nodes":0}],
       "tool_mem":[…empty…],"skill_mem":[…empty…]}
```

Same response shape with Neo4j down. The search path catches the dep failure and returns an empty corpus instead of `503 dependency unavailable`. A caller doing "did this memory exist?" gets a *real* "no" instead of a *transient* "the store is down, retry".

Combined with finding F-1 this means a Neo4j blip during read+write can lose data AND mask the loss with an empty search result on the next query.

**Remediation:** propagate `DependencyUnavailable` from search-path try/excepts in `multi_mem_cube/single_cube.py` (lines 535, 584, 655, 760) instead of falling through to `except Exception` log-and-return-empty.

Evidence: `evidence/p01-qdrant-outage.txt` (search section), `evidence/p02-neo4j-outage.txt` (search section).

---

### F-3 Fine-mode write with broken LLM key returns HTTP 200 with `data:[]` (silent drop)

**Class:** silent-failure / data-loss
**Severity:** **Critical**

Set `MEMRADER_API_KEY=sk-garbage-broken-9999` in the loaded `audit.env` (avoiding our pre-export shell variable, which `load_dotenv(override=True)` clobbers — see also F-7). Restart, send a fine-mode sync write:

```
POST /product/add  mode=default async_mode=sync
→ HTTP 200 (0.92s)
{"code":200,"message":"Memory added successfully","data":[]}
```

`data: []` — empty memory list. No `memory_id`s. Nothing in Qdrant or Neo4j (verified: `qdrant=14, neo4j=12`, unchanged from before the bad-key write). The LLM-extraction step returned no parsed memories, the API treated empty extraction as a success, and the caller has no way to tell the write was dropped.

By contrast, sending the same write with `mode:"fast"` (raw text path, no LLM) succeeds normally and persists the message verbatim — so the fast-mode fallback is implemented but **not auto-engaged** when extraction yields nothing.

**Remediation:** when fine-mode extraction returns zero memories, either (a) auto-fall-back to fast mode and tag with `extraction_status="failed"`, or (b) return `502 LLM provider extraction failed` instead of `200 OK data:[]`. Either is fine; silent `200 + []` is not.

Evidence: `evidence/p11-llm-outage.txt`.

---

### F-4 Embedder cache unreadable → server fails to boot, no graceful fallback

**Class:** no-recovery / cascading-failure
**Severity:** **High**

`chmod 000` on the throwaway `sentence-transformers/` cache → server boot:

```
File "transformers/utils/hub.py", line 524, in cached_files
  raise OSError(...)
OSError: PermissionError at .../sentence-transformers/token when downloading
sentence-transformers/all-MiniLM-L6-v2. Check cache directory permissions.
```

The process exits and stays dead. There is no fallback to:
- A backup embedder
- Online HF download (transient)
- A "embedder-degraded, refuse writes but allow reads" mode

Effect: any disk corruption in the embedder cache (a single `.lock` file zero-byte, a permission flip after a `chown -R`, etc.) → full server outage with no auto-recovery.

**Remediation:** wrap `EmbedderFactory.from_config` boot path in a fallback try/except that either retries with a tmpfs cache, falls through to a stub embedder that returns `dependency_unavailable: embedder` on every write, or at minimum logs `FATAL: embedder unhealthy, refusing to start — operator action required`. Currently it logs a stack trace and exits.

Evidence: `evidence/p10-embedder.txt`.

---

### F-5 100 parallel writes: 49 % rejected with HTTP 429 at the rate-limit middleware

**Class:** backpressure (working as designed but the threshold is restrictive)
**Severity:** **Medium**

100 async-mode `/product/add` from a single client, single cube, `xargs -P50`:

| | Count |
|---|---|
| HTTP 200 | 51 |
| HTTP 429 | 49 |
| p50 latency | 1.73 s |
| p95 latency | 3.36 s |
| Total elapsed | 3.61 s |

No SQLITE_BUSY visible to caller, no silent drops — explicit 429 is surfaced and `data: null`. This is the rate-limit middleware doing its job (`src/memos/api/middleware/rate_limit.py` — runs in SQLite-fallback mode under `/var/tmp/memos-ratelimit.db` because `MEMOS_REDIS_URL` is unset).

**Remediation (operator):** set `MEMOS_REDIS_URL` for production multi-worker; tune the per-key limits if 50 RPS is too restrictive for the agents.

Evidence: `evidence/p04-100par-writes.txt`, `evidence/p04-raw.txt`, `evidence/p04-times.txt`.

---

### F-6 `agents-auth.json` mode 0644 starts silently, no warning

**Class:** silent-failure (security posture)
**Severity:** **Medium**

`chmod 644 agents-auth.json` (world-readable BCrypt hashes) → restart server → `READY after 2s`. No warning logged about insecure mode. There is no `stat.S_IROTH` check anywhere in `agent_auth.py`.

**Remediation:** at registry load, `os.stat(config_path).st_mode & 0o077` and warn (or refuse, behind a `MEMOS_REQUIRE_AUTH_FILE_PRIVATE_MODE=true` flag) when group/other have any bits. The audit prompt called this out as a probe explicitly because it reflects on perception of secret-handling discipline.

Evidence: `evidence/p07-auth-perms.txt`.

---

### F-7 `load_dotenv(override=True)` at import time silently clobbers process-env overrides

**Class:** silent-failure (operational footgun)
**Severity:** **Medium**

`memos/api/config.py:26` runs `load_dotenv(override=True)` unconditionally at module import, with `find_dotenv()` walking up from `__file__` until it finds `/home/openclaw/Coding/MemOS/.env`. **An operator who exports `QDRANT_HOST=…` or any of the other ~40 envs read by `api/config.py` and then runs `python -m memos.api.server_api` is silently overridden by the on-disk `.env`.** This makes "stand up an isolated MemOS pointing at different deps" require either patching the `.env` (unsafe — touches the live config the live server reads) or monkey-patching `dotenv.load_dotenv` (what this audit had to do — see `server-wrapper.py`).

This is also the reason Probe 11 v1 looked like it succeeded against a broken LLM key when in reality the in-shell `MEMRADER_API_KEY=garbage` had been clobbered by the on-disk value.

**Remediation:** change `load_dotenv(override=True)` to `load_dotenv(override=False)` (POSIX-standard "env wins"), or honour a `MEMOS_DOTENV_PATH` env var that points `find_dotenv` at a chosen file. This single change makes isolated harnesses possible without monkey-patching.

Evidence: `evidence/p11-llm-outage.txt` (probe v1 vs v3 contrast).

---

### F-8 Mid-write Qdrant `docker kill`: 5 concurrent writes → 5 × HTTP 503, no partial state

**Class:** (observation, no defect)
**Severity:** Info — **good behaviour**

Five sync writes fired in parallel, Qdrant `docker kill` 50 ms in. All five surfaced as HTTP 503 (`Qdrant unreachable during query_points after 3 attempts (caused by ResponseHandlingException)`) with the proper `dependency: "qdrant"` envelope. After Qdrant restart, `delta_qdrant=0, delta_neo4j=0`. **No torn writes; rejection is atomic at the dep-failure boundary.**

This is the qdrant retry contract from `vec_dbs/qdrant.py:127 _with_retry` working as designed. Evidence: `evidence/p03-qdrant-mid-write.txt`.

---

### F-9 Qdrant outage + reconnect: server reconnects automatically, no restart needed

**Class:** (observation, no defect)
**Severity:** Info — **good behaviour**

`docker stop qdrant-audit-res` → write returns 503 with named dep → `docker start` → next write returns 200, `/health/deps` says `qdrant.ok=true`. No server restart required. The `QdrantClient` lazy-reconnects on each `_with_retry` attempt. Same pattern with Neo4j (modulo F-1's silent-failure issue on writes). Evidence: `evidence/p01-qdrant-outage.txt`, `evidence/p02-neo4j-outage.txt`.

---

### F-10 Server's user-DB (`memos_users.db`) is not on the `/product/add` write path

**Class:** (observation; clarifies the prompt's "SQLite corruption" scenarios)
**Severity:** Info

The audit prompt assumes `~/.memos/data/memos.db` is hot-path SQLite. On the live system that file is 0 bytes (`ls -la /home/openclaw/.memos/data/memos.db` → 0). The actual SQLite file the server uses is `MEMOS_DIR/memos_users.db` (default `<MemOS-base>/.memos/memos_users.db`) and it only stores user/cube metadata. **Memory writes go straight to Qdrant + Neo4j, not SQLite.**

Probe 5 (held a 15 s `BEGIN IMMEDIATE` write lock on the audit `memos_users.db`) → `/product/add` succeeded in 3.77 s, fully unaffected. WAL-recovery and SQLITE_BUSY don't materially shape v1 resilience because the hot path doesn't use SQLite.

This means the prompt's "SQLite corruption" / "WAL recovery" scenarios are **mostly moot** for v1 — only operations that touch the user/cube registry (auth load, cube create) would be exposed. Sprint 2's v2 plugin path (per the migration doc not read here) may change this.

Evidence: `evidence/p05-sqlite-lock.txt`.

---

### F-11 Malformed `agents-auth.json` → server starts, every request 401, error logged

**Class:** soft-fail (acceptable, could be louder)
**Severity:** Low

Truncated invalid JSON (`{"version": 2, "agents": [`) → server boots, registry is empty, every `/product/*` request returns `401 {"detail":"Invalid or unknown agent key."}`. `agent_auth.py:255 except Exception as e: logger.error("[AgentAuth] Failed to load config: ...")` — error is logged but startup is not aborted. Acceptable degradation: live server keeps running for whatever pre-existing in-memory state is OK; new logins fail. Loud-but-not-fatal is defensible. Evidence: `evidence/p08-malformed-auth.txt`.

---

### F-12 FD exhaustion attempt: 500 idle sockets → server unbothered, FDs reclaimed cleanly

**Class:** (observation)
**Severity:** Info — **good behaviour**

Opened 500 raw TCP sockets to `:8002` without sending a request. `/health` under load: `HTTP=200`. After client closes: server FDs back to baseline 22 within 2 s. ulimit on the box is 1 048 576, so the audit prompt's 10 000-socket threshold would also pass; not exhaustively probed. Evidence: `evidence/p13-fd.txt`.

---

## Final summary table

| Area | Score 1-10 | Key findings |
|------|-----------|--------------|
| LLM (DeepSeek/MEMRADER) outage handling | **2** | F-3: silent data-drop on fine mode (`200 OK data:[]`). Fast-mode fallback exists but is not auto-engaged. |
| Embedder failure handling | **3** | F-4: cache permission failure → process exits. No fallback or degraded-mode start. |
| Qdrant outage + reconnect | **6** | F-9 reconnects cleanly, F-8 atomic mid-write rejection. But F-2: search returns empty silently instead of 503. |
| Neo4j outage + reconnect | **2** | F-1 critical: writes return 200 with split-brain (Qdrant ok, Neo4j missing). No retry queue, no reconciliation. |
| SQLite corruption detection | **N/A** (Info) | F-10: not a real area for v1 — `memos_users.db` is registry-only, not on hot path. |
| SQLite WAL recovery | **N/A** (Info) | Same as above. |
| Concurrent-write handling (SQLITE_BUSY) | **6** | F-5: 100-parallel → 49 % 429s, no silent drops. Threshold restrictive for production but explicit. |
| Config malformed / perms enforcement | **4** | F-6 644 perms accepted silently, F-7 `dotenv override=True` clobbers env, F-11 malformed auth boots silently. |
| Process crash + restart consistency | **6** | Server restarts clean; auto-restart by supervisor not configured (out of scope to set up). |
| Soft-delete teardown collisions | **N/A** | Not exercised — would require separate dedup probe; deferred. |
| Hub / cross-agent sync resilience | **N/A** | Not configured in this build (`hub-sync.py` not present). |
| Hermes plugin retry / queue | **5** | Server tolerates SIGSTOP-then-CONT recovery (Probe 9). Plugin-side retry behaviour not directly probed in this run; the underlying server-side 503 contract is correct, the plugin just needs to honour it. |
| Disk-full / FD-exhaustion behaviour | **7** | F-12 FD exhaustion handled. Disk-full not exercised (out of time-box; the throwaway harness on `/tmp` shares the host disk and that probe needed root-only `dd` of >GB to be meaningful — deferred). |

**Overall resilience score = MIN(scoring areas) = 2 / 10.**

The single dominant axis is the **silent-failure pair F-1 + F-3 + F-2**: a Neo4j blip OR a DeepSeek hiccup OR a Qdrant flap during read does not return an error to the caller. The system reports `200 OK` on writes that didn't happen and `200 OK data:[]` on searches that couldn't run. There is no client-visible signal that "the store is degraded, retry later" except `GET /health/deps` (which the plugin doesn't poll on the hot path).

## One-paragraph judgement

**Cannot survive a typical production day with one or two transient dep outages.** The Qdrant retry/503 contract is well-built and recovers cleanly, but Neo4j writes and LLM-fine-mode extractions both fail silently with HTTP 200 and either split-brain backend state (F-1) or empty `data:[]` (F-3). A 5-second DeepSeek hiccup during a fine-mode write loses the memory permanently with no caller signal. A 30-second Neo4j hiccup leaves Qdrant and Neo4j permanently desynchronised with no reconciliation path. Combined with `/product/search` returning empty arrays instead of 503 when a backend is down (F-2), the failure modes are invisible in normal use — the only triage signal is `GET /health/deps`, which the plugin does not poll. The fixes are small in scope (mirror the Qdrant `_with_retry → 503` pattern in the Neo4j and MemReader paths; auto-fall-back fine→fast on empty extraction; replace `200 data:[]` with `502`) but the current state would lose data on any non-trivial day.

---

## Out-of-scope but worth flagging (for the v1 fix sprint)

- F-7 (`load_dotenv override=True` clobbers env) makes building any isolated audit harness or staging instance painful. Cheap fix, big test-tooling unlock.
- The provisioning script `setup-memos-agents.py` is `*.archived` again on `tests/v1.0-audit-reports-2026-04-30`. PR #15 was supposed to un-archive it. Whatever subsequent v2 cleanup re-archived it should be reviewed; v1 audits need it un-archived, with `--output` and `--agents` argparse, exactly as the audit prompts assume.
- `/health/deps` is not aggregated into a single liveness/readiness endpoint that supervisors / load balancers can scrape. Wiring a `/readyz` that returns 503 if any required dep is red would let upstream callers shed load instead of receiving silent `200 data:[]`.
