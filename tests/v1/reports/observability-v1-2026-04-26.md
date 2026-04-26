# MemOS v1 Observability Audit — 2026-04-26

**Audit marker:** V1-OBS-1777215880  
**Auditor:** Claude Sonnet 4.6 (blind, zero-knowledge)  
**System under test:** MemOS v1.0.1 server at `http://localhost:8001`  
**Source analyzed:** `/home/openclaw/Coding/MemOS/src/memos/`  
**Hermes plugin:** `@memtensor/memos-local-hermes-plugin` (hub at `127.0.0.1:18992`)

---

## Findings

### F-01: LLM Request Body Logged in Full — Includes Raw Memory Content

| Field | Value |
|---|---|
| **Class** | Secret/PII Exposure via Log Sink |
| **Severity** | CRITICAL |
| **Reproducer** | `POST /product/add` with content `"bearer sk-test-1234567890 and email user@example.com and phone 555-1234"` → inspect `/home/openclaw/Coding/MemOS/.memos/logs/memos.log` |
| **Evidence** | `memos.llms.openai - INFO - openai.py:83 - generate - OpenAI LLM Request body: {'model': 'deepseek-chat', 'messages': [{'role': 'user', 'content': '...bearer sk-test-1234567890 and email user@example.com and phone 555-1234...'}]...}` — full prompt body including the raw API token, email, and phone logged at INFO level to the persistent rotating log file. |
| **Remediation** | Truncate or redact message content in `openai.py:83` before logging; never log full LLM request bodies at INFO. |

---

### F-02: Trace ID Does Not Cross Subsystem Boundaries

| Field | Value |
|---|---|
| **Class** | Request Correlation Gap |
| **Severity** | HIGH |
| **Reproducer** | Submit `POST /product/add` with header `x-trace-id: v1obs-audit-trace-XXXX`. Grep `memos.log` for that trace ID. |
| **Evidence** | Trace ID `v1obs-audit-trace-1777215946` appears in **only 2 lines**: rate-limit middleware and product_models deprecation warning. It does not appear in Qdrant HTTP logs (separate Docker container, no trace header forwarded), Neo4j log, embedder log, or the `[SingleCubeView]` processing lines. The `neo4j_community add_nodes_batch:` lines in stdout carry no trace identifier at all. |
| **Remediation** | Propagate `x-trace-id` as an HTTP header to Qdrant and Neo4j client calls; add trace_id to all subsystem log lines in the add/search pipeline. |

---

### F-03: Health Endpoint Exposes Only Liveness — No Readiness or Depth

| Field | Value |
|---|---|
| **Class** | Health Endpoint Depth |
| **Severity** | HIGH |
| **Reproducer** | `GET /health` → `{"status":"healthy","service":"memos","version":"1.0.1"}`. Try `/info`, `/metrics`, `/api/v1/health` — all return 401. |
| **Evidence** | `/health` returns a static 3-field object. No Qdrant reachability, no Neo4j reachability, no SQLite existence check, no queue depth, no memory count. `/admin/health` returns `{"status":"ok","admin_key_configured":true,"auth_config_exists":true,"auth_config_path":"..."}` — still no subsystem pings. Both `/info` and `/api/v1/health` return 401 (auth-gated), making them useless for load-balancer or on-call probing without a key. |
| **Remediation** | Add a `/health/ready` endpoint that synchronously pings Qdrant, Neo4j, and SQLite; return 503 if any dependency is down. |

---

### F-04: No Prometheus Metrics Endpoint

| Field | Value |
|---|---|
| **Class** | Metrics / Instrumentation |
| **Severity** | HIGH |
| **Reproducer** | `GET /metrics` → `{"detail":"Authorization header required..."}` (401, not a Prometheus text format response). |
| **Evidence** | The OpenAPI spec lists no `/metrics` endpoint with Prometheus output. No `prometheus_client` import was found in any source file under `src/memos/`. The only operational counters visible are scheduler summary counts from `/product/scheduler/allstatus`, which are aggregate and in-memory only (reset on restart). |
| **Remediation** | Add `prometheus_client` and expose `GET /metrics` (unauthenticated, per Prometheus convention) with request counters, latency histograms, queue depth, error rates, and subsystem connection status. |

---

### F-05: Request Log File vs. Stdout Sink Split — File Misses Request Logs in Default Config

| Field | Value |
|---|---|
| **Class** | Log Sink Configuration |
| **Severity** | HIGH |
| **Reproducer** | Start server with default env. All actual request activity (trace IDs, path, status, latency) appears in stdout (`/tmp/memos-v1-di-audit.log` for this run). The file sink at `.memos/logs/memos.log` captures only startup initialization logs. |
| **Evidence** | `log.py` `LOGGING_CONFIG` defines a file handler at level `INFO` with `ConcurrentTimedRotatingFileHandler`. The console handler is set to `logging.WARNING` (non-DEBUG mode). However, the actual running server has stdout redirected to a temp file by the launch script — the `.memos/logs/memos.log` file exists but only contains module-init events, not any request trace entries. Operators cannot `tail -f memos.log` to watch live traffic. |
| **Remediation** | Ensure `RequestContextMiddleware` logger propagates to the file handler; validate this with a startup smoke test that writes a synthetic request and checks the file. |

---

### F-06: Docker Log Rotation Not Configured — Disk at 93% Capacity

| Field | Value |
|---|---|
| **Class** | Log Rotation + Disk |
| **Severity** | HIGH |
| **Reproducer** | `docker inspect qdrant --format='{{.HostConfig.LogConfig.Config}}'` → `map[]`. `df -h /` → 93% used (95 GB of 108 GB). |
| **Evidence** | No `/etc/docker/daemon.json` exists. Docker uses `json-file` driver with no `max-size` or `max-file` limits. Qdrant and Neo4j containers will grow their logs without bound. The MemOS file log uses `ConcurrentTimedRotatingFileHandler` with `backupCount=3` (midnight rotation, 3-day retention) — that is configured, but Docker container logs are not. |
| **Remediation** | Add `{"log-driver":"json-file","log-opts":{"max-size":"100m","max-file":"5"}}` to `/etc/docker/daemon.json` and recreate containers; alert when disk > 85%. |

---

### F-07: Server Crashes on New-User Cube Init When Qdrant Requires API Key

| Field | Value |
|---|---|
| **Class** | Crash / Restart Observability |
| **Severity** | HIGH |
| **Reproducer** | Create a new agent key via `POST /admin/keys` for a user_id that has no existing Qdrant collection. Issue `POST /product/add` using that key. |
| **Evidence** | Server raised `qdrant_client.http.exceptions.UnexpectedResponse: Unexpected Response: 401 (Unauthorized) — Must provide an API key or an Authorization bearer token` during `init_server()` (module-level code in `server_router.py:84`). The crash occurs at startup/import time when a new Neo4j cube tries to create its backing Qdrant collection without the Qdrant API key set in the running environment. The error is visible in the process's stderr but produces **no structured log entry** with a trace ID — the process just exits. |
| **Remediation** | Load `QDRANT_API_KEY` from secrets at startup and pass it through the `VecDBFactory`; add startup validation that aborts with a clear error rather than crashing mid-import. |

---

### F-08: No Debug Log-Level Toggle Without Code Change

| Field | Value |
|---|---|
| **Class** | Debug Toggles |
| **Severity** | MEDIUM |
| **Reproducer** | `grep -n "DEBUG" /home/openclaw/Coding/MemOS/src/memos/settings.py` → `DEBUG = False` (hardcoded). |
| **Evidence** | `settings.py` sets `DEBUG = False` as a module-level constant with no `os.getenv("DEBUG", "false")` lookup. Enabling debug logging requires editing the source file and restarting. The console handler switches from WARNING to DEBUG based on `settings.DEBUG`, but there is no runtime toggle (no `LOG_LEVEL` env var, no SIGHUP reload). |
| **Remediation** | Change `DEBUG = os.getenv("MEMOS_DEBUG", "false").lower() == "true"` in `settings.py`; add a `POST /admin/log-level` endpoint for runtime toggle. |

---

### F-09: Hermes Plugin Does Not Verify Write Success

| Field | Value |
|---|---|
| **Class** | Hermes Plugin Observability |
| **Severity** | MEDIUM |
| **Reproducer** | Inspect `~/.hermes/memos-state-research-agent/logs/bridge-daemon.log` after a write via the plugin. |
| **Evidence** | Bridge daemon logs only initialization: `[info] Plugin ready.`, `[info] Bridge daemon listening on 127.0.0.1:18990`. No per-write confirmation, no error entries on bridge timeout. Hub sync log (`hub-sync.log`) reports `"0 new traces since ts=..."` on each tick — no way to confirm a specific write landed. The only write verification available is `GET /product/get_memory_dashboard` against the API, which is not called automatically by the plugin. One prior entry shows `MemOS: bridge init failed — [timeout] session.open did not respond within 30.0s` in `~/.hermes/logs/errors.log` — a timeout that produced no alert. |
| **Remediation** | Add a post-write confirmation log line in the bridge client; expose a `memos_verify_write(memory_id)` tool so agents can confirm storage. |

---

### F-10: Auth Failure Logging Lacks Rate-Limit State Visibility

| Field | Value |
|---|---|
| **Class** | Auth / Security Observability |
| **Severity** | LOW |
| **Reproducer** | Submit 10 bad keys; the 11th returns `{"detail":"Too many failed authentication attempts. Try again later."}` with HTTP 429. Grep logs for this event. |
| **Evidence** | Auth failures generate no log line at WARNING or ERROR level from `AgentAuthMiddleware` (only the `request_context` middleware logs the 429 status code). There is no log entry identifying the IP address that was rate-limited, making it impossible to distinguish a brute-force attack from a misconfigured client after the fact. |
| **Remediation** | Add `logger.warning(f"[AgentAuth] Rate-limited IP {client_ip}: {len(failures)} failures in {window}s")` on rate-limit trigger. |

---

## Per-Scenario Diagnostic Walk-Through

### Scenario 1: "A memory I just stored isn't searchable"

**CAN do:** Call `GET /product/get_memory_dashboard` with user_id and cube_id — returns all stored memories with metadata, `vector_sync: "success"` flag, and `created_at`. Can confirm the memory exists in the DB.  
**CANNOT do:** Correlate the write request (by trace ID) through to Qdrant and Neo4j insert confirmations. Cannot distinguish "memory not extracted by LLM" (extraction failure) from "stored but not indexed in Qdrant" from "wrong cube_id." The scheduler task status shows counts (waiting/completed/failed) but no per-memory linkage.

### Scenario 2: "Search is slow today"

**CAN do:** Inspect request log lines with `cost:` latency values (`path=/product/search ... cost: 5115.51ms`).  
**CANNOT do:** Break down latency by sub-system. There is no per-stage timing: embedding time, Qdrant query time, Neo4j graph time, reranker time, LLM re-ranking time. Total wall time is logged, but the breakdown is invisible.

### Scenario 3: "Auth keeps failing for one agent"

**CAN do:** See HTTP 401/403 in uvicorn access log and `request_context` ERROR lines with trace ID and path.  
**CANNOT do:** Know which specific agent key is failing (key prefix not logged on auth failures — only on successful auth at DEBUG level), or how many failures have accumulated against that IP. The rate-limit bucket state is in-memory only and resets on restart.

### Scenario 4: "Disk is filling up"

**CAN do:** `df -h /` shows 93% usage already. `ls -lh .memos/logs/` shows the rotating log at 2.5 MB (bounded by 3-day rotation).  
**CANNOT do:** Identify which Docker container's log is the culprit — no `daemon.json` enforces size limits. No alert fires at 85% or 95%. The operator must manually `docker system df` or `du` to find the source.

### Scenario 5: "MemOS keeps restarting"

**CAN do:** `journalctl --user -u memos-hub` would show systemd restarts for the hub (the v2 plugin service). For the v1 API server, crash output goes to the stdout/stderr file (e.g., `/tmp/memos-v1-di-audit.log`).  
**CANNOT do:** See the crash reason in any persistent, structured log. Crashes produce plain Python tracebacks in stderr, not structured JSON. There is no watchdog alert, no restart counter endpoint, and no way to query restart history via the API.

### Scenario 6: "An LLM extraction returned garbage"

**CAN do:** The full LLM request body (including the prompt sent to DeepSeek) is logged at INFO to `memos.log` (see F-01). The response is NOT logged.  
**CANNOT do:** See the LLM response, compare input vs. extracted memory, check token usage, or replay the extraction. No extraction quality metrics are emitted.

### Scenario 7: "A duplicate slipped through dedup"

**CAN do:** `GET /product/get_memory_dashboard` shows all stored memories with metadata and `history` array (evolution chain). Can manually inspect for near-duplicates.  
**CANNOT do:** Query "what dedup decision was made for this write." There is no log entry recording dedup algorithm decisions (MMR threshold, similarity score) per write. No dedup audit trail.

---

## Summary Table

| Area | Score 1–10 | Key Findings |
|------|-----------|--------------|
| Log sinks + content quality | 3 | File sink misses request logs in default config; stdout-only for live traffic; no structured JSON |
| Health endpoint depth | 2 | `/health` is liveness-only (3 fields); no subsystem ping; `/info` and `/api/v1/health` auth-gated |
| Metrics endpoint (Prometheus or equiv) | 1 | No Prometheus endpoint; `/metrics` returns 401; only scheduler summary counters (in-memory, reset on restart) |
| Request correlation IDs | 4 | Trace ID injected at middleware layer and flows through API-layer logs; does NOT cross to Qdrant/Neo4j/embedder subsystems |
| Secret redaction across all sinks | 1 | Full LLM prompt body logged at INFO including raw bearer tokens, emails, phones — no redaction at any layer |
| Log rotation + retention | 4 | File log: `ConcurrentTimedRotatingFileHandler` midnight/3-day (configured). Docker logs: no `max-size`, no `daemon.json` — unbounded growth |
| Debug toggles | 2 | `DEBUG = False` hardcoded; no `MEMOS_DEBUG` env var; no runtime log-level endpoint; requires source edit + restart |
| Hermes plugin observability | 3 | Bridge logs init only; no per-write confirmation; hub-sync shows trace counts but no storage verification; bridge timeout produced no alert |
| Per-incident diagnostic capability | 2 | Cannot break down latency by subsystem; cannot trace a write end-to-end; crash logs are ephemeral non-structured text |

### Overall Observability Score: **MIN = 1 / 10**

The minimum is set by both the metrics endpoint (1) and secret redaction (1). The metrics gap alone makes proactive detection of most production incidents impossible. The secret/PII exposure means the log archive itself becomes a liability under data-protection requirements.

---

## Closing Assessment

At 3 a.m. with one live incident, the on-call operator faces the following concrete obstacles:

1. **No metrics** — there is no Prometheus scrape target, no counter for request errors, no latency histogram, no queue depth gauge. The operator has no dashboard to look at. They must `tail` a log file to observe anything.

2. **Logs split across ephemeral stdout** — the actual request trace log lives wherever the process's stdout was redirected at launch (e.g., `/tmp/memos-v1-di-audit.log`). On a fresh restart the file path changes. The file sink at `.memos/logs/memos.log` captures startup noise but not request traffic in default configuration.

3. **Trace ID stops at the API layer** — even if the operator finds the correct log file and isolates a trace ID, they cannot follow it into Qdrant or Neo4j. A slow-search incident requires manually correlating wall-clock timestamps across three separate log systems.

4. **Health check lies** — `GET /health` returns `"status":"healthy"` even when Qdrant is returning 401 (as demonstrated by the crash scenario). A load balancer or uptime monitor will report green while writes are silently failing.

5. **No debug toggle** — to increase verbosity, the operator must edit `settings.py` and restart, which interrupts the live service further.

The system has the structural scaffolding for good observability (trace_id injection, rotating file handler, middleware latency logging) but the wiring is incomplete and the critical gaps — metrics, secret redaction, subsystem correlation — leave the operator effectively blind for the most common failure modes.

**Verdict:** Not production-ready for on-call operations without a Prometheus exporter, a working readiness probe, and log-content redaction for LLM request bodies.
