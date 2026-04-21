# Hermes v2 Performance Blind Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

Local memory plugin `@memtensor/memos-local-hermes-plugin`. Per-profile SQLite at `~/.hermes/memos-state-<profile>/memos-local/memos.db`. Hub HTTP on `http://localhost:18992`. Plugin source `~/.hermes/memos-plugin-<profile>/`. Xenova embedder (local, 384d). DeepSeek summarizer (remote).

Your job: **Measure latency and throughput under realistic + adversarial load. Find the saturation point and the failure mode at saturation.** Score performance 1-10 with numbers.

Use markers `PERF-AUDIT-<timestamp>`. Create your own data. Measure with wall-clock (`time`, `curl -w`, or a small benchmark harness).

### Recon

- What's the advertised performance envelope? Read `package.json` and `README.md` for any perf claims.
- What does the capture pipeline look like end-to-end? Embedder (local, should be ms) → SQLite write (should be sub-ms) → optional summarizer (remote, 100ms-10s) → optional hub sync (localhost, should be ms).
- What's the current machine spec? `nproc`, `free -h`, `df -h` on the disk holding SQLite.

### Measurements

**Capture latency (single-turn):**
- Send 100 captures, one at a time, sequential. Record P50, P95, P99 of the server-side processing time and the client-side round-trip.
- Is there a cold-start penalty on the first request? (Xenova model load, SQLite warmup.)
- Break down the latency: embedder time vs DB write time vs summarizer time. Which dominates?

**Capture throughput (concurrent):**
- Fire N parallel captures for N ∈ {1, 5, 10, 25, 50, 100}. Measure aggregate throughput (captures/sec) and individual latency distribution at each N.
- Find the concurrency level where latency-per-request crosses 2× the N=1 baseline. That's the saturation point.
- At saturation, what's the bottleneck? Embedder (CPU)? SQLite (disk)? Node event loop? Use `top`, `iostat`, `strace` to narrow it down.

**Search latency — keyword (FTS5):**
- Preload the DB with 500 memories (varied content, include your marker).
- Run 50 keyword queries. P50/P95/P99.

**Search latency — vector:**
- Same 50 queries but semantic (paraphrased, no keyword overlap). P50/P95/P99.

**Search latency — hybrid fusion:**
- Same 50 queries with both active. P50/P95/P99. Is fusion additive (keyword_ms + vector_ms) or parallel (max)?

**Scaling — DB size:**
- At DB size 500: repeat the 50-query suite, record P95.
- At 2000: repeat.
- At 5000: repeat.
- At 10000: repeat if time permits.
- Plot latency vs DB size. Linear? Sublinear? Superlinear?

**Hub throughput (read):**
- Hammer `GET /api/v1/hub/info` or an equivalent read route with 100 parallel clients. Find the QPS ceiling.
- What's the latency P95 at 50% of ceiling? At 80% ceiling? At 99% ceiling?

**Hub throughput (write):**
- Same with captures through the hub.

**Memory footprint:**
- Record RSS of the hub process + plugin process at: idle, after 500 captures, after 5000 captures, after 10000.
- Record V-sz growth. Does it stabilize (bounded cache) or grow unboundedly (leak)?

**Skill-evolution pipeline:**
- Run skill-evolution on a corpus of 50 captured turns. Measure wall-clock time. How much is LLM-bound vs wrapper overhead?
- Repeat with 200 turns. Does the pipeline parallelize, or is it serial?

**Summarizer latency:**
- Trigger a task summarization. Wall-clock breakdown: input prep, LLM call, postprocessing, DB write.

**Large-turn ingestion:**
- Capture a single turn of 20k words. Chunking time, embedding time, DB write time — all measured separately. Does any one phase dominate?

**Embedding batch vs streaming:**
- Write 100 short captures back-to-back vs 1 long one with 100 chunks. Is there batch amortization?

### Reporting

Each measurement includes:

- What was measured
- Methodology (command used, iterations, warmup)
- Raw numbers (P50/P95/P99, throughput/sec, RSS in MB)
- Bottleneck identified (CPU / disk / net / LLM)
- Score 1-10 (relative to what a memory plugin should deliver)

Summary table:

| Metric | Number | Score 1-10 | Bottleneck |
|--------|--------|-----------|------------|
| Capture P50 (cold) | | | |
| Capture P50 (warm) | | | |
| Capture P95 (concurrent 10) | | | |
| Saturation concurrency | | | |
| Search keyword P95 (500 rows) | | | |
| Search vector P95 (500 rows) | | | |
| Search hybrid P95 (5000 rows) | | | |
| Scaling: P95 at 500 vs 5000 | | | |
| Hub read QPS ceiling | | | |
| Hub write QPS ceiling | | | |
| RSS growth 0 → 5000 captures | | | |
| Skill-evolution wall-clock (50 turns) | | | |

**Overall performance score = MIN of above.** Provide a one-paragraph production-sizing guidance: how many concurrent agents can this setup handle before user-perceived latency degrades?

### Out of bounds

Do not read `/tmp/`, `CLAUDE.md`, other audit reports, or plan files. Do not use existing benchmark scripts in the repo; write your own harness.
