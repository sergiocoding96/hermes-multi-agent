#!/usr/bin/env bash
#
# refresh-ceo-token.sh — Daily refresh of the CEO hub token.
#
# Re-mints the CEO token (provision-ceo-token.sh is idempotent via identityKey)
# and propagates the new value into ~/.claude.json so the memos-hub MCP server
# picks it up on the next Claude Code session start.
#
# Cron suggestion:
#   @daily /home/openclaw/Coding/Hermes/scripts/ceo/refresh-ceo-token.sh \
#       >> /home/openclaw/.hermes/logs/ceo-token-refresh.log 2>&1
#
# The hub-issued token currently has a ~24h TTL, so daily renewal is the
# safety margin. The hub must be running (memos-hub.service) for this to work.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$HOME/.claude/memos-hub.env"
CLAUDE_JSON="$HOME/.claude.json"

# 1) Mint a fresh token (writes ~/.claude/memos-hub.env)
bash "$REPO/scripts/ceo/provision-ceo-token.sh" >/dev/null

# 2) Propagate the new token into .claude.json's MCP server env
[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE after provision"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
[[ -n "${MEMOS_HUB_TOKEN:-}" ]] || { echo "MEMOS_HUB_TOKEN unset after provision"; exit 1; }

python3 - <<PY
import json, os
path = "$CLAUDE_JSON"
with open(path) as f:
    d = json.load(f)
proj = d["projects"]["/home/openclaw/Coding/Hermes"]["mcpServers"]["memos-hub"]
proj["env"]["MEMOS_HUB_TOKEN"] = os.environ["MEMOS_HUB_TOKEN"]
proj["env"]["MEMOS_HUB_URL"]   = os.environ["MEMOS_HUB_URL"]
with open(path, "w") as f:
    json.dump(d, f, indent=2)
os.chmod(path, 0o600)
print(f"refreshed memos-hub MCP env (token ...{os.environ['MEMOS_HUB_TOKEN'][-12:]})")
PY

echo "[$(date -Iseconds)] CEO token refreshed."
