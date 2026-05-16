#!/usr/bin/env bash
# Tower: HR strict placement — disable MemOS injection on hr-agent (recap still used memory context after SOUL apply).
# Policy: docs/tower-agent-access-architecture.md §6.6, §7.3, §9.8
# Tradeoff: HR loses automatic MemOS injection; session transcript + explicit tools policy only.
# Run on sergio: bash scripts/tower-hr-strict-placement-enforce.sh
set -euo pipefail

HR_CFG=/home/openclaw/.hermes/profiles/hr-agent/config.yaml
HR_SOUL=/home/openclaw/.hermes/profiles/hr-agent/SOUL.md
MARKER="## Tower HR strict placement (MemOS off)"
BLOCK=$'Tower HR strict placement (MemOS off):\n- memory.memory_enabled is false on this profile: no automatic MemOS injection block in the prompt.\n- For recap ("your messages in #hr", "assistant messages in this session"), use only this Hermes session transcript. If none, say so.\n- Do not cite "memory context provided" or other bots\' dialogue as #hr history.\n- Long-term HR facts: only if the operator re-enables memory or the user explicitly asks to store/recall HR facts after that change.'

[[ -f "$HR_CFG" ]] || {
  echo "missing: $HR_CFG" >&2
  exit 1
}

cp "$HR_CFG" "${HR_CFG}.bak.strict-placement"
if grep -q '^  memory_enabled: true$' "$HR_CFG"; then
  sed -i 's/^  memory_enabled: true$/  memory_enabled: false/' "$HR_CFG"
  echo "hr-agent: memory_enabled -> false"
elif grep -q '^  memory_enabled: false$' "$HR_CFG"; then
  echo "hr-agent: memory_enabled already false"
else
  echo "hr-agent: memory_enabled line not found — inspect $HR_CFG" >&2
  exit 1
fi

if [[ -f "$HR_SOUL" ]] && ! grep -qF "$MARKER" "$HR_SOUL"; then
  cp "$HR_SOUL" "${HR_SOUL}.bak.strict-placement"
  {
    echo ""
    echo "$MARKER"
    echo ""
    printf '%s\n' "$BLOCK"
  } >>"$HR_SOUL"
  echo "hr-agent SOUL: strict placement block appended"
elif [[ -f "$HR_SOUL" ]]; then
  echo "hr-agent SOUL: marker already present"
fi

systemctl --user restart hermes-gateway-hr-agent.service
systemctl --user is-active hermes-gateway-hr-agent.service
grep -nE 'memory_enabled|user_profile_enabled' "$HR_CFG" | head -5
