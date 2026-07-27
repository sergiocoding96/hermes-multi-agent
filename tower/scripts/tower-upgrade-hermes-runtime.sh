#!/usr/bin/env bash
# Tower: upgrade live Hermes runtime on sergio (NousResearch upstream) + re-apply team patches.
# Run on sergio as openclaw: bash scripts/tower-upgrade-hermes-runtime.sh
set -euo pipefail

HERMES_AGENT_DIR="${HERMES_AGENT_DIR:-$HOME/.hermes/hermes-agent}"
HERMES_BIN="$HERMES_AGENT_DIR/venv/bin/hermes"
PATCH_SCRIPT="/home/openclaw/Coding/Hermes/deploy/scripts/apply-hermes-agent-patches.sh"
UNITS=(
  hermes-gateway.service
  hermes-gateway-arinze.service
  hermes-gateway-krati.service
  hermes-gateway-sergio.service
  hermes-gateway-hr-agent.service
  hermes-gateway-research-agent.service
)

echo "=== before ==="
"$HERMES_BIN" version 2>/dev/null | head -6 || true

echo "=== stopping gateways ==="
for u in "${UNITS[@]}"; do
  systemctl --user stop "$u" 2>/dev/null || true
done
sleep 3

echo "=== hermes update (upstream pull + deps) ==="
cd "$HERMES_AGENT_DIR"
"$HERMES_BIN" update --yes

echo "=== after update ==="
"$HERMES_BIN" version 2>/dev/null | head -6 || true

if [[ -f "$PATCH_SCRIPT" ]]; then
  echo "=== applying team patches (continue if some fail on v0.14) ==="
  bash "$PATCH_SCRIPT" || warn "some patches failed — see output; gateways may still run"
else
  echo "WARN: patch script missing at $PATCH_SCRIPT"
fi

echo "=== starting gateways ==="
for u in "${UNITS[@]}"; do
  systemctl --user start "$u" || true
done
sleep 8

echo "=== status ==="
for u in "${UNITS[@]}"; do
  printf '%s: ' "$u"
  systemctl --user is-active "$u" || true
done

echo "done"
