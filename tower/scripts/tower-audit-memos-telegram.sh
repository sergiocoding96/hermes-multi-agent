#!/usr/bin/env bash
# Run on sergio: MemOS key presence + Telegram token line hash per profile (no secrets printed).
set -euo pipefail
BASE=/home/openclaw/.hermes/profiles
for p in mohammed arinze sergio krati hr-agent research-agent; do
  echo "=== ${p} ==="
  if grep -qE '^MEMOS_USER_ID=' "$BASE/$p/.env" 2>/dev/null; then echo "  MEMOS_USER_ID=<set>"; else echo "  MEMOS_USER_ID=<missing>"; fi
  if grep -qE '^MEMOS_CUBE_ID=' "$BASE/$p/.env" 2>/dev/null; then echo "  MEMOS_CUBE_ID=<set>"; else echo "  MEMOS_CUBE_ID=<missing>"; fi
  if grep -qE '^TELEGRAM_BOT_TOKEN=' "$BASE/$p/.env" 2>/dev/null; then
    h=$(grep '^TELEGRAM_BOT_TOKEN=' "$BASE/$p/.env" | sha256sum | awk '{print $1}')
    echo "  TELEGRAM_BOT_TOKEN sha256=${h}"
  else
    echo "  TELEGRAM_BOT_TOKEN=<absent>"
  fi
done
echo "--- If two profiles show the same sha256, they share the same Telegram token (only one gateway can hold it). ---"
