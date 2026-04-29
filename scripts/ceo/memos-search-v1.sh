#!/usr/bin/env bash
#
# memos-search-v1.sh — Search MemOS v1 server as the CEO.
#
# v1 replacement for memos-search.sh. Talks to the v1 MemOS server at
# $MEMOS_ENDPOINT (default http://localhost:8001) over the standard
# /product/search endpoint, authenticated with a long-lived BCrypt-hashed
# agent key (no token refresh). Multi-cube reads via CompositeCubeView are
# enabled by passing every readable cube id in the request body.
#
# Usage:
#   bash scripts/ceo/memos-search-v1.sh "query" [--max N] [--raw]
#
# Required env (set via ~/.hermes/profiles/ceo/.env, chmod 600):
#   MEMOS_ENDPOINT             default: http://localhost:8001
#   MEMOS_API_KEY              raw key from setup-memos-agents.py (one-time print)
#   MEMOS_USER_ID              default: ceo
#   MEMOS_READABLE_CUBE_IDS    comma-separated, e.g. "ceo-cube,research-cube,email-mkt-cube"
#                              (when unset, falls back to the CEO's own cube)
#
# Output: JSON with the same top-level shape as the v2 hub variant so existing
# consumers (`jq '.hits[].summary'`, etc.) keep working:
#   { query, totalHits, hits: [...], meta }
#
# Each hit carries best-effort v2 field names. v1 does not expose every v2
# field; missing fields are surfaced as null and documented inline below.

set -euo pipefail

usage() {
  echo "Usage: $0 \"query\" [--max N] [--raw]" >&2
  echo "       --max N   Return at most N results (default: 10, max: 50)" >&2
  echo "       --raw     Print the raw v1 JSON response (no v2-shape adapter)" >&2
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
READABLE_CUBE_IDS="${MEMOS_READABLE_CUBE_IDS:-ceo-cube}"

if [[ -z "$API_KEY" ]]; then
  echo "Error: MEMOS_API_KEY not set. Configure $ENV_FILE or export it." >&2
  exit 1
fi

# Top-k clamped to v1 server's accepted range.
if ! [[ "$MAX_RESULTS" =~ ^[0-9]+$ ]] || [[ "$MAX_RESULTS" -lt 1 ]]; then
  echo "Error: --max must be a positive integer." >&2
  exit 2
fi
if [[ "$MAX_RESULTS" -gt 50 ]]; then
  MAX_RESULTS=50
fi

# ─── Build payload ───
PAYLOAD="$(QUERY="$QUERY" USER_ID="$USER_ID" CUBES="$READABLE_CUBE_IDS" TOP_K="$MAX_RESULTS" python3 -c '
import json, os
cubes = [c.strip() for c in os.environ["CUBES"].split(",") if c.strip()]
payload = {
    "query": os.environ["QUERY"],
    "user_id": os.environ["USER_ID"],
    "readable_cube_ids": cubes,
    "top_k": int(os.environ["TOP_K"]),
    "relativity": 0.05,
    "dedup": "mmr",
}
print(json.dumps(payload))
')"

# ─── Call v1 search ───
RESPONSE="$(curl -sf --max-time 15 \
  -X POST "${ENDPOINT}/product/search" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d "$PAYLOAD" \
  2>/dev/null)" || {
  echo "Error: request to ${ENDPOINT}/product/search failed (curl exit $?)." >&2
  echo "       Check MEMOS_ENDPOINT, MEMOS_API_KEY, and that the v1 server is reachable." >&2
  exit 1
}

if [[ -z "$RESPONSE" ]]; then
  echo "Error: empty response from ${ENDPOINT}." >&2
  exit 1
fi

# ─── Output ───
if [[ "$RAW" == "true" ]]; then
  echo "$RESPONSE"
  exit 0
fi

# v2-shape adapter. v1 returns { data: { text_mem: [ { cube_id, memories: [ { id, memory, metadata } ] } ] } }.
# We project onto the v2 hits[] shape that existing CEO consumers expect.
# We pass the response through MEMOS_RAW_RESPONSE rather than stdin to avoid the
# heredoc-vs-pipe redirection contention (heredoc captures stdin, blocking sys.stdin.read()).
QUERY="$QUERY" MEMOS_RAW_RESPONSE="$RESPONSE" python3 <<'PY'
import json, os, sys

raw = os.environ.get("MEMOS_RAW_RESPONSE", "")
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    print(json.dumps({"error": "non-json response from v1 server", "raw": raw[:500]}))
    sys.exit(1)

data = d.get("data", d) or {}
text_mem = data.get("text_mem", []) or []

hits = []
for bucket in text_mem:
    bucket_cube = bucket.get("cube_id") or bucket.get("cube") or ""
    for mem in bucket.get("memories", []) or []:
        meta = mem.get("metadata") or {}
        memory_text = mem.get("memory") or mem.get("content") or ""
        relativity = meta.get("relativity")
        try:
            relativity = round(float(relativity), 4) if relativity is not None else None
        except (TypeError, ValueError):
            relativity = None
        hits.append({
            "rank": len(hits) + 1,
            # v1 has no separate summary field — derive from the memory text.
            "summary": memory_text[:200],
            "excerpt": memory_text[:240],
            # ownerName / sourceAgent: v1 doesn't carry an explicit owner per
            # memory, but cube_id is a 1:1 proxy for the producing agent.
            "ownerName": meta.get("user_id") or bucket_cube or "unknown",
            "sourceAgent": meta.get("source_agent") or bucket_cube or "",
            "cubeId": bucket_cube,
            "taskTitle": meta.get("task_title"),
            "visibility": meta.get("visibility", "private"),
            "remoteHitId": mem.get("id") or mem.get("mem_id"),
            "tags": meta.get("tags") or [],
            "createdAt": meta.get("created_at"),
            "relevance": relativity,
        })

out = {
    "query": os.environ["QUERY"],
    "totalHits": len(hits),
    "hits": hits,
    "meta": {
        "backend": "memos-v1",
        "endpoint": data.get("endpoint") or "/product/search",
        "cubeView": "composite" if len({h["cubeId"] for h in hits if h["cubeId"]}) > 1 else "single",
    },
}
print(json.dumps(out, indent=2))
PY
