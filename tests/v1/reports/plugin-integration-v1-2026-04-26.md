# MemOS v1 Plugin Integration Audit
**Date:** 2026-04-26  
**Marker:** V1-PI-1745712000  
**Auditor:** Claude Sonnet 4.6 (blind, zero-knowledge)  
**Scope:** `~/.hermes/plugins/memos-toolset/` → MemOS API at `http://localhost:8001`

---

## Executive Summary

The memos-toolset plugin has a sound design: identity is read from environment variables, schemas expose no credential parameters, and the MemOS server has correct spoof-detection on the authenticated path. However, the integration is **functionally broken in its current deployed state**: `agents-auth.json` does not exist at the configured path, yet `MEMOS_AUTH_REQUIRED=true`, causing every `/product/*` call to fail with HTTP 401. Neither demo agent can store or retrieve any memories. The v1.0.3 auto-capture feature referenced in the audit prompt is not implemented in the plugin. Overall score: **MIN = 1/10**.

---

## Recon Findings

### Plugin inventory (`~/.hermes/plugins/memos-toolset/`)

| File | Purpose |
|------|---------|
| `plugin.yaml` | Declares `name`, `version`, `requires_env`, `provides_tools` |
| `__init__.py` | Registers `memos_store` and `memos_search` via `ctx.register_tool()` |
| `handlers.py` | HTTP client — reads identity from env, calls MemOS `/product/add` and `/product/search` |
| `schemas.py` | LLM-visible tool schemas — no credential or identity fields |

No `SKILL.md` is present. The plugin exposes exactly two tools.

### Identity-loading code

`handlers._get_config()` at line 20:

```python
def _get_config():
    return {
        "api_url": os.environ.get("MEMOS_API_URL", "http://localhost:8001"),
        "api_key": os.environ["MEMOS_API_KEY"],
        "user_id": os.environ["MEMOS_USER_ID"],
        "cube_id": os.environ["MEMOS_CUBE_ID"],
    }
```

Called **per invocation**, not at startup. Identity can change mid-session if `os.environ` is mutated between calls.

### HTTP client

`handlers._post()` — uses `urllib.request`, attaches `Authorization: Bearer <api_key>`. Endpoint resolved from `MEMOS_API_URL` env var (default `http://localhost:8001`). No URL scheme/host allowlist.

### Privilege-escalation surface

No tool in the schema accepts `user_id`, `cube_id`, or endpoint URL. No "switch user" or admin tool is registered. The LLM has zero direct control over identity.

### OpenClaw analogous plugin

`~/.openclaw/plugins/` does not exist. The analogous isolation path is not deployed.

---

## Probe Matrix

### 1. Tool Surface Exposure

**Tools registered:** `memos_store` and `memos_search` only.

**Schema parameters:**
- `memos_store`: `content` (required), `mode` (enum: fine/fast), `tags` (array of strings)
- `memos_search`: `query` (required), `top_k` (integer, clamped 1–50)

No `user_id`, `cube_id`, `api_url`, or admin parameter appears in either schema. No admin tool (clear, delete-all, switch-cube) is registered. The check function `_memos_available()` gates registration on the three required env vars.

**Score: 9/10.** Deduction: no `SKILL.md` means the LLM has no structured guidance on when to call each tool; risk of over-storing is real.

---

### 2. Identity-from-env Enforcement

**Plugin side (good):** `_get_config()` reads `os.environ` at each call — the LLM cannot supply identity values. Even an attempted override (e.g., injecting `cube_id` in `content`) would be ignored; the handler constructs the API payload from env, not from args.

**Plugin side (concern — race/mutation):** `_get_config()` calls `os.environ["MEMOS_API_KEY"]` dynamically. If `load_dotenv(override=True)` is re-run mid-session (e.g., triggered by another plugin or a config reload), a modified `.env` would immediately change the identity used for the next call. There is no per-call assertion that env is stable.

**Server side (good, when auth is functioning):** `AgentAuthMiddleware` sets `_authenticated_user` contextvar from the API key. Both `AddHandler` and `SearchHandler` verify:

```python
authenticated = get_authenticated_user()
if authenticated is not None and authenticated != req.user_id:
    raise HTTPException(403, "Spoofing not allowed.")
```

This correctly blocks a key for agent A from claiming to act as agent B.

**Score: 5/10.** The design is correct but the dynamic env re-read creates a mid-session identity-swap window. Per-call env snapshot would harden this.

---

### 3. Auth Header Propagation + Redaction

**Plugin transmits:** `Authorization: Bearer <raw_key>` to MemOS — correct header format.

**Key in responses:** Tested both `memos_store` and `memos_search` under error conditions — the raw API key does not appear in any tool result returned to the LLM.

```
Store result: {"status": "error", "error": "HTTP 401", "detail": "{\"detail\":\"Invalid or unknown agent key.\"}"}
```

**Key at rest:** Profile `.env` files store the raw API key in plaintext:
```
MEMOS_API_KEY=ak_ebf6642a941f62f0054d597ec99e2a8e
```
Permissions on the profile `.env` are `rw-rw-r--` (world-readable within the group).

**Server-side:** `AgentAuthMiddleware` logs `user_id` at DEBUG but does not log the raw token. The bcrypt verify cache uses `sha256(raw_key)` as the cache key — the hash is never persisted or logged.

**Score: 7/10.** Bearer format is correct; key not leaked into LLM context. Deduction: plaintext storage in world-readable `.env` files; no key-at-rest encryption.

---

### 4. Agent ↔ MemOS Round-Trip Correctness

**Finding: Completely broken. This is the highest-severity finding.**

Configuration:
- `MEMOS_AUTH_REQUIRED=true` (in `/home/openclaw/Coding/MemOS/.env`)
- `MEMOS_AGENT_AUTH_CONFIG=/home/openclaw/Coding/Hermes/agents-auth.json`
- `agents-auth.json` **does not exist** at that path (nor anywhere on the filesystem)

The setup script (`setup-memos-agents.py`) that generates `agents-auth.json` has been archived (`setup-memos-agents.py.archived`) and is not runnable.

**Live probe results:**

```bash
# No auth header:
POST /product/search  →  HTTP 401

# With research-agent key (ak_ebf6642a941f62f0054d597ec99e2a8e):
POST /product/search  →  HTTP 401  {"detail": "Invalid or unknown agent key."}

# With email-marketing-agent key:
POST /product/search  →  HTTP 401
```

Neither demo agent can execute any memory operation. The plugin returns `{"status": "error", "error": "HTTP 401"}` to the agent on every call. The LLM receives error responses but is not explicitly informed that its memory backend is permanently unavailable.

The setup script would need to be restored and run to generate `agents-auth.json`, creating the bcrypt-hashed key entries for all agents.

**Score: 1/10.** The round-trip is entirely non-functional in the current deployment.

---

### 5. Auto-Capture (v1.0.3) Reliability

No auto-capture code was found anywhere in the plugin:

```
grep -r "auto.captur\|turn_end\|session_end\|hook\|autocapture" ~/.hermes/plugins/memos-toolset/
→ No autocapture code found
```

The Hermes lifecycle hooks (`on_session_end`, `post_llm_call`, etc.) exist in `plugins.py`, but the memos-toolset plugin's `register()` function does not register any hook callbacks — only tool registrations.

The feature is not implemented.

**Score: 1/10.** Auto-capture is absent.

---

### 6. Concurrent-Agent Isolation

Each named profile (`research-agent`, `email-marketing`) is a separate `HERMES_HOME` directory with its own `.env`, loaded via `load_dotenv(override=True)` into the process's `os.environ` at startup. When each agent runs as a separate process, isolation is correct: each process has its own env namespace.

**Risk:** If two profiles are ever run within the same Python process (e.g., a future multi-agent orchestrator spawning threads), `os.environ` is shared. The second `load_dotenv(override=True)` call would overwrite the first profile's identity. The plugin's per-call `os.environ` read would then use the wrong identity.

The hub-sync path (`hub-sync.db` exists in research-agent profile) was not probed; the sync state DB is present but auth is broken, so no cross-profile replication could be tested.

**Score: 6/10.** Process-level isolation is correct. In-process multi-profile scenario would break isolation.

---

### 7. CompositeCubeView (CEO) Read-Only

`CompositeCubeView` in `composite_cube.py` implements `add_memories()` with a full fan-out write to all cube views. There is no CEO-specific write restriction:

```python
def add_memories(self, add_req: APIADDRequest) -> list[dict]:
    for view in self.cube_views:
        results = view.add_memories(add_req)  # no role check
        all_results.extend(results)
```

The only protection against CEO writing to worker cubes is `validate_user_cube_access()` — an ACL check based on `user_cube_association` table rows. The provisioning script adds worker cubes to the CEO via `CEO_SHARES`, which grants read access. Whether that share grants write access depends on how `validate_user_cube_access` is implemented — it was not audited to this depth.

The result tags from CompositeCubeView fan-out search do not include `cube_id` per-memory — the aggregated results drop the source cube tag. LLM consumers of the CEO path cannot distinguish which cube a memory came from.

**Score: 4/10.** No explicit CEO write restriction at the API level; search results lack source cube_id tags.

---

### 8. Endpoint Discovery + URL Allowlist

**Wrong host (fast failure):**

```python
os.environ["MEMOS_API_URL"] = "http://wrong-host-1745712000.invalid:8001"
result = memos_store({"content": "SSRF test"})
# → {"status": "error", "error": "connection_failed", "detail": "[Errno -2] Name or service not known"}
# Elapsed: 0.02s
```

DNS failure is fast (< 50ms). Good.

**URL allowlist:** None. The plugin constructs the URL as:

```python
url = f"{api_url.rstrip('/')}/{endpoint.lstrip('/')}"
```

No scheme validation (`http://` vs `https://`), no host allowlist, no port restriction. If an attacker can write to the profile `.env`, they can redirect the API key to any HTTP server they control. The LLM cannot supply `MEMOS_API_URL` (not in schema), but file-system-level access to `.env` is the attack surface.

**Score: 5/10.** Fast failure on DNS errors is good. No URL allowlist is a medium finding.

---

### 9. Plugin Reload Behavior

**Identity (env):** `_get_config()` re-reads `os.environ` on every call. A `.env` modification takes effect on the next plugin call — no restart required, no notification to the LLM.

**Auth config (MemOS server):** `AgentAuthMiddleware._check_reload()` compares file mtime on every request. Config file changes propagate immediately to the running server.

**Plugin code:** Python module code (handlers.py, schemas.py) is loaded once at import time. Changes to these files require a Hermes process restart.

**Security impact of env reload:** An operator (or any process with write access to the profile `.env`) can swap a live agent's identity mid-session by modifying `MEMOS_API_KEY` / `MEMOS_USER_ID` / `MEMOS_CUBE_ID`. The agent receives no signal that its identity changed; subsequent memory operations silently target the new identity.

**Score: 5/10.** Hot env reloading is a double-edged design choice — convenient for ops but creates a silent identity-swap risk.

---

### 10. Plugin-Side Logging + Secret Redaction

**Plugin logging:** The plugin module sets `logger = logging.getLogger(__name__)` but makes no log calls in `memos_store` or `memos_search`. Tool inputs and outputs are not logged by the plugin itself.

**MemOS server logging:** `AgentAuthMiddleware` logs `user_id` at DEBUG on successful auth (not the key). No raw token appears in any logger call observed in `agent_auth.py`. The MemOS log is written to `~/.memos/logs/memos.log`.

**Key at rest:** Profile `.env` files store raw API keys plaintext with group-read permissions (`rw-rw-r--`). There is no key-at-rest encryption. The profile directory also contains other plaintext secrets (`MINIMAX_API_KEY`, `DEEPSEEK_API_KEY`).

**Score: 7/10.** Server-side redaction is correct. Deduction: plaintext credentials at rest in world-readable files; no per-tool-call audit log.

---

## Findings Index

| ID | Class | Severity | Summary |
|----|-------|----------|---------|
| F-01 | capture-loss / discovery-failure | Critical | `agents-auth.json` missing → all /product/* calls return 401; both demo agents are memory-blind |
| F-02 | capture-loss | Critical | Auto-capture (v1.0.3) not implemented; no hook registrations in plugin |
| F-03 | identity-leak / privilege-escalation | High | `_get_config()` reads `os.environ` per call — mid-session identity swap possible via `.env` mutation or `load_dotenv(override=True)` re-run |
| F-04 | unredacted-secret | Medium | Raw API keys stored plaintext in profile `.env` files with group-read permissions |
| F-05 | privilege-escalation | Medium | CompositeCubeView has no CEO write restriction; CEO can write to worker cubes if ACL allows |
| F-06 | cross-profile-leak | Medium | CompositeCubeView search results do not tag memories with source `cube_id`; CEO cannot distinguish memory provenance |
| F-07 | discovery-failure | Medium | No URL allowlist in plugin — if `.env` is writable by an attacker, API key follows any URL |
| F-08 | identity-leak | Low | `os.environ` is shared across threads/plugins in the same process; future in-process multi-profile would break isolation |
| F-09 | silent-coercion | Info | No SKILL.md in plugin — LLM has no structured guidance on when to use `memos_store` vs when not to |

### F-01 Detail (Critical)

**Class:** capture-loss / discovery-failure  
**Reproducer:**
```bash
curl -s -X POST http://localhost:8001/product/search \
  -H "Authorization: Bearer ak_ebf6642a941f62f0054d597ec99e2a8e" \
  -H "Content-Type: application/json" \
  -d '{"query":"test","user_id":"research-agent","readable_cube_ids":["research-cube"],"top_k":1}'
# → {"detail":"Invalid or unknown agent key."}
```
**Evidence:** `MEMOS_AGENT_AUTH_CONFIG=/home/openclaw/Coding/Hermes/agents-auth.json` — file absent. Setup script archived at `deploy/scripts/setup-memos-agents.py.archived`.  
**Remediation:** Restore setup script and run it to generate `agents-auth.json`; verify the file is present and readable by the MemOS server process before declaring the integration operational.

### F-02 Detail (Critical)

**Class:** capture-loss  
**Reproducer:** Inspect `~/.hermes/plugins/memos-toolset/__init__.py` `register()` function — no `ctx.register_hook()` call present.  
**Evidence:** `grep -r "hook\|on_session" ~/.hermes/plugins/memos-toolset/` returns nothing.  
**Remediation:** Implement auto-capture by registering a `post_llm_call` or `on_session_end` hook in `register(ctx)` that calls `memos_store` with turn content.

### F-03 Detail (High)

**Class:** identity-leak / privilege-escalation  
**Reproducer:** In a running Hermes session, write a new `MEMOS_CUBE_ID` to the profile `.env`; the next `memos_store` call silently targets the new cube.  
**Evidence:** `handlers._get_config()` calls `os.environ["MEMOS_API_KEY"]` at line 22 with no snapshot or validation.  
**Remediation:** Snapshot env at session start into an immutable dict; raise an error (or at minimum log a warning) if env values change mid-session.

### F-04 Detail (Medium)

**Class:** unredacted-secret  
**Evidence:**
```
-rw-rw-r-- ~/.hermes/profiles/research-agent/.env
Contents: MEMOS_API_KEY=ak_ebf6642a941f62f0054d597ec99e2a8e
```
**Remediation:** `chmod 600` on all profile `.env` files; consider using an OS keychain or age-encrypted secrets file.

### F-05 Detail (Medium)

**Class:** privilege-escalation  
**Evidence:** `composite_cube.py:28-38` — `add_memories()` iterates `cube_views` with no role check.  
**Remediation:** Add a `read_only` flag to `CompositeCubeView`; raise on `add_memories` when set. Provision CEO shares as read-only in `user_cube_association`.

### F-06 Detail (Medium)

**Class:** cross-profile-leak  
**Evidence:** `composite_cube.py:60-77` — `search_memories()` merges results into a flat list without annotating each memory with its source `cube_id`.  
**Remediation:** Tag each result with `cube_id` from the originating `SingleCubeView` before merging.

### F-07 Detail (Medium)

**Class:** discovery-failure  
**Evidence:** `handlers._post()` line 32: `url = f"{api_url.rstrip('/')}/{endpoint.lstrip('/')}"` — no validation of `api_url` scheme or host.  
**Remediation:** Validate `MEMOS_API_URL` against an allowlist (`localhost` or a configurable whitelist of trusted hosts) before constructing the request.

---

## Summary Score Table

| Area | Score 1-10 | Key findings |
|------|-----------|--------------|
| Tool surface (no admin / no escalation) | 9 | No identity params in schema; no admin tools; no SKILL.md |
| Identity-from-env enforcement | 5 | Per-call env read creates mid-session swap window; no snapshot |
| Auth header propagation + redaction | 7 | Bearer format correct; key not in responses; plaintext at rest |
| Agent ↔ MemOS round-trip correctness | **1** | agents-auth.json missing; all /product/* return 401; zero functional memory |
| Auto-capture (v1.0.3) reliability | **1** | Not implemented; no hook registrations in plugin |
| Concurrent-agent isolation | 6 | Process-level isolation correct; in-process scenario would break |
| CompositeCubeView (CEO) read-only | 4 | No write restriction; no source cube_id tags in results |
| Endpoint discovery + URL allowlist | 5 | Fast DNS failure; no URL allowlist; SSRF risk if .env writable |
| Plugin reload behaviour | 5 | Env hot-reload = silent identity swap; code requires restart |
| Plugin-side logging + secret redaction | 7 | No key in server logs; plaintext credentials at rest |

**Overall plugin-integration score = MIN = 1/10**

---

## Judgement

The demo agents (research-agent, email-marketing-agent, and the CEO orchestrator) do **not** get correct, isolated, or observable memory access through this plugin in the current deployment state. The authentication contract is broken at the most fundamental level: `agents-auth.json` does not exist, and `MEMOS_AUTH_REQUIRED=true`, so every memory operation fails silently with a 401. The v1.0.3 auto-capture feature is not implemented. When the auth issue is resolved (restoring and running the setup script), the plugin's core design is sound — identity is correctly derived from environment variables, credential parameters are absent from the LLM-visible schema, and the MemOS server enforces the spoof-check via contextvar. The remaining Medium/Low findings (plaintext secrets at rest, no URL allowlist, no CEO write restriction, missing source cube_id tags) are addressable without architectural changes. The system cannot be called operationally sound until F-01 and F-02 are resolved.
