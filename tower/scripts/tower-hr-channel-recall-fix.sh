#!/usr/bin/env bash
# Specialists: stop MemOS / session_search from answering "last replies in #channel".
set -euo pipefail

HR_CFG=/home/openclaw/.hermes/profiles/hr-agent/config.yaml
RS_CFG=/home/openclaw/.hermes/profiles/research-agent/config.yaml
HR_SOUL=/home/openclaw/.hermes/profiles/hr-agent/SOUL.md
RS_SOUL=/home/openclaw/.hermes/profiles/research-agent/SOUL.md
MARKER="## Tower channel recap (#hr / home only)"
BLOCK=$'Tower channel recap (#hr / home only):\n- If the user asks for your last replies in this channel or home room, answer only from this Hermes session transcript (assistant turns since this thread/channel session started).\n- Do not call memory_search, session_search, or memory_timeline to answer that recap. Do not use MemOS injection as if it were this channel transcript.\n- If you have no prior assistant turns in this session, say so plainly. Never paste Mohamed, CEO, or Research bot dialogue as your #hr replies.'

for cfg in "$HR_CFG" "$RS_CFG"; do
  [[ -f "$cfg" ]] || continue
  cp "$cfg" "${cfg}.bak.recall-fix"
  sed -i 's/^  user_profile_enabled: true$/  user_profile_enabled: false/' "$cfg"
done

append_soul() {
  local soul="$1"
  [[ -f "$soul" ]] || return 0
  if grep -qF "$MARKER" "$soul"; then
    echo "already: $soul"
    return 0
  fi
  cp "$soul" "${soul}.bak.recall-fix"
  {
    echo ""
    echo "$MARKER"
    echo ""
    printf '%s\n' "$BLOCK"
  } >>"$soul"
  echo "patched: $soul"
}

append_soul "$HR_SOUL"
append_soul "$RS_SOUL"

systemctl --user restart hermes-gateway-hr-agent.service
systemctl --user restart hermes-gateway-research-agent.service

systemctl --user is-active hermes-gateway-hr-agent.service hermes-gateway-research-agent.service
