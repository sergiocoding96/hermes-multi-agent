#!/usr/bin/env bash
# post-merge-fixup.sh — run AFTER you've merged the
# claude/nice-mclaren-13f017 PR into main and pulled.
#
# Swaps the live crontab entries from the temporary Claude Code worktree
# paths (/home/openclaw/Coding/Hermes/.claude/worktrees/.../scripts/...)
# to the merged-into-main paths (/home/openclaw/Coding/Hermes/scripts/...).
#
# Idempotent: safe to re-run.
# Non-destructive: backs up the current crontab to /tmp before changing.
#
# Usage:
#   bash scripts/post-merge-fixup.sh

set -euo pipefail

MAIN_REPO="/home/openclaw/Coding/Hermes"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { printf "${BLUE}[fixup]${NC} %s\n" "$*"; }
ok()      { printf "${GREEN}[fixup] ✓${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[fixup] ⚠${NC} %s\n" "$*" >&2; }
fail()    { printf "${RED}[fixup] ✘${NC} %s\n" "$*" >&2; exit 1; }

# ─── Step 1: verify the merged files exist at the main-repo path ───
info "Checking that the new scripts landed in $MAIN_REPO/scripts/"
for f in promote-memos-shares.py check-memos-plugin-update.sh; do
  target="$MAIN_REPO/scripts/$f"
  if [[ ! -e "$target" ]]; then
    fail "$target not found — did you merge the PR and 'git pull' on main?"
  fi
  if [[ ! -x "$target" ]]; then
    warn "$target exists but is not executable; running chmod +x"
    chmod +x "$target"
  fi
  ok "$target ready"
done

# ─── Step 2: backup current crontab ───
BACKUP="/tmp/crontab.pre-post-merge-fixup.$(date +%s).bak"
crontab -l > "$BACKUP" 2>/dev/null || true
ok "current crontab backed up to $BACKUP"

# ─── Step 3: rewrite worktree paths → main repo paths ───
NEW_CRON="$(mktemp)"
crontab -l 2>/dev/null | sed -E \
  "s|/home/openclaw/Coding/Hermes/\\.claude/worktrees/[^/]+/scripts/|$MAIN_REPO/scripts/|g" \
  > "$NEW_CRON"

# ─── Step 4: short-circuit if nothing changed ───
if diff -q "$BACKUP" "$NEW_CRON" >/dev/null 2>&1; then
  ok "no path swaps needed — cron already points at $MAIN_REPO/scripts/"
  rm "$NEW_CRON"
  exit 0
fi

echo ""
info "Cron diff (current → new):"
diff "$BACKUP" "$NEW_CRON" || true
echo ""

# ─── Step 5: apply ───
crontab "$NEW_CRON"
rm "$NEW_CRON"
ok "crontab updated"

# ─── Step 6: smoke-test the new paths ───
echo ""
info "Smoke-testing the merged scripts..."
"$MAIN_REPO/scripts/promote-memos-shares.py" --dry 2>&1 | tail -2
"$MAIN_REPO/scripts/check-memos-plugin-update.sh" 2>&1 | tail -2

echo ""
ok "post-merge fixup complete. Cron now references $MAIN_REPO/scripts/"
ok "the worktree at /.claude/worktrees/nice-mclaren-13f017/ is safe to remove"
