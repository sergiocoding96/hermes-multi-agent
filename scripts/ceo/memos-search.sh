#!/usr/bin/env bash
#
# memos-search.sh — Search the memos hub as the CEO.
#
# Usage:
#   bash scripts/ceo/memos-search.sh "query" [--max N] [--raw]
#
# Prerequisites:
#   source ~/.claude/memos-hub.env
#   OR set MEMOS_HUB_URL and MEMOS_HUB_TOKEN in the environment.
#
# Output: JSON array of hits, each with:
#   summary, excerpt, ownerName, sourceAgent, taskTitle, hubRank, visibility
#
# The CEO (Claude Code session) can pipe this output through `jq` or use it directly.

set -euo pipefail

usage() {
  echo "Usage: $0 \"query\" [--max N] [--raw]" >&2
  echo "       --max N   Return at most N results (default: 10)" >&2
  echo "       --raw     Print raw JSON response without formatting" >&2
  exit 2
}

QUERY=""
MAX_RESULTS=10
RAW=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max)  MAX_RESULTS="$2"; shift 2 ;;
    --raw)  RAW=true; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown flag: $1" >&2; usage ;;
    *)
      if [[ -z "$QUERY" ]]; then
        QUERY="$1"
      else
        echo "Extra argument: $1" >&2; usage
      fi
      shift
      ;;
  esac
done

if [[ -z "$QUERY" ]]; then
  echo "Error: query string required." >&2
  usage
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

# ─── Call hub search ───
RESPONSE="$(curl -sf --max-time 15 \
  -X POST "${HUB_URL}/api/v1/hub/search" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"query\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$QUERY"),\"maxResults\":$MAX_RESULTS}" \
  2>/dev/null)"

if [[ -z "$RESPONSE" ]]; then
  echo "Error: No response from hub at $HUB_URL. Is it running?" >&2
  exit 1
fi

# ─── Output ───
if [[ "$RAW" == "true" ]]; then
  echo "$RESPONSE"
else
  # Compact, jq-friendly output: hits array + meta
  echo "$RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
hits = d.get('hits', [])
meta = d.get('meta', {})
out = {
    'query': $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$QUERY"),
    'totalHits': len(hits),
    'hits': [
        {
            'rank': h.get('hubRank'),
            'summary': h.get('summary', '')[:200],
            'excerpt': h.get('excerpt', '')[:240],
            'ownerName': h.get('ownerName', 'unknown'),
            'sourceAgent': h.get('sourceAgent', ''),
            'taskTitle': h.get('taskTitle'),
            'visibility': h.get('visibility'),
            'remoteHitId': h.get('remoteHitId'),
        }
        for h in hits
    ],
    'meta': meta,
}
print(json.dumps(out, indent=2))
"
fi
