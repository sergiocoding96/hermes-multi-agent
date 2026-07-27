#!/usr/bin/env bash
# Tower: align personal agents arinze + sergio for THE SPIRE #general + DMs (match mohammed hub fixes).
# Run on sergio: bash scripts/tower-align-personal-agents-arinze-sergio.sh
set -euo pipefail

SPIRE_GENERAL=1503342972950024244
CEO_HOME=1501140736651821076
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ensure_ignore_false() {
  local envf="$1"
  [[ -f "$envf" ]] || return 0
  if grep -q '^DISCORD_IGNORE_NO_MENTION=' "$envf"; then
    sed -i 's/^DISCORD_IGNORE_NO_MENTION=.*/DISCORD_IGNORE_NO_MENTION=false/' "$envf"
  else
    echo 'DISCORD_IGNORE_NO_MENTION=false' >>"$envf"
  fi
}

ensure_no_thread_general() {
  local cfg="$1"
  [[ -f "$cfg" ]] || return 0
  if grep -q "$SPIRE_GENERAL" "$cfg"; then
    echo "no_thread already has SPIRE #general in $cfg"
    return 0
  fi
  cp "$cfg" "${cfg}.bak.align-personal"
  if grep -q '^  no_thread_channels:' "$cfg"; then
    sed -i "/^  no_thread_channels:/a\\  - '${SPIRE_GENERAL}'" "$cfg"
  elif grep -q '^  auto_thread:' "$cfg"; then
    sed -i "/^  auto_thread:/a\\  no_thread_channels:\\n  - '${SPIRE_GENERAL}'" "$cfg"
  else
    sed -i "/^discord:/a\\  no_thread_channels:\\n  - '${SPIRE_GENERAL}'" "$cfg"
  fi
  echo "added no_thread_channels SPIRE #general -> $cfg"
}

fix_sergio_bot_token() {
  local envf="/home/openclaw/.hermes/profiles/sergio/.env"
  [[ -f "$envf" ]] || return 0
  if grep -q '^DISCORD_BOT_TOKEN=' "$envf"; then
    echo "sergio: DISCORD_BOT_TOKEN already set"
    return 0
  fi
  if grep -q '^DISCORD-BOT-TOKEN=' "$envf"; then
    cp "$envf" "${envf}.bak.align-personal"
    line=$(grep '^DISCORD-BOT-TOKEN=' "$envf")
    token="${line#DISCORD-BOT-TOKEN=}"
    echo "DISCORD_BOT_TOKEN=${token}" >>"$envf"
    echo "sergio: copied DISCORD-BOT-TOKEN -> DISCORD_BOT_TOKEN"
  else
    echo "sergio: WARNING no Discord bot token key found in .env" >&2
  fi
}

ensure_sergio_ceo_home() {
  local cfg="/home/openclaw/.hermes/profiles/sergio/config.yaml"
  local envf="/home/openclaw/.hermes/profiles/sergio/.env"
  grep -q "^  free_response_channels: '${CEO_HOME}'" "$cfg" \
    || sed -i "s|^  free_response_channels:.*|  free_response_channels: '${CEO_HOME}'|" "$cfg"
  if grep -q '^DISCORD_HOME_CHANNEL=' "$envf"; then
    sed -i "s/^DISCORD_HOME_CHANNEL=.*/DISCORD_HOME_CHANNEL=${CEO_HOME}/" "$envf"
  else
    echo "DISCORD_HOME_CHANNEL=${CEO_HOME}" >>"$envf"
  fi
  echo "sergio: CEO home ${CEO_HOME} (ambient); #general uses @ + no_thread"
}

ensure_arinze_hub_home() {
  local envf="/home/openclaw/.hermes/profiles/arinze/.env"
  cp "$envf" "${envf}.bak.align-personal"
  if grep -q '^DISCORD_HOME_CHANNEL=' "$envf"; then
    sed -i "s/^DISCORD_HOME_CHANNEL=.*/DISCORD_HOME_CHANNEL=${SPIRE_GENERAL}/" "$envf"
  else
    echo "DISCORD_HOME_CHANNEL=${SPIRE_GENERAL}" >>"$envf"
  fi
  echo "arinze: DISCORD_HOME_CHANNEL -> THE SPIRE #general"
}

# SOUL / session context (idempotent)
if [[ -f "$SCRIPT_DIR/tower-discord-session-context.sh" ]]; then
  bash "$SCRIPT_DIR/tower-discord-session-context.sh"
fi

# --- arinze ---
ARINZE_CFG=/home/openclaw/.hermes/profiles/arinze/config.yaml
ARINZE_ENV=/home/openclaw/.hermes/profiles/arinze/.env
ensure_ignore_false "$ARINZE_ENV"
ensure_arinze_hub_home
ensure_no_thread_general "$ARINZE_CFG"

# --- sergio (CEO personal — keep CEO home, fix token + #general threads) ---
SERGIO_CFG=/home/openclaw/.hermes/profiles/sergio/config.yaml
SERGIO_ENV=/home/openclaw/.hermes/profiles/sergio/.env
ensure_ignore_false "$SERGIO_ENV"
fix_sergio_bot_token
ensure_sergio_ceo_home
ensure_no_thread_general "$SERGIO_CFG"

systemctl --user restart hermes-gateway-arinze.service
systemctl --user restart hermes-gateway-sergio.service
sleep 4
echo "--- gateway status ---"
systemctl --user is-active hermes-gateway-arinze.service hermes-gateway-sergio.service
echo "--- arinze discord ---"
awk '/^discord:/{p=1} p{print} /^[a-z_]+:/ && !/^discord:/{if(p&&n++) exit}' "$ARINZE_CFG"
echo "--- sergio discord ---"
awk '/^discord:/{p=1} p{print} /^[a-z_]+:/ && !/^discord:/{if(p&&n++) exit}' "$SERGIO_CFG"
echo "--- allowlist keys (must stay per-owner) ---"
grep -E '^DISCORD_ALLOWED_USERS=' "$ARINZE_ENV" "$SERGIO_ENV" | cut -d= -f1 | sort -u
echo "done: arinze + sergio aligned for THE SPIRE #general @ + DM (no allowlist changes)"
