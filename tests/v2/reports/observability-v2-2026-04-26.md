# Hermes v2 Observability Blind Audit — 2026-04-26

**System under test:** `@memtensor/memos-local-hermes-plugin`
**Hub:** `http://localhost:18992` (research-agent profile, PID 331114, uptime ~23h at audit time)
**Bridge/Viewer:** `http://localhost:18901` — **connection refused** (daemon not running)
**Auditor role:** SRE who has never seen this system

---

## Environment snapshot

```
Hub process:   PID 331114, hub-launcher.cts via tsx, Node v22.22.1
Hub uptime:    ~83,100 s at start of audit
DB path:       ~/.hermes/memos-state-research-agent/memos-local/memos.db
DB size:       24.1 MB  (6163 pages × 4096 bytes)
WAL size:      1.26 MB
Integrity:     OK (PRAGMA integrity_check passed)
perf-audit:    separate profile — only daemon.log (456 B), plugin FATAL at startup
               (better-sqlite3 compiled for NODE_MODULE_VERSION 127, runtime needs 141)
```

---

## Surface-by-surface findings

### 1. Hub logs (`~/.hermes/memos-state-research-agent/logs/hub.log`)

**Format:** Mixed — plain-text `[level] message` lines interleaved with one raw JSON startup line:
```
[debug] Database schema initialized
[info] memos-local: bootstrap admin token persisted to ...
[info] hub-launcher: hub up at http://127.0.0.1:18992
{"hubUrl":"http://127.0.0.1:18992","hubPort":18992,"teamName":"ceo-team","pid":331114}
[info] Hub: user "ceo" (...) went offline
[info] hub: embedded shared memory <uuid>
```

**What is logged:**
- DB schema init, admin token bootstrap, hub bind address+PID
- User online/offline transitions
- Embedding completions (`hub: embedded shared memory <uuid>`)
- Embedding failures (`hub: embedding shared chunks failed: <err>`)

**What is NOT logged:**
- Individual HTTP requests (no access log)
- Authentication failures — `authenticate()` silently returns `null`; no log line is emitted on a bad/expired/missing token
- Rate-limit rejections — no log on 429
- Capture pipeline events (trivial-skip, dedup decision, summarize failure)
- Request/correlation IDs — none exist anywhere in the pipeline
- Search queries

**Log levels available:** `[debug]`, `[info]`, `[warn]`, `[error]`, `[fatal]`
**How to enable DEBUG:** Not documented. Source uses `ctx.log.debug(...)` calls; enabling requires knowing the undocumented config flag.
**Rotation:** None observed. Both log files are flat, unbounded files. No `.1`, `.gz`, or rotation sentinel found.
**Access log vs application log:** Single merged file. No HTTP access log separate from application events.

---

### 2. Client-side / bridge logs (`~/.hermes/memos-state-research-agent/logs/bridge-daemon.log`)

473 bytes, last modified 2026-04-20. Captures only bridge daemon startup:
```
[info] Initializing memos-local plugin...
[debug] Database schema initialized
[info] Plugin ready. DB: /home/openclaw/.openharness/memos-state/memos-local/memos.db, Embedding: local
[info] Bridge: plugin initialized (daemon mode)
[debug] Telemetry disabled (opt-out)
[debug] Database schema initialized
[info] Viewer started at http://127.0.0.1:18901
[info] Bridge daemon listening on 127.0.0.1:18990
{"daemonPort":18990,"viewerUrl":"http://127.0.0.1:18901","pid":1042775}
```

**Critical discrepancy:** The bridge daemon log points to `/home/openclaw/.openharness/memos-state/` (different path from `~/.hermes/memos-state-research-agent/`). The bridge daemon process is dead; the viewer at port 18901 is unreachable.

**Per-request capture traces:** NOT in log files. The ingest worker logs individual message outcomes to `ctx.log.debug(...)` (trivial skip), `ctx.log.error(...)` (ingest error), and batches to the `api_logs` SQLite table (not a log file). An operator watching log files sees nothing about whether a specific message landed.

---

### 3. SQLite audit trail (`memos.db`)

The most useful observability surface — but requires direct DB access, not a log file or API.

**`api_logs` table** (`id, tool_name, input_data, output_data, duration_ms, success, called_at`):
- `memory_add` rows record session key, message count, per-message roles/content, and outcome stats:
  ```
  input:  {"session":"preload-w3","messages":2,"details":[{"role":"user","content":"..."}]}
  output: "stored=2400\n{role, action, summary, content per line}"
  ```
- `memory_search` rows record query and full candidate list with scores.
- Coverage: batch-level (not per-message row).

**`chunks` table** — dedup is fully traceable:
- `dedup_status`: `active` | `duplicate` (2913 active, 246 duplicate in this DB)
- `dedup_target`: UUID of the original chunk this was deduplicated against
- `dedup_reason`: human-readable, e.g. `"exact content hash match"`
- `content_hash`: SHA-256 truncated — allows deterministic re-checking
- `session_key`, `owner`, `turn_id` — enough to attribute any chunk to a session + agent

**`skill_versions` table** (`id, skill_id, version, content, changelog, upgrade_type, quality_score, change_summary, metrics, created_at`):
- Stores the final SKILL.md content per version
- `quality_score` field exists; empty in all sampled rows (never populated)
- **LLM input/output NOT stored** — the prompt sent to the summarizer/evolver and its raw response are not persisted anywhere

**`tool_calls` table** (`tool_name, duration_ms, success, called_at`):
- Aggregate per-call performance tracking (not per-request)

**Attribution:** Every chunk has `session_key` + `owner`. Can answer "who wrote memory X at time T". Append-only rows; no mutation log for post-write edits.

---

### 4. Health endpoint (`GET /api/v1/hub/health`)

**Authentication:** None required (public). Loopback-only binding limits exposure.

**Response (healthy):**
```json
{
  "status": "healthy",
  "teamName": "ceo-team",
  "hubInstanceId": "88217e93-...",
  "uptimeSec": 83122,
  "nodeVersion": "v22.22.1",
  "db": {
    "journalMode": "wal",
    "pageSize": 4096,
    "pageCount": 6163,
    "dbSizeBytes": 25243648,
    "walSizeBytes": 1297832,
    "walPages": 317,
    "integrityOk": true
  },
  "issues": [],
  "ts": 1777209827069
}
```

**What it checks:**
- SQLite `PRAGMA integrity_check` → sets `integrityOk`
- WAL size > 256 MB → `status: "degraded"`, `issues: ["wal > 256MB"]`
- HTTP 503 when degraded, 200 when healthy

**What it does NOT check:**
- Embedder availability (no probe of the local model)
- Available disk space (reports DB/WAL bytes but no free-space check)
- Process memory / RSS
- Ingest queue depth
- Bridge daemon liveness or viewer availability

**State vocabulary:** Only `"healthy"` | `"degraded"`. No `"starting"`, `"shutting_down"`, or `"unhealthy"` states.

**`/api/v1/hub/info`** (separate, also public):
```json
{"teamName":"ceo-team","version":"0.0.0","apiVersion":"v1","hubInstanceId":"..."}
```
Returns software version (always `"0.0.0"` — not semver-stamped), API version, and instance ID.

---

### 5. Metrics endpoint

- `GET /metrics` (unauthenticated) → `{"error":"unauthorized"}`
- `GET /metrics` (with valid Bearer token) → `{"error":"not_found"}`
- No Prometheus-compatible endpoint exists anywhere in the route table.
- `GET /api/v1/hub/metrics` → `{"error":"not_found"}`

**In-DB counters (not exposed via HTTP):**
- `tool_calls`: call count + duration per tool name — readable only via direct SQL
- `api_logs`: full ingest trace — readable only via direct SQL

**To feed Prometheus/Alertmanager:** Would require a custom exporter that polls the health endpoint and/or queries SQLite directly. Cannot integrate without wrapping.

---

### 6. Viewer dashboard (port 18901)

**Status:** Connection refused. Bridge daemon is not running. The viewer_events table in SQLite is empty (no rows). Cannot assess the viewer UX at all.

**What the viewer is supposed to provide** (from source scan of `src/viewer/server.ts`): recent captures, search UI, memory metadata inspection, migration progress, skill management, hub status. None of this is accessible to an SRE during this audit.

---

### 7. Error message quality

| Trigger | HTTP | Response | Quality |
|---------|------|----------|---------|
| Invalid JSON body (`not-json`) | 500 | `{"error":"internal_error"}` | **Cryptic** — doesn't say "invalid JSON", exposes nothing useful |
| Bad/missing Bearer token | 401 | `{"error":"unauthorized"}` | Acceptable for security, but indistinguishable from expired/wrong/revoked |
| Missing required field (`sourceChunkId`) | 400 | `{"error":"missing_source_chunk_id"}` | **Good** — field-level specificity |
| Unknown route | 404 | `{"error":"not_found"}` | Neutral |
| Body too large (>10 MB) | 413 | `{"error":"request_body_too_large"}` | Good |
| Rate limit exceeded | 429 | `{"error":"rate_limit_exceeded","retryAfterMs":60000}` | Good — includes retry guidance |

Auth errors deliberately collapse to a single code (prevents oracle attacks), but this makes lockout diagnosis impossible from the API alone. An operator cannot distinguish "bad token" from "token valid but user blocked" from "user not found" from "token hash mismatch" — all return identical 401.

---

## Diagnostic scenario matrix

| Scenario | Logs | Dashboard | Health | Metrics | Audit (DB) | Score |
|----------|------|-----------|--------|---------|------------|-------|
| Missing capture | ~ | ✗ | ✗ | ✗ | ~ | **4** |
| Bad search | ✗ | ✗ | ✗ | ✗ | ~ | **3** |
| Hub down | ~ | ✗ | ✓ | ✗ | ✗ | **6** |
| Bad skill | ✗ | ✗ | ✗ | ✗ | ~ | **3** |
| Auth lockout | ✗ | ✗ | ✗ | ✗ | ✗ | **2** |
| Disk fill | ✗ | ✗ | ~ | ✗ | ~ | **4** |
| Dup capture | ✗ | ✗ | ✗ | ✗ | ✓ | **7** |

Legend: ✓ fully answered from this surface alone · ~ partially answered · ✗ not answered

### Scenario notes

**Missing capture:** `api_logs` records batch outcomes with session key and per-message actions. But there is no request ID tying a specific client call to a server-side log line in real time. If the message was filtered as trivial content (`isTrivialContent()`) or as an ephemeral session, the rejection only reaches a `log.debug()` line — never persisted unless DEBUG log level is active. No way to answer "what happened to message X at 14:32:01" purely from log files.

**Bad search:** The hub computes FTS5 ranks, vector cosine scores, and RRF fusion internally, but exposes none of this breakdown in the search response (`meta` only contains `totalCandidates`, `searchedGroups`, `includedPublic`). No debug-level per-query log. `api_logs` records full candidates for `memory_search` tool calls but not for raw hub `/api/v1/hub/search` calls. Had to read source to understand the MIN_VECTOR_SIM=0.45 threshold and K=60 RRF constant — both diagnostically important, nowhere documented or logged.

**Hub down:** Health endpoint is the strong point. Public, returns structured JSON, reports WAL size and integrity. Combined with `hub.pid`, an operator can script: check PID exists → call health → parse status. Gap: embedder failure would not be reported here.

**Bad skill:** `skill_versions` table records final content, changelog, and change_summary. Quality score field exists but is always null in practice. The LLM prompt sent to the evolver and the raw LLM response are not stored anywhere — an operator cannot audit *why* a skill was accepted or what the model produced before post-processing.

**Auth lockout:** Worst scenario. `authenticate()` returns `null` on any failure without logging. The hub has no auth event log. Rate limiting only applies to authenticated endpoints (per userId), not to the auth flow itself. An operator cannot answer: Was this a bad token? Expired token? User blocked? User not found? Token hash mismatch? All are silent 401s.

**Disk fill:** Health endpoint reports raw DB and WAL bytes. The WAL threshold (256 MB) is the only proactive warning. No per-growth-rate tracking, no free-space check, no operator notification before the threshold is hit. Had to read source to find the 256 MB constant.

**Dup capture:** Strongest scenario. Every deduplicated chunk records `dedup_status=duplicate`, `dedup_target=<original_uuid>`, and `dedup_reason="exact content hash match"`. Decision is deterministic (SHA-256 content hash within same owner), traceable, and queryable. `api_logs` also reports `dedup=N` counts per batch. Gap: requires direct DB access; no API endpoint to query dedup history.

---

## Per-surface scores

| Surface | Score 1-10 | Key gaps |
|---------|-----------|---------|
| Client logs | **3** | No per-request trace; trivial-skip decisions only at DEBUG; no rotation |
| Hub logs | **3** | No auth event logging; no HTTP access log; no request IDs; no capture events |
| Viewer UX | **1** | Not running (bridge daemon dead, port 18901 refused) |
| Health endpoints | **6** | Good structure; missing embedder probe and free-disk check |
| Metrics | **1** | No HTTP metrics endpoint; in-DB only; not Prometheus-compatible |
| Audit trail (DB) | **7** | Dedup fully traceable; attribution present; skill LLM I/O absent |
| Error messages | **5** | Auth errors correctly opaque but diagnostically useless; invalid JSON returns 500 internal_error |

**Overall observability score = MIN of above = 1**

(Viewer is down; no metrics endpoint. MIN-aggregation correctly surfaces these as blockers.)

---

## Critical findings (score < 5)

### BLOCKER-1: No auth event logging (Score: 2)
Auth failures are completely silent. `authenticate()` returns `null` with zero log output. An operator investigating a lockout has no telemetry surface to work with. Fix: log auth failures at WARN with failure category (bad signature, expired, user not found, user blocked, token hash mismatch) — without exposing the token itself.

### BLOCKER-2: No metrics endpoint (Score: 1)
No Prometheus-compatible `/metrics` route exists. Counters and histograms are buried in SQLite (`tool_calls`, `api_logs`). Cannot integrate with any standard monitoring stack (Prometheus, Grafana, Alertmanager, Datadog) without a custom exporter. Fix: expose `/metrics` with at minimum: captures_total, searches_total, auth_failures_total, db_size_bytes, wal_size_bytes, uptime_seconds.

### BLOCKER-3: Viewer dashboard not running (Score: 1)
Port 18901 connection refused. Bridge daemon last ran under a different state path (`/home/openclaw/.openharness/` vs `~/.hermes/`). `viewer_events` table is empty. The dashboard — intended as the primary operator UI — is completely inaccessible.

### BLOCKER-4: Invalid JSON returns 500 internal_error (Score: 5 → error quality)
A malformed JSON body causes an unhandled `JSON.parse()` throw inside `readJson()`, which propagates as a generic 500. It should be caught and returned as 400 with `{"error":"invalid_json"}`. Currently misleads operators into thinking the server has a bug.

### BLOCKER-5: No request/correlation IDs (Score: across scenarios)
No request ID is assigned at ingestion or at the HTTP layer. There is no way to correlate a client-side capture attempt with a specific server-side log line or DB row in real time. Session key is the closest proxy, but it spans many turns.

---

## Medium findings (5–7)

### MED-1: Health endpoint missing embedder probe
`/api/v1/hub/health` does not verify the local embedding model is loadable. If Xenova fails silently after startup (OOM, model file corrupt), the endpoint reports `healthy` while all future embedding operations fail. Fix: add an embedder liveness probe (e.g., embed a 1-word string and verify the vector is non-zero).

### MED-2: No log rotation
Both `hub.log` and `bridge-daemon.log` are flat unbounded files. On a long-running deployment these will grow without limit. Fix: add size-based rotation (e.g., 10 MB rotate, keep 3 files) or integrate with `logrotate`.

### MED-3: DEBUG level not documented or configurable at runtime
Skipped-capture decisions (trivial content, ephemeral session) go to `log.debug()`. There is no documented config flag to enable DEBUG and no runtime toggle. An operator debugging a missing-capture incident cannot see these decisions without code changes. Fix: document `LOG_LEVEL=debug` (or equivalent config key) in README.

### MED-4: Skill evolution — LLM I/O not persisted
`skill_versions` records the final output but not the LLM input/output. Diagnosing why a nonsense skill was accepted requires inspecting the skill content and changelog only. Fix: store the evolver prompt + raw LLM response in a `skill_evolution_trace` table, retained for 30 days.

### MED-5: `version: "0.0.0"` in hub info
`/api/v1/hub/info` always returns `"version":"0.0.0"`. This makes it impossible to confirm which release is deployed. Fix: stamp version from `package.json` at build time.

---

## Strong areas (8–10)

### STRONG-1: Dedup audit trail (8/10)
Every deduplicated chunk has `dedup_status`, `dedup_target` (UUID of original), and `dedup_reason` (human-readable). Decision is deterministic and fully reproducible via `content_hash`. The `api_logs` table also records batch-level `dedup=N` stats. This is the most complete observability surface in the system.

### STRONG-2: Health endpoint structure (6/10 overall, good design)
`/api/v1/hub/health` returns a rich, structured JSON payload including DB integrity, WAL metrics, uptime, Node version, and an `issues[]` array for degraded-state explanations. Public + loopback-only is the right security model. The 503 status code on degradation enables load-balancer health checks. Good foundation — needs embedder and disk probes added.

### STRONG-3: api_logs ingest trace
The `api_logs` SQLite table provides session-level capture traces with per-message action breakdowns (`stored`, `dedup`, `merged`, `error`). This is genuinely useful for post-hoc investigation if the operator knows to query it directly.

---

## Ship recommendation

**Do not ship** for production operator use at current observability posture.

The minimum-score surfaces (viewer down, no metrics) are not edge cases — they are the primary operator interfaces. An SRE on-call for this system has: no real-time metrics, no dashboard, no auth event log, and no correlation IDs. Diagnosing any incident beyond "is the hub process alive?" requires direct SQLite access and source reading.

**Minimum bar before ship:**
1. Fix viewer/bridge daemon registration so port 18901 starts reliably
2. Log auth failures (WARN, with failure category, no token)
3. Expose `/metrics` with 6–8 key counters (captures, searches, auth_failures, db_size, wal_size, uptime)
4. Add embedder probe to health endpoint
5. Return 400 for invalid JSON, not 500

With items 1–5 addressed, re-score is likely 5–6 (ship-with-caveats). Full 8+ requires request IDs and log rotation.
