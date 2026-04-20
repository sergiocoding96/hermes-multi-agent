#!/usr/bin/env bash
# create-hermes-employees.sh
#
# Create Paperclip "employee" agents backed by the hermes_local adapter, one
# per Hermes profile we want the CEO to be able to delegate to. Idempotent —
# skips creation if an agent with the same name already exists in the company.
#
# Requires:
#   - hermes_local adapter installed (run install-hermes-adapter.sh first)
#   - Paperclip reachable at $PAPERCLIP_URL
#   - Target company ID known (defaults to the CEO's company)
#   - Hermes CLI ($HERMES_BIN) with the profiles referenced below

set -euo pipefail

PAPERCLIP_URL="${PAPERCLIP_URL:-http://localhost:3100}"
COMPANY_ID="${COMPANY_ID:-a5e49b0d-bd58-4239-b139-435046e9ab91}"
CEO_AGENT_ID="${CEO_AGENT_ID:-84a0aad9-5249-4fd6-a056-a9da9b4d1e01}"
HERMES_BIN="${HERMES_BIN:-$(command -v hermes || echo hermes)}"
BOARD_TOKEN="${PAPERCLIP_BOARD_TOKEN:-}"
TIMEOUT_SEC="${HERMES_TIMEOUT_SEC:-600}"
MAX_TURNS="${HERMES_MAX_TURNS:-30}"

log() { printf '[create-hermes-employees] %s\n' "$*" >&2; }
die() { printf '[create-hermes-employees] ERROR: %s\n' "$*" >&2; exit 1; }

auth_header=()
if [ -n "$BOARD_TOKEN" ]; then
  auth_header=(-H "Authorization: Bearer $BOARD_TOKEN")
fi

command -v curl >/dev/null || die "curl is required"
command -v jq   >/dev/null || die "jq is required"

# ---------------------------------------------------------------------------
# Verify prerequisites
# ---------------------------------------------------------------------------

log "Verifying hermes_local adapter is registered..."
adapters_json=$(curl -sf "${auth_header[@]}" "$PAPERCLIP_URL/api/adapters" 2>/dev/null \
  || die "GET /api/adapters failed. Run scripts/paperclip/install-hermes-adapter.sh first (and upgrade paperclipai if it 404s).")

if ! jq -e 'type == "array"' <<<"$adapters_json" >/dev/null; then
  die "GET /api/adapters did not return an array. Body: $adapters_json"
fi

if ! jq -e '.[] | select(.type == "hermes_local")' <<<"$adapters_json" >/dev/null; then
  die "hermes_local adapter not registered. Run scripts/paperclip/install-hermes-adapter.sh first."
fi

log "Verifying hermes CLI has the expected profiles..."
profiles_out=$("$HERMES_BIN" profile list 2>&1 || true)
for prof in research-agent email-marketing; do
  if ! grep -q "$prof" <<<"$profiles_out"; then
    die "Hermes profile '$prof' not found. Create it with: $HERMES_BIN profile create $prof"
  fi
done

# ---------------------------------------------------------------------------
# Fetch existing agents in company (for idempotency check)
# ---------------------------------------------------------------------------

existing=$(curl -sf "${auth_header[@]}" "$PAPERCLIP_URL/api/companies/$COMPANY_ID/agents" \
           || die "Failed to list agents in company $COMPANY_ID")

# ---------------------------------------------------------------------------
# Create an employee if it doesn't already exist
# ---------------------------------------------------------------------------

create_employee() {
  local name="$1"
  local title="$2"
  local hermes_profile="$3"
  local model="$4"
  local toolsets="$5"

  if jq -e --arg n "$name" '.[]? | select(.name == $n)' <<<"$existing" >/dev/null; then
    log "Employee '$name' already exists — skipping."
    return 0
  fi

  log "Creating employee '$name' (profile=$hermes_profile)..."

  local payload
  payload=$(jq -n \
    --arg name "$name" \
    --arg title "$title" \
    --arg reports_to "$CEO_AGENT_ID" \
    --arg model "$model" \
    --arg hermes_bin "$HERMES_BIN" \
    --arg profile "$hermes_profile" \
    --arg toolsets "$toolsets" \
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
        extraArgs: ["-p", $profile]
      },
      budgetMonthlyCents: 0
    }')

  local resp code body
  resp=$(
    curl -s -w '\n%{http_code}' \
      -X POST "$PAPERCLIP_URL/api/companies/$COMPANY_ID/agents" \
      "${auth_header[@]}" \
      -H 'Content-Type: application/json' \
      -d "$payload"
  )
  body=$(printf '%s' "$resp" | head -n -1)
  code=$(printf '%s' "$resp" | tail -n 1)

  if [ "$code" != "201" ] && [ "$code" != "200" ]; then
    die "Create '$name' failed (HTTP $code): $body"
  fi

  printf '%s\n' "$body" | jq '{id, name, adapterType, reportsTo}'
}

create_employee \
  "Research Agent" \
  "Senior Research Analyst" \
  "research-agent" \
  "minimax/MiniMax-M2" \
  "terminal,file,web,browser"

create_employee \
  "Email Marketing Agent" \
  "Email Marketing Specialist" \
  "email-marketing" \
  "minimax/MiniMax-M2" \
  "terminal,file,web"

log "Done. Both employees report to CEO ($CEO_AGENT_ID)."
log "Next: apply the updated CEO SOUL.md (scripts/paperclip/soul/CEO-SOUL.md) to the running instance."
