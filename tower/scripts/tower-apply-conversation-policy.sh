#!/usr/bin/env bash
# Tower: apply conversation placement policy on sergio (session scope, MemOS boundary, specialist recap).
# Policy: docs/tower-agent-access-architecture.md §6.6, §9.8
# Run on sergio: bash scripts/tower-apply-conversation-policy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run() {
  local name="$1"
  local path="$2"
  if [[ ! -f "$path" ]]; then
    echo "missing: $path" >&2
    exit 1
  fi
  echo "=== $name ==="
  bash "$path"
}

run "discord session context" "$SCRIPT_DIR/tower-discord-session-context.sh"
run "MemOS vs session boundary" "$SCRIPT_DIR/tower-memos-agent-boundary.sh"
run "specialist channel recap" "$SCRIPT_DIR/tower-hr-channel-recall-fix.sh"

echo "=== done: conversation placement policy applied (see doc §6.6 regression prompt in #hr) ==="
