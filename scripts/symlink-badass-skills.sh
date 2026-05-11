#!/usr/bin/env bash
#
# symlink-badass-skills.sh — symlink ~/Coding/badass-skills/* into ~/.claude/skills/
#
# Creates ~/.claude/skills/ if needed, then for each top-level skill directory
# in ~/Coding/badass-skills/ creates a relative symlink in ~/.claude/skills/.
#
# Idempotent:
#   - Symlink already correct  → no-op
#   - Symlink exists but wrong → warn, skip
#   - Real file/dir exists     → warn, skip
#   - No entry exists          → create symlink
#
# Usage: bash scripts/migration/symlink-badass-skills.sh

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[symlink-skills]${NC} $*"; }
success() { echo -e "${GREEN}[symlink-skills] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[symlink-skills] ⚠${NC} $*"; }
error()   { echo -e "${RED}[symlink-skills] ✗${NC} $*" >&2; }

BADASS_SKILLS_DIR="${BADASS_SKILLS_DIR:-$HOME/Coding/badass-skills}"
CLAUDE_SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"

if [[ ! -d "$BADASS_SKILLS_DIR" ]]; then
  error "Source directory not found: $BADASS_SKILLS_DIR"
  exit 1
fi

info "Source : $BADASS_SKILLS_DIR"
info "Target : $CLAUDE_SKILLS_DIR"

mkdir -p "$CLAUDE_SKILLS_DIR"
info "Ensured $CLAUDE_SKILLS_DIR exists"

created=0
skipped=0
warned=0

for skill_dir in "$BADASS_SKILLS_DIR"/*/; do
  [[ -d "$skill_dir" ]] || continue
  skill_name=$(basename "$skill_dir")
  target="$CLAUDE_SKILLS_DIR/$skill_name"
  # Absolute path of source (no trailing slash for symlink)
  src="${skill_dir%/}"

  if [[ -L "$target" ]]; then
    resolved=$(readlink -f "$target" 2>/dev/null || true)
    if [[ "$resolved" == "$(readlink -f "$src")" ]]; then
      success "$skill_name → already correct, no-op"
      (( skipped++ )) || true
    else
      warn "$skill_name → symlink exists but points elsewhere ($resolved). Skipping."
      (( warned++ )) || true
    fi
  elif [[ -e "$target" ]]; then
    warn "$skill_name → a real file/dir exists at $target. Skipping."
    (( warned++ )) || true
  else
    ln -s "$src" "$target"
    success "$skill_name → created symlink $target → $src"
    (( created++ )) || true
  fi
done

echo ""
info "Done. Created=$created  Already-correct=$skipped  Warned=$warned"

if (( warned > 0 )); then
  warn "Some symlinks were skipped — review warnings above."
fi

echo ""
info "Current ~/.claude/skills/ contents:"
ls -la "$CLAUDE_SKILLS_DIR"
