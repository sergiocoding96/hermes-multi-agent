#!/usr/bin/env bash
#
# configure-plugin-skill-output.sh — redirect the MemOS plugin's skill-output
# directory to ~/Coding/badass-skills/auto/.
#
# The plugin hardcodes its skill output path to:
#   <stateDir>/skills-store/
#
# This script replaces that directory with a symlink so generated SKILL.md files
# land in ~/Coding/badass-skills/auto/ instead, making them visible to both
# Hermes workers (via external_dirs) and Claude Code CEO (via ~/.claude/skills/).
#
# Idempotent:
#   - skills-store is already a correct symlink → no-op
#   - skills-store is a real directory → migrate contents to auto/, replace with symlink
#   - skills-store doesn't exist → create symlink
#
# Covers all ~/.hermes/memos-state-* directories found on this machine.
#
# Usage: bash scripts/migration/configure-plugin-skill-output.sh

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[plugin-skill-cfg]${NC} $*"; }
success() { echo -e "${GREEN}[plugin-skill-cfg] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[plugin-skill-cfg] ⚠${NC} $*"; }
error()   { echo -e "${RED}[plugin-skill-cfg] ✗${NC} $*" >&2; }

BADASS_AUTO_DIR="${BADASS_AUTO_DIR:-$HOME/Coding/badass-skills/auto}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"

info "Skill output target : $BADASS_AUTO_DIR"
info "Hermes home         : $HERMES_HOME"

# Create the auto/ subdir in badass-skills
mkdir -p "$BADASS_AUTO_DIR"
success "Ensured $BADASS_AUTO_DIR exists"

any_found=0

for state_dir in "$HERMES_HOME"/memos-state-*/; do
  [[ -d "$state_dir" ]] || continue
  any_found=1
  profile_name=$(basename "$state_dir")
  skills_store="$state_dir/skills-store"

  info "Processing $profile_name ..."

  if [[ -L "$skills_store" ]]; then
    resolved=$(readlink -f "$skills_store" 2>/dev/null || true)
    expected=$(readlink -f "$BADASS_AUTO_DIR")
    if [[ "$resolved" == "$expected" ]]; then
      success "$profile_name/skills-store → already correct symlink, no-op"
      continue
    else
      warn "$profile_name/skills-store is a symlink but points to $resolved (expected $expected)"
      warn "Removing old symlink and replacing with correct one."
      rm "$skills_store"
    fi
  elif [[ -d "$skills_store" ]]; then
    # Real directory: migrate any existing skill dirs into auto/
    skill_count=$(find "$skills_store" -mindepth 1 -maxdepth 1 -type d | wc -l)
    if (( skill_count > 0 )); then
      info "Migrating $skill_count skill(s) from $skills_store → $BADASS_AUTO_DIR"
      for skill_subdir in "$skills_store"/*/; do
        [[ -d "$skill_subdir" ]] || continue
        skill_subname=$(basename "$skill_subdir")
        dest="$BADASS_AUTO_DIR/$skill_subname"
        if [[ -e "$dest" ]]; then
          warn "  $skill_subname already exists in auto/ — skipping migration of this one"
        else
          mv "$skill_subdir" "$dest"
          success "  Moved $skill_subname → auto/"
        fi
      done
    else
      info "skills-store is empty, nothing to migrate"
    fi
    rmdir "$skills_store" 2>/dev/null || {
      warn "Could not rmdir $skills_store (non-empty?). Removing with rm -rf."
      rm -rf "$skills_store"
    }
  fi

  # Create the symlink
  ln -s "$BADASS_AUTO_DIR" "$skills_store"
  success "$profile_name/skills-store → $BADASS_AUTO_DIR"
done

if (( any_found == 0 )); then
  warn "No memos-state-* directories found under $HERMES_HOME."
  warn "Run scripts/migration/install-plugin.sh <profile> first."
  exit 1
fi

echo ""
info "Final state of $BADASS_AUTO_DIR:"
ls -la "$BADASS_AUTO_DIR" 2>/dev/null || info "(empty)"

echo ""
info "Symlink verification:"
for state_dir in "$HERMES_HOME"/memos-state-*/; do
  [[ -d "$state_dir" ]] || continue
  profile_name=$(basename "$state_dir")
  skills_store="$state_dir/skills-store"
  if [[ -L "$skills_store" ]]; then
    resolved=$(readlink -f "$skills_store")
    echo "  $profile_name/skills-store -> $resolved"
  else
    warn "  $profile_name/skills-store is NOT a symlink!"
  fi
done
