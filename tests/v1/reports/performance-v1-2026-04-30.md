# V1 Performance Audit — 2026-04-30

**Marker:** `V1-PERF-1777576195`
**Audit user:** `audit-v1-perf-1777576195`  /  **Cube:** `V1-PERF-1777576195`
**Server:** MemOS v1.0.1 at `http://localhost:8001`, single uvicorn process (PID 2667993)

## Headline

**Overall performance score: 2 / 10 (= MIN of area scores).**

The system meets demo-scale latency targets on the warm-cache happy path (cached auth ≈ 6 ms p50, fast-mode write ≈ 84 ms p50, search on a 200-row corpus ≈ 123 ms p50). It is **fundamentally throughput-capped** by a server-wide IP rate-limit middleware whose default ceiling — **100 requests / 60 s per IP** — is reached during ordinary CEO + research + email-marketing co-tenant traffic, during the very first bulk seed of an agent's memory cube (every burst > 100 calls/min returns 429), and during any concurrent worker fan-out. Until that ceiling is raised, the system cannot run a single agent at the throughput the prompt names (≤ 100 qps) — it tops out at **1.34 writes/s globally** in steady state, ~75× short.

A second cliff sits at the BCrypt cache: a fresh key takes ~262 ms to verify, the verify-cache holds 64 entries with FIFO eviction — fine today (3 agents) but stops scaling at the 65th distinct API key.

## Throwaway provisioning (for reproducibility)

```bash
export MEMOS_HOME=/tmp/memos-v1-audit-207796d3-...
TS=1777576195
# audit user/cube/key created via direct UserManager API call (the
# setup-memos-agents.py the doc references is .archived in this repo —
# see Appendix A for the inline equivalent).
python3.12 -c "from memos.mem_user.user_manager import UserManager, UserRole
um = UserManager()
um.create_user('audit-v1-perf-$TS', UserRole.USER, user_id='audit-v1-perf-$TS')
um.create_cube('V1-PERF-$TS', 'audit-v1-perf-$TS', cube_id='V1-PERF-$TS')"
# raw key 'ak_dd2676873e54976198ddbf6479079cb2' written to agents-auth.json
# with bcrypt rounds=12; mtime change triggers AgentAuthMiddleware reload.
```

Teardown:
```bash
sqlite3 ~/.memos/data/memos.db <<SQL
DELETE FROM users WHERE user_id LIKE 'audit-v1-perf-1777576195%';
DELETE FROM cubes WHERE cube_id LIKE 'V1-PERF-1777576195%';
SQL
# remove ephemeral entries from /home/openclaw/Coding/Hermes/agents-auth.json
```

## Recon

**Host:** Intel Core i5-3570 @ 3.4 GHz, 4 cores, 15.5 GiB RAM (12 GiB used + 4 GiB swap **fully consumed** at audit start), 95 % full root disk (6 GiB free). The host is already paging heavily before any probe runs — that taxes p99 tails everywhere.

**Containers (baseline, idle):**
- `qdrant`: 0.1 % CPU, 46 MiB RAM
- `neo4j-docker`: 0.6 % CPU, 1.13 GiB RAM
- MemOS server (`memos.api.server_api`, port 8001): RSS 718 MiB pre-load → 980 MiB after the full probe matrix below

**Code surfaces:**
- `src/memos/api/middleware/agent_auth.py` (425 LOC): BCrypt registry with `key_prefix → record` bucket index (`KEY_PREFIX_LEN = 12`), 64-entry verify-cache (sha256(raw)→user_id, FIFO/LRU), per-IP failure tracker (`RATE_LIMIT_MAX_FAILURES = 10`, `RATE_LIMIT_WINDOW_SECONDS = 60`), enforces `MIN_BCRYPT_COST = 10` at load time. Auto-reloads on config-file mtime change.
- `src/memos/api/middleware/rate_limit.py` (317 LOC): Sliding-window rate limiter, **`RATE_LIMIT = 100` reqs / `RATE_WINDOW_SEC = 60` window** by default. Redis preferred via `MEMOS_REDIS_URL`; falls back to file-backed SQLite (`/var/tmp/memos-ratelimit.db`) — this run used the SQLite fallback (no `MEMOS_REDIS_URL` set). `_get_client_key` keys on `Authorization` header prefix `krlk_*` (admin-only) or otherwise on client IP / `X-Forwarded-For`. **All `/product/*` agent keys (`ak_*`) share one IP bucket.**
- `src/memos/multi_mem_cube/single_cube.py` (847 LOC): `add_memories` → `_process_text_mem` → `mem_reader.get_memory()`. `extract_mode = "fast"` skips LLM and uses naive sentence/token chunking; `extract_mode = "fine"` invokes `mem_reader.general_llm` (DeepSeek V3 per `.env`). Async path always uses fast extraction.
- `src/memos/chunkers/`: default `chunk_size = 512` tokens (sentence chunker, character chunker); MemOS API config forces 512 in three places. `MEM_READER_CHAT_CHUNK_TOKEN_SIZE = 4000` in MemOS `.env` overrides the reader-side chat-history chunker.
- Storage backends behind `naive_mem_cube`: `Neo4jGraphDB` for tree-text-memory (graph + embeddings), `QdrantVecDB` only for `prefer_text_memory`. **For the audit user (no preference memory), Qdrant is essentially unused** — confirmed below (peak 0.05 % CPU / 52 MiB during the full burst).

## Probe matrix — measured

### Auth latency

| Path | n | p50 ms | p95 ms | p99 ms | mean | stdev |
|------|---|-------:|-------:|-------:|-----:|------:|
| Cold (BCrypt verify, fresh key, 1st call) | 8 | 262 | 350 | 369 | 280 | 39 |
| Warm (verify-cache hit, 2nd call same key) | 8 | 5.8 | 10.0 | 10.9 | 6.7 | 1.9 |
| 1000-call sustained warm-loop (mixed cache + RL) | 93 | 59 | 214 | 249 | 87 | 61 |

**Cold = BCrypt cost.** With `rounds = 12` (the gensalt default the provisioning script writes) bcrypt verify runs ~250 ms on this CPU. That number lines up exactly with `_authenticate_key`'s prefix-bucket lookup — the bucket has 1 candidate, so we pay exactly one BCrypt verify, no walk. The minimum across 8 keys was 254 ms, max 374 ms — a tight CPU-bound distribution.

**Cache hit cost ≈ 6 ms.** That's roughly the cost of the entire `/product/search` round-trip when the corpus is empty and the verify-cache lookup is just sha256 + dict get. This is the floor for any well-warmed agent.

**1000-loop sustained warm path returned 93 / 1000 success.** The 907 missing samples were all 429s from the `RateLimitMiddleware` (100 req / 60 s). The 93 surviving p50 of 59 ms confirms the verify cache works under load; the p99 of 249 ms is dominated by sporadic GIL/swap pressure on this host.

### Auth rate-limit (agent_auth path, 10 / 60 s on wrong-key floor)

Confirmed exactly as designed in `agent_auth.py:114-115`:

| Attempt # | Status | Body |
|-----------|--------|------|
| 1–10 | 401 | `Invalid or unknown agent key.` (~1.8 ms — bucket miss, no BCrypt cost) |
| 11–15 | 429 | `Too many failed authentication attempts. Try again later.` |

**Granularity = per IP**, computed from `request.client.host` (no `X-Forwarded-For` consideration in this middleware — the *separate* RL middleware honours the header, but `agent_auth` does not). No `Retry-After` / `X-RateLimit-*` headers on this 429.

**Lockout window observable:** the lockout is *implicit*; once 10 failures sit in the sliding window, every subsequent failed attempt also gets 429 (and is also recorded — so 11+ failures stretch the lockout). **One successful auth on the same IP wipes the counter** (`_clear_failures`). My "valid call after 11 wrongs" sample landed at status 200 in 370 ms (cold BCrypt), and recovery 65 s later at 378 ms. **A successful auth bypasses the rate-limit branch entirely** even if `_is_rate_limited` is true — `dispatch` only returns 429 in the wrong-key/bad-format path.

### Server-wide IP rate-limit (RateLimitMiddleware, 100 / 60 s)

This is the dominant production cliff. Every probe that exceeded 100 calls in a 60-second window hit the wall:

- 1 000-call sequential warm-loop: 93 succeeded, 907 returned 429 (`Too many requests. Please slow down.`, `retry_after: 4`).
- Bulk write of 800 entries (initial run, no pacing): **0 / 800 succeeded** in 1.9 s — every call hit 429 because the previous probe had already exhausted the window.
- 5×50 concurrent writers (initial run, no pacing): 1 / 250 succeeded.
- 10×20 concurrent searchers: 0 / 200 succeeded.
- 50×4 concurrent searchers: 0 / 200 succeeded.

The "valid samples" reported below for fast/fine/async writes and for searches all come from a *paced* re-run that issues at ≤ 92 req/min to stay just under the cap.

### Single-write latency by mode (paced)

| Mode | n | p50 ms | p95 ms | p99 ms | mean | stdev | errors |
|------|---|-------:|-------:|-------:|-----:|------:|-------:|
| Fast / sync, paced @ 0.65 s | 100 | 84 | 127 | 139 | 87 | 19 | 0 |
| Async (fire-and-forget enqueue), paced | 50 | 114 | 231 | 267 | 126 | 57 | 0 |
| Fine / sync (LLM extraction, DeepSeek V3) | 20 | 2 382 | 2 769 | 3 522 | 2 463 | 323 | 0 |

**Where the time goes in fast/sync.** No LLM call. Pipeline = bcrypt cache hit (~5 ms) + `mem_reader.get_memory` (sentence chunking + local sentence-transformers embedding) + Neo4j writes (graph node + embedding vector) + cube validation + dedup-search via `graph_store.search_by_embedding`. During the burst, neo4j-docker hit **88 % of one core**; qdrant stayed at 0.04 % (preference memory is not provisioned for this user). MemOS process RSS grew from 718 MiB to ≈ 980 MiB across the whole probe matrix.

**Async caller-side latency is *not* near zero.** The doc claim was "caller-side latency should be near zero." Measured p50 = 114 ms — comparable to fast/sync. The async path still walks bcrypt cache, request validation, cube-permission check, and enqueues onto the in-process scheduler before the response returns. Background extraction completion was not separately timed (no `/scheduler/wait/stream` event subscription was set up); but the `/product/scheduler/status` endpoint is available for that.

**Fine/sync is LLM-bound.** Mean ≈ 2.5 s for a 200-character message. The LLM (`MEMRADER` = DeepSeek V3 via OpenAI-compatible API) dominates; chunking and storage cost are noise next to it.

### Single-search latency by mode + corpus size (paced, all dedup modes; mode = `fast`)

| Corpus | dedup | n | p50 ms | p95 ms | p99 ms | mean |
|--------|-------|---|-------:|-------:|-------:|-----:|
| ~200   | `no`  | 30 | 123 | 361 | 366 | 165 |
| ~200   | `sim` | 30 | 161 | 549 | 627 | 239 |
| ~200   | `mmr` | 30 | 137 | 342 | 588 | 180 |
| ~500   | `no`  | 30 | 280 | 454 | 474 | 261 |
| ~500   | `sim` | 30 | 301 | 455 | 469 | 285 |
| ~500   | `mmr` | 30 | 118 | 313 | 361 | 165 |

(I padded the corpus to ~500 instead of the doc's 1 000 — the bulk pad takes ~4 min at the rate-limit cap; 1 000 would have been ~9 min and 10 000 is not feasible on this host's remaining 1.6 GiB RAM and 6 GiB disk.)

**Scaling shape.** From 200 → 500 corpus the `no` and `sim` paths **roughly double** (123→280 ms p50 = 2.3×; 161→301 ms = 1.9×) for a ~2.5× corpus. That's *super-linear* — the per-write dedup search and the in-Neo4j embedding scan grow worse than O(N). The `mmr` path is essentially flat across this range (137→118 p50, within noise) because its overhead is dominated by the post-process MMR re-rank loop, not by candidate retrieval. **The cliff for `no`/`sim` will sit somewhere between 1 k and 10 k memories; 10 k is out of reach for this run.**

### Chunking cost (paced, fine mode, single-shot per size)

| Input chars | Status | Latency ms |
|------------:|--------|-----------:|
|         100 | 200 |  3 869 |
|       1 000 | 200 |  2 950 |
|       5 000 | 200 |  3 161 |
|      20 000 | 200 |  3 702 |

**Latency is essentially flat** between 100 and 20 000 chars — the LLM call dominates so completely that input size doesn't move the needle in this range. The 100-char latency is *higher* than the 1 000-char latency, suggesting per-call LLM warm-up variance dominates the chunking cost itself. The chunker default `chunk_size = 512` tokens means a 20 000-char message split into ~10 chunks is still completed inside one DeepSeek roundtrip due to MemOS's batching. The chunking threshold the prompt asked about is not a hard cliff — it's effectively "first chunk" and 512-token batches thereafter, which only matter at the >> 20 000-char range I didn't probe.

### Concurrent throughput (writes), paced 5 × 18 = 90 calls (sub-cap)

| metric | value |
|--------|-------|
| n succeeded | 90 / 90 |
| p50 / p95 / p99 ms | 307 / 401 / 448 |
| mean ± stdev ms | 315 ± 47 |
| burst duration | 5.72 s |
| **throughput (writes/s)** | **15.74** |

When the burst stays *just under* the 100/60 cap, the underlying pipeline sustains ~16 writes/s with no errors and a healthy p99 of 448 ms. **That's the realistic write throughput ceiling for this server with the current rate-limit at default**: ~16 writes/s for ~6 s, then forced quiet for 60 s for the window to slide. Steady-state effective throughput across longer windows is the rate-limit cap (1.67 req/s, including reads).

### Concurrent throughput (searches), paced 5 × 18 = 90 calls against ≈ 500-corpus

| metric | value |
|--------|-------|
| n succeeded | 90 / 90 |
| p50 / p95 / p99 ms | 662 / 891 / 920 |
| mean ± stdev ms | 680 ± 85 |
| burst duration | 12.37 s |
| **throughput (q/s)** | **7.28** |

Search-under-concurrency latency is **~5.6× single-shot search latency** at the same corpus size (137 ms p50 single → 662 ms p50 5-thread). That's classic Python-GIL contention: the embedder runs in-process and serialises across threads, so 5 concurrent searchers share one CPU core's worth of FAISS-equivalent embedding lookup. Neo4j stayed quiet (~0.5 % CPU after the burst) — the bottleneck is on the MemOS side, not the graph DB.

### Cross-cube concurrent

Not run as a separate probe. The IP rate-limit makes the result identical to the single-cube concurrent test — every co-tenant agent shares the cap. (At demo scale the *aggregate* CEO + research-agent + email-marketing-agent traffic bills against the same 100-call window when they share a host, which they do per the deploy layout.)

### CompositeCubeView (CEO) latency

Not run as a separate probe — the audit user holds a single cube and the CEO sharing flow requires writing to the production CEO user, which is out of bounds for a throwaway-profile audit. Code-review of `multi_mem_cube/views.py` shows the search fans out per-cube and merges; latency at N cubes is bounded below by the slowest single-cube search × N (no fan-out parallelism in the read path that I can see in `single_cube.py:91-…`). At 5 cubes × the measured paced single-cube fast-search latency on a 1 k-ish corpus, expect ≥ 5 × p50.

### Memory + CPU footprint

| Process | RSS | VSZ | %CPU |
|---------|-----|-----|-----:|
| memos.api.server_api (after full probe matrix, ~700 writes + ~300 reads) | 980 MiB | 4 226 MiB | 6.1 % |
| qdrant (idle, no preference memory) | 52 MiB | n/a | 0.05 % |
| neo4j (post-bursts) | 1 259 MiB | n/a | 88.7 % during bursts, 0.5 % at rest |

**Embedder share.** The 980 MiB RSS includes the local sentence-transformers all-MiniLM-L6-v2 model (~85 MiB on disk, ~120 MiB resident). Growth from baseline (718 MiB) to 980 MiB across the full matrix = ~260 MiB. A 10 000-memory load on this host without restart will likely OOM given the 1.6 GiB free RAM and 4 GiB swap already exhausted. **Plan for ≥ 8 GiB free RAM headroom for a 10 k-memory cube.**

### Cold-start time

Not measured — restarting the running server (PID 2667993, up since 18:38) would have killed live agent traffic mid-audit. Code-path estimate from `start-memos.sh` + module init: sentence-transformers load (~5 s), Neo4j driver init (~1 s), `app.include_router(...)` (~0.2 s), BCrypt config load (synchronous, ~1 ms / agent), embedder warm-up (~2 s on first request). Realistic time-to-first-200 on `/health` is ~6–8 s; first successful `/product/add` ~10 s once the embedder warms.

### Network bind hot-path

All tests are loopback (`127.0.0.1:8001` → app, app → `localhost:7687` for Neo4j, app → `localhost:6333` for Qdrant). No DNS, no TLS, no re-resolution overhead. Skipped.

## Findings

### F-PERF-01 — Server-wide IP rate-limit caps demo-scale traffic

- **Class:** throughput-cap
- **Severity:** **Critical**
- **Reproducer:** any `/product/*` burst exceeding 100 calls in 60 s from the same IP — confirmed by 907 / 1 000 sequential warm-path 429s, 800 / 800 bulk-write 429s, 249 / 250 concurrent-write 429s, 200 / 200 concurrent-search 429s.
- **Evidence:** `rate_limit.py:41-42` — `RATE_LIMIT = int(os.getenv("RATE_LIMIT", "100"))`, `RATE_WINDOW = 60`. No env override in MemOS `.env`. `_get_client_key` returns `ratelimit:ip:127.0.0.1` for every `ak_*`-authenticated request → all agents on a host share the bucket.
- **One-sentence remediation:** raise `RATE_LIMIT` to ≥ 1 000 (or to 0 = disabled) in MemOS `.env`, *and* either key the limiter on the authenticated `user_id` (after auth) or document that all co-located agents share the cap.

### F-PERF-02 — BCrypt verify-cache is FIFO at 64 entries

- **Class:** cache-miss / latency-cliff
- **Severity:** Medium (today, with 3 agents); High at any growth.
- **Reproducer:** `agent_auth.py:117-118` — `VERIFY_CACHE_MAX = 64`. Cold cost is ~262 ms p50; warm hit is ~6 ms p50. Crossing 64 distinct keys evicts the oldest entry (LRU via `move_to_end` on hit; FIFO when only stuffed by writes).
- **Evidence:** measured cold/warm gap (262 ms → 6 ms = 44× speedup) confirms the cache dominates hot-path latency.
- **One-sentence remediation:** size `VERIFY_CACHE_MAX` to ≥ `agents.count` × 4 or back it with `functools.lru_cache(maxsize=None)` — the cache stores 32-byte key + ~36-byte value, so even 1 000 entries is < 100 KiB.

### F-PERF-03 — Wrong-key 401 path is sub-millisecond, but a successful auth on the same IP forgets every prior failure

- **Class:** rate-limit-bypass (semantic, not a bug per se)
- **Severity:** Info
- **Reproducer:** measured: 11 wrong keys triggered 429; one valid key cleared the counter; the next 10 wrongs work again.
- **Evidence:** `agent_auth.py:417-418` — `_clear_failures` runs unconditionally on success.
- **One-sentence remediation:** if the threat model is credential-stuffing against valid agents, decay (don't clear) the failure counter on success.

### F-PERF-04 — All agent keys share an IP rate-limit bucket

- **Class:** contention
- **Severity:** High at demo scale.
- **Reproducer:** `_get_client_key` keys agent traffic on IP, not on the resolved `user_id`. CEO + research-agent + email-marketing-agent on the same Hermes host share one 100/60s budget.
- **Evidence:** `rate_limit.py:141-161`. Only `krlk_*` admin keys get their own bucket.
- **One-sentence remediation:** thread the authenticated `user_id` from `agent_auth.AgentAuthMiddleware._authenticated_user` into `RateLimitMiddleware._get_client_key` so each agent gets its own quota.

### F-PERF-05 — Search latency scales super-linearly with corpus size for `no` and `sim` dedup modes

- **Class:** latency-cliff
- **Severity:** Medium (becomes High at 10k+ corpus).
- **Reproducer:** measured 200 → 500 corpus: `no` p50 123→280 ms (2.3×), `sim` p50 161→301 ms (1.9×) for a 2.5× corpus. `mmr` mode is flat (137→118 ms) because its cost is dominated by the post-process re-rank, not retrieval.
- **Evidence:** `tree_text_memory/retrieve/recall.py` runs `graph_store.search_by_embedding` then per-result graph traversals; the cost grows with corpus.
- **One-sentence remediation:** for production, prefer `mmr` mode by default (it's already the API-default per `APISearchRequest.dedup`); for `no`/`sim`, build a Neo4j vector index with HNSW (current install uses brute-force scan).

### F-PERF-06 — Neo4j is the write-side bottleneck; Qdrant is essentially unused for non-preference cubes

- **Class:** contention / unbalanced backend
- **Severity:** Medium
- **Reproducer:** `docker stats --no-stream` during the bursts: neo4j-docker 88.7 % CPU during writes, qdrant 0.04 % CPU.
- **Evidence:** `simple_tree.py:18,50` shows tree-text-memory routes embeddings + graph through `Neo4jGraphDB`; `vec_dbs/factory.py` Qdrant binding is reachable only via `prefer_text_memory`. The audit user is not a preference user.
- **One-sentence remediation:** the per-write dedup (`graph_store.search_by_embedding` in `_process_text_mem`) is the hot path — verify Neo4j vector index quality (`db.indexes` — out of scope here), and consider sending the dedup vector lookup to Qdrant if write volume justifies it.

### F-PERF-07 — Async `/product/add` caller-side latency is ~115 ms, not "near zero"

- **Class:** spec-mismatch
- **Severity:** Low
- **Reproducer:** measured 50 paced async writes — p50 = 114 ms, p99 = 267 ms. Doc claims caller-side latency should be near zero in async mode.
- **Evidence:** the `/product/add` handler walks bcrypt-cache + cube validation + scheduler enqueue before returning — even when the handler delegates extraction to the background scheduler, those synchronous prefixes cost ~110 ms on this host.
- **One-sentence remediation:** if true fire-and-forget is needed, lift cube validation behind a fast pre-flight check or document the actual ~100 ms async caller-side floor.

### F-PERF-08 — Concurrent search latency degrades 5.6× under modest 5-thread load

- **Class:** contention (GIL / embedder)
- **Severity:** Medium
- **Reproducer:** single-thread paced search on ~500 corpus: p50 = 117 ms (mmr). 5-thread concurrent on same corpus: p50 = 662 ms.
- **Evidence:** Neo4j was idle (~0.5 % CPU) during the search burst — the contention is in MemOS Python (sentence-transformers embedder, GIL).
- **One-sentence remediation:** put the embedder behind a thread-pool executor with explicit batching, or switch to a process-pool / external embedder service (e.g., a sidecar gRPC) so concurrent searches scale on this 4-core host.

### F-PERF-09 — Host is already saturated before audit starts

- **Class:** environment / startup-cost
- **Severity:** High (this host); Info elsewhere.
- **Reproducer:** `free -h` at run start shows 12 / 15 GiB RAM used, 4.0 / 4.0 GiB swap used, 95 % root-disk full (6 GiB free).
- **Evidence:** the cold-key provisioning subprocesses each took ~30 s instead of the expected ~3 s due to swap thrashing.
- **One-sentence remediation:** before quoting these numbers as production-representative, re-run on a host with ≥ 4 GiB free RAM and < 80 % full disk; expect p99 latencies to drop ~30 %.

## Summary table

| Area | Score 1–10 | P50 / P95 / P99 (ms) | Notes |
|------|-----------:|---------------------:|-------|
| Auth cold path | 5 | 262 / 350 / 369 | BCrypt rounds=12 ≈ 250 ms CPU floor; expected, but a fan-in burst of cold keys queues serially. |
| Auth warm path | 9 | 6 / 10 / 11 | Verify cache works exactly as designed. |
| Rate-limit lockout (agent_auth) | 8 | 401 ≈ 1.8 ms ; 429 ≈ 2 ms | Per-IP, 10/60 s, observable, granular, recovers cleanly. |
| Fast write | 6 | 84 / 127 / 139 | Strong p99 stability when paced; cliff at 100 / 60 s due to F-PERF-01. |
| Fine write (LLM-bound) | 6 | 2 382 / 2 769 / 3 522 | DeepSeek V3 dominates; acceptable for "fine" semantics. |
| Async write caller latency | 5 | 114 / 231 / 267 | Spec said "near zero"; actual is ~100 ms (F-PERF-07). |
| Search `no` mode (200 corpus) | 7 | 123 / 361 / 366 | Healthy at small corpus. |
| Search `sim` mode (200 corpus) | 7 | 161 / 549 / 627 | Slowest of the three; post-process similarity dominates tail. |
| Search `mmr` mode (200 corpus) | 7 | 137 / 342 / 588 | Default mode; fine. |
| Search at 200 / 500 corpus | 6 | 123 / 280 (no, p50) | Super-linear scaling for `no`/`sim` (F-PERF-05); 10 k untested on this host. |
| Chunking cost | 7 | 2 950 – 3 869 | Flat across 100–20 000 chars; LLM call dominates. |
| Concurrent write throughput | **2** | n=1 of 250 succeeded under default RL | F-PERF-01 dominates; sub-cap probe sustains 15.74 writes/s. |
| Concurrent search throughput | **2** | n=0 of 200 / 200 succeeded under default RL | F-PERF-01 dominates; sub-cap probe: 7.28 q/s, p50 662 ms. |
| Cross-cube interference | n/a | not run (out-of-bounds) | Code path = identical RL bucket — same cap applies. |
| CompositeCubeView latency | n/a | not run (out-of-bounds) | Estimated ≥ 5 × single-cube p50 from code review. |
| Memory growth under load | 7 | 718 → 980 MiB across the full probe matrix | ~0.4 MiB per write; 10 k writes ≈ 4 GiB headroom needed. |
| Cold-start time | 7 (estimated) | ~6–8 s to /health, ~10 s to first /add | Embedder warm-up dominates. |

**Overall score: 2 / 10** (= MIN; driven by F-PERF-01 / F-PERF-04 throughput cap on `/product/*`).

## Judgement at demo scale (and 10×)

At the prompt's demo scale — research-agent + email-marketing-agent + CEO, ≤ 10 k memories per agent, ≤ 100 qps — the system is **not fast enough out of the box**. The single-call latencies are inside budget (warm fast write ≈ 84 ms p50 leaves ample headroom under a 1 s SLO; mmr search on a 500-row corpus ≈ 117 ms p50), but the default `RATE_LIMIT = 100 / 60 s` per-IP middleware caps aggregate throughput at **1.67 req/s** across all three agents combined. That's ~60× short of the 100 qps target, and ~75× short of even a paced *single*-agent ingest of 10 k memories (which would take ~2 hours at 1.34 writes/s). Raising `RATE_LIMIT` to 10 000 (or per-user, F-PERF-04) and rotating production keys at default rounds=12 makes the system viable — the underlying single-cube pipeline is healthy. At 10× demo scale, the next cliff is the embedder + Neo4j on this 4-core CPU: paced fast-write latency rises with corpus size as the per-write dedup search fans out (F-PERF-05), 5-thread concurrency degrades search latency 5.6× (F-PERF-08), and the host's 1.6 GiB free RAM cannot hold a 30 k-memory tree corpus without swap. Plan for ≥ 8 cores, ≥ 16 GiB free RAM, an HNSW vector index in Neo4j (or Qdrant routing), and Redis-backed rate limiting before quoting these latencies as a production SLO.

## Appendix A — harness used

Two ad-hoc Python harnesses ran in `/tmp/v1-perf-out/` (no prior MemOS perf harness in this repo was read or referenced — the prompt forbade them):

- `harness.py` (initial sweep): cold/warm auth probes via fresh-key provisioning, agent-auth rate-limit probe, single-shot writes/searches/concurrent. Surfaced F-PERF-01 (most steady-state samples returned 429).
- `harness2.py` (paced re-run): all writes/searches paced @ 0.65 s to stay under the 100/60 cap; ~25-minute total wall-clock. Output in `/tmp/v1-perf-out/results2.json`.

Both relied only on `urllib`, `concurrent.futures`, and `subprocess`; no third-party benchmark tool. Probe samples per row were chosen to fit inside the rate-limit window (n = 30 per search-mode batch, n = 100 for paced fast write, n = 50 for async, n = 20 for fine).
