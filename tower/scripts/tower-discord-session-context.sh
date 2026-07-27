#!/usr/bin/env bash
# Tower: Discord session continuity + honest context scope for Hermes agents.
# Run on sergio: bash scripts/tower-discord-session-context.sh
set -euo pipefail

SPIRE_GENERAL=1503342972950024244
MARKER="## Tower Discord context"
PROMPT=$'Tower Discord context (Hermes):\n- You receive this Hermes session transcript: prior turns with this user in the same thread, DM, or per-user channel session.\n- You do not automatically receive full public channel scrollback: other people\'s messages, parent #general before a thread, or a different thread/session.\n- In #general with auto-thread, each new @mention often starts a new thread = new session. Continue in the same thread for follow-ups; use MemOS/memory tools for facts that must persist across sessions.\n- If asked about older chat you lack, say what you can see, ask for a short recap, or suggest reply-in-thread, quote/reply, or /resume — do not claim Discord blocks you unless tools failed.'

append_soul() {
  local soul="$1"
  [[ -f "$soul" ]] || return 0
  if grep -qF "$MARKER" "$soul"; then
    echo "SOUL already has marker: $soul"
    return 0
  fi
  cp "$soul" "${soul}.bak.tower-discord-context"
  {
    echo ""
    echo "$MARKER"
    echo ""
    printf '%s\n' "$PROMPT"
  } >>"$soul"
  echo "appended SOUL: $soul"
}

patch_mohammed_no_thread() {
  local cfg=/home/openclaw/.hermes/profiles/mohammed/config.yaml
  if grep -q "$SPIRE_GENERAL" "$cfg"; then
    echo "mohammed no_thread already set"
    return 0
  fi
  cp "$cfg" "${cfg}.bak.tower-discord-context"
  sed -i "/^  auto_thread: true$/a\\  no_thread_channels:\\n  - '${SPIRE_GENERAL}'" "$cfg"
  echo "mohammed no_thread_channels added for THE SPIRE #general"
}

append_soul /home/openclaw/.hermes/profiles/mohammed/SOUL.md
append_soul /home/openclaw/.hermes/profiles/arinze/SOUL.md
append_soul /home/openclaw/.hermes/profiles/sergio/SOUL.md
append_soul /home/openclaw/.hermes/profiles/hr-agent/SOUL.md
append_soul /home/openclaw/.hermes/profiles/research-agent/SOUL.md
[[ -f /home/openclaw/.hermes/profiles/krati/SOUL.md ]] && append_soul /home/openclaw/.hermes/profiles/krati/SOUL.md
patch_mohammed_no_thread

systemctl --user restart hermes-gateway.service
systemctl --user restart hermes-gateway-arinze.service
systemctl --user restart hermes-gateway-sergio.service
systemctl --user restart hermes-gateway-hr-agent.service
systemctl --user restart hermes-gateway-research-agent.service
systemctl --user restart hermes-gateway-krati.service 2>/dev/null || true

echo "--- mohammed discord ---"
sed -n '/^discord:/,/^whatsapp:/p' /home/openclaw/.hermes/profiles/mohammed/config.yaml | head -15
systemctl --user is-active hermes-gateway.service hermes-gateway-arinze.service hermes-gateway-sergio.service hermes-gateway-krati.service hermes-gateway-hr-agent.service hermes-gateway-research-agent.service 2>/dev/null || true
