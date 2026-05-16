#!/usr/bin/env bash
# Tower: compare all agent profiles to mohammed (reference personal agent).
# Run on sergio: bash scripts/tower-audit-align-to-mohammed.sh
set -euo pipefail

REF=mohammed
SPIRE_GENERAL=1503342972950024244
PROFILES=(mohammed arinze sergio krati hr-agent research-agent)

ref_cfg="/home/openclaw/.hermes/profiles/${REF}/config.yaml"
ref_env="/home/openclaw/.hermes/profiles/${REF}/.env"

echo "======== Reference: $REF ========"
echo "--- discord (config.yaml) ---"
awk '/^discord:/{p=1} p{print} /^[a-z_]+:/ && !/^discord:/{if(p&&n++) exit}' "$ref_cfg" 2>/dev/null || true
echo "--- session ---"
grep -E 'group_sessions_per_user|record_sessions' "$ref_cfg" 2>/dev/null || true
echo "--- memory ---"
awk '/^memory:/{p=1} p{print} /^[a-z_]+:/ && !/^memory:/{if(p&&n++) exit}' "$ref_cfg" 2>/dev/null | head -8
echo "--- env keys ---"
grep -E '^DISCORD_|^MEMOS_|GATEWAY_' "$ref_env" 2>/dev/null | cut -d= -f1 | sort
echo "--- SOUL markers ---"
for m in 'Tower Discord context' 'Tower MemOS' 'Tower channel recap' 'Tower HR strict'; do
  grep -c "$m" "/home/openclaw/.hermes/profiles/${REF}/SOUL.md" 2>/dev/null || echo "0"
done | paste -sd' ' -
echo "--- systemd ---"
systemctl --user is-active hermes-gateway.service 2>/dev/null || true

for p in "${PROFILES[@]}"; do
  [[ "$p" == "$REF" ]] && continue
  cfg="/home/openclaw/.hermes/profiles/${p}/config.yaml"
  envf="/home/openclaw/.hermes/profiles/${p}/.env"
  echo ""
  echo "======== $p vs $REF ========"
  echo "--- discord ---"
  awk '/^discord:/{p=1} p{print} /^[a-z_]+:/ && !/^discord:/{if(p&&n++) exit}' "$cfg" 2>/dev/null || true
  echo "--- session ---"
  grep -E 'group_sessions_per_user|record_sessions' "$cfg" 2>/dev/null || echo "(missing)"
  ign=$(grep '^DISCORD_IGNORE_NO_MENTION=' "$envf" 2>/dev/null || echo "DISCORD_IGNORE_NO_MENTION=(unset->default true)")
  echo "--- $ign ---"
  echo "--- allowlist set? ---"
  grep -q '^DISCORD_ALLOWED_USERS=' "$envf" && echo "DISCORD_ALLOWED_USERS=yes" || echo "DISCORD_ALLOWED_USERS=NO"
  tok=$(grep -c '^DISCORD_BOT_TOKEN=' "$envf" 2>/dev/null || echo 0)
  echo "--- DISCORD_BOT_TOKEN lines: $tok ---"
  unit="hermes-gateway-${p}.service"
  [[ "$p" == "mohammed" ]] && unit=hermes-gateway.service
  printf '--- %s: ' "$unit"
  systemctl --user is-active "$unit" 2>/dev/null || echo inactive
done

echo ""
echo "======== Global ~/.hermes/.env ========"
grep -E '^DISCORD_IGNORE' /home/openclaw/.hermes/.env 2>/dev/null || echo "(no DISCORD_IGNORE in global)"
