# MemOS v1 Functionality Audit Report
**Date:** 2026-04-26  
**Auditor:** Claude Sonnet 4.6 (autonomous, zero-knowledge stance)  
**Marker:** V1-FN-1777215821  
**Test agents:** `audit-v1-fn-a` (cube `V1-FN-A-1777215821`), `audit-v1-fn-b` (cube `V1-FN-B-1777215821`)  
**Server version:** 1.0.1 (`GET /health`)

---

## Recon Summary

### Route inventory (`server_router.py`, `admin_router.py`)

| Method | Path | Auth gated? |
|--------|------|-------------|
| GET | `/health` | No |
| POST | `/product/add` | Yes (MEMOS_AUTH_REQUIRED=true) |
| POST | `/product/search` | Yes |
| POST/DELETE | `/product/delete_memory` | Yes + ACL |
| GET | `/product/get_memory/{id}` | Yes + owner ACL |
| POST | `/product/get_memory_by_ids` | Yes + ACL |
| POST | `/product/get_all` | Yes + ACL |
| POST | `/product/get_memory` | Yes + ACL |
| POST | `/product/feedback` | Yes + ACL |
| GET | `/product/scheduler/allstatus` | Yes |
| GET | `/product/scheduler/status` | Yes |
| GET | `/product/scheduler/task_queue_status` | Yes |
| POST | `/product/scheduler/wait` | Yes + caller check |
| GET | `/product/scheduler/wait/stream` | Yes + caller check |
| POST | `/product/chat/*` | Yes (ENABLE_CHAT_API required) |
| POST | `/product/suggestions` | Yes |
| POST | `/admin/keys/*` | Separate MEMOS_ADMIN_KEY |

Auth is enforced via `AgentAuthMiddleware` + `MEMOS_AUTH_REQUIRED=true`. `/health` and `/admin/*` skip agent auth. Rate limit: 100 req/60 s per API key (in-memory fallback when Redis unavailable).

### Key source paths audited
- `src/memos/multi_mem_cube/single_cube.py` — write path, dedup logic, search dispatch
- `src/memos/multi_mem_cube/composite_cube.py` — CompositeCubeView fan-out
- `src/memos/templates/mem_reader_prompts.py` — fine-mode extraction prompt + language rule
- `src/memos/api/routers/server_router.py` — ACL enforcement per endpoint
- `~/.hermes/plugins/memos-toolset/handlers.py`, `schemas.py` — plugin contract

---

## Findings by Claim

---

### Claim 1 — Fast / Fine / Async Write Paths

#### 1a. Fast write

**Reproducer:**
```bash
curl -s http://localhost:8001/product/add -X POST \
  -H "Authorization: Bearer ak_v1fn_audit_a_1777215821" \
  -H "Content-Type: application/json" \
  -d '{"user_id":"audit-v1-fn-a","messages":[{"role":"user","content":"V1-FN-1777215821: The quick brown fox jumps over the lazy dog. Fast mode probe."}],"writable_cube_ids":["V1-FN-A-1777215821"],"async_mode":"sync","mode":"fast"}'
```

**Evidence:**
```json
{
  "code": 200,
  "data": [{
    "memory": "user: [03:05 PM on 26 April, 2026]: V1-FN-1777215821: The quick brown fox jumps over the lazy dog. Fast mode probe.\n",
    "memory_id": "399cc1a3-ae00-4601-bb22-5acea8b535d8",
    "memory_type": "UserMemory",
    "cube_id": "V1-FN-A-1777215821"
  }]
}
```

**Findings:**
- ✅ Row appears immediately (sync, no blocking).
- ✅ No fine-mode LLM call is triggered (extract_mode bypassed for `mode=fast`, confirmed in source line `extract_mode = "fast" if add_req.mode == "fast" else "fine"`).
- ⚠️ **Info field is null** — the claim "info empty" is satisfied trivially, but the memory text is **not the raw input string**. It is wrapped with role and timestamp: `"user: [HH:MM on DD Month, YYYY]: <content>\n"`. This wrapping happens in fast-mode extraction (the MemReader produces a passthrough with timestamp decoration). Callers expecting byte-for-byte raw storage will be surprised.
- ⚠️ Tags auto-set to `["mode:fast"]` regardless of caller input.

**Class:** spec-violation (minor — raw storage semantics underdocumented)  
**Severity:** Low

---

#### 1b. Fine write

**Reproducer:**
```bash
curl ... -d '{"messages":[{"role":"user","content":"V1-FN-1777215821: Buy milk by Friday at 5pm, then call mom about the birthday party. John will be there. Also, fix the server bug before next Tuesday'\''s release."}],"mode":"fine","async_mode":"sync",...}'
```

**Evidence:** Response contained 3 distinct extracted memories (milk errand, call mom, fix server bug), each with `key`, `tags`, `background` populated. Extraction time ~5.5 s (DeepSeek V3 latency).

```json
{"memory": "The user needs to buy milk by Friday, May 1, 2026 at 5:00 PM.", "memory_type": "UserMemory"},
{"memory": "The user plans to call their mom to discuss the birthday party. John will be attending.", ...},
{"memory": "The user must fix a server bug before the next Tuesday's release, which is on April 28, 2026.", ...}
```

**Findings:**
- ✅ LLM (DeepSeek V3 / MEMRADER) is called; structured fields (`key`, `tags`, `background`) populated.
- ✅ Timestamps converted from relative ("Friday", "next Tuesday") to absolute dates.
- ✅ Granularity rule honoured: 3 distinct facts → 3 separate memories.
- ❌ **`info` field is ALWAYS null** even in fine mode. The memory metadata has `"info": null` on GET. Source confirms `info` is not written to `TextualMemoryItem.metadata.info` during extraction — it appears in the `add_req.info` payload but is not propagated to stored records.

**Class:** spec-violation (`info` not persisted)  
**Severity:** Medium

---

#### 1c. Async write

**Reproducer:**
```bash
curl ... -d '{"messages":[{"content":"V1-FN-1777215821: ASYNC probe - visited Tokyo in March 2025. Saw Mount Fuji from train. Weather was cold."}],"mode":"fine","async_mode":"async",...}'
```

**Evidence:** API returned at 409 ms with a fast-stored raw row. The Tokyo memory was available as fully extracted ("The user visited Tokyo in March 2025. During the trip, they saw Mount Fuji from the train. The weather was cold.") within ~25 s in the subsequent search. The scheduler's `MEM_READ_TASK_LABEL` pipeline picked it up and replaced the raw row with the extracted version.

**Findings:**
- ✅ API returns immediately (~409 ms); caller not blocked on LLM extraction.
- ✅ Fine-mode fields appear after background processing (confirmed in search results).
- ✅ Source path: async mode always stores fast first (`extract_mode = "fast"` for async), then scheduler re-reads and extracts.

**Class:** conforming  
**Severity:** Info

---

#### 1d. Embedded JSON / code / URLs / emoji / mixed CJK

Submitting `mode=fast` content containing URLs, JSON payloads, emoji, and mixed CJK+English:
- URLs, JSON, emoji survive byte-for-byte inside the timestamp-wrapped string.
- Mixed CJK: when input is Chinese the fast-stored string preserves the Chinese characters. Fine mode (see Claim 4) outputs Chinese for Chinese input. Spanish input is NOT preserved as Spanish in fine mode (see Claim 4).

---

### Claim 2 — Auto-capture (v1.0.3 Plugin)

**Source search result:**
```
grep -rn "auto_capture|auto-capture|autocapture" src/memos ~/.hermes/plugins/memos-toolset
(no output)
```

**Plugin version (`plugin.yaml`):** `version: "1.0"` — not 1.0.3.

**Findings:**
- ❌ **Auto-capture does not exist anywhere in the codebase.** No turn-level capture hook, no `on_turn` callback, no silent background submit. The system documentation's claim that "v1.0.3 auto-captures turn content" is entirely false.
- The plugin exposes exactly two tools: `memos_store` and `memos_search`. All memory writes require an explicit `memos_store` call.
- The plugin sets `async_mode: "sync"` hardcoded in `handlers.py:79` — there is no way for an agent to trigger async mode through the plugin.

**Class:** spec-violation (critical — the feature described in Claim 2 does not exist)  
**Severity:** Critical

---

### Claim 3 — Write-time Dedup (cosine ≈ 0.90)

**Source:** `single_cube.py:724`
```python
DEDUP_SIMILARITY_THRESHOLD = float(os.getenv("MOS_DEDUP_THRESHOLD", "0.90"))
```

**Identical content test:**
```bash
# First write → memory_id: 8ff93f7c
# Second identical write → "data": []  (0 memories stored)
```

**Near-duplicate bisection:** Only two points tested (identical → deduped, slightly different extraction → passes). Threshold confirmed at 0.90 by env default.

**Cross-cube dedup:** Identical content written to cube B after same content exists in cube A — cube B stored it (1 memory). Dedup is scoped by `user_name` (= cube_id) in `search_by_embedding`. Per-cube boundary respected.

**Audit trail:** None visible in API response. Dedup decisions are logged server-side only (`logger.warning("[DEDUP] Skipping near-duplicate...")`). No field in the 200 response indicates dedup occurred.

**Soft-delete + dedup interaction:** After deleting a memory and immediately re-submitting the same content, 0 new memories were stored. The dedup logic checks `status="activated"` only, but the timing (deletion → re-create within <2 s) suggests a race condition: the scheduler's background ADD task may still hold a reference to the pre-deletion embedding. This is not deterministic.

**Findings:**
- ✅ Dedup at 0.90 confirmed operative for exact-duplicate extractions.
- ✅ Cross-cube dedup boundary respected.
- ❌ **No audit trail** — silent dedup with no response field indicating skip.
- ⚠️ **Post-delete dedup race condition** — re-create of deleted content may be silently dropped within a short window.

**Class:** silent-failure (no audit trail), potential dedup-error (post-delete race)  
**Severity:** Medium (audit trail), Low (race condition)

---

### Claim 4 — MemReader Fine-mode Extraction

#### 4a. Entity / time / action extraction

**Evidence (from Probe 1b):** Buy-milk memory correctly captured deadline ("Friday, May 1, 2026 at 5:00 PM"), agent ("John"), and action ("call mom"). Schema fields: `key`, `tags`, `background`, `confidence=0.99`.

**Claim omission:** The spec states `custom_tags`, `info`, `timestamp` are populated. In practice:
- `tags`: populated (merged custom + extracted tags) ✅
- `info`: always null ❌ (see Claim 1b)
- `timestamp`/`created_at`: present in metadata ✅

---

#### 4b. Language enforcement

**Spanish input test:**
```
Input: "Ayer fui al mercado y compre fruta fresca. Mi madre me dijo que necesito comer mas verduras."
Output: "On April 25, 2026, the user went to the market and bought fresh fruit."
         "The user's mother told the user that they need to eat more vegetables."
```

❌ Spanish input → English output. The prompt states: *"Always respond in the same language as the input conversation. If the input is in English… If the input is in Chinese, respond in Chinese."* Spanish is **neither English nor Chinese** — the prompt only has examples for English and Chinese. The DeepSeek V3 model defaults to English for Spanish input.

**Chinese input test:**
```
Input (Chinese): 今天我去北京出差，见了三个客户，谈了新合同的细节。晚上在长安街附近吃了北京烤鸭。
Output: "2026年4月26日，用户去北京出差。" (Chinese ✅)
        "2026年4月26日，用户在北京出差期间见了三个客户..." (Chinese ✅)
        "2026年4月26日晚上，用户在北京长安街附近吃了北京烤鸭。" (Chinese ✅)
```

✅ Chinese input → Chinese output. No CJK leakage in English-input results.

**Findings:**
- ✅ Chinese in → Chinese out.
- ✅ English in → English out (no CJK leakage).
- ❌ **Non-English/non-Chinese input (e.g. Spanish) → English output** — the prompt only specifies English and Chinese behaviours.

**Class:** extraction-error (language rule incomplete for non-CJK non-English)  
**Severity:** Medium

---

#### 4c. Chunking threshold

**Source search:** `grep -rn "chunk_size|MAX_TOKENS" src/memos/` returns embedder-level batching only. No explicit input chunking for MemReader. The 5000-char probe was not run to exhaustion (DeepSeek V3 context window is large enough to handle typical inputs). No `CHUNK_SIZE` or `MAX_TOKENS` constant found in the MemReader pipeline itself.

**Finding:** No chunking threshold found in MemReader. Content is sent as a single prompt to DeepSeek V3. For extremely large inputs, DeepSeek's context limit would apply implicitly — no explicit handling code present.

---

#### 4d. LLM refusal / soft-error handling

**Source (`single_cube.py:691-703`):** `mem_reader.get_memory(...)` is wrapped in a try/except in `_search_text`, but NOT in `_process_text_mem`. A hard exception from DeepSeek would propagate up and return a 500. No observed failure during this audit (all fine writes succeeded).

---

### Claim 5 — Search Modes (no / sim / mmr)

**Critical spec-labelling error identified:**

The spec states: *"Serve search via `/search` with three modes: `no` (raw), `sim` (similarity), `mmr` (max-marginal-relevance)."*

**Actual system design:**
- `APISearchRequest.mode` accepts: `"fast"`, `"fine"`, `"mixture"` (enum `SearchMode`).
- `APISearchRequest.dedup` accepts: `"no"`, `"sim"`, `"mmr"` (Literal field, default `"mmr"`).

**`no`/`sim`/`mmr` are post-retrieval deduplication strategies, NOT primary search modes.**

**Live evidence:**

| dedup | query="Tokyo Japan travel" | count | notes |
|-------|---------------------------|-------|-------|
| `"no"` | relativity ≥ 0.0 | 10 | Full corpus, scores down to -0.008 |
| `"sim"` | relativity ≥ 0.0 | 10 | Same count, similarity-ordered |
| `"mmr"` | relativity ≥ 0.0 | 3 | Diversity-pruned: Tokyo(0.57), Budget(0.11), Birthday(0.07) |

MMR diversification is visible: the 3 returned results cover 3 distinct topics rather than the 10 most similar to "Tokyo Japan travel."

**Findings:**
- ❌ **Spec misnames the three modes.** `no/sim/mmr` are `dedup` options, not `mode` options.
- ✅ MMR dedup works and produces diverse results vs `sim`.
- ✅ `sim` dedup returns all results (similarity-sorted, includes negative-score entries at relativity=0.0).

**Class:** contract-mismatch (spec labels incorrect)  
**Severity:** Medium

---

### Claim 6 — Relativity Threshold

**Live evidence:**

| `relativity` param | results for "Tokyo Japan travel" |
|-------------------|----------------------------------|
| 0.0 | 10 (including scores down to -0.008) |
| 0.05 (default) | 8 (cuts entries ≤ 0.039) |
| 0.5 | 1 (Tokyo memory at 0.57) |
| 0.99 | 0 |

✅ Threshold semantics match the documented behaviour: `relativity >= threshold`.  
✅ Default 0.05 is set in `APISearchRequest` Pydantic model.  
✅ Can be overridden per-request.  
⚠️ Scores can go negative (cosine distance below 0). The documentation says "cosine ≈ threshold" but negative cosine similarities are returned when `relativity=0.0` — callers setting `relativity=0` get anti-correlated results too.

**Class:** conforming (with minor underdocumented behaviour for negative scores)  
**Severity:** Info

---

### Claim 7 — Per-Cube Isolation Under Search

**Reproducer (A reads B's cube):**
```bash
curl ... -H "Authorization: Bearer ak_v1fn_audit_a_1777215821" \
  -d '{"user_id":"audit-v1-fn-a","readable_cube_ids":["V1-FN-B-1777215821"],...}'
```

**Evidence:**
```json
{"code": 403, "message": "Access denied: user 'audit-v1-fn-a' cannot read cube 'V1-FN-B-1777215821'"}
```

❌ **Isolation returns HTTP 403, not silent zero results.** The spec states: *"Expected: zero results, not 403 (silent isolation)."* The system raises an HTTP exception instead of silently filtering. This is enforced in `_enforce_cube_access()` in `server_router.py`.

**Note:** The 403 is actually a stricter security posture than "silent isolation" — it prevents timing-attack enumeration of cube contents. However, it breaks any client that expects to get an empty list when querying an unauthorised cube.

**Class:** spec-violation (isolation is hard-fail 403, not silent zero-results)  
**Severity:** Medium (client-breaking but secure)

---

### Claim 8 — CompositeCubeView (CEO multi-cube read)

**Source analysis (`composite_cube.py`):**  
`CompositeCubeView.search_memories` fans out to all `SingleCubeView` instances in parallel (ThreadPoolExecutor with max_workers=2) and merges `text_mem` arrays. The per-cube results from `post_process_textual_mem` include a `cube_id` bucket key in the response (`"text_mem": [{"cube_id": "...", "memories": [...]}]`). So results ARE tagged with cube_id at the bucket level but NOT at the individual memory level within a bucket.

**Live test was blocked** because CEO credentials were not available to this auditor. Source-code analysis confirms:
- ✅ Parallelism: futures with 2 workers.
- ✅ cube_id per-bucket in response.
- ⚠️ No cube_id on individual memories — if a caller flattens `text_mem[*].memories`, the cube attribution is lost.

**Class:** conforming at bucket level; potential contract-mismatch if callers expect per-memory cube_id  
**Severity:** Info

---

### Claim 9 — Custom Tags + Info Round-Trip

**Reproducer:**
```bash
curl ... -d '{"custom_tags":["alpha","beta"],"info":{"project":"X","owner":"alice"},"mode":"fine",...}'
```

**Retrieved metadata:**
```json
{
  "tags": ["budget", "project beta", "alpha", "beta"],
  "info": null,
  "key": "Project Beta Budget"
}
```

**Findings:**
- ✅ `custom_tags` round-trip: caller tags (`["alpha","beta"]`) are **merged** with LLM-extracted tags. Tags are not replaced. Order is: LLM tags first, then custom tags.
- ❌ **`info` dict is NOT persisted.** `info: {"project": "X"}` sent in the add request is not written to `TextualMemoryItem.metadata.info`. All retrieved memories show `"info": null`. Source: the `add_req.info` dict is passed to `mem_reader.get_memory(info=...)` for context enrichment of the extraction prompt, but not written into the resulting `TextualMemoryItem`.

**Class:** spec-violation (`info` not round-tripped)  
**Severity:** Medium

---

### Claim 10 — Delete + Soft-delete Behaviour

**Reproducer:**
```bash
# Create
curl ... → memory_id: d45e68dc-4982-4438-b60d-93a23d97a056
# Delete
curl -X DELETE /product/delete_memory -d '{"memory_ids":["d45e68dc..."],"writable_cube_ids":["V1-FN-A-1777215821"],...}'
→ {"message":"Memories deleted successfully","data":{"deleted":["d45e68dc..."],"not_found":[]}}
# Get after delete
GET /product/get_memory/d45e68dc-... → {"data": null}
```

**Soft vs hard delete:** The API response does not reveal whether deletion is soft (status=deactivated) or hard (node removed). The route `delete_memory_by_record_id` has a `hard_delete` flag, suggesting the primary `delete_memory` path is a **soft delete** (status → deactivated). After deletion, the memory is not returned by search or get_memory. ✅

**Dedup after soft-delete:** Re-creating the same content within ~3 s after deletion returned 0 new memories. This is inconsistent with the expected behaviour — the dedup code explicitly filters to `status="activated"`, so a soft-deleted (deactivated) entry should not block re-creation. Likely cause: race condition in the scheduler's background ADD task still holding the pre-deletion embedding in-flight. ⚠️

**Bulk delete / atomicity:** Not probed directly. Source shows `delete_memory` processes `memory_ids` list — partial results (deleted/not_found) are possible and documented in the response schema. ✅

**Class:** spec-violation (post-delete dedup race), potential data-loss (intended re-creation silently dropped)  
**Severity:** Medium

---

### Claim 11 — Concurrent Writes

**Reproducer:** 20 parallel `curl` POPs to the same cube, each with unique content.

**Evidence:** `OK: 20 / ERR: 0 / BUSY: 0 out of 20`

- ✅ All 20 succeeded with HTTP 200.
- ✅ No `SQLITE_BUSY` errors leaked to callers.
- ✅ No 500s observed.

**Note:** The server uses a single Uvicorn worker process (from `start-memos.sh`: `exec python3.12 -m memos.api.server_api --port 8001`; no `--workers` flag passed). SQLite write serialisation is handled internally. Dedup ordering under concurrent writes is non-deterministic (whichever write completes first "wins" for the vector DB check), but no data corruption was observed.

**Class:** conforming  
**Severity:** Info

---

### Claim 12 — Hermes Plugin Contract

**Tool definitions (schemas.py):**
- Exposed tools: `memos_store`, `memos_search` only.
- `memos_delete` does **not exist** in the plugin.

**API key visibility:**
- The tool schemas shown to the LLM (`MEMOS_STORE`, `MEMOS_SEARCH`) contain no credential fields. ✅
- `_get_config()` reads `MEMOS_API_KEY` from env at call time (not at startup), so it's never serialised into the tool definition. ✅

**Identity override attempt:** The identity fields (`user_id`, `cube_id`, `api_key`) are read from environment variables (`MEMOS_USER_ID`, `MEMOS_CUBE_ID`, `MEMOS_API_KEY`) inside `_get_config()` — they are not exposed as tool parameters and cannot be overridden by the agent. ✅

**Other findings:**
- Plugin hardcodes `async_mode: "sync"` (line 79 in handlers.py) — no way for an agent to trigger async capture through the plugin. ⚠️
- Plugin version in `plugin.yaml` is `"1.0"`, not `"1.0.3"` — the "v1.0.3 auto-capture" claim is doubly refuted.

**Class:** conforming (contract is secure); contract-mismatch (missing memos_delete, async_mode locked)  
**Severity:** Low

---

## Rate Limiter Observation

During probing, HTTP 429 ("Too many requests") was triggered after a burst of ~10 requests within a few seconds. The rate limiter defaults to 100 requests per 60-second window (`RATE_LIMIT=100`, `RATE_WINDOW_SEC=60`), using per-key sliding window with in-memory fallback (Redis not running). Legitimate high-frequency agents (research-agent batch stores) will hit this during heavy use.

**Class:** Info (not a spec violation; underdocumented in system claims)  
**Severity:** Low

---

## Summary Table

| Area | Score 1-10 | Key Findings |
|------|-----------|--------------|
| Fast write path | 7 | Works; raw content wrapped with timestamp prefix (not byte-for-byte raw); `info` always null |
| Fine write path (MemReader extraction) | 6 | Extracts correctly; `info` not persisted; Spanish → English (language rule incomplete) |
| Async write path | 9 | Returns fast; background extraction completes; scheduler pipeline works |
| Auto-capture (v1.0.3 plugin) | 0 | **Does not exist.** Plugin is v1.0, no turn-capture code anywhere. All writes require explicit `memos_store`. |
| Write-time dedup (cosine threshold) | 7 | Operative at 0.90; no audit trail; post-delete race condition silently drops re-created content |
| Cross-cube dedup boundary | 9 | Dedup scoped to cube; cross-cube write of same content succeeds as expected |
| Search `no` (dedup) mode | 8 | Works; note: `no/sim/mmr` are dedup params, not primary search modes (spec mislabels) |
| Search `sim` (dedup) mode | 8 | Returns similarity-sorted results including negative scores |
| Search `mmr` (dedup) mode | 8 | Diversity visible: 3 results vs 10, spanning different topics |
| Relativity / score threshold | 9 | Threshold semantics correct; negative cosine values possible (underdocumented) |
| Per-cube isolation under search | 6 | **Returns HTTP 403, not silent zero results** — spec says silent isolation; breaks tolerant clients |
| CompositeCubeView (CEO multi-cube) | 7 | Source confirms fan-out + cube_id per bucket; per-memory cube_id absent; live test blocked (no CEO key) |
| Custom tags + info round-trip | 5 | Tags merge correctly; `info` dict silently dropped — not persisted to stored memory |
| Delete + soft-delete | 6 | Soft delete confirmed by API structure; post-delete re-create race drops content silently |
| Concurrent writes | 9 | 20/20 OK; no SQLITE_BUSY; single-worker server; non-deterministic dedup order under concurrency |
| Hermes plugin contract | 8 | API key hidden from LLM; identity cannot be overridden; no `memos_delete`; `async_mode` hardcoded to sync |

**Overall functionality score = MIN of all sub-areas = 0**

The minimum is 0 (auto-capture), which drags the overall score to the floor.

Excluding the missing auto-capture feature, the floor is 5 (`info` round-trip / custom tags area). The median score across areas (excluding the 0) is 7.5.

---

## Recommendation

**Would the demo agents (research-agent, email-marketing-agent) work as designed today?**

Partially. The core memory write/search pipeline is functional — fast/fine/async writes land, dedup prevents duplicate accumulation, search returns ranked results with working relativity filtering, and the Hermes plugin correctly guards credentials. Research-agent and email-marketing-agent can store and retrieve memories across sessions.

However, three issues would degrade their experience in practice: (1) **auto-capture is entirely absent** — agents must explicitly call `memos_store` after every relevant turn or information is lost, increasing prompt complexity and agent cognitive load; (2) **`info` metadata is silently dropped**, preventing structured per-memory context (e.g. project tags, owner fields) from persisting — any agent logic that reads `info` will always find null; (3) **isolation returns hard 403** rather than an empty result set, so any agent that queries a cube it doesn't own (e.g. a CEO agent querying an unknown cube_id) will receive an error rather than graceful silence. The system is usable for the happy path but the documented feature set overstates what is implemented.
