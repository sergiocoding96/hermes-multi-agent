# Hermes v2 Data Integrity Audit

Marker: `INTEG-AUDIT-1776791142`
Date: 2026-04-21
Plugin: `@memtensor/memos-local-hermes-plugin@1.0.3`
DB: `~/.hermes/memos-state-research-agent/memos-local/memos.db` (WAL, synchronous=FULL)
Hub: `http://localhost:18992` — **not running during audit** (stale `hub.pid` 1624019, no listener); hub HTTP round-trip therefore tested statically from source + schema rather than live.

All probes created their own rows tagged `owner='agent:integ-audit'` and were cleaned up after.

---

## Recon

### Schema (key tables)
- `chunks` (PK id TEXT, FK `task_id`→tasks, `content_hash`, `owner`, `dedup_status` ∈ {active, superseded}, `dedup_target`, `merge_history` JSON, `merge_count`, `last_hit_at`)
- `embeddings` (PK `chunk_id` → chunks ON DELETE CASCADE)
- `chunks_fts` (FTS5 tokenize=**trigram**, synced via AI/AU/AD triggers)
- `tasks`, `task_embeddings`, `tasks_fts`
- `skills`, `skill_versions` (FK → skills; no ON DELETE), `skill_embeddings` (CASCADE), `task_skills` (composite PK, no cascade), `skills_fts`
- No version/etag/revision column on any row → no optimistic concurrency control

### Write paths
- DB opens via `better-sqlite3` with `PRAGMA foreign_keys = ON` (sqlite.ts:15). A transient migration block temporarily sets it OFF then back ON (sqlite.ts:1506–1537) — OK if completes, dangerous if process dies mid-migration.
- **Hub ↔ local is NOT transactional.** Hub writes go over HTTP (`/api/v1/hub/memories/share`, `/publish`, `/unshare`). The client persists locally first, then optionally calls hub. No outbox / retry queue was found. If hub is down at share time → silent skip (the plugin's hub calls just throw; caller must catch).
- Skill file writes (`generator.ts:205,218,226,242,253`): plain `fs.writeFileSync(...)`. **No fsync, no tmp→rename atomic swap.** Crash mid-write leaves partial file. `installer.cleanSync()` does `rmSync(dstDir, {recursive})` **then** `mkdirSync` + `cpSync` — crash between rm and cp = installed skill totally erased from workspace with no rollback.
- Hub index is a separate set of tables (`hub_memories`, `hub_skills`, etc.) in the same memos.db, populated via HTTP handlers in `hub/server.ts`. `embedMemoryAsync` is fire-and-forget — if embedder fails, hub row exists without vector.

### Timestamp source
- `capture/index.ts:66,108` — **pure client `Date.now()`**. For user messages the code optionally uses `userSearchTime` (still client-derived), then monotonicity-coerces (`if (ts <= lastTimestamp) ts = lastTimestamp + 1`) — only within one batch, not across batches/clients.
- No NTP check, no hub-assigned timestamps, no skew detection.

---

## Probes and findings

### 1. Local DB ↔ hub consistency
| Facet | Finding |
|---|---|
| Share flow | Explicit push model (/share). Client-local capture is independent of hub state. |
| Transactionality | **None**. Local insert commits before hub HTTP call; hub call can fail independently. No outbox, no retry. 100 rapid writes with hub dead = 100 local rows, 0 hub rows, no reconciliation on revival. |
| Field mismatch | Hub `upsertHubMemory` copies `content/summary/role/kind` verbatim but discards local `content_hash`, `owner`, `dedup_status`, `merge_history`, `last_hit_at`, `task_id`, `turn_id`, `seq`. These are **local-only** and hub cannot reproduce them → search results from hub cannot participate in local dedup/task-lineage. |
| Embedding | Hub re-embeds via `embedMemoryAsync` (separate vector from local embedding). If embedder versions differ across clients, hub and local will return different neighborhoods. |
| Timestamps | Hub stamps its own `createdAt = Date.now()` on insert if no existing row (server.ts:668), then `updatedAt = now` on every re-share → hub's `createdAt` ≠ local chunk `created_at`. |

**Integrity class:** consistency + fidelity. **Score: 4/10** — no cross-layer transaction, silent field loss, independent embeddings, timestamp divergence.

### 2. Skill file ↔ index consistency
| Facet | Finding |
|---|---|
| Atomicity | `writeFileSync` w/o tmp-rename; `cleanSync` does `rm -rf` before `cp`. Power loss / SIGKILL mid-install can wipe an installed skill and partially write the replacement. |
| fsync | Never called. Data in pagecache may be lost on hard crash even if the syscall returned. |
| Drift detection | None. `installer.ts` never hashes on-disk `SKILL.md` and compares to `skill_versions.content`. Manual edits persist silently until next `syncIfInstalled()` blindly overwrites them. Edit is NOT detected and NOT re-embedded. |
| Deleted on-disk, row present | `install()` returns `{installed:false, message:"Skill directory not found"}` (installer.ts:116–118). The DB row remains; `skill_embeddings` remains; FTS on `skills` still matches. Search returns a hit whose content can no longer be sourced from disk. Dangling reference. |
| Hub vs file | `hub/skills/publish` stores bundle as JSON blob in `hub_skills.bundle` — independent of `skills.dir_path`. No drift check between hub bundle and on-disk files. |

**Integrity class:** durability + consistency. **Score: 3/10** — non-atomic filesystem ops, zero drift detection.

### 3. Task summary ↔ underlying chunks
| Facet | Finding |
|---|---|
| FK from chunk → task | Yes: `chunks.task_id REFERENCES tasks(id)` (no `ON DELETE`), so deleting a task without `task_id=NULL` update leaves **orphan chunks with dangling task_id** (FK ON would block the delete → so safe if FK on; but FK OFF window in migrations leaves loophole). |
| Summary fidelity | LLM-generated via `Summarizer.summarizeTask` over `buildConversationText(chunks)`. Nothing in `task-processor.ts` cross-checks that every factual claim in the summary appears in a chunk. Hallucination is **not detected by the plugin**; there are no reference-style citations back to chunk IDs in the summary body. |
| Skip-short-task logic | `shouldSkipSummary` drops conversations < 4 chunks or <200 chars (80 CJK) — these tasks end with `summary=reason, status="skipped"`. **Data still exists in chunks**, just no summary row populated. Acceptable, but search over `tasks` misses them. |
| Reverse link | No reverse index: given a claim in a summary, there's no mapping to originating chunk(s). |

**Integrity class:** fidelity. **Score: 5/10** — FK structure is sound; summary-to-source traceability is absent.

### 4. Dedup merge correctness
| Facet | Finding |
|---|---|
| Exact dup | `content_hash` (sha256) — catches byte-identical duplicates. |
| Near-dup | `findDuplicate(newVec, threshold=0.92–0.95)` via O(n) cosine scan over all embeddings of matching owners (`dedup.ts:12`). |
| Merge semantics | Schema provides `dedup_status`, `dedup_target`, `dedup_reason`, `merge_count`, `merge_history` (JSON array). Source of truth for merged behavior is wherever `findDuplicate` is called; when a near-dup is found, the newer row's unique facts (e.g. "Alice is 30" vs the existing "Alice is 25") are **not structurally reconciled** — merge decision is up to caller. The schema can preserve both via `merge_history` but there is no code path that diff-extracts conflicting claims into a safe delta. |
| "Alice is 25" vs "Alice is 30" | Two separate sha256 hashes (confirmed: `d443c6…` vs `2ba61f…`); if cosine ≥ threshold they will be flagged as dup and one will be superseded — the conflicting age becomes recoverable only if `merge_history` captured original content. |
| Near-dup across owners | `getAllEmbeddings(ownerFilter)` restricts by owner, so cross-owner dedup is opt-in. |

**Integrity class:** fidelity. **Score: 5/10** — plumbing exists, reconciliation logic is thin; "keep newer and lose facts" is possible.

### 5. Embedding drift
- Embedding dimensionality is stored per-row in `embeddings.dimensions` — good, a model change that produces different dims won't silently corrupt cosine math (dim mismatch would throw at `cosineSimilarity`).
- But there is **no embedder-version column**. Two embeddings of the same text from different model versions are indistinguishable in schema. A forced re-embed run on a subset produces a **bimodal index** — recall against queries embedded with the new model gives lower scores for the old-model subset. No migration path is codified.
- Corrupted vector (tested: wrote `Buffer.from("garbage")`, dims=999): DB accepts unconditionally. Downstream cosine will either NaN out or mis-score. No checksum/length guard.

**Integrity class:** consistency. **Score: 4/10** — no version tag, no bulk re-embed protocol, blob accepted without validation.

### 6. Soft-delete propagation
- Marking `dedup_status='superseded'` does **not** propagate to:
  - `chunks_fts` — FTS row stays (triggers don't filter). Queries must explicitly `AND dedup_status='active'` or bad hits return. Probed: soft-deleted row still matches FTS.
  - `embeddings` — row remains; still scanned by `getAllEmbeddings` in dedup.
- No orphan after true delete (FK CASCADE drops embedding). But true DELETE is rare; the code prefers soft-delete.
- No dangling FK observed when FK ON.

**Integrity class:** isolation. **Score: 4/10** — soft-deleted rows leak into search and dedup scans unless every caller remembers to filter.

### 7. Clock skew handling
- Timestamps are `Date.now()` from whichever client wrote. Tested: rows with `created_at` in the year 2027 (+1 year) and with `created_at = -1` are accepted without validation.
- Ordering (`idx_chunks_session_created`) will place future rows ahead of present rows; recency-decay (`recency.ts`) will score them higher.
- No server-side clamp, no skew detection.

**Integrity class:** ordering. **Score: 3/10** — a misconfigured client clock poisons recency ranking indefinitely.

### 8. Content-fidelity round-trip (chunk insert → SELECT)
All 14 payload classes (decimals, `9007199254740993`, emoji 🔥, Chinese, Arabic RTL, complex URL, triple-backticks, escaped-JSON, markdown pipes, **null bytes `\x00`**, control chars CR/LF/TAB/BELL, 10 000-char line, mixed newlines, no-trailing-nl) survived byte-for-byte through `INSERT → SELECT`. Lengths and byte counts identical.

Caveats (retrieval via FTS, not raw SELECT):
- `chunks_fts` uses **tokenize=trigram** — queries under 3 consecutive non-space chars never match. Confirmed: `'🔥'` / `'永和'` / `'X'` return 0; `'🔥🔥🔥'` / `'永和九'` / `'XXX'` return 1. Short emoji or 2-char CJK queries silently miss.
- Null-byte content is searchable ("before after" → 1 hit).

**Integrity class:** fidelity. **Score: 9/10** — storage is byte-exact; trigram tokenizer is a legitimate but undocumented retrieval limitation.

### 9. Orphan / FK integrity
- With `foreign_keys=ON` (plugin default): deleting a chunk correctly cascades embedding rows; orphan embedding INSERT is blocked.
- With FK OFF (default for any external connection, e.g. a forgotten CLI/migration): orphans insert freely.
- `chunks_fts` is a content-backed FTS5 table; its data blocks live independently (`chunks_fts_data`). If the `chunks` table is rebuilt or the triggers disabled during a manual admin op, FTS drifts. No rebuild command is exposed.
- Corrupt `embeddings.vector` blob: DB accepts (18-byte "garbage" stored with dims=999). Plugin has no length-equals-`dimensions*4` invariant.

**Integrity class:** isolation + fidelity. **Score: 6/10** — plugin's own connection is safe; any external connection is a foot-gun.

### 10. Concurrent edit semantics
Two in-process connections both updating the same `chunks.id` in sequence: final content = last writer, no conflict detection.
- No `version`, `etag`, or `updated_at_must_equal` check — pure last-writer-wins.
- WAL-mode allows concurrent reads during writes, but there is no optimistic-concurrency path for coordinated multi-client writes.
- Same applies to `skills`, `tasks`.

**Integrity class:** isolation. **Score: 4/10** — single-writer assumption baked in; multi-client writes will silently clobber.

### 11. Backup / restore
`sqlite3 memos.db '.dump' | sqlite3 restored.db`: row counts identical across `chunks (32)`, `embeddings (32)`, `tasks (2)`, `skills (1)`, `chunks_fts (32)`. FTS MATCH query returns same hit count. No documented export/import tool beyond raw sqlite.

**Integrity class:** durability. **Score: 8/10** — standard `.dump` works; no plugin-level backup tooling means restore of a *live* DB during plugin runtime needs external coordination (WAL checkpointing, stopping plugin first).

---

## Summary table

| Area | Score | Key finding |
|------|-------|-------------|
| Local ↔ hub consistency | 4 | No transaction, silent field loss, hub re-embeds and re-stamps |
| Skill file ↔ index | 3 | No fsync/atomic rename; zero drift detection; `rm -rf` before `cp` |
| Summary ↔ chunk fidelity | 5 | FK sound; no citation back to source chunks, no hallucination guard |
| Dedup merge correctness | 5 | Hash+cosine detection fine; merge keeps newer, `merge_history` optional |
| Embedding drift | 4 | No model-version column; bulk re-embed undefined; blobs accepted raw |
| Soft-delete propagation | 4 | FTS and embeddings still contain superseded rows |
| Clock skew handling | 3 | Pure client `Date.now()`; future + negative ts both accepted |
| Content fidelity | 9 | Byte-exact storage; trigram-FTS has ≥3-char minimum |
| Orphan / FK integrity | 6 | Safe when plugin holds the connection; external connections can orphan |
| Concurrent edit semantics | 4 | Last-writer-wins; no version column anywhere |
| Backup / restore | 8 | `.dump`/restore lossless; no plugin-level tooling |

**Overall integrity score = MIN = 3/10.**
Bottleneck risks: skill-file durability (no atomic writes), clock-skew acceptance.

## Priority fixes (highest integrity ROI)
1. **Atomic skill writes** — write to `<name>.md.tmp`, `fsync`, `rename`, `fsync` dir. Apply to `generator.ts` and `installer.cleanSync`.
2. **Clock-skew clamp** — server-side (or on-write) clamp of `created_at` into `[now-30d, now+5m]`; log outliers.
3. **Embedder version tag** — add `embeddings.model_id TEXT` and `embeddings.model_version INT`; gate cosine by matching model; expose bulk re-embed.
4. **Soft-delete-aware FTS** — include `dedup_status` as an indexed column on the FTS content table, or change every search call site to filter explicitly and add a CI lint.
5. **Optimistic concurrency** — `chunks.version INTEGER`, bump on UPDATE, reject stale writes. Same for `skills`/`tasks`.
6. **Hub outbox** — persist pending `/share` calls in a local queue table with retry-on-reconnect.
7. **Vector invariant** — enforce `length(vector) = dimensions*4` via CHECK constraint.
