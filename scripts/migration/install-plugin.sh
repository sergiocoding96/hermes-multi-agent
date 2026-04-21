#!/usr/bin/env bash
#
# install-plugin.sh — install @memtensor/memos-local-hermes-plugin for a given Hermes profile.
#
# Usage:   scripts/migration/install-plugin.sh <profile>
# Example: scripts/migration/install-plugin.sh research-agent
#
# This wraps the plugin's own installer. It is idempotent: re-running with the
# same profile upgrades in place and preserves node_modules.
#
# Env overrides:
#   MEMOS_INSTALL_DIR   - where the plugin lives     (default: ~/.hermes/memos-plugin-<profile>)
#   MEMOS_STATE_DIR     - where the sqlite DB lives  (default: ~/.hermes/memos-state-<profile>)
#   MEMOS_DAEMON_PORT   - bridge daemon TCP port     (default: 18992)
#   MEMOS_VIEWER_PORT   - memory viewer HTTP port    (default: 18901)
#   PLUGIN_VERSION      - npm version tag            (default: latest)
#   NODE_BIN            - path to a Node 18..24      (default: auto-detect — plugin requires <25)
#
# Exit codes: 0 on success, non-zero on any failure.

set -euo pipefail

PROFILE="${1:-}"
if [[ -z "$PROFILE" ]]; then
  echo "usage: $0 <profile>" >&2
  exit 2
fi

# ─── Colors ───
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${BLUE}[install-plugin]${NC} $*"; }
success() { echo -e "${GREEN}[install-plugin] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[install-plugin] ⚠${NC} $*"; }
error()   { echo -e "${RED}[install-plugin] ✗${NC} $*" >&2; }

# ─── Resolve a Node binary in the supported range (>=18, <25) ───
detect_node() {
  if [[ -n "${NODE_BIN:-}" && -x "$NODE_BIN" ]]; then
    echo "$NODE_BIN"; return
  fi
  local candidates=(
    /usr/bin/node
    /usr/local/bin/node
    "$HOME/.nvm/versions/node/v22"*/bin/node
    "$HOME/.nvm/versions/node/v20"*/bin/node
    "$HOME/.nvm/versions/node/v18"*/bin/node
    /home/linuxbrew/.linuxbrew/opt/node@22/bin/node
  )
  for c in "${candidates[@]}"; do
    [[ -x "$c" ]] || continue
    local major
    major=$("$c" -v 2>/dev/null | sed 's/^v//;s/\..*//')
    if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 18 && major < 25 )); then
      echo "$c"; return
    fi
  done
  # Fall back to current PATH node if it happens to satisfy
  if command -v node >/dev/null 2>&1; then
    local major
    major=$(node -v | sed 's/^v//;s/\..*//')
    if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 18 && major < 25 )); then
      command -v node; return
    fi
  fi
  return 1
}

NODE_EXEC="$(detect_node)" || { error "No Node.js 18..24 found. Install with: sudo apt install nodejs (v22) or via nvm."; exit 1; }
NODE_DIR="$(dirname "$NODE_EXEC")"
NPM_EXEC="$NODE_DIR/npm"
[[ -x "$NPM_EXEC" ]] || NPM_EXEC="$(command -v npm || true)"

info "Profile:  $PROFILE"
info "Node:     $NODE_EXEC ($($NODE_EXEC -v))"
info "npm:      $NPM_EXEC ($($NPM_EXEC -v 2>/dev/null || echo ?))"

# ─── Paths, per-profile isolation ───
INSTALL_DIR="${MEMOS_INSTALL_DIR:-$HOME/.hermes/memos-plugin-$PROFILE}"
STATE_DIR="${MEMOS_STATE_DIR:-$HOME/.hermes/memos-state-$PROFILE}"
DAEMON_PORT="${MEMOS_DAEMON_PORT:-18992}"
VIEWER_PORT="${MEMOS_VIEWER_PORT:-18901}"
PLUGIN_VERSION="${PLUGIN_VERSION:-}"
NPM_PKG="@memtensor/memos-local-hermes-plugin"

info "Install dir: $INSTALL_DIR"
info "State dir:   $STATE_DIR"

mkdir -p "$STATE_DIR"

# ─── Check Bun too (TASK acceptance criterion — not a plugin dep) ───
if command -v bun >/dev/null 2>&1; then
  success "bun $(bun --version) present (TASK prerequisite)"
else
  warn "bun not found — plugin does not require it, but TASK Probe 1 lists it"
fi

# ─── Resolve version ───
if [[ -z "$PLUGIN_VERSION" ]]; then
  PLUGIN_VERSION="$("$NPM_EXEC" view "$NPM_PKG" dist-tags.latest 2>/dev/null | tr -d '\n')"
  [[ -n "$PLUGIN_VERSION" ]] || { error "Cannot resolve latest version of $NPM_PKG"; exit 1; }
fi
info "Version:  $PLUGIN_VERSION"

# ─── Download + extract via npm pack (idempotent) ───
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
cd "$TMP_DIR"

info "Downloading ${NPM_PKG}@${PLUGIN_VERSION}..."
"$NPM_EXEC" pack "${NPM_PKG}@${PLUGIN_VERSION}" --loglevel=error >/dev/null 2>&1
TARBALL="$(ls -1 memtensor-memos-local-hermes-plugin-*.tgz | head -1)"
[[ -f "$TARBALL" ]] || { error "npm pack produced no tarball"; exit 1; }

tar xzf "$TARBALL"
[[ -d package ]] || { error "tarball extraction failed"; exit 1; }

# ─── Preserve node_modules if re-installing ───
if [[ -d "$INSTALL_DIR/node_modules" ]]; then
  info "Preserving existing node_modules for fast reinstall"
  mv "$INSTALL_DIR/node_modules" "$TMP_DIR/_saved_node_modules"
fi

rm -rf "$INSTALL_DIR"
mkdir -p "$(dirname "$INSTALL_DIR")"
mv package "$INSTALL_DIR"

if [[ -d "$TMP_DIR/_saved_node_modules" ]]; then
  mv "$TMP_DIR/_saved_node_modules" "$INSTALL_DIR/node_modules"
fi

# ─── npm install deps (uses the Node we detected) ───
info "Running npm install (this can take a minute on first run)..."
cd "$INSTALL_DIR"
PATH="$NODE_DIR:$PATH" "$NPM_EXEC" install --no-fund --no-audit --loglevel=error 2>&1 | tail -5
success "Dependencies installed"

# ─── Verify ───
[[ -f "$INSTALL_DIR/bridge.cts" ]]   || { error "bridge.cts missing from $INSTALL_DIR"; exit 1; }
[[ -f "$INSTALL_DIR/index.ts"   ]]   || { error "index.ts missing from $INSTALL_DIR";   exit 1; }
[[ -f "$INSTALL_DIR/package.json" ]] || { error "package.json missing";                   exit 1; }

# Write an environment stub so later scripts know where we put things.
cat > "$INSTALL_DIR/.memos-env" <<EOF
# Auto-generated by install-plugin.sh on $(date -Iseconds)
MEMOS_PROFILE=$PROFILE
MEMOS_INSTALL_DIR=$INSTALL_DIR
MEMOS_STATE_DIR=$STATE_DIR
MEMOS_DAEMON_PORT=$DAEMON_PORT
MEMOS_VIEWER_PORT=$VIEWER_PORT
MEMOS_NODE_EXEC=$NODE_EXEC
MEMOS_PLUGIN_VERSION=$PLUGIN_VERSION
EOF

success "Plugin ${NPM_PKG}@${PLUGIN_VERSION} installed for profile '$PROFILE'"
info "  install_dir=$INSTALL_DIR"
info "  state_dir=$STATE_DIR"
info "  node=$NODE_EXEC"
info "  env_stub=$INSTALL_DIR/.memos-env"
exit 0
