#!/usr/bin/env bash
#
# memos-write-v1.sh — Store a memory in the CEO's MemOS v1 cube.
#
# v1 replacement for memos-write.sh. Posts to the v1 server's standard
# /product/add endpoint, writing to whichever cubes are listed in
# MEMOS_WRITABLE_CUBE_IDS (in practice, just `ceo-cube`).
#
# Usage:
#   bash scripts/ceo/memos-write-v1.sh --content "text" \
#       [--summary "..."] [--agent "ceo"] [--chunk-id ID] [--mode fine|fast]
#
# v1 vs v2 divergences (kept arg-compatible on purpose):
#   --summary   v1 has no first-class "summary" field on /product/add, so we
#               surface the summary as a tag of the form `summary:<text>`.
#               Search adapters treat the first 200 chars of the stored
#               content as the summary, mirroring v2 hits.
#   --chunk-id  v1's add endpoint does not accept an external dedup key, so
#               we surface it as a tag of the form `chunk_id:<id>`. Stable
#               chunk ids still let downstream consumers dedup via tag
#               filtering, but server-side dedup is not enforced.
#
# Required env (set via ~/.hermes/profiles/ceo/.env, chmod 600):
#   MEMOS_ENDPOINT             default: http://localhost:8001
#   MEMOS_API_KEY              raw key from setup-memos-agents.py
#   MEMOS_USER_ID              default: ceo
#   MEMOS_WRITABLE_CUBE_IDS    comma-separated; default: ceo-cube

set -euo pipefail

usage() {
  echo "Usage: $0 --content \"text\" [--summary \"...\"] [--agent \"ceo\"] [--chunk-id ID] [--mode fine|fast]" >&2
  echo "       --content   Required. The memory text to store." >&2
  echo "       --summary   Optional summary (defaults to first 120 chars of content). Stored as a tag." >&2
  echo "       --agent     Source agent name (default: ceo). Stored as a tag." >&2
  echo "       --chunk-id  Stable source chunk id (default: random UUID). Stored as a tag for dedup." >&2
  echo "       --mode      MemReader extraction mode: fine (default) or fast." >&2
  exit 2
}

CONTENT=""
SUMMARY=""
AGENT="ceo"
CHUNK_ID=""
MODE="fine"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --content)  CONTENT="$2";   shift 2 ;;
    --summary)  SUMMARY="$2";   shift 2 ;;
    --agent)    AGENT="$2";     shift 2 ;;
    --chunk-id) CHUNK_ID="$2";  shift 2 ;;
    --mode)     MODE="$2";      shift 2 ;;
    -h|--help)  usage ;;
    *) echo "Unknown flag: $1" >&2; usage ;;
  esac
done

if [[ -z "$CONTENT" ]]; then
  echo "Error: --content is required." >&2
  usage
fi

if [[ "$MODE" != "fine" && "$MODE" != "fast" ]]; then
  echo "Error: --mode must be 'fine' or 'fast'." >&2
  usage
fi

# Defaults that mirror the v2 script's behaviour.
if [[ -z "$SUMMARY" ]]; then
  SUMMARY="${CONTENT:0:120}"
fi
if [[ -z "$CHUNK_ID" ]]; then
  CHUNK_ID="ceo-$(python3 -c 'import uuid; print(uuid.uuid4())')"
fi

# ─── Load credentials ───
ENV_FILE="${CEO_ENV_FILE:-$HOME/.hermes/profiles/ceo/.env}"
if [[ -f "$ENV_FILE" ]] && [[ -z "${MEMOS_API_KEY:-}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

ENDPOINT="${MEMOS_ENDPOINT:-http://localhost:8001}"
API_KEY="${MEMOS_API_KEY:-}"
USER_ID="${MEMOS_USER_ID:-ceo}"
WRITABLE_CUBE_IDS="${MEMOS_WRITABLE_CUBE_IDS:-ceo-cube}"

if [[ -z "$API_KEY" ]]; then
  echo "Error: MEMOS_API_KEY not set. Configure $ENV_FILE or export it." >&2
  exit 1
fi

# ─── Build payload ───
PAYLOAD="$(
  CONTENT="$CONTENT" SUMMARY="$SUMMARY" AGENT="$AGENT" CHUNK_ID="$CHUNK_ID" \
  USER_ID="$USER_ID" CUBES="$WRITABLE_CUBE_IDS" MODE="$MODE" \
  python3 -c '
import json, os
agent = os.environ["AGENT"]
chunk_id = os.environ["CHUNK_ID"]
summary = os.environ["SUMMARY"]
cubes = [c.strip() for c in os.environ["CUBES"].split(",") if c.strip()]
tags = [
    "agent:" + agent,
    "chunk_id:" + chunk_id,
    "summary:" + summary,
]
payload = {
    "user_id": os.environ["USER_ID"],
    "writable_cube_ids": cubes,
    "messages": [{"role": "assistant", "content": os.environ["CONTENT"]}],
    "async_mode": "sync",
    "mode": os.environ["MODE"],
    "custom_tags": tags,
}
print(json.dumps(payload))
'
)"

# ─── Call v1 add ───
RESPONSE="$(curl -sf --max-time 60 \
  -X POST "${ENDPOINT}/product/add" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d "$PAYLOAD" \
  2>/dev/null)" || {
  echo "Error: request to ${ENDPOINT}/product/add failed (curl exit $?)." >&2
  exit 1
}

if [[ -z "$RESPONSE" ]]; then
  echo "Error: empty response from ${ENDPOINT}." >&2
  exit 1
fi

echo "$RESPONSE" | python3 -m json.tool
