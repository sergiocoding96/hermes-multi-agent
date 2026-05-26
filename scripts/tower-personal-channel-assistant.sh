#!/usr/bin/env bash
# Tower: personal agents read recent channel context on @mention (todo, tasks with teammates).
# - Hermes history_backfill (default on); auto_thread off so backfill sees parent channel, not empty thread.
# - SOUL: use [Recent channel messages]; MemOS is not this channel transcript.
# Run on sergio: bash scripts/tower-personal-channel-assistant.sh
set -euo pipefail

SPIRE_GENERAL=1503342972950024244
PROFILES=(mohammed arinze krati)
MARKER="## Tower personal assistant (channel @)"
SOUL_BLOCK=$'Tower personal assistant (channel @):\n- When a teammate @mentions this bot in a server channel, Hermes may attach a [Recent channel messages] block (messages since this bot last replied here, up to history_backfill_limit). Use it for personal-assistant work: todos, action items, summaries of what someone asked the user to do.\n- The human must @ THIS bot by name — being @mentioned by someone else does not wake the bot.\n- Prefer [Recent channel messages] and the user\'s message over MemOS for "what did they ask in this channel?" Do not treat MemOS or another Tower bot\'s DM as this channel unless quoted here.\n- If context is thin, ask for a one-line recap or suggest reply+@ with the task text. Do not claim you cannot see the channel if [Recent channel messages] was provided.'

patch_discord_config() {
  local profile="$1"
  local cfg="/home/openclaw/.hermes/profiles/${profile}/config.yaml"
  [[ -f "$cfg" ]] || return 0
  cp "$cfg" "${cfg}.bak.tower-personal-channel-assistant"
  python3 <<PY
import re
from pathlib import Path

cfg = Path("${cfg}")
text = cfg.read_text()
if not re.search(r"^discord:\s*$", text, re.M):
    print(f"skip discord block: {cfg}")
    raise SystemExit(0)

# auto_thread: false — parent-channel backfill (auto threads hide Sergio's lines in parent)
text = re.sub(r"(^discord:\n(?:  .+\n)*?)(  auto_thread: )true", r"\1\2false", text, count=1)
if "  auto_thread: false" not in text and "  auto_thread: true" in text:
    text = text.replace("  auto_thread: true", "  auto_thread: false", 1)

def set_discord_key(key: str, value: str) -> None:
    global text
    pat = rf"^  {re.escape(key)}:.*$"
    line = f"  {key}: {value}"
    if re.search(pat, text, re.M):
        text = re.sub(pat, line, text, count=1)
    else:
        text = re.sub(r"(^discord:\n)", rf"\1{line}\n", text, count=1)

set_discord_key("history_backfill", "true")
set_discord_key("history_backfill_limit", "80")

# Keep hub in no_thread_channels if block exists
if "no_thread_channels:" in text and "${SPIRE_GENERAL}" not in text:
    text = re.sub(
        r"(  no_thread_channels:\n)",
        rf"\1  - '${SPIRE_GENERAL}'\n",
        text,
        count=1,
    )
elif "no_thread_channels:" not in text and "  auto_thread:" in text:
    text = re.sub(
        r"(  auto_thread: false\n)",
        rf"\1  no_thread_channels:\n  - '${SPIRE_GENERAL}'\n",
        text,
        count=1,
    )

cfg.write_text(text)
print(f"patched discord: {cfg}")
PY
}

append_soul() {
  local soul="$1"
  [[ -f "$soul" ]] || return 0
  if grep -qF "$MARKER" "$soul"; then
    echo "SOUL already has marker: $soul"
    return 0
  fi
  cp "$soul" "${soul}.bak.tower-personal-channel-assistant"
  {
    echo ""
    echo "$MARKER"
    echo ""
    printf '%s\n' "$SOUL_BLOCK"
  } >>"$soul"
  echo "appended SOUL: $soul"
}

for p in "${PROFILES[@]}"; do
  patch_discord_config "$p"
  append_soul "/home/openclaw/.hermes/profiles/${p}/SOUL.md"
done

# MemOS bridge: collapse runaway processes before restart.
# SAFE cleanup only — never blanket `pkill -f 'bridge\.cts'` (kills the :18800
# daemon + matches admin shells). See scripts/lib-bridge-safe-cleanup.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib-bridge-safe-cleanup.sh"
bridge_count="$(pgrep -c -f 'bridge\.cts --agent' 2>/dev/null || echo 0)"
if [[ "${bridge_count}" -gt 8 ]]; then
  echo "memos bridge processes=${bridge_count} — cleaning (preserving :18800 daemon)"
  safe_bridge_cleanup
  sleep 2
fi

systemctl --user restart hermes-gateway.service
systemctl --user restart hermes-gateway-arinze.service
systemctl --user restart hermes-gateway-krati.service 2>/dev/null || true

echo "--- discord (mohammed) ---"
sed -n '/^discord:/,/^whatsapp:/p' /home/openclaw/.hermes/profiles/mohammed/config.yaml | head -20
echo "--- gateways ---"
systemctl --user is-active hermes-gateway.service hermes-gateway-arinze.service hermes-gateway-krati.service 2>/dev/null || true
echo "--- bridge count ---"
pgrep -c -f 'bridge\.cts' 2>/dev/null || echo 0
echo "done: tower-personal-channel-assistant"
