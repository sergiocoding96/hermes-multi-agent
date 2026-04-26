#!/usr/bin/env bash
# setup-fix-worktrees.sh — Create worktrees for the v1 MVP fix sprint.
#
# Idempotent. Safe to re-run (existing worktrees skipped).
#
# This script creates Hermes-side worktrees that hold the per-bug TASK.md
# briefs. Worktrees whose code work happens in the MemOS repo (fix-storage,
# fix-redaction, MemOS-side of fix-auth) instruct the agent to create their
# own MemOS worktree as their first step — the banner at the top of each
# TASK.md has the exact `git worktree add` command.
#
# Usage:
#   bash scripts/worktrees/fix-mvp/setup-fix-worktrees.sh        # create
#   bash scripts/worktrees/fix-mvp/setup-fix-worktrees.sh --dry  # preview
set -euo pipefail

HERMES_REPO="${HERMES_REPO:-$HOME/Coding/Hermes}"
HERMES_WT="${HERMES_WT:-$HOME/Coding/Hermes-wt}"
MEMOS_REPO="${MEMOS_REPO:-$HOME/Coding/MemOS}"
MEMOS_WT="${MEMOS_WT:-$HOME/Coding/MemOS-wt}"
BRIEF_DIR="$HERMES_REPO/scripts/worktrees/fix-mvp"

DRY_RUN=0
[[ "${1:-}" == "--dry" ]] && DRY_RUN=1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
info() { echo -e "${BLUE}→${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

# Format: short-name|branch-name|brief-file-relative-to-BRIEF_DIR|primary-repo
# primary-repo is "hermes" or "memos" — the repo where the briefing worktree lives.
# Storage and redaction edit MemOS source only, so their briefing worktree IS the
# MemOS worktree (no follow-up worktree needed). Auth is split-repo: briefing
# lives in Hermes (where the script-restoration happens) and the agent creates a
# MemOS worktree as a follow-up step for the server-side gate + rate limiter.
# Auto-capture is pure Hermes (plugin source).
WORKTREES=(
  "fix-storage|fix/v1-storage-resilience|storage/TASK.md|memos"
  "fix-auth|fix/v1-auth-ratelimit|auth/TASK.md|hermes"
  "fix-redaction|fix/v1-log-redaction|redaction/TASK.md|memos"
  "fix-auto-capture|fix/v1-auto-capture|auto-capture/TASK.md|hermes"
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
[[ -d "$MEMOS_REPO/.git"  ]] || warn "MEMOS_REPO not found at $MEMOS_REPO — agents whose work is MemOS-side will need to point MEMOS_REPO at the right path"

mkdir -p "$HERMES_WT"
mkdir -p "$MEMOS_WT" 2>/dev/null || true

echo ""
echo "=== v1 MVP fix sprint — 4 parallel worktrees ==="
for entry in "${WORKTREES[@]}"; do
  IFS='|' read -r short branch brief primary <<<"$entry"
  if [[ "$primary" == "hermes" ]]; then
    make_worktree "$HERMES_REPO" "$HERMES_WT" "$short" "$branch" "$brief"
  else
    make_worktree "$MEMOS_REPO" "$MEMOS_WT" "$short" "$branch" "$brief"
  fi
done

echo ""
echo "=== Repo map ==="
echo "  Hermes:  $HERMES_REPO  (worktrees in $HERMES_WT)"
echo "  MemOS:   $MEMOS_REPO  (worktrees in $MEMOS_WT)"
echo ""
echo "=== Worktree locations after this script runs ==="
for entry in "${WORKTREES[@]}"; do
  IFS='|' read -r short branch _ primary <<<"$entry"
  if [[ "$primary" == "hermes" ]]; then
    printf "  %-18s  %s/%s  →  branch %s  (Hermes)\n" "$short" "$HERMES_WT" "$short" "$branch"
  else
    printf "  %-18s  %s/%s  →  branch %s  (MemOS)\n" "$short" "$MEMOS_WT" "$short" "$branch"
  fi
done
echo ""
echo "=== Next step ==="
echo ""
echo "Open four fresh Claude Code Desktop sessions, one per worktree above."
echo "Set each session's working directory to the worktree path shown."
echo ""
echo "For each session, paste the matching block from:"
echo "  ${BLUE}$HERMES_REPO/tests/v1/FIX-RUNBOOK.md${NC}"
echo ""
echo "Notes:"
echo "  - fix-storage and fix-redaction now sit directly on the MemOS repo (no follow-up worktree needed)."
echo "  - fix-auth lives on Hermes for the script restoration; agent creates a MemOS worktree as a follow-up per the TASK.md banner (this one is split-repo, two PRs)."
echo "  - fix-auto-capture sits on Hermes; first action is to un-archive deploy/plugins/_archive/memos-toolset per the TASK.md banner."
echo "  - All four can run in parallel — no file overlap."
