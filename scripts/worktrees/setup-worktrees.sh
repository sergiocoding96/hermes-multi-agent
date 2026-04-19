#!/usr/bin/env bash
# setup-worktrees.sh — Create git worktrees for the 10/10 hardening sprint
#
# One worktree = one branch = one Claude Code session.
# Worktrees share the .git of the main checkout but have their own working tree,
# so N Claude sessions can run in parallel without stepping on each other.
#
# Usage:
#   bash scripts/worktrees/setup-worktrees.sh          # create all
#   bash scripts/worktrees/setup-worktrees.sh --dry    # print plan only
#   MEMOS_REPO=... HERMES_REPO=... bash ...            # override paths
#
# Safe to re-run: existing worktrees are skipped.
set -euo pipefail

MEMOS_REPO="${MEMOS_REPO:-$HOME/Coding/MemOS}"
HERMES_REPO="${HERMES_REPO:-$HOME/Coding/Hermes}"
MEMOS_WT="${MEMOS_WT:-$HOME/Coding/MemOS-wt}"
HERMES_WT="${HERMES_WT:-$HOME/Coding/Hermes-wt}"
BRIEF_DIR="$HERMES_REPO/scripts/worktrees"

DRY_RUN=0
[[ "${1:-}" == "--dry" ]] && DRY_RUN=1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
info() { echo -e "${BLUE}→${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

# Format: short-name|branch-name|brief-file-relative-to-BRIEF_DIR
MEMOS_WORKTREES=(
  "fix-auth-perf|fix/auth-perf|memos/fix-auth-perf.md"
  "fix-custom-metadata|fix/custom-metadata|memos/fix-custom-metadata.md"
  "fix-delete-api|fix/delete-api|memos/fix-delete-api.md"
  "fix-search-dedup|fix/search-dedup|memos/fix-search-dedup.md"
  "feat-fast-mode-chunking|feat/fast-mode-chunking|memos/feat-fast-mode-chunking.md"
)

HERMES_WORKTREES=(
  "feat-memos-provisioning|feat/memos-provisioning|hermes/feat-memos-provisioning.md"
  "feat-paperclip-adapter|feat/paperclip-adapter|hermes/feat-paperclip-adapter.md"
  "feat-memos-dual-write|feat/memos-dual-write|hermes/feat-memos-dual-write.md"
)

make_worktree() {
  local repo="$1" wt_base="$2" short="$3" branch="$4" brief="$5"
  local target="$wt_base/$short"
  local brief_path="$BRIEF_DIR/$brief"

  if [[ ! -f "$brief_path" ]]; then
    warn "Brief missing: $brief_path — skipping $short"
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

  ( cd "$repo" && git worktree add "$target" -b "$branch" main )
  cp "$brief_path" "$target/TASK.md"
  ok "$target  →  $branch"
}

[[ -d "$MEMOS_REPO/.git" ]]  || fail "MEMOS_REPO not a git repo: $MEMOS_REPO"
[[ -d "$HERMES_REPO/.git" ]] || fail "HERMES_REPO not a git repo: $HERMES_REPO"

mkdir -p "$MEMOS_WT" "$HERMES_WT"

echo "=== MemOS worktrees ==="
for entry in "${MEMOS_WORKTREES[@]}"; do
  IFS='|' read -r short branch brief <<<"$entry"
  make_worktree "$MEMOS_REPO" "$MEMOS_WT" "$short" "$branch" "$brief"
done

echo ""
echo "=== Hermes worktrees ==="
for entry in "${HERMES_WORKTREES[@]}"; do
  IFS='|' read -r short branch brief <<<"$entry"
  make_worktree "$HERMES_REPO" "$HERMES_WT" "$short" "$branch" "$brief"
done

echo ""
echo "=== Next: launch Claude sessions ==="
echo ""
echo "  tmux new -s hermes    # first time, or: tmux attach -t hermes"
echo ""
echo "  # Inside tmux, Ctrl-b c to create a window, then:"
for entry in "${MEMOS_WORKTREES[@]}"; do
  IFS='|' read -r short branch brief <<<"$entry"
  echo "  cd $MEMOS_WT/$short && claude   # $branch"
done
for entry in "${HERMES_WORKTREES[@]}"; do
  IFS='|' read -r short branch brief <<<"$entry"
  echo "  cd $HERMES_WT/$short && claude   # $branch"
done
echo ""
echo "See scripts/worktrees/TMUX-CHEATSHEET.md for controls."
