#!/usr/bin/env bash
# Tower: Research strict placement — disable MemOS injection on research-agent (same policy as HR).
# Policy: docs/tower-agent-access-architecture.md §6.6, §7.3
# Run on sergio: bash scripts/tower-research-strict-placement-enforce.sh
set -euo pipefail

RS_CFG=/home/openclaw/.hermes/profiles/research-agent/config.yaml
RS_SOUL=/home/openclaw/.hermes/profiles/research-agent/SOUL.md
RESEARCH_HOME=1503722569277374534
MARKER="## Tower Research strict placement (MemOS off)"
BLOCK=$'Tower Research strict placement (MemOS off):\n- memory.memory_enabled is false on this profile: no automatic MemOS injection block in the prompt.\n- For recap ("your messages in #research", "assistant messages in this session"), use only this Hermes session transcript for this #research placement.\n- Do not cite "memory context provided" or other bots\' dialogue as #research history.\n- Do not answer with hub word, zebra, or #general content unless the user quoted it in #research.\n- Long-term research facts: only if memory is re-enabled or the user explicitly asks to store/recall research facts.'

POISON_MARKER="## Tower Research poisoned-turn filter"
POISON_BLOCK=$'Tower Research poisoned-turn filter:\n- Assistant turns in #research about hub word, zebra, #general, Mohamed personal agent, or HR topics are placement errors — omit from recap.\n- For "last question in #research only", use only user questions asked in #research for research work.\n- Never substitute CEO, HR, or Mohamed agent answers as Research replies.'

RECAP_MARKER="## Tower channel recap (#research home only)"
RECAP_BLOCK=$'Tower channel recap (#research home only):\n- If the user asks for your last replies in #research or this home room, answer only from this Hermes session transcript.\n- Do not call memory_search, session_search, or memory_timeline for that recap unless the user explicitly asks for stored memory.\n- If you have no prior assistant turns in this session, say so plainly. Never paste HR, CEO, or Mohamed #general dialogue as your #research replies.'

[[ -f "$RS_CFG" ]] || {
  echo "missing: $RS_CFG" >&2
  exit 1
}

cp "$RS_CFG" "${RS_CFG}.bak.research-strict"
if grep -q '^  memory_enabled: true$' "$RS_CFG"; then
  sed -i 's/^  memory_enabled: true$/  memory_enabled: false/' "$RS_CFG"
  echo "research-agent: memory_enabled -> false"
elif grep -q '^  memory_enabled: false$' "$RS_CFG"; then
  echo "research-agent: memory_enabled already false"
else
  echo "research-agent: memory_enabled line not found" >&2
  exit 1
fi

append_block() {
  local soul="$1" marker="$2" block="$3"
  if grep -qF "$marker" "$soul"; then
    echo "already: $marker"
    return 0
  fi
  cp "$soul" "${soul}.bak.research-strict"
  {
    echo ""
    echo "$marker"
    echo ""
    printf '%s\n' "$block"
  } >>"$soul"
  echo "appended: $marker"
}

if grep -q 'Tower channel recap (#hr' "$RS_SOUL"; then
  sed -i 's/Tower channel recap (#hr \/ home only)/Tower channel recap (#research home only)/' "$RS_SOUL"
  sed -i 's/in #hr /in #research /g' "$RS_SOUL"
  sed -i 's/as your #hr replies/as your #research replies/g' "$RS_SOUL"
  sed -i 's/Never paste Mohamed, CEO, or Research bot/Never paste Mohamed, CEO, or HR bot/' "$RS_SOUL"
  echo "research-agent SOUL: retargeted hr-only recap block -> #research"
fi

append_block "$RS_SOUL" "$MARKER" "$BLOCK"
append_block "$RS_SOUL" "$POISON_MARKER" "$POISON_BLOCK"
if ! grep -qF "$RECAP_MARKER" "$RS_SOUL"; then
  append_block "$RS_SOUL" "$RECAP_MARKER" "$RECAP_BLOCK"
fi

ENV=/home/openclaw/.hermes/profiles/research-agent/.env
if [[ -f "$ENV" ]]; then
  if grep -q '^DISCORD_IGNORE_NO_MENTION=' "$ENV"; then
    sed -i 's/^DISCORD_IGNORE_NO_MENTION=.*/DISCORD_IGNORE_NO_MENTION=false/' "$ENV"
  else
    echo 'DISCORD_IGNORE_NO_MENTION=false' >>"$ENV"
  fi
  if grep -q '^DISCORD_HOME_CHANNEL=' "$ENV"; then
    sed -i "s/^DISCORD_HOME_CHANNEL=.*/DISCORD_HOME_CHANNEL=${RESEARCH_HOME}/" "$ENV"
  fi
  echo "research-agent .env: IGNORE_NO_MENTION=false, HOME=${RESEARCH_HOME}"
fi

systemctl --user restart hermes-gateway-research-agent.service
sleep 3
systemctl --user is-active hermes-gateway-research-agent.service
grep -nE 'memory_enabled|user_profile_enabled' "$RS_CFG" | head -3
