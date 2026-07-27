#!/usr/bin/env bash
# Compare MemOS identity per profile without printing secrets (sha256 of value).
set -euo pipefail
BASE=/home/openclaw/.hermes/profiles
for p in mohammed arinze sergio krati hr-agent research-agent; do
  uid=$(grep '^MEMOS_USER_ID=' "$BASE/$p/.env" 2>/dev/null | cut -d= -f2- || true)
  cube=$(grep '^MEMOS_CUBE_ID=' "$BASE/$p/.env" 2>/dev/null | cut -d= -f2- || true)
  echo "=== $p ==="
  if [[ -n "$uid" ]]; then echo "  MEMOS_USER_ID sha256=$(printf %s "$uid" | sha256sum | awk '{print $1}')"; else echo "  MEMOS_USER_ID <missing>"; fi
  if [[ -n "$cube" ]]; then echo "  MEMOS_CUBE_ID sha256=$(printf %s "$cube" | sha256sum | awk '{print $1}')"; else echo "  MEMOS_CUBE_ID <missing>"; fi
done
