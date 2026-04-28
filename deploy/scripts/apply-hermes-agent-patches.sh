#!/usr/bin/env bash
# apply-hermes-agent-patches.sh — Apply our local Hermes Agent patches.
#
# Hermes Agent is installed via the upstream `curl install.sh | bash`
# from NousResearch/hermes-agent. We track upstream as-is and keep our
# local fixes as numbered .patch files in this repo (not as a fork).
#
# This script is idempotent — already-applied patches are detected via
# their commit subject and skipped. Run it after any fresh hermes-agent
# install, or whenever you sync the patches/ directory from this repo.
#
# Failure modes:
#   - Patch fails to apply cleanly → upstream changed the file under us.
#     Triage: open the patch, re-create it against current upstream,
#     replace the file in patches/hermes-agent/, re-run.
#
# Usage: bash deploy/scripts/apply-hermes-agent-patches.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }
info() { echo -e "${BLUE}→${NC} $1"; }

HERMES_AGENT_DIR="${HERMES_AGENT_DIR:-$HOME/.hermes/hermes-agent}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_DIR="$REPO_DIR/patches/hermes-agent"

if [ ! -d "$HERMES_AGENT_DIR/.git" ]; then
    fail "Hermes Agent not found as a git checkout at $HERMES_AGENT_DIR"
    fail "Install upstream first: curl -fsSL https://hermes-agent.nousresearch.com/install | bash"
    exit 1
fi

if [ ! -d "$PATCH_DIR" ]; then
    warn "No patches dir at $PATCH_DIR — nothing to apply"
    exit 0
fi

shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
shopt -u nullglob

if [ "${#patches[@]}" -eq 0 ]; then
    ok "No patches to apply"
    exit 0
fi

cd "$HERMES_AGENT_DIR"

applied=0; skipped=0; failed=0
for p in "${patches[@]}"; do
    # Each format-patch file starts with: From <sha> Mon Sep 17 ...
    # If that commit object already exists locally, the patch is applied.
    sha=$(awk 'NR==1 && /^From [0-9a-f]+ /{print $2; exit}' "$p")
    if [ -n "$sha" ] && git cat-file -e "$sha" 2>/dev/null; then
        ok "skip   $(basename "$p")  (commit ${sha:0:8} already present)"
        skipped=$((skipped+1))
        continue
    fi
    info "apply  $(basename "$p")"
    if git am --keep-cr "$p" >/dev/null 2>&1; then
        ok "applied $(basename "$p")"
        applied=$((applied+1))
    else
        git am --abort 2>/dev/null || true
        fail "FAILED $(basename "$p") — likely upstream changed the patched file"
        fail "       inspect: cd $HERMES_AGENT_DIR && git apply --check $p"
        failed=$((failed+1))
    fi
done

echo ""
echo "applied=$applied skipped=$skipped failed=$failed"
[ "$failed" -eq 0 ]
