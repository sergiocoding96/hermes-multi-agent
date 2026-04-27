# memos-local-plugin v2.0 Data Integrity Audit

Paste this into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

You are auditing data correctness of `@memtensor/memos-local-plugin` v2.0.0-beta.1. The store is SQLite with WAL at `~/.hermes/memos-plugin/data/memos.db`. Schema is built by **additive-only** migrations (`core/storage/migrations/001-init.sql` … `012-status-unification.sql`) applied by `core/storage/migrator.ts` at startup. The plugin SOURCE lives at `~/.hermes/plugins/memos-local-plugin/`; audit runtime state sits at `~/.hermes/memos-plugin/`. (OpenClaw mirror at `~/.openclaw/…`.)

**Your job:** find every way v2.0 can silently lose, reorder, mis-link, mis-encode, or corrupt data across the layers (SQLite rows, blob embeddings, JSON columns, skill package files, log sinks, WAL checkpoints). Score integrity 1-10.

Use marker `INTEG-AUDIT-<timestamp>`. Stand up a throwaway install per README precondition; do not touch pre-existing rows.

### Recon (read these before probing)

- `core/storage/migrations/*.sql` — enumerate tables (expect at least: `turns`, `memories_l1`, `memories_l2`, `memories_l3`, `skills`, `skill_evidence`, `embeddings`, `sessions`, `episodes`, `tasks`, `captures`, `feedback`, `config_kv`, plus `schema_version`).
- `core/storage/migrator.ts` — idempotence strategy, order, failure mode on a partial apply.
- `core/storage/README.md` + `docs/DATA-MODEL.md` — authoritative field list, FKs, indexes, triggers.
- `core/storage/migrations/012-status-unification.sql` — the most recent migration; what columns / backfill / constraint it adds.
- `agent-contract/memory-core.ts` — DTO shape the outside world sees; compare against raw SQL.

### Schema probes

- Dump schema: `sqlite3 ~/.hermes/memos-plugin/data/memos.db '.schema'`. Diff against the concatenated migration SQL — any drift (triggers missing, FKs not declared, indexes not created)?
- `PRAGMA foreign_keys;` — is FK enforcement actually ON at runtime (check both CLI and what the plugin sets via `db.ts` on open)? If OFF, FKs in migrations are cosmetic.
- `PRAGMA journal_mode;` — expect `wal`. `PRAGMA synchronous;` — what level (`NORMAL` vs `FULL`)?
- `SELECT version FROM schema_version;` — matches the highest migration filename?

### Migration correctness

- Apply on an empty DB. All 12 migrations succeed, `schema_version` = 12.
- Partial-apply: interrupt migrator mid-run (e.g. SIGKILL after `005-*.sql`). Restart. Does migrator idempotently resume at 006? Or does it re-run 001-005 and blow up on existing tables? Exact symptom?
- Downgrade: start a DB written by v2.0, attempt to open with a hypothetical older migrator (comment out 012). Does startup refuse cleanly, or silently truncate?
- Backfill: migration 012 unifies status columns — for rows written by an older schema, verify the backfill actually populated the new columns (no NULLs where the app expects an enum value).

### FK & cascade probes

- Find every `REFERENCES` in the migration files. For each, test the cascade policy:
  - Delete a parent row (e.g. a `turn`) that has child rows (`memories_l1`, `embeddings`). Do children cascade-delete, get SET NULL, or block the parent delete?
  - Try the forbidden case — is there a path where an orphan child can exist? Record the exact `PRAGMA foreign_key_check` output.
- `captures` → `turns` → `sessions` → `episodes` chain: delete a session; episodes / tasks cleanup as expected?

### JSON column validity

- Any column storing JSON (policy body, world-model body, skill `procedure_json`, DTO blobs, capture fields): write a malformed JSON via raw SQL, then read through the plugin API. Does the reader crash, return the raw string, or reject the row?
- Write valid JSON through the API; read the raw column; verify the serialization is stable (no double-escaping, no key-ordering churn that breaks idempotence).

### Vector encoding & dim safety

- `embeddings` column: what storage (BLOB? JSON array? sqlite-vec virtual table?). Inspect a row: is the byte layout Float32 LE? Endian-portable if you move the DB to another host?
- Write one row with N dims using provider A (e.g. local all-MiniLM-L6-v2 → 384). Switch embedder config to provider B with different dim (e.g. openai text-embedding-3-small → 1536). Do retrieval queries blow up on the first dim-mismatched row, skip it, or silently cosine across mismatched lengths? Expected: hard fail + actionable log.
- Round-trip: write → read → compare byte-for-byte. Any NaN / Inf / subnormal mangling?
- Cache key: `core/embedding/*` — verify cache keys include BOTH `provider:model:dim` so a provider swap invalidates. If not, cross-contamination.

### Clock & ID stability

- Timestamp source — `Date.now()`? Monotonic? What happens if the system clock jumps backward (`timedatectl set-time <past>`)? Do timestamps go non-monotonic? Are they used as ORDER BY keys?
- ID generation — UUID v4? Or autoincrement? Collisions possible across multi-agent runs on the same machine?
- Create a row with a future timestamp (1 year ahead). Does retrieval still surface it, or does recency-decay push it off-chart?

### Export / import round-trip

- Is there an export endpoint / CLI (check `server/routes/`, `bridge/methods.ts`, `agent-contract/jsonrpc.ts` for `export`/`import` / dump methods)? If so, run it, wipe the DB, import, diff row counts and a sampled row-hash.
- `sqlite3 memos.db '.dump' > backup.sql` → new blank DB → restore. Boot plugin against restored DB: any integrity complaints in `memos.log` / `error.log`?

### Cross-table referential integrity

- Every `memories_l2` policy should link to ≥1 `memories_l1` trace and vice-versa via `skill_evidence` or a bridge table. After running a capture + induction cycle, `PRAGMA foreign_key_check` should be empty. If rows are "orphan-reachable" (no parent and no `visibility=tombstone`), that's a leak.
- Every `skill` row in status=active should have a corresponding skill package directory at `~/.hermes/memos-plugin/skills/<id>/`. Mismatch in either direction?
- Every `episode` should close with an `R_human` and a `task_summary` row; interrupt mid-episode and see if orphans accumulate.

### Reward / priority math drift

- Read `core/reward/README.md` + code. Write 10 turns, close the episode, observe backprop: `V_t = α_t·R + (1-α_t)·γ·V_{t+1}`. Compute expected V values by hand for a small R sequence; compare against DB values. Tolerance ≤ 1e-6.
- Priority decay: read the decay rule, simulate N turns of no-access, verify priority column monotonically decreases and never goes NaN / negative-infinity.

### Audit-log integrity

- `logs/audit.log` is marked forever-retention per `docs/LOGGING.md`. Verify: (a) never gzipped in-place to `.gz` then deleted (should accumulate monthly `.gz`). (b) every mutation emits an entry. Delete a memory via API → audit line with actor, method, id, before/after hash?
- Can an attacker with file-system access truncate `audit.log` without the plugin detecting (no checksum chain, no append-only OS flag)? Document the attack surface.

### WAL & durability

- Write 1000 rows. `kill -9` the plugin mid-write. Restart. Row count = what? WAL file state (`-wal`, `-shm` present, sizes)?
- Force checkpoint: `PRAGMA wal_checkpoint(TRUNCATE);` and confirm no data loss and no schema corruption.
- Full-disk simulation (fill `/home` to 99%): does a write fail cleanly with ENOSPC logged at ERROR, or does the DB enter a half-committed state?

### Content fidelity round-trip

Write a turn containing — then read it back via retrieval and byte-compare:

- Numbers w/ high precision (`3.141592653589793238`)
- Large ints (`9007199254740993` — beyond JS `Number.MAX_SAFE_INTEGER`)
- Unicode: emoji, CJK, RTL Arabic, combining marks, zero-width joiner
- URLs w/ query + fragment, percent-encoding
- Fenced code blocks with triple backticks and language tag
- JSON with escaped quotes and ``
- Markdown tables with pipes
- NULL byte (`\x00`), BEL, DEL, form feed
- 10k-char single line w/ no newline
- Mixed line endings (`\n`, `\r\n`, `\r`)

Log every divergence (silent replacement, truncation, re-encoding).

### Skill-package filesystem integrity

- `skills/<id>/SKILL.md` + sidecars: after crystallization, is the write atomic (tmp → rename + fsync)? Interrupt with `kill -9` during write — torn file possible?
- Delete a skill via API: row marked retired/tombstoned AND filesystem cleaned up? Or leak?
- Manually corrupt `SKILL.md`. Next load — does the plugin detect and mark the skill unavailable, or serve the corrupt content?

### Reporting

For each probe: description, expected, actual, evidence (SQL / file perms / bytes / log line), integrity class (consistency/fidelity/durability/ordering/isolation), score 1-10.

| Area | Score 1-10 | Key finding |
|------|-----------|-------------|
| Schema drift vs migrations | | |
| Migration idempotence & partial-apply | | |
| FK enforcement & cascade | | |
| JSON-column validity | | |
| Vector encoding + dim safety | | |
| Clock & ID stability | | |
| Export / import round-trip | | |
| Cross-table referential integrity | | |
| Reward / priority math | | |
| Audit-log integrity | | |
| WAL durability | | |
| Content fidelity | | |
| Skill-package FS integrity | | |

**Overall integrity score = MIN of above.** Evidence required on every cell.

### Out of bounds

Do not read `/tmp/`, `CLAUDE.md`, `tests/v2/reports/`, `memos-setup/learnings/`, prior audit reports, or plan/TASK.md files.


### Deliver — end-to-end (do this at the end of the audit)

Reports land on the shared branch `tests/v2.0-audit-reports-2026-04-22` (at https://github.com/sergiocoding96/hermes-multi-agent/tree/tests/v2.0-audit-reports-2026-04-22). Every audit session pushes to it directly — that's how the 10 concurrent runs converge.

1. From `/home/openclaw/Coding/Hermes`, ensure you are on the shared branch:
   ```bash
   git fetch origin tests/v2.0-audit-reports-2026-04-22
   git switch tests/v2.0-audit-reports-2026-04-22
   git pull --rebase origin tests/v2.0-audit-reports-2026-04-22
   ```
2. Write your report to `tests/v2/reports/data-integrity-v2-$(date +%Y-%m-%d).md`. Create the directory if it does not exist. The filename MUST use the audit name (matching this file's basename) so aggregation scripts can find it.
3. Commit and push:
   ```bash
   git add tests/v2/reports/<your-report>.md
   git commit -m "report(tests/v2.0): data-integrity audit"
   git push origin tests/v2.0-audit-reports-2026-04-22
   ```
   If the push fails because another audit pushed first, `git pull --rebase` and push again. Do NOT force-push.
4. Do NOT open a PR. Do NOT merge to main. The branch is a staging area for aggregation.
5. Do NOT read other audit reports on the branch (under `tests/v2/reports/`). Your conclusions must be independent.
6. After pushing, close the session. Do not run a second audit in the same session.
