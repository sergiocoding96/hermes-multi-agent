#!/usr/bin/env bash
# apply-ceo-soul.sh
#
# Copy the canonical CEO SOUL.md from this repo to the running Paperclip
# instance's CEO agent instructions directory, backing up the previous version.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/soul/CEO-SOUL.md"
DEST="${CEO_SOUL_PATH:-$HOME/.paperclip/instances/default/companies/a5e49b0d-bd58-4239-b139-435046e9ab91/agents/84a0aad9-5249-4fd6-a056-a9da9b4d1e01/instructions/SOUL.md}"

log() { printf '[apply-ceo-soul] %s\n' "$*" >&2; }
die() { printf '[apply-ceo-soul] ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$SRC" ]  || die "Source not found: $SRC"
[ -d "$(dirname "$DEST")" ] || die "Destination directory missing: $(dirname "$DEST"). Wrong company/agent id?"

if [ -f "$DEST" ] && cmp -s "$SRC" "$DEST"; then
  log "SOUL.md already up to date at $DEST"
  exit 0
fi

if [ -f "$DEST" ]; then
  backup="$DEST.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$DEST" "$backup"
  log "Backed up existing SOUL.md -> $backup"
fi

cp "$SRC" "$DEST"
log "Wrote $DEST"
log "You may need to restart the CEO agent session for the new SOUL.md to take effect."
