#!/usr/bin/env bash
# Tower: if MemOS bridge processes pile up, kill extras and restart personal gateways.
# Run on sergio (cron optional): bash scripts/tower-memos-bridge-guard.sh
set -euo pipefail

# Default raised to 16: normal steady state is ~1 bridge pair per active gateway,
# so 8 was below baseline and made the guard nuke healthy bridges. The real leak
# fix is the adapter's serialized cold-boot (see the 2026-05-26 decision doc); this
# guard is only a safety net.
MAX_BRIDGE="${TOWER_MEMOS_BRIDGE_MAX:-16}"
# SAFE cleanup only — never blanket `pkill -f 'bridge\.cts'` (it kills the :18800
# daemon and matches admin shells). See scripts/lib-bridge-safe-cleanup.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib-bridge-safe-cleanup.sh"
count="$(pgrep -c -f 'bridge\.cts --agent' 2>/dev/null || echo 0)"

if [[ "${count}" -le "${MAX_BRIDGE}" ]]; then
  echo "memos bridge ok: ${count} process(es)"
  exit 0
fi

echo "memos bridge high: ${count} — cleaning (max ${MAX_BRIDGE}; preserving :18800 daemon)"
safe_bridge_cleanup
sleep 2

# Restart STAGGERED so bridges don't cold-boot (BGE-large load) concurrently and
# starve the CPU into the respawn death-spiral this guard exists to contain.
for svc in hermes-gateway hermes-gateway-arinze hermes-gateway-krati hermes-gateway-sergio; do
  systemctl --user restart "${svc}.service" 2>/dev/null || true
  sleep 25
done

sleep 3
new_count="$(pgrep -c -f 'bridge\.cts --agent' 2>/dev/null || echo 0)"
echo "memos bridge after guard: ${new_count} process(es)"
systemctl --user is-active hermes-gateway.service hermes-gateway-arinze.service 2>/dev/null || true
