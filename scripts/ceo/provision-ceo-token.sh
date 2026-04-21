#!/usr/bin/env bash
#
# provision-ceo-token.sh — Mint a CEO-specific hub token and save it.
#
# Usage:  scripts/ceo/provision-ceo-token.sh [--hub-url URL] [--state-dir DIR]
#
# What it does:
#   1. Reads team-token + bootstrap admin token from the plugin state dir.
#   2. POSTs /api/v1/hub/join as username "ceo" (idempotent via identityKey).
#   3. If the user is pending, approves it via the admin API.
#   4. Writes the CEO userToken to ~/.claude/memos-hub.env (0600, not committed).
#
# Prerequisites: hub must be running (run scripts/migration/bootstrap-hub.sh first).
# Safe to re-run: idempotent via the stable CEO_IDENTITY_KEY.

set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${BLUE}[provision-ceo]${NC} $*"; }
success() { echo -e "${GREEN}[provision-ceo] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[provision-ceo] ⚠${NC} $*"; }
error()   { echo -e "${RED}[provision-ceo] ✗${NC} $*" >&2; }

# ─── Config ───
HUB_URL="${HUB_URL:-http://localhost:18992}"
STATE_DIR="${MEMOS_STATE_DIR:-$HOME/.hermes/memos-state-research-agent}"
SECRETS_DIR="$STATE_DIR/secrets"
CEO_ENV_FILE="$HOME/.claude/memos-hub.env"

# Stable identity key so re-runs recognize the existing CEO account.
CEO_IDENTITY_KEY="ceo-claude-code-fixed-identity-v1"
CEO_USERNAME="ceo"

info "Hub URL:     $HUB_URL"
info "State dir:   $STATE_DIR"
info "Output file: $CEO_ENV_FILE"

# ─── Verify hub is alive ───
LIVENESS="$(curl -sf --max-time 5 "${HUB_URL}/api/v1/hub/info" 2>/dev/null || true)"
if [[ -z "$LIVENESS" ]]; then
  error "Hub at $HUB_URL is not responding. Run bootstrap-hub.sh first."
  exit 1
fi
info "Hub alive: $LIVENESS"

# ─── Read tokens ───
TEAM_TOKEN_FILE="$SECRETS_DIR/team-token"
ADMIN_TOKEN_FILE="$SECRETS_DIR/hub-admin-token"

if [[ ! -f "$TEAM_TOKEN_FILE" ]]; then
  error "team-token not found at $TEAM_TOKEN_FILE — run bootstrap-hub.sh first."
  exit 1
fi
if [[ ! -f "$ADMIN_TOKEN_FILE" ]]; then
  error "hub-admin-token not found at $ADMIN_TOKEN_FILE — run bootstrap-hub.sh first."
  exit 1
fi

TEAM_TOKEN="$(cat "$TEAM_TOKEN_FILE")"
ADMIN_TOKEN="$(cat "$ADMIN_TOKEN_FILE")"

# ─── Join as CEO ───
info "Joining hub as '$CEO_USERNAME' (identityKey: $CEO_IDENTITY_KEY) ..."
JOIN_RESP="$(curl -sf --max-time 10 \
  -X POST "${HUB_URL}/api/v1/hub/join" \
  -H "Content-Type: application/json" \
  -d "{\"teamToken\":\"$TEAM_TOKEN\",\"username\":\"$CEO_USERNAME\",\"identityKey\":\"$CEO_IDENTITY_KEY\"}" \
  2>/dev/null)"
info "Join response: $JOIN_RESP"

JOIN_STATUS="$(echo "$JOIN_RESP" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("status",""))' 2>/dev/null || echo "")"
USER_ID="$(echo "$JOIN_RESP" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("userId",""))' 2>/dev/null || echo "")"

# ─── If already active, extract token from join response ───
if [[ "$JOIN_STATUS" == "active" ]]; then
  CEO_TOKEN="$(echo "$JOIN_RESP" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("userToken",""))' 2>/dev/null || echo "")"
  if [[ -n "$CEO_TOKEN" ]]; then
    success "CEO user already active — reusing existing token."
  else
    # Active but token not in join response — call registration-status
    STATUS_RESP="$(curl -sf --max-time 10 \
      -X POST "${HUB_URL}/api/v1/hub/registration-status" \
      -H "Content-Type: application/json" \
      -d "{\"teamToken\":\"$TEAM_TOKEN\",\"userId\":\"$USER_ID\"}" \
      2>/dev/null)"
    CEO_TOKEN="$(echo "$STATUS_RESP" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("userToken",""))' 2>/dev/null || echo "")"
    success "CEO user already active — refreshed token via registration-status."
  fi

# ─── If pending, approve via admin API ───
elif [[ "$JOIN_STATUS" == "pending" ]]; then
  if [[ -z "$USER_ID" ]]; then
    error "Join returned pending but no userId. Response: $JOIN_RESP"
    exit 1
  fi
  info "CEO user pending (userId=$USER_ID) — approving via admin API ..."
  APPROVE_RESP="$(curl -sf --max-time 10 \
    -X POST "${HUB_URL}/api/v1/hub/admin/approve-user" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "{\"userId\":\"$USER_ID\",\"username\":\"$CEO_USERNAME\"}" \
    2>/dev/null)"
  info "Approve response: $APPROVE_RESP"
  CEO_TOKEN="$(echo "$APPROVE_RESP" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("token",""))' 2>/dev/null || echo "")"
  if [[ -z "$CEO_TOKEN" ]]; then
    error "Admin approve returned no token. Response: $APPROVE_RESP"
    exit 1
  fi
  success "CEO user approved. Token received."

# ─── Username taken (CEO already exists with different identity) ───
elif [[ "$JOIN_STATUS" == "" ]] && echo "$JOIN_RESP" | grep -q "username_taken"; then
  warn "Username '$CEO_USERNAME' is already taken. Attempting login via identityKey ..."
  # The server should have matched by identityKey already. Something's wrong.
  error "Could not resolve CEO identity. Check hub-auth.json manually."
  exit 1

else
  error "Unexpected join status '$JOIN_STATUS'. Full response: $JOIN_RESP"
  exit 1
fi

if [[ -z "$CEO_TOKEN" ]]; then
  error "CEO token is empty after all attempts. Check hub logs."
  exit 1
fi

# ─── Save to ~/.claude/memos-hub.env ───
mkdir -p "$(dirname "$CEO_ENV_FILE")"
umask 077
cat > "$CEO_ENV_FILE" << EOF
# CEO hub access credentials for memos-hub at $HUB_URL
# Generated by provision-ceo-token.sh — DO NOT COMMIT
# Regenerate: scripts/ceo/provision-ceo-token.sh
export MEMOS_HUB_URL="$HUB_URL"
export MEMOS_HUB_TOKEN="$CEO_TOKEN"
EOF
chmod 600 "$CEO_ENV_FILE"
success "Token saved to $CEO_ENV_FILE (0600)"

# ─── Verify by calling /api/v1/hub/me ───
ME_RESP="$(curl -sf --max-time 5 \
  "${HUB_URL}/api/v1/hub/me" \
  -H "Authorization: Bearer $CEO_TOKEN" \
  2>/dev/null || true)"
info "Verification (/me): $ME_RESP"
ME_USERNAME="$(echo "$ME_RESP" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("username",""))' 2>/dev/null || echo "")"
if [[ "$ME_USERNAME" == "$CEO_USERNAME" ]]; then
  success "Token verified — authenticated as '$ME_USERNAME'."
else
  warn "Verification returned unexpected username: '$ME_USERNAME'. Full: $ME_RESP"
fi

echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│ CEO TOKEN PROVISIONED                                       │"
echo "├─────────────────────────────────────────────────────────────┤"
printf "│ Username:  %-47s│\n" "$CEO_USERNAME"
printf "│ Saved to:  %-47s│\n" "$CEO_ENV_FILE"
printf "│ Hub URL:   %-47s│\n" "$HUB_URL"
echo "│                                                             │"
echo "│ Usage:                                                      │"
echo "│   source ~/.claude/memos-hub.env                           │"
echo "│   bash scripts/ceo/memos-search.sh \"your query\"            │"
echo "└─────────────────────────────────────────────────────────────┘"
