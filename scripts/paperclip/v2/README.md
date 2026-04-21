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

# Create research-agent employee (idempotent — safe to re-run)
PAPERCLIP_BOARD_TOKEN="$PAPERCLIP_BOARD_TOKEN" ./create-research-employee.sh

# Create email-marketing-agent employee (idempotent — safe to re-run)
PAPERCLIP_BOARD_TOKEN="$PAPERCLIP_BOARD_TOKEN" ./create-email-employee.sh
```

Both scripts:
- Verify `hermes_local` is registered before doing anything
- Check that the target Hermes profile exists
- Skip creation if an agent using that profile already exists in the company
- Print the resulting agent JSON on success

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
