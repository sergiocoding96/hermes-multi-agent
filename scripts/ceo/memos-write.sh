#!/usr/bin/env bash
#
# memos-write.sh — Share a memory to the hub as the CEO.
#
# Usage:
#   bash scripts/ceo/memos-write.sh --content "text" [--summary "..."] [--agent "ceo"]
#
# Prerequisites:
#   source ~/.claude/memos-hub.env
#   OR set MEMOS_HUB_URL and MEMOS_HUB_TOKEN in the environment.
#
# This goes through the hub's /memories/share endpoint, which is the sanctioned
# path for writing cross-agent memories (never bypass via direct SQLite writes).

set -euo pipefail

usage() {
  echo "Usage: $0 --content \"text\" [--summary \"...\"] [--agent \"ceo\"] [--chunk-id ID]" >&2
  echo "       --content   Required. The memory text to share." >&2
  echo "       --summary   Optional summary (defaults to first 120 chars of content)." >&2
  echo "       --agent     Source agent name (default: ceo)." >&2
  echo "       --chunk-id  Stable source chunk ID for dedup (default: random UUID)." >&2
  exit 2
}

CONTENT=""
SUMMARY=""
AGENT="ceo"
CHUNK_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --content)  CONTENT="$2";   shift 2 ;;
    --summary)  SUMMARY="$2";   shift 2 ;;
    --agent)    AGENT="$2";     shift 2 ;;
    --chunk-id) CHUNK_ID="$2";  shift 2 ;;
    -h|--help)  usage ;;
    *) echo "Unknown flag: $1" >&2; usage ;;
  esac
done

if [[ -z "$CONTENT" ]]; then
  echo "Error: --content is required." >&2
  usage
fi

# Default summary
if [[ -z "$SUMMARY" ]]; then
  SUMMARY="${CONTENT:0:120}"
fi

# Generate a stable chunk-id if not given
if [[ -z "$CHUNK_ID" ]]; then
  CHUNK_ID="ceo-$(python3 -c "import uuid; print(str(uuid.uuid4()))")"
fi

# ─── Load credentials ───
ENV_FILE="${CEO_ENV_FILE:-$HOME/.claude/memos-hub.env}"
if [[ -f "$ENV_FILE" ]] && [[ -z "${MEMOS_HUB_TOKEN:-}" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

HUB_URL="${MEMOS_HUB_URL:-http://localhost:18992}"
TOKEN="${MEMOS_HUB_TOKEN:-}"

if [[ -z "$TOKEN" ]]; then
  echo "Error: MEMOS_HUB_TOKEN not set. Run provision-ceo-token.sh or source ~/.claude/memos-hub.env." >&2
  exit 1
fi

# ─── Build payload ───
PAYLOAD="$(python3 -c "
import json, sys
memory = {
    'sourceChunkId': sys.argv[1],
    'sourceAgent': sys.argv[2],
    'role': 'assistant',
    'content': sys.argv[3],
    'summary': sys.argv[4],
    'kind': 'paragraph',
}
print(json.dumps({'memory': memory}))
" "$CHUNK_ID" "$AGENT" "$CONTENT" "$SUMMARY")"

# ─── POST to hub ───
RESPONSE="$(curl -sf --max-time 15 \
  -X POST "${HUB_URL}/api/v1/hub/memories/share" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "$PAYLOAD" \
  2>/dev/null)"

if [[ -z "$RESPONSE" ]]; then
  echo "Error: No response from hub at $HUB_URL." >&2
  exit 1
fi

echo "$RESPONSE" | python3 -m json.tool
