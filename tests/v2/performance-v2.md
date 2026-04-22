# memos-local-plugin v2.0 Performance Audit

Paste this into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

You are measuring latency + scaling of `@memtensor/memos-local-plugin` v2.0.0-beta.1. Plugin source: `~/.hermes/plugins/memos-local-plugin/`. Runtime: `~/.hermes/memos-plugin/`. HTTP on `127.0.0.1:18799` (walks `+1..+10`). Bridge TCP (if enabled) on `18911`. Default embedder is local sentence-transformers (all-MiniLM-L6-v2, 384 dim). Default LLM provider: configurable — check `config.yaml`.

**Your job:** measure real latency and throughput across the full turn pipeline, find the saturation point, identify the dominant bottleneck at each scale (cold start, 1k rows, 10k rows, 100k rows), and score 1-10 with numbers.

Use marker `PERF-AUDIT-<timestamp>`. Measure on a throwaway profile. Record machine context: `nproc`, `free -h`, `df -h /`, `uname -a`, node version, is /home on NVMe/SATA/HDD.

### Pipeline under test (read first)

- Turn RPC arrives (`agent-contract/jsonrpc.ts` method → `core/pipeline/`). Turn-start: three-tier retrieval (L1 FTS + L2/L3 vector + Skill) → per-channel RRF fusion → MMR diversity → return context. Turn-end: capture → step-extract → α-score → embed → write L1 rows. Background: induction L1→L2, abstraction L2→L3, skill crystallization, backprop on episode close.
- Log timers you can harvest: `logs/perf.jsonl` entries emitted by `log.timer()` close in `core/logger/`.
- `GET /api/v1/health` shape — can surface per-subsystem latencies?

### Ground rules

- Two runs per measurement: COLD (fresh boot, no cache) + WARM (3 priming iterations discarded).
- Report P50 / P95 / P99 + count.
- Break down every number by phase via `perf.jsonl` timers; don't just report end-to-end.
- Do NOT read or use the existing `perf-audit-harness.mjs` — write your own harness in a scratch dir outside the repo.

### Measurements

**Cold start to ready:**
- Time from process start to `GET /api/v1/health` returning 200 + all subsystems healthy. Repeat 5×. P50 / P95.
- Breakdown: migrator time, LLM/embedder handshake, viewer static asset load, first SSE subscriber attach. From `logs/self-check.log` + `perf.jsonl`.

**Turn-start retrieval at scale:**
- Seed the DB to 1 000 / 10 000 / 100 000 L1 rows with varied content (use a generator with marker tagging).
- At each size, run 50 retrieval queries. Record per-phase from `perf.jsonl`: L1 FTS scan, L2 vector scan, L3 vector scan, skill match, RRF fuse, MMR pick, final assembly. End-to-end P50 / P95 / P99.
- Is the vector scan linear (full scan of `embeddings` blob column)? Sub-linear (ANN index)? Which? Confirm by plotting latency vs row count.
- Does retrieval parallelize the three tiers, or run serially?

**Turn-end fan-out:**
- Send 100 captures sequentially. Measure server-side processing via `perf.jsonl` (`core.capture.*` timers). Break down into: step extraction, α-scoring LLM call, embed batch, DB write, L1 insert, event emit.
- Concurrent fan-out: 1, 5, 10, 25, 50, 100 parallel captures. Aggregate throughput + individual P95. Saturation concurrency = where per-request latency crosses 2× the N=1 baseline.
- At saturation, bottleneck? `top -H` for hot threads, `iostat -x 1` for disk, `ss -s` for socket state, `strace -c -p <pid>` for syscall distribution.

**Capture batched vs per-step:**
- One turn with 10 tool_call+tool_result steps captured in batch mode vs one step per RPC. Amortized per-step time in each mode. Is the α-scoring LLM call issued once per batch or once per step?

**Embedding cache hit/miss:**
- Write 100 distinct turns, then re-embed 100 identical ones. Hit rate in `core/embedding/` cache? Per-call latency before/after warm cache?
- Cache key must include provider+model+dim — flip embedder provider and confirm cache misses (not cross-contamination).

**Vector scan cost:**
- 1 000 / 10 000 / 100 000 rows: time one cosine similarity pass via direct SQL vs through the retrieval API. Overhead from the API layer?
- If sqlite-vec / HNSW exists, confirm it's actually used at the largest scale. Otherwise you're getting O(N) per query.

**L1 FTS scan:**
- Same three scales. FTS5 index should be sub-linear. Confirm by query plan (`EXPLAIN QUERY PLAN`).

**Concurrent load:**
- 50 concurrent retrievals + 50 concurrent captures for 60 seconds. QPS ceiling on each? Error rate? Any `SQLITE_BUSY` leaking to clients as a user-visible error?

**Memory footprint:**
- RSS + VSZ at: idle, 1k rows, 10k rows, 100k rows, 100k rows + 10 minutes of activity. Plot growth. Bounded (cache evicts) or monotonic (leak)?
- Heap snapshots via `--inspect` if Node is easy to attach.

**Log overhead:**
- Disable DEBUG; measure turn-start retrieval P95. Enable DEBUG on `core.retrieval.*`; re-measure. Δ = log write overhead. Is DEBUG safe to leave on in prod?
- Measure `perf.jsonl` write rate at steady state. Any back-pressure on the logger thread?

**Bridge spawn cost:**
- Spawn a fresh bridge via stdio (simulating an agent process attaching). Time to first successful RPC round-trip. If the plugin spawns a bridge per request (should NOT), document it — that's a bug.
- Same for TCP bridge (port 18911) if enabled: connect → first RPC round-trip.

**Skill-evolution cycle wall-clock:**
- Seed 50 L1 rows in one task family. Trigger induction → abstraction → crystallization via RPC. Measure wall-clock per stage from `events.jsonl` (`core.skill.*` events).
- Repeat with 200 L1 rows. Does the pipeline parallelize within a stage, or serial?

**Reward backprop cost:**
- Close an episode with 5 / 50 / 500 L1 steps. Measure `finalizeEpisode` wall-clock. Linear in steps? Dominated by LLM rubric call or by DB writes?

**Viewer bundle perf:**
- Load `/` (Vite SPA). Time to interactive from `performance.timing` in browser dev-tools. Bundle size over the wire. JS parse + first render under 500ms on localhost?
- Open the Memories view with 10k rows in the DB. Pagination works? Client-side freeze?

**SSE delivery:**
- Subscribe to `/api/v1/events`. Measure event delivery latency: time from `log.event()` call (server log) to event arrival on client. P50 / P95. Under back-pressure?

### Reporting

Every row gets a number + a phase attribution (`phase: embed | db | llm | fts | vector | mmr | rrf | serialize | …`).

| Metric | Size | P50 | P95 | P99 | Score 1-10 | Phase bottleneck |
|--------|------|-----|-----|-----|-----------|------------------|
| Cold start → ready | — | | | | | |
| Retrieval (1k rows) | 1k | | | | | |
| Retrieval (10k rows) | 10k | | | | | |
| Retrieval (100k rows) | 100k | | | | | |
| Capture (N=1 warm) | — | | | | | |
| Capture (N=50 concurrent) | — | | | | | |
| Saturation concurrency | — | | | | | |
| FTS scan (100k) | 100k | | | | | |
| Vector scan (100k) | 100k | | | | | |
| Embedding cache hit | — | | | | | |
| Bridge first-RPC | — | | | | | |
| Skill-evolution (200 rows) | — | | | | | |
| Episode finalize (500 steps) | — | | | | | |
| Viewer TTI (10k rows) | — | | | | | |
| SSE event latency | — | | | | | |

Also:

| Metric | Value |
|----|---|
| RSS idle / 10k / 100k / 100k+10min | |
| Log-DEBUG overhead % | |
| SQLITE_BUSY leak rate under load | |

**Overall performance score = MIN of above.**

One-paragraph production sizing: on a modern dev laptop (M-series or Ryzen + NVMe), how many concurrent agent turns can this setup serve before user-perceived latency crosses 500 ms? 2 s? Above what DB size does retrieval latency require an ANN index to stay interactive?

### Out of bounds

Do not read `/tmp/`, `CLAUDE.md`, `tests/v2/reports/`, `memos-setup/learnings/`, prior audit reports, or plan/TASK.md files. Do NOT use the existing `perf-audit-harness.mjs` or any other benchmark script in the repo — write your own harness in a scratch dir outside the repo and clean up when done.


### Deliver — end-to-end (do this at the end of the audit)

Reports land on the shared branch `tests/v2.0-audit-reports-2026-04-22` (at https://github.com/sergiocoding96/hermes-multi-agent/tree/tests/v2.0-audit-reports-2026-04-22). Every audit session pushes to it directly — that's how the 10 concurrent runs converge.

1. From `/home/openclaw/Coding/Hermes`, ensure you are on the shared branch:
   ```bash
   git fetch origin tests/v2.0-audit-reports-2026-04-22
   git switch tests/v2.0-audit-reports-2026-04-22
   git pull --rebase origin tests/v2.0-audit-reports-2026-04-22
   ```
2. Write your report to `tests/v2/reports/performance-v2-$(date +%Y-%m-%d).md`. Create the directory if it does not exist. The filename MUST use the audit name (matching this file's basename) so aggregation scripts can find it.
3. Commit and push:
   ```bash
   git add tests/v2/reports/<your-report>.md
   git commit -m "report(tests/v2.0): performance audit"
   git push origin tests/v2.0-audit-reports-2026-04-22
   ```
   If the push fails because another audit pushed first, `git pull --rebase` and push again. Do NOT force-push.
4. Do NOT open a PR. Do NOT merge to main. The branch is a staging area for aggregation.
5. Do NOT read other audit reports on the branch (under `tests/v2/reports/`). Your conclusions must be independent.
6. After pushing, close the session. Do not run a second audit in the same session.
