#!/usr/bin/env bash
#
# install-infra.sh — install the cron entries that drive Hermes + MemOS
# maintenance on this host.
#
# Run once on a fresh machine after:
#   1. ./setup-web-stack.sh (Firecrawl, SearXNG, Camofox)
#   2. MemOS server provisioning (see deploy/README.md)
#
# Idempotent: re-running is safe.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[install-infra]${NC} $*"; }
success() { echo -e "${GREEN}[install-infra] ✓${NC} $*"; }

# ─── linger so user-level services survive logout ───
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
success "Infra installed."
