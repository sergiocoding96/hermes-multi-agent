#!/usr/bin/env bash
# Tower: fix @mentions in shared #general for all Hermes gateways on sergio.
# - DISCORD_IGNORE_NO_MENTION=false (Hermes default true blocks many hub messages)
# - Restart all Tower gateway units
# Run on sergio: bash scripts/tower-fix-discord-general-hub.sh
set -euo pipefail

PROFILES=(mohammed arinze sergio krati hr-agent research-agent)
GLOBAL_ENV=/home/openclaw/.hermes/.env

set_ignore_false() {
  local envf="$1"
  [[ -f "$envf" ]] || return 0
  if grep -q '^DISCORD_IGNORE_NO_MENTION=' "$envf"; then
    sed -i 's/^DISCORD_IGNORE_NO_MENTION=.*/DISCORD_IGNORE_NO_MENTION=false/' "$envf"
  else
    echo 'DISCORD_IGNORE_NO_MENTION=false' >>"$envf"
  fi
}

if [[ -f "$GLOBAL_ENV" ]]; then
  cp "$GLOBAL_ENV" "${GLOBAL_ENV}.bak.tower-general-hub"
  set_ignore_false "$GLOBAL_ENV"
  echo "updated global $GLOBAL_ENV"
fi

for p in "${PROFILES[@]}"; do
  envf="/home/openclaw/.hermes/profiles/${p}/.env"
  if [[ -f "$envf" ]]; then
    cp "$envf" "${envf}.bak.tower-general-hub"
    set_ignore_false "$envf"
    echo "DISCORD_IGNORE_NO_MENTION=false -> $p"
  fi
done

units=(
  hermes-gateway.service
  hermes-gateway-arinze.service
  hermes-gateway-sergio.service
  hermes-gateway-krati.service
  hermes-gateway-hr-agent.service
  hermes-gateway-research-agent.service
)

for u in "${units[@]}"; do
  systemctl --user restart "$u" || true
done

sleep 5
for u in "${units[@]}"; do
  printf '%s: ' "$u"
  systemctl --user is-active "$u" || true
done

echo "done — retest @mention in THE SPIRE #general (1503342972950024244)"
