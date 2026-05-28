#!/bin/bash
# Hermes Memory System stress test — 2026-05-17
# Verifies: services, daemon, viewer, search, attribution, isolation, audit,
# web stack, embeddings, models.

set -u  # don't set -e — we want to keep going on minor failures
PASS=0
FAIL=0
SKIP=0

ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
skip() { echo "  ⏭️  $1"; SKIP=$((SKIP+1)); }

echo "════════════════════════════════════════════════════════════════"
echo " HERMES MEMORY SYSTEM STRESS TEST — $(date -Iseconds)"
echo "════════════════════════════════════════════════════════════════"

# ───────────────────────── 1. systemd services ─────────────────────────
echo ""
echo "▸ 1. Hermes gateway services"
for svc in hermes-gateway hermes-gateway-arinze hermes-gateway-hr-agent hermes-gateway-krati hermes-gateway-research-agent hermes-gateway-sergio cloak-service; do
  if systemctl --user is-active --quiet "$svc.service" 2>/dev/null; then
    ok "$svc active"
  else
    fail "$svc not active"
  fi
done
# These should be STOPPED post-2026-05-17
echo "  (expected stopped:)"
for svc in memos-server memos-hub; do
  if systemctl --user is-active --quiet "$svc.service" 2>/dev/null; then
    fail "$svc still running (should be disabled)"
  else
    ok "$svc inactive (disabled)"
  fi
done

# ───────────────────────── 2. plugin daemon ─────────────────────────
echo ""
echo "▸ 2. v2 plugin daemon"
DPID=$(pgrep -af "bridge\.cts.*--daemon" | grep -v grep | awk '{print $1}' | head -1)
if [ -n "$DPID" ]; then
  ok "daemon running (pid=$DPID)"
else
  fail "no daemon process"
fi
if ss -tln 2>/dev/null | grep -q "127.0.0.1:18800"; then
  ok "port 18800 bound"
else
  fail "port 18800 not bound"
fi
if curl -s --max-time 5 -I http://localhost:18800/ 2>/dev/null | head -1 | grep -q "200 OK"; then
  ok "HTTP viewer responding"
else
  fail "HTTP viewer not responding"
fi
if curl -sk --max-time 5 -I https://tower.taila4a33f.ts.net/ 2>/dev/null | head -1 | grep -q "200"; then
  ok "Tailscale Serve proxy responding"
else
  fail "Tailscale Serve not responding"
fi

# ───────────────────────── 3. data state ─────────────────────────
echo ""
echo "▸ 3. Memory store data integrity"
DB=~/.hermes/memos-plugin/data/memos.db
counts=$(sqlite3 "$DB" "
SELECT 'traces|' || share_scope || '|' || COUNT(*) FROM traces GROUP BY share_scope;
SELECT 'episodes|' || share_scope || '|' || COUNT(*) FROM episodes GROUP BY share_scope;
SELECT 'policies|' || share_scope || '|' || COUNT(*) FROM policies GROUP BY share_scope;
SELECT 'world_model|' || share_scope || '|' || COUNT(*) FROM world_model GROUP BY share_scope;
SELECT 'skills|' || share_scope || '|' || COUNT(*) FROM skills GROUP BY share_scope;
")
echo "  share_scope distribution:"
echo "$counts" | awk -F'|' '{printf "    %-12s  %-8s  %s\n", $1, $2, $3}'
# Verify: traces/policies/episodes should be private; world_model/skills should be local
priv_t=$(sqlite3 "$DB" "SELECT COUNT(*) FROM traces WHERE share_scope='private'")
total_t=$(sqlite3 "$DB" "SELECT COUNT(*) FROM traces")
[ "$priv_t" = "$total_t" ] && ok "all $total_t traces are private" || fail "traces: $priv_t/$total_t are private"
priv_p=$(sqlite3 "$DB" "SELECT COUNT(*) FROM policies WHERE share_scope='private'")
total_p=$(sqlite3 "$DB" "SELECT COUNT(*) FROM policies")
[ "$priv_p" = "$total_p" ] && ok "all $total_p policies are private" || fail "policies: $priv_p/$total_p are private"
local_s=$(sqlite3 "$DB" "SELECT COUNT(*) FROM skills WHERE share_scope='local'")
total_s=$(sqlite3 "$DB" "SELECT COUNT(*) FROM skills")
[ "$local_s" = "$total_s" ] && ok "all $total_s skills are local (shared)" || fail "skills: $local_s/$total_s are local"

# ───────────────────────── 4. embedding coverage ─────────────────────────
echo ""
echo "▸ 4. Embedding (BGE-large) coverage"
has_summary=$(sqlite3 "$DB" "SELECT COUNT(*) FROM traces WHERE vec_summary IS NOT NULL")
dim_sample=$(sqlite3 "$DB" "SELECT length(vec_summary) FROM traces WHERE vec_summary IS NOT NULL LIMIT 1")
dim=$((dim_sample / 4))
[ "$has_summary" -ge "$total_t" ] && ok "vec_summary backfill complete ($has_summary/$total_t)" || fail "vec_summary partial ($has_summary/$total_t)"
[ "$dim" = "1024" ] && ok "vec dim=1024 (BGE-large)" || fail "vec dim=$dim (expected 1024)"
queue_pending=$(sqlite3 "$DB" "SELECT COUNT(*) FROM embedding_retry_queue WHERE status='pending'")
[ "$queue_pending" = "0" ] && ok "retry queue clean (0 pending)" || fail "retry queue has $queue_pending pending"

# ───────────────────────── 5. forensic audit ─────────────────────────
echo ""
echo "▸ 5. Forensic share_scope_audit"
trigger_count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'share_scope_audit%'")
[ "$trigger_count" = "6" ] && ok "all 6 triggers installed" || fail "only $trigger_count/6 triggers"
unexpected=$(sqlite3 "$DB" "SELECT COUNT(*) FROM share_scope_audit WHERE COALESCE(new_scope,'')='local' AND table_name IN ('traces','policies','episodes') AND ts_ms > $(date -d '20 minutes ago' +%s)000")
[ "$unexpected" = "0" ] && ok "no traces/policies/episodes promoted to local in last 20 min" || fail "$unexpected unexpected promotions in last 20 min"

# ───────────────────────── 6. cron — promote disabled ─────────────────────────
echo ""
echo "▸ 6. Cron — auto-promoter must be disabled"
if crontab -l 2>/dev/null | grep -qE "^[^#].*promote-memos-shares\.py"; then
  fail "auto-promote cron is ACTIVE (should be disabled)"
else
  ok "auto-promote cron disabled"
fi
if [ ! -f /home/openclaw/Coding/Hermes/.claude/worktrees/nice-mclaren-13f017/scripts/promote-memos-shares.py ]; then
  ok "orphan worktree removed"
else
  fail "orphan worktree still exists"
fi

# ───────────────────────── 7. API stress: 10 parallel searches ─────────────────────────
echo ""
echo "▸ 7. API stress: 10 parallel /memory/search calls"
COOKIE=/tmp/memos-cookie.txt
curl -s -c "$COOKIE" -X POST http://localhost:18800/api/v1/auth/login \
  -H "Content-Type: application/json" -d '{"password":"Open.claw2026!"}' >/dev/null
queries=("RAM compatibility FPR" "embedding model BGE" "memory architecture" \
         "tailscale ACL" "Idealista PDF" "Gemini API key" \
         "cron auto promote" "share scope private" \
         "skill crystallization L2" "DeepSeek summarizer")
start=$(date +%s%N)
results=""
for q in "${queries[@]}"; do
  ( curl -s -b "$COOKIE" -X POST http://localhost:18800/api/v1/memory/search \
      -H "Content-Type: application/json" \
      -d "{\"query\":\"$q\",\"limit\":3}" -o /tmp/stress-q-"$RANDOM".json 2>&1 ) &
done
wait
end=$(date +%s%N)
elapsed_ms=$(( (end - start) / 1000000 ))
files=$(ls /tmp/stress-q-*.json 2>/dev/null | wc -l)
ok_files=$(grep -l '"hits"' /tmp/stress-q-*.json 2>/dev/null | wc -l)
attribution_hits=$(grep -l '(learned by ' /tmp/stress-q-*.json 2>/dev/null | wc -l)
[ "$ok_files" = "10" ] && ok "all 10 queries returned hits structure" || fail "only $ok_files/10 returned hits"
[ "$attribution_hits" -ge 1 ] && ok "$attribution_hits/10 responses include '(learned by ...)' attribution" || fail "no attribution in any response"
echo "  elapsed: ${elapsed_ms}ms for 10 parallel queries"
rm -f /tmp/stress-q-*.json

# ───────────────────────── 8. explorer tool ─────────────────────────
echo ""
echo "▸ 8. tools/memos-explorer.py functional"
cd /home/openclaw/Coding/Hermes
if python3.12 tools/memos-explorer.py profiles >/tmp/expl-profiles.out 2>&1 && grep -q "hr-agent" /tmp/expl-profiles.out; then
  ok "explorer 'profiles' returns hr-agent et al."
else
  fail "explorer 'profiles' failed"
fi
if python3.12 tools/memos-explorer.py vec-stats 2>/dev/null | grep -q "dim=1024"; then
  ok "explorer 'vec-stats' reports dim=1024"
else
  fail "explorer 'vec-stats' failed"
fi
if python3.12 tools/memos-explorer.py traces sergio --limit 1 2>/dev/null | grep -q "tr_"; then
  ok "explorer 'traces sergio' returns rows"
else
  fail "explorer 'traces sergio' failed"
fi

# ───────────────────────── 9. web stack ─────────────────────────
echo ""
echo "▸ 9. Web stack (Firecrawl + SearXNG + Cloak)"
# Firecrawl + SearXNG are on-demand (idle-stopped by firecrawl-idle-monitor) — a
# down service is EXPECTED, not a memory failure, so SKIP rather than FAIL.
curl -s --max-time 5 localhost:3002/ 2>/dev/null | grep -q "Firecrawl" && ok "Firecrawl responding (/)" || skip "Firecrawl down (on-demand / idle-stopped — not a memory fault)"
curl -s --max-time 5 "localhost:8888/healthz" 2>/dev/null | head -c 50 | grep -qE "OK|200|searx" && ok "SearXNG healthy" || skip "SearXNG down (on-demand / idle-stopped — not a memory fault)"
curl -s --max-time 5 localhost:9378/health 2>/dev/null | grep -qE "ok|true|healthy" && ok "Cloak healthy" || fail "Cloak not responding"

# ───────────────────────── 10. memory-stress: 5 sequential searches, each unique ─────────────────────────
echo ""
echo "▸ 10. Daemon resilience — 5 unique sequential queries"
for i in 1 2 3 4 5; do
  q="memory test query $i $(date +%s)"
  resp=$(curl -s -b "$COOKIE" -X POST http://localhost:18800/api/v1/memory/search \
    -H "Content-Type: application/json" -d "{\"query\":\"$q\",\"limit\":2}")
  hits=$(echo "$resp" | python3.12 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('hits',[])))" 2>/dev/null)
  if [ -n "$hits" ]; then
    ok "query $i: $hits hits"
  else
    fail "query $i: parse failure"
  fi
done

# ───────────────────────── summary ─────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo " STRESS TEST SUMMARY"
echo "════════════════════════════════════════════════════════════════"
echo "   Passed: $PASS"
echo "   Failed: $FAIL"
echo "   Skipped: $SKIP (on-demand services down — not a memory fault)"
total=$((PASS+FAIL))
[ "$FAIL" = "0" ] && echo "   Status: ✅ ALL GREEN ($PASS/$total$([ "$SKIP" -gt 0 ] && echo ", $SKIP skipped"))" || echo "   Status: ❌ $FAIL/$total failing"
exit "$FAIL"
