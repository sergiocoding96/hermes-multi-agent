#!/usr/bin/env bash
#
# provision-worker-token.sh — Mint a Hermes-worker hub token.
#
# Usage:  scripts/ceo/provision-worker-token.sh <profile-name>
# Example: scripts/ceo/provision-worker-token.sh research-agent
#
# Each Hermes worker profile that pushes memories to the v1.0.3 hub needs
# its own bearer token (so the hub records the right `sourceUserId` on
# shared memories). This script joins the hub as the worker via a stable
# identityKey and writes the resulting bearer to a 0600 file.
#
# Saved at: ~/.hermes/profiles/<profile>/.hub-token (sourced by hub-sync.py)
# Idempotent via identityKey — re-running refreshes a near-expired token.

set -euo pipefail

PROFILE="${1:-}"
[[ -n "$PROFILE" ]] || { echo "usage: $0 <profile>" >&2; exit 2; }

HUB_URL="${HUB_URL:-http://127.0.0.1:18992}"
STATE_DIR="${MEMOS_STATE_DIR:-$HOME/.hermes/memos-state-research-agent}"
SECRETS_DIR="$STATE_DIR/secrets"
PROFILE_DIR="$HOME/.hermes/profiles/$PROFILE"
WORKER_ENV_FILE="$PROFILE_DIR/.hub-token"
IDENTITY_KEY="hermes-worker-${PROFILE}-v1"

[[ -d "$PROFILE_DIR" ]] || { echo "profile dir missing: $PROFILE_DIR" >&2; exit 1; }
[[ -f "$SECRETS_DIR/team-token" ]] || { echo "team-token missing: $SECRETS_DIR/team-token (run bootstrap-hub.sh first)" >&2; exit 1; }
[[ -f "$SECRETS_DIR/hub-admin-token" ]] || { echo "hub-admin-token missing: $SECRETS_DIR/hub-admin-token" >&2; exit 1; }

TEAM_TOKEN="$(cat "$SECRETS_DIR/team-token")"
ADMIN_TOKEN="$(cat "$SECRETS_DIR/hub-admin-token")"

curl -sf --max-time 5 "${HUB_URL}/api/v1/hub/info" >/dev/null || { echo "hub at $HUB_URL unreachable" >&2; exit 1; }

JOIN_RESP="$(curl -sf --max-time 10 -X POST "${HUB_URL}/api/v1/hub/join" \
  -H "Content-Type: application/json" \
  -d "{\"teamToken\":\"$TEAM_TOKEN\",\"username\":\"$PROFILE\",\"identityKey\":\"$IDENTITY_KEY\"}")"

STATUS="$(echo "$JOIN_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status",""))' 2>/dev/null || echo "")"
USER_ID="$(echo "$JOIN_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("userId",""))' 2>/dev/null || echo "")"

if [[ "$STATUS" == "active" ]]; then
  TOKEN="$(echo "$JOIN_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("userToken",""))')"
elif [[ "$STATUS" == "pending" ]]; then
  APPROVE_RESP="$(curl -sf --max-time 10 -X POST "${HUB_URL}/api/v1/hub/admin/approve-user" \
    -H "Content-Type: application/json" -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d "{\"userId\":\"$USER_ID\",\"username\":\"$PROFILE\"}")"
  TOKEN="$(echo "$APPROVE_RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')"
else
  echo "unexpected join status: $STATUS — $JOIN_RESP" >&2
  exit 1
fi

[[ -n "$TOKEN" ]] || { echo "got empty token" >&2; exit 1; }

umask 077
cat > "$WORKER_ENV_FILE" <<EOF
# Hub bearer for $PROFILE — provisioned $(date -Iseconds)
# Used by scripts/migration/hub-sync.py.
export HERMES_WORKER_HUB_URL="$HUB_URL"
export HERMES_WORKER_HUB_TOKEN="$TOKEN"
export HERMES_WORKER_HUB_USER="$PROFILE"
EOF
chmod 600 "$WORKER_ENV_FILE"
echo "✓ Worker hub token saved to $WORKER_ENV_FILE"
