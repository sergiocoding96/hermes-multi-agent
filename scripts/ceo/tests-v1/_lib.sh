#!/usr/bin/env bash
# Shared helpers for the v1 CEO bash-script unit tests.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CEO_DIR="$(cd "$TESTS_DIR/.." && pwd)"

PASS=0
FAIL=0
FAIL_LINES=()

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  ok   $label"
  else
    FAIL=$((FAIL + 1))
    FAIL_LINES+=("$label: expected [$expected] got [$actual]")
    echo "  FAIL $label" >&2
    echo "       expected: $expected" >&2
    echo "       actual:   $actual" >&2
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "  ok   $label"
  else
    FAIL=$((FAIL + 1))
    FAIL_LINES+=("$label: missing [$needle]")
    echo "  FAIL $label" >&2
    echo "       expected to contain: $needle" >&2
    echo "       actual: $haystack" >&2
  fi
}

start_fake_server() {
  # Args: <log path> <port-file> [<mode>]
  local log_path="$1" port_file="$2" mode="${3:-ok}"
  rm -f "$log_path" "$port_file"
  python3 "$TESTS_DIR/_fake_memos.py" --log "$log_path" --port-file "$port_file" --mode "$mode" &
  FAKE_PID=$!
  for _ in $(seq 1 50); do
    if [[ -s "$port_file" ]]; then
      FAKE_PORT="$(cat "$port_file")"
      return 0
    fi
    sleep 0.05
  done
  echo "fake server failed to start" >&2
  kill "$FAKE_PID" 2>/dev/null || true
  return 1
}

stop_fake_server() {
  if [[ -n "${FAKE_PID:-}" ]]; then
    kill "$FAKE_PID" 2>/dev/null || true
    wait "$FAKE_PID" 2>/dev/null || true
    FAKE_PID=""
  fi
}

trap_cleanup() {
  trap 'stop_fake_server; rm -f "$LOG_PATH" "$PORT_FILE" 2>/dev/null || true' EXIT
}

summary_and_exit() {
  echo
  if [[ "$FAIL" -eq 0 ]]; then
    echo "PASS $PASS assertions"
    exit 0
  else
    echo "FAIL  $FAIL of $((PASS + FAIL)) assertions" >&2
    for line in "${FAIL_LINES[@]}"; do
      echo "  - $line" >&2
    done
    exit 1
  fi
}
