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
#   4. Named-speaker memory summaries (core/capture/summarizer.ts MEMOS_HUMANS,
#      bridge.cts dotenv loader) + skill packager default share-scope
#      (core/skill/packager.ts).
#
# Patches added 2026-05-25 (bounded-capture-LLM / boot-hang prevention):
#   5. Chunked batch reflection — core/capture/capture.ts splits a closed
#      episode into ≤ batchThreshold-step batch calls (scoreBatchChunk) so an
#      oversized single call can't return malformed JSON / time out and stall
#      a cold bridge boot. Orphan-fallback summaries use the heuristic path
#      (summarizer.ts heuristicOnly) to avoid one LLM call per orphan step.
#   6. Per-step tool-call cap + maxTokens — core/capture/batch-scorer.ts bounds
#      the per-step tool_calls array (capToolCalls, 24) and forwards a hard
#      maxTokens ceiling on the batched-reflection response.
#   7. Bridge keepalive / leak fix — adapters/hermes/memos_provider/__init__.py
#      blocks 90s for a cold boot (was 10s, which respawned mid-boot and leaked
#      node procs) and closes a failed/timed-out bridge subprocess before
#      dropping the handle.
#   Decision doc: memos-setup/learnings/2026-05-25-bounded-capture-llm-boot-hang.md
#
# NOTE: the `skillEvolver → NVIDIA integrate API` switch (2026-05-25) lives in
#   the user's ~/.hermes/memos-plugin/config.yaml (it carries a secret API key,
#   so it is intentionally NOT committed here). config.yaml is user data and is
#   preserved across plugin reinstalls; backup at config.yaml.bak-skillevolver-2026-05-25.
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
  "core/capture/capture.ts"
  "core/capture/batch-scorer.ts"
  "adapters/hermes/memos_provider/__init__.py"
  "adapters/hermes/memos_provider/daemon_manager.py"
  "bridge.cts"
  "server/http.ts"
  "web/dist/index.html"
  "web/dist/hermes-profile-switcher.js"
  "core/config/defaults.ts"
  "core/reward/backprop.ts"
  "core/llm/prompts/l2-induction.ts"
  "core/memory/l2/induce.ts"
  "core/memory/l2/types.ts"
  "core/memory/l3/merge.ts"
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
  ["core/capture/summarizer.ts"]="heuristicOnly"
  ["core/capture/capture.ts"]="scoreBatchChunk"
  ["core/capture/batch-scorer.ts"]="capToolCalls"
  ["adapters/hermes/memos_provider/__init__.py"]="Kill the failed/timed-out bridge subprocess"
  ["adapters/hermes/memos_provider/daemon_manager.py"]="bridge_boot_lock"
  ["bridge.cts"]="loadDotEnv"
  ["server/http.ts"]="runWithRequestNamespace"
  ["web/dist/index.html"]="hermes-profile-switcher.js"
  ["web/dist/hermes-profile-switcher.js"]="X-As-Profile"
  ["core/config/defaults.ts"]="minSupport: 3"
  ["core/reward/backprop.ts"]="ERROR_OUTCOME_PENALTY"
  ["core/llm/prompts/l2-induction.ts"]="failure_avoidance"
  ["core/memory/l2/induce.ts"]="antiPatterns"
  ["core/memory/l2/types.ts"]="antiPatterns?: string[]"
  ["core/memory/l3/merge.ts"]="WM_SIM_MERGE_THRESHOLD"
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
echo "  Restart to pick up changes (the :18800 daemon is now a systemd unit;"
echo "  do NOT 'pkill -f bridge.cts' — that kills the daemon + matches shells):"
echo "    systemctl --user restart hermes-memos-daemon.service   # the :18800 daemon"
echo "    # then restart agent gateways STAGGERED (flock serializes boots, but spacing helps):"
echo "    for s in sergio krati arinze lucas hr-agent research-agent; do \\"
echo "      systemctl --user restart hermes-gateway-\$s.service; sleep 25; done"
exit "$missing"
