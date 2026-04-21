# Paperclip Hermes employees — v2 setup (built-in adapter)

This directory replaces the older `install-hermes-adapter.sh` flow from `scripts/paperclip/`.

## What changed from v1

**`install-hermes-adapter.sh` is obsolete.** Starting with `paperclipai 2026.416.0`,
the `hermes_local` adapter ships bundled with Paperclip. There is nothing to install —
it appears automatically in `GET /api/adapters`. Running the old install script against
a current Paperclip instance is a no-op at best and will error if the external-adapter
plugin endpoint has been removed.

## Prerequisites

| Requirement | Check |
|-------------|-------|
| Paperclip running | `curl -s http://localhost:3100/api/adapters \| jq '.[] \| select(.type=="hermes_local")'` |
| `hermes` CLI on PATH | `hermes profile list` |
| Hermes profile `research-agent` exists | `hermes profile list \| grep research-agent` |
| Hermes profile `email-marketing` exists | `hermes profile list \| grep email-marketing` |
| `jq` installed | `jq --version` |
| `PAPERCLIP_BOARD_TOKEN` in env | see below |

## How to get PAPERCLIP_BOARD_TOKEN

The scripts need a board-level API token. **Never commit this value.**

### Option A — Paperclip UI (recommended)

1. Open Paperclip at `http://localhost:3100` and sign in.
2. Click your avatar (top-right) → **Settings** → **API Keys**.
3. Click **New API key**, give it a name (e.g. `hermes-wire-script`), copy the value.
4. The key is shown **once** — copy it immediately.

### Option B — CLI (browser-based OAuth)

```bash
paperclipai auth login --api-base http://localhost:3100
# Follow the printed URL to approve in the browser
paperclipai auth whoami  # verify
```

The CLI stores the token in its context profile. To extract it for use in shell
scripts, run:

```bash
paperclipai context show --json | jq -r '.profile.apiKey // empty'
```

### Setting the token in your shell session

```bash
export PAPERCLIP_BOARD_TOKEN="pcp_board_<your-key-here>"
```

Add to `~/.hermes/.env` or your shell profile if you want it persistent.

## Run order

```bash
cd scripts/paperclip/v2

# ── One-time: patch the bundled hermes-paperclip-adapter ──────────────────
# Two idempotent patches, both auto-discovering every copy of
# hermes-paperclip-adapter/dist/server/execute.js under the npm global root:
#
#   1. patch-hermes-adapter.sh      — fixes the wake-context read bug so
#                                     agents actually see their assigned task
#                                     (see "Why the adapter patch").
#
#   2. patch-hermes-adapter-jwt.sh  — propagates the per-run scoped JWT
#                                     Paperclip already mints (as
#                                     `ctx.authToken`) into the subprocess
#                                     env as `PAPERCLIP_AGENT_JWT`, so the
#                                     agent can PATCH its issue to done on
#                                     completion (see "Why the JWT patch").
#
# IMPORTANT: restart paperclipai afterwards — Node caches modules in-memory.
./patch-hermes-adapter.sh
./patch-hermes-adapter-jwt.sh

# Optional but recommended: shorten the per-run JWT TTL from the 48h default
# to 10 minutes. The token is already scoped to {agent, company, run}; a
# short TTL limits the blast radius if a subprocess log leaks it.
#   grep -q '^PAPERCLIP_AGENT_JWT_TTL_SECONDS=' ~/.paperclip/instances/default/.env \
#     || printf '\nPAPERCLIP_AGENT_JWT_TTL_SECONDS=600\n' >> ~/.paperclip/instances/default/.env

# Then restart Paperclip so the patched module + env are reloaded:
source ~/.paperclip/instances/default/.env
pkill -TERM -f 'node .*paperclipai run' && sleep 2
nohup paperclipai run > ~/.paperclip/instances/default/logs/server.log 2>&1 &

# Create research-agent employee (idempotent — safe to re-run)
PAPERCLIP_BOARD_TOKEN="$PAPERCLIP_BOARD_TOKEN" ./create-research-employee.sh

# Create email-marketing-agent employee (idempotent — safe to re-run)
PAPERCLIP_BOARD_TOKEN="$PAPERCLIP_BOARD_TOKEN" ./create-email-employee.sh

# Apply the stdout-completion prompt override to every existing hermes_local
# employee. Required for agents that were created *before* the template was
# wired into the create-* scripts; harmless no-op for ones created after.
PAPERCLIP_BOARD_TOKEN="$PAPERCLIP_BOARD_TOKEN" ./apply-prompt-override.sh
```

Both `create-*` scripts:
- Verify `hermes_local` is registered before doing anything
- Check that the target Hermes profile exists
- Skip creation if an agent using that profile already exists in the company
- Embed `adapterConfig.promptTemplate` from `prompts/hermes-employee.mustache`
  so fresh installs ship with the stdout-completion template from day one
- Print the resulting agent JSON on success

`apply-prompt-override.sh`:
- Reads the template from `prompts/hermes-employee.mustache` so the DB always
  matches the committed source file.
- GETs every `hermes_local` agent in the company, compares each agent's
  current `adapterConfig.promptTemplate` to the on-disk template, skips if
  they already match (re-running is a no-op).
- Otherwise PATCHes `/api/agents/:id` with a partial `adapterConfig`. Paperclip
  merges partial `adapterConfig` updates by default (no `replaceAdapterConfig`
  flag), so every other adapterConfig field is preserved.
- Verifies the PATCH response contains the expected template before counting
  the agent as updated.

## Why the adapter patch

`hermes-paperclip-adapter/dist/server/execute.js` reads wake-context fields
(taskId, taskTitle, taskBody, commentId, wakeReason, companyName, projectName)
from `ctx.config` — but Paperclip's heartbeat service puts those fields on
`ctx.context` (the contextSnapshot). `ctx.config` is only the resolved
runtimeConfig (workspace + skills). As a result, every wake — including
`issue_assigned` — rendered the `{{#noTask}}` branch of the prompt
template, meaning the agent **never saw its assigned task**.

Other paperclipai adapters (e.g. `adapter-claude-local`) correctly read
`context.taskId`. Only the hermes adapter has this bug.

`patch-hermes-adapter.sh` rewrites the 8 affected reads to `ctx.context?.*`
and adds fallbacks to `ctx.context.paperclipWake.issue.{id,title,body}` so
the template populates with the wake payload when the direct fields aren't
set.

The script auto-discovers every copy of the adapter under the npm global
root — paperclipai bundles its own copy under
`node_modules/paperclipai/node_modules/hermes-paperclip-adapter/`, and that's
the copy that gets loaded at runtime; patching only the top-level global
copy is a no-op. Idempotency is enforced via a sentinel comment; every
patched file gets a timestamped `.orig-YYYYMMDD-HHMMSS` backup for easy
revert.

## Why the JWT patch

Paperclip's heartbeat service (`@paperclipai/server/dist/services/heartbeat.js`)
already mints a short-lived, HS256-signed, per-run JWT for every adapter whose
registry entry has `supportsLocalAgentJwt: true` — and `hermes_local` is one
of them. The token is produced by
`createLocalAgentJwt(agentId, companyId, adapterType, runId)` and passed to
the adapter's `execute()` function as `ctx.authToken`. Claims:

```
{ sub: <agentId>, company_id, adapter_type, run_id,
  iat, exp, iss: "paperclip", aud: "paperclip-api" }        // HS256
```

The Paperclip auth middleware (`@paperclipai/server/dist/middleware/auth.js`)
verifies this token on every request via `verifyLocalAgentJwt()` and sets
`req.actor = { type: "agent", agentId, companyId, runId }`. Authorization is
scoped by that actor — an agent JWT can only touch its own agent/company.

The reference adapter `@paperclipai/adapter-claude-local` reads
`ctx.authToken` and exports it as `PAPERCLIP_API_KEY` in the subprocess env.
The hermes adapter (through v2026.416.0) simply ignores that field. That is
why agents had no way to self-transition issues to `done` and Paperclip's
reconciler kept demoting them to `blocked`.

`patch-hermes-adapter-jwt.sh` adds one block after the existing
`PAPERCLIP_RUN_ID` injection in `execute.js`:

```js
if (typeof ctx.authToken === "string" && ctx.authToken.length > 0)
    env.PAPERCLIP_AGENT_JWT = ctx.authToken;
```

The prompt template at `prompts/hermes-employee.mustache` instructs the agent
to issue exactly one `PATCH /api/issues/:id -d '{"status":"done"}'` with that
bearer as the final step. Stdout capture still handles the issue comment —
only the status transition now requires auth.

### Why not mint our own token in the adapter

An earlier plan (see
[`2026-04-21-paperclip-hermes-adapter-auth-gap.md`](../../../memos-setup/learnings/2026-04-21-paperclip-hermes-adapter-auth-gap.md),
"Option 3") was to sign a fresh JWT inside `buildPaperclipEnv()`. That would
duplicate the signing logic already present upstream and drift from its claim
shape. Paperclip's mint is authoritative — we propagate it.

### TTL tuning

TASK.md asks for `exp ≤ 10 minutes`. Upstream default is 48h (see
`PAPERCLIP_AGENT_JWT_TTL_SECONDS` in
`@paperclipai/server/dist/agent-auth-jwt.js`). Set that env var to `600` on
the Paperclip process to meet the per-run scope (the snippet in "Run order"
does this). The agent only needs the token for ~15s, so 10 minutes is a
safe upper bound.

## Delegation smoke test (validates the override end-to-end)

```bash
PAPERCLIP_URL="http://localhost:3100"
COMPANY_ID="a5e49b0d-bd58-4239-b139-435046e9ab91"
TS=$(date +%s)
MARKER="FIX-AGENT-AUTH-$TS"

# Locate both employees by profile name
RESEARCH_AGENT_ID=$(curl -s "$PAPERCLIP_URL/api/companies/$COMPANY_ID/agents" \
  -H "Authorization: Bearer $PAPERCLIP_BOARD_TOKEN" \
  | jq -r '[.[] | select(.adapterType=="hermes_local" and (.adapterConfig.extraArgs|join(" ")|contains("research-agent")))][0].id')
EMAIL_AGENT_ID=$(curl -s "$PAPERCLIP_URL/api/companies/$COMPANY_ID/agents" \
  -H "Authorization: Bearer $PAPERCLIP_BOARD_TOKEN" \
  | jq -r '[.[] | select(.adapterType=="hermes_local" and (.adapterConfig.extraArgs|join(" ")|contains("email-marketing")))][0].id')

# Assign a trivial task to each
for pair in "$RESEARCH_AGENT_ID:HTTP status codes one-sentence summary" \
            "$EMAIL_AGENT_ID:one-sentence subject-line tip for a cold outreach email"; do
  aid="${pair%%:*}"; title="${pair#*:}"
  curl -sf -X POST "$PAPERCLIP_URL/api/companies/$COMPANY_ID/issues" \
    -H "Authorization: Bearer $PAPERCLIP_BOARD_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"$MARKER: $title\",\"assigneeAgentId\":\"$aid\",\"status\":\"todo\",\"priority\":\"high\"}"
done

# Wait up to 90s, then check status + run logs
sleep 90
curl -sf "$PAPERCLIP_URL/api/issues?q=$MARKER" \
  -H "Authorization: Bearer $PAPERCLIP_BOARD_TOKEN" \
  | jq '.[] | {title, status, assigneeAgentId, completedAt}'

# Expect: both issues status=="done", completedAt set, zero 401s in run logs.
```

Pass criteria:

- Each run log contains zero HTTP 401 / `Board access required` responses.
- Each agent completes in `< 5` turns.
- The captured completion message (persisted as an issue comment) is
  coherent and directly answers the assigned task.
- Run status `succeeded` within 60 s.
- Issue status transitions to `done` within 60 s (via the agent's one
  `PATCH /api/issues/:id` using `$PAPERCLIP_AGENT_JWT`).

## Verifying end to end

```bash
PAPERCLIP_URL="http://localhost:3100"
COMPANY_ID="a5e49b0d-bd58-4239-b139-435046e9ab91"

# 1. Adapter registered
curl -s "$PAPERCLIP_URL/api/adapters" \
  -H "Authorization: Bearer $PAPERCLIP_BOARD_TOKEN" \
  | jq '.[] | select(.type == "hermes_local")'

# 2. Both employees present
curl -s "$PAPERCLIP_URL/api/companies/$COMPANY_ID/agents" \
  -H "Authorization: Bearer $PAPERCLIP_BOARD_TOKEN" \
  | jq '[.[] | select(.adapterType == "hermes_local") | {id, name, status, adapterConfig: {profile: .adapterConfig.extraArgs}}]'

# 3. Delegation smoke test (uses unique marker to avoid colliding with real traffic)
TS=$(date +%s)
RESEARCH_AGENT_ID=$(curl -s "$PAPERCLIP_URL/api/companies/$COMPANY_ID/agents" \
  -H "Authorization: Bearer $PAPERCLIP_BOARD_TOKEN" \
  | jq -r '[.[] | select(.adapterType=="hermes_local" and (.adapterConfig.extraArgs | join(" ") | contains("research-agent")))][0].id')

curl -s -X POST "$PAPERCLIP_URL/api/companies/$COMPANY_ID/issues" \
  -H "Authorization: Bearer $PAPERCLIP_BOARD_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"title\": \"PAPERCLIP-WIRE-$TS: write a one-sentence summary of HTTP status codes\",
    \"assigneeAgentId\": \"$RESEARCH_AGENT_ID\",
    \"status\": \"todo\",
    \"priority\": \"high\"
  }" | jq '{id, title, status, assigneeAgentId}'
```

Paperclip's heartbeat scheduler (default ~60s cadence) wakes the assigned employee on
its next tick. You can also force-wake from the UI: open the agent's card → **Run now**.
Check the run log via `GET /api/companies/$COMPANY_ID/issues/<issue-id>/runs`.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PAPERCLIP_URL` | `http://localhost:3100` | Paperclip API base |
| `PAPERCLIP_BOARD_TOKEN` | (required) | Board-level API token |
| `COMPANY_ID` | `a5e49b0d-bd58-4239-b139-435046e9ab91` | Target company |
| `CEO_AGENT_ID` | `84a0aad9-5249-4fd6-a056-a9da9b4d1e01` | Used as `reportsTo` |
| `HERMES_BIN` | `hermes` (PATH) | Hermes CLI binary path |
| `HERMES_MODEL` | `minimax/MiniMax-M2` | Model for both agents |
| `HERMES_TIMEOUT_SEC` | `600` | Per-run timeout |
| `HERMES_MAX_TURNS` | `30` | `maxIterations` cap |

## What the v2 payload looks like

```json
{
  "name": "Research Agent",
  "title": "Senior Research Analyst",
  "role": "general",
  "reportsTo": "84a0aad9-5249-4fd6-a056-a9da9b4d1e01",
  "adapterType": "hermes_local",
  "adapterConfig": {
    "model": "minimax/MiniMax-M2",
    "hermesCommand": "/home/openclaw/.local/bin/hermes",
    "toolsets": "terminal,file,web,browser",
    "timeoutSec": 600,
    "maxIterations": 30,
    "persistSession": true,
    "quiet": true,
    "extraArgs": ["-p", "research-agent"]
  },
  "budgetMonthlyCents": 0
}
```

Note: `POST /api/companies/<id>/agents` returns **HTTP 201** (not 200) on success.

## Error handling

| Symptom | Fix |
|---------|-----|
| `Board access required` on GET /api/adapters | Token missing or expired — re-run `paperclipai auth login` |
| `hermes_local adapter not registered` | `paperclipai` version too old — upgrade to `2026.416.0+` |
| `Hermes profile 'X' not found` | Run `hermes profile create <name>` first |
| Employee status stays `error` | Check heartbeat run log in Paperclip UI; likely a missing API key in the Hermes profile |
