# FOLLOWUP — wire/paperclip-employees sprint handoff

**Date:** 2026-04-21  
**Branch:** `wire/paperclip-employees`  
**PR:** https://github.com/sergiocoding96/hermes-multi-agent/pull/7

---

## What was completed

- `scripts/paperclip/v2/create-research-employee.sh` — idempotent, creates Research Agent with `hermes_local` adapter, `cwd: $HOME` baked in.
- `scripts/paperclip/v2/create-email-employee.sh` — same for Email Marketing Agent.
- `scripts/paperclip/v2/README.md` — documents full setup flow, token retrieval, env vars, error table.
- `scripts/paperclip/_archive/install-hermes-adapter.sh` — archived old script with obsolescence header.
- Both employees exist in Paperclip's DB and were verified via API.
- `adapterConfig.cwd` fix was applied (both existing agents + baked into v2 scripts) to prevent Python `os.getcwd()` crash when Paperclip's own CWD is a deleted directory.

## What is NOT working — agent delegation times out

**Symptom:** When the CEO assigns an issue to either Hermes employee, the agent runs for the full timeout (600 s) without completing the task. The run log shows normal startup but the agent's curl calls to the Paperclip API return HTTP 401.

**Root cause:** The `hermes_local` adapter spawns `hermes chat -q` as a subprocess but does NOT inject any Paperclip auth token into the subprocess environment. The default Hermes SOUL template tells agents to use `curl` to post back results via `POST /api/companies/<id>/messages` (or similar), but those calls return `{"error":"Board access required"}` because no bearer token is available.

**Location of the gap:**  
`/home/linuxbrew/.linuxbrew/lib/node_modules/hermes-paperclip-adapter/node_modules/@paperclipai/adapter-utils/dist/server-utils.js`  
Function `buildPaperclipEnv()` — only provides:
- `PAPERCLIP_AGENT_ID`
- `PAPERCLIP_COMPANY_ID`
- `PAPERCLIP_API_URL`

It does **not** provide `PAPERCLIP_AGENT_JWT` or any bearer token.

**The adapter does support `adapterConfig.env`** — any key/value pairs there get merged into the subprocess environment:
```javascript
// execute.js ~line 120
const userEnv = config.env;
if (userEnv && typeof userEnv === "object") {
    Object.assign(env, userEnv);
}
```

---

## Fix options (pick one)

### Option A — Quick fix: inject board token via `adapterConfig.env` (recommended)

Update both agents' `adapterConfig` in the DB to add an `env` field containing a valid board token. The agents can then use `$PAPERCLIP_BOARD_TOKEN` in their curl calls.

```javascript
// Connect to embedded Postgres and run:
const { Client } = require('pg');
const client = new Client({ connectionString: 'postgres://paperclip:paperclip@127.0.0.1:54329/paperclip' });
await client.connect();

const token = 'pcp_board_b3cbbf04ab1b1b1a7ebab168412b96e09a6ae964e08d6882';  // already in DB

for (const agentId of [
  '5d385a03-d5ed-4437-a56a-c99933237662',   // Research Agent
  '99619b79-8d4f-4a07-a1dc-cca8e4a729a7',   // Email Marketing Agent
]) {
  await client.query(`
    UPDATE agents
    SET "adapterConfig" = jsonb_set(
      "adapterConfig",
      '{env}',
      $1::jsonb
    )
    WHERE id = $2
  `, [JSON.stringify({ PAPERCLIP_BOARD_TOKEN: token }), agentId]);
}
await client.end();
```

Then verify the Hermes SOUL/profile tells agents to use `$PAPERCLIP_BOARD_TOKEN` in API calls. Check:
```bash
cat ~/.hermes/profiles/research-agent/SOUL.md
cat ~/.hermes/profiles/email-marketing/SOUL.md
```

If the SOUL doesn't reference `$PAPERCLIP_BOARD_TOKEN`, add a line like:
```
When calling the Paperclip API, authenticate with: -H "Authorization: Bearer $PAPERCLIP_BOARD_TOKEN"
```

### Option B — Proper fix: patch adapter to mint a short-lived JWT

The Node.js process has `process.env.PAPERCLIP_AGENT_JWT_SECRET`. Patch `buildPaperclipEnv()` to use it to sign a short-lived JWT scoped to the agent and inject it as `PAPERCLIP_AGENT_JWT`.

File to patch:  
`/home/linuxbrew/.linuxbrew/lib/node_modules/hermes-paperclip-adapter/node_modules/@paperclipai/adapter-utils/dist/server-utils.js`

This is cleaner long-term but requires understanding Paperclip's JWT format.

---

## Relevant IDs and state

| Item | Value |
|------|-------|
| Paperclip URL | `http://localhost:3100` |
| DB connection | `postgres://paperclip:paperclip@127.0.0.1:54329/paperclip` |
| Company ID | `a5e49b0d-bd58-4239-b139-435046e9ab91` |
| CEO Agent ID | `84a0aad9-5249-4fd6-a056-a9da9b4d1e01` |
| Research Agent ID | `5d385a03-d5ed-4437-a56a-c99933237662` |
| Email Agent ID | `99619b79-8d4f-4a07-a1dc-cca8e4a729a7` |
| Board API key ID | `d3d0bf02-a32c-4845-9624-6c893bdf3d81` |
| Board token user | `x38WMZ3lpysWtStE5ok30mdV18556Myk` (pedicelsocial@gmail.com) |
| Paperclip PID | 6614 (started from a deleted worktree — may need restart from valid dir) |
| Delegation test issues | Research: `25244531-d250-47d3-9b2a-eb4ab431e2b6`, Email: `7df645f0-32fb-49a8-bb05-ce958847f261` |

---

## Secondary issue: Paperclip server CWD

Paperclip (PID 6614) was started from a since-deleted worktree directory. While the `cwd` fix in `adapterConfig` prevents the Hermes subprocess crash, the Paperclip server itself may have stability issues from being in an invalid CWD. Consider restarting it from a stable directory:

```bash
cd ~ && paperclipai run &
```

(Kill the old process first: `kill 6614`)

---

## Acceptance criteria still pending

- [ ] CEO assigns trivial task → agent completes it within timeout and posts a result.
- [ ] Run log shows no HTTP 401 errors.
- [ ] Both research + email delegation tests return sane output (not timeout/error).
