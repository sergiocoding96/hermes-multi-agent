#!/usr/bin/env bash
# Tower: HR must not treat pre-fix cross-placement turns (zebra/hub/#general) as valid #hr history.
# Run on sergio after tower-hr-strict-placement-enforce.sh
set -euo pipefail

HR_SOUL=/home/openclaw/.hermes/profiles/hr-agent/SOUL.md
MARKER="## Tower HR poisoned-turn filter"
BLOCK=$'Tower HR poisoned-turn filter:\n- If this #hr session transcript contains assistant turns about "hub word", "zebra", Mohamed/Mohammed personal agent, or #general, those are placement errors (wrong bot or wrong room), NOT valid HR work.\n- When listing "your assistant messages in #hr", omit those turns and say they are invalid for HR recap.\n- For "last question in #hr only", use only user questions asked in #hr after any such bad turn, or say no valid HR-only Q&A yet.\n- Never answer HR questions using Mohamed CEO or Research dialogue.'

[[ -f "$HR_SOUL" ]] || exit 1
if grep -qF "$MARKER" "$HR_SOUL"; then
  echo "already present: $HR_SOUL"
else
  cp "$HR_SOUL" "${HR_SOUL}.bak.poisoned-filter"
  {
    echo ""
    echo "$MARKER"
    echo ""
    printf '%s\n' "$BLOCK"
  } >>"$HR_SOUL"
  echo "appended: $HR_SOUL"
fi

systemctl --user restart hermes-gateway-hr-agent.service
systemctl --user is-active hermes-gateway-hr-agent.service
