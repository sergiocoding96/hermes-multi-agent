#!/usr/bin/env bash
# Run ON sergio (Tower): require @ in #general while keeping ambient chat in home channels
# via Hermes: require_mention true + free_response_channels = home channel id only.
# Usage: bash scripts/sergio-discord-require-mention-general.sh
# Or from dev machine: Get-Content scripts/sergio-discord-require-mention-general.sh | ssh sergio bash

set -euo pipefail
HR=/home/openclaw/.hermes/profiles/hr-agent/config.yaml
RS=/home/openclaw/.hermes/profiles/research-agent/config.yaml
CEO=/home/openclaw/.hermes/profiles/sergio/config.yaml

sed -i '223s/require_mention: false/require_mention: true/' "$HR"
sed -i '38s/require_mention: false/require_mention: true/' "$RS"
sed -i '382s/require_mention: false/require_mention: true/' "$CEO"
sed -i "383s|free_response_channels: ''|free_response_channels: '1501140736651821076'|" "$CEO"

echo "--- hr-agent discord (snippet) ---"
grep -A4 '^discord:' "$HR" | head -6
echo "--- research-agent ---"
grep -A4 '^discord:' "$RS" | head -6
echo "--- sergio ---"
grep -A5 '^discord:' "$CEO" | head -8

systemctl --user restart hermes-gateway-hr-agent.service
systemctl --user restart hermes-gateway-research-agent.service
systemctl --user restart hermes-gateway-sergio.service

echo "Restarted hr-agent, research-agent, sergio gateways."
systemctl --user is-active hermes-gateway-hr-agent.service hermes-gateway-research-agent.service hermes-gateway-sergio.service
