#!/usr/bin/env bash
# setup-migration-worktrees.sh — Create worktrees for the v2 migration sprint.
#
# Idempotent. Safe to re-run (existing worktrees skipped).
#
# Usage:
#   bash scripts/worktrees/migration/setup-migration-worktrees.sh        # create
#   bash scripts/worktrees/migration/setup-migration-worktrees.sh --dry  # preview
set -euo pipefail

HERMES_REPO="${HERMES_REPO:-$HOME/Coding/Hermes}"
HERMES_WT="${HERMES_WT:-$HOME/Coding/Hermes-wt}"
BRIEF_DIR="$HERMES_REPO/scripts/worktrees/migration"

DRY_RUN=0
[[ "${1:-}" == "--dry" ]] && DRY_RUN=1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
info() { echo -e "${BLUE}→${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

# Format: short-name|branch-name|brief-file-relative-to-BRIEF_DIR|stage
WORKTREES=(
  "feat-migrate-setup|feat/migrate-setup|gate/migrate-setup.md|Stage 1 — Gate (sequential)"
  "wire-paperclip-employees|wire/paperclip-employees|wire/paperclip-employees.md|Stage 2 — Integration"
  "wire-ceo-hub-access|wire/ceo-hub-access|wire/ceo-hub-access.md|Stage 2 — Integration"
  "wire-badass-skills-groundtruth|wire/badass-skills-groundtruth|wire/badass-skills-groundtruth.md|Stage 2 — Integration"
  "docs-write-v2-audit-suite|docs/write-v2-audit-suite|docs/write-v2-audit-suite.md|Stage 3 — Docs"
  "hermes-fallback-model|hermes/fallback-model|phase3/fallback-model.md|Stage 5 — Phase 3"
  "hermes-mcp-integration|hermes/mcp-integration|phase3/mcp-integration.md|Stage 5 — Phase 3"
  "hermes-python-library-adapter|hermes/python-library-adapter|phase3/python-library-adapter.md|Stage 5 — Phase 3"
  "hermes-github-webhook|hermes/github-webhook|phase3/github-webhook.md|Stage 5 — Phase 3"
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

  ( cd "$repo" && git worktree add "$target" -b "$branch" main )
  cp "$brief_path" "$target/TASK.md"
  cp "$BRIEF_DIR/INITIATION-PROMPT.md" "$target/INITIATION-PROMPT.md"
  ok "$target  →  $branch"
}

[[ -d "$HERMES_REPO/.git" ]] || fail "HERMES_REPO not a git repo: $HERMES_REPO"

mkdir -p "$HERMES_WT"

current_stage=""
for entry in "${WORKTREES[@]}"; do
  IFS='|' read -r short branch brief stage <<<"$entry"
  if [[ "$stage" != "$current_stage" ]]; then
    echo ""
    echo "=== $stage ==="
    current_stage="$stage"
  fi
  make_worktree "$HERMES_REPO" "$HERMES_WT" "$short" "$branch" "$brief"
done

echo ""
echo "=== Next step ==="
echo ""
echo "Start with the Stage 1 GATE session first:"
echo "  ${BLUE}Open a fresh Claude Code Desktop session in:${NC}"
echo "    $HERMES_WT/feat-migrate-setup"
echo ""
echo "  ${BLUE}Paste the contents of INITIATION-PROMPT.md as the first message.${NC}"
echo ""
echo "Do NOT launch Stage 2+ sessions until the gate session reports PASS."
echo ""
echo "See $BRIEF_DIR/README.md for the full flow."
