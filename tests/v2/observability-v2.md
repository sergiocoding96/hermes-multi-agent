# memos-local-plugin v2.0 Observability Audit

Paste this into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

You are auditing the telemetry surfaces of `@memtensor/memos-local-plugin` v2.0.0-beta.1. The plugin exposes logs under `~/.hermes/memos-plugin/logs/`, an HTTP server + viewer on `127.0.0.1:18799` (or fallback `+1..+10`), SSE on `/api/v1/events`, and health on `/api/v1/health`. Source root: `~/.hermes/plugins/memos-local-plugin/`.

**Your job:** play an SRE who has never seen this system. Answer each diagnostic scenario below using ONLY the plugin's telemetry surfaces. Every time you drop to `grep src/` or open the DB to reason, that's a gap — record it. Score observability 1-10.

Use marker `OBS-AUDIT-<timestamp>`.

### Recon (before probing)

- `core/logger/README.md` + `core/logger/*.ts` — channel taxonomy, sinks, redaction pipeline.
- `docs/LOGGING.md` — sink list, retention, rotation rules.
- `server/routes/` — enumerate every endpoint. Which emit structured events?
- `agent-contract/events.ts` — the `CORE_EVENTS` catalogue: every event the plugin can emit on SSE.
- `core/telemetry/` — any counters/timers, and where they're surfaced.
- `web/` — viewer views (Overview / Memories / Policies / WorldModels / Tasks / Skills / Analytics / Logs / Admin / Settings / Help / Import).

### Sink inventory

Enumerate every file under `logs/`. Expected per `docs/LOGGING.md`:

- `memos.log` — human-readable, rotated + gzipped.
- `error.log` — WARN/ERROR/FATAL aggregated across channels.
- `audit.log` — security/mutation events, never deleted (monthly gzip).
- `llm.jsonl` — every LLM call (prompt, response, tokens, latency, cost, provider).
- `perf.jsonl` — every `log.timer()` close.
- `events.jsonl` — every `CoreEvent`.
- `self-check.log` — startup probe results.

For each: confirm exists after boot, line format (plain vs JSON), rotation policy (size or time), gzip behaviour, and retention. Any documented sink missing? Any undocumented sink present?

### Channel + level taxonomy

- Run `sqlite3`/`grep` over sink files to enumerate distinct channel names. Map each to its code home (`core.capture.*`, `core.memory.l1`, `core.retrieval.*`, `core.skill.*`, `core.reward.*`, `core.feedback.*`, `server.*`, `bridge.*`, `llm.*`, `embed.*`, …).
- Is there a live knob to raise a single channel to DEBUG without restart (config reload? `/api/v1/config`?)? Test it.
- Cross-channel consistency: pick one turn, grep its id across all sinks — every sink that *should* mention it does?

### Diagnostic scenarios

Answer each using **only** the indicated surfaces. Mark ✓ full / ~ partial / ✗ none.

**S1 — "A user's last turn wasn't captured."**
- Surfaces: `memos.log`, `events.jsonl`, SSE `/api/v1/events`, viewer Memories/Logs.
- Can you find the capture attempt? Reason for drop (gate filter, dedup, policy, embed failure)?
- Is there a turn id / correlation id threading the pipeline?

**S2 — "Retrieval is returning nothing relevant."**
- Surfaces: `perf.jsonl`, `events.jsonl`, viewer Analytics.
- Can you see per-tier (L1/L2/L3/skill) candidate counts, RRF fusion scores, MMR pick order, final top-k?
- Per-query DEBUG toggle exists?

**S3 — "HTTP server is unresponsive."**
- `GET /api/v1/health` — shape, fields. Does it probe SQLite, embedder, LLM provider, disk space, port binding? Distinguish healthy / degraded / dead?
- When the server is actually dead, is there still evidence in `memos.log` of the last heartbeat or shutdown?

**S4 — "Crystallization produced a bad skill."**
- `llm.jsonl` must carry full prompt + response for the induction / abstraction / crystallization calls.
- `events.jsonl` must carry gate outcomes (eligibility, verifier, packager), per `core/skill/README.md`.
- Viewer Skills view shows Beta posterior η, trial count, probation status?

**S5 — "A user is locked out."**
- `audit.log`: bad password vs bad API key vs cookie expired vs brute-force lockout — distinguishable? Source IP? Timing attack mitigated (log shows constant-time compare)?

**S6 — "Disk is filling."**
- Which sink tells you? Is there a periodic disk-usage probe? WAL size tracked?
- Does the plugin self-throttle or just crash on ENOSPC?

**S7 — "An embedder call took 9s."**
- `perf.jsonl` has the timer with provider / model / batch size / payload size?
- `llm.jsonl` for embed calls (or is embed-only a different sink)?

**S8 — "A capture produced a duplicate memory."**
- Dedup decision visible (suppressed-as-dup vs passed-through) with the matching row id?
- Trace id threads capture → l1 write → index?

**S9 — "Reward backprop looks wrong."**
- Events for episode finalize, R_human scoring (3-axis breakdown), priority decay — all there?

**S10 — "Viewer lost its connection."**
- SSE `/api/v1/events` drop — does the server log the disconnect + reason? Client auto-reconnect observable? Back-pressure if client is slow — drop or buffer (bounded)?

### Redaction correctness

- Write a turn that contains: OpenAI-style key `sk-…`, `Bearer …` token, AWS `AKIA…`, private-key header, `password=…`, `authorization: …`, `.env`-style export, 16-digit card, email, SSN, JWT, IP address, RSA `-----BEGIN …-----` block.
- For each: does it appear raw in ANY sink (`memos.log`, `error.log`, `audit.log`, `llm.jsonl`, `perf.jsonl`, `events.jsonl`, `self-check.log`)? Redaction must apply **before** sink write per `core/logger/redact.ts`.
- Also check SSE stream output and viewer DOM — any sink that bypasses redaction.

### Viewer UX

For each view, assess what an operator can accomplish:

- **Overview** — key counts, recent activity, at-a-glance health?
- **Memories** — filter by level (L1/L2/L3), time, agent, visibility; see full row + embedding preview + trace links?
- **Policies / WorldModels** — edit / retire / pin?
- **Tasks** — episode timeline, R_human breakdown, priority decay visible?
- **Skills** — Beta posterior chart, probation → active → retired transitions, verifier output?
- **Analytics** — retrieval latency histograms, tier hit rates, LLM latency + cost?
- **Logs** — tail the sinks with channel filter + level filter + search? DEBUG toggle?
- **Admin** — trigger re-embed, vacuum, migration replay, shutdown?
- **Settings / Import** — config diff, import round-trip?

Trigger a user-visible error on each view; is the error surface helpful or swallowed?

### Metrics (Prometheus or equivalent)

- Does any endpoint expose scrape-able metrics? If not, could Prometheus be wired without forking?
- Counters (captures/s, searches/s, auth-fail/s), histograms (latency per endpoint + per tier), gauges (DB MB, WAL MB, RSS, open conn, SSE subscribers) — each present/missing.

### Audit trail

- Every mutation attributable? `who, when, method, before-hash, after-hash, correlation-id`?
- Append-only semantics — can the plugin detect truncation of `audit.log`? (Likely no.)

### Error-message quality

Trigger: invalid JSON, wrong auth, unknown JSON-RPC method, embed-provider down, dim-mismatch row, malformed SQL path. Score each error message on helpful vs cryptic vs misleading.

### Reporting

| Scenario | Logs | Events/SSE | Viewer | Health | Metrics | Audit | Score 1-10 |
|----|---|---|---|---|---|---|---|
| S1 missing capture | | | | | | | |
| S2 bad retrieval | | | | | | | |
| S3 server down | | | | | | | |
| S4 bad skill | | | | | | | |
| S5 auth lockout | | | | | | | |
| S6 disk fill | | | | | | | |
| S7 slow embed | | | | | | | |
| S8 dup capture | | | | | | | |
| S9 reward drift | | | | | | | |
| S10 SSE drop | | | | | | | |

| Surface | Score 1-10 | Gaps |
|----|---|---|
| Sink inventory completeness | | |
| Channel taxonomy | | |
| Redaction-before-sink | | |
| Correlation-id threading | | |
| Viewer Overview/Memories | | |
| Viewer Policies/WorldModels/Tasks | | |
| Viewer Skills/Analytics | | |
| Viewer Logs/Admin | | |
| Health endpoint depth | | |
| Metrics scrapeability | | |
| Audit trail completeness | | |
| Error-message quality | | |

**Overall observability score = MIN of above.**

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
2. Write your report to `tests/v2/reports/observability-v2-$(date +%Y-%m-%d).md`. Create the directory if it does not exist. The filename MUST use the audit name (matching this file's basename) so aggregation scripts can find it.
3. Commit and push:
   ```bash
   git add tests/v2/reports/<your-report>.md
   git commit -m "report(tests/v2.0): observability audit"
   git push origin tests/v2.0-audit-reports-2026-04-22
   ```
   If the push fails because another audit pushed first, `git pull --rebase` and push again. Do NOT force-push.
4. Do NOT open a PR. Do NOT merge to main. The branch is a staging area for aggregation.
5. Do NOT read other audit reports on the branch (under `tests/v2/reports/`). Your conclusions must be independent.
6. After pushing, close the session. Do not run a second audit in the same session.
