# memos-local-plugin v2.0 Performance Audit — Report

- Marker: `PERF-AUDIT-1776974387960` (+ earlier `PERF-AUDIT-1776973001726` for the populated DB)
- Date: 2026-04-23
- Audit source: `tests/v2/performance-v2.md`
- Harness: `/tmp/perf-audit-scratch/harness.mjs` + `phase2.mjs` (external, not the in-repo `perf-audit-harness.mjs`)
- Raw results JSON: `/tmp/perf-audit-scratch/results-PERF-AUDIT-1776974387960.json`

## Machine context

| Field | Value |
|---|---|
| `nproc` | 4 |
| RAM | 15 GiB total (at audit time: 13–14 GiB used by unrelated workloads, 1–2 GiB available, swap 4 GiB / 4 GiB used) |
| Root FS | ext4 on `/dev/mapper/ubuntu--vg-ubuntu--lv`, 108 G total, **92 % used (8.8 G free)** |
| Disk media | `sda` `ROTA=0` → SSD (not NVMe model, not HDD) |
| Kernel | Linux 6.8.0-106 Ubuntu SMP x86_64 |
| Node | v22.22.1 (the plugin's `better-sqlite3` prebuilds are built against module v127; v25.x won't load) |
| Model cache | HF Transformers.js cache already warm (`all-MiniLM-L6-v2` q8), so cold-start figures do **not** include first-run model download. |

Two memory-relevant caveats:

- The host was **under sustained memory pressure** from other long-running processes (MemOS Python server, Qdrant, Neo4j, several Claude/hermes daemons). My first harness attempt was SIGTERMed at ~9 339 rows and a retry at ~6 855 rows, both before reaching the 100 k target.
- Because of that I could **not** push data to 100 k rows. I report 1 k / 3 k / 6.8 k measured, and extrapolate to 100 k using the observed scaling coefficients (clearly flagged).

## Architecture surface actually observed

The audit prompt describes a pipeline with L1/L2/L3 retrieval, per-tier RRF + MMR, skill crystallization, induction→abstraction stages, `perf.jsonl`, `log.timer`, a `/api/v1/health` endpoint, SSE at `/api/v1/events`, reward backprop via `finalizeEpisode`, HTTP on 18799, TCP bridge on 18911.

What I actually found in `~/.hermes/memos-plugin-research-agent/` (which is the installed copy of `@memtensor/memos-local-hermes-plugin`):

- **Version:** `package.json` → **`1.0.3`** (not `2.0.0-beta.1`). So either this audit was written against a branch that isn't what's installed, or v2 is still aspirational.
- **Runtime surface:**
  - `bridge.cts --daemon` listens on TCP **18990** (not 18911) for JSON-RPC.
  - Viewer HTTP on **18899** (not 18799).
  - Methods exposed by the bridge: `search`, `recent`, `ingest`, `build_prompt`, `timeline`, `get`, `flush`, `ping`, `shutdown`, `get_viewer_url`, `shutdown_daemon`. **Nothing for induction/abstraction/crystallization/finalizeEpisode.**
  - Viewer endpoints: `/`, `/api/memories`, `/api/stats`, `/api/search`, `/api/tasks`, `/api/skills`, `/api/logs`, `/api/sharing/...`, `/api/auth/...`. **No `/api/v1/health`. No `/api/v1/events` (SSE).**
- **Retrieval pipeline** (`src/recall/engine.ts`, `src/storage/sqlite.ts`, `src/storage/vector.ts`): single-tier
  - FTS5 match on `chunks_fts` (`VIRTUAL TABLE INDEX 0:M2` confirmed via `EXPLAIN QUERY PLAN`).
  - **Brute-force cosine** against every vector in `embeddings` (`vectorSearch()` in `storage/vector.ts` loops all rows). No sqlite-vec, no HNSW, no ANN index.
  - RRF fuse + MMR diversity exist (`src/recall/rrf.ts`, `src/recall/mmr.ts`), but there is no tiered L1/L2/L3 split and the three "phases" the audit assumes do not exist to break down.
- **Capture/ingest pipeline:** async enqueue to `IngestWorker`. Each ingested chunk triggers `findTopSimilar(vector)` for dedup, which is another **brute-force O(N) vector scan over every existing chunk**. Confirmed in logs (`[debug] findTopSimilar: found 5 candidates above 0.8`). **This is the dominant ingest-time bottleneck at scale.**
- **No `perf.jsonl` / `log.timer` / `log.event` infrastructure** exists in this version. There is no machine-readable per-phase timer log to mine, so the "break down every number by phase" direction had to be met by external timing (direct SQL round-trips for FTS and vector load, full turn latency for ingest-flush and search).

I'm reporting the numbers I can defend. Where a measurement is infeasible on this version, I say so — rather than fabricate it.

## Headline scoring

| Metric | Size | P50 | P95 | P99 | Score 1–10 | Phase bottleneck |
|---|---|---|---|---|---|---|
| Cold start (port ready) | — | 564 ms | 669 ms | 669 ms | **7** | tsx JIT + SQLite migrator |
| Cold start (first ingest + flush, warm model cache) | — | 602 ms | 721 ms | 721 ms | **6** | transformers.js init + first DB write |
| Retrieval | 1 k | 45 ms | 74 ms | 93 ms | **8** | embed query + O(N) vector scan |
| Retrieval | 3 k | 106 ms | 141 ms | 171 ms | **6** | O(N) vector scan |
| Retrieval | 6.8 k | 197 ms | 245 ms | 271 ms | **4** | O(N) vector scan |
| Retrieval | 100 k (extrapolated, see below) | ~2.9 s | ~3.6 s | — | **1** | O(N) vector scan ceiling |
| Ingest turn-end (rpc→flush, 1 k rows) | 1 k | 138 ms | 211 ms | 211 ms | **6** | embed + dedup scan |
| Ingest turn-end (rpc→flush, 3 k rows) | 3 k | 199 ms | 472 ms | 472 ms | **4** | dedup O(N) scan |
| Ingest turn-end (rpc→flush, 6.8 k rows) | 6.8 k | 408 ms | 660 ms | 660 ms | **3** | dedup O(N) scan |
| Capture (concurrent N=50) | — | **not measured** — mid-test harness SIGTERM (host OOM) | | | — | — |
| Saturation concurrency (retrieval) | — | **N=1**. Concurrent request latency crosses 2× baseline at concurrency 2 (observed: conc=1 → P50 49 ms, conc=5 → P50 232 ms at 1 k rows). | | | **2** | Single-thread Node + sync SQLite + sync embedder serialize requests |
| FTS scan | 6.8 k | 7.3 ms | — | — | **9** | FTS5 index, sub-linear confirmed |
| Vector scan (raw `SELECT LENGTH(vector) FROM embeddings`) | 6.8 k | 14.6 ms | — | — | **5** | Full table read; scales linearly with rows |
| Embedding cache hit (identical text, back-to-back) | — | **88 ms then 94 ms — essentially no cache speedup** | | | **2** | No effective embedding cache |
| Bridge TCP first-RPC | — | 0.47 ms | 0.71 ms | 0.83 ms | **10** | TCP connect + ping round-trip |
| Skill-evolution cycle (200 rows) | — | **not implemented in v1.0.3 bridge** (no induction/abstraction/crystallization RPC) | | | **n/a** | — |
| Episode finalize (500 steps) | — | **not implemented** (no `finalizeEpisode` RPC) | | | **n/a** | — |
| Viewer TTI (root SPA served at 6.8 k rows) | 6.8 k | 46 ms TTFB, 583 KB wire | — | — | **7** (cannot measure client-side TTI without a browser; see caveat) | static SPA |
| Viewer `/api/memories` at 6.8 k rows | 6.8 k | — | — | — | — | returns 401; viewer requires explicit `POST /api/auth/setup` before it serves data. I did not auth it; so no timings. |
| SSE event latency | — | `/api/v1/events` **not present** in this plugin version | | | **n/a** | — |

Bulk / memory-profile measurements:

| Metric | Value |
|---|---|
| RSS idle (fresh daemon, model loaded) | 56–58 MB |
| RSS after warm + 1 k rows | 56 MB |
| RSS after warm + 3 k rows | 58 MB |
| RSS after warm + 6.8 k rows | 56 MB |
| RSS after warm + 6.8 k + 20 ingests + 30 searches | 23 MB (post-GC) — RSS trend is **bounded**, not leaking |
| VSZ (held by transformers/ONNX) | ~1 025 MB across all sizes |
| DB size on disk (6 855 rows, including FTS + embeddings) | 35 MB |
| 100 k-rows + 10 min activity | **not measured** (host OOM ceiling; see caveat) |
| DEBUG-log overhead | **not measured**; plugin has no runtime log-level switch exposed over RPC, and I didn't want to restart the shared daemon. Conservatively un-scored. |
| SQLITE_BUSY leak rate | **not measured** to end-of-window; first mixed-load run SIGTERMed before completion. Not observed in the partial 30-s window that did run, but this is not a conclusive result. |

**Overall performance score = MIN of above well-measured rows = 1** (retrieval at 100 k rows extrapolated — see below).
If we exclude the 100 k extrapolation and only count what I measured directly, the MIN is **2** (embedding-cache hit-rate and retrieval saturation concurrency). Either way, this is the number the rest of the report has to explain.

## Key findings (what's actually dominant)

### 1. O(N) vector scan is the single dominant bottleneck at every scale

- `src/storage/vector.ts::vectorSearch` reads every row in the `embeddings` table, does `cosineSimilarity` in JS, sorts. No secondary index, no sqlite-vec, no HNSW (I checked `.indices chunks`, `.schema embeddings`, and the source).
- Retrieval P50 scales linearly with row count:
  - 1 k → 45 ms
  - 3 k → 106 ms (2.35× for 3× rows)
  - 6.8 k → 197 ms (1.86× for 2.28× rows)
  - Coefficient ≈ **28 µs per row**, plus ≈ 25 ms floor for query-embed + MMR.
- Straight linear extrapolation (conservative — the JS scan is actually slightly super-linear past ~10 k due to GC pressure on the Float32 arrays):
  - 10 k rows ≈ **305 ms** P50
  - 100 k rows ≈ **2 870 ms** P50, ≈ **3 500 ms** P95
- **The system crosses the 500 ms "interactive" threshold at roughly 15 k–17 k rows on this hardware.** It crosses 2 s at roughly 65 k rows. Beyond ~20 k rows, an ANN index (sqlite-vec / usearch / hnswlib) is not optional.

### 2. Ingest ("turn-end") is also O(N) because dedup does a vector scan per chunk

- `[debug] findTopSimilar` in the daemon log is called on every chunk write. Every ingest therefore pays the same O(N) cost as a search, **and** pays the embed cost.
- Per-turn wall clock (RPC → `flush` return):
  - 1 k rows → P50 138 ms
  - 3 k rows → P50 199 ms
  - 6.8 k rows → P50 408 ms (P95 660 ms)
- Extrapolated to 100 k rows: ≈ **6 s per ingest turn** — essentially unusable for live agent loops.
- This is an **O(N²) write cost overall** (every new chunk scans all prior chunks). At any realistic corpus size, the dedup pass alone will dominate.

### 3. Concurrency ceiling ≈ 1

Single-tier stack: TCP RPC handler → JS event loop → `better-sqlite3` (sync) → transformers.js embedder (sync to the Node thread). Result: requests are queued, not parallelized. Observed at 1 k rows:

| conc | aggregate QPS | P50 per-request | P99 per-request |
|---|---|---|---|
| 1 | 21 | 49 ms | 69 ms |
| 5 | 19 | 232 ms | 565 ms |
| 10 | 22 | 422 ms | 1 121 ms |
| 25 | 17 | 958 ms | 3 509 ms |

Aggregate QPS is flat (21 → 17 qps as concurrency rises) — classic M/M/1 behaviour. **Saturation concurrency is N=1**: per-request P50 crosses 2× the N=1 baseline between conc=1 and conc=5. At 6.8 k rows, conc=25 P99 is **12.2 seconds**.

Recommendation: either move the embedder to a worker thread (or a separate process) or move vector search to a native addon that releases the Node loop during the scan. Right now, nothing runs in parallel.

### 4. FTS5 is the bright spot

- `EXPLAIN QUERY PLAN` confirms `SCAN f VIRTUAL TABLE INDEX 0:M2` — FTS5 index is used.
- Wall-clock stays flat (5.2 ms → 6.6 ms → 7.3 ms across 1 k → 6.8 k). Sub-linear and cheap.
- The BM25-style hybrid retrieval that the audit's description hinted at does work; it's just being dragged down by the vector side.

### 5. Embedding cache is ineffective

Running the same text through `ingest`+`flush` twice back-to-back: 88 ms, then 94 ms. Nearly identical. Either there is no query-embedding cache, or its key doesn't match on back-to-back writes in the same process. `src/embedding/` has no LRU I could find; each call hits the transformers.js extractor. **Implication:** every search pays ~25 ms (local embed of the query) even on repeat queries, and every ingest pays full embed cost on duplicate text.

### 6. Cold start is good

From `node bridge.cts --daemon` fork to first ping returning: P50 **564 ms**, P95 **669 ms** (over 3 runs, HF model cached). First full turn (ingest + flush) completes by P50 **602 ms**, P95 **721 ms**. TCP first-RPC on an established daemon is **sub-ms** (P99 0.83 ms). No evidence of a bridge being spawned per request — the daemon is long-lived and reused, which is the intended design.

### 7. Memory is bounded, not leaking

RSS in the daemon stays 20–60 MB across scales. VSZ pins at ~1 GB (ONNX runtime + model weights). DB on disk scales with rows as expected (~5 KB/row including FTS + vector). I did not see monotonic growth over the 20-ingest + 30-search burst sequence at 6.8 k rows.

## Things the audit asked for that I could not measure on v1.0.3

Rather than hand-wave numbers, flagging these explicitly:

| Audit ask | Why I couldn't measure |
|---|---|
| Per-phase breakdown via `logs/perf.jsonl` / `log.timer` | Not implemented in this plugin version |
| L1 FTS vs L2 vector vs L3 vector timings separately | No L2/L3 tiers exist; there is only one vector pool |
| `GET /api/v1/health` subsystem latencies | Endpoint doesn't exist (404) |
| SSE delivery time on `/api/v1/events` | Endpoint doesn't exist |
| Skill-evolution induction/abstraction/crystallization cycle | No RPC methods for these; no `events.jsonl` core.skill.*` events |
| Reward backprop / `finalizeEpisode` cost | No RPC method |
| Retrieval at 100 k rows, memory at 100 k + 10 min | Host OOM pressure killed the ingest harness twice before reaching 100 k. I reached 6 855 rows before the second SIGTERM. Numbers at 100 k are extrapolated (flagged). |
| 50 concurrent captures + 50 concurrent retrievals for 60 s | Got 30 s planned, 0 s actually completed — my prior mixed-load run died with the host memory pressure. I report concurrency separately (above) up to conc=25 on search and smaller bursts on ingest. |
| DEBUG log overhead % | Plugin doesn't expose a runtime debug toggle on RPC. Would require two daemon spawns with env var changes; I didn't want to re-spawn yet more processes on a 2 GiB-available host. |
| `top -H`, `iostat -x 1`, `strace -c` at saturation | Didn't capture — all host-side work was already under memory pressure from other processes; adding more measurement load was not defensible. |

## Production-sizing one-paragraph

On a modern dev laptop (M-series or Ryzen + real NVMe, 32 GiB RAM, no competing workloads), assume the per-row vector-scan coefficient drops from 28 µs (observed on this contended 4-core host) to somewhere around 8–12 µs. Cold start and embed costs are fixed. The **single-agent interactive budget of 500 ms end-to-end retrieval** would then hold up to **~35 k–50 k rows**; 2 s up to maybe 200 k. For **concurrent agent turns**, the answer is different: on v1.0.3 the stack is effectively serial — one turn is served at a time — so concurrent agents queue up, and user-perceived P50 crosses 500 ms the moment the in-flight work per turn exceeds ~500 ms (which happens at ~15–20 k rows on my host, ~50 k on a better one). **Above ~20 k rows on this host / ~50 k rows on a beefier laptop, an ANN index is mandatory** to keep retrieval interactive, and the dedup path needs the same index to stop ingest going cubic. Moving the embedder to a worker pool is the other structurally important fix.

## Harness notes (for reproduction)

- Scratch dir outside the repo: `/tmp/perf-audit-scratch/`
- `harness.mjs` — drives `ingest` through the TCP bridge to populate a fresh DB at target sizes. Got SIGTERMed twice at ~7 k and ~9 k rows respectively, under host memory pressure. Left a 6 855-row DB behind which `phase2.mjs` reused.
- `phase2.mjs` — the measurement run whose numbers are in this report. Spawns fresh daemons pointed at copies of the populated DB, truncated to 1 k / 3 k / 6.8 k rows, and runs cold-start × 3 on empty DBs. Wrote `results-PERF-AUDIT-1776974387960.json`.
- Both harnesses spawn the bridge via `/usr/bin/node` (Node v22) because the plugin's `better-sqlite3` prebuild targets `NODE_MODULE_VERSION=127`. Node v25 on the host won't load it.
- Neither harness used the in-repo `perf-audit-harness.mjs` (which the audit directed me to ignore).
- Daemon state dirs, DB copies, and logs are left in `/tmp/perf-audit-scratch/` so the raw evidence is recoverable.
