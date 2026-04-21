# Hermes v2 Observability Blind Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

Local memory plugin `@memtensor/memos-local-hermes-plugin`. Hub on `http://localhost:18992`. Viewer dashboard on `http://localhost:18901`. Logs under `~/.hermes/memos-state-<profile>/logs/`. Plugin source `~/.hermes/memos-plugin-<profile>/`.

Your job: **Evaluate whether an operator can diagnose why a memory didn't land, why search is slow, or why the hub is unhealthy — using logs, dashboard, metrics, and health endpoints alone.** Score observability 1-10.

Approach: play the role of an SRE who has never seen this system. Try to answer each diagnostic question below using only the system's own telemetry surfaces. Note where you had to grep source to understand something — that's a gap.

### Diagnostic scenarios

**"A user says their last message didn't get captured."**
- Can you find the specific capture attempt in the logs? What identifier ties a client request to a server-side log line?
- If it was rejected, does the log say why (validation, auth, rate-limit, disk, DB lock)?
- Is there a correlation ID or request ID? If not, how do you follow one request through the pipeline?

**"Search is returning nothing relevant."**
- Can you see the query at the hub? The scoring breakdown (FTS5 vs vector vs RRF)? The top-k candidates considered?
- Is there a debug-level log you can enable per-query?

**"The hub is unresponsive."**
- Is there a health endpoint? What does it verify — just process-alive, or also SQLite access, embedder availability, disk space?
- Does the health endpoint distinguish "degraded" from "dead"?

**"Skill evolution produced a nonsense skill."**
- Can you find the LLM input + output for that generation? Or just the final SKILL.md?
- Is there a "why was this accepted" trace (quality filter score, similarity check)?

**"A user was locked out of the hub."**
- Are auth failures logged with enough detail to distinguish: bad token, revoked key, expired token, unknown user?
- Is there rate-limiting on auth, and is that logged?

**"Disk is filling up fast."**
- Is there a metric for DB size growth? Log volume growth? WAL size?
- Does the plugin warn when approaching a disk threshold?

**"A capture was duplicated."**
- Can you see the dedup decision (suppressed as duplicate / passed through)?
- Is the decision deterministic and traceable?

### Surfaces to probe

**Client-side logs:**
- Where are they written (`~/.hermes/memos-state-<profile>/logs/`)?
- What log levels exist? How do you enable DEBUG?
- Log format: plain text, JSON, structured? Rotation?

**Hub-side logs:**
- Same questions.
- Access log vs application log — both present?

**Viewer dashboard (port 18901):**
- Can you see recent captures? Filter by agent, time, content?
- Can you inspect a single memory's full metadata (embedding, chunks, task association)?
- Can you run a query from the UI and see the scoring?
- Are errors surfaced in the UI (e.g. recent 5xx)?
- Can an operator trigger a re-embed, delete, or pair a new client from the UI?

**Health endpoint:**
- `GET /api/v1/hub/info` — returns what? Versions? Counts? Last heartbeat?
- Any `/metrics` endpoint (Prometheus-style)?

**Metrics:**
- Counters: captures / sec, searches / sec, auth-fail / sec?
- Histograms: latency by endpoint?
- Gauges: DB size, WAL size, RSS, open connections?

**Audit trail:**
- Can you answer: "who wrote memory X at time T"? Every mutation attributable?
- Mutable history vs append-only log?

**Error messages quality:**
- Trigger specific errors: invalid JSON, wrong auth, write to non-existent group. Error message → helpful / cryptic / misleading? Score each.

**Alert-ability:**
- Could this system feed Prometheus + Alertmanager without wrapping? Or do you need a custom exporter?

### Reporting

Fill this table for each scenario (rows) against each surface (columns) — did the surface alone suffice to diagnose?

| Scenario | Logs | Dashboard | Health | Metrics | Audit | Score 1-10 |
|----------|------|-----------|--------|---------|-------|-----------|
| Missing capture | | | | | | |
| Bad search | | | | | | |
| Hub down | | | | | | |
| Bad skill | | | | | | |
| Auth lockout | | | | | | |
| Disk fill | | | | | | |
| Dup capture | | | | | | |

For each cell: ✓ (fully answered), ~ (partial), ✗ (not answered from this surface).

Additional per-surface assessment:

| Surface | Score 1-10 | Gaps |
|---------|-----------|------|
| Client logs | | |
| Hub logs | | |
| Viewer UX | | |
| Health endpoints | | |
| Metrics | | |
| Audit trail | | |
| Error messages | | |

**Overall observability score = MIN of above.**

### Out of bounds

Do not read `/tmp/`, `CLAUDE.md`, other audit reports, plan files, or existing test scripts.
