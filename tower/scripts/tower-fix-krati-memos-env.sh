#!/usr/bin/env bash
# Tower: finish krati MemOS .env when agents-auth exists but key was not written.
set -euo pipefail

ENV_FILE=/home/openclaw/.hermes/profiles/krati/.env
AUTH_JSON=/home/openclaw/Coding/Hermes/agents-auth.json

python3.12 <<'PYEOF'
import json
import secrets
from datetime import datetime, timezone
from pathlib import Path

import bcrypt

AGENT_ID = "krati"
AUTH_JSON = Path("/home/openclaw/Coding/Hermes/agents-auth.json")
ENV_FILE = Path("/home/openclaw/.hermes/profiles/krati/.env")

data = json.loads(AUTH_JSON.read_text())
agents = data.setdefault("agents", [])
raw_key = "ak_" + secrets.token_hex(16)
key_hash = bcrypt.hashpw(raw_key.encode("utf-8"), bcrypt.gensalt(rounds=12)).decode("utf-8")

replaced = False
for i, a in enumerate(agents):
    if a.get("user_id") == AGENT_ID:
        agents[i] = {
            "key_hash": key_hash,
            "key_prefix": raw_key[:12],
            "user_id": AGENT_ID,
            "description": f"{AGENT_ID} - Hermes personal agent",
            "created_at": a.get("created_at") or datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
            "rotated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        }
        replaced = True
        break

if not replaced:
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

text = ENV_FILE.read_text() if ENV_FILE.exists() else ""
lines = [ln for ln in text.splitlines() if not ln.startswith(("MEMOS_USER_ID=", "MEMOS_CUBE_ID=", "MEMOS_API_KEY=", "MEMOS_API_URL=", "MEMOS_QUEUE_PATH="))]
lines.extend(
    [
        "MEMOS_USER_ID=krati",
        "MEMOS_CUBE_ID=krati-cube",
        f"MEMOS_API_KEY={raw_key}",
        "MEMOS_API_URL=http://localhost:8001",
        "MEMOS_QUEUE_PATH=/home/openclaw/.hermes/profiles/krati/memos-state/captures.db",
    ]
)
ENV_FILE.write_text("\n".join(lines).rstrip() + "\n")
Path("/tmp/krati-memos-done").write_text("ok")
print("MEMOS_USER_ID=krati")
print("MEMOS_CUBE_ID=krati-cube")
print("MEMOS_API_KEY=<written to .env>")
PYEOF

mkdir -p /home/openclaw/.hermes/profiles/krati/memos-state
systemctl --user restart hermes-gateway-krati.service 2>/dev/null || systemctl --user start hermes-gateway-krati.service
sleep 3
systemctl --user is-active hermes-gateway-krati.service
grep '^MEMOS_' "$ENV_FILE" | cut -d= -f1
echo done
