# MemOS Session 2: From Infrastructure Testing to Native Tool Plugin

## Session Scope (2026-04-06 to 2026-04-07)

Continued from a previous session that had built the core MemOS infrastructure (embedder, MEMRADER, provisioning, profiles). This session focused on stress testing, security hardening, and building a native Hermes plugin to replace curl-based memory operations.

---

## 1. Search Recall Fix (Was 1/12 results, now 5+)

### Root cause
Four compounding filters in the search pipeline were too aggressive:
- `relativity` threshold at 0.20 (vague queries score 0.10-0.25, got filtered)
- Top-K expansion only 3x (not enough candidates before MMR dedup)
- MMR text similarity threshold at 0.92 (too strict)
- MMR exponential penalty starting at 0.90

### Fixes applied
| Parameter | File | Before | After | Env var |
|-----------|------|--------|-------|---------|
| Relativity default | `product_models.py` | 0.20 | 0.05 | — |
| Top-K expansion | `search_handler.py` | 3x hardcoded | 5x | `MOS_SEARCH_TOP_K_FACTOR` |
| Text similarity | `search_handler.py` | 0.92 | 0.85 | `MOS_MMR_TEXT_THRESHOLD` |
| Penalty start | `search_handler.py` | 0.90 | 0.70 | `MOS_MMR_PENALTY_THRESHOLD` |

### Learning
Making search parameters env-configurable instead of hardcoded means tuning without code changes. Always make thresholds configurable when they affect quality.

---

## 2. Cube Isolation (Was 3/10, now 10/10)

### Root cause
`UserManager.validate_user_cube_access()` existed in the codebase but was never called. Any user could read/write any cube by passing its cube_id.

### Fix
Added permission check at the top of `SearchHandler.handle_search_memories()` and `AddHandler.handle_add_memories()`, before any cube view is constructed. Also injected `UserManager()` into `HandlerDependencies` via `component_init.py`.

### Learning
The `mem_cube_id` deprecated field was also tested — it flows through a Pydantic `model_validator` that converts it to `readable_cube_ids`/`writable_cube_ids`, so our guard catches it. The user_id fallback path (when no cube_ids are provided) correctly returns 403 because `user_id != cube_id` in our setup.

---

## 3. Per-Agent API Key Auth

### Design
- Keys stored in `agents-auth.json` (ships with git repo)
- `AgentAuthMiddleware` (Starlette middleware) validates `Authorization: Bearer ak_...` headers
- Authenticated user_id stored in a `ContextVar`
- Handlers check: if key was presented, `user_id` in request body must match the key's identity
- `MEMOS_AUTH_REQUIRED=true` enforces auth on all requests (no passthrough)

### Key insight: trust-based isolation vs real auth
With `MEMOS_AUTH_REQUIRED=false`, the cube isolation only works if callers honestly identify themselves. Anyone can claim `user_id: "ceo"` and read everything. Setting it to `true` closes this gap.

### Evolution during session
The audit session later upgraded the middleware with:
- **bcrypt key hashing** (v2 format in agents-auth.json)
- **Rate limiting** on failed auth (10 failures/60s per IP → 429)
- **Auto-reload** when agents-auth.json changes on disk
- **Router-level `Depends(_require_auth)`** covering ALL `/product/*` routes

---

## 4. Stress Test Evolution (v1 → v2 → v3)

### v1: Confirmation bias
- 9/9 passed, but tests ran against dirty state (50+ pre-existing memories)
- Test 6 (long content) was rewritten to use diverse content instead of fixing extraction
- Only tested 2 endpoints (`/product/add`, `/product/search`)

### v2: Adversarial, clean state
- 12 tests with fresh users/cubes per run, teardown after
- Added auth spoofing tests, bypass path tests, edge cases
- Found the soft-delete collision bug (teardown sets `is_active=False`, next run hits UNIQUE constraint on create, cube stays inactive)
- Fix: unique timestamp prefix per test run

### v3: Zero-knowledge audit
- Gave a fresh Claude Code session zero context: just "there's an API on port 8001, find everything wrong"
- Result: 2/10 production-readiness
- Found 15 vulnerabilities we completely missed: open Qdrant, default Neo4j password, unprotected endpoints, root server on 8000, tokens in logs, data in /tmp

### Learning
**Never test your own security code.** The same reasoning patterns that built the system blind you to its gaps. Zero-knowledge auditing by a fresh session with no hints is the only reliable method.

---

## 5. Security Hardening (Post-Audit)

### CRIT fixes applied
| Finding | Fix |
|---------|-----|
| Qdrant open on 0.0.0.0 | Bound to 127.0.0.1, API key required (`qk_7cbb...`) |
| Neo4j default password | Changed to `n4j_3117d1c...`, bound to 127.0.0.1 |
| Root MemOS on port 8000 | Container removed, port blocked via UFW |
| delete/recover endpoints no auth | Router-level `Depends(_require_auth)` covers ALL routes |
| Data in /tmp | Moved to `~/.memos/data` |
| Bearer tokens in logs | Stripped from `request_context.py` |
| Full request body in logs | Replaced with summary in `add_handler.py` |
| Firecrawl/SearXNG exposed | Docker-compose ports bound to 127.0.0.1 |

### Learning: Qdrant client SSL bug
When `api_key` is set with `host`+`port` (not `url`), the Qdrant Python client defaults to HTTPS. Fix: `client_kwargs["https"] = False` for localhost connections. This was in `memos/vec_dbs/qdrant.py` — upstream only passed `api_key` when using the `url` connection mode.

---

## 6. Blind Audit Test Suite

Created 6 zero-knowledge audit prompts for fresh Claude Code sessions:
1. **Security** — auth, isolation, infrastructure exposure
2. **Functionality** — write, search, extraction, dedup, cross-cube
3. **Resilience** — DB down, restart, concurrent stress, resource exhaustion
4. **Performance** — latency, throughput, bottleneck profiling
5. **Data integrity** — cross-layer consistency (API vs Qdrant vs Neo4j)
6. **Observability** — logging, error messages, health checks, debugging

All at `tests/` in the Hermes repo. Overall score = minimum across all 6 (not average).

---

## 7. Native Tool Plugin (memos_store + memos_search)

### Why
Agents were using curl commands from SKILL.md to talk to MemOS. This leaked API keys into LLM context, wasted ~200 tokens per call, and was error-prone (malformed JSON, wrong headers, forgotten auth).

### Implementation
Created `~/.hermes/plugins/memos-toolset/` with:
- `plugin.yaml` — manifest, requires `MEMOS_API_KEY`, `MEMOS_USER_ID`, `MEMOS_CUBE_ID`
- `schemas.py` — minimal tool schemas (agent sees `content`/`query` only)
- `handlers.py` — HTTP calls with identity injected from env vars, 30s/10s timeouts
- `__init__.py` — registers tools via `ctx.register_tool()`

### Key design decisions
- **Identity from env, not LLM**: `_get_config()` reads env vars at call time. Agent never sees credentials.
- **Per-profile `.env`**: Each Hermes profile gets its own `.env` with `MEMOS_USER_ID`, `MEMOS_CUBE_ID`, `MEMOS_API_KEY`. When Hermes activates a profile, it sets `HERMES_HOME` to the profile dir and loads that `.env`.
- **No startup health check**: If MemOS is down, the tool returns a structured error when called. This avoids disabling tools for an entire session if MemOS is temporarily unavailable.
- **Search results formatted for LLM**: Numbered list with `rank`, `content`, `relevance` — not raw API JSON.
- **No delete tool**: Deletion is admin-only. LLMs shouldn't be able to destroy memories.

### MiniMax key bug
Profile `.env` files replace the global `~/.hermes/.env`. If the profile `.env` only had MEMOS vars, MiniMax key was lost → 401. Fix: include `MINIMAX_API_KEY` and `DEEPSEEK_API_KEY` in every profile's `.env`.

---

## 8. Architecture Summary (End of Session)

```
┌─────────────────────────────────────────────────────────┐
│ Agent (MiniMax M2.7)                                    │
│   calls memos_store() / memos_search()                  │
│   ↓ (plugin injects user_id, cube_id, Bearer key)       │
├─────────────────────────────────────────────────────────┤
│ MemOS API (localhost:8001)                               │
│   AgentAuthMiddleware → validates Bearer key             │
│   Router Depends(_require_auth) → 401 if no key         │
│   Handler spoof check → 403 if key != user_id           │
│   Handler cube check → 403 if user can't access cube    │
├─────────────────────────────────────────────────────────┤
│ MEMRADER (DeepSeek V3) → extracts structured memories   │
│ Embedder (local MiniLM) → generates 384-dim vectors     │
├─────────────────────────────────────────────────────────┤
│ Neo4j (127.0.0.1:7687) → graph storage, strong password │
│ Qdrant (127.0.0.1:6333) → vector storage, API key       │
│ SQLite → user/cube ACL                                   │
└─────────────────────────────────────────────────────────┘
```

---

## 9. Known Remaining Gaps

- **Qdrant data loss**: Recreating the container lost old vectors. Neo4j still has the text. New writes populate both.
- **No key rotation mechanism**: Keys are static in agents-auth.json. To rotate: update file, restart server (auto-reload helps but agents need new keys in .env too).
- **No read/write granularity**: Cube access is binary (full access or none). Can't give an agent read-only access to another cube.
- **Root MemOS zombie**: Parent process (PID 1801537) can't be killed even with sudo. Workers are dead, port is blocked, but the process lingers.
- **`/health` is a static 200**: Doesn't verify Neo4j/Qdrant connectivity. If a backend dies, health still says "healthy".
- **Hermes built-in memory vs MemOS**: Both systems coexist. No benchmarking done yet on which is better for what use case.

---

## 10. Files Modified (MemOS Patches)

All patches are in `/home/openclaw/.local/lib/python3.12/site-packages/memos/`:

| File | What changed |
|------|-------------|
| `api/middleware/agent_auth.py` | Created — per-agent API key auth middleware |
| `api/middleware/request_context.py` | Strip Authorization header from logs |
| `api/server_api.py` | Register AgentAuthMiddleware + RateLimitMiddleware |
| `api/routers/server_router.py` | Router-level auth dependency, `_enforce_cube_access()` on all routes |
| `api/handlers/search_handler.py` | Spoof check + cube isolation + search tuning (env-configurable) |
| `api/handlers/add_handler.py` | Spoof check + cube isolation + empty content rejection |
| `api/handlers/component_init.py` | Inject UserManager into handler dependencies |
| `api/product_models.py` | Relativity default 0.20 → 0.05 |
| `vec_dbs/qdrant.py` | Pass API key with host+port mode, force `https=False` |
| `templates/mem_reader_prompts.py` | Granularity rule, English language enforcement |
| `multi_mem_cube/single_cube.py` | Write-time dedup (cosine ≥ 0.90) |

**Warning**: These are patches to an installed pip package. They will be lost on `pip install --upgrade memos`. Document them and reapply after upgrades.
