#!/usr/bin/env bash
# Tower: provision MemOS user/cube + API key for krati on sergio.
# Run on sergio: bash scripts/tower-provision-krati-memos.sh
set -euo pipefail

AGENT_ID=krati
CUBE_ID=krati-cube
ENV_FILE=/home/openclaw/.hermes/profiles/krati/.env
KEY_TMP=/tmp/krati-memos-api-key.tmp

if [[ ! -f "$ENV_FILE" ]]; then
  echo "missing $ENV_FILE — run tower-provision-krati-agent.sh first" >&2
  exit 1
fi

python3.12 <<'PYEOF'
import json
import os
import secrets
import sys
from datetime import datetime, timezone
from pathlib import Path

import bcrypt

sys.path.insert(0, "/home/openclaw/.local/lib/python3.12/site-packages")
os.chdir("/home/openclaw/Coding/MemOS")

from dotenv import load_dotenv

load_dotenv(".env")

from memos.mem_user.user_manager import UserManager, UserRole

AGENT_ID = "krati"
CUBE_ID = "krati-cube"
AUTH_JSON = Path("/home/openclaw/Coding/Hermes/agents-auth.json")
KEY_TMP = Path("/tmp/krati-memos-api-key.tmp")

# --- MemOS DB: user + cube ---
um = UserManager()
try:
    um.create_user(AGENT_ID, UserRole.USER, AGENT_ID)
    print(f"created user: {AGENT_ID}")
except Exception as e:
    print(f"create_user: {e}")

try:
    um.create_cube(CUBE_ID, AGENT_ID, cube_id=CUBE_ID)
    print(f"created cube: {CUBE_ID}")
except Exception as e:
    print(f"create_cube: {e}")

try:
    um.add_user_to_cube(AGENT_ID, CUBE_ID)
    print(f"granted: {AGENT_ID} -> {CUBE_ID}")
except Exception as e:
    print(f"add_user_to_cube: {e}")

# --- agents-auth.json: API key ---
data = json.loads(AUTH_JSON.read_text())
data.setdefault("version", 2)
agents = data.setdefault("agents", [])

raw_key = None
for a in agents:
    if a.get("user_id") == AGENT_ID and not a.get("rotated_at"):
        print(f"agents-auth: {AGENT_ID} already registered (prefix {a.get('key_prefix')})")
        env_path = Path("/home/openclaw/.hermes/profiles/krati/.env")
        if env_path.exists():
            for line in env_path.read_text().splitlines():
                if line.startswith("MEMOS_API_KEY="):
                    raw_key = line.split("=", 1)[1]
                    break
        if not raw_key:
            print("ERROR: krati in agents-auth but MEMOS_API_KEY missing in .env — rotate key manually", file=sys.stderr)
            sys.exit(1)
        break

if not raw_key:
    raw_key = "ak_" + secrets.token_hex(16)
    key_hash = bcrypt.hashpw(raw_key.encode("utf-8"), bcrypt.gensalt(rounds=12)).decode("utf-8")
    agents.append(
        {
            "key_hash": key_hash,
            "key_prefix": raw_key[:12],
            "user_id": AGENT_ID,
            "description": f"{AGENT_ID} - Hermes personal agent",
            "created_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        }
    )
    AUTH_JSON.write_text(json.dumps(data, indent=2) + "\n")
    print(f"created agents-auth entry for {AGENT_ID}")

KEY_TMP.write_text(raw_key)
print(f"MEMOS_USER_ID={AGENT_ID}")
print(f"MEMOS_CUBE_ID={CUBE_ID}")
PYEOF

RAW_KEY=$(cat "$KEY_TMP")
rm -f "$KEY_TMP"

mkdir -p /home/openclaw/.hermes/profiles/krati/memos-state
cp "$ENV_FILE" "${ENV_FILE}.bak.tower-memos"

for key in MEMOS_USER_ID MEMOS_CUBE_ID MEMOS_API_KEY MEMOS_API_URL MEMOS_QUEUE_PATH; do
  sed -i "/^${key}=/d" "$ENV_FILE"
done

{
  echo "MEMOS_USER_ID=${AGENT_ID}"
  echo "MEMOS_CUBE_ID=${CUBE_ID}"
  echo "MEMOS_API_KEY=${RAW_KEY}"
  echo "MEMOS_API_URL=http://localhost:8001"
  echo "MEMOS_QUEUE_PATH=/home/openclaw/.hermes/profiles/krati/memos-state/captures.db"
} >>"$ENV_FILE"

CFG=/home/openclaw/.hermes/profiles/krati/config.yaml
if [[ -f "$CFG" ]] && grep -q 'memory_enabled: false' "$CFG"; then
  sed -i 's/memory_enabled: false/memory_enabled: true/' "$CFG"
fi

if systemctl --user is-enabled hermes-gateway-krati.service &>/dev/null; then
  systemctl --user restart hermes-gateway-krati.service 2>/dev/null \
    || systemctl --user start hermes-gateway-krati.service
  sleep 3
  systemctl --user is-active hermes-gateway-krati.service || true
fi

echo "--- krati MemOS (key names only) ---"
grep '^MEMOS_' "$ENV_FILE" | cut -d= -f1
echo "done: krati MemOS user_id=${AGENT_ID} cube_id=${CUBE_ID}"
