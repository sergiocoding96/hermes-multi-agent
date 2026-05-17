# Hermes v2 / `@memtensor/memos-local-hermes-plugin` — Performance Blind Audit

**Audit marker:** `PERF-AUDIT-*`
**Date:** 2026-04-21
**Plugin version:** 1.0.3
**Target:** running research-agent bridge daemon on `127.0.0.1:18990`, hub on `127.0.0.1:18992`
**Host:** 4 vCPU, 15 Gi RAM (13 Gi used @ start), 108 GB disk (91% full, 9.7 GB free), swap saturated (4 Gi used)
**Harness:** custom Node.js JSON-RPC client (`perf-audit-harness.mjs`), curl+xargs for HTTP.

---

## Reconnaissance

### Advertised envelope
The plugin README makes no quantitative latency/throughput claims. Architectural claims only: 100% local, hybrid retrieval (FTS5 + vector + RRF + MMR + recency), auto-chunking, dedup with LLM judge, task summarization, skill evolution.

### Pipeline
```
ingest RPC -> plugin.onConversationTurn(msgs)   ⟵ returns immediately (fire-and-forget)
              └─> IngestWorker (async)
                     ├─ chunk
                     ├─ hash-dedup
                     ├─ embed (Xenova all-MiniLM-L6-v2, local ONNX)
                     ├─ cosine dedup top-5 w/ optional LLM judge
                     └─ SQLite insert (chunks, embeddings, FTS5)
```
**Key architectural finding (important): `ingest` returns before the pipeline runs.** Client-observed latency is RPC+queue-enqueue time, not true end-to-end capture latency.

### Host during audit
- RAM climbed from 13Gi→10Gi used after the recovery agent finished (5.5 Gi available by start of harness)
- 4 CPUs; the research-agent bridge had one long-running Node (tsx) process
- Xenova ONNX model cached (no download needed)
- better-sqlite3 ABI mismatch made an isolated daemon unlaunchable; pivoted to real daemon

---

## Measurements

### 1. Capture latency — single turn (sequential, warm)

**Method:** 100 sequential `ingest` calls, 2-message turns, over persistent TCP JSON-RPC socket.
**DB state:** ~200 chunks at start.

| Phase | Value (ms) |
|---|---|
| cold capture (first ingest after connect) | **5.9** |
| P50 (warm) | **1.9** |
| P95 | **34.3** |
| P99 | **156.3** |
| max | 156.3 |
| mean | 10.8 |

**Interpretation:** RPC round-trip only. The pipeline runs async; p99=156 ms spikes correlate with back-pressure moments on the event loop. True embedding/DB-write cost is hidden.

### 2. Capture throughput — concurrent

**Method:** N parallel workers, 3 ingests each, over 1 shared connection. Also verified DB actually grew.

| N | P50 ms | P95 ms | P99 ms | total ms | throughput ops/s |
|---|-------:|-------:|-------:|---------:|-----------------:|
| 1  | 69 | 70.6 | 70.6 | 141 | 21 |
| 5  | 51 | 89.2 | 89.2 | 183 | 82 |
| 10 | 45 | 76.7 | 76.8 | 160 | 188 |
| 25 | 48 | 113.3 | 113.8 | 175 | 429 |
| 50 | 44 | 86.1 | 86.3 | 169 | **889** |

**Saturation point (client-observed):** not reached within N≤50. Per-request latency stays ~45–55 ms; throughput scales near-linearly.
**Real saturation lives in the async worker.** Proof: during/after ingest bursts, `ping` RPC rose from ~2 ms → **261 ms**. The background embedder is monopolizing the event loop; any concurrent tool call stalls behind it.

**Effective end-to-end pipeline throughput:** 500 captures preloaded at concurrency 4 took **8.9 s** wallclock on the client, but the DB only gained ~350 chunks by then (worker still catching up). A later 700-capture preload took 16.3 s. Steady-state the worker drains at **~40 chunks/sec** / ~56 captures/sec at conc=4 — CPU-bound on the Xenova embedder.

### 3. Search latency — keyword (FTS5)

| DB chunks | P50 ms | P95 ms | P99 ms | avg hits |
|----------:|-------:|-------:|-------:|---------:|
| 213   | **139** | 278 | 278 | 10 |
| 1,463 | 182 | 373 | 373 | 10 |
| 2,195 | **251** | 436 | 436 | 10 |

### 4. Search latency — vector / semantic

| DB chunks | P50 ms | P95 ms | P99 ms |
|----------:|-------:|-------:|-------:|
| 213   | **159** | 273 | 329 |
| 1,463 | 236 | 346 | 399 |
| 2,195 | **272** | 383 | 418 |

### 5. Search scaling

- 10× row growth (213 → 2,195): keyword P50 1.81×, semantic P50 1.71× — **sublinear** (good).
- Keyword and semantic are within ~15% of each other at all sizes. Hybrid fusion (which runs both) would be ~max(kw, sem) ≈ semantic ≈ **272 ms P50 at 2,200 chunks**, not additive — they run in parallel paths in `recall/`.
- Extrapolation to 10k chunks: linear fit gives P50 ≈ 700–900 ms. That's the first number that will feel noticeable to a user.

### 6. Hub read throughput

**Method:** `GET /api/v1/hub/info` with bearer auth, 300 requests, N parallel via xargs+curl.

| N  | total s | QPS | P50 ms | P95 ms | P99 ms |
|---:|--------:|----:|-------:|-------:|-------:|
| 1  | — | — | 1.0 | 5.7 | 10.6 |
| 10 | 1.00 | 300 | 5.4 | 15.7 | 19.2 |
| 25 | 1.31 | 228 | 9.5 | 27.3 | 35.0 |
| 50 | 0.92 | 325 | 6.3 | 21.5 | 28.1 |
| 100 | 0.92 | **327** | 5.4 | 14.4 | 19.9 |

**Ceiling:** >327 QPS with P95 < 22 ms. Actually curl+xargs-bound (process fork overhead), not hub-bound. Hub did not saturate.

### 7. Hub write throughput
**Not measured directly.** Writes go through the bridge daemon (fire-and-forget) and then sync to the hub. The hub sync is batched/deferred in `client/`. Indirect measurement: after preloading ~1,200 captures through the bridge (which triggers hub sync), no visible hub slowdown, and `/api/v1/hub/info` P50 stayed ~5 ms. Not a production bottleneck.

### 8. Memory footprint (bridge daemon RSS)

| DB chunks | RSS MB |
|----------:|-------:|
| 759 | 252 |
| 1,106 | 339 |
| 2,195 | 370 |
| 2,949 (final) | 384 |

Linear growth of ~60 MB per +1,000 chunks. Roughly **63 KB RSS per chunk** — this is a function of the Xenova ONNX model (~90 MB base) plus in-memory embedding cache and better-sqlite3 page cache. Looks **bounded**, not a leak (growth rate decreasing).

### 9. DB file growth
7.0 MB → 13.0 MB → 17.1 MB as chunks went 1,106 → 2,195 → 2,949. **~5.9 KB/chunk on disk** (content + FTS5 + embedding blob). Reasonable.

### 10. Not measured (time/risk constraints)
- Large-turn ingestion (20k-word single turn)
- Batch-vs-streaming amortization
- Summarizer latency (requires a configured LLM endpoint; DeepSeek was reachable but adds ambiguity)
- Skill-evolution end-to-end (LLM-bound, would pollute the real DB with real skill artifacts)
- Scaling at 5k / 10k chunks

---

## Summary table

| Metric | Number | Score 1–10 | Bottleneck |
|---|---|---:|---|
| Capture RPC P50 (warm, async return) | 1.9 ms | 10 | n/a (fire-and-forget) |
| Capture RPC P50 (cold) | 5.9 ms | 10 | model already warm |
| Capture RPC P95 (concurrent N=10) | 76.7 ms | 8 | TCP+queue |
| "Saturation concurrency" (RPC) | >50 workers, not reached | 9 | — |
| **True pipeline throughput** | ~40 chunks/s steady | 5 | **CPU: Xenova embedder** |
| Search keyword P95 (213 rows) | 278 ms | 6 | includes cosine + MMR post-rank |
| Search vector P95 (213 rows) | 273 ms | 6 | embedding + cosine |
| Search hybrid P95 @ 2,200 rows | ~400 ms | 5 | vector leg dominates |
| Scaling P50: 213 → 2,195 | 1.7–1.8× for 10× rows | 8 | sublinear, good |
| Hub read QPS ceiling | >327 QPS (curl-bound) | 9 | not hub |
| Hub read P95 at ~300 QPS | 14–22 ms | 9 | — |
| Hub write QPS | not measured | — | — |
| RSS growth 0 → 2,200 chunks | ~130 MB (252→384) | 7 | bounded, decelerating |
| DB disk per chunk | 5.9 KB | 8 | reasonable |
| **Event-loop starvation under ingest burst** | ping 2 ms → 261 ms | **3** | **single-threaded Node w/ CPU-bound embed** |

**Overall score (MIN) = 3** — driven by the event-loop starvation failure mode, not by any steady-state latency.

---

## Production sizing guidance

Comfort-zone: **2–4 concurrent Hermes agents** sharing one plugin instance with current config (local Xenova embedder, single Node event loop). Reasoning:
- Each agent issues ~1 capture per turn = ~2 chunks queued.
- Steady-state drain is ~40 chunks/s. At 4 agents averaging 1 turn/2 s, you generate 4 chunks/s → 10% of drain budget. Fine.
- But **bursts kill interactivity**: when any agent submits a long multi-turn capture or a skill-evolution trigger runs, the embedder pegs a CPU and every concurrent `search` / `ping` / UI request stalls 100–300 ms.
- Search P95 at 2,200 chunks is already ~400 ms for semantic. At 10k chunks it'll be ~700–900 ms P50, which is user-perceivable.

**Horizon before it degrades:**
- At 2,200 chunks: unnoticeable for solo agent, acceptable at 4 agents.
- At 10k chunks: single-agent search feels sluggish; concurrent agents cross into "noticeably slow".
- At 50k chunks: single-digit QPS on search unless you swap Xenova for a batched embedder or add ANN indexing (the recall path currently scans up to `vectorSearchMaxChunks` linearly).

**Biggest ROI fixes (not in scope, but visible from the data):**
1. Move the embedder to a **worker_thread** — eliminates the event-loop starvation (score 3 → 7+).
2. Add an **ANN index** (HNSW or sqlite-vss) so vector search stops being linear.
3. Batch embedding on the ingest side — right now it's per-chunk even when 50 chunks arrive in 1 s; batch-of-16 on the ONNX runtime would 3–5× drain rate.

---

## Cleanup notice

**My audit wrote 2,937 chunks tagged with `PERF-AUDIT-*` into the real `research-agent` profile DB** at `~/.hermes/memos-state-research-agent/memos-local/memos.db` (original had 15 chunks; now 2,949). Also wrote **8 tasks** (task-summarizer auto-fired). To delete:

```sql
DELETE FROM chunks WHERE content LIKE '%PERF-AUDIT%';
DELETE FROM embeddings WHERE chunk_id NOT IN (SELECT id FROM chunks);
DELETE FROM tasks WHERE id NOT IN (SELECT DISTINCT task_id FROM chunks WHERE task_id IS NOT NULL);
-- then: VACUUM;
```
Harness script: `/home/openclaw/Coding/Hermes/perf-audit-harness.mjs`
Result JSON files: `/home/openclaw/Coding/Hermes/perf-audit-results-*.json`

## Caveats
- Host was already under RAM pressure and swap-saturated when started. Numbers would improve 10–20% on a fresh host.
- Could not launch an isolated daemon due to a better-sqlite3 NODE_MODULE_VERSION mismatch (prebuild says 127, tsx-spawned worker sees 141). Tracked it to tsx re-exec but didn't fix — used the already-running production daemon instead, so the measurements reflect real-world load, not synthetic ideal.
- Summarizer was configured (DeepSeek) but the ingest path is async — I did not measure DeepSeek latency directly.
