#!/usr/bin/env bash
# Tower: MemOS must not be treated as this bot's Discord transcript (cross-agent bleed).
set -euo pipefail

MARKER="## Tower MemOS vs this session"
BLOCK=$'Tower MemOS vs this session:\n- Injected memory / MemOS may include the same human\'s other Tower bots or older sessions. That is not this profile\'s Discord transcript.\n- For "your last messages", "what did you say", or "what did I say here", use only this Hermes session (assistant/user turns in this thread or channel session).\n- Do not list Mohamed, Research, CEO, or other bots\' replies as if you said them in this room unless the user quoted them here or policy explicitly allows sharing.'

append_block() {
  local soul="$1"
  [[ -f "$soul" ]] || return 0
  if grep -qF "$MARKER" "$soul"; then
    echo "already: $soul"
    return 0
  fi
  cp "$soul" "${soul}.bak.memos-boundary"
  {
    echo ""
    echo "$MARKER"
    echo ""
    printf '%s\n' "$BLOCK"
  } >>"$soul"
  echo "patched: $soul"
}

append_block /home/openclaw/.hermes/profiles/hr-agent/SOUL.md
append_block /home/openclaw/.hermes/profiles/research-agent/SOUL.md
append_block /home/openclaw/.hermes/profiles/sergio/SOUL.md
append_block /home/openclaw/.hermes/profiles/mohammed/SOUL.md
append_block /home/openclaw/.hermes/profiles/arinze/SOUL.md

systemctl --user restart hermes-gateway.service
systemctl --user restart hermes-gateway-arinze.service
systemctl --user restart hermes-gateway-hr-agent.service
systemctl --user restart hermes-gateway-research-agent.service
systemctl --user restart hermes-gateway-sergio.service

systemctl --user is-active hermes-gateway.service hermes-gateway-arinze.service hermes-gateway-hr-agent.service hermes-gateway-research-agent.service hermes-gateway-sergio.service
