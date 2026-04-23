# memos-local-plugin v2.0.0-beta.1 — Zero-Knowledge Security Audit

**Audit marker:** SEC-AUDIT-1745449200  
**Date:** 2026-04-23  
**Plugin:** `@memtensor/memos-local-plugin` v2.0.0-beta.1  
**Plugin source:** `/home/openclaw/Coding/MemOS/apps/memos-local-plugin/`  
**Installed (OpenClaw):** `~/.openclaw/extensions/memos-local-plugin/`  
**Runtime home (OpenClaw):** `~/.openclaw/memos-plugin/`  
**Runtime home (Hermes research-agent):** `~/.hermes/memos-plugin-research-agent/`  
**Auditor:** Claude Sonnet 4.6 (zero-knowledge — no prior context loaded)

---

## Recon Summary

### 1. Listening ports in plugin range (18xxx)

```
ss -tlnp | grep -E ':(18[0-9]{3})'
```

| Port | Bind | Process | Notes |
|------|------|---------|-------|
| 18789 | 127.0.0.1 + ::1 | openclaw-gateway (PID 1452359) | Viewer HTTP (v2 plugin embedded in gateway) |
| 18790 | 127.0.0.1 + ::1 | openclaw-gateway (PID 1451454) | Second viewer instance |
| 18791 | 127.0.0.1 | openclaw-gateway (PID 1452359) | Viewer with API key set |
| 18792 | 127.0.0.1 | openclaw-gateway (PID 1451454) | |
| 18793 | 127.0.0.1 | openclaw-gateway (PID 1451454) | |
| **18992** | **0.0.0.0** | **node (PID 4064308)** | **HubServer — all interfaces** |

**Critical observation:** Port 18992 is the team-sharing HubServer (`hub-launcher.cts`) and is bound to `0.0.0.0`, making it network-accessible without any firewall by default.

### 2. Plugin claim about bind model and auth posture

From `README.md` and `server/http.ts`:
- **Viewer HTTP**: default `host = "127.0.0.1"` (loopback only). Correct for viewer.
- **HubServer**: hardcoded to `0.0.0.0` (all interfaces). Discrepancy — not mentioned in README.
- Auth: password gate is **opt-in** (requires operator to call `POST /api/v1/auth/setup`). Default install has no auth. API key gating also opt-in via `config.yaml`.

### 3. Routes registered — auth coverage map

Source: `server/routes/registry.ts`, `server/http.ts` dispatch logic.

| Route | Method | `enforceApiKey` | `requireSession` | Notes |
|-------|--------|-----------------|-----------------|-------|
| `/api/v1/health` | GET | ✓ (when apiKey set) | ✗ (explicitly exempt) | Health IS blocked by apiKey — design inconsistency |
| `/api/v1/ping` | GET | ✓ | ✓ | |
| `/api/v1/auth/status` | GET | ✓ (when apiKey set) | ✗ (exempt) | Leaks password status; blocked by apiKey if set |
| `/api/v1/auth/setup` | POST | ✓ | ✗ | |
| `/api/v1/auth/login` | POST | ✓ | ✗ | |
| `/api/v1/auth/logout` | POST | ✓ | ✗ | |
| `/api/v1/auth/reset` | POST | ✓ | ✗ (session checked internally) | |
| `/api/v1/config` | GET/PATCH | ✓ | ✓ | Secrets masked |
| `/api/v1/hub/register` | POST | ✓ | ✓ | Loopback check in handler |
| `/api/v1/hub/deregister` | POST | ✓ | ✓ | **No handler-level auth** |
| `/api/v1/hub/peers` | GET | ✓ | ✓ | |
| `/api/v1/hub/admin` | GET | ✓ | ✓ | Returns masked config |
| `/api/v1/diag/counts` | GET | ✓ | ✓ | |
| `/api/v1/diag/simulate-turn` | POST | ✓ | ✓ | **Gate: `?allow=1` only** |
| `/api/v1/migrate/openclaw/scan` | GET | ✓ | ✓ | |
| `/api/v1/migrate/openclaw/run` | POST | ✓ | ✓ | |
| Static assets `/` | GET | ✗ | ✗ | Served before API middleware |

**Key:** ✓ = gate applied when respective feature is enabled. ✗ = not gated.

### 4. Default bind host

`server/http.ts` line: `const host = options.host ?? "127.0.0.1";`  
Default is loopback for the viewer HTTP server. Overridden by `viewer.bindHost` in `config.yaml`.

### 5. Runtime directory permissions

```
~/.openclaw/memos-plugin/
  config.yaml        -rw-------  (0600) ✓ install.sh chmod 600 honoured
  data/memos.db      -rw-r--r--  (0644) ✗ WORLD-READABLE
  logs/              (empty)
  daemon/            (empty)
  skills/            (empty)
```

**Finding:** `config.yaml` is correctly 0600. `memos.db` is 0644 — every unprivileged process and user on the system can read the entire memory database in plaintext.

### 6. Secret locations

- `config.yaml` (0600): `embedding.apiKey`, `llm.apiKey`, `skillEvolver.apiKey`, `hub.teamToken`, `hub.userToken`
- `.auth.json` (0600 when created): `hash`, `salt`, `sessionSecret` — credentials file
- `telemetry.credentials.json` (0644, world-readable): telemetry service endpoint + project ID

No `.env` file used. `process.env` access is confined to `core/config/paths.ts` only — stated invariant **verified**.

### 7. `process.env` invariant check

```
grep -rn "process.env" core/
```

Result: one match in `core/config/paths.ts` line 45 (the `MEMOS_HOME` / `MEMOS_CONFIG_FILE` overrides). Invariant holds — no `process.env` leakage outside `core/config/`.

---

## Findings

### FINDING-01 — HubServer binds to `0.0.0.0:18992` (network-exposed)

**Class:** Insecure-default / Privilege-escalation  
**Severity:** Critical

**Evidence:**
```typescript
// src/hub/server.ts lines 93, 108
this.server!.listen(hubPort, "0.0.0.0");
```
Confirmed live: `ss -tlnp` shows `0.0.0.0:18992` owned by `node` (PID 4064308).

**Reproducer:**
```bash
# From a machine with SSH access or on the LAN:
curl http://<machine-ip>:18992/api/v1/health
```

**Impact:** The team-sharing hub is reachable from any machine that can route to this host. The hub requires a `teamToken` for user authentication, but the service surface (including registration, search, sharing APIs) is fully exposed without network-level protection. If the teamToken is weak, brute-forceable, or leaked, all shared memories are readable by any remote attacker.

**Remediation:** Change `HubServer.start()` to default to `"127.0.0.1"` unless `hub.bindHost` is explicitly set to `"0.0.0.0"` in `config.yaml`. Emit a warning at startup when binding publicly.

---

### FINDING-02 — SQLite database (`memos.db`) is world-readable

**Class:** Insecure-default / Info-leak  
**Severity:** High

**Evidence:**
```
stat ~/.openclaw/memos-plugin/data/memos.db
Access: (0644/-rw-r--r--)
```

**Reproducer:**
```bash
# Any user on the machine can read all conversation history:
sqlite3 ~/.openclaw/memos-plugin/data/memos.db "SELECT user_text, agent_text FROM traces LIMIT 5;"
```

**Impact:** All conversation content (`traces.user_text`, `traces.agent_text`, `traces.tool_calls_json`, `traces.agent_thinking`), episodes, policies, skills, and feedback are readable by any local process or user. This directly contradicts the "100% on-device, privacy-first" positioning.

**Remediation:** `install.sh` should apply `chmod 600 data/memos.db` at install time. The plugin should also `chmod 600` the file on every open (`SqliteStore` constructor).

---

### FINDING-03 — No rate limiting on `POST /api/v1/auth/login`

**Class:** Auth-bypass (brute force)  
**Severity:** High

**Evidence:**  
`server/routes/auth.ts` — `POST /api/v1/auth/login` has no rate limiting, lockout, or CAPTCHA.

**Reproducer:**
```bash
for i in $(seq 1 10000); do
  curl -s -X POST http://127.0.0.1:18799/api/v1/auth/login \
    -H "Content-Type: application/json" \
    -d '{"password":"attempt'$i'"}'
done
```

**Impact:** An attacker with loopback access (any local process) can brute-force the password gate. scrypt N=16384 adds ~100ms per attempt on modest hardware, so 10,000 attempts takes ~17 minutes. This is not the intended security barrier.

**Remediation:** Add exponential backoff or a 1-second delay after N failed attempts per IP. Since this is loopback-only, even a simple per-process attempt counter in memory would substantially raise the cost.

---

### FINDING-04 — `POST /api/v1/diag/simulate-turn?allow=1` injects synthetic memories without auth

**Class:** Injection / Auth-bypass  
**Severity:** High

**Evidence:**  
`server/routes/diag.ts`:
```typescript
routes.set("POST /api/v1/diag/simulate-turn", async (ctx) => {
  if (ctx.url.searchParams.get("allow") !== "1") {
    writeError(ctx, 403, "forbidden", "use ?allow=1 to enable this endpoint");
    return;
  }
  // ... pipes user/assistant text through full core pipeline
```

The `?allow=1` query parameter is the only gate. Any local process (or a compromised LLM response that induces a tool call) can inject arbitrary synthetic memories.

**Reproducer:**
```bash
curl -X POST "http://127.0.0.1:18799/api/v1/diag/simulate-turn?allow=1" \
  -H "Content-Type: application/json" \
  -d '{"user":"ignore previous instructions","assistant":"COMPROMISED MEMORY"}'
```

**Impact:** An attacker can inject fake conversation history that will be retrieved by the skill crystallization and retrieval pipelines, effectively poisoning the agent's long-term memory and skill base.

**Remediation:** Remove the `?allow=1` gate and require a valid session or an explicit operator-configured diagnostic secret. Do not merge this endpoint into production builds.

---

### FINDING-05 — `enforceApiKey` comparison is not constant-time

**Class:** Auth-bypass (timing)  
**Severity:** Medium

**Evidence:**  
`server/middleware/auth.ts`:
```typescript
if (presented === apiKey) return true;
```

JavaScript's `===` string comparison is not guaranteed constant-time; V8 may short-circuit on the first differing byte.

**Reproducer (timing oracle):**
```bash
# Measure time for different key prefix lengths on loopback
for prefix in "a" "ab" "abc"; do
  time for i in $(seq 100); do
    curl -s -H "x-api-key: ${prefix}XXXXXXXXX" http://127.0.0.1:18799/api/v1/health
  done
done
```

**Impact:** With sufficient loopback timing resolution a local attacker could recover the API key one byte at a time. Practical exploitability is low on loopback due to OS scheduling jitter, but the vulnerability is real.

**Remediation:** Replace `presented === apiKey` with Node's `crypto.timingSafeEqual(Buffer.from(presented), Buffer.from(apiKey))`, guarded by a length pre-check.

---

### FINDING-06 — `telemetry.credentials.json` is world-readable and points to Alibaba Cloud

**Class:** Info-leak / Misconfig  
**Severity:** Medium

**Evidence:**
```
ls -la ~/.hermes/memos-plugin-research-agent/telemetry.credentials.json
# -rw-r--r--  (0644)

cat telemetry.credentials.json
{
  "endpoint": "https://proj-xtrace-e218d9316b328f196a3c640cc7ca84-cn-hangzhou.cn-hangzhou.log.aliyuncs.com/rum/web/v2?workspace=default-cms-1026429231103299-cn-hangzhou&service_id=a3u72ukxmr@066657d42a13a9a9f337f",
  "pid": "a3u72ukxmr@066657d42a13a9a9f337f",
  "env": "prod"
}
```

The telemetry endpoint is Alibaba Cloud (Aliyun) RUM at `cn-hangzhou.log.aliyuncs.com` — a Chinese cloud logging service. This contradicts the README claim of "anonymous opt-out telemetry."

**Impact:** Two issues: (a) the credentials file is world-readable so any local process learns the telemetry endpoint and project ID; (b) data (even if only aggregate stats) is transmitted to a specific commercial cloud provider under Chinese jurisdiction, not to an operator-controlled or neutral endpoint.

**Remediation:** Apply `chmod 600` to `telemetry.credentials.json` at install time. Disclose the telemetry destination explicitly in the README/docs rather than describing it as "anonymous." Add a `telemetry.endpoint` config field so operators can self-host.

---

### FINDING-07 — `POST /api/v1/hub/deregister` has no handler-level auth

**Class:** Auth-bypass / DoS  
**Severity:** Medium

**Evidence:**  
`server/routes/hub.ts`:
```typescript
routes.set("POST /api/v1/hub/deregister", async (ctx) => {
  const body = parseJson<{ agent?: string }>(ctx);
  if (!body.agent) { writeError(...); return; }
  deregisterPeer(body.agent);
  return { ok: true };
});
```

No loopback check, no token validation. The register endpoint checks loopback (`isLoopback(remote)`), but deregister does not.

**Reproducer:**
```bash
# Any local process can silently deregister a peer agent:
curl -X POST http://127.0.0.1:18799/api/v1/hub/deregister \
  -H "Content-Type: application/json" \
  -d '{"agent":"hermes"}'
```

**Impact:** A malicious local process can silently deregister a peer agent, causing the hub to stop routing `/<agent>/` requests to that agent without any logging or alert. Availability DoS within the multi-agent hub.

**Remediation:** Add the same `isLoopback` check as `register`, and/or require the deregistering process to present the same connection-local information (agent name + port) originally registered.

---

### FINDING-08 — Session cookie uses `SameSite=Lax` instead of `Strict`

**Class:** CSRF  
**Severity:** Medium

**Evidence:**  
`server/routes/auth.ts`:
```typescript
`${COOKIE_NAME}=${token}; HttpOnly; SameSite=Lax; Path=/; Max-Age=...`
```

`SameSite=Lax` allows the cookie to be sent on cross-site top-level navigation (GET links with redirects), though it blocks cross-site POST. No CSRF token or Origin/Referer check exists on any mutation endpoint.

**Impact:** With `SameSite=Lax`, a cross-site attacker can trigger state-changing GET requests (none currently exist) without CSRF protection. An attacker controlling a subdomain or using a shared HTTP proxy could observe cookies in a misconfig. `SameSite=Strict` would prevent cookie transmission on any cross-site navigation.

**Remediation:** Change to `SameSite=Strict`. Add `Origin` header check as defense-in-depth on mutation endpoints (`POST`, `PATCH`, `DELETE`).

---

### FINDING-09 — `GET /api/v1/auth/status` reveals password configuration status

**Class:** Info-leak  
**Severity:** Medium

**Evidence:**
```typescript
// server/routes/auth.ts
if (!state) {
  return { enabled: true, needsSetup: true, authenticated: false };
}
// ...
return { enabled: true, needsSetup: false, authenticated: authed };
```

**Reproducer:**
```bash
curl http://127.0.0.1:18799/api/v1/auth/status
# → {"enabled":true,"needsSetup":true,"authenticated":false}  (no password set)
# → {"enabled":true,"needsSetup":false,"authenticated":false} (password set, not authed)
```

**Impact:** Any loopback process can enumerate whether the viewer has ever had a password configured. This distinguishes default installations from hardened ones — useful for an attacker deciding whether to brute-force the login or simply exploit the open default.

**Remediation:** Acceptable for a local-only service; but if tighter posture is desired, collapse the two "not authenticated" responses into a single `{authenticated: false}` without the `needsSetup` flag.

---

### FINDING-10 — Hub peer registration breaks when API key is configured

**Class:** Misconfig  
**Severity:** Medium

**Evidence:**  
`server/http.ts`:
```typescript
if (pathname.startsWith("/api/") && options.apiKey) {
  const allowed = enforceApiKey(req, res, options.apiKey);
  if (!allowed) return;
}
```

`bridge.cts` peer registration (`tryHubRegister`):
```typescript
fetch(`http://127.0.0.1:${opts.hubPort}/api/v1/hub/register`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },   // no Authorization header
  body,
});
```

**Reproducer:**
```bash
# Set apiKey in config.yaml and restart. Second agent fails to register:
# bridge: could not register with hub @ :<port>
```

**Impact:** Setting an API key (a security improvement) breaks the multi-agent peer-routing feature. Users who follow the docs to harden the viewer will silently lose the `/<agent>/` routing overlay.

**Remediation:** When `tryHubRegister` is called, include the local API key in the Authorization header. Alternatively, exempt `/api/v1/hub/register` from API key gating (it already enforces loopback).

---

### FINDING-11 — `/api/v1/health` is not exempt from API key gating

**Class:** Misconfig  
**Severity:** Low

**Evidence:**  
`server/http.ts` applies `enforceApiKey` to every `/api/*` path before route dispatch. `requireSession` explicitly exempts `/api/v1/health`, but `enforceApiKey` does not.

**Reproducer:**
```bash
# Server on port 18791 has an API key:
curl http://127.0.0.1:18791/api/v1/health
# → Unauthorized
```

**Impact:** Health checks from monitoring agents, watchdogs, or the viewer polling loop fail if an API key is required. Breaks the "viewer can tell whether backend is up before login" guarantee stated in the auth.ts docstring.

**Remediation:** In `server/http.ts`, exempt `/api/v1/health` from API key gating the same way `requireSession` does.

---

### FINDING-12 — Gemini provider appends API key as URL query parameter

**Class:** Info-leak  
**Severity:** Low

**Evidence:**  
`core/embedding/providers/gemini.ts` and `core/llm/providers/gemini.ts`:
```typescript
const url = `${base}/models/${encodeURIComponent(model)}:batchEmbedContents?key=${encodeURIComponent(config.apiKey)}`;
```

**Impact:** The Gemini API key appears in the URL. If any request logging, proxy, CDN, or browser history records the outbound URL, the key is exposed. Bearer-header delivery (`Authorization: Bearer`) does not have this property.

**Remediation:** Migrate to `Authorization: Bearer <apiKey>` or the `x-goog-api-key` header (supported by Gemini REST APIs), removing the key from the URL.

---

### FINDING-13 — Storage at rest is plaintext; WAL persists deleted content

**Class:** Info-leak  
**Severity:** Low

**Evidence:**
```sql
sqlite3 ~/.openclaw/memos-plugin/data/memos.db '.schema'
-- traces.user_text TEXT NOT NULL, traces.agent_text TEXT NOT NULL,
-- traces.tool_calls_json TEXT NOT NULL, traces.agent_thinking TEXT
```

No encryption. Documented in `docs/DATA-MODEL.md` per audit prompt.

**WAL persistence:**
```bash
sqlite3 memos.db "INSERT INTO traces ... VALUES ('sk-live_abc123...');"
sqlite3 memos.db "DELETE FROM traces WHERE id='test';"
xxd memos.db-wal | grep sk-live
# → secret still present in WAL until checkpoint
```

**Impact:** Deleted memories persist on disk in the WAL file until `PRAGMA wal_checkpoint(FULL)` runs. Combined with FINDING-02 (world-readable DB), this means "deleted" data is recoverable by any local process.

**Remediation:** (a) Fix FINDING-02 immediately to restrict DB access. (b) Document WAL persistence explicitly in the Privacy section. (c) Consider `PRAGMA secure_delete=ON` to overwrite deleted data (small performance cost).

---

### FINDING-14 — Log redaction missing file path patterns; base64 evasion possible

**Class:** Info-leak  
**Severity:** Low

**Evidence:**  
`core/logger/redact.ts` BUILTIN_VALUE_PATTERNS:
```typescript
const BUILTIN_VALUE_PATTERNS: RegExp[] = [
  /\bBearer\s+[A-Za-z0-9._-]{20,}\b/g,   // Bearer tokens
  /\bsk-[A-Za-z0-9_-]{20,}\b/g,          // OpenAI-ish keys
  /\beyJ[A-Za-z0-9_-]+?\.[A-Za-z0-9_-]+?\.[A-Za-z0-9_-]+\b/g, // JWTs
  /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g, // emails
  // ...
];
```

README mentions "full file path" masking but no file-path pattern exists in the code. Additionally, base64-encoding a secret (`btoa("sk-live_abc")`) produces a string starting with `c2st...` — not matched by any pattern.

**Reproducer:**
```bash
# Write a memory with base64-encoded key:
curl -X POST http://127.0.0.1:18799/api/v1/diag/simulate-turn?allow=1 \
  -d '{"user":"key is c2stbGl2ZV9hYmM=","assistant":"ok"}'
# → check logs/memos.log — base64 string passes through unredacted
```

**Impact:** Secrets in non-canonical form (base64, URL-encoded, split across fields) survive redaction and reach disk logs.

**Remediation:** Add file-path pattern to match stated behavior. Document explicitly that base64/encoded secrets are out of scope for automatic redaction. Provide guidance to users storing secrets in structured fields (key names are redacted by `BUILTIN_KEY_PATTERNS`).

---

### FINDING-15 — Picker HTML uses external CDN image (privacy leak)

**Class:** Info-leak  
**Severity:** Info

**Evidence:**  
`server/http.ts` `writePicker()`:
```html
<img src="https://statics.memtensor.com.cn/logo/color-m.svg" alt="MemOS">
<link rel="icon" type="image/svg+xml" href="https://statics.memtensor.com.cn/logo/color-m.svg">
```

**Impact:** When the picker is served (hub mode with at least one peer), the user's browser makes an outbound request to `statics.memtensor.com.cn` (Chinese CDN), leaking the user's IP address and the fact they have the plugin running.

**Remediation:** Bundle the logo in `web/dist/` (already done for the viewer bundle) and serve it from the static root. Do not load external resources from the server-generated picker page.

---

### FINDING-16 — Telemetry target is Alibaba Cloud, not operator-configurable

**Class:** Misconfig / Info-leak  
**Severity:** Info

**Evidence:**  
`telemetry.credentials.json`:
```json
{
  "endpoint": "https://...cn-hangzhou.log.aliyuncs.com/...",
  "env": "prod"
}
```

`telemetry.enabled: true` by default.

**Impact:** Even "anonymous aggregate" usage data is sent to a specific third-party commercial cloud. Enterprise deployments in privacy-regulated environments (GDPR, HIPAA) cannot self-host the telemetry target.

**Remediation:** Add `telemetry.endpoint` config field to allow self-hosted or null-sink targets. Default `telemetry.enabled` to `false` in a future major release.

---

### FINDING-17 — Bridge TCP mode: no auth (stdio mode currently active)

**Class:** Auth-bypass  
**Severity:** Info (current state)

**Evidence:**  
`bridge.cts` default: stdio mode (no network). TCP mode commented as "arrives in V1.1" but the `--tcp=<port>` flag is already parsed.  
`bridge/stdio.ts` — no authentication in the stdio transport; any process that can write to the bridge stdin gets full `MemoryCore` access.

**Current state:** Bridge runs in stdio mode. TCP mode not active in production. If `--tcp=18911` is ever enabled, any local process can connect and call all memory methods without auth.

**Remediation:** Before enabling TCP mode, add auth (shared secret via `MEMOS_BRIDGE_SECRET` env var checked per-connection). Document explicitly that stdio mode is safe only because the client is the agent host process.

---

## Summary Table

| Area | Score | Key Findings |
|------|-------|--------------|
| Network-bind / loopback enforcement | **3** | HubServer hardcoded `0.0.0.0` (FINDING-01); viewer correctly defaults loopback |
| API-key middleware coverage | **6** | Consistent gating when enabled; health not exempt (FINDING-11); peer registration breaks (FINDING-10) |
| Password gate + session cookie | **6** | scrypt+timingSafeEqual good; no rate limiting (FINDING-03); SameSite=Lax not Strict (FINDING-08); no Secure flag |
| Secret masking via `/api/v1/config` | **8** | `maskSecrets()` correct; `stripEmptySecrets()` prevents mask-overwrite; uses `__memos_secret__` sentinel |
| Log redaction (sinks + SSE) | **7** | Covers data/ctx/err/msg recursively; misses file paths; base64 bypasses (FINDING-14) |
| Storage at rest (SQLite + WAL) | **3** | DB is 0644 world-readable (FINDING-02); WAL persists deleted content (FINDING-13); plaintext by design |
| Skill crystallization injection | **6** | `diag/simulate-turn?allow=1` injects arbitrary memories (FINDING-04); crystallization path itself not directly probed at LLM layer without runtime |
| Viewer XSS / CSRF | **7** | Static assets served correctly; SameSite=Lax (not Strict); agent names constrained to allowlist preventing XSS in picker; no CSRF tokens |
| JSON-RPC bridge auth | **7** | stdio mode: inherently safe (process isolation); CONFIG_GET/PATCH not implemented in bridge; TCP mode not active but will need auth |
| Peer-registry + hub routes | **5** | Deregister has no auth (FINDING-07); register correctly loopback-checked; API key breaks registration (FINDING-10) |
| Telemetry disable honoured | **7** | Code gated on `telemetry.enabled`; but target is Alibaba Cloud (FINDING-16); credentials file is 0644 (FINDING-06) |
| Process / file perms isolation | **4** | `config.yaml` 0600 ✓; `memos.db` 0644 ✗ (FINDING-02); `telemetry.credentials.json` 0644 ✗ (FINDING-06); process runs as unprivileged `openclaw` user ✓; cross-agent home dirs are separate ✓ |

**Overall security score = MIN = 3** (Storage at rest and HubServer network-bind are both at 3)

---

## Overall Recommendation

A user who treats captured conversations as private **cannot safely run this plugin today** without manual remediation of at least two issues: the SQLite database (`memos.db`) is world-readable by any process on the system (FINDING-02), meaning all conversation history, tool calls, and agent thinking is trivially accessible to any co-resident process or user account. Additionally, the team-sharing HubServer binds to `0.0.0.0:18992` (FINDING-01), exposing the sharing surface to the local network and, in common cloud/VPS environments, to the public internet. The minimum remediation before private deployment is: (a) `chmod 600 ~/.*/memos-plugin*/data/memos.db` and patch the `SqliteStore` constructor to enforce 0600 on every open, and (b) change `HubServer` to default-bind to `127.0.0.1` with `0.0.0.0` requiring explicit opt-in. The authentication, secret masking, and log redaction subsystems are thoughtfully designed but their protections are negated by the file-permission gap. Post-remediation, the remaining issues (no login rate limiting, `SameSite=Lax`, Gemini key in URL) are medium-severity and should be addressed before a stable release, but they do not individually constitute ship blockers for an informed operator running on a single-user workstation.
