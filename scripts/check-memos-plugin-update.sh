#!/usr/bin/env bash
# check-memos-plugin-update.sh — weekly check for new @memtensor/memos-local-plugin
# versions on npm. Compares against the installed version; appends a one-line
# notice to the log if a newer stable is available.
#
# Designed for cron — silent on no-op, noisy on update available.

set -euo pipefail

INSTALLED_VERSION="$(/usr/bin/node -p "require('/home/openclaw/.hermes/memos-plugin/package.json').version" 2>/dev/null || echo unknown)"
LATEST_VERSION="$(/usr/bin/curl -fsS --max-time 10 https://registry.npmjs.org/-/package/@memtensor/memos-local-plugin/dist-tags | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("latest",""))' 2>/dev/null || echo "")"

if [[ -z "$LATEST_VERSION" ]]; then
  echo "[$(date -Is)] check-failed: could not fetch latest from npm" >&2
  exit 1
fi

if [[ "$INSTALLED_VERSION" == "$LATEST_VERSION" ]]; then
  # Up-to-date; print nothing so cron stays silent.
  exit 0
fi

# Mismatch — write notice to stdout (cron captures to log).
echo "[$(date -Is)] memos-local-plugin update available: installed=$INSTALLED_VERSION latest=$LATEST_VERSION"
echo "[$(date -Is)]   to upgrade: cd /tmp && npm pack @memtensor/memos-local-plugin@$LATEST_VERSION && tar -xzf memtensor-memos-local-plugin-$LATEST_VERSION.tgz && bash package/install.sh --version $LATEST_VERSION"
echo "[$(date -Is)]   release notes: gh api repos/MemTensor/MemOS/releases/latest --jq .body | head -50"
