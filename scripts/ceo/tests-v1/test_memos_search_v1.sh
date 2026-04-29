#!/usr/bin/env bash
#
# Unit tests for memos-search-v1.sh. Spins up a fake MemOS v1 server, invokes
# the script with various flag combinations, and asserts on:
#   - the request shape (path, payload keys, top_k, readable_cube_ids)
#   - the Authorization header
#   - the v2-shape adapter output
#   - the --raw passthrough

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$TESTS_DIR/_lib.sh"

SEARCH_SCRIPT="$CEO_DIR/memos-search-v1.sh"
LOG_PATH="$(mktemp -t memos-search-log.XXXXXX)"
PORT_FILE="$(mktemp -t memos-search-port.XXXXXX)"
trap_cleanup

start_fake_server "$LOG_PATH" "$PORT_FILE" ok

# Isolate from any real CEO env file the operator might have on the host.
export CEO_ENV_FILE="/nonexistent-$(date +%s)"
export MEMOS_ENDPOINT="http://127.0.0.1:$FAKE_PORT"
export MEMOS_API_KEY="test-key-abc123"
export MEMOS_USER_ID="ceo"

# ── Case 1: default flags, multi-cube readable list ──────────────────────────
echo "case 1: multi-cube readable list, default --max"
export MEMOS_READABLE_CUBE_IDS="ceo-cube,research-cube,email-mkt-cube"
OUTPUT="$(bash "$SEARCH_SCRIPT" "rocket fuel")"

LAST_REQ="$(tail -n 1 "$LOG_PATH")"
assert_contains "case1 path"        "/product/search"            "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["path"])')"
assert_eq       "case1 query"       "rocket fuel"                "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["body"]["query"])')"
assert_eq       "case1 top_k"       "10"                         "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["body"]["top_k"])')"
assert_eq       "case1 user_id"     "ceo"                        "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["body"]["user_id"])')"
assert_eq       "case1 cubes_n"     "3"                          "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["body"]["readable_cube_ids"]))')"
assert_contains "case1 cube_match"  "research-cube"              "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(",".join(json.load(sys.stdin)["body"]["readable_cube_ids"]))')"
assert_contains "case1 auth"        "Bearer test-key-abc123"     "$(echo "$LAST_REQ" | python3 -c 'import json,sys;d=json.load(sys.stdin); print(d["headers"].get("Authorization",""))')"

# Adapter output shape
assert_eq       "case1 totalHits"   "2"                          "$(echo "$OUTPUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["totalHits"])')"
assert_eq       "case1 meta.cubeView" "composite"                "$(echo "$OUTPUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["meta"]["cubeView"])')"
assert_eq       "case1 hit0.cubeId" "ceo-cube"                   "$(echo "$OUTPUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["hits"][0]["cubeId"])')"

# ── Case 2: single cube, --max override ──────────────────────────────────────
echo "case 2: single cube, --max 5"
export MEMOS_READABLE_CUBE_IDS="ceo-cube"
bash "$SEARCH_SCRIPT" "anything" --max 5 >/dev/null

LAST_REQ="$(tail -n 1 "$LOG_PATH")"
assert_eq       "case2 cubes_n"     "1"                          "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["body"]["readable_cube_ids"]))')"
assert_eq       "case2 top_k"       "5"                          "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["body"]["top_k"])')"

# ── Case 3: --raw ────────────────────────────────────────────────────────────
echo "case 3: --raw passthrough"
RAW_OUT="$(bash "$SEARCH_SCRIPT" "anything" --raw)"
# raw output should be the canned v1 JSON; presence of 'text_mem' is sufficient
assert_contains "case3 raw text_mem" "text_mem"                  "$RAW_OUT"
# adapter would replace memory with summary[200]; raw should still hold 'memory'
assert_contains "case3 raw memory"   "\"memory\""                "$RAW_OUT"

# ── Case 4: MEMOS_READABLE_CUBE_IDS unset → defaults to ceo-cube ─────────────
echo "case 4: default cube fallback when MEMOS_READABLE_CUBE_IDS unset"
unset MEMOS_READABLE_CUBE_IDS
bash "$SEARCH_SCRIPT" "default-fallback" >/dev/null
LAST_REQ="$(tail -n 1 "$LOG_PATH")"
assert_eq       "case4 cubes_n"     "1"                          "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["body"]["readable_cube_ids"]))')"
assert_eq       "case4 cube[0]"     "ceo-cube"                   "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["body"]["readable_cube_ids"][0])')"

# ── Case 5: missing API key → exit non-zero ──────────────────────────────────
echo "case 5: missing MEMOS_API_KEY exits non-zero"
EXIT_CODE=0
( unset MEMOS_API_KEY; bash "$SEARCH_SCRIPT" "anything" ) >/dev/null 2>&1 || EXIT_CODE=$?
assert_eq       "case5 exit_nonzero" "1"                         "$EXIT_CODE"

# ── Case 6: server unreachable → exit non-zero with helpful error ────────────
echo "case 6: unreachable endpoint exits non-zero"
EXIT_CODE=0
ERR_OUT=""
ERR_OUT="$(MEMOS_ENDPOINT="http://127.0.0.1:1" bash "$SEARCH_SCRIPT" "anything" 2>&1 >/dev/null)" || EXIT_CODE=$?
assert_eq       "case6 exit_nonzero" "1"                         "$EXIT_CODE"
assert_contains "case6 err_msg"      "failed"                    "$ERR_OUT"

stop_fake_server
summary_and_exit
