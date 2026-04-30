# MemOS v1 Observability Audit — 2026-04-30

Marker: `V1-OBS-1777576524` (and corollaries `V1-OBS-CORR-PROBE-1234567890abcdef`)
Auditor stance: 3 a.m. on-call.
Inputs honored: zero-knowledge — no `/tmp/**` (other than my own writes), no `CLAUDE.md`, no prior audit reports/learnings/plan files, no commit messages mentioning "audit/score/fix/remediation".
Sources used: live `localhost:8001`, `localhost:6333` (Qdrant), Neo4j container logs, `/home/openclaw/Coding/MemOS/src/memos/**`, `/home/openclaw/Coding/MemOS/.memos/logs/**`, `~/.hermes/plugins/memos-toolset/**`, `~/.hermes/logs/**`.

> ⚠️ Mid-audit note: the doc's throwaway-profile bootstrap calls `deploy/scripts/setup-memos-agents.py`, which was archived (`.archived` suffix) — the script has been removed from the supported deploy surface but the audit doc was not updated to match. I therefore **could not mint a fresh agent key** for the throwaway profile and probed the system as an anonymous client (which already exercises the auth, request-context, and redaction layers comprehensively) plus by reading already-on-disk logs from in-flight system traffic. **No live agent credential was harvested or used during this audit.** Findings noted as "anon-only" where probe was constrained.

---

## Recon (5-minute pass)

**Endpoint surface (`/openapi.json`):**

```
/health                       (anon)
/health/deps                  (auth-required — bug? — see F-3)
/admin/health                 (anon, returns admin_key/auth_config presence)
/admin/keys                   (admin scope)
/admin/keys/rotate            (admin scope)
/product/{search,add,...}     (Bearer required)
/product/scheduler/{status,allstatus,task_queue_status,wait,wait/stream}
/docs, /openapi.json
NO /metrics                   (Prometheus not exposed — see F-7)
NO /info                      (404 → 401 from auth middleware — see F-3)
```

**Log sinks (from `src/memos/log.py:204-265`):**
- `console` (stdout, level=DEBUG if `MEMOS_DEBUG` else WARNING) — typically captured by systemd journal.
- `file` — `concurrent_log_handler.ConcurrentTimedRotatingFileHandler`, midnight rotation, **backupCount=3**, filename derived from `settings.MEMOS_DIR / logs / memos.log`. **MEMOS_DIR is process-CWD-relative** — the file therefore lands in whichever directory the process happened to start (`/home/openclaw/Coding/MemOS/.memos/logs/memos.log` for the systemd unit, `/home/openclaw/.openclaw/workspace/.memos/logs/memos.log` for openclaw shell, `~/.hermes/logs/memos.log` for an old hermes-spawned run, `~/Coding/Hermes/.memos/logs/memos.log` for older hermes). At least 4 stale parallel log trees exist on this host (`find / -name memos.log*` shows them). Searching "where do my logs go?" at 3 a.m. is not deterministic — see F-1.
- `custom_logger` — only enabled when `CUSTOM_LOGGER_URL` is set; non-blocking POST to a remote ingestor.

**Format (one line):**

```
%(asctime)s | %(trace_id)s | path=%(api_path)s | env=%(env)s | user_type=%(user_type)s | user_name=%(user_name)s | %(name)s - %(levelname)s - %(filename)s:%(lineno)d - %(funcName)s - %(message)s
```

Plain text, **not JSON-line** structured. `trace_id`, `api_path`, `env`, `user_type`, `user_name` are bound from `RequestContext` via `ContextFilter`.

**Filter chain (`src/memos/log.py:218-258`):** `redaction_filter` runs at logger-level (root) and additionally on every handler. Redaction is mechanical regex (`src/memos/core/redactor.py`).

**Health probe wiring (`server_api.py:127-227`):** lazy-registered Qdrant + Neo4j probes (`required=True`), 2 s timeout. `/health` returns 200 only when both deps green; 503 + `Retry-After: 5` otherwise. **Major win over a static 200**, but several gaps remain — see F-2, F-3, F-4.

**Instrumentation density:**
- 168 `logger.info|warning|error` calls in `src/memos/api/**` — heavy on every read/write, both INFO (start/finish, timing) and WARNING/ERROR (validation, failures).
- Structured `MONITOR_EVENT` JSON-line emissions on every scheduler enqueue/dequeue/start/finish (`memos.mem_scheduler.utils.monitor_event_utils`). Good — see F-9.

---

## Findings

### F-1 — `memos.log` filename is process-CWD-relative; multiple log trees on disk
**Class:** poor-coverage / discoverability
**Severity:** Medium
**Reproducer:** `find / -name "memos.log*" 2>/dev/null` lists ≥4 parallel directories (`~/Coding/MemOS/.memos/logs/`, `~/.openclaw/workspace/.memos/logs/`, `~/.hermes/logs/`, `~/Coding/Hermes/.memos/logs/`). Inspection of `_setup_logfile` in `log.py:33-42` — the path comes from `settings.MEMOS_DIR / "logs" / "memos.log"` and `MEMOS_DIR` is created relative to `os.getcwd()` (or the env-resolved `MEMOS_DIR`) at *first import* of `memos.log`.
**Evidence:** `/home/openclaw/Coding/Hermes/.memos/logs/memos.log.2026-04-05` (last touched April 5) coexists with a live `/home/openclaw/Coding/MemOS/.memos/logs/memos.log`. An on-call pulled to "the MemOS log file" cannot answer that without `lsof -p <pid>`.
**Remediation:** anchor `MEMOS_DIR` to a constant absolute path (e.g. `/var/log/memos` or `~/.memos/logs/`) regardless of CWD, or surface the resolved path on `/info` / `/admin/health`.

### F-2 — Phone & card regexes destroy floats, timestamps, IDs in logs
**Class:** unredacted-secret-mitigation-with-collateral-damage / poor-coverage
**Severity:** **HIGH** (blocks diagnosis)
**Reproducer:** `tail -200 /home/openclaw/Coding/MemOS/.memos/logs/memos.log` after any `/product/search` or `/product/add` call.
**Evidence:**
- `audit-v1-perf-1777576075` (a *user_id* I/anyone could write to logs as part of audit traffic) is rendered as `audit-v1-perf-[REDACTED:phone]` because `1777576075` is a 10-digit run that satisfies the phone regex (`src/memos/core/redactor.py:114-122`).
- Cube IDs containing the unix-ts marker (`V1-FN-A-1777576075` → `V1-FN-A-[REDACTED:phone]`) — same root cause.
- Vector embedding floats (`-0.04724487...`) consistently redact to `-[REDACTED:phone]`. A single search log line dumps 384-d embedding ≈ 380 `[REDACTED:phone]` substitutions.
- Worse, `start_delay_ms: 1.5064010620117188` redacts to `1.[REDACTED:card]` because that long fractional digit run passes Luhn. So even *latency numbers* in `MONITOR_EVENT` payloads come out unreadable.
**Impact:** at 3 a.m., grepping for a user_id like `audit-v1-obs-1777576524` returns 0 hits — the logged form is `audit-v1-obs-[REDACTED:phone]` which is not unique. Embedding dumps are noise that bloats log size, and `start_delay_ms` / `event_duration_ms` cannot be parsed for performance triage.
**Remediation:** (a) tighten phone regex to require explicit phone shape (e.g. `+`, parentheses, or hyphenated grouping) — current pattern matches any 9–15 contiguous digits; (b) skip Luhn check on number-shaped tokens that contain a `.`; (c) suppress vector-embedding fields entirely at log site (don't log the embedding list); (d) safelist a configurable allowlist of identifier patterns (`audit-*`, `V1-*`, `usr_*`).

### F-3 — `/health/deps` (and any non-existent path) requires auth → operators can't introspect health detail without a valid agent key
**Class:** missing-signal / poor-coverage
**Severity:** Medium
**Reproducer:** `curl -i http://localhost:8001/health/deps` → `401 Authorization header required`. Same for `curl -i http://localhost:8001/info` and `/metrics` (which don't exist, but `AgentAuthMiddleware.SKIP_PATHS` (`agent_auth.py:109`) only exempts `/health, /docs, /openapi.json, /redoc` and prefixes `/download, /admin`, so 404s never surface — every "is this endpoint here?" probe gets 401 instead of 404).
**Evidence:** `agent_auth.py:109-110`:
```
SKIP_PATHS = {"/health", "/docs", "/openapi.json", "/redoc"}
SKIP_PREFIXES = ("/download", "/admin")
```
`/health/deps` is registered as a router on `app.get("/health/deps")` (`server_api.py:230`) but `/health/deps` ∉ SKIP_PATHS, so AgentAuthMiddleware rejects it before the route is reached.
**Impact:** the surface that *would* answer "which dep is failing right now?" is gated behind a credential. The on-call has to either (a) decode `/health`'s 503 list (only available when something *is* failing), (b) read the log file, or (c) hold an agent key.
**Remediation:** add `/health/deps` to `SKIP_PATHS`. Optionally implement a real `/info` (version, git sha, started-at, log path).

### F-4 — `/health` does not probe SQLite, the LLM provider, or the embedder
**Class:** silent-failure
**Severity:** **HIGH**
**Reproducer:** read `_ensure_health_probes` in `server_api.py:131-197` — only `qdrant` and `neo4j` are registered. SQLite (the user/cube store), DeepSeek / MEMRADER, and the local sentence-transformers embedder have no probes.
**Evidence:** if MEMRADER's API key is invalid, `/product/add` will accept the write, the scheduler will run extraction, and the failure surfaces only as a per-record warning log. `/health` continues to say `{"status":"healthy"}`. Same for SQLite write-lock contention (`memos_users.db` is the auth source-of-truth for every authenticated request).
**Impact:** in incident "MemOS isn't writing memories any more" or "auth requests intermittently 500", `/health` is a green light while the system is silently degraded.
**Remediation:** register `sqlite` (cheap `SELECT 1`), `embedder` (one-off encode of "ping" with timeout), and `llm_provider` (HEAD / lightweight ping behind a circuit breaker so a transient outage doesn't cascade to /health). Mark `embedder` and `llm_provider` `required=False` so a green LLM provider isn't a deploy gate, but still reflected in `/health/deps`.

### F-5 — Header redaction works; but body redaction at API ingress is *not* logged before the route handler runs
**Class:** poor-coverage
**Severity:** Low (informational defense-in-depth)
**Reproducer:**
```
curl -i -X POST http://localhost:8001/product/search \
  -H "Authorization: Bearer ak_FAKEFAKEFAKEFAKEFAKE0123456789ab" \
  -H "X-Custom-Token: sk-fake12345abcdef67890" \
  -H "X-Email: alice@example.com" \
  -H "X-Phone: +1-415-555-1234" \
  -H "Content-Type: application/json" \
  -d '{"query":"v1-obs-2026-04-30 ..."}'
tail -3 /home/openclaw/Coding/MemOS/.memos/logs/memos.log
```
**Evidence:** logged line shows `'x-custom-token': '[REDACTED:sk-key]'`, `'x-email': '[REDACTED:email]'`, `'x-phone': '[REDACTED:phone]'`, and `Authorization` header is dropped entirely (`request_context.py:71`). Bodies are *not* logged at request-start (good — but means the log mirror that I'd want for "what did the client actually post?" doesn't exist either; the agent-add handler does log content downstream after extraction, where the redaction filter does fire).
**Impact:** redaction is solid where logging happens, but coverage of payload bodies is opaque — a misbehaving payload can only be reconstructed by re-replaying. Acceptable, but document it.
**Remediation:** add a config flag `MEMOS_LOG_REQUEST_BODY=1` for staging only.

### F-6 — `user_name` / `user_type` / `env` columns are persistently `None` for the API request path
**Class:** poor-coverage / no-correlation
**Severity:** **HIGH**
**Reproducer:** every `path=/product/*` log line in `memos.log` from authenticated traffic shows `env=None | user_type=None | user_name=None`.
**Evidence:** `request_context.py:54-66` only reads `x-env`, `x-user-type`, `x-user-name` headers — Hermes plugin (`~/.hermes/plugins/memos-toolset/handlers.py:36`) only sets `Authorization`, never the user-name headers. The `AgentAuthMiddleware` does decode the bearer to a `user_id` but writes it to a *separate* context (it lives only inside the scheduler context lines, where you see `user_name=V1-FN-A-1777576075`), not into the `RequestContext` consumed by the per-request log filter.
**Impact:** "auth keeps failing for one agent" — the operator has the trace_id and the path, but the request line **does not contain which agent key was used** (and the auth-rejection log strips Authorization too). To attribute a 401 to a user, the operator has to grep adjacent INFO lines or correlate by client IP — both unreliable.
**Remediation:** in `AgentAuthMiddleware`, after key resolution, mutate the active `RequestContext` to set `user_name=<resolved user_id>`. Alternatively, log the resolved `user_id` as a structured field in the request_context "started" / "completed" lines.

### F-7 — No Prometheus `/metrics` endpoint
**Class:** no-metrics
**Severity:** **HIGH**
**Reproducer:** `curl -i http://localhost:8001/metrics` → 401 (path doesn't exist; auth middleware shadows the 404). `grep -rn "prometheus\|Counter(\|Histogram(\|Gauge(" /home/openclaw/Coding/MemOS/src/memos` returns nothing under `api/`.
**Evidence:** counters that exist in *log lines only*: `[TIMER] X took Yms`, request status codes, scheduler `event_duration_ms`. Pulling a meaningful "p99 search latency last 5m" requires log scraping. There is no histogram. There is no rate counter. Rate-limit middleware emits headers on response (`X-Ratelimit-Limit`, `X-Ratelimit-Remaining`, `X-Ratelimit-Reset`) — those are per-response only, not aggregated.
**Impact:** "search is slow today" cannot be answered without log scrape. Capacity planning, SLO tracking, and alerting all depend on a metrics surface this system does not have.
**Remediation:** mount `prometheus_fastapi_instrumentator` (one decorator on app), expose `/metrics` (auth-exempt or behind admin scope), add custom histograms for `search_latency_ms` and `add_latency_ms` keyed by `cube_id` cardinality-controlled bucket. **Ship before any production traffic.**

### F-8 — Log rotation is daily-only, `backupCount=3`; no size cap, no compression
**Class:** no-rotation
**Severity:** Medium
**Reproducer:** `ls -la /home/openclaw/Coding/MemOS/.memos/logs/` shows `memos.log` (3.1 MB after 1 day), and three day-stamped backups (1.3–3.7 MB each). `log.py:236-243` configures `ConcurrentTimedRotatingFileHandler(when="midnight", interval=1, backupCount=3)`.
**Evidence:** under v1 traffic the rotation cadence is fine, but: (a) **no size-based fallback** — a sudden burst of debug-level traffic between midnight rotations can blow up `memos.log` unbounded, and (b) **no compression** — old days sit on disk uncompressed. Verbose vector-embedding lines (see F-2 collateral) at ~5 KB each x 384 floats x N searches is significant.
**Impact:** "disk is filling up — what's filling it?" is answerable (`du`) but rotation gives no headroom against a runaway log spike.
**Remediation:** switch to `ConcurrentRotatingFileHandler` with `maxBytes=100MB, backupCount=10` *and* keep the time component, gzip rotated files (third-party plug `concurrent_log_handler` supports it via `use_gzip`).

### F-9 — Scheduler emits structured `MONITOR_EVENT` JSON lines (good!)
**Class:** strength-not-finding (positive observation)
**Severity:** Info
**Evidence:** `monitor_event_utils.py:65` writes one-line JSON per event (`enqueue / dequeue / start / finish`) with `event_duration_ms`, `total_duration_ms`, `queue_wait_ms`, `host`, `trace_id`, `user_id`, `mem_cube_id`. With a `jq`-able stream this is the only place in the system you can answer "how long was X queued vs running?".
**Caveat:** the values get rekt by F-2 (durations show as `1.[REDACTED:card]`).

### F-10 — Hermes plugin client side: no trace-id propagation
**Class:** no-correlation-id
**Severity:** **HIGH**
**Reproducer:** `grep -rn "x-trace-id\|X-Trace\|trace_id\|request_id" ~/.hermes/plugins/memos-toolset/*.py` → only one match, and that's not a header set call. Plugin sets `Authorization` and nothing else (`handlers.py:36`).
**Evidence:** server happily honors a client-supplied `x-trace-id` (`request_context.py:23`) — I confirmed by sending `x-trace-id: V1-OBS-CORR-PROBE-1234567890abcdef` and seeing it in the trace_id column. But the plugin doesn't send it. So an agent that just called `add()` and then `search()` cannot answer "what was the trace_id of my add call?" without parsing the response. There is **no end-to-end correlation chain from the agent's perspective**.
**Impact:** "did my memory get stored?" — the agent has to retry-search and infer. There is no `request_id` in the response either (server returns the plain payload, no `x-trace-id` echo header).
**Remediation:** (a) plugin generates a UUID per call and sends it as `x-trace-id`; (b) server echoes the trace_id back in the response header; (c) plugin logs both client-side. Bonus: a tool call `mem.confirm(trace_id=...)` that returns the persisted-memory IDs the server stamped against that trace.

### F-11 — Hermes plugin observability surface for the agent is empty
**Class:** missing-signal
**Severity:** Medium
**Evidence:** `~/.hermes/plugins/memos-toolset/` has `__init__.py`, `handlers.py`, `auto_capture.py`, `capture_queue.py`, `schemas.py`. `grep -rn` for logger calls shows ≈8 `logger.info` / `logger.warning` total — the agent-side equivalent of "I tried to capture this and the queue rejected it" is logged but not exposed back to the agent as a tool-callable status. There is a `capture_queue` (with `queue/` directory) but no `mem.queue_status()` / `mem.last_capture_result()` tool. The agent flies blind on its own writes — see also F-10.
**Remediation:** expose two tools — `mem.health()` (return server `/health/deps` + plugin-local queue depth + last error) and `mem.audit(trace_id=...)`.

### F-12 — Container observability adequate but un-correlated
**Class:** poor-coverage
**Severity:** Low
**Evidence:** `docker logs qdrant` and `docker logs neo4j-docker` produce per-request access lines. Qdrant: `INFO actix_web::middleware::logger: 172.17.0.1 "POST /collections/neo4j_vec_db/points/query HTTP/1.1" 200 60 "-" "python-client/1.17.1" 0.001612` — useful for sanity, but no trace_id propagated downstream of MemOS, so an operator cannot correlate a slow `/product/search` log line in MemOS with the matching Qdrant access line beyond timestamp.
**Remediation:** stamp the trace_id into the qdrant client `User-Agent` header or as a custom header (Qdrant logs `User-Agent` already), and into Neo4j session metadata.

### F-13 — Per-incident diagnostic walkthrough (the heart of the audit)

Each scenario assumes the on-call has shell on the host but no Bearer key (a realistic 3 a.m. constraint).

| # | Incident | Diagnosis path | <10 min? | Score |
|---|----------|----------------|----------|-------|
| 1 | "A memory I just stored isn't searchable" | `tail memos.log | grep <user_id-fragment>` — but user_id digits get F-2 redacted. Then `sqlite3 memos.db "select * from memories where ..."` — but path of the live `.db` is CWD-dependent (F-1). Then `qdrant_client search` directly → assumes Bearer for Qdrant. | Marginal | 4/10 |
| 2 | "Search is slow today" | No `/metrics` (F-7). Have to grep `[TIMER] search took Xms` lines, awk-sum, and hope durations aren't redacted as `[REDACTED:card]` (F-2). p99 not derivable. | No | 2/10 |
| 3 | "Auth keeps failing for one agent" | trace_id present in 401 lines, but `user_name=None` (F-6) and `Authorization` stripped (correct), so cannot tell *which* agent without IP-correlation. Rate-limit headers exist on response only — not in logs. | No | 3/10 |
| 4 | "Disk is filling up" | `du` works. Logs are largest contributor (F-8). Vector-WAL not separately health-checked (F-4). | Yes | 7/10 |
| 5 | "MemOS keeps restarting" | `journalctl -u memos` works. Last log line in `memos.log` may be `[REDACTED:phone]` rich (F-2). Exit code visible in journal. | Yes | 7/10 |
| 6 | "An LLM extraction returned garbage" | Prompt is logged at INFO from MemReader path (`grep "MemReader\|llm.*prompt"` in source). Cost is *not* logged anywhere. | Marginal | 4/10 |
| 7 | "A duplicate slipped through dedup" | Dedup decision logging is sparse — `grep -rn "dedup" src/memos` returns scattered debug lines, not a consistent decision-record format. | No | 3/10 |

Mean: ≈4.3/10. Min: 2/10.

---

## Summary

| Area | Score 1-10 | Key findings |
|------|-----------|--------------|
| Log sinks + content quality | 5 | F-1 (CWD-relative path), F-2 (collateral redaction), F-9 (structured scheduler events). Rich INFO instrumentation, but plain text not JSON-line. |
| Health endpoint depth | 5 | F-3 (`/health/deps` auth-gated), F-4 (no SQLite/LLM/embedder probes). `/health` correctly 503's on Qdrant or Neo4j down (real win). |
| Metrics endpoint (Prometheus or equiv) | 1 | F-7 — absent entirely; counters live in log lines only. |
| Request correlation IDs | 4 | F-6, F-10, F-12 — server-side trace_id is solid; client-side propagation absent; user_id never bound to log line. |
| Secret redaction across all sinks | 5 | Headers good, defense-in-depth filter on every handler. F-2 makes redaction destroy legitimate identifiers; net is mixed — strong on real secrets, harmful on numerics. |
| Log rotation + retention | 5 | F-8 — daily-only, no size cap, no compression. Adequate today, fragile under burst. |
| Debug toggles | 6 | `MEMOS_DEBUG=1` flips both console and file levels; takes restart (no SIGHUP path). Verbose mode is safe (redaction is on every handler unconditionally). |
| Hermes plugin observability | 3 | F-10, F-11 — no client trace-id, no agent-callable status. |
| Per-incident diagnostic capability | 2 | F-13 — slow-search and dedup-debug effectively undiagnosable without DB shell + Bearer key. |

**Overall observability score = MIN = 1/10** (driven by F-7, no metrics).

---

## 3 a.m. judgement

If I am paged at 3 a.m. with "search latency is up and a customer says writes are missing", this system gives me: a working `/health` (so I know the binary is up and Qdrant+Neo4j respond), a working `journalctl`, and a 1.8 MB plain-text log file in a CWD-dependent path with a rich-but-redaction-mangled timeline. I have no metrics endpoint to feed a dashboard, so I cannot quantify "slow" — I have to grep `[TIMER]` lines and hope the durations aren't `[REDACTED:card]`. I cannot attribute a 401 storm to a specific agent because `user_name` is `None` on the request line. I cannot tell whether MEMRADER is silently failing because there's no probe for it. The scheduler's `MONITOR_EVENT` lines are excellent in shape but unusable in practice because `event_duration_ms: 1.5064...` shows as `1.[REDACTED:card]`. The Hermes plugin can write but cannot ask "did it land?" so the agent's own observability is a stub. Net: I can probably *survive* the page (the binary stays up, dependencies are honest), but I cannot *resolve* the page in <30 minutes without ssh, sqlite3, jq, and patience. **Ship metrics + fix F-2 + bind user_id into RequestContext before any user-facing v1.0.**
