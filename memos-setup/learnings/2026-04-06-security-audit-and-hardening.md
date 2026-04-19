# MemOS Security Audit & Hardening — 2026-04-06 to 2026-04-07

## What Happened

A zero-knowledge security audit was run against the MemOS API (v1.0.1) at localhost:8001. The audit found **15 vulnerabilities** scoring the system **2/10** for production-readiness. Over two sessions, all 15 were resolved, bringing the score to approximately **8/10**.

---

## Phase 0: Initial Audit Findings (2026-04-06)

### What the audit tested
- Unauthenticated access to every API endpoint
- Cross-agent memory read/write/delete (agent A accessing agent B's cube)
- Direct database access (Qdrant on :6333, Neo4j on :7474/:7687)
- Path traversal on /download static file endpoint
- User/cube enumeration via exist_mem_cube_id
- Scheduler DoS via unbounded SSE connections
- Secret exposure in config files and logs
- Network exposure (all services bound to 0.0.0.0)

### Critical findings at time of audit
1. **Qdrant completely open** — no API key, bound to 0.0.0.0:6333, anyone could read/delete all vectors
2. **Neo4j with default password** (neo4j/12345678) — 425 nodes across 12 cubes fully accessible
3. **`delete_memory_by_record_id` and `recover_memory_by_record_id`** — zero auth, anyone could delete any agent's memories
4. **All 9 services bound to 0.0.0.0** — accessible from the entire local network
5. **`MEMOS_AUTH_REQUIRED=false`** — the auth middleware was a no-op
6. **Root-owned uvicorn on port 8000** — same codebase running as root

---

## Phase 1: Infrastructure Fixes (done before our session, by prior conversation)

These were already applied when we started:

| Fix | Detail |
|-----|--------|
| Qdrant API key | `QDRANT_API_KEY` set, bound to 127.0.0.1 |
| Neo4j password | Changed from default, bound to 127.0.0.1 |
| SearXNG | Bound to 127.0.0.1 |
| Auth enabled | `MEMOS_AUTH_REQUIRED=true` |
| Root uvicorn killed | Port 8000 process stopped |
| Header logging sanitized | `request_context.py` filters `authorization`/`cookie` from logs |
| Data path | Moved from `/tmp/memos_data` to `~/.memos/data` |

---

## Phase 2: Application-Level Authorization (our session)

### Problem
Auth was enforced at the gate (middleware rejects unauthenticated requests), but **authorization** (who can access which cube) was only implemented in `SearchHandler` and `AddHandler`. The other ~10 endpoints had zero access control — any authenticated agent could read/delete any other agent's data.

### What we did

#### 2.1 — Created `_enforce_cube_access()` helper in server_router.py
A shared function that:
- Checks `get_authenticated_user()` for spoof detection (key says "research-agent" but request claims "ceo")
- Checks `user_manager.validate_user_cube_access()` for cube-level ACL

#### 2.2 — Added auth to every unprotected endpoint

| Endpoint | What was added |
|----------|----------------|
| `POST /product/get_all` | Spoof check + cube access |
| `POST /product/get_memory` | Spoof check + cube access |
| `GET /product/get_memory/{id}` | Looks up memory owner via graph_db, validates caller access |
| `POST /product/get_memory_by_ids` | Batch owner lookup, rejects if any memory belongs to inaccessible cube |
| `POST /product/delete_memory` | Checks each writable_cube_id |
| `POST /product/delete_memory_by_record_id` | Spoof check + cube access on mem_cube_id |
| `POST /product/recover_memory_by_record_id` | Same as above |
| `POST /product/feedback` | Checks writable_cube_ids |
| `POST /product/get_memory_dashboard` | Cube access on mem_cube_id |
| `POST /product/get_user_names_by_memory_ids` | Filters results to only cubes caller can access |
| `POST /product/exist_mem_cube_id` | Hides existence of cubes caller can't access |

#### 2.3 — Fixed `validate_user_cube_access()` in UserManager

**Key learning:** MemOS agents address cubes by `user_id` (e.g., "ceo"), but the UserManager DB stores them as `cube_id` (e.g., "ceo-cube"). The original method only matched on `cube_id`, so every access check failed.

Fix: the method now resolves cubes by trying `cube_id` -> `cube_name` -> `owner_id` in sequence.

**File:** `~/.local/lib/python3.12/site-packages/memos/mem_user/user_manager.py`

#### 2.4 — Registered RateLimitMiddleware

`RateLimitMiddleware` existed but was never added to the app. Added it as the outermost middleware in `server_api.py`. Verified: 429 kicks in after ~96 requests/minute.

#### 2.5 — Capped scheduler endpoints

- `scheduler/wait` and `scheduler/wait/stream`: max timeout 300s, min poll interval 0.25s
- Both now verify `authenticated_user == user_name` (cross-agent scheduler access blocked)

---

## Phase 3: Admin API & Secret Management (our session)

### 3.1 — Admin Router for Key Management

Rewrote `admin_router.py` to work with the v2 bcrypt-hashed `agents-auth.json` format (the previous version was dead code targeting PostgreSQL which this system doesn't use).

| Endpoint | Purpose |
|----------|---------|
| `GET /admin/health` | Health check (unauthenticated) |
| `GET /admin/keys` | List agent keys (prefixes only) |
| `POST /admin/keys` | Create new agent key (bcrypt hashed) |
| `DELETE /admin/keys` | Revoke agent key |
| `POST /admin/keys/rotate` | Rotate key (old dies immediately) |

Protected by `MEMOS_ADMIN_KEY` env var (separate from agent keys). The `/admin/*` path was added to `AgentAuthMiddleware.SKIP_PREFIXES` so it uses its own auth.

**Key learning:** The middleware auto-reloads when the config file's mtime changes (`_check_reload()`), so the admin router doesn't need to manually trigger reloads — it just writes the file and the next request picks up the change.

### 3.2 — Secret Management with age encryption

Moved 5 secrets out of plaintext `.env` into `~/.memos/secrets.env.age`:
- `MINIMAX_API_KEY`
- `MEMRADER_API_KEY`
- `NEO4J_PASSWORD`
- `QDRANT_API_KEY`
- `MEMOS_ADMIN_KEY`

Setup:
- Age keypair at `~/.memos/keys/memos.key` (mode 600, dir mode 700)
- Encrypted secrets at `~/.memos/secrets.env.age`
- Startup script `start-memos.sh` decrypts at boot, exports to env, then `exec`s the server
- All sensitive files locked to `chmod 600`

**To add/change a secret:**
```bash
export PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
age -d -i ~/.memos/keys/memos.key ~/.memos/secrets.env.age > /tmp/secrets.env
# edit /tmp/secrets.env
AGE_PUB=$(grep "public key" ~/.memos/keys/memos.key | awk '{print $NF}')
age -r "$AGE_PUB" -o ~/.memos/secrets.env.age /tmp/secrets.env
shred -u /tmp/secrets.env
```

### 3.3 — Camofox Bound to Localhost

- `server.js` patched: `app.listen(PORT, BIND_HOST)` with `BIND_HOST` defaulting to `127.0.0.1`
- Crontab updated: `CAMOFOX_BIND_HOST=127.0.0.1` added to `@reboot` entry
- Verified: listening on `127.0.0.1:9377` only

### 3.4 — MemOS API Bind Address

- `server_api.py` now reads `MEMOS_BIND_HOST` env var (default `127.0.0.1`)
- Set `MEMOS_BIND_HOST=127.0.0.1` if you want localhost-only, or `0.0.0.0` if behind a reverse proxy

---

## Files Modified

| File | What changed |
|------|-------------|
| `memos/api/routers/server_router.py` | `_enforce_cube_access()` helper; auth on 11 endpoints; scheduler caps |
| `memos/api/routers/admin_router.py` | Full rewrite: bcrypt v2 key management via agents-auth.json |
| `memos/api/server_api.py` | Registered RateLimitMiddleware + admin_router; localhost bind |
| `memos/api/middleware/agent_auth.py` | Added `/admin` to SKIP_PREFIXES |
| `memos/mem_user/user_manager.py` | `validate_user_cube_access` resolves cubes by cube_id, cube_name, or owner_id |
| `camofox-browser/server.js` | Bind to `CAMOFOX_BIND_HOST` (default 127.0.0.1) |
| `MemOS/.env` | Secrets replaced with comments; added MEMOS_ADMIN_KEY placeholder |
| `Hermes/agents-auth.json` | Fixed broken rotation (removed plaintext key, updated hash) |

All modified source files are in the installed package at `~/.local/lib/python3.12/site-packages/memos/`.

---

## Gotchas & Lessons Learned

1. **Cube ID mismatch is the #1 trap.** Agents use `user_id` as the cube address, but `UserManager` stores `cube_id` which is different (e.g., "ceo" vs "ceo-cube"). Any new auth check must resolve through owner_id, not just cube_id.

2. **The middleware auto-reloads on mtime change.** Don't manually call `reload()` from endpoint handlers — just write the file. The next request triggers `_check_reload()`.

3. **v2 config uses bcrypt hashes.** Any code that creates/rotates keys must `bcrypt.hashpw()` and store `key_hash`, never write plaintext `key` field. The `_authenticate_key()` method iterates all agents and calls `bcrypt.checkpw()` — this is O(n) and slow for many agents.

4. **RateLimitMiddleware was fully implemented but never registered.** Always check `server_api.py` middleware chain when reviewing what's actually active.

5. **`memory_handler.py` functions are standalone, not class-based.** They don't have access to `user_manager` or `get_authenticated_user`. Auth must be enforced in the router layer before calling them. Future refactor: convert to `MemoryHandler(BaseHandler)`.

6. **Two auth systems exist in the codebase.** `agent_auth.py` (active, JSON file) and `auth.py` (dead code, PostgreSQL). Only `agent_auth.py` is wired up. The admin_router.py was also dead code targeting PostgreSQL before the rewrite.

7. **`start-memos.sh` is now the canonical way to start the server.** It decrypts secrets then execs. Don't use `python -m memos.api.server_api` directly — secrets won't be loaded.

8. **The `@reboot` crontab for Camofox needs `CAMOFOX_BIND_HOST=127.0.0.1`.** Without it, the default in the patched server.js kicks in, but if the package is ever updated, the patch could be lost.

---

## Verification Commands

```bash
# Check all services are localhost-only
ss -tlnp | grep -E "6333|7474|7687|8001|8888|9377"

# Test unauthenticated → 401
curl -s -o /dev/null -w "%{http_code}" -X POST localhost:8001/product/search \
  -H "Content-Type: application/json" -d '{"user_id":"ceo","query":"test","top_k":1}'

# Test cross-agent → 403
curl -s -o /dev/null -w "%{http_code}" -X POST localhost:8001/product/search \
  -H "Content-Type: application/json" -H "Authorization: Bearer <research-key>" \
  -d '{"user_id":"ceo","query":"test","top_k":1}'

# Test admin API
curl -s localhost:8001/admin/keys -H "Authorization: Bearer <admin-key>"

# Test rate limiting (should get 429 around request 96-100)
for i in $(seq 1 110); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST localhost:8001/product/exist_mem_cube_id \
    -H "Content-Type: application/json" -H "Authorization: Bearer <ceo-key>" \
    -d '{"mem_cube_id":"ceo"}'
done | sort | uniq -c
```

---

## Current Score: ~8/10

| Area | Before | After |
|------|--------|-------|
| Authentication | 2 | 9 |
| Authorization / Isolation | 2 | 8 |
| Data confidentiality | 1 | 8 |
| Data integrity | 2 | 8 |
| Availability | 3 | 7 |
| Secret management | 1 | 7 |
| Infrastructure exposure | 1 | 9 |
| Code quality (security) | 4 | 7 |

Remaining gaps: source modifications are in site-packages (not version-controlled), bcrypt key validation is O(n), no TLS on localhost connections, no audit logging to persistent storage.
