# memos-local-plugin v2.0 Resilience Audit

Paste this into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

You are attacking the failure modes of `@memtensor/memos-local-plugin` v2.0.0-beta.1. Plugin source lives at `~/.hermes/plugins/memos-local-plugin/`. Runtime state at `~/.hermes/memos-plugin/` — SQLite (WAL) at `data/memos.db`, logs at `logs/`, skills at `skills/`, bridge pid/port in `daemon/`. HTTP server + viewer on loopback `127.0.0.1:18799` (walks `+1..+10` on collision; actual port reported by `GET /api/v1/health`). Optional TCP bridge on `18911` (when `bridge.mode: "tcp"`). Optional team-sharing hub on `18912` (when `hub.enabled: true` and `hub.role: "hub"`).

**Your job:** break this system every way you can and measure recovery. Score resilience 1-10 with evidence.

Use marker `RES-AUDIT-<timestamp>`. Stand up a throwaway install per README precondition. Restart from clean between destructive scenarios.

### Recon (read before attacking)

- `core/storage/migrator.ts` + `core/storage/db.ts` — startup order, WAL setup, failure modes.
- `core/llm/README.md` + provider adapters (`openai`, `anthropic`, `gemini`, `bedrock`, `host`, `local_only`). Fallback behaviour.
- `core/embedding/README.md` + adapters (`local`, `openai`, `gemini`, `cohere`, `voyage`, `mistral`). Cache + retry policy.
- `core/capture/` — dead-letter / outbox? Synchronous vs queued path.
- `core/hub/README.md` — team-sharing degradation story.
- `server/http.ts` + `server/middleware/` — request size caps, connection limits, graceful shutdown.
- `bridge.cts` + `bridge/stdio.ts` — line-delimited JSON-RPC protocol, backpressure.
- `agent-contract/errors.ts` — the ERROR_CODES you should see surface at the boundary.

### Failure scenarios

**LLM-provider outage:**
- Configure provider to point to an unreachable host (or revoke API key). Send a capture — L1 row still written? α-scoring fallback engaged (`core/capture/alpha-scorer.ts`)? L2 induction, L3 abstraction, skill crystallization, reward rubric — each stage: queue, skip with marker, or hard fail?
- Restore provider: queued jobs catch up? Any infinite retry burn? Check `llm.jsonl` for retry counts.
- `host` provider (via bridge to host Claude CLI) specifically: kill the host process mid-call — bridge recovers or dangles?

**Embedder outage:**
- Point embedder to unreachable host (or delete the local cache dir). Send capture — row lands with `embedding=NULL` + scheduled re-embed, or capture rejected?
- Restart embedder, confirm backfill path (if exists).
- Dim mismatch: swap embedder model to one with different output dim without re-migrating. Retrieval — hard-fail with actionable log, or silent cosine across mismatched lengths?

**SQLite corruption:**
- Stop plugin. Truncate last 1024 bytes of `data/memos.db`. Restart. Crash? Rebuild from WAL? Refuse to boot with actionable error?
- Same with `data/memos.db-wal` truncated, and with `data/memos.db-shm` deleted.
- Append random bytes mid-file. On next `SELECT`, SQLITE_CORRUPT? Plugin catches and logs to `error.log` with context?
- `PRAGMA integrity_check` — is the plugin ever running this at boot? Self-check output in `logs/self-check.log`?

**Partial migration:**
- Drop to migration 006 (delete rows in `schema_version` > 6 and roll back corresponding table changes manually). Restart. Migrator resumes cleanly? Or re-runs from 001 and explodes on existing tables? Exact symptom + error code.
- Interrupt migrator mid-run via `kill -9`. Restart. Idempotent replay?

**Config malformed:**
- Corrupt `config.yaml` (invalid YAML, missing required key, wrong type for a numeric knob). Startup refuses with a specific message mapping to `ERROR_CODES`? Or crashes with Node stack?
- `chmod 644 config.yaml` (should be 600). Plugin refuses / warns / accepts?
- Override `MEMOS_HOME` / `MEMOS_CONFIG_FILE` env vars to a nonexistent path. Behaviour — fall back or fatal?

**Process crash:**
- `kill -9` the HTTP server process mid-request. Connected clients see — RST, silent hang, clean 5xx? `daemon/` pid/port files cleaned up? Restart: stale PID detected + removed + rebound, or port-in-use error + walks fallback?
- Same with `SIGTERM`: graceful shutdown closes connections, flushes WAL, writes shutdown marker to `memos.log`? Time budget before force-kill?
- Crash mid-capture with batch in flight: rows in durable queue survive, or silent drop?
- Crash mid-crystallize: torn `SKILL.md` / `.tmp` leftover in `skills/<id>/`?

**Concurrent writes:**
- Fire 100 parallel captures via RPC (bridge stdio fan-out or HTTP direct). All rows land? Any duplicates? Any `SQLITE_BUSY` surfacing as user-visible error, or is it internally retried with timeout?
- While writes run, fire 50 reads. Are reads starved? Lock timeout vs deadlock path.
- Two processes against the same `MEMOS_HOME`: WAL mode should allow multi-reader + single-writer. Confirm behaviour; any data-race corruption?

**Subscriber back-pressure (SSE):**
- Open 50 concurrent `/api/v1/events` SSE clients. Throttle one to 1 byte/s. Does the server buffer unboundedly (OOM risk) or drop the slow client after a bound? Check server source: back-pressure handling.

**Log rotation under pressure:**
- Flood the plugin with ops to produce rapid log growth. Rotation (size or time based per `docs/LOGGING.md`) happens cleanly? Any gap in the timeline during rotate? Gzipped files appear (`memos.log.1.gz`)?
- Fill disk to 99% while logging. Plugin degrades (drops debug lines) or crashes on ENOSPC?

**Malformed JSON-RPC requests:**
- Send raw binary over bridge stdio. Parser rejects per line without killing the bridge process?
- Oversized payload (e.g. 100 MB turn content). Rate-limited / capped / OOM?
- Send 10,000 RPC calls in one batch — queue depth bounded?
- Method name not in `agent-contract/jsonrpc.ts` registry → specific error code, not 500.

**Hub degradation:**
- If hub is enabled: hub server down → clients degrade to local-only? Hub visible error surfaced in viewer + `events.jsonl`?
- Peer registry (`/api/v1/hub/peers`): if a registered peer dies, stale entry purged on TTL? Peer port collision → `+1..+10` walk confirmed by `GET /api/v1/health.port`.

**Host-LLM-bridge fallback:**
- The `host` LLM provider drives via a spawned bridge to the host environment (e.g. Claude CLI). Kill the host process mid-call. Does the plugin retry, fall back to a secondary provider (if configured), or fail the call with a clear error code?
- Spawn storm: if every call spawns a new host process, cap enforced or fork-bomb risk?

**Network chaos on loopback (if tractable):**
- Introduce loopback latency via `tc qdisc` (requires root — skip if not available; document). Does HTTP client timeout sanely? SSE reconnect logic handles it?

**Rapid restart:**
- Restart the process 50× in 30s. Any zombie process? Port re-use collision + fallback works? `daemon/*.pid` hygiene?

**Viewer under attack:**
- 1000 concurrent HTTP connections to `18799`. Server limits connection count gracefully, or exhausts FDs?
- Slow-loris on viewer routes: does the server enforce request header timeouts?

**Power-cut approximation:**
- Immediately after a capture RPC returns success, `kill -9` plus drop page cache (`echo 3 > /proc/sys/vm/drop_caches`). On restart, is the row durable? This tests fsync policy (`PRAGMA synchronous`).

### Reporting

For each scenario: description, command/attack used, observed behavior, recovery path (auto/manual/data-loss), evidence (log line / error code / row count / timing), score 1-10.

| Failure mode | Score 1-10 | Recovery | Data loss | Evidence |
|--------------|-----------|----------|-----------|----------|
| LLM-provider outage | | | | |
| Embedder outage / dim mismatch | | | | |
| SQLite corruption | | | | |
| Partial migration | | | | |
| Config malformed / perms | | | | |
| Process crash (HTTP) | | | | |
| Mid-capture crash | | | | |
| Mid-crystallize crash | | | | |
| Concurrent writes | | | | |
| SSE back-pressure | | | | |
| Log rotation under pressure | | | | |
| Malformed JSON-RPC | | | | |
| Hub degradation | | | | |
| Host-LLM-bridge fallback | | | | |
| Rapid restart | | | | |
| Viewer connection flood | | | | |
| Power-cut durability | | | | |

**Overall resilience score = MIN of above.** One-paragraph synthesis: under real-world flaky networks, kill -9 of any component, and disk filling up, what's the worst realistic data-loss scenario?

### Out of bounds

Do not read `/tmp/`, `CLAUDE.md`, `tests/v2/reports/`, `memos-setup/learnings/`, prior audit reports, or plan/TASK.md files. Clean up disk-fill scratch files + `RES-AUDIT-*` rows when done.


### Deliver — end-to-end (do this at the end of the audit)

Reports land on the shared branch `tests/v2.0-audit-reports-2026-04-22` (at https://github.com/sergiocoding96/hermes-multi-agent/tree/tests/v2.0-audit-reports-2026-04-22). Every audit session pushes to it directly — that's how the 10 concurrent runs converge.

1. From `/home/openclaw/Coding/Hermes`, ensure you are on the shared branch:
   ```bash
   git fetch origin tests/v2.0-audit-reports-2026-04-22
   git switch tests/v2.0-audit-reports-2026-04-22
   git pull --rebase origin tests/v2.0-audit-reports-2026-04-22
   ```
2. Write your report to `tests/v2/reports/resilience-v2-$(date +%Y-%m-%d).md`. Create the directory if it does not exist. The filename MUST use the audit name (matching this file's basename) so aggregation scripts can find it.
3. Commit and push:
   ```bash
   git add tests/v2/reports/<your-report>.md
   git commit -m "report(tests/v2.0): resilience audit"
   git push origin tests/v2.0-audit-reports-2026-04-22
   ```
   If the push fails because another audit pushed first, `git pull --rebase` and push again. Do NOT force-push.
4. Do NOT open a PR. Do NOT merge to main. The branch is a staging area for aggregation.
5. Do NOT read other audit reports on the branch (under `tests/v2/reports/`). Your conclusions must be independent.
6. After pushing, close the session. Do not run a second audit in the same session.
