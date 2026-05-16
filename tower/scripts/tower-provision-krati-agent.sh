#!/usr/bin/env bash
# Tower: provision Hermes profile krati (Krati personal agent) on sergio.
# Policy: docs/tower-agent-access-architecture.md — personal agent, same hub rules as mohammed/arinze.
# Run on sergio: bash scripts/tower-provision-krati-agent.sh
#
# Before first gateway start, operator must set on sergio:
#   ~/.hermes/profiles/krati/.env  →  DISCORD_BOT_TOKEN, DISCORD_ALLOWED_USERS (Krati numeric id)
# Then: systemctl --user start hermes-gateway-krati.service
set -euo pipefail

PROFILE=krati
SPIRE_GENERAL=1503342972950024244
PROFILE_DIR=/home/openclaw/.hermes/profiles/${PROFILE}
CFG="${PROFILE_DIR}/config.yaml"
ENV="${PROFILE_DIR}/.env"
UNIT=/home/openclaw/.config/systemd/user/hermes-gateway-${PROFILE}.service
HERMES_PY=/home/openclaw/.hermes/hermes-agent/venv/bin/python
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

create_profile() {
  if [[ -d "$PROFILE_DIR" ]]; then
    echo "profile ${PROFILE} already exists at ${PROFILE_DIR}"
    return 0
  fi
  echo "creating profile ${PROFILE} (clone config from mohammed, no secrets)..."
  cd /home/openclaw/.hermes/hermes-agent
  HERMES_HOME=/home/openclaw/.hermes/profiles/mohammed \
    "$HERMES_PY" -m hermes_cli.main profile create "${PROFILE}" --clone-from mohammed --no-alias
}

strip_cloned_secrets() {
  [[ -f "$ENV" ]] || return 0
  cp "$ENV" "${ENV}.bak.tower-provision-krati"
  for key in DISCORD_BOT_TOKEN DISCORD-BOT-TOKEN DISCORD_ALLOWED_USERS TELEGRAM_BOT_TOKEN \
    MEMOS_USER_ID MEMOS_CUBE_ID MEMOS_API_KEY MEMOS_API_URL MEMOS_QUEUE_PATH; do
    sed -i "/^${key}=/d" "$ENV" 2>/dev/null || true
  done
}

ensure_env_hub() {
  [[ -f "$ENV" ]] || touch "$ENV"
  grep -q '^DISCORD_HOME_CHANNEL=' "$ENV" \
    && sed -i "s/^DISCORD_HOME_CHANNEL=.*/DISCORD_HOME_CHANNEL=${SPIRE_GENERAL}/" "$ENV" \
    || echo "DISCORD_HOME_CHANNEL=${SPIRE_GENERAL}" >>"$ENV"
  if grep -q '^DISCORD_IGNORE_NO_MENTION=' "$ENV"; then
    sed -i 's/^DISCORD_IGNORE_NO_MENTION=.*/DISCORD_IGNORE_NO_MENTION=false/' "$ENV"
  else
    echo 'DISCORD_IGNORE_NO_MENTION=false' >>"$ENV"
  fi
  grep -q '^# Tower krati' "$ENV" || cat >>"$ENV" <<'EOF'

# Tower krati — operator: set before starting gateway
# DISCORD_BOT_TOKEN=
# DISCORD_ALLOWED_USERS=
EOF
}

ensure_discord_yaml() {
  [[ -f "$CFG" ]] || { echo "missing $CFG" >&2; exit 1; }
  if ! grep -q "$SPIRE_GENERAL" "$CFG"; then
    cp "$CFG" "${CFG}.bak.tower-provision-krati"
    if grep -q '^  auto_thread:' "$CFG"; then
      sed -i "/^  auto_thread: true$/a\\  no_thread_channels:\\n  - '${SPIRE_GENERAL}'" "$CFG"
    fi
  fi
  sed -i "s/^  require_mention:.*/  require_mention: true/" "$CFG"
  sed -i "s/^  free_response_channels:.*/  free_response_channels: ''/" "$CFG"
  sed -i "s/^  auto_thread:.*/  auto_thread: true/" "$CFG"
  echo "discord block tuned for personal hub (${SPIRE_GENERAL})"
}

install_systemd() {
  if [[ -f "$UNIT" ]]; then
    echo "systemd unit exists: $UNIT"
    return 0
  fi
  sed "s/--profile arinze/--profile ${PROFILE}/g; s/hermes-gateway-arinze/hermes-gateway-${PROFILE}/g" \
    /home/openclaw/.config/systemd/user/hermes-gateway-arinze.service >"$UNIT"
  systemctl --user daemon-reload
  systemctl --user enable "hermes-gateway-${PROFILE}.service"
  echo "installed and enabled hermes-gateway-${PROFILE}.service"
}

apply_soul_policy() {
  [[ -f "$SCRIPT_DIR/tower-discord-session-context.sh" ]] && bash "$SCRIPT_DIR/tower-discord-session-context.sh" || true
  [[ -f "$SCRIPT_DIR/tower-memos-agent-boundary.sh" ]] && bash "$SCRIPT_DIR/tower-memos-agent-boundary.sh" || true
}

maybe_start_gateway() {
  if [[ -f "$ENV" ]] && grep -qE '^DISCORD_BOT_TOKEN=.+$' "$ENV" && grep -qE '^DISCORD_ALLOWED_USERS=.+$' "$ENV"; then
    systemctl --user restart "hermes-gateway-${PROFILE}.service" || systemctl --user start "hermes-gateway-${PROFILE}.service"
    sleep 3
    systemctl --user is-active "hermes-gateway-${PROFILE}.service"
  else
    echo "SKIP gateway start: set DISCORD_BOT_TOKEN and DISCORD_ALLOWED_USERS in ${ENV}"
    echo "Then: systemctl --user start hermes-gateway-${PROFILE}.service"
  fi
}

create_profile
strip_cloned_secrets
ensure_env_hub
ensure_discord_yaml
install_systemd
apply_soul_policy
maybe_start_gateway

echo "--- krati discord (config.yaml) ---"
sed -n '/^discord:/,/^whatsapp:/p' "$CFG" | head -12
echo "--- env keys (no values) ---"
grep -E '^DISCORD_|^MEMOS_' "$ENV" 2>/dev/null | cut -d= -f1 || true
echo "done: profile ${PROFILE} provisioned — see docs/tower-krati-agent-setup.md for Discord app + invite"
