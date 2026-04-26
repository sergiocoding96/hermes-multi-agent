# MemOS v1 Performance Audit

Paste this as your FIRST message into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`. No other context should be present.

---

## Prompt

The legacy MemOS server at `http://localhost:8001` claims:

- **BCrypt API-key auth** with a warm cache: cold ~350 ms, warm ~40 ms.
- **Rate limit** of 10 wrong-key attempts per user per 60 s (`agent_auth.py`).
- **Three-store backend** (SQLite + Qdrant + Neo4j): each write touches all three; each search may hit one or more.
- **Search modes** `no` / `sim` / `mmr` with per-mode complexity profiles.
- **Chunking** for long content (find the threshold; default likely ~1000–4000 chars).

**Your job: profile real latency / throughput / scaling and find the cliffs.** Score 1-10 per area where 9–10 means "headroom for production at demo scale" and 1–2 means "broken at any scale".

Use marker `V1-PERF-<unix-ts>` on every memory / cube / query you create.

### Zero-knowledge constraint

Do NOT read any of:
- `/tmp/**` beyond files you created this run
- `CLAUDE.md` at any level
- `tests/v1/reports/**`, `tests/v2/reports/**`
- `tests/blind-*`, `tests/zero-knowledge-audit.md`, `tests/security-remediation-report.md`
- `memos-setup/learnings/**`
- any `TASK.md` or plan file
- any commit message that mentions "audit", "score", "fix", or "remediation"

Inputs allowed: this prompt, the live system, source under `/home/openclaw/Coding/MemOS/src/memos/**`. Discover everything else.

### Throwaway profile (provision before any probe)

```bash
curl -s http://localhost:8001/health | jq . || (
  cd /home/openclaw/Coding/MemOS
  set -a && source .env && set +a
  python3.12 -m memos.api.server_api > /tmp/memos-v1-perf.log 2>&1 &
  sleep 5 && curl -s http://localhost:8001/health | jq .
)

export MEMOS_HOME=/tmp/memos-v1-audit-$(uuidgen)
mkdir -p "$MEMOS_HOME/data"
TS=$(date +%s)
python3.12 /home/openclaw/Coding/Hermes/deploy/scripts/setup-memos-agents.py \
  --output "$MEMOS_HOME/agents-auth.json" \
  --agents "audit-v1-perf:V1-PERF-$TS"
```

Teardown:
```bash
rm -rf "$MEMOS_HOME"
sqlite3 ~/.memos/data/memos.db <<SQL
DELETE FROM users WHERE user_id LIKE 'audit-v1-perf%';
DELETE FROM cubes WHERE cube_id LIKE 'V1-PERF-%';
SQL
```

### Recon (first 5 minutes)

1. Read `src/memos/api/middleware/agent_auth.py` — find the BCrypt verify path, cache structure, eviction policy, rate-limit window.
2. Read `src/memos/multi_mem_cube/single_cube.py` — what hits SQLite vs Qdrant vs Neo4j for each operation?
3. Find the chunking constant (`grep -rn "chunk_size\|MAX_CHARS\|MAX_TOKENS"`).
4. `docker stats` on Qdrant + Neo4j containers — baseline CPU + memory before any probe.
5. Note the host: number of CPU cores, RAM, free disk. `lscpu | head; free -h; df -h ~`.

### Probe matrix

For every probe: report P50, P95, P99 latencies + samples + standard deviation. Use `hyperfine`, `wrk`, or a custom Python loop with `time.perf_counter_ns`.

**Auth latency.**
- Cold path: server fresh-restarted, first request with valid key. Latency? Repeat after BCrypt cache eviction (find/induce).
- Warm path: 1000 sequential calls with the same valid key. P50, P95, P99.
- Mixed cold/warm: 5 distinct valid keys, round-robin 1000 calls. Cache hit rate? Eviction triggered?

**Auth rate-limit.**
- Submit 11 wrong-key attempts in 60 s. After the 11th, when does normal traffic resume? Is the lockout window observable (header / response)? What's the lockout granularity (per-IP, per-user, global)?

**Single-write latency by mode.**
- Fast mode: 100 sequential `POST /memories`. P50/P95/P99. Where's the time spent (auth / SQLite / Qdrant / Neo4j)? Look at server logs with timing.
- Fine mode: same, with extraction. The LLM call should dominate. Quantify the LLM-call share.
- Async mode: caller-side latency should be near zero; check that. Then time the background extraction completion.

**Single-search latency by mode + corpus size.**
- Insert 100 memories. Run 50 queries each in `no`, `sim`, `mmr`. P50/P95/P99 per mode.
- Insert 1000 memories. Repeat. Is search latency growing linearly, sub-linearly, or with a cliff?
- Insert 10000 memories (if feasible — synthetic content, fast mode, no-LLM). Repeat. Look for the saturation cliff.

**Chunking cost.**
- Submit memories of size 100 / 1000 / 5000 / 50000 chars. Find the chunking threshold. Time per chunk for fine-mode extraction.

**Concurrent throughput (writes).**
- 5 parallel writers, 200 writes each = 1000 total. Sustained throughput (writes/sec)? Tail latency degradation?
- 50 parallel writers, 20 writes each. Where does the system saturate? CPU? SQLite WAL? Embedder?

**Concurrent throughput (searches).**
- 50 parallel searchers against a 1000-memory corpus. Throughput (queries/sec)? P99 latency?

**Cross-cube concurrent.**
- 5 agents (5 cubes), each 100 writes + 100 searches. Does cross-cube traffic interfere (lock contention, cache pollution)?

**CompositeCubeView (CEO) latency.**
- With 5 cubes each holding 1000 memories, run a CEO-mode search. Does latency scale ~linearly with cube count? Are results ranked correctly across cubes?

**Memory + CPU footprint.**
- `ps -o pid,rss,vsz,pcpu -p $(pgrep -f memos.api.server_api)` baseline. After 10000 memory inserts. After 10000 searches. Document growth.
- Embedder model RAM share — `pmap` or similar.

**Cold-start time.**
- `kill` then start. Measure time-to-first-200 on `/health` and time-to-first successful write.

**Network bind hot-path.**
- All tests so far are loopback. Is there any non-loopback path (Qdrant client → Qdrant container) where TLS / DNS / re-resolution adds material latency? Time it.

### Reporting

For every finding:

- Class: latency-cliff / throughput-cap / memory-leak / cache-miss / contention / startup-cost.
- Reproducer: exact commands + sample size.
- Evidence: percentile table, log excerpt, container stats.
- Severity: Critical / High / Medium / Low / Info — graded against demo-scale needs (a few agents, ≤10k memories per agent, ≤100 qps).
- One-sentence remediation.

Final summary table:

| Area | Score 1-10 | P50 / P95 / P99 | Notes |
|------|-----------|-----------------|-------|
| Auth cold path | | | |
| Auth warm path | | | |
| Rate-limit lockout | | | |
| Fast write | | | |
| Fine write (LLM-bound) | | | |
| Async write caller latency | | | |
| Search `no` mode | | | |
| Search `sim` mode | | | |
| Search `mmr` mode | | | |
| Search at 1k / 10k corpus | | | |
| Chunking cost | | | |
| Concurrent write throughput | | | |
| Concurrent search throughput | | | |
| Cross-cube interference | | | |
| CompositeCubeView latency | | | |
| Memory growth under load | | | |
| Cold-start time | | | |

**Overall performance score = MIN.** Close with a one-paragraph judgement: at the demo scale described in `CLAUDE.md` (research-agent + email-marketing-agent + CEO, ≤10k memories per agent), is this system fast enough? At 10× that scale?

### Out of bounds (re-asserted)

Do NOT read `/tmp/` beyond files you created this run, `CLAUDE.md`, prior audit reports, plan files, learning docs, or any commit message that telegraphs prior findings.

### Deliver

```bash
git fetch origin tests/v1.0-audit-reports-2026-04-26
git switch tests/v1.0-audit-reports-2026-04-26
git pull --rebase origin tests/v1.0-audit-reports-2026-04-26
# write tests/v1/reports/performance-v1-$(date +%Y-%m-%d).md
git add tests/v1/reports/performance-v1-*.md
git commit -m "report(tests/v1.0): performance audit"
git push origin tests/v1.0-audit-reports-2026-04-26
```

Do not open a PR. Do not modify any other file. Do not push to `main` or any other branch.
