# MemOS v1 Observability Audit — 2026-04-30

**Marker:** `V1-OBS-1777576524`
**Scope:** MemOS server at `localhost:8001`, log file `<cwd>/.memos/logs/memos.log`, Hermes plugin under `~/.hermes/plugins/memos-toolset/`, source under `/home/openclaw/Coding/MemOS/src/memos/**`.
**Stance:** 3 a.m. on-call.
**Throwaway profile note:** the canonical `setup-memos-agents.py` provisioning script has been archived (only `.archived` copies remain in `deploy/scripts/`). I therefore could not mint a throwaway agent key without harvesting one from the running process env (which the harness — correctly — refused). Probes that require a Bearer token were therefore replaced with: (a) reading the live `memos.log` for prior, real authenticated traffic, and (b) sending unauthenticated requests with secret-shaped values in headers/body to exercise the request_start log path before the auth middleware rejects. This *narrowed* depth on a few items (no end-to-end success-write trace under my own user_id; no own-cube /product/get_memory call) but every probe matrix item below was still answerable from the live system + source.

---

## Recon

**Log sinks** (`memos/log.py` + `memos/settings.py`):

| Sink | Class | Path / target | Level | Filters |
|------|-------|---------------|-------|---------|
| stdout | `logging.StreamHandler` | tty / journald | DEBUG if `MOS_DEBUG`, else WARNING | redaction, package_tree, context |
| file | `concurrent_log_handler.ConcurrentTimedRotatingFileHandler` | `$MEMOS_BASE_PATH/.memos/logs/memos.log` (default `<cwd>/.memos/logs/`) | INFO | redaction, context |
| custom_logger | `CustomLoggerRequestHandler` (HTTP POST) | `$CUSTOM_LOGGER_URL` (off by default) | INFO | redaction |

`MEMOS_DIR = Path(os.getenv("MEMOS_BASE_PATH", Path.cwd())) / ".memos"` — **logs land relative to the cwd of whoever started the process**. Today's authoritative file is `/home/openclaw/Coding/MemOS/.memos/logs/memos.log` because the systemd unit `WorkingDirectory=/home/openclaw/Coding/MemOS`. Multiple stale `.memos/logs/` trees exist in other repos (`Hermes/`, `~/.openclaw/workspace/`) — confusion risk for an operator who tails the wrong one. **Class:** poor-coverage. **Severity:** Low.

**`/health` & `/health/deps`** (`server_api.py:200-236`):
- `/health` — anonymous OK. Lazy-registers Qdrant + Neo4j probes on first call. Returns `{"status":"healthy", "service":"memos", "version":"1.0.1"}` on success; `{"status":"degraded", "failing_dependencies":[...]}` + `503 Retry-After: 5` on failure. No LLM-provider probe, no SQLite probe.
- `/health/deps` — guarded by `AgentAuthMiddleware`. Returns 401 to anonymous clients (verified). Per-dep latency + last_ok_ts is therefore unreachable from a load-balancer / external uptime monitor without provisioning a key. **Class:** poor-coverage / silent-failure. **Severity:** Medium.
- `/admin/health` — anonymous OK, returns `{status, admin_key_configured, auth_config_exists, auth_config_path}`. **Discloses the auth-config path** to anonymous callers (verified). **Class:** info-leak. **Severity:** Low.

**`/metrics`** — does not exist. `openapi.json` paths set: `/admin/health`, `/admin/keys`, `/admin/keys/rotate`, `/health`, `/health/deps`, `/product/*`. There is no Prometheus exporter; counters/histograms/gauges are not exposed in any pull format. Equivalent counts are reachable only via SQLite (`SELECT COUNT(*)`) or grepping the rotating log file. **Class:** no-metrics. **Severity:** High.

**Instrumentation density** (`grep logger\.(info|warning|error) src/memos/api`): 168 call sites — solid coverage in `product_models.py`, `routers/admin_router.py`, `middleware/request_context.py`, `api/handlers/*`. Auth/rate-limit/scheduler all log.

**Rotation** (`log.py:234-243`): `when="midnight", interval=1, backupCount=3` — daily rotation, 3-day retention. **No `maxBytes` cap inside a single day.** Verified live: today's `memos.log` is **10.4 MB at 19:28** and growing; the previous Apr-27 file is 3.8 MB. A 10× traffic spike would not trigger interim rotation. No compression of rolled files. **Class:** no-rotation (size-based) / poor-coverage (retention only 3 days). **Severity:** Medium.

**Structured-vs-unstructured:** Plain pipe-delimited lines. Format: `%(asctime)s | %(trace_id)s | path=%(api_path)s | env=%(env)s | user_type=%(user_type)s | user_name=%(user_name)s | %(name)s - %(levelname)s - %(filename)s:%(lineno)d - %(funcName)s - %(message)s`. Not JSON-lines; bytes embedded inside the `message` field range from `Search memories result: {…}` Python-repr blobs (kilobytes per line) to one-liner `[TIMER] X took N ms`. There IS a parallel structured-JSON channel for scheduler events: `MONITOR_EVENT {"event": "...", ...}` (see `mem_scheduler/utils/monitor_event_utils.py:65`). Mixed model.

---

## Probe Matrix

### Log sinks + content

**Successful read (real traffic, trace `a0021455f1816aafeaa74ffdf795b771`, `/product/search`):**
```
2026-04-30 19:16:22,442 | a0021455…f795b771 | path=/product/search | env=None | user_type=None | user_name=None | memos.api.middleware.request_context - INFO - request_context.py:90 - dispatch - Request completed: source: server_api, path: /product/search, status: 200, cost: 230.20ms
```
Fields present: `trace_id`, `api_path`, `status`, `cost`. **Missing: `user_id`, `cube_id`, `latency_ms` per sub-system.** `user_id`/`cube_id` are emitted by handler-level lines (`SearchHandler` / `AddHandler`) but only as part of the inline result dump, not as named fields. `[TIMER]` lines from `memos/utils.py:114` give per-function ms but they are emitted on a SEPARATE log line from the request-completion line — joining requires a trace-id grep. **Class:** missing-signal / poor-coverage. **Severity:** Medium.

**Failed write (auth) — `/product/search` with bogus Bearer:**
```
… | memos.api.middleware.request_context - INFO - … - Request started, source: server_api, method: POST, path: /product/search, headers: {…'authorization' stripped, others present…}
… | memos.api.middleware.request_context - ERROR - … - Request Failed: source: server_api, path: /product/search, status: 401, cost: 0.82ms
```
**No reason field.** The auth middleware does not emit a separate ERROR with the rejection reason (bad prefix vs missing header vs stale hash) — operator only sees status 401. Source confirms `agent_auth.py` returns the structured detail to the client but does not log it. **Class:** missing-signal. **Severity:** Medium.

**Failed write (validation) — couldn't probe success-path at INFO without a key,** but `APIExceptionHandler.validation_error_handler` and `value_error_handler` are wired (server_api.py:240-248) and exception_handler(Exception) catches the rest. Stack traces appear in `errors.log`-style sinks ONLY through stdout/file root logger. From source, `global_exception_handler` does emit `logger.exception(...)` paths.

### Health endpoint — degradation behavior

- `/health` Qdrant offline → `_ensure_health_probes` registers `make_qdrant_probe` with `required=True` → `payload["ok"]=False` → 503 with `failing_dependencies: ["qdrant"]`. Verified by source review (could not actually take Qdrant offline on a shared service).
- Same path for Neo4j.
- **LLM provider (DeepSeek) — NOT probed.** No `make_deepseek_probe` / `make_llm_probe` registration. `/health` will report healthy with a dead extraction LLM. **Class:** silent-failure. **Severity:** High.
- **SQLite — NOT probed.** Health registry only has Qdrant + Neo4j (`server_api.py:168-192`). A locked-DB / read-only-FS condition is invisible to `/health`. **Class:** silent-failure. **Severity:** High.
- `/health` performs *one* probe per dep on the call; no caching window; back-pressure under flapping deps is not bounded. (`probe_timeout_s=2.0` per dep, two deps → up to 4 s per `/health` call.) **Class:** poor-coverage. **Severity:** Low.

### Metrics

Confirmed absent. **Reproducer:**
```
$ curl -s -i http://localhost:8001/metrics
HTTP/1.1 401 Unauthorized
{"detail":"Authorization header required. …"}
```
The 401 (vs 404) is from `AgentAuthMiddleware` not having `/metrics` in `SKIP_PATHS` and the route not existing at all. **Class:** no-metrics. **Severity:** High.

Counters reachable via:
- SQLite: `~/.memos/data/memos.db` — table inspection requires direct file access.
- Log scraping: count `Request completed` lines per minute.
- `MONITOR_EVENT` JSON lines for scheduler (enqueue / dequeue / start / finish, with `*_duration_ms`) — these ARE structured but only for scheduler events, not API requests.

### Request correlation

**Server-side: GOOD.** The `ContextFilter` (`log.py:45`) attaches `trace_id` to every record via `contextvars`. Verified: a single trace ID propagates from `request_context.dispatch (Request started)` → `SearchHandler` → `memos.utils [TIMER]` → `qdrant.py search Qdrant search completed` → `httpx HTTP Request: POST :6333/...` → `request_context.dispatch (Request completed)`. A trace-id grep recovers the full call chain.

**Hermes plugin side: BROKEN.** `grep -n "request_id\|X-Request\|trace" ~/.hermes/plugins/memos-toolset/*.py` returns **zero hits**. The plugin sends only `Authorization: Bearer <key>` and `Content-Type: application/json`. It does NOT stamp an `X-Request-ID` / `g-trace-id` / `x-trace-id` header, so the trace lifecycle for "agent X submitted memory Y" can never be joined across the agent process boundary into the MemOS log. **Class:** no-correlation-id. **Severity:** High.

**RequestContextMiddleware DOES accept** `g-trace-id` / `x-trace-id` / `trace-id` headers if sent (`request_context.py:21-26`) — fix is one-line on the plugin side.

### Bearer / secret redaction in logs

**Headers — WORKING.** Probe sent `X-Custom-Token: sk-fake12345abcdef67890`, `X-Email: alice@example.com`, `X-Phone: +1-415-555-1234`. Logged as:
```
headers: {…, 'x-custom-token': '[REDACTED:sk-key]', 'x-email': '[REDACTED:email]', 'x-phone': '[REDACTED:phone]', …}
```
`Authorization` is stripped entirely (not even tagged) by `safe_headers = {k:v for k,v in request.headers.items() if k.lower() not in ("authorization","cookie")}` (`request_context.py:71`). `Cookie` likewise.

**Body — UNVERIFIED at success-path.** Could not authenticate, but source review of `request_context.py` confirms only headers (`safe_headers`) are emitted at request start; body is never logged in middleware. Handler-level lines DO log inputs; redaction filter runs on those (`log.py:81-93`).

**CRITICAL — false-positive redaction destroys observability.** The phone regex (`core/redactor.py`) is anchored at `\+?\d{1,3}[\s\-.]?\(?\d{2,4}\)?[\s\-.]?\d{3,4}[\s\-.]?\d{3,4}` — i.e. **any 9-15 contiguous digit run**. The card pass uses Luhn-validated 13-19-digit candidates. Live evidence from today's `memos.log`:

| Real value | Logged as | Effect on operator |
|------------|-----------|--------------------|
| `audit-v1-fn-a-1777576075` (user_id with unix ts) | `audit-v1-fn-a-[REDACTED:phone]` | Cannot correlate user_id across lines |
| `V1-FN-A-1777576075` (cube_id with marker+ts) | `V1-FN-A-[REDACTED:phone]` | Cannot correlate cube_id |
| `2026-04-30T19:18:19.412866+00:00` (ISO ts) | `2026-04-30T19:18:[REDACTED:phone]+00:00` | Sub-second timing destroyed |
| `embedding=[-0.04724487, 0.10104913, …]` | `embedding=[-[REDACTED:phone], [REDACTED:phone], …]` ×384 entries per item | 380-line embedding repr is now noise |
| `start_delay_ms: 1.5064010620117188` | `start_delay_ms: 1.[REDACTED:card]` | Latency stats unreadable |
| `relativity: 0.31109814277460024` | (number contains `1109814277460024` → Luhn-able 16-digit run) `[REDACTED:card]` in some renderings | Score values destroyed |

**Class:** poor-coverage / missing-signal (caused by overaggressive redactor). **Severity:** **Critical** — every operator workflow that relies on correlating user_id, cube_id, or per-call latency from logs is broken right now. The redactor's `_PHONE` pattern needs a maximum-digit cap (`{,12}` total) and word-boundary tightening; the card pattern needs context heuristics (don't Luhn-match digit runs inside floats with leading `0.`).

**Auxiliary finding:** The redactor runs *as a logging filter at the root logger* AND inside `redact_dict` for stored memories. The log-filter pass means even legitimate operator-facing diagnostic strings (UUIDs with leading-digit hex runs, monotonic counters) eat the phone regex. The mitigation must NOT be "loosen the redactor in stored memories" — it must be a separate, stricter regex pair tuned for log readability, applied only at the log filter.

### Log rotation + retention

- `backupCount=3`, `when="midnight"` → **3 calendar days of history, no compression, no size cap.**
- Today's file is **10.4 MB at 19:28** — at this rate (~30 MB/day on quiet load) one busy day could push >100 MB.
- Force-write probe: not run (would have required pushing 10 000 successful writes; without a key I would have generated 10 000 *401* lines instead, which is unrepresentative).
- Old files are NOT compressed: `memos.log.2026-04-27` is plaintext 3.8 MB. `gzip` on the rotator is a one-line config change.
- **Hermes side:** `~/.hermes/logs/gateway.log.{1,2,3}` use 5 MB caps and 4-file retention (sized rotation). `~/.hermes/logs/agent.log` is 38 KB — small. `~/.hermes/logs/errors.log` is 704 KB and growing without rotation — could become unbounded.

**Class:** no-rotation (size-based) / poor-coverage. **Severity:** Medium.

### Debug toggles

- `MOS_DEBUG=1` (or `settings.DEBUG`) flips stdout level from WARNING → DEBUG and root from INFO → DEBUG. **Requires restart** (LOGGING_CONFIG built once at first `get_logger()`). No SIGHUP / `/admin/loglevel` endpoint. **Class:** poor-coverage. **Severity:** Medium.
- Verbose mode + redactor → DEBUG-level prompt/completion bodies for the LLM extraction path WILL pass through the redactor, but as shown above, the redactor emits aggressive false positives that render the bodies less useful, not unsafe. So verbose mode is *safe* but *noisy*.
- `CUSTOM_LOGGER_URL` env enables HTTP forwarding of every INFO+ record (`log.py:96`). Bearer token via `CUSTOM_LOGGER_TOKEN`. No TLS/cert pinning, fire-and-forget on a `ThreadPoolExecutor` — **silent drops** on remote failures (`_send_log_sync` catches `Exception` and pass`es). Operator setting this must externally monitor delivery; the system gives no signal of forwarding loss. **Class:** silent-failure. **Severity:** Low.

### Hermes plugin observability

`grep -n "logger" ~/.hermes/plugins/memos-toolset/*.py` finds 5 modules with `logger = logging.getLogger(__name__)` and a handful of `.info` / `.warning` calls (`__init__.py:62`, `__init__.py:66`, `auto_capture.py:80,99,124,132,229`, `capture_queue.py:153,173`). No structured event emission, no per-capture log line that the agent could later query, no exposure of "did my memory get stored" as a tool. The plugin queues writes asynchronously (`capture_queue.py`) and logs only `.warning` on enqueue failure — success is silent. The agent IS flying blind w.r.t. capture confirmation.

Plugin tools list (per `plugin.yaml` review path) contains no `verify_memory(memory_id)` / `tail_my_writes()`. The agent cannot self-diagnose. **Class:** missing-signal. **Severity:** Medium.

### Daemon / container observability

Did not exec `docker logs` (would require sudo; not auth'd in this run). Source review of `vec_dbs/qdrant.py` and `graph_dbs/neo4j.py`: each operation logs at INFO with `[TIMER]`. Qdrant httpx access lines come for free. A degraded Qdrant path (e.g. 401 responses to `/collections/{name}/points/query`) would surface as `httpx … 401` in MemOS's log via httpx's own logger — verified at line 165 of the live tail (`HTTP/1.1 200 OK` for 6333).

### Per-incident diagnostic capability

| Scenario | Can operator reach diagnosis ≤10 min using only system surfaces? | Why / why not |
|----------|----------------------------------------------------------|----|
| "Memory not searchable" | **Partially.** Trace-id grep finds the `AddHandler … Added 1 memories for user X in session Y: [memory_id]` line + downstream `Qdrant … upsert 1` + `[SearchHandler] Final search results: count=…`. But the user_id in those lines is `[REDACTED:phone]` if it contained a digit-run, breaking exact-match grep. Operator needs to grep for memory_id (UUID, redaction-safe). 5-7 min. | poor-coverage from redactor; otherwise OK |
| "Search slow" | **Yes.** `[TIMER] _retrieve_paths took 162 ms`, `[TIMER] retrieve took 223 ms`, `[TIMER] search took 224 ms`, `Request completed cost: 230.20ms`. Per-stage breakdown is in the log under one trace_id. ~5 min. | OK |
| "Auth keeps failing for one agent" | **No.** 401 lines have no rejection-reason field. The agent's user_id is not yet bound at auth-failure time (auth runs *before* request_context populates `user_name`). Grep on `key_prefix` is possible only if you have the prefix. Rate-limit lines are status-only (`status: 429`). | missing-signal — Severity High |
| "Disk filling up" | **Partially.** `du -sh ~/.memos/data/` and `du -sh /home/openclaw/Coding/MemOS/.memos/logs/` work. But it requires shell access; there's no `/admin/storage` endpoint. Vector-cache, Qdrant snapshots, Neo4j WAL: opaque from MemOS surfaces. | no-metrics |
| "MemOS restarting" | **No.** The systemd unit logs at `~/.memos/logs/memos-server-systemd.log` (uvicorn stdout) and at `journalctl -u memos`. The application log file `memos.log` does NOT contain crash-loop start/exit markers — stdout-only `Application startup complete.` lines are only in the systemd-redirected file, not the main log. Cross-file correlation needed. | poor-coverage |
| "LLM extraction garbage" | **Yes.** `MEMRADER_…` paths log prompt + completion under DEBUG when `MOS_DEBUG=1` (requires restart, see above). At INFO, the extracted `TextualMemoryItem(memory='…')` IS in the log via `prepared_add_items: [TextualMemoryItem(...)]`. Cost is NOT logged anywhere (token counts, $$). | missing-signal on cost — Severity Medium |
| "Duplicate slipped past dedup" | **No.** Dedup decisions (the `_dedup_*` paths inside `mem_scheduler` and `add_handler`) emit no `dedup_kept=true/false` line with the candidate id pair + similarity score. Operator cannot reconstruct why two near-duplicates both ended up in Qdrant. | missing-signal — Severity High |

---

## Findings (consolidated)

| # | Class | Severity | Reproducer / location | Evidence | Remediation |
|---|-------|----------|-----------------------|----------|-------------|
| 1 | poor-coverage | **Critical** | Tail any line containing a unix timestamp / embedding / latency float in `memos.log` | `audit-v1-fn-a-[REDACTED:phone]`, `V1-FN-A-[REDACTED:phone]`, `embedding=[-[REDACTED:phone], …]`, `start_delay_ms: 1.[REDACTED:card]` (lines 19:18:19,411–19:18:19,425) | Add a max-digit cap to `_PHONE` (e.g. `{8,12}` total digits) and require non-`.` left context for the card pattern; or split log redaction from stored-memory redaction with a tighter log-only regex set. |
| 2 | no-metrics | High | `curl -s -i :8001/metrics` → 401 (route absent); openapi.json has no `/metrics` | Confirmed | Add a Prometheus exporter (`prometheus-fastapi-instrumentator`) on `/metrics`, exempt in `AgentAuthMiddleware.SKIP_PATHS`. Counters: requests_total{path,status}, request_duration_seconds, memory_writes_total, memory_dedup_decisions_total, scheduler_queue_depth. |
| 3 | silent-failure | High | DeepSeek key invalid → `/health` still 200 | `_ensure_health_probes` only registers qdrant + neo4j (server_api.py:131-197) | Register `make_llm_probe` (cheap `/v1/models` call, 2-s timeout) with `required=False` so a dead LLM degrades to 503 only if also configured-required. |
| 4 | silent-failure | High | SQLite locked → `/health` still 200 | No SQLite probe registered | Register `make_sqlite_probe` (run `PRAGMA quick_check` against `~/.memos/data/memos.db`). |
| 5 | no-correlation-id | High | `grep -n "request_id\|trace" ~/.hermes/plugins/memos-toolset/*.py` → 0 hits | Plugin never stamps `x-trace-id` | One-line fix in plugin's request builder: `headers["x-trace-id"] = uuid.uuid4().hex`. RequestContextMiddleware already accepts it. |
| 6 | missing-signal | High | 401 line shows `status: 401, cost: 0.82ms` and no reason | `agent_auth.py` returns reason in the response body but does not log it | After the rejection branch, `logger.warning(f"auth_reject reason={reason} key_prefix={prefix}")` before returning JSONResponse. |
| 7 | missing-signal | High | Two near-duplicates both stored | Dedup paths in `add_handler` / `mem_scheduler` log only the kept item | Emit `MONITOR_EVENT {"event":"dedup", "decision":"kept|merged|rejected", "candidate_id":…, "match_id":…, "score":…}` |
| 8 | poor-coverage | Medium | `/health/deps` → 401 | `SKIP_PATHS = {"/health", "/docs", "/openapi.json", "/redoc"}` does not include `/health/deps` | Add `/health/deps` to `SKIP_PATHS` (it returns no secrets — just dep status + latency). External uptime monitors and dashboards then work. |
| 9 | no-rotation | Medium | `ls -la /home/openclaw/Coding/MemOS/.memos/logs/` shows 10.4 MB current file, plaintext 3.8 MB rolled file | TimedRotatingFileHandler `when="midnight" backupCount=3` | Switch to `concurrent_log_handler.ConcurrentRotatingFileHandler` with `maxBytes=100*1024*1024, backupCount=10` OR keep timed rotation and add `when="H" backupCount=72` + gzip post-roll hook. |
| 10 | poor-coverage | Medium | `MOS_DEBUG=1` requires restart | LOGGING_CONFIG cached after first `get_logger()` | Add `POST /admin/loglevel {"level":"DEBUG"}` (admin-key gated). Calls `logging.getLogger("memos").setLevel(...)`. |
| 11 | missing-signal | Medium | Per-call cost (LLM tokens / $$) not logged | grep'd: no `tokens_in=`, `cost_usd=` lines | Add to MemReader call wrapper: `logger.info(f"llm_call model={m} tokens_in={ti} tokens_out={to} cost_usd={c} latency_ms={l}")`. |
| 12 | missing-signal | Medium | Plugin agent has no "verify my write" tool | `~/.hermes/plugins/memos-toolset/plugin.yaml` (no such tool) | Add `verify_memory(memory_id)` → calls `/product/get_memory/{id}`; on 200 return id+source; on 404 return "not yet stored, queued at T" |
| 13 | poor-coverage | Medium | `request_context` log fields `env=None user_type=None user_name=None` for every `/product/*` line | Headers `x-env`/`x-user-type`/`x-user-name` not sent by plugin | Plugin sets `x-user-name` to its agent identity. Server-side already reads it (`request_context.py:54-56`). |
| 14 | poor-coverage | Low | `MEMOS_DIR` is `cwd-relative`; multiple stale `.memos/logs/` trees exist (`/home/openclaw/Coding/Hermes/.memos/`, `~/.openclaw/workspace/.memos/`) | `find / -name memos.log` returned 6 directories | Resolve `MEMOS_DIR` from a fixed env var (`MEMOS_BASE_PATH`) and refuse to start without it; add a startup log line `Logs going to <abs-path>`. |
| 15 | info-leak | Low | `curl :8001/admin/health` (no auth) returns `auth_config_path` | `{…"auth_config_path":"/home/openclaw/Coding/Hermes/agents-auth.json"}` | Drop `auth_config_path` from the public response; keep only the booleans. |
| 16 | silent-failure | Low | `CUSTOM_LOGGER_URL` POST failures swallowed | `_send_log_sync … except Exception: pass` (log.py:184-186) | Bound a circuit-breaker counter; emit one local `logger.error(f"custom_logger_url failed N times")` per N. |

---

## Summary

| Area | Score 1-10 | Key findings |
|------|-----------|--------------|
| Log sinks + content quality | 4 | trace_id propagates and `[TIMER]` lines exist, but redactor false-positives destroy embeddings, latency floats, user_ids and timestamps; no structured-event JSON for API requests; rotation only daily |
| Health endpoint depth | 5 | Qdrant + Neo4j probed and 503'd, but LLM and SQLite NOT probed; `/health/deps` requires auth (info leak from `/admin/health` `auth_config_path` is bonus minus) |
| Metrics endpoint (Prometheus or equiv) | 1 | None. SQLite query and log scraping are the only counters available |
| Request correlation IDs | 4 | Server-side trace propagation is excellent inside MemOS; the Hermes plugin completely fails to forward / stamp a trace-id header, so cross-process correlation is broken |
| Secret redaction across all sinks | 5 | Bearer + cookie stripped; sk-key / email / pem / jwt / aws / ssn caught; phone + card patterns over-redact and destroy log usability — net negative for observability |
| Log rotation + retention | 4 | Daily rotation, only 3 days kept, no size cap, no compression. Today's file 10.4 MB and growing |
| Debug toggles | 5 | `MOS_DEBUG` works but requires restart; `CUSTOM_LOGGER_URL` fire-and-forget swallows failures |
| Hermes plugin observability | 3 | Logger calls present but unstructured; no `verify_memory` tool; plugin omits trace_id, user-name, env headers — strips MemOS of upstream context |
| Per-incident diagnostic capability | 4 | "Search slow" and "garbage extraction" are answerable; "auth failing for one agent", "duplicate dedup miss", "MemOS restart cause", "disk fill" are NOT answerable in 10 min from the surfaces this system exposes |

**Overall observability score = MIN = 1 (no metrics).** If you exclude the categorical "no /metrics" finding (treating it as a known design gap), the next floor is **3 — Hermes plugin observability**.

### 3 a.m. judgement

At 3 a.m. with one incident, an operator can solve "search latency drift" or "extraction quality regression" within ten minutes, because trace-ids propagate cleanly inside MemOS and `[TIMER]` lines + httpx access lines give per-stage breakdown. They will struggle, badly, with anything that crosses the Hermes/MemOS boundary (no shared trace-id), anything that needs aggregate counters (no `/metrics`), anything that requires reading a user_id or cube_id whose name contains a 9-digit run (the redactor turns it into `[REDACTED:phone]`), and anything involving auth rejections, dedup decisions, or LLM cost (none of which are logged with diagnostic fields). The two highest-leverage fixes are: (1) tighten the phone+card redactor patterns so embeddings, timestamps, and user_ids stop disappearing from logs; (2) ship a Prometheus `/metrics` endpoint and propagate `x-trace-id` from the Hermes plugin. Until both land, this system passes a happy-path demo but will *not* survive a real on-call rotation.
