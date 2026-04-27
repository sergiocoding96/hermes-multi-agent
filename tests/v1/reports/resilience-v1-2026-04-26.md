# MemOS v1 Resilience Audit

**Marker:** V1-RES-1777215513  
**Date:** 2026-04-26  
**Auditor:** Claude Sonnet 4.6 (zero-knowledge, chaos-monkey stance)  
**Branch:** tests/v1.0-audit-reports-2026-04-26

---

## System Under Test

- **MemOS server:** `python3.12 -m memos.api.server_api --port 8001` (PID 450537 at audit start)
- **Qdrant:** Docker container `qdrant`, restart policy `unless-stopped`, port 6333
- **Neo4j:** Docker container `neo4j-docker`, restart policy `unless-stopped`, port 7687
- **SQLite (users/cubes):** `~/.memos/data/memos_users.db` — primary memory stored in Neo4j + Qdrant
- **Embedder:** `sentence-transformers/all-MiniLM-L6-v2`, local HuggingFace cache
- **LLM (MemRADER):** DeepSeek V3 (`deepseek-chat`) via `MEMRADER_API_BASE`
- **ASYNC_MODE:** `async` (writes return 200 immediately; extraction runs via in-process scheduler)

---

## Recon Findings

### Restart policies
Both `qdrant` and `neo4j-docker` use `RestartPolicy: unless-stopped`. This means Docker restarts them after daemon restart but **not** after a container crash. The MemOS server has no Docker wrapper — it runs as a raw Python process. Its systemd unit (`memos.service`) exited with `status=1/FAILURE` on 2026-04-25 and is currently `inactive (dead)`. The only auto-start mechanism is an `@reboot` cron entry:
```
@reboot source ~/.hermes/venv/bin/activate && cd ~/Coding/MemOS && bash start-memos.sh >> ~/.hermes/logs/memos.log 2>&1 &
```
There is **no process supervisor** for crash recovery.

### Retry / circuit-breaker coverage
`QdrantVecDB.__init__` and `Neo4jGraphDB.__init__` instantiate clients with no timeout, no retry, and no circuit-breaker. `QdrantClient.upsert`, `.query_points`, etc. call the network synchronously; exceptions bubble up into the handler. The global FastAPI exception handler catches all `Exception` and returns HTTP 500 — but in practice (see probes below) the scheduler's async path swallows many of these at the task level.

### Error surfacing
`exceptions.py` maps:
- `RequestValidationError` → 422
- `ValueError` → 400
- `HTTPException` → pass-through status
- `Exception` (catch-all) → 500

No 502 or 503 code is ever emitted. Dependency failures surface as 500 if they reach the HTTP layer, but the async scheduler intercepts most write-path failures before they reach HTTP.

### Silent excepts inventory
`single_cube.py:490-493`: bare `except Exception: return "sync"` — low risk, harmless default.  
`mem_scheduler/task_schedule_modules/dispatcher.py:238,263`: marks tasks as `"failed"` in the status tracker but does **not** retry, requeue, or dead-letter. Failed async tasks are silently discarded after logging.

### Embedder load path
`SenTranEmbedder.__init__` calls `SentenceTransformer(model_name_or_path, trust_remote_code=True)` inline at server startup — no lazy load, no fallback. If the model is unreadable, server startup fails with an unhandled Python exception before the HTTP listener binds.

---

## Probe Results

### 1. LLM Provider Outage (DeepSeek fine-mode extraction)

**Method:** The server runs in `ASYNC_MODE=async`. Memory writes queue a `MEM_READ_LABEL` scheduler task that calls the MemRADER (DeepSeek) for structured extraction. The `/product/add` HTTP 200 is returned before extraction runs.

**Finding:** If DeepSeek fails or times out, the scheduler task is marked `"failed"` via `status_tracker.task_failed()`. The caller-visible response was already 200. The extraction result (structured memories, tags, graph edges) is silently lost. No fallback to fast/raw mode. No retry. No dead-letter queue. The initial `UserMemory` row (raw chat content) survives, but all enriched long-term memory is dropped.

- **Class:** silent-failure / data-loss (partial)
- **Severity:** High
- **Reproducer:** Set `MEMRADER_API_KEY=garbage`, restart server, submit any write in fine mode, observe scheduler status `failed`.
- **Evidence:** Scheduler allstatus API confirmed 0 retries on failure; dispatcher.py:263 calls `task_item.mark_failed(str(e))` with no requeue logic.
- **Remediation:** Add retry-with-backoff (≥3 attempts) in the dispatcher before marking failed; consider falling back to fast/raw mode extraction when LLM is unavailable.

---

### 2. Embedder Failure

**Method (cache chmod):**
```bash
chmod 000 ~/.cache/huggingface/hub/models--sentence-transformers--all-MiniLM-L6-v2/snapshots/
```
Server was running with model already loaded in memory. Write attempted immediately after chmod.

**Result:** Write succeeded (200). The in-process model instance is unaffected by filesystem permission changes after load.

**Method (restart with broken cache):**
After killing the server, the snapshots directory was chmod 000, then the server was restarted.

**Result:** Server started healthy. `SentenceTransformer` found the model via a secondary resolution path (the HuggingFace cache contains multiple copies under `blobs/` that are accessible directly). **However**, this is environment-specific: in a clean deployment with a single cache path, server startup would raise an unhandled `OSError` before binding to the port.

**Method (concurrent writes during embedder failure):**
With no model accessible (theoretical), both writes in flight would race on the same Python exception — no locking around the model load path. Potential for confusing concurrent failure states.

- **Class:** silent-failure (currently) / no-recovery (on clean deploy restart)
- **Severity:** Medium
- **Evidence:** `sentence_transformer.py:22` — `self.model = SentenceTransformer(...)` is bare, no try/except.
- **Remediation:** Wrap model load in try/except; emit a structured startup error and exit(1) with clear message if the model is missing; add a health-check endpoint that validates embedder is ready.

---

### 3. Qdrant Outage + Reconnect

**Reproducer:**
```bash
docker stop qdrant
curl -X POST http://localhost:8001/product/add -H "Authorization: Bearer $KEY" \
  -d '{"user_id":"ceo","mem_cube_id":"ceo-cube","messages":[{"role":"user","content":"V1-RES qdrant-outage-write-test"}]}'
# → HTTP 200 {"code":200,"message":"Memory added successfully","data":[]}

curl -X POST http://localhost:8001/product/search ... # → HTTP 200 with text_mem:[]
docker start qdrant
# Write/search succeeds again after ~8s (Qdrant startup)
```

**Evidence:**
- Write: HTTP 200, `data: []` — memory accepted but vector not stored. The async scheduler's Qdrant upsert silently fails when the container is down.
- Search: HTTP 200, `text_mem: []` — no error surfaced, just empty results.
- Reconnect: Automatic. The Qdrant Python client creates a new HTTP connection per request; no session state is held. After `docker start qdrant`, the next write/search succeeded without server restart.

**Data consistency:** Memories written during Qdrant outage are **not recoverable** — the scheduler task is marked failed and discarded. SQLite retains the raw message but the structured extraction is lost.

- **Class:** silent-failure / data-loss
- **Severity:** Critical
- **Remediation:** Return HTTP 503 (degraded) when Qdrant is unreachable. Add a write-ahead buffer or at-least-once delivery queue for the async extraction tasks. Expose a `/health/deps` endpoint that reports Qdrant/Neo4j reachability.

---

### 4. Neo4j Outage + Reconnect

**Reproducer:**
```bash
docker stop neo4j-docker
# Same write + search pattern as Qdrant probe
```

**Result:** Identical to Qdrant: HTTP 200 on write, HTTP 200 with empty results on search. No 503. Silent data loss. Auto-reconnect after `docker start neo4j-docker`.

**Tree-memory operations:** TreeTextMemory uses Neo4j for graph structure (`add_node`, `add_edge`). When Neo4j is down, these calls fail silently in the async scheduler path. The tree structure is not rebuilt after reconnect.

- **Class:** silent-failure / data-loss
- **Severity:** Critical
- **Evidence:** Same as Qdrant. `neo4j.py` has no retry/timeout/circuit-breaker.
- **Remediation:** Same as Qdrant — 503 on write when Neo4j unreachable, durable task queue.

---

### 5. SQLite Corruption Detection

**Configuration observed:**
```
PRAGMA journal_mode; → delete
PRAGMA busy_timeout; → 0
```

**Note on storage architecture:** SQLite (`~/.memos/data/memos_users.db`) stores only user accounts and cube associations. The actual memory payload lives in Neo4j + Qdrant. A corrupted `memos_users.db` would make all user lookups fail (500 on every request) but would not destroy memory content.

**Controlled corruption test:** `~/.memos/data/memos.db` (a phantom/empty file) was found at the expected path with 0 bytes — this is a stale empty file, not the live DB. The live users DB (`memos_users.db`) was not corrupted.

**Behavior with empty/new DB:** Server starts and initialises SQLite schema from scratch. No corruption detection logic in source.

**Busy timeout = 0:** No retry on SQLITE_BUSY. An immediate write from a second connection would return `OperationalError: database is locked` without any wait. This is not currently triggered because async writes are serialized through the scheduler's local queue, but a direct concurrent API call path could hit it.

- **Class:** no-recovery (corrupted DB → 500 storm), silent-failure (SQLITE_BUSY unhandled)
- **Severity:** Medium
- **Remediation:** Set `PRAGMA busy_timeout = 5000` (5s). Add startup DB integrity check (`PRAGMA integrity_check`). Document the DB split (users vs. memory) so ops knows Neo4j/Qdrant are the critical stores.

---

### 6. SQLite WAL Recovery

**Journal mode:** `DELETE` (not WAL). After `kill -9`, no `-wal` or `-shm` artifacts were found. The users DB uses DELETE mode which holds an exclusive lock during each write transaction and releases it on commit. Kill-9 during a write leaves the DB in a clean state (uncommitted transaction rolled back by SQLite on next open).

**WAL-specific finding:** Because WAL is not enabled, there is no concurrent reader/writer support. All writes to `memos_users.db` are serialized with an exclusive lock.

- **Class:** acceptable (DELETE mode is safe for single-writer patterns)
- **Severity:** Low
- **Evidence:** `PRAGMA journal_mode → delete`, no WAL files present post-kill.
- **Remediation:** Enable WAL mode (`PRAGMA journal_mode = WAL`) for better read concurrency. Unlikely to matter at current load since SQLite only holds user auth data.

---

### 7. Concurrent-Write Handling (SQLITE_BUSY + Rate Limiting)

**20 parallel writes (single agent):** All 20 returned HTTP 200 in 524ms total. No SQLITE_BUSY. The async scheduler serializes actual DB writes, so the concurrent HTTP layer never contends on SQLite directly.

**100 parallel writes (single agent):** ~99 returned HTTP 429 "Too many requests", 1 returned HTTP 200.

**Root cause — rate limiter key extraction bug:**
```python
# rate_limit.py:62
if auth_header.startswith("krlk_"):
    return f"ratelimit:key:{auth_header[:20]}"
# Falls through to IP-based key for all other prefixes
```
Agent API keys use `ak_` prefix; the `krlk_` branch is never taken. All agents on the same host (127.0.0.1) share a single IP-keyed rate-limit bucket of **100 requests per 60 seconds**. In a multi-agent deployment where CEO, research-agent, and email-marketing-agent all run locally, they collectively consume one shared bucket.

- **Class:** cascading-failure (one busy agent can starve all others)
- **Severity:** High
- **Evidence:** `rate_limit.py:62` — `krlk_` prefix never matches `ak_*` keys. 100-write burst test produced 99× HTTP 429.
- **Reproducer:** `for i in $(seq 1 100); do curl ... -H "Authorization: Bearer ak_..." & done; wait`
- **Remediation:** Change `_get_client_key` to handle `ak_` prefix: `if auth_header.lower().startswith("bearer ak_"): return f"ratelimit:key:{auth_header[7:27]}"`. Per-agent rate limiting prevents one agent from starving others.

---

### 8. Config Malformed / Perms Enforcement

#### Finding 8a: Missing agents-auth.json → complete service lockout (Critical)

At audit start, `MEMOS_AGENT_AUTH_CONFIG=/home/openclaw/Coding/Hermes/agents-auth.json` pointed to a file that had been renamed to `.archived`. With `MEMOS_AUTH_REQUIRED=true`, the `AgentAuthMiddleware` loaded an empty key registry and every `/product/*` request returned HTTP 401.

```
GET /admin/health → {"auth_config_exists": false, "auth_config_path": null}
POST /product/add → {"detail": "Invalid or unknown agent key."} 401
```

The server was healthy and running but completely inaccessible to all agents. No alert, no log-level ERROR distinguishable from normal auth failures, no `/health` degradation.

- **Class:** wedge (service inaccessible without restart)
- **Severity:** Critical
- **Reproducer:** `mv agents-auth.json agents-auth.json.bak` while server is running.
- **Remediation:** On auth config file-not-found, emit a `CRITICAL` log and expose `healthy: false` in `/health`. Consider falling back to `AUTH_REQUIRED=false` with a stern warning rather than locking out all agents.

#### Finding 8b: Non-UTF8 byte in .env — silent empty value

```bash
echo -e "KEY=hello\x80world" >> .env
# bash source: KEY="" (value silently becomes empty string)
```
The server starts but the affected env var is silently empty. No parse error, no startup warning.

- **Class:** silent-failure (misconfiguration undetectable)
- **Severity:** Low
- **Remediation:** Add a config validation step at startup that checks all required env vars are non-empty.

#### Finding 8c: agents-auth.json world-readable (664)

The BCrypt hash file is mode 664 (group-readable). The middleware does not enforce any minimum permission.

- **Class:** leak (hash exposure to group members)
- **Severity:** Low
- **Remediation:** `chmod 600 agents-auth.json` at provisioning time; add a file-permissions check in `AgentAuthMiddleware._load_config`.

---

### 9. Process Crash + Restart Consistency

**Method:** `kill -9 $MEMOS_PID` while a `/product/add` request was in flight.

**Results:**
- In-flight HTTP request: connection reset → HTTP status 000 (no response)
- In-flight async scheduler task: lost (task was queued to in-process scheduler, which died)
- Server: did not auto-restart (no supervisor)
- Manual restart: `bash start-memos.sh` brought the server back in ~6 seconds
- Post-restart state: clean, no corruption

**Process supervisor state:**
```
memos.service: inactive (dead) since 2026-04-25 12:13:52, exit code 1/FAILURE
supervisord: not present
@reboot cron: present (restarts on machine reboot only, not on crash)
```

The systemd unit itself exited with failure and was not restarted by systemd (no `Restart=on-failure` directive).

- **Class:** no-recovery (crash → manual intervention required)
- **Severity:** Critical
- **Reproducer:** `kill -9 $(pgrep -f memos.api.server_api)`
- **Remediation:** Fix the systemd unit with `Restart=on-failure; RestartSec=5`. Or add `supervisord` config. The @reboot cron is not sufficient for production reliability.

---

### 10. Soft-Delete Teardown Collisions

**Reproducer:**
```bash
# 1. Write memory M with content C
# 2. Soft-delete M → response: {"deleted": ["<id>"]}
# 3. Write identical content C again
# Response: {"code":200,"message":"Memory added successfully","data":[]}  ← data: [] !
```

The dedup system (cosine similarity threshold 0.90) checks for near-duplicate vectors including soft-deleted records. Re-ingesting identical content after a soft-delete silently no-ops — the memory ID is not returned, the content is not stored.

This means: an operator who soft-deletes a memory and then tries to re-add it (e.g., after correction) silently gets no storage. There is no caller-visible indication that dedup suppressed the write.

- **Class:** silent-failure / data-loss
- **Severity:** Medium
- **Evidence:** Write returned `data: []` after soft-delete/re-add of identical content. Dedup threshold `MOS_DEDUP_THRESHOLD=0.90` in `.env`.
- **Remediation:** Exclude soft-deleted (`is_active=False` / `status=deleted`) records from dedup candidate pool, or return a specific response code/message when a write is suppressed by dedup.

---

### 11. Hub / Cross-Agent Sync Resilience

`hub-sync.py` (`scripts/migration/hub-sync.py`) is a **one-shot migration script**, not a running daemon. It pushes memtensor traces to the v1.0.3 hub using a SQLite watermark state file.

**Failure behavior:** On HTTP error or exception, the function logs to stderr and returns exit code 2. No retry, no local queue, no back-pressure. Caller (cron or manual) is responsible for retry.

No continuously-running hub-sync daemon was found. No `hub-sync.py` or equivalent service is wired to the live server path — there is no sender/receiver pair to kill in the current deployment.

- **Class:** no-recovery (script-level only; no daemon resilience)
- **Severity:** Low (not in production hot path)
- **Evidence:** `scripts/migration/hub-sync.py` — `except Exception: ... return 2`
- **Remediation:** If hub-sync becomes a production path, convert to a retry-loop daemon with exponential backoff and local SQLite queue buffer.

---

### 12. Hermes Plugin Retry / Queue

The `memos-plugin` adapter (`adapters/hermes/memos_provider/__init__.py`) makes synchronous JSON-RPC calls to the MemOS server. On failure:

```python
except Exception as err:
    logger.debug("MemOS: queue_prefetch failed — %s", err)
```

`logger.debug` — the failure is invisible unless debug logging is enabled. No retry, no local offline buffer, no degraded-mode signal to the agent.

**2s timeout:** Request simply fails with connection timeout → silently dropped.  
**60s timeout:** Same behaviour, longer wait.  
**Port 8001 blocked:** The iptables probe could not be run (non-root), but source analysis confirms: `queue_prefetch` runs on a background thread; if the RPC call raises, the exception is caught and logged at DEBUG level with no further action. The agent continues running with no memory capture for that turn.

- **Class:** silent-failure
- **Severity:** High (memory capture silently disabled during any server unavailability)
- **Evidence:** `memos_provider/__init__.py:220` — `logger.debug("MemOS: queue_prefetch failed — %s", err)`
- **Remediation:** Promote to `logger.warning`. Add a local in-memory ring buffer (last N turns) that flushes when the server reconnects. Surface degraded state to the agent via a status method.

---

### 13. Disk-Full / FD-Exhaustion Behaviour

**Disk state:** 93% full — 7.9GB free on 108GB volume. This is borderline; a large batch write run could exhaust remaining space.

**ENOSPC handling:** No `ENOSPC` or "no space left on device" handling found in MemOS source. A disk-full condition during a Neo4j / Qdrant flush would cause those containers to crash (Docker volume exhaustion). The MemOS server itself would receive an unhandled connection error from both deps and return HTTP 500.

**FD exhaustion probe:**
```python
# Opened 200 sockets to 127.0.0.1:8001
# Health check with 200 open connections → still healthy
```
Server survived 200 simultaneous open (idle) connections. OS-level FD limit is not the bottleneck at this scale.

- **Class:** cascading-failure (disk-full → dep crash → 500 storm); acceptable (FD)
- **Severity:** High (disk), Low (FD)
- **Evidence:** `df -h /` → 93% full. No ENOSPC guard in source. 200-socket test passed.
- **Remediation:** Add disk-space monitoring alert at 85% / 90%. Add log rotation for `~/.hermes/logs/`. Consider pruning old Qdrant snapshots and Neo4j transaction logs.

---

## Summary Table

| Area | Score 1–10 | Key findings |
|------|-----------|--------------|
| LLM (DeepSeek) outage handling | 4 | Silent data loss in async scheduler; no retry, no fallback to fast mode |
| Embedder failure handling | 5 | Running server unaffected; restart with missing model = unhandled crash |
| Qdrant outage + reconnect | 2 | Write returns 200 silently; vector data lost; no 503; auto-reconnect works |
| Neo4j outage + reconnect | 2 | Identical to Qdrant; tree structure lost silently; auto-reconnect works |
| SQLite corruption detection | 5 | SQLite not primary store; busy_timeout=0; no integrity check on startup |
| SQLite WAL recovery | 6 | DELETE mode; clean kill-9 recovery; no WAL = no concurrency benefit |
| Concurrent-write handling (SQLITE_BUSY) | 4 | Rate limiter key-prefix bug → all agents share IP bucket; 100-burst → 99× 429 |
| Config malformed / perms enforcement | 3 | Missing auth file = silent lockout; no /health signal; 664 hash file |
| Process crash + restart consistency | 2 | No supervisor; kill -9 = manual restart; systemd unit dead |
| Soft-delete teardown collisions | 3 | Re-add after soft-delete silently no-ops due to dedup threshold |
| Hub / cross-agent sync resilience | 5 | Migration script only; no running daemon; no retry/queue |
| Hermes plugin retry / queue | 3 | All network failures silently dropped at DEBUG log level |
| Disk-full / FD-exhaustion behaviour | 4 | Disk at 93%; no ENOSPC guard; FD exhaustion survived |

**Overall resilience score (MIN): 2**

---

## Final Judgement

MemOS v1 cannot survive a typical production day with even a single transient dependency outage without silent data loss. The two most dangerous failure modes are (1) Qdrant or Neo4j going down — writes return 200 while silently dropping all structured memory extraction, giving agents a false confidence that their memory was captured — and (2) the complete absence of a process supervisor meaning any crash requires manual intervention. Together these mean an unattended 24-hour run will eventually result in both data loss and prolonged downtime.

The system's async architecture makes these failures particularly insidious: the HTTP layer reports success before the extraction pipeline runs, so callers cannot distinguish a successful write from a silently-failed one. The three lowest-scoring areas (Qdrant/Neo4j silent data loss, process crash no-recovery) are all **Critical** severity and should be addressed before any production promotion. Priority fixes: (1) return HTTP 503 when either vector/graph dep is unreachable; (2) add `Restart=on-failure` to the systemd unit or deploy supervisord; (3) fix the rate limiter key-prefix bug so agents are isolated.
