#!/usr/bin/env bash
#
# install-infra.sh — install the systemd unit that keeps the v1 MemOS server
# auto-restarting on crash.
#
# Run once on a fresh machine after:
#   1. ./setup-web-stack.sh (Firecrawl, SearXNG, Camofox)
#   2. MemOS installed: pip install git+https://github.com/sergiocoding96/memos
#   3. deploy/scripts/setup-memos-agents.py (creates users/cubes + API keys)
#
# Idempotent: re-running is safe.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[install-infra]${NC} $*"; }
success() { echo -e "${GREEN}[install-infra] ✓${NC} $*"; }

# ─── systemd user unit ───
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"
cp "$REPO/deploy/systemd/memos-server.service" "$SYSTEMD_USER_DIR/memos-server.service"
systemctl --user daemon-reload
systemctl --user enable --now memos-server.service
success "memos-server.service enabled + started"

# ─── linger so the unit survives logout ───
if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
  info "Enabling user lingering (sudo required) ..."
  sudo loginctl enable-linger "$USER" && success "linger=yes for $USER"
fi

echo ""
success "Infra installed. MemOS server: systemctl --user status memos-server.service"
