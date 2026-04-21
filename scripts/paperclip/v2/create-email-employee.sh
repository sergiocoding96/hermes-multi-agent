#!/usr/bin/env bash
# create-email-employee.sh
#
# Create the "email-marketing-agent" Paperclip employee backed by the
# hermes_local adapter (built into Paperclip — no separate install needed).
#
# Idempotent: skips creation if an agent using the email-marketing profile
# already exists in the company.
#
# Usage:
#   PAPERCLIP_BOARD_TOKEN=<token> ./create-email-employee.sh
#
# See README.md for how to obtain PAPERCLIP_BOARD_TOKEN.

set -euo pipefail

PAPERCLIP_URL="${PAPERCLIP_URL:-http://localhost:3100}"
COMPANY_ID="${COMPANY_ID:-a5e49b0d-bd58-4239-b139-435046e9ab91}"
CEO_AGENT_ID="${CEO_AGENT_ID:-84a0aad9-5249-4fd6-a056-a9da9b4d1e01}"
HERMES_BIN="${HERMES_BIN:-$(command -v hermes || echo hermes)}"
BOARD_TOKEN="${PAPERCLIP_BOARD_TOKEN:-}"
TIMEOUT_SEC="${HERMES_TIMEOUT_SEC:-600}"
MAX_TURNS="${HERMES_MAX_TURNS:-30}"

PROFILE="email-marketing"
AGENT_NAME="Email Marketing Agent"
AGENT_TITLE="Email Marketing Specialist"
MODEL="${HERMES_MODEL:-minimax/MiniMax-M2}"
TOOLSETS="terminal,file,web"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_TEMPLATE_FILE="${PROMPT_TEMPLATE_FILE:-$SCRIPT_DIR/prompts/hermes-employee.mustache}"

log() { printf '[create-email-employee] %s\n' "$*" >&2; }
die() { printf '[create-email-employee] ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$PROMPT_TEMPLATE_FILE" ] || die "Prompt template not found at $PROMPT_TEMPLATE_FILE"

command -v curl >/dev/null || die "curl is required"
command -v jq   >/dev/null || die "jq is required"

[ -n "$BOARD_TOKEN" ] || die "PAPERCLIP_BOARD_TOKEN is not set. See README.md for how to obtain it."

AUTH=(-H "Authorization: Bearer $BOARD_TOKEN")

# ---------------------------------------------------------------------------
# 1. Verify hermes_local adapter is registered
# ---------------------------------------------------------------------------

log "Checking hermes_local adapter..."
adapters_json=$(curl -sf "${AUTH[@]}" "$PAPERCLIP_URL/api/adapters" \
  || die "GET /api/adapters failed — is Paperclip running at $PAPERCLIP_URL?")

if ! echo "$adapters_json" | jq -e '.[] | select(.type == "hermes_local")' >/dev/null 2>&1; then
  die "hermes_local adapter is not registered. Upgrade paperclipai: npm i -g paperclipai@latest and restart."
fi
log "hermes_local adapter: OK"

# ---------------------------------------------------------------------------
# 2. Check hermes profile exists
# ---------------------------------------------------------------------------

log "Checking Hermes profile '$PROFILE'..."
if ! "$HERMES_BIN" profile list 2>&1 | grep -q "$PROFILE"; then
  die "Hermes profile '$PROFILE' not found. Create it with: $HERMES_BIN profile create $PROFILE"
fi
log "Hermes profile: OK"

# ---------------------------------------------------------------------------
# 3. Idempotency check — look for existing agent using this profile
# ---------------------------------------------------------------------------

existing=$(curl -sf "${AUTH[@]}" "$PAPERCLIP_URL/api/companies/$COMPANY_ID/agents" \
  || die "Failed to list agents in company $COMPANY_ID")

existing_id=$(echo "$existing" | jq -r --arg p "$PROFILE" '
  .[] | select(
    .adapterType == "hermes_local" and
    (.adapterConfig.extraArgs // [] | map(tostring) | join(" ") | contains($p))
  ) | .id' | head -1)

if [ -n "$existing_id" ]; then
  log "Employee using profile '$PROFILE' already exists (id=$existing_id) — skipping creation."
  echo "$existing" | jq --arg id "$existing_id" '.[] | select(.id == $id) | {id, name, adapterType, status, reportsTo}'
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Create the employee
# ---------------------------------------------------------------------------

log "Creating employee '$AGENT_NAME' (profile=$PROFILE, model=$MODEL)..."

payload=$(jq -n \
  --arg name "$AGENT_NAME" \
  --arg title "$AGENT_TITLE" \
  --arg reports_to "$CEO_AGENT_ID" \
  --arg model "$MODEL" \
  --arg hermes_bin "$HERMES_BIN" \
  --arg profile "$PROFILE" \
  --arg toolsets "$TOOLSETS" \
  --arg cwd "$HOME" \
  --rawfile prompt_template "$PROMPT_TEMPLATE_FILE" \
  --argjson timeout "$TIMEOUT_SEC" \
  --argjson max_turns "$MAX_TURNS" \
  '{
    name: $name,
    title: $title,
    role: "general",
    reportsTo: $reports_to,
    adapterType: "hermes_local",
    adapterConfig: {
      model: $model,
      hermesCommand: $hermes_bin,
      toolsets: $toolsets,
      timeoutSec: $timeout,
      maxIterations: $max_turns,
      persistSession: true,
      quiet: true,
      cwd: $cwd,
      extraArgs: ["-p", $profile],
      promptTemplate: $prompt_template
    },
    budgetMonthlyCents: 0
  }')

resp=$(curl -s -w '\n%{http_code}' \
  -X POST "$PAPERCLIP_URL/api/companies/$COMPANY_ID/agents" \
  "${AUTH[@]}" \
  -H 'Content-Type: application/json' \
  -d "$payload")
body=$(printf '%s' "$resp" | head -n -1)
code=$(printf '%s' "$resp" | tail -n 1)

if [ "$code" != "201" ] && [ "$code" != "200" ]; then
  die "Create '$AGENT_NAME' failed (HTTP $code): $body"
fi

log "Created (HTTP $code):"
printf '%s\n' "$body" | jq '{id, name, adapterType, reportsTo, status}'
