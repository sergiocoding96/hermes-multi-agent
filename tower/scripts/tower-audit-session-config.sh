#!/usr/bin/env bash
# Tower: audit session / Discord continuity settings on sergio (no secrets).
# Run on sergio: bash scripts/tower-audit-session-config.sh
set -euo pipefail

PROFILES=(mohammed arinze sergio krati hr-agent research-agent)

for p in "${PROFILES[@]}"; do
  echo "======== $p ========"
  cfg="/home/openclaw/.hermes/profiles/$p/config.yaml"
  if [[ -f "$cfg" ]]; then
    grep -nE 'group_sessions|compaction|max_context|session' "$cfg" 2>/dev/null | head -15 || true
    echo "--- discord ---"
    awk '/^discord:/{f=1} f{print} /^[a-z_]+:/ && !/^discord:/{if(f&&n++) exit}' "$cfg" 2>/dev/null | head -22
  fi
  soul="/home/openclaw/.hermes/profiles/$p/SOUL.md"
  if [[ -f "$soul" ]]; then
    echo "--- SOUL markers ---"
    grep -c 'Tower Discord context' "$soul" 2>/dev/null || echo "0 discord"
    grep -c 'Tower MemOS' "$soul" 2>/dev/null || echo "0 memos"
  fi
  envf="/home/openclaw/.hermes/profiles/$p/.env"
  if [[ -f "$envf" ]]; then
    echo "--- env keys (names only) ---"
    grep -E '^DISCORD_|^MEMOS_' "$envf" | cut -d= -f1 | tr '\n' ' '
    echo
  fi
  sessdir="/home/openclaw/.hermes/profiles/$p/sessions"
  if [[ -d "$sessdir" ]]; then
    echo "--- sessions dir ---"
    ls -lt "$sessdir" 2>/dev/null | head -4
  fi
  echo
done

echo "======== sergio discord channels ========"
python3 <<'PY'
import json
from pathlib import Path
p = Path("/home/openclaw/.hermes/profiles/sergio/channel_directory.json")
if p.exists():
    d = json.loads(p.read_text())
    for plat, items in d.get("platforms", {}).items():
        print(f"  {plat}: {len(items)} entries")
        for x in items[:8]:
            print(f"    - {x.get('name')} id={x.get('id')} type={x.get('type')}")
PY
