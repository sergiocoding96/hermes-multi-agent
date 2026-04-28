#!/usr/bin/env bash
#
# Unit tests for memos-write-v1.sh. Drives the script against a fake server
# and asserts on the request shape (path, payload keys, custom_tags carrying
# summary/chunk_id/agent, writable_cube_ids).

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$TESTS_DIR/_lib.sh"

WRITE_SCRIPT="$CEO_DIR/memos-write-v1.sh"
LOG_PATH="$(mktemp -t memos-write-log.XXXXXX)"
PORT_FILE="$(mktemp -t memos-write-port.XXXXXX)"
trap_cleanup

start_fake_server "$LOG_PATH" "$PORT_FILE" ok

export CEO_ENV_FILE="/nonexistent-$(date +%s)"
export MEMOS_ENDPOINT="http://127.0.0.1:$FAKE_PORT"
export MEMOS_API_KEY="test-key-write-456"
export MEMOS_USER_ID="ceo"
export MEMOS_WRITABLE_CUBE_IDS="ceo-cube"

# ── Case 1: minimal --content ────────────────────────────────────────────────
echo "case 1: minimal --content"
bash "$WRITE_SCRIPT" --content "hello v1" >/dev/null
LAST_REQ="$(tail -n 1 "$LOG_PATH")"

assert_contains "case1 path"        "/product/add"               "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["path"])')"
assert_eq       "case1 user_id"     "ceo"                        "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["body"]["user_id"])')"
assert_eq       "case1 mode"        "fine"                       "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["body"]["mode"])')"
assert_eq       "case1 async_mode"  "sync"                       "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["body"]["async_mode"])')"
assert_eq       "case1 content"     "hello v1"                   "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["body"]["messages"][0]["content"])')"
assert_eq       "case1 role"        "assistant"                  "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["body"]["messages"][0]["role"])')"
assert_eq       "case1 cube[0]"     "ceo-cube"                   "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["body"]["writable_cube_ids"][0])')"
# Default summary tag = first 120 chars of content (here, just "hello v1")
assert_contains "case1 summary tag" "summary:hello v1"           "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(",".join(json.load(sys.stdin)["body"]["custom_tags"]))')"
assert_contains "case1 agent tag"   "agent:ceo"                  "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(",".join(json.load(sys.stdin)["body"]["custom_tags"]))')"
assert_contains "case1 chunk tag"   "chunk_id:ceo-"              "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(",".join(json.load(sys.stdin)["body"]["custom_tags"]))')"
assert_contains "case1 auth"        "Bearer test-key-write-456"  "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["headers"].get("Authorization",""))')"

# ── Case 2: --summary explicit ───────────────────────────────────────────────
echo "case 2: --summary explicit"
bash "$WRITE_SCRIPT" --content "longer body" --summary "tldr-here" >/dev/null
LAST_REQ="$(tail -n 1 "$LOG_PATH")"
assert_contains "case2 summary tag" "summary:tldr-here"          "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(",".join(json.load(sys.stdin)["body"]["custom_tags"]))')"

# ── Case 3: --chunk-id explicit ──────────────────────────────────────────────
echo "case 3: --chunk-id explicit"
bash "$WRITE_SCRIPT" --content "x" --chunk-id "stable-id-9001" >/dev/null
LAST_REQ="$(tail -n 1 "$LOG_PATH")"
assert_contains "case3 chunk tag"   "chunk_id:stable-id-9001"    "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(",".join(json.load(sys.stdin)["body"]["custom_tags"]))')"

# ── Case 4: --agent override ─────────────────────────────────────────────────
echo "case 4: --agent override"
bash "$WRITE_SCRIPT" --content "x" --agent "ceo-shadow" >/dev/null
LAST_REQ="$(tail -n 1 "$LOG_PATH")"
assert_contains "case4 agent tag"   "agent:ceo-shadow"           "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(",".join(json.load(sys.stdin)["body"]["custom_tags"]))')"

# ── Case 5: --mode fast ──────────────────────────────────────────────────────
echo "case 5: --mode fast"
bash "$WRITE_SCRIPT" --content "x" --mode fast >/dev/null
LAST_REQ="$(tail -n 1 "$LOG_PATH")"
assert_eq       "case5 mode"        "fast"                       "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["body"]["mode"])')"

# ── Case 6: bad --mode rejected ──────────────────────────────────────────────
echo "case 6: invalid --mode rejected"
EXIT_CODE=0
( bash "$WRITE_SCRIPT" --content "x" --mode bogus ) >/dev/null 2>&1 || EXIT_CODE=$?
[[ "$EXIT_CODE" -ne 0 ]] && PASS=$((PASS+1)) && echo "  ok   case6 exit_nonzero" || { FAIL=$((FAIL+1)); FAIL_LINES+=("case6 expected nonzero"); echo "  FAIL case6 expected nonzero"; }

# ── Case 7: missing --content rejected ───────────────────────────────────────
echo "case 7: missing --content rejected"
EXIT_CODE=0
( bash "$WRITE_SCRIPT" ) >/dev/null 2>&1 || EXIT_CODE=$?
[[ "$EXIT_CODE" -ne 0 ]] && PASS=$((PASS+1)) && echo "  ok   case7 exit_nonzero" || { FAIL=$((FAIL+1)); FAIL_LINES+=("case7 expected nonzero"); echo "  FAIL case7 expected nonzero"; }

# ── Case 8: multi-cube writable list ─────────────────────────────────────────
echo "case 8: multi-cube writable list"
MEMOS_WRITABLE_CUBE_IDS="ceo-cube,shared-cube" bash "$WRITE_SCRIPT" --content "multi" >/dev/null
LAST_REQ="$(tail -n 1 "$LOG_PATH")"
assert_eq       "case8 cubes_n"     "2"                          "$(echo "$LAST_REQ" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["body"]["writable_cube_ids"]))')"

stop_fake_server
summary_and_exit
