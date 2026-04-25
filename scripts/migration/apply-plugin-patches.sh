#!/usr/bin/env bash
#
# apply-plugin-patches.sh — apply Hermes patches to a v1.0.3 plugin install.
#
# Usage:  scripts/migration/apply-plugin-patches.sh <install-dir>
#
# Applied patches close audit blockers (memos-setup/learnings/2026-04-25-*):
#   src/hub/server.ts        — loopback bind + /api/v1/hub/health endpoint
#   src/ingest/dedup.ts      — bounded scan via DEDUP_MAX_SCAN + INFO logs
#   src/storage/sqlite.ts    — api_logs STRICT migration + getDbStats()
#
# Idempotent: `patch --forward` skips already-applied hunks (exit 0 or 1).
# Fails closed if a sentinel marker isn't present after apply (catches
# drift if upstream renames a function we patch).

set -euo pipefail

INSTALL_DIR="${1:-}"
if [[ -z "$INSTALL_DIR" ]]; then
  echo "usage: $0 <install-dir>" >&2
  exit 2
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCHES_DIR="$REPO/scripts/migration/plugin-patches-v1.0.3"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${BLUE}[apply-patches]${NC} $*"; }
success() { echo -e "${GREEN}[apply-patches] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[apply-patches] ⚠${NC} $*"; }
error()   { echo -e "${RED}[apply-patches] ✗${NC} $*" >&2; }

[[ -d "$INSTALL_DIR" ]]   || { error "Install dir missing: $INSTALL_DIR"; exit 1; }
[[ -d "$PATCHES_DIR" ]]   || { error "Patches dir missing: $PATCHES_DIR"; exit 1; }

# Verify version match — refuse to patch a different plugin version.
PLUGIN_VERSION="$(node -p "require('$INSTALL_DIR/package.json').version" 2>/dev/null || echo unknown)"
if [[ "$PLUGIN_VERSION" != "1.0.3" ]]; then
  error "Plugin version mismatch: expected 1.0.3, got '$PLUGIN_VERSION'. Patches in $PATCHES_DIR are pinned to 1.0.3 — refusing to apply."
  exit 1
fi
info "Plugin version: $PLUGIN_VERSION"

# Patches: filename → target relative path → sentinel string the patch must install.
PATCH_FILES=(
  "src-hub-server.ts.patch|src/hub/server.ts|Hermes patch (observability audit"
  "src-ingest-dedup.ts.patch|src/ingest/dedup.ts|Hermes patch (performance audit"
  "src-storage-sqlite.ts.patch|src/storage/sqlite.ts|Hermes patch (data-integrity audit"
)

for entry in "${PATCH_FILES[@]}"; do
  patch_file="${entry%%|*}"
  rest="${entry#*|}"
  target_rel="${rest%%|*}"
  sentinel="${rest#*|}"

  patch_path="$PATCHES_DIR/$patch_file"
  [[ -f "$patch_path" ]] || { error "Missing patch: $patch_path"; exit 1; }

  target_abs="$INSTALL_DIR/$target_rel"

  if [[ ! -f "$target_abs" ]]; then
    error "Patch target missing: $target_abs"; exit 1
  fi

  if grep -qF "$sentinel" "$target_abs"; then
    info "Already patched: $target_rel"
    continue
  fi

  info "Applying $patch_file → $target_rel"
  if patch --forward --batch --silent -d "$INSTALL_DIR" -p1 < "$patch_path"; then
    success "Applied $patch_file"
  else
    error "Failed to apply $patch_file"
    exit 1
  fi

  if ! grep -qF "$sentinel" "$target_abs"; then
    error "Sentinel '$sentinel' not found in $target_rel after apply — patch is suspect."
    exit 1
  fi
done

# Lock down telemetry credentials (zero-knowledge audit, separate from .ts patches).
TELEMETRY_CREDS="$INSTALL_DIR/telemetry.credentials.json"
if [[ -f "$TELEMETRY_CREDS" ]]; then
  chmod 600 "$TELEMETRY_CREDS" || true
fi

success "All Hermes patches applied/verified for v$PLUGIN_VERSION"

# ─── Optional: also patch the v2 worker plugin if present ───
# The v2 plugin (@memtensor/memos-local-plugin@2.0.0-beta.1) lives in a
# separate install at ~/.hermes/memos-plugin and is what Hermes workers
# use via the memtensor memory provider. It needs one Sprint 3 patch so
# bridge.cts can be spawned via tsx (Node 22 ESM strip-types limitation).
V2_INSTALL="${MEMOS_V2_INSTALL_DIR:-$HOME/.hermes/memos-plugin}"
V2_PATCHES="$REPO/scripts/migration/plugin-patches-v2"
if [[ -d "$V2_INSTALL" && -d "$V2_PATCHES" ]]; then
  V2_VERSION="$(node -p "require('$V2_INSTALL/package.json').version" 2>/dev/null || echo unknown)"
  if [[ "$V2_VERSION" == "2.0.0-beta.1" ]]; then
    V2_TARGET="$V2_INSTALL/adapters/hermes/memos_provider/bridge_client.py"
    V2_SENTINEL='Hermes patch (Sprint 3 worker-wiring)'
    if [[ -f "$V2_TARGET" ]]; then
      if grep -qF "$V2_SENTINEL" "$V2_TARGET"; then
        info "v2 already patched: bridge_client.py"
      else
        info "Applying v2 patch → bridge_client.py"
        if patch --forward --batch --silent -d "$V2_INSTALL" -p1 < "$V2_PATCHES/bridge_client.py.patch"; then
          if grep -qF "$V2_SENTINEL" "$V2_TARGET"; then
            success "v2 patch applied + verified"
          else
            error "v2 patch sentinel missing after apply — inspect $V2_TARGET"
            exit 1
          fi
        else
          warn "v2 bridge_client.py patch failed to apply (skipping; v2 wiring not blocking hub)"
        fi
      fi
    fi
  else
    warn "v2 plugin version is '$V2_VERSION' — patches pinned to 2.0.0-beta.1, skipping"
  fi
fi
