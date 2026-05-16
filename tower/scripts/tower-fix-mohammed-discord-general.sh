#!/usr/bin/env bash
# Tower: fix Mohamed @mention in THE SPIRE #general (1503342972950024244).
# Run on sergio: bash scripts/tower-fix-mohammed-discord-general.sh
set -euo pipefail

SPIRE_GENERAL=1503342972950024244
ENV=/home/openclaw/.hermes/profiles/mohammed/.env
CFG=/home/openclaw/.hermes/profiles/mohammed/config.yaml

backup() {
  local f="$1"
  cp "$f" "${f}.bak.tower-discord-general-$(date +%Y%m%d%H%M%S)"
}

# 1) Home channel = THE SPIRE #general (was CEO home id — wrong guild/channel)
if grep -q '^DISCORD_HOME_CHANNEL=' "$ENV"; then
  backup "$ENV"
  sed -i "s/^DISCORD_HOME_CHANNEL=.*/DISCORD_HOME_CHANNEL=${SPIRE_GENERAL}/" "$ENV"
  echo "DISCORD_HOME_CHANNEL -> ${SPIRE_GENERAL}"
else
  echo "DISCORD_HOME_CHANNEL=${SPIRE_GENERAL}" >>"$ENV"
  echo "appended DISCORD_HOME_CHANNEL"
fi

# 2) Multi-bot #general: do not drop messages that mention humans but not us when we ARE @mentioned
#    Default DISCORD_IGNORE_NO_MENTION=true can silence in edge cases; explicit false is safer for hub.
if grep -q '^DISCORD_IGNORE_NO_MENTION=' "$ENV"; then
  sed -i 's/^DISCORD_IGNORE_NO_MENTION=.*/DISCORD_IGNORE_NO_MENTION=false/' "$ENV"
else
  echo 'DISCORD_IGNORE_NO_MENTION=false' >>"$ENV"
fi
echo "DISCORD_IGNORE_NO_MENTION=false"

# 3) Ensure no_thread_channels includes THE SPIRE #general
if ! grep -q "$SPIRE_GENERAL" "$CFG"; then
  backup "$CFG"
  sed -i "/^  auto_thread: true$/a\\  no_thread_channels:\\n  - '${SPIRE_GENERAL}'" "$CFG"
  echo "added no_thread_channels for #general"
else
  echo "no_thread_channels already has #general"
fi

systemctl --user restart hermes-gateway.service
sleep 4
systemctl --user is-active hermes-gateway.service
echo "--- discord block ---"
awk '/^discord:/{p=1} p{print} /^[a-z_]+:/ && !/^discord:/{if(p&&n++) exit}' "$CFG"
echo "--- env (keys only) ---"
grep -E '^DISCORD_' "$ENV" | cut -d= -f1
