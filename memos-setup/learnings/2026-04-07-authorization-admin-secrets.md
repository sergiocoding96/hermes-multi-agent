# Session: Authorization, Admin API & Secret Management — 2026-04-07

## Context
Prior session ran a zero-knowledge security audit (2/10 score, 15 findings). Infrastructure fixes (Qdrant auth, Neo4j password, localhost binding, `MEMOS_AUTH_REQUIRED=true`) were applied before this session. This session closed the remaining 8 application-level gaps.

---

## What We Did

### 1. Endpoint-Level Authorization (Phase 1)

**Problem:** Auth middleware now blocks unauthenticated requests, but any authenticated agent could still read/write/delete any other agent's memories. Only `SearchHandler` and `AddHandler` had cube access checks — the other ~10 endpoints were wide open.

**Solution:** Created `_enforce_cube_access()` in `server_router.py` — a shared helper that checks spoof detection (`get_authenticated_user() != request.user_id`) and cube ACL (`user_manager.validate_user_cube_access()`). Applied it to all 11 unprotected endpoints:

- `get_all`, `get_memory`, `get_memory/{id}`, `get_memory_by_ids`, `get_memory_dashboard` — read access
- `delete_memory`, `delete_memory_by_record_id`, `recover_memory_by_record_id` — write/delete access
- `feedback` — write access
- `exist_mem_cube_id` — hides existence of cubes caller can't access
- `get_user_names_by_memory_ids` — filters results to accessible cubes only

**Critical fix — cube ID mismatch:** `validate_user_cube_access("ceo", "ceo")` was returning `False` because the DB stores `cube_id = "ceo-cube"`, not `"ceo"`. MemOS agents address cubes by `user_id`, not `cube_id`. Fixed `UserManager.validate_user_cube_access()` to resolve cubes by `cube_id` → `cube_name` → `owner_id` in sequence.

### 2. Rate Limiting & Scheduler Hardening (Phase 2)

- **RateLimitMiddleware** existed in code but was never registered. Added to `server_api.py` as outermost middleware. Default: 100 req/60s per IP (in-memory fallback since no Redis).
- **Scheduler wait/stream endpoints:** capped `timeout_seconds` at 300s, `poll_interval` min 0.25s, added cross-agent check (`authenticated_user` must match `user_name`).
- **Diagnostic logging** in `add_handler.py` — was already fixed (no longer dumps full request body).

### 3. Admin Router — Key Management API (Phase 3)

**Problem:** `admin_router.py` was dead code targeting PostgreSQL. This system uses `agents-auth.json` with bcrypt v2 hashes.

**Solution:** Full rewrite of admin_router.py:

| Endpoint | Auth | Purpose |
|----------|------|---------|
| `GET /admin/health` | None | Health check |
| `GET /admin/keys` | Admin key | List keys (prefixes only) |
| `POST /admin/keys` | Admin key | Create key (bcrypt hashed) |
| `DELETE /admin/keys` | Admin key | Revoke key |
| `POST /admin/keys/rotate` | Admin key | Rotate key (old dies immediately) |

- Protected by `MEMOS_ADMIN_KEY` env var (separate from agent keys)
- Added `/admin` to `AgentAuthMiddleware.SKIP_PREFIXES` so admin routes use their own auth
- Keys are bcrypt-hashed before writing to `agents-auth.json`
- Middleware auto-reloads on file mtime change — no manual reload needed

**Bug encountered during implementation:** First rotation attempt wrote a plaintext `key` field alongside the old `key_hash`. The middleware only checks `key_hash` via bcrypt, so the new key didn't work and the old key stayed valid. Fixed by: hashing the new key, writing `key_hash`, removing any plaintext `key` field.

### 4. Secret Management — age Encryption (Phase 3)

Moved 5 secrets from plaintext `.env` to encrypted storage:

```
MINIMAX_API_KEY, MEMRADER_API_KEY, NEO4J_PASSWORD, QDRANT_API_KEY, MEMOS_ADMIN_KEY
```

Setup:
- `age-keygen` → `~/.memos/keys/memos.key` (mode 600)
- Secrets encrypted to `~/.memos/secrets.env.age`
- `.env` now has comment placeholders where secrets were
- `start-memos.sh` decrypts at boot, exports to env, then `exec`s server
- All sensitive files locked to `chmod 600`

### 5. Network Binding (Phase 3)

- **MemOS API:** `server_api.py` now reads `MEMOS_BIND_HOST` (default `127.0.0.1`)
- **Camofox:** Patched `server.js` to bind to `CAMOFOX_BIND_HOST` (default `127.0.0.1`). Updated `@reboot` crontab entry. Restarted process.

---

## Files Modified

| File | Location | Changes |
|------|----------|---------|
| `server_router.py` | `site-packages/memos/api/routers/` | `_enforce_cube_access()`, auth on 11 endpoints, scheduler caps, extracted `user_manager` at module level |
| `admin_router.py` | `site-packages/memos/api/routers/` | Full rewrite: bcrypt v2 key management |
| `server_api.py` | `site-packages/memos/api/` | Registered RateLimitMiddleware + admin_router, localhost bind |
| `agent_auth.py` | `site-packages/memos/api/middleware/` | Added `/admin` to SKIP_PREFIXES |
| `user_manager.py` | `site-packages/memos/mem_user/` | Cube resolution: cube_id → cube_name → owner_id |
| `server.js` | `~/.hermes/.../camofox-browser/` | Bind to CAMOFOX_BIND_HOST |
| `.env` | `~/Coding/MemOS/` | Secrets removed, MEMOS_ADMIN_KEY added |
| `agents-auth.json` | `~/Coding/Hermes/` | Fixed broken rotation entry |
| `start-memos.sh` | `~/Coding/MemOS/` | **New** — decrypt-and-start wrapper |
| `secrets.env.age` | `~/.memos/` | **New** — encrypted secrets |
| `memos.key` | `~/.memos/keys/` | **New** — age keypair |

---

## Key Lessons

1. **Cube ID != User ID.** Agents use `user_id` ("ceo") as the cube address. The UserManager DB stores `cube_id` ("ceo-cube"). Any auth check that queries by `cube_id` alone will fail. Always resolve through owner_id as fallback.

2. **Auth gate != authorization.** `MEMOS_AUTH_REQUIRED=true` only proves the caller has a valid key. It does NOT check which cubes they can access. Every endpoint needs its own `_enforce_cube_access()` call.

3. **v2 config = bcrypt hashes only.** Never write a plaintext `key` field to `agents-auth.json`. The middleware's `_authenticate_key()` calls `bcrypt.checkpw()` against `key_hash`. A plaintext `key` field is ignored and creates confusion.

4. **Middleware auto-reloads on mtime.** `AgentAuthMiddleware._check_reload()` runs on every request. After writing `agents-auth.json`, the next request picks up changes. No need to call `reload()` from handlers.

5. **`RateLimitMiddleware` must be outermost.** It runs before auth so rate-limited attackers can't even attempt key validation. Middleware order in `server_api.py`: RateLimit → AgentAuth → RequestContext.

6. **`start-memos.sh` is now required.** Running `python -m memos.api.server_api` directly will fail — secrets aren't in `.env` anymore. Always use `./start-memos.sh`.

7. **Admin routes need their own auth path.** `/admin/*` is excluded from `AgentAuthMiddleware` via `SKIP_PREFIXES`. The admin router uses `MEMOS_ADMIN_KEY` directly. Don't mix agent keys with admin keys.

8. **Source mods are in site-packages — not version-controlled.** All changes live in `~/.local/lib/python3.12/site-packages/memos/`. A `pip install --upgrade` will overwrite them. These need to be upstreamed or maintained as patches.

---

## Verification (all passing)

```
Unauthenticated access:     9/9 endpoints return 401
Cross-agent access:         6/6 endpoints return 403
Legitimate own-cube access: 6/6 endpoints return 200
CEO cross-read (authorized): 1/1 returns 200
Rate limiting:              429 after ~96 requests
Scheduler caps:             403 on cross-agent, timeout capped at 300s
Admin key rotation:         Old key → 401, new key → 200
Camofox:                    127.0.0.1:9377 only
```
