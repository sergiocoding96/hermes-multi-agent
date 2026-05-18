#!/usr/bin/env bash
# postinstall-patches.sh — re-apply Hermes patches to @memtensor/memos-local-plugin.
#
# The v2 plugin ships as an npm package with no public repository, so we can't
# upstream our additions. Instead we keep patched copies under tools/plugin-patches/
# and copy them in after a fresh install / upgrade.
#
# Patches applied (2026-05-17):
#   1. Shared-skill attribution — renderSkill appends "(learned by <profile>)"
#      (types.ts, tier1-skill.ts, injector.ts, retrieval-repos.ts)
#   2. Per-request "view as <profile>" override via X-As-Profile header /
#      ?as_profile= query param (new core/runtime/request-namespace.ts,
#      memory-core.ts effectiveNamespace, server/http.ts dispatch wrapping,
#      traces.ts listTurnKeys+countTurns namespace-aware SQL)
#   3. Bundled-viewer UI overlay (web/dist/index.html script tag,
#      hermes-profile-switcher.js)
#
# Run:    bash tools/postinstall-patches.sh
# Verify: bash tools/postinstall-patches.sh --check     (read-only sanity)
#
# Linked decision doc: memos-setup/learnings/2026-05-17-v2-only-bge-shares.md

set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
PATCHES="$REPO/tools/plugin-patches"
PLUGIN="${MEMOS_PLUGIN_HOME:-$HOME/.hermes/memos-plugin}"
MODE="${1:-apply}"

if [ ! -d "$PLUGIN" ]; then
  echo "✗ plugin not found at $PLUGIN — set MEMOS_PLUGIN_HOME env to override" >&2
  exit 2
fi
if [ ! -d "$PATCHES" ]; then
  echo "✗ patches not found at $PATCHES" >&2
  exit 2
fi

FILES=(
  "core/retrieval/types.ts"
  "core/retrieval/tier1-skill.ts"
  "core/retrieval/injector.ts"
  "core/pipeline/retrieval-repos.ts"
  "core/pipeline/memory-core.ts"
  "core/runtime/request-namespace.ts"
  "core/storage/repos/traces.ts"
  "core/skill/packager.ts"
  "core/capture/summarizer.ts"
  "bridge.cts"
  "server/http.ts"
  "web/dist/index.html"
  "web/dist/hermes-profile-switcher.js"
)

# Sanity-check markers we expect to find in the patched versions.
declare -A MARKERS=(
  ["core/retrieval/types.ts"]="ownerProfileId?: string;"
  ["core/retrieval/tier1-skill.ts"]="ownerProfileId: sk.ownerProfileId,"
  ["core/retrieval/injector.ts"]="learned by"
  ["core/pipeline/retrieval-repos.ts"]="ownerProfileId: row.ownerProfileId,"
  ["core/pipeline/memory-core.ts"]="effectiveNamespace"
  ["core/runtime/request-namespace.ts"]="runWithRequestNamespace"
  ["core/storage/repos/traces.ts"]="getRequestNamespace"
  ["core/skill/packager.ts"]="share: existing?.share ?? { scope: \"local\""
  ["core/capture/summarizer.ts"]="MEMOS_HUMAN_NAME"
  ["bridge.cts"]="loadDotEnv"
  ["server/http.ts"]="runWithRequestNamespace"
  ["web/dist/index.html"]="hermes-profile-switcher.js"
  ["web/dist/hermes-profile-switcher.js"]="X-As-Profile"
)

missing=0
applied=0
skipped=0

for f in "${FILES[@]}"; do
  src="$PATCHES/$f"
  dst="$PLUGIN/$f"
  marker="${MARKERS[$f]}"
  if [ ! -f "$src" ]; then
    echo "✗ patch source missing: $src"
    missing=$((missing+1))
    continue
  fi
  if [ "$MODE" = "--check" ]; then
    if [ -f "$dst" ] && grep -Fq "$marker" "$dst" 2>/dev/null; then
      echo "✓ $f — marker present"
    else
      echo "✗ $f — marker missing or file absent"
      missing=$((missing+1))
    fi
    continue
  fi
  # Skip if identical (cheap idempotency).
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    skipped=$((skipped+1))
    continue
  fi
  mkdir -p "$(dirname "$dst")"
  cp -f "$src" "$dst"
  applied=$((applied+1))
  echo "✓ $f"
done

# Symlink the UMAP viewers + data into the plugin's static root so it serves them.
if [ "$MODE" != "--check" ]; then
  for f in umap-viewer.html vec-map.json umap-3d-viewer.html vec-map-3d.json memory-map.html memory-graph.json d3.v7.min.js; do
    target="$REPO/tools/$f"
    link="$PLUGIN/web/dist/$f"
    if [ -e "$target" ]; then
      ln -sfn "$target" "$link"
      echo "✓ web/dist/$f → tools/$f (symlink)"
    fi
  done
fi

echo
if [ "$MODE" = "--check" ]; then
  if [ "$missing" -gt 0 ]; then
    echo "→ $missing patch(es) missing. Re-run without --check to apply."
    exit 1
  fi
  echo "→ all patches present."
  exit 0
fi
echo "→ applied $applied, skipped $skipped (already up to date), missing $missing"
echo "  Restart the daemon to pick up changes:"
echo "  pkill -9 -f 'memos-plugin/bridge.cts' ; sleep 3"
echo "  ( cd ~/.hermes/memos-plugin && nohup setsid node \\"
echo "      --require ./node_modules/tsx/dist/preflight.cjs \\"
echo "      --import \"file://\$PWD/node_modules/tsx/dist/loader.mjs\" \\"
echo "      ./bridge.cts --agent=hermes --daemon \\"
echo "      >/tmp/memos-daemon.log 2>&1 </dev/null & disown )"
exit "$missing"
