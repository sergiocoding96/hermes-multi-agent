#!/usr/bin/env bash
# setup-fix-worktrees.sh — Create worktrees for the v1 MVP fix sprint.
#
# Idempotent. Safe to re-run (existing worktrees skipped).
#
# Usage:
#   bash scripts/worktrees/fix-mvp/setup-fix-worktrees.sh        # create
#   bash scripts/worktrees/fix-mvp/setup-fix-worktrees.sh --dry  # preview
set -euo pipefail

HERMES_REPO="${HERMES_REPO:-$HOME/Coding/Hermes}"
HERMES_WT="${HERMES_WT:-$HOME/Coding/Hermes-wt}"
BRIEF_DIR="$HERMES_REPO/scripts/worktrees/fix-mvp"

DRY_RUN=0
[[ "${1:-}" == "--dry" ]] && DRY_RUN=1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
info() { echo -e "${BLUE}→${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

# Format: short-name|branch-name|brief-file-relative-to-BRIEF_DIR
WORKTREES=(
  "fix-storage|fix/v1-storage-resilience|storage/TASK.md"
  "fix-auth|fix/v1-auth-ratelimit|auth/TASK.md"
  "fix-redaction|fix/v1-log-redaction|redaction/TASK.md"
  "fix-auto-capture|fix/v1-auto-capture|auto-capture/TASK.md"
)

make_worktree() {
  local repo="$1" wt_base="$2" short="$3" branch="$4" brief="$5"
  local target="$wt_base/$short"
  local brief_path="$BRIEF_DIR/$brief"

  if [[ ! -f "$brief_path" ]]; then
    warn "brief missing: $brief_path — skipping $short"
    return
  fi

  if [[ -d "$target" ]]; then
    warn "SKIP $target (already exists)"
    return
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    info "[dry] would create $target on branch $branch"
    return
  fi

  ( cd "$repo" && git fetch origin main && git worktree add "$target" -b "$branch" origin/main )
  cp "$brief_path" "$target/TASK.md"
  ok "$target  →  $branch"
}

[[ -d "$HERMES_REPO/.git" ]] || fail "HERMES_REPO not a git repo: $HERMES_REPO"

mkdir -p "$HERMES_WT"

echo ""
echo "=== v1 MVP fix sprint — 4 parallel worktrees ==="
for entry in "${WORKTREES[@]}"; do
  IFS='|' read -r short branch brief <<<"$entry"
  make_worktree "$HERMES_REPO" "$HERMES_WT" "$short" "$branch" "$brief"
done

echo ""
echo "=== Next step ==="
echo ""
echo "Open four fresh Claude Code Desktop sessions, one per worktree:"
echo ""
for entry in "${WORKTREES[@]}"; do
  IFS='|' read -r short branch _ <<<"$entry"
  echo "  ${BLUE}$HERMES_WT/$short${NC}  →  branch ${GREEN}$branch${NC}"
done
echo ""
echo "For each session, paste the matching block from:"
echo "  ${BLUE}$HERMES_REPO/tests/v1/FIX-RUNBOOK.md${NC}"
echo ""
echo "All four worktrees can run in parallel — no file overlap."
