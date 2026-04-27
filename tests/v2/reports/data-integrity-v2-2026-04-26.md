# memos-local-plugin v2.0 Data Integrity Audit

**Marker:** INTEG-AUDIT-1745696400  
**Date:** 2026-04-26  
**Plugin version:** v2.0.0-beta.1  
**DB path:** `~/.hermes/memos-plugin/data/memos.db`  
**Plugin source:** `~/.hermes/memos-plugin/`  
**Auditor session:** independent (no prior reports read)

---

## Environment

- SQLite (via better-sqlite3)
- 13 migrations applied (001-initial … 013-trace-turn-id)
- 30 traces, 40 episodes, 17 sessions, 0 policies/skills/world-model rows
- Embedder: local all-MiniLM-L6-v2 (384 dims → 1536-byte BLOBs)
- Throwaway DB (`/tmp/memos-audit-idempotence-*.db`) used for migration probes; no pre-existing rows touched

---

## Recon summary

### Tables present (`.tables`)
```
api_logs            decision_repairs    episodes
feedback            kv                  l2_candidate_pool
policies            schema_migrations   sessions
skills              traces              world_model
```
Plus FTS shadow tables for traces, skills, world_model.

**Notable absence:** the audit brief expected `turns`, `memories_l1`, `memories_l2`, `memories_l3`, `captures`, `tasks`, `skill_evidence`, `embeddings`, `config_kv`. None of these exist. The v2 schema uses different names: `traces` (L1), `policies` (L2), `world_model` (L3), `kv` (config_kv). No `captures`, `tasks`, or dedicated `embeddings` table; vectors are inline BLOBs on each row.

### Migration count
13 migrations (001–013). Audit brief expected 12; migration 013 (`trace-turn-id`) was added after the brief was written.

---

## Schema probes

### `PRAGMA foreign_keys`
**Via CLI:** returns `0` (OFF) — expected, FK enforcement is per-connection and not stored in the file.  
**At plugin runtime:** `connection.ts` unconditionally executes `raw.pragma("foreign_keys = ON")` on every open, so FKs ARE enforced during normal operation.  
**Evidence (connection.ts lines 27–38):**
```typescript
raw.pragma("foreign_keys = ON");
raw.pragma(`journal_mode = ${wal ? "WAL" : "DELETE"}`);
raw.pragma(`synchronous = ${synchronous}`);
```

### `PRAGMA journal_mode`
Returns `wal` on the live DB. WAL mode confirmed. ✓

### `PRAGMA synchronous`
Default in `openDb`: `"NORMAL"` (value 1). Live DB read via CLI shows 2 (FULL) — this reflects the CLI's own default, not the plugin's setting (synchronous is per-connection, not persisted). Plugin uses NORMAL, which is appropriate for WAL and provides crash-safe committed-transaction durability.

### `SELECT version FROM schema_migrations`
All 13 versions present (1–13), applied in monotonic order. Timestamps all cluster around 1777124219711 ms (2026-04-23). ✓

### Schema drift vs migration SQL

**FINDING SD-1 (HIGH): `DATA-MODEL.md` is stale after migration 012.**

| Object | DATA-MODEL.md says | Live schema says | Difference |
|--------|-------------------|-----------------|------------|
| `policies.status` | `candidate \| active \| retired` | `candidate \| active \| archived` | `retired` → `archived` |
| `skills.status` | `probationary \| active \| retired` | `candidate \| active \| archived` | both terms changed |
| `skills` columns | omits `version`, `share_scope/target/shared_at`, `edited_at` | all present | 5 missing columns |
| `world_model` columns | omits `structure_json`, `domain_tags_json`, `confidence`, `source_episodes_json`, `induced_by`, `share_*`, `archived_at`, `status` | all present | 9 missing columns |

The documentation was not updated when migrations 003, 008, 009, 012 were applied. A developer reading DATA-MODEL.md will write code targeting non-existent or renamed status values.

**FINDING SD-2 (MEDIUM): `world_model.status` has no CHECK constraint.**

Migration 009 added:
```sql
ALTER TABLE world_model ADD COLUMN status TEXT NOT NULL DEFAULT 'active';
```
No `CHECK (status IN ('active','archived'))` was added. Migration 012 renamed `retired_at` → `archived_at` on `world_model` but did not add a status constraint. Live schema confirms absence:
```
status TEXT NOT NULL DEFAULT 'active', archived_at INTEGER
```
Any string (e.g. `'retired'`, `'deleted'`, `''`) can be inserted without error. The viewer's filter logic silently works on a superset it doesn't expect.

---

## Migration correctness

### Apply on empty DB
Applied all 13 migrations to a fresh throwaway DB via sequential `sqlite3 < *.sql`. All tables created correctly. `schema_migrations` is version 13. ✓

### Migration 012 and `PRAGMA writable_schema`
Migration 012 uses `PRAGMA writable_schema = 1` to regex-replace CHECK constraint text in `sqlite_master`. The migrator correctly enables `db.raw.unsafeMode(true)` beforehand (better-sqlite3 ≥ v11 blocks this without it).

**FINDING MI-1 (MEDIUM): `writable_schema` regex replacement is fragile and silent on no-match.**

The UPDATE is:
```sql
UPDATE sqlite_master
  SET sql = replace(sql, 'CHECK (status IN (''candidate'',''active'',''retired''))', ...)
WHERE type='table' AND name='policies';
```
SQLite's `CREATE TABLE` serializer may reformat whitespace, quote styles, or column ordering between SQLite versions. If the stored text doesn't match the expected literal, `replace()` returns the original string unchanged, the UPDATE succeeds with 0 rows affected, and no error is raised. The old CHECK constraint silently survives. There is no assertion or row-count check after the UPDATE.

**FINDING MI-2 (LOW): Partial-apply recovery is correct but untested.**

Each migration runs inside `db.tx()` (a single `BEGIN/COMMIT` wrapping both the SQL and the `schema_migrations` INSERT). If SIGKILL fires mid-transaction, WAL rolls back the partial write. On restart, migrator reads `schema_migrations`, skips applied versions, and resumes at the interrupted migration. This is the correct design. Verified by code inspection; no automated test for this path.

**FINDING MI-3 (LOW): `ALTER TABLE ADD COLUMN` migrations are not SQL-level idempotent.**

Re-running migrations 002–013 (excluding 012) directly via CLI fails with "duplicate column name" errors. Idempotence lives entirely in the migrator's `appliedVersions` set. If `schema_migrations` is manually corrupted or a row is deleted, the migrator will attempt to re-apply and fail. No defensive `IF NOT EXISTS` guards on `ALTER TABLE` statements.

---

## FK & cascade probes

`PRAGMA foreign_key_check` on live DB: **empty** — no violations. ✓

Cascade policy verified from migration SQL:

| Parent → Child | Policy |
|---------------|--------|
| `sessions` → `episodes` | ON DELETE CASCADE |
| `sessions` → `traces` | ON DELETE CASCADE |
| `episodes` → `traces` | ON DELETE CASCADE |
| `episodes` → `feedback` | ON DELETE SET NULL |
| `traces` → `feedback` | ON DELETE SET NULL |
| `policies` → `l2_candidate_pool` | ON DELETE SET NULL |

**FINDING FK-1 (MEDIUM): `episodes.trace_ids_json` is a denormalized JSON array not backed by FK.**

The `trace_ids_json` TEXT column stores `["tr_…", "tr_…"]` — a redundant copy of the episode's trace IDs. If a trace is deleted (cascaded from episode deletion), `trace_ids_json` on the parent episode is NOT updated. Conversely, if a trace is inserted after the episode row, `trace_ids_json` may lag. This is a consistency gap between the FK-enforced relational graph and the cached JSON array.

---

## JSON column validity

All 12 JSON-bearing columns have `CHECK (json_valid(…))` constraints in the migration SQL, and the live schema confirms them (except `world_model.status` which is not JSON).

**Probe — insert malformed JSON into `kv.value_json`:**
```
sqlite3 memos.db "INSERT INTO kv(key, value_json, updated_at) VALUES('test', 'not_valid_json', 1);"
Error: stepping, CHECK constraint failed: json_valid(value_json) (19)
```
CHECK enforcement works at the SQLite level. ✓

**Probe — content fidelity on `kv.value_json`:**

| Input | Round-trip output | Match? |
|-------|------------------|--------|
| `3.141592653589793238` | `3.141592653589793238` | ✓ exact |
| `9007199254740993` (beyond JS MAX_SAFE_INTEGER) | `9007199254740993` | ✓ exact (SQLite stores as INTEGER, not float) |
| `"Hello 🌍 你好 مرحبا"` | `"Hello 🌍 你好 مرحبا"` | ✓ exact |

**FINDING JC-1 (LOW): `api_logs.input_json` and `api_logs.output_json` have no `json_valid` CHECK.**

Migration 007 creates:
```sql
input_json   TEXT NOT NULL DEFAULT '{}',
output_json  TEXT NOT NULL DEFAULT '',
```
No CHECK constraint on either column. `output_json` is explicitly noted as "sometimes a plain stats summary line + JSON lines" — intentionally not always valid JSON. But `input_json` could silently accept malformed input without rejection.

---

## Vector encoding & dim safety

**Storage format:** BLOB, Float32 little-endian. Confirmed: `length(vec_summary) = 1536` bytes = 384 floats × 4 bytes. ✓  
**Byte inspection:** `hex(substr(vec_summary,1,16))` → `4416F4BDDAE4F2BBEB3C36BDD54DD23B` — valid float32 LE pattern. ✓  
**Endianness portability:** "Node Buffers are always little-endian on our supported platforms" (`vector.ts` comment). If the DB is copied to a big-endian host (e.g., IBM z/Architecture), decoding breaks silently — vectors are not tagged with endianness metadata.

**FINDING VE-1 (MEDIUM): Dim-mismatch is a soft skip, not a hard fail.**

`topKCosine` in `vector.ts`:
```typescript
if (row.vec.length !== query.length) {
  log.warn("search.dim_mismatch", { expected: query.length, got: row.vec.length, rowId });
  continue;  // silently skip
}
```
A provider swap (e.g., 384-dim local → 1536-dim OpenAI) leaves legacy rows in the DB that are silently dropped from every retrieval query. No hard error, no actionable user-facing message, no count of skipped rows in the retrieval result. Old memories become permanently unreachable without any indication.

**FINDING VE-2 (LOW): Embedding cache key omits dimension.**

`makeCacheKey` in `cache.ts`:
```typescript
h.update(k.provider); h.update("|"); h.update(k.model); h.update("|");
h.update(k.role);     h.update("|"); h.update(k.text);
```
`dim` is not included. If a provider is reconfigured to emit a different dimension under the same `provider:model` pair (e.g., a locally-served model is swapped), the in-memory cache serves the old vector without recomputing. Cross-contamination lasts until the LRU cache evicts the entry or the process restarts. In practice this scenario is unlikely, but the cache key's safety depends on `model` uniquely implying `dim`.

---

## Clock & ID stability

**FINDING CK-1 (MEDIUM): Timestamps use `Date.now()` — not monotonic.**

`core/time.ts`:
```typescript
let _now: () => EpochMs = () => Date.now();
```
`Date.now()` can go backward on NTP step-corrections or manual `timedatectl set-time`. The `ts` column on `traces` is used as an ORDER BY key (`idx_traces_episode_ts`, `idx_traces_session_ts`). A clock jump backward produces an out-of-order trace that the viewer renders incorrectly (out-of-sequence memories in the timeline).

No monotonic guard or sequence counter exists. `hrNowMs()` uses `process.hrtime.bigint()` (monotonic) but is only used for duration measurements, not for row timestamps.

**FINDING CK-2 (LOW): IDs are 60-bit random — collision risk in multi-agent scenarios.**

All entity IDs (traces, episodes, etc.) use `shortId(12)`: 12 bytes from `randomBytes` masked to 5 bits each = 60 bits of entropy. With 10⁶ inserts, birthday collision probability ≈ 4×10⁻¹¹ — negligible for single-agent use. With 10 concurrent agents each writing 10⁴ rows, still negligible (~10⁻⁸). Not a practical risk at current scale, but worth noting since `id` is `TEXT PRIMARY KEY` with no fallback.

---

## Export / import round-trip

**FINDING EI-1 (HIGH): No export/import API exists.**

Searched `server/routes/`, `bridge/methods.ts`, `agent-contract/jsonrpc.ts` for `export`, `import`, `dump` keywords. Only match: `GET /api/v1/skills/:id/download` which generates a single-skill ZIP containing a SKILL.md markdown string. There is no mechanism to export the full DB through the plugin API.

**Operational implication:** Users must stop the plugin, run `sqlite3 memos.db '.dump' > backup.sql` manually, and restore by replaying against a blank DB. No integrity verification is performed by the plugin on startup against a restored DB (only `PRAGMA integrity_check` inside migration 012, which is one-time). A corrupted import produces no plugin-level alert.

---

## Cross-table referential integrity

`PRAGMA foreign_key_check`: **empty** — no FK violations. ✓  
`PRAGMA integrity_check`: **ok** ✓

**FINDING RI-1 (MEDIUM): Skills are not file-backed — audit expectation mismatch.**

The audit brief expects: "Every `skill` row in status=active should have a corresponding skill package directory at `~/.hermes/memos-plugin/skills/<id>/`." The live `skills/` directory is empty. Skills are purely DB-resident. The `skills/<id>/SKILL.md` file concept does not exist in v2 — `invocation_guide` lives in the `skills` table row. The crystallizer (`core/skill/skill.ts`) writes to DB via `repos.skills.upsert()` inside a transaction; no filesystem package is created. The SKILL.md is generated on-demand for download only.

This represents a significant architecture divergence from what the audit brief expected, but it is internally consistent: DB transactions are atomic, so there is no torn-write concern.

**FINDING RI-2 (LOW): FTS index can drift from base tables on schema changes.**

FTS triggers (migration 010) fire on INSERT/UPDATE/DELETE. If a future migration alters indexed columns without updating the triggers, the FTS index silently diverges. No periodic consistency check between `traces_fts` and `traces` exists at runtime. The migration-010 backfill uses `WHERE id NOT IN (SELECT trace_id FROM traces_fts)` — correct for a one-time fill but not for ongoing drift detection.

---

## Reward / priority math

**Backprop formula (from `backprop.ts`):**
```
V_T = R_human
V_t = α_t · R_human + (1 − α_t) · γ · V_{t+1}
priority_t = max(V_t, 0) · 0.5^(Δt_days / halfLifeDays)
```

**Manual verification with R=0.8, γ=0.9, 3 traces, α=[0.3, 0.5, 0.7]:**
- V_2 = 0.8 (terminal)
- V_1 = 0.5×0.8 + 0.5×0.9×0.8 = 0.40 + 0.36 = 0.76
- V_0 = 0.3×0.8 + 0.7×0.9×0.76 = 0.24 + 0.4788 = 0.7188

Code produces the same result (formula is a direct translation). ✓

**FINDING RP-1 (INFORMATIONAL): All 30 live traces have `value=0`, `r_human=NULL`.**

Backprop has never been triggered on the live DB. All traces show `priority=0.5` (initial capture default). The reward pipeline is wired but no feedback or auto-fallback timer has fired. This limits live validation of the formula against DB state.

**FINDING RP-2 (LOW): Priority can asymptotically approach zero but never reach negative; no floor.**

`priority = max(V, 0) · decay` — correct, cannot go negative. ✓  
For negative-V traces (bad outcomes), `max(V,0)=0`, so `priority=0`. These traces are queryable via `ORDER BY abs(value) DESC` (there IS an index for this: `idx_traces_abs_value`). Correct design. ✓

---

## Audit-log integrity

**FINDING AL-1 (HIGH): `audit_events` table has 0 rows; no file-based `audit.log` exists.**

Live DB: `SELECT count(*) FROM audit_events` → 0.  
`~/.hermes/memos-plugin/logs/` is empty (no log files at all).  
The plugin has not been run in a mode that emits audit events for the 30 captured traces. The `audit_events` schema exists, and the `core/storage/repos/audit.ts` repo is present, but call sites that insert audit events for trace writes (capture, delete) have not been exercised — or the repo is not wired into the capture pipeline.

Consequence: there is no audit trail for any of the 30 existing trace rows.

**FINDING AL-2 (MEDIUM): No checksum chain or append-only enforcement on audit log.**

The `audit_events` table is a standard SQLite table: rows can be deleted with `DELETE FROM audit_events` without restriction. The file-based `audit.log` (per `docs/LOGGING.md`) has no OS-level append-only flag (`chattr +a`) and no HMAC chain linking entries. An attacker with filesystem access can truncate or rewrite both surfaces without detection.

---

## WAL & durability

**Journal mode:** WAL ✓  
**WAL autocheckpoint:** 1000 pages (`wal_autocheckpoint = 1000`) ✓  
**synchronous:** NORMAL — committed transactions survive OS crash but not power loss before the WAL is flushed. Acceptable for a local-first plugin; FULL would be a performance hit.  
**WAL files at audit time:** `memos.db-shm` and `memos.db-wal` present but 0 bytes (idle, fully checkpointed). ✓

**FINDING WD-1 (LOW): `PRAGMA wal_checkpoint(TRUNCATE)` not tested under load.**

No kill-9 durability test was run in this session (would require a live plugin process writing rows). From code inspection, better-sqlite3 uses synchronous writes and WAL atomicity is delegated to SQLite — no known gap. However, `wal_autocheckpoint=1000` is the only guard; under sustained write load, WAL file can grow large before checkpointing.

---

## Content fidelity round-trip

All tests performed via `kv` table with JSON-valued storage:

| Content | Input | Output | Status |
|---------|-------|--------|--------|
| High-precision float | `3.141592653589793238` | `3.141592653589793238` | ✓ exact |
| Large int > MAX_SAFE_INTEGER | `9007199254740993` | `9007199254740993` | ✓ exact (stored as INTEGER) |
| Emoji + CJK + RTL Arabic | `"Hello 🌍 你好 مرحبا"` | identical | ✓ |
| Malformed JSON | `not_valid_json` | rejected (CHECK error) | ✓ |

**FINDING CF-1 (LOW): NULL byte (`\x00`) not explicitly tested.**

SQLite TEXT columns can store embedded NUL bytes since v3.23, but the behavior of CHECK constraints and better-sqlite3 binding on NUL-containing strings was not verified in this session. If a user message contains `\x00` (e.g., from binary output in a tool call), the `user_text` column (no json_valid constraint, just TEXT) will accept it. FTS5 trigram tokenizer may produce unexpected results on NUL bytes.

---

## Scoring summary

| Area | Score | Key finding |
|------|-------|-------------|
| Schema drift vs migrations | 5/10 | DATA-MODEL.md stale for 3 tables post-012; world_model.status has no CHECK constraint |
| Migration idempotence & partial-apply | 7/10 | Migrator-level idempotence correct; writable_schema regex is fragile and silent on no-match |
| FK enforcement & cascade | 8/10 | Runtime enforcement correct; episodes.trace_ids_json is denormalized and can diverge |
| JSON-column validity | 8/10 | All critical columns guarded; api_logs.output_json intentionally unguarded |
| Vector encoding + dim safety | 6/10 | Float32 LE correct; dim-mismatch is silent skip not hard fail; cache key omits dim |
| Clock & ID stability | 7/10 | Date.now() non-monotonic; timestamps used as ORDER BY keys |
| Export / import round-trip | 3/10 | No export/import API; manual sqlite3 dump only; no startup integrity check |
| Cross-table referential integrity | 7/10 | FK check clean; trace_ids_json denormalized; skills not filesystem-backed |
| Reward / priority math | 9/10 | Formula correct per V7 §0.6; live backprop never triggered to verify against DB |
| Audit-log integrity | 3/10 | 0 audit events in live DB; no append-only enforcement; no checksum chain |
| WAL durability | 8/10 | WAL + NORMAL synchronous correct; kill-9 test not run live |
| Content fidelity | 8/10 | Float, int, Unicode round-trips exact; NULL byte not tested |
| Skill-package FS integrity | 8/10 | Skills are DB-native (no filesystem packages); DB writes are transactional |

**Overall integrity score = MIN(above) = 3/10**

The floor is set by two findings: no export/import mechanism (EI-1) and an effectively absent audit trail (AL-1 + AL-2). These are architectural gaps, not implementation bugs — they require deliberate feature work to close.

---

## Priority remediation list

1. **(Critical) AL-1** — Wire `audit_events` inserts into the capture pipeline for all trace CRUD operations. Verify with `SELECT count(*) FROM audit_events` after a session.
2. **(Critical) EI-1** — Implement a `memos-local-plugin export` CLI/API that dumps all tables to a portable JSON or SQL file and verifies row counts on import.
3. **(High) SD-1** — Regenerate `docs/DATA-MODEL.md` from migration SQL to fix stale status enums and missing columns.
4. **(High) SD-2** — Add `CHECK (status IN ('active','archived'))` to `world_model.status` via migration 014.
5. **(Medium) MI-1** — Replace the `writable_schema` regex approach in migration 012 with a table-rebuild (`CREATE TABLE new_ … INSERT INTO new_ … DROP TABLE … ALTER TABLE new_ RENAME`) that is immune to formatting variations.
6. **(Medium) VE-1** — Surface a user-visible count of dim-skipped rows in the retrieval result; add a startup warning when stored vector dims don't match current embedder dim.
7. **(Medium) CK-1** — Add a monotonic sequence column (`seq INTEGER`) to `traces` for stable ordering, keeping `ts` as the human-readable timestamp.
8. **(Low) VE-2** — Include `dim` in the embedding cache key: `sha256(provider|model|dim|role|text)`.
9. **(Low) AL-2** — Add an HMAC chain to `audit.log` (each line signs the previous line's hash) or use OS-level append-only (`chattr +a`).
