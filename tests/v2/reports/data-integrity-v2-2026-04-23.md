# memos-local-plugin v2.0 — Data Integrity Audit Report

**Marker:** INTEG-AUDIT-1745438400  
**Date:** 2026-04-23  
**Plugin version:** `@memtensor/memos-local-plugin` (13 migrations applied)  
**DB under audit:** `~/.openclaw/memos-plugin/data/memos.db`  
**Source:** `~/.openclaw/extensions/memos-local-plugin/`

---

## Recon Summary

### Tables present (from `.schema`)

`schema_migrations`, `sessions`, `episodes`, `traces`, `policies`, `l2_candidate_pool`, `world_model`, `skills`, `feedback`, `decision_repairs`, `audit_events`, `kv`, `api_logs` — plus FTS5 virtual tables (`traces_fts`, `skills_fts`, `world_model_fts`) and their shadow tables and triggers.

Tables in the audit's expected list that do **not exist**: `turns`, `memories_l1`, `memories_l2`, `memories_l3`, `embeddings`, `sessions`→exists, `tasks`, `captures`. The plugin uses a different taxonomy: L1=`traces`, L2=`policies`, L3=`world_model`. No separate `embeddings` table — vectors are BLOB columns on each row.

### Migration count

13 migrations (`001-initial` … `013-trace-turn-id`), all applied. The audit prompt expects up to 12; migration 013 (`trace-turn-id`) adds `traces.turn_id INTEGER NULL` and a composite index. Applied at startup, recorded in `schema_migrations` (not `schema_version` — see INTEG-1 below).

### Schema version table name

The tracking table is `schema_migrations(version, name, applied_at)`, **not** `schema_version`. `SELECT version FROM schema_version` would error with "no such table".

---

## PRAGMA Probes (CLI session)

```
PRAGMA foreign_keys;   → 0   (CLI default; plugin enables ON at open — see INTEG-3)
PRAGMA journal_mode;   → wal ✓
PRAGMA synchronous;    → 2   (FULL in CLI default; plugin sets NORMAL at runtime)
PRAGMA integrity_check; → ok
PRAGMA foreign_key_check; → (empty — no FK violations)
PRAGMA wal_checkpoint(PASSIVE); → 0|0|0 (WAL fully checkpointed, no pending frames)
```

---

## Findings

### INTEG-1 — `api_logs` table: missing `json_valid()` CHECK + missing STRICT
**Class:** Fidelity | **Severity:** High

**Description:** Every other JSON column in the schema has `CHECK (json_valid(...))` and every other table uses `STRICT`. Migration 007 created `api_logs` with neither:

```sql
-- From 007-api-logs.sql
CREATE TABLE IF NOT EXISTS api_logs (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  tool_name    TEXT    NOT NULL,
  input_json   TEXT    NOT NULL DEFAULT '{}',
  output_json  TEXT    NOT NULL DEFAULT '',   -- '' is NOT valid JSON
  ...
);
```

**Expected:** Malformed JSON rejected with CHECK constraint failure, same as `kv`, `traces`, `policies`, etc.

**Actual (reproduced):**
```sql
INSERT INTO api_logs (tool_name, input_json, output_json, duration_ms, success, called_at)
VALUES ('test_bad', 'NOT-JSON', 'ALSO-NOT-JSON', 0, 1, 1745438000000);
-- succeeds silently; SELECT confirms 1|test_bad|NOT-JSON
```

**Second issue:** `output_json TEXT NOT NULL DEFAULT ''` — the default value `''` is not valid JSON. Any row inserted without an explicit `output_json` lands with an empty string that `JSON.parse` will throw on.

**Evidence:** `007-api-logs.sql` (no CHECK, no STRICT); live probe confirmed acceptance of non-JSON text.

**Score: 4/10**

---

### INTEG-2 — Vector dim mismatch: silent skip, not hard fail
**Class:** Consistency | **Severity:** High

**Description:** `core/storage/vector.ts:124-129` (`topKCosine`):

```typescript
if (row.vec.length !== query.length) {
  log.warn("search.dim_mismatch", {
    expected: query.length,
    got: row.vec.length,
    rowId: String(row.id),
  });
  continue;   // silently excluded from results
}
```

If an embedder switch changes the dimension (e.g. local all-MiniLM-L6-v2 → 384 dim to openai text-embedding-3-small → 1536 dim), all existing rows are silently dropped from every retrieval query. The user sees degraded recall with no error surface — no exception, no counter exposed in health/metrics, no user-visible warning.

**Expected:** Hard fail or a health-check metric that surfaces the count of dim-mismatched rows. At minimum, `core/health()` should report mismatched embedding counts if >0 rows have a different dim than the current provider.

**Actual:** One `WARN` log per mismatched row per query; result set silently shrinks.

**Evidence:** `core/storage/vector.ts:123-128`; no dim-mismatch counter in `CoreHealth` interface (`agent-contract/memory-core.ts`).

**Score: 5/10**

---

### INTEG-3 — `PRAGMA foreign_keys = ON` inside transaction is a no-op
**Class:** Consistency | **Severity:** Medium

**Description:** `core/storage/migrations/001-initial.sql` line 11:

```sql
PRAGMA foreign_keys = ON;
```

This migration runs inside `db.tx()` (a better-sqlite3 transaction). SQLite silently ignores `PRAGMA foreign_keys` changes inside active transactions. The pragma has no effect.

**Expected:** FK enforcement to be set by this statement.

**Actual:** No-op inside the transaction. FK enforcement works only because `connection.ts:48` sets `raw.pragma("foreign_keys = ON")` on the raw connection before any transaction runs. If `openDb` were ever called without the pragma block (e.g., a future caller uses `better-sqlite3` directly), FKs would be OFF and the migration PRAGMA still wouldn't help.

**Evidence:** SQLite documentation: "PRAGMA foreign_keys cannot be enabled or disabled within a transaction"; `migrator.ts:112`: migrations run in `db.tx()`; `connection.ts:48` is the actual enforcement point.

**Score: 7/10** (mitigated by `connection.ts`; risk is latent)

---

### INTEG-4 — `episodes.trace_ids_json` dual source of truth
**Class:** Consistency | **Severity:** Medium

**Description:** There are two ways to enumerate which traces belong to an episode:
1. `SELECT id FROM traces WHERE episode_id = ?` (FK relationship, authoritative)
2. `episodes.trace_ids_json` (denormalized JSON array, maintained manually)

`repos/episodes.ts:110` appends to `trace_ids_json` when a trace is added. However, when a trace is deleted via `repos/traces.ts:deleteById()` (or cascade-deleted when an episode is deleted), there is no trigger or code path that removes the ID from `episodes.trace_ids_json`. After a hard-delete of a trace, `trace_ids_json` contains stale IDs that reference non-existent rows.

**Expected:** Either a trigger updates `trace_ids_json` on `DELETE FROM traces`, or the column is computed on read from the FK side.

**Actual:** No such trigger in the schema. The `traces_fts_ad` trigger (migration 010) removes from the FTS index but does not update `episodes.trace_ids_json`.

**Evidence:** `010-search-fts.sql` triggers; `repos/episodes.ts:110`; no counter-trigger on `traces` DELETE.

**Score: 6/10**

---

### INTEG-5 — Audit log has no checksum chain
**Class:** Durability | **Severity:** Medium

**Description:** `core/logger/sinks/audit-log.ts` writes to `logs/audit.log` via `FileRotatingTransport`. There is no HMAC, rolling checksum, or append-only OS flag on the file.

An attacker (or accidental `truncate`) with filesystem access can:
- Silently truncate `audit.log` to 0 bytes
- Delete or modify past entries
- The plugin has no mechanism to detect tampering on startup or at read time

The in-DB `audit_events` table likewise stores `detail_json` without a before/after content hash — a delete-via-API emits an audit row with `target = id` but no hash of the deleted row's content.

**Expected (per `docs/LOGGING.md`):** "forever-retention". Rotation accumulates `.gz` archives; never deleted. This is enforced by `retention.ts` (`maxFiles: 0`). However, forever-retention ≠ tamper-evidence.

**Actual:** No checksum chain; no append-only flag; no hash of mutated content in `detail_json`.

**Evidence:** `core/logger/sinks/audit-log.ts`; `core/logger/retention.ts:45` (`maxFiles: 0`); `repos/audit.ts` (no hash fields).

**Score: 5/10**

---

### INTEG-6 — Clock non-monotonic; `skills.updateContent` bypasses injectable clock
**Class:** Ordering | **Severity:** Low-Medium

**Description:** Two sub-issues:

**6a.** `core/time.ts` wraps `Date.now()` so tests can inject a deterministic clock via `setNow()`. `core/storage/repos/skills.ts:302` calls `Date.now()` directly instead:

```typescript
params.edited_at = Date.now();   // bypasses core/time.ts
```

Test-clock injection does not affect `edited_at` timestamps on skill content edits.

**6b.** `core/reward/backprop.ts:41`:
```typescript
const now = input.now ?? Date.now();
```
The fallback is `Date.now()`, not `nowMs()`. If callers omit `input.now`, priority computations use wall-clock rather than the injected clock. This matters for deterministic testing of decay math.

**6c.** Backward clock jumps (NTP corrections, `timedatectl set-time <past>`): `traces.ts` inserts `ts = nowMs()` which is `Date.now()`. Timestamps used as ORDER BY keys in three indexes (`idx_traces_episode_ts`, `idx_traces_session_ts`, `idx_traces_priority`). A backward jump makes newer rows appear older in those indexes.

**Evidence:** `repos/skills.ts:302`; `reward/backprop.ts:41`; `core/time.ts:10`.

**Score: 6/10**

---

### INTEG-7 — Export silently drops all embeddings; no re-embed trigger
**Class:** Fidelity | **Severity:** Medium

**Description:** `server/routes/import-export.ts` comment: "Binary blobs (embeddings) are deliberately dropped on export — we can't re-normalise them after transport."

After `POST /api/v1/import` on a wiped DB, all imported rows have `vec = NULL`. Retrieval degrades to keyword-only (FTS + pattern), with no vector channel, until embeddings are regenerated. There is no automatic re-embedding job triggered by import, no UI warning, and the `/health` endpoint's `embedder.lastOkAt` field would not indicate the gap.

**Expected:** Import should either (a) trigger a background re-embedding pass, or (b) emit a health-check warning that N rows are embedding-less after import.

**Actual:** `importBundle()` returns `{ imported, skipped }` — no embedding-gap counter.

**Evidence:** `server/routes/import-export.ts:14-15` (drop comment); `agent-contract/memory-core.ts` `importBundle` return type.

**Score: 6/10**

---

### INTEG-8 — Migration 012 `PRAGMA integrity_check` is non-fatal
**Class:** Durability | **Severity:** Low

**Description:** Migration 012 uses `PRAGMA writable_schema = 1` to swap CHECK constraints in-place (updating `sqlite_master` directly). The migration ends with:

```sql
-- ─── 4. Sanity check (non-fatal; SQLite will throw if schema broken) ─
PRAGMA integrity_check;
```

The comment says "non-fatal". `PRAGMA integrity_check` returns result rows but does not throw an exception on failure when run as a bare SQL statement inside a migration. If the `writable_schema` edit left the schema in an inconsistent state, the transaction commits and the problem is silently swallowed.

**Expected:** The migrator should query the result of `integrity_check` and abort/rollback if it is not `ok`.

**Actual:** The PRAGMA output is discarded. The `db.tx()` wrapping the migration uses `db.exec()` which discards result rows.

**Evidence:** `migrator.ts:112-119` (`db.exec(sql)` discards results); `012-status-unification.sql:87`.

**Score: 7/10** (integrity_check passes on the live DB; risk is correctness of the migration, not ongoing state)

---

### INTEG-9 — Embedding cache key missing explicit dimension
**Class:** Isolation | **Severity:** Low

**Description:** `core/embedding/cache.ts` `makeCacheKey`:

```typescript
h.update(k.provider);
h.update("|");
h.update(k.model);
h.update("|");
h.update(k.role);
h.update("|");
h.update(k.text);
```

The dimension is not included. If a local model is reconfigured to a different output dimension without changing its model name (e.g., same `local` provider, same model path, different truncation), the cache serves stale vectors of the wrong dimension. Downstream `topKCosine` would then log dim-mismatch warnings and skip those entries.

In practice, standard providers encode dim in the model name (e.g., `text-embedding-3-small` vs `-large`). Risk is highest for custom local models.

**Evidence:** `core/embedding/cache.ts:35-44`; `core/embedding/types.ts` (no `dim` in `EmbedCacheKey`).

**Score: 6/10** (low probability on standard setups)

---

### INTEG-10 — WAL + `synchronous = NORMAL`: last-frame durability gap
**Class:** Durability | **Severity:** Low

**Description:** `connection.ts:49`: `raw.pragma(\`synchronous = ${synchronous}\`)` defaults to `"NORMAL"`. In WAL mode with `synchronous = NORMAL`, SQLite does not `fsync` the WAL file after each write. On an OS crash (power loss), up to the last unflushed WAL frame can be lost.

`PRAGMA wal_checkpoint(PASSIVE)` → `0|0|0` (no pending frames in the idle DB), so the live state is clean. This is an at-risk window only during active writes.

**Expected:** For a memory store where data loss means permanent loss of captured turns, `synchronous = FULL` would guarantee every WAL frame is synced before the transaction returns.

**Actual:** `NORMAL` trades ~30% write throughput for a durability gap under OS crash.

**Evidence:** `connection.ts:30,49`; SQLite WAL documentation.

**Score: 7/10** (reasonable trade-off; documented behavior)

---

## Scorecard

| Area | Score 1-10 | Key finding |
|------|-----------|-------------|
| Schema drift vs migrations | 7 | Table is `schema_migrations` not `schema_version`; 13 not 12 migrations; live schema matches SQL |
| Migration idempotence & partial-apply | 7 | Applied-versions set makes it idempotent; 012 `integrity_check` result silently discarded |
| FK enforcement & cascade | 8 | Runtime FKs ON (`connection.ts:48`); CLI shows 0 (expected); no FK violations in DB |
| JSON-column validity | **4** | `api_logs` has no `json_valid()` CHECK, no STRICT; `output_json DEFAULT ''` is invalid JSON; confirmed via probe |
| Vector encoding + dim safety | 5 | Float32 LE BLOB (correct, portable risk on big-endian); dim mismatch silently skips rows; no health metric |
| Clock & ID stability | 6 | `Date.now()` non-monotonic; `skills.updateContent` bypasses `now()`; UUIDv7 + shortId entropy fine |
| Export / import round-trip | 6 | Export/import routes exist and work; embeddings silently dropped; no re-embed trigger or health warning |
| Cross-table referential integrity | 6 | `episodes.trace_ids_json` stale after trace hard-delete; no trigger to reconcile |
| Reward / priority math | 8 | Backprop formula correct (V7 §0.6); clamps applied; `priorityFor` fallback bypasses injected clock |
| Audit-log integrity | 5 | No checksum chain; no before/after content hash; truncatable without detection |
| WAL durability | 7 | WAL enabled; `synchronous=NORMAL` (durability gap under power loss); checkpoint clean |
| Content fidelity | 7 | STRICT + `json_valid()` on all tables except `api_logs`; no NUL/binary fidelity probes possible on empty DB |
| Skill-package FS integrity | 7 | No filesystem SKILL.md files at the plugin layer — skills stored entirely in DB; FS atomicity non-issue here |

**Overall integrity score = MIN = 4/10** (JSON-column validity; `api_logs` table)

---

## Critical Action Items

1. **Fix `api_logs`** (blocks score): Add `CHECK (json_valid(input_json))`, `CHECK (json_valid(output_json))`, change `DEFAULT ''` → `DEFAULT 'null'`, add `STRICT`. Requires a new migration (`014-api-logs-strict.sql`) with a `CREATE TABLE new_api_logs ... INSERT INTO new_api_logs SELECT ... FROM api_logs ... DROP TABLE api_logs ... ALTER TABLE new_api_logs RENAME TO api_logs` pattern (SQLite cannot `ALTER TABLE ... ADD CONSTRAINT`).

2. **Surface dim-mismatch as health metric**: Add `embeddingDimMismatches: number` to `CoreHealth`; expose count of rows with `LENGTH(vec) != expected_dim * 4`.

3. **Reconcile `trace_ids_json` on delete**: Add `UPDATE episodes SET trace_ids_json = json_remove(trace_ids_json, ...) WHERE id = old.episode_id` trigger on `DELETE FROM traces`, or deprecate the column and compute on read.

4. **Audit log tamper-evidence**: Compute a rolling SHA-256 chain entry (`prev_hash XOR entry_hash`) stored in each `audit_events` row; verify chain on startup.

5. **Fix `skills.updateContent` clock bypass**: Replace `Date.now()` with `nowMs()` from `core/time.ts`.
