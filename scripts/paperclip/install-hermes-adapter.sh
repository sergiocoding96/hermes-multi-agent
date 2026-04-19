#!/usr/bin/env bash
# install-hermes-adapter.sh
#
# Install the hermes-paperclip-adapter into a running Paperclip instance so
# Paperclip can spawn Hermes workers as "managed employees". Idempotent.
#
# Requires:
#   - Paperclip running at $PAPERCLIP_URL (default: http://localhost:3100)
#     and serving /api/adapters (paperclipai with external-adapter support).
#   - npm available on the host running Paperclip.
#
# References:
#   - hermes-paperclip-adapter: https://www.npmjs.com/package/hermes-paperclip-adapter
#   - Paperclip external adapter docs: paperclip-desktop/docs/adapters/external-adapters.md

set -euo pipefail

PAPERCLIP_URL="${PAPERCLIP_URL:-http://localhost:3100}"
ADAPTER_PACKAGE="${ADAPTER_PACKAGE:-hermes-paperclip-adapter}"
ADAPTER_VERSION="${ADAPTER_VERSION:-}"    # leave blank for latest
ADAPTER_TYPE="${ADAPTER_TYPE:-hermes_local}"  # matches createServerAdapter().type in the npm package
BOARD_TOKEN="${PAPERCLIP_BOARD_TOKEN:-}"  # only needed for non-local deployments

log()  { printf '[install-hermes-adapter] %s\n' "$*" >&2; }
die()  { printf '[install-hermes-adapter] ERROR: %s\n' "$*" >&2; exit 1; }

auth_header=()
if [ -n "$BOARD_TOKEN" ]; then
  auth_header=(-H "Authorization: Bearer $BOARD_TOKEN")
fi

# ---------------------------------------------------------------------------
# 1. Preconditions
# ---------------------------------------------------------------------------

command -v curl >/dev/null || die "curl is required"
command -v jq   >/dev/null || die "jq is required"

log "Paperclip URL: $PAPERCLIP_URL"

if ! curl -sf "$PAPERCLIP_URL/" >/dev/null 2>&1; then
  die "Paperclip is not reachable at $PAPERCLIP_URL. Start it first (paperclipai run)."
fi

# Probe for the adapter-install route. Older paperclipai releases (<= 2026.325.0)
# do not ship the external-adapter plugin system and will 404 here.
adapters_list_code=$(
  curl -s -o /dev/null -w '%{http_code}' \
    "${auth_header[@]}" \
    "$PAPERCLIP_URL/api/adapters"
)

if [ "$adapters_list_code" = "404" ]; then
  die "GET $PAPERCLIP_URL/api/adapters returned 404. Your paperclipai is too old to support external adapters. Upgrade: npm install -g paperclipai@latest && restart the server."
fi

if [ "$adapters_list_code" != "200" ]; then
  die "GET /api/adapters returned HTTP $adapters_list_code. Check server logs and $BOARD_TOKEN if remote."
fi

# ---------------------------------------------------------------------------
# 2. Idempotency — skip if already registered
# ---------------------------------------------------------------------------

if curl -s "${auth_header[@]}" "$PAPERCLIP_URL/api/adapters" \
     | jq -e --arg t "$ADAPTER_TYPE" '.[] | select(.type == $t)' >/dev/null
then
  log "Adapter '$ADAPTER_TYPE' already registered — skipping install."
  curl -s "${auth_header[@]}" "$PAPERCLIP_URL/api/adapters" \
    | jq --arg t "$ADAPTER_TYPE" '.[] | select(.type == $t)'
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Install
# ---------------------------------------------------------------------------

payload=$(jq -n \
  --arg pkg "$ADAPTER_PACKAGE" \
  --arg ver "$ADAPTER_VERSION" \
  '{packageName: $pkg} + (if $ver == "" then {} else {version: $ver} end)')

log "Installing $ADAPTER_PACKAGE${ADAPTER_VERSION:+@$ADAPTER_VERSION} via Paperclip API..."

response=$(
  curl -s -w '\n%{http_code}' \
    -X POST "$PAPERCLIP_URL/api/adapters/install" \
    "${auth_header[@]}" \
    -H 'Content-Type: application/json' \
    -d "$payload"
)

body=$(printf '%s' "$response" | head -n -1)
code=$(printf '%s' "$response" | tail -n 1)

if [ "$code" != "201" ]; then
  die "Install failed (HTTP $code): $body"
fi

log "Adapter installed:"
printf '%s\n' "$body" | jq .

# ---------------------------------------------------------------------------
# 4. Verify
# ---------------------------------------------------------------------------

log "Verifying registration..."

registered=$(
  curl -s "${auth_header[@]}" "$PAPERCLIP_URL/api/adapters" \
    | jq --arg t "$ADAPTER_TYPE" '.[] | select(.type == $t)'
)

if [ -z "$registered" ]; then
  die "Adapter '$ADAPTER_TYPE' was installed but does not appear in /api/adapters."
fi

printf '%s\n' "$registered" | jq .

log "Done. Next: scripts/paperclip/create-hermes-employees.sh"
