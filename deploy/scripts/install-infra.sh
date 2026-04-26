#!/usr/bin/env bash
#
# install-infra.sh — install the systemd unit + cron entries that keep
# the v1.0.3 MemOS hub running and the worker→hub sync ticking.
#
# Run once on a fresh machine after:
#   1. ./setup-web-stack.sh (Firecrawl, SearXNG, Camofox)
#   2. plugin install: scripts/migration/install-plugin.sh research-agent
#   3. hub bootstrap: scripts/migration/bootstrap-hub.sh research-agent
#   4. CEO token: scripts/ceo/provision-ceo-token.sh
#   5. worker token: scripts/ceo/provision-worker-token.sh research-agent
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
cp "$REPO/deploy/systemd/memos-hub.service" "$SYSTEMD_USER_DIR/memos-hub.service"
systemctl --user daemon-reload
systemctl --user enable --now memos-hub.service
success "memos-hub.service enabled + started"

# ─── linger so the unit survives logout ───
if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
  info "Enabling user lingering (sudo required) ..."
  sudo loginctl enable-linger "$USER" && success "linger=yes for $USER"
fi

# ─── cron entries ───
TMP_CRON="$(mktemp)"
crontab -l 2>/dev/null > "$TMP_CRON" || true
# Append entries that aren't already present.
while IFS= read -r line; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue
  if ! grep -qF -- "$line" "$TMP_CRON"; then
    echo "$line" >> "$TMP_CRON"
    info "+ cron: $line"
  fi
done < "$REPO/deploy/cron/hermes-memos.crontab"
crontab "$TMP_CRON"
rm -f "$TMP_CRON"
success "cron entries installed"

echo ""
success "Infra installed. Hub: systemctl --user status memos-hub.service"
