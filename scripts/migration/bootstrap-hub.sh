#!/usr/bin/env bash
#
# bootstrap-hub.sh — start @memtensor/memos-local-hermes-plugin in HUB mode
#
# Usage:  scripts/migration/bootstrap-hub.sh <profile>
# Example: scripts/migration/bootstrap-hub.sh research-agent
#
# Prereq: install-plugin.sh has been run for <profile>.
#
# What it does:
#   1. Loads the env stub written by install-plugin.sh
#   2. Generates (or reuses) a teamToken for the ceo-team group
#   3. Launches the plugin's bridge in daemon mode with sharing.role=hub
#   4. Waits for /api/v1/hub/info to respond, proving the hub is live
#   5. Locks hub-auth.json to 0600 and copies the bootstrap admin token
#      into a separate 0600 file (NOT committed — see .gitignore)
#
# Env overrides:
#   TEAM_NAME        default "ceo-team"
#   HUB_PORT         default 18992   (the hub HTTP server port — matches TASK)
#   DAEMON_PORT      default 18990   (the bridge JSON-RPC TCP port)
#   VIEWER_PORT      default 18901
#
# Exit codes: 0 on success, non-zero on failure.

set -euo pipefail

PROFILE="${1:-}"
if [[ -z "$PROFILE" ]]; then
  echo "usage: $0 <profile>" >&2
  exit 2
fi

# ─── Colors ───
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${BLUE}[bootstrap-hub]${NC} $*"; }
success() { echo -e "${GREEN}[bootstrap-hub] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[bootstrap-hub] ⚠${NC} $*"; }
error()   { echo -e "${RED}[bootstrap-hub] ✗${NC} $*" >&2; }

# ─── Load env stub ───
INSTALL_DIR="${MEMOS_INSTALL_DIR:-$HOME/.hermes/memos-plugin-$PROFILE}"
ENV_STUB="$INSTALL_DIR/.memos-env"
if [[ -f "$ENV_STUB" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_STUB"
else
  warn "No $ENV_STUB — did you run install-plugin.sh $PROFILE first? Using defaults."
fi

STATE_DIR="${MEMOS_STATE_DIR:-$HOME/.hermes/memos-state-$PROFILE}"
NODE_EXEC="${MEMOS_NODE_EXEC:-/usr/bin/node}"
TEAM_NAME="${TEAM_NAME:-ceo-team}"
HUB_PORT="${HUB_PORT:-18992}"
DAEMON_PORT="${DAEMON_PORT:-18990}"
VIEWER_PORT="${VIEWER_PORT:-18901}"

# Secrets dir per profile — never committed
SECRETS_DIR="$STATE_DIR/secrets"
mkdir -p "$SECRETS_DIR" "$STATE_DIR/logs"
chmod 700 "$SECRETS_DIR"

TEAM_TOKEN_FILE="$SECRETS_DIR/team-token"
ADMIN_TOKEN_FILE="$SECRETS_DIR/hub-admin-token"
HUB_AUTH_FILE="$STATE_DIR/hub-auth.json"

info "Profile:      $PROFILE"
info "Install dir:  $INSTALL_DIR"
info "State dir:    $STATE_DIR"
info "Node:         $NODE_EXEC ($($NODE_EXEC -v 2>/dev/null || echo ?))"
info "Team name:    $TEAM_NAME"
info "Hub port:     $HUB_PORT"
info "Daemon port:  $DAEMON_PORT"
info "Viewer port:  $VIEWER_PORT"

# ─── Sanity ───
[[ -f "$INSTALL_DIR/bridge.cts" ]] || { error "bridge.cts not at $INSTALL_DIR — run install-plugin.sh first"; exit 1; }
command -v "$NODE_EXEC" >/dev/null 2>&1 || { error "Node not executable: $NODE_EXEC"; exit 1; }

# ─── Generate or reuse team token ───
if [[ -f "$TEAM_TOKEN_FILE" ]]; then
  TEAM_TOKEN="$(cat "$TEAM_TOKEN_FILE")"
  info "Reusing existing team token from $TEAM_TOKEN_FILE"
else
  TEAM_TOKEN="$("$NODE_EXEC" -e 'console.log(require("crypto").randomBytes(24).toString("hex"))')"
  umask 077
  printf '%s' "$TEAM_TOKEN" > "$TEAM_TOKEN_FILE"
  chmod 600 "$TEAM_TOKEN_FILE"
  success "Generated new team token — stored at $TEAM_TOKEN_FILE (0600)"
fi

# ─── Build bridge config ───
# The plugin reads this JSON via MEMOS_BRIDGE_CONFIG env var.
# Shape per bridge.cts: { stateDir, workspaceDir, config: { ...plugin config } }
# Env vars must precede the command so they become environment, not argv.
BRIDGE_CONFIG="$(STATE_DIR="$STATE_DIR" INSTALL_DIR="$INSTALL_DIR" HUB_PORT="$HUB_PORT" TEAM_NAME="$TEAM_NAME" TEAM_TOKEN="$TEAM_TOKEN" "$NODE_EXEC" -e "
const cfg = {
  stateDir: process.env.STATE_DIR,
  workspaceDir: process.env.INSTALL_DIR,
  config: {
    embedding: { provider: 'local' },
    sharing: {
      enabled: true,
      role: 'hub',
      hub: {
        port: parseInt(process.env.HUB_PORT, 10),
        teamName: process.env.TEAM_NAME,
        teamToken: process.env.TEAM_TOKEN,
      }
    },
    telemetry: { enabled: false }
  }
};
process.stdout.write(JSON.stringify(cfg));
")"

# ─── Kill any previous daemon bound to our ports ───
if pgrep -f "bridge.cts.*--daemon.*${DAEMON_PORT}" >/dev/null 2>&1; then
  info "Stopping previous daemon on port $DAEMON_PORT"
  pkill -f "bridge.cts.*--daemon.*${DAEMON_PORT}" 2>/dev/null || true
  sleep 1
fi

# Also free hub port if something stale occupies it
if command -v fuser >/dev/null 2>&1; then
  fuser -k "${HUB_PORT}/tcp" 2>/dev/null || true
fi

# ─── Stage hub-launcher.cts inside the plugin dir ───
# bridge.cts daemon mode does NOT start the HubServer — the hub is only
# wired by the OpenHarness plugin entry (index.ts). We stage a standalone
# launcher that instantiates HubServer directly; it must live inside the
# plugin dir so its relative "./src/..." imports resolve.
LAUNCHER_SRC="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/hub-launcher.cts"
LAUNCHER_DST="$INSTALL_DIR/hub-launcher.cts"
if [[ ! -f "$LAUNCHER_SRC" ]]; then
  error "hub-launcher.cts not found next to bootstrap-hub.sh at: $LAUNCHER_SRC"
  exit 1
fi
cp "$LAUNCHER_SRC" "$LAUNCHER_DST"
info "Staged hub-launcher.cts at $LAUNCHER_DST"

LOG_FILE="$STATE_DIR/logs/hub.log"
info "Starting hub (logs: $LOG_FILE)"

# Use nohup + disown so it survives this shell exiting
cd "$INSTALL_DIR"
MEMOS_BRIDGE_CONFIG="$BRIDGE_CONFIG" \
MEMOS_STATE_DIR="$STATE_DIR" \
TELEMETRY_ENABLED=false \
PATH="$(dirname "$NODE_EXEC"):$PATH" \
  nohup "$NODE_EXEC" \
    "$INSTALL_DIR/node_modules/tsx/dist/cli.mjs" \
    "$LAUNCHER_DST" \
  > "$LOG_FILE" 2>&1 &
DAEMON_PID=$!
disown "$DAEMON_PID" || true
echo "$DAEMON_PID" > "$STATE_DIR/hub.pid"
info "Hub PID: $DAEMON_PID"

# ─── Wait for hub to respond on /api/v1/hub/info ───
# Note: The plugin exposes GET /api/v1/hub/info as its liveness probe
# (no /health endpoint exists in the hub router as of v1.0.3).
HUB_URL="http://127.0.0.1:${HUB_PORT}"
info "Waiting for hub on $HUB_URL ..."
ATTEMPTS=60
for i in $(seq 1 $ATTEMPTS); do
  if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    error "Daemon process died. Last 30 lines of log:"
    tail -30 "$LOG_FILE" >&2 || true
    exit 1
  fi
  RESP="$(curl -sf --max-time 2 "${HUB_URL}/api/v1/hub/info" 2>/dev/null || true)"
  if [[ -n "$RESP" ]]; then
    success "Hub live after ${i}s: $RESP"
    break
  fi
  sleep 1
  if (( i == ATTEMPTS )); then
    error "Hub did not respond within ${ATTEMPTS}s. Last 40 lines of log:"
    tail -40 "$LOG_FILE" >&2 || true
    exit 1
  fi
done

# ─── Verify team name ───
TEAM_FROM_HUB="$("$NODE_EXEC" -e 'const d=JSON.parse(process.argv[1]); process.stdout.write(d.teamName||"");' "$RESP")"
if [[ "$TEAM_FROM_HUB" != "$TEAM_NAME" ]]; then
  error "Hub teamName mismatch: got '$TEAM_FROM_HUB', expected '$TEAM_NAME'"
  exit 1
fi
success "Hub advertises teamName='$TEAM_NAME'"

# ─── Secure and extract bootstrap admin token ───
if [[ -f "$HUB_AUTH_FILE" ]]; then
  chmod 600 "$HUB_AUTH_FILE"
  ADMIN_TOKEN="$("$NODE_EXEC" -e 'const fs=require("fs");const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(d.bootstrapAdminToken||"");' "$HUB_AUTH_FILE")"
  if [[ -n "$ADMIN_TOKEN" ]]; then
    umask 077
    printf '%s' "$ADMIN_TOKEN" > "$ADMIN_TOKEN_FILE"
    chmod 600 "$ADMIN_TOKEN_FILE"
    success "Bootstrap admin token saved to $ADMIN_TOKEN_FILE (0600)"
  else
    warn "hub-auth.json has no bootstrapAdminToken field — did hub finish starting?"
  fi
else
  warn "hub-auth.json not yet written at $HUB_AUTH_FILE"
fi

# ─── Verify the ceo-team group is queryable via /hub/info ───
success "ceo-team team is live (single-team-per-hub model — teamName is its ID)"

echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│ HUB BOOTSTRAP COMPLETE                                      │"
echo "├─────────────────────────────────────────────────────────────┤"
printf "│ Team:           %-43s│\n" "$TEAM_NAME"
printf "│ Hub URL:        %-43s│\n" "$HUB_URL"
printf "│ Daemon:         127.0.0.1:%-31s│\n" "$DAEMON_PORT (JSON-RPC)"
printf "│ Viewer:         http://127.0.0.1:%-25s│\n" "$VIEWER_PORT"
printf "│ PID:            %-43s│\n" "$DAEMON_PID"
printf "│ Log:            %-43s│\n" "$LOG_FILE"
printf "│ Team token:     %-43s│\n" "$TEAM_TOKEN_FILE (0600)"
printf "│ Admin token:    %-43s│\n" "$ADMIN_TOKEN_FILE (0600)"
echo "└─────────────────────────────────────────────────────────────┘"
exit 0
