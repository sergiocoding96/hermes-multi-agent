# MemOS Security Remediation Report

**Date:** 2026-04-07
**Auditor:** Claude Code (zero-knowledge audit)
**System:** MemOS v1.0.1 running at localhost:8001

---

## Executive Summary

The initial audit on 2026-04-06 scored the system **2/10** for production-readiness.
Infrastructure-level fixes have been applied (database auth, network binding, data path).
However, **application-level authorization is still missing on most endpoints**, meaning any
authenticated agent can read, delete, or modify any other agent's memories. Current score: **5/10**.

---

## Status of Original Findings

### Fixed (7 of 15)

| ID | Finding | Evidence of Fix |
|----|---------|-----------------|
| CRIT-1 | Qdrant unauthenticated | `QDRANT_API_KEY` set, bound to 127.0.0.1 |
| CRIT-2 | Neo4j default password | Password changed, old creds rejected, bound to 127.0.0.1 |
| CRIT-4 (partial) | Services on 0.0.0.0 | Qdrant/Neo4j/SearXNG now localhost-only |
| HIGH-1 | Auth disabled | `MEMOS_AUTH_REQUIRED=true` |
| HIGH-5 | Root-owned uvicorn :8000 | Process no longer running |
| MED-1 | Auth headers logged | `request_context.py` filters `authorization`/`cookie` |
| MED-5 | Data in /tmp | `MOS_CUBE_PATH=/home/openclaw/.memos/data` |

### Still Open (8 of 15)

| ID | Severity | Finding | Location |
|----|----------|---------|----------|
| CRIT-3 | CRITICAL | `delete_memory_by_record_id` and `recover_memory_by_record_id` — no cube-level authorization. Any authenticated agent can delete/recover any cube's memories | `server_router.py:406-442` |
| HIGH-2 | HIGH | `get_all`, `get_memory`, `get_memory/{id}`, `get_memory_by_ids`, `get_memory_dashboard` — no `user_manager` access check. Any authenticated agent reads any cube | `memory_handler.py` (all functions), `server_router.py:282-326,446-452` |
| HIGH-3 | HIGH | `RateLimitMiddleware` exists but is not registered | `server_api.py` — missing `app.add_middleware(RateLimitMiddleware)` |
| MED-2 | MEDIUM | `add_handler.py` logs full request body at INFO level | `add_handler.py:57` — `[DIAGNOSTIC]` log line |
| MED-3 | MEDIUM | `exist_mem_cube_id` allows any authenticated agent to enumerate all cube IDs | `server_router.py:381-392` |
| MED-4 | MEDIUM | `scheduler/wait/stream` accepts unbounded timeout for any user | `server_router.py:191-204` |
| MED-6 | MEDIUM | `admin_router.py` is dead code — no key management API available | `admin_router.py` never imported in `server_api.py` |
| LOW | LOW | MemOS API on 0.0.0.0:8001, Camofox on *:9377 | `server_api.py:66`, Camofox config |

---

## Remediation Plan

### Phase 1: Critical Authorization Fixes (do first)

These are the highest-impact changes — they close cross-agent data access.

#### 1.1 Add auth + cube access checks to `delete_memory_by_record_id` and `recover_memory_by_record_id`

**File:** `/home/openclaw/.local/lib/python3.12/site-packages/memos/api/routers/server_router.py`

Both endpoints call `graph_db` directly with no authorization. Fix:

```python
# In delete_memory_by_record_id (line ~411)
from memos.api.middleware.agent_auth import get_authenticated_user

def delete_memory_by_record_id(memory_req: DeleteMemoryByRecordIdRequest):
    authenticated = get_authenticated_user()
    if authenticated is not None and authenticated != memory_req.mem_cube_id:
        raise HTTPException(
            status_code=403,
            detail=f"Key authenticated as '{authenticated}' cannot delete from cube '{memory_req.mem_cube_id}'"
        )
    # Also check user_manager
    user_manager = dependencies.user_manager  # need to expose this
    if user_manager and not user_manager.validate_user_cube_access(memory_req.mem_cube_id, memory_req.mem_cube_id):
        raise HTTPException(status_code=403, detail="Access denied")
    # ... existing logic
```

Same pattern for `recover_memory_by_record_id`.

**Effort:** ~30 min
**Risk:** Low — additive check, no behavior change for legitimate callers

#### 1.2 Add auth + cube access checks to all `memory_handler` endpoints

**Files:**
- `server_router.py` — routes for `get_all`, `get_memory`, `get_memory/{id}`, `get_memory_by_ids`, `get_memory_dashboard`
- `memory_handler.py` — standalone functions need access to `user_manager`

Two approaches (pick one):

**Option A (recommended):** Convert `memory_handler.py` to a class-based `MemoryHandler(BaseHandler)` like `SearchHandler`/`AddHandler`, inject `user_manager` via `HandlerDependencies`, add auth checks in each method.

**Option B (quick):** Pass `user_manager` and `authenticated_user` as parameters from each router function:

```python
# In server_router.py get_all_memories route
@router.post("/get_all", ...)
def get_all_memories(memory_req: GetMemoryPlaygroundRequest):
    authenticated = get_authenticated_user()
    target_cube = memory_req.mem_cube_ids[0] if memory_req.mem_cube_ids else memory_req.user_id
    if authenticated is not None and authenticated != memory_req.user_id:
        raise HTTPException(status_code=403, detail="Spoofing not allowed")
    user_mgr = dependencies.user_manager
    if user_mgr and not user_mgr.validate_user_cube_access(memory_req.user_id, target_cube):
        raise HTTPException(status_code=403, detail="Access denied")
    # ... existing logic
```

Apply to: `get_all_memories`, `get_memories`, `get_memory_by_id`, `get_memory_by_ids`, `get_memories_dashboard`

Note: `get_memory_by_id` and `get_memory_by_ids` take memory IDs with no user context — need to either:
- Add a required `user_id` parameter and validate cube ownership, or
- Look up the memory's owning cube and check access against the authenticated user

**Effort:** ~2 hours (Option B), ~4 hours (Option A)
**Risk:** Medium — `get_memory_by_id` API change may break existing callers

### Phase 2: High-Priority Hardening

#### 2.1 Register RateLimitMiddleware

**File:** `server_api.py`

```python
from memos.api.middleware.rate_limit import RateLimitMiddleware
# Add BEFORE other middleware (outermost = runs first)
app.add_middleware(RateLimitMiddleware)
app.add_middleware(AgentAuthMiddleware)
app.add_middleware(RequestContextMiddleware, source="server_api")
```

Also set reasonable env vars:
```
RATE_LIMIT=60        # 60 requests per window
RATE_WINDOW_SEC=60   # 1 minute window
```

**Effort:** 15 min
**Risk:** Low

#### 2.2 Remove diagnostic logging in add_handler

**File:** `add_handler.py:57`

Delete or downgrade to DEBUG:
```python
# REMOVE this line:
self.logger.info(f"[DIAGNOSTIC] ... Full request: {add_req.model_dump_json(indent=2)}")
# REPLACE with:
self.logger.debug(f"[AddHandler] add_memories called for user_id={add_req.user_id}")
```

**Effort:** 5 min
**Risk:** None

### Phase 3: Medium-Priority Improvements

#### 3.1 Restrict `exist_mem_cube_id` to return only cubes the caller can access

Add spoof check: only return existence info for cubes the authenticated user has access to.

#### 3.2 Cap `scheduler/wait/stream` timeout and validate caller

```python
MAX_TIMEOUT = 300  # 5 minutes max
timeout_seconds = min(timeout_seconds, MAX_TIMEOUT)
```

Add check: `user_name` must match authenticated user (or be a cube they can access).

#### 3.3 Bind MemOS API to 127.0.0.1

Change `server_api.py:66`:
```python
uvicorn.run("memos.api.server_api:app", host="127.0.0.1", port=args.port, workers=args.workers)
```

If Tailscale or external access is needed, use a reverse proxy (nginx/Caddy) with TLS.

#### 3.4 Bind Camofox to 127.0.0.1

Update Camofox launch config to listen on localhost only.

### Phase 4: Nice-to-Have

#### 4.1 Register admin_router for key management

```python
# In server_api.py or a separate admin app
from memos.api.routers.admin_router import router as admin_router
app.include_router(admin_router)
```

Requires PostgreSQL setup or migration to SQLite-based key management.

#### 4.2 Move API keys to secret manager or encrypted env

Consider `sops`, `age`, or at minimum `chmod 600` on `.env` and `agents-auth.json`.

---

## Implementation Order

```
Week 1 (Critical):
  Day 1: Phase 1.1 — auth on delete/recover endpoints
  Day 1: Phase 1.2 — auth on memory_handler endpoints (Option B first, refactor to Option A later)
  Day 2: Phase 2.1 — register rate limiter
  Day 2: Phase 2.2 — remove diagnostic logging

Week 2 (Hardening):
  Day 3: Phase 3.1-3.2 — restrict enumeration + cap SSE
  Day 3: Phase 3.3-3.4 — bind to localhost
  Day 4: Phase 4.1-4.2 — admin router + secret management

Verification:
  Re-run the adversarial test suite after each phase
  Confirm 401/403 on all cross-agent access attempts
```

---

## Verification Checklist

After fixes, each of these must return 401 or 403:

```bash
# No auth → 401
curl -s -X POST localhost:8001/product/get_all -H "Content-Type: application/json" \
  -d '{"user_id":"ceo","memory_type":"text_mem"}'

# Agent A key accessing Agent B cube → 403
curl -s -X POST localhost:8001/product/get_all -H "Content-Type: application/json" \
  -H "Authorization: Bearer ak_<research-agent-key>" \
  -d '{"user_id":"ceo","memory_type":"text_mem"}'

# Delete cross-cube → 403
curl -s -X POST localhost:8001/product/delete_memory_by_record_id \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ak_<research-agent-key>" \
  -d '{"mem_cube_id":"ceo","record_id":"any","hard_delete":false}'

# Direct DB access → connection refused or auth error
curl -s http://localhost:6333/collections  # should fail (API key required)
curl -s http://10.x.x.x:6333/collections  # should fail (not listening)

# Rate limit → 429 after N requests
for i in $(seq 1 70); do curl -s -o /dev/null -w "%{http_code}\n" ...; done
```
