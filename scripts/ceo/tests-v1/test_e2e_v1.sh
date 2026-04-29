#!/usr/bin/env bash
#
# End-to-end test against a live MemOS v1 server at $MEMOS_ENDPOINT
# (default http://localhost:8001). Skips cleanly when the server isn't up
# or the operator hasn't sourced their CEO profile.
#
# What it covers:
#   1. Write a uniquely-tagged memory via memos-write-v1.sh
#   2. Search for the same memory via memos-search-v1.sh
#   3. Assert the round-trip lands and the v2-shape adapter sees it
#
# This test does NOT mutate other agents' cubes — it only writes to the
# CEO's own cube via MEMOS_WRITABLE_CUBE_IDS.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CEO_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# Auto-source the CEO env if it exists and the operator hasn't already set
# the required vars in this shell.
ENV_FILE="${CEO_ENV_FILE:-$HOME/.hermes/profiles/ceo/.env}"
if [[ -f "$ENV_FILE" ]] && [[ -z "${MEMOS_API_KEY:-}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

ENDPOINT="${MEMOS_ENDPOINT:-http://localhost:8001}"

# Skip if the server isn't reachable.
if ! curl -fs --max-time 3 "${ENDPOINT}/health" >/dev/null 2>&1 \
   && ! curl -fs --max-time 3 "${ENDPOINT}/" >/dev/null 2>&1; then
  echo "SKIP  v1 server not reachable at ${ENDPOINT}"
  exit 0
fi

if [[ -z "${MEMOS_API_KEY:-}" ]]; then
  echo "SKIP  MEMOS_API_KEY not set; either source ~/.hermes/profiles/ceo/.env or export it"
  exit 0
fi

UNIQUE_TAG="ceo-e2e-$(date +%s%N)"
CONTENT="E2E test write at $(date -u +%FT%TZ) — chunk ${UNIQUE_TAG}"

echo "1) writing memory tagged ${UNIQUE_TAG}"
WRITE_OUT="$(bash "$CEO_DIR/memos-write-v1.sh" \
  --content "$CONTENT" \
  --summary "e2e round-trip" \
  --chunk-id "$UNIQUE_TAG")"
echo "$WRITE_OUT" | head -c 300; echo

# Give the v1 scheduler a moment to materialize the write into the index.
sleep 2

echo "2) searching for the unique tag"
SEARCH_OUT="$(bash "$CEO_DIR/memos-search-v1.sh" "$UNIQUE_TAG" --max 5)"
echo "$SEARCH_OUT" | python3 -c 'import json,sys;d=json.load(sys.stdin); print("totalHits:", d["totalHits"])'

HITS="$(echo "$SEARCH_OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["totalHits"])')"
if [[ "$HITS" -lt 1 ]]; then
  echo "FAIL  expected at least 1 hit for tag ${UNIQUE_TAG}, got ${HITS}" >&2
  echo "      raw response:" >&2
  bash "$CEO_DIR/memos-search-v1.sh" "$UNIQUE_TAG" --raw >&2
  exit 1
fi

echo
echo "PASS  e2e round-trip succeeded (${HITS} hit(s) for ${UNIQUE_TAG})"
