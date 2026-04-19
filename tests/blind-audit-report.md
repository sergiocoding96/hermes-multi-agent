# MemOS Blind Functionality Audit Report

**Auditor:** Claude Sonnet 4.6 (autonomous agent)
**Date:** 2026-04-07
**API Version:** MemOS 1.0.1
**Server:** localhost:8001
**Test users created:** audit-alpha (audit-alpha-cube), audit-beta (audit-beta-cube), audit-gamma (audit-gamma-cube)

---

## Summary Table

| Area | Score | Verdict |
|------|-------|---------|
| Write path (fast mode) | 8/10 | Works, raw text stored with timestamp |
| Write path (fine mode) | 7/10 | LLM extraction works, not always atomic |
| Sync vs async timing | 6/10 | Sync blocks; async surprisingly slow (~1.1s) |
| Extraction quality | 7/10 | Third-person maintained, pronouns resolved, timestamps mostly correct |
| Search (exact/semantic) | 8/10 | Works well, relevance scores meaningful |
| Relativity threshold | 9/10 | Works exactly as documented |
| Top-K | 9/10 | Returns exactly top_k results |
| Dedup search modes (no/sim/mmr) | 3/10 | Three modes return identical results |
| Dedup at write time | 8/10 | 90% threshold works correctly |
| Long content | 5/10 | Fast mode: stores as single chunk; fine mode: 500w→25 facts in 48s |
| Cross-cube isolation | 9/10 | Strictly enforced, correct |
| Memory types | 6/10 | Text/LongTerm work; preference extracted; info/tags have bugs |
| Feedback endpoint | 7/10 | Works with writable_cube_ids; fails without it |
| Scheduler | 5/10 | Runs but Redis-based queue unavailable; tasks show 0 |
| Chat endpoint | 4/10 | 422 error on APIChatCompleteRequest (missing `query` field) |
| Auth (bcrypt v2) | 6/10 | Correct but ~1.1s overhead per request |
| Delete memory | 7/10 | Works with `memory_ids` plural, fails with `mem_cube_id` alone |
| Data persistence | 8/10 | Survives server restart (Qdrant + Neo4j), not across config changes |
| Edge cases | 8/10 | URL, JSON, HTML, code, whitespace handled correctly |

**Overall system score: 6.8/10**

---

## 1. Write Path

### 1a. Sync Fast Mode
- **Tested:** POST `/product/add` with `async_mode=sync, mode=fast`
- **Expected:** Store raw message, return immediately
- **Actual:** Stores raw message as-is with timestamp prefix. Returns 1 memory. Time: ~440ms (dominated by bcrypt auth).
- **Raw format:** `user: [01:47 PM on 07 April, 2026]: <content>\n`
- **Score: 8/10** — Works correctly. The prepended timestamp is a useful artifact. The auth overhead (bcrypt) makes "fast" not actually fast.

### 1b. Sync Fine Mode
- **Tested:** POST `/product/add` with `async_mode=sync, mode=fine`
- **Expected:** LLM-extracted atomic facts
- **Actual:** DeepSeek V3 extracts facts in ~10-20s (depending on content length). Returns multiple `TextualMemoryItem` objects.
- **Example:** "My name is Alice. I work at TechCorp. I love hiking. Favorite language Python." → 4 separate facts. BUT: "Alice is 28 and works as a software engineer at TechCorp" → merged into 1 (not fully atomic). The LLM sometimes combines closely related facts.
- **Score: 7/10** — Extraction works but is not consistently atomic.

### 1c. Async Mode
- **Tested:** POST `/product/add` with `async_mode=async`
- **Expected:** Return immediately (< 50ms), background processing
- **Actual:** Returns in ~127ms (with fresh server) to ~1.1s (after bcrypt key is in cache). Returns raw message immediately — fine-mode extraction is NOT triggered in async mode. The returned memory is always the raw string.
- **Critical finding:** Async mode NEVER triggers fine-mode extraction. It always stores the raw message. The `mode` parameter is documented as "only used when async_mode='sync'" — this is consistent but means async mode gives lower quality storage.
- **Score: 6/10** — Works as documented but the 1.1s auth overhead dominates; async mode loses extraction quality.

---

## 2. Extraction Quality

### 2a. Atomicity
- **Tested:** Fine mode with multi-fact input
- **Expected:** One fact per memory item
- **Actual:** Mostly atomic (4 facts from 5-fact input), but some combining occurs. "Alice is 28 years old and works at TechCorp" was stored as a single memory rather than two separate ones.
- **Score: 7/10**

### 2b. Third-Person Perspective
- **Tested:** Fine mode on first-person input ("I am afraid of spiders. I have a cat named Whiskers. I just moved to Boston.")
- **Expected:** Converts to third-person
- **Actual:** CORRECT — Output is "The user has a fear of spiders." / "The user has a pet cat named Whiskers." / "The user recently moved to Boston." No first-person pronouns ("I") in stored memories.
- **Score: 10/10**

### 2c. Pronoun Resolution
- **Tested:** Multi-turn conversation: "David is 45 years old. He is a physicist at MIT. His wife Sarah is a doctor." + "he won the Nobel Prize last year. She works at Boston General."
- **Expected:** Pronouns resolved to proper nouns
- **Actual:** Correct: "David won the Nobel Prize last year." / "Sarah works at Boston General hospital." Pronouns fully resolved.
- **Score: 10/10**

### 2d. Timestamp Resolution
- **Tested:** Message with `chat_time: "2026-04-06 10:00:00"` containing "I had a meeting yesterday."
- **Expected:** "Yesterday" resolved to specific date
- **Actual:** "On April 5, 2026, the user had a meeting where they discussed the budget." — CORRECT, resolves "yesterday" relative to the chat_time.
- **Score: 9/10**

### 2e. Memory Type Assignment
- **Tested:** Various message types (user, assistant, multi-turn conversations)
- **Actual observations:**
  - Single `user` message → `UserMemory`
  - Multi-turn conversation with user+assistant → both `UserMemory` and `LongTermMemory`
  - `assistant` messages stored as raw format → `LongTermMemory`
  - Fine mode on conversation → `LongTermMemory` for extracted facts
- **Score: 7/10** — Memory type assignment isn't fully transparent but seems systematic.

---

## 3. Search Path

### 3a. Exact Search
- **Tested:** Searching for "What is the capital of France?" after writing "The capital of France is Paris."
- **Actual:** Found with relativity score 0.73.
- **Score: 9/10**

### 3b. Semantic/Vague Search
- **Tested:** "Where does Alice work?" → Retrieved "Alice introduced herself. She is 28 and works as a software engineer at TechCorp." with relativity 0.61
- **Actual:** Semantic search works well. Results are relevance-ranked.
- **Score: 8/10**

### 3c. Relativity Threshold
- **Tested:** Same query with thresholds 0, 0.05, 0.3, 0.5, 0.8
- **Actual:** 11 → 8 → 4 → 2 → 0 results. Perfectly monotonic filtering.
- **Score: 9/10**

### 3d. Top-K
- **Tested:** top_k = 1, 3, 5, 10, 20
- **Actual:** Returns exactly top_k results (or fewer if not enough memories exist). Works correctly.
- **Score: 9/10**

### 3e. Search Mode (fast/fine/mixture)
- **Tested:** Same query with fast, fine, mixture modes
- **Actual:**
  - `fast`: 10 results in 1.06s
  - `fine`: 10 results in 6.97s (slower but same count, slightly different order)
  - `mixture`: 10 results in 1.06s (identical to fast in our tests)
- **Finding:** `mixture` appears to behave identically to `fast` — may require specific conditions to trigger the mixed pipeline. `fine` mode search is much slower but may rerank differently.
- **Score: 6/10** — `fine` and `mixture` modes don't show clearly differentiated behavior in basic tests.

### 3f. Dedup Search Modes (no/sim/mmr)
- **Tested:** After adding 5 near-identical "Curie Nobel Prize" sentences, searched with all 4 dedup modes
- **Expected:** `sim` and `mmr` should reduce duplicate results vs `no`
- **Actual:** All 4 modes (null, no, sim, mmr) returned identical result counts and identical results in our tests.
- **Critical finding:** The search-time dedup modes appear non-functional or require more similar results to trigger. Write-time dedup (90% threshold) works correctly and is the primary dedup mechanism.
- **Score: 3/10** — Search-time dedup modes showed no observable difference.

---

## 4. Write-Time Deduplication

### 4a. Exact Duplicate
- **Tested:** Writing identical sentence 3 times
- **Actual:** Only 1 memory stored. 2nd and 3rd writes return `data: []` (empty, no memory_id).
- **Score: 10/10**

### 4b. Near-Duplicate (Paraphrase)
- **Tested:** "The Pacific Ocean covers about 46% of Earth's water surface." + "The Pacific Ocean covers approximately 46% of Earth's water surface." + "The Pacific Ocean covers roughly half of Earth's water surface area."
- **Actual:** 1st stored, 2nd DEDUPED (>90% similarity), 3rd STORED (similarity <90%). "Atlantic Ocean" stored as a new fact.
- **Score: 9/10** — Threshold behavior is correct and predictable.

### 4c. Dedup Analysis
- **Tested:** Sky-related sentences with known similarity levels
- **Results:**
  - "The sky is blue." vs "The sky is blue." → DEDUPED ✓
  - "The sky is blue." vs "The sky appears blue." → DEDUPED ✓  
  - "The sky is blue." vs "The heavens have a blue color." → NOT DEDUPED ✓
  - "The sky is blue." vs "Water is wet." → NOT DEDUPED ✓
- **Configured threshold:** `MOS_DEDUP_THRESHOLD=0.90`
- **Score: 9/10**

---

## 5. Long Content

### 5a. Fast Mode
- **Tested:** 100, 500, 1000, 5000 words
- **100 words:** 1 memory stored (full content)
- **500 words:** 0 memories (deduped because content was repetitive — similar to existing memories)
- **1000 words:** 0 memories (same reason)
- **5000 words (unique):** 1 memory stored
- **Finding:** Fast mode stores the entire content as a SINGLE memory regardless of length. No chunking. For very long texts, this means semantic search quality degrades since the whole document is one embedding.
- **Score: 5/10** — No chunking = single-vector retrieval for any document length.

### 5b. Fine Mode on Long Content
- **Tested:** 500 words (unique facts) with fine mode
- **Actual:** 25 facts extracted in 48 seconds. Facts at beginning AND end of document extracted correctly.
- **Tested:** 10-sentence computing history → 10 facts extracted in 18.7 seconds.
- **Finding:** Fine mode effectively chunks semantically. All facts extracted regardless of position. But cost is ~2 seconds per sentence (LLM API).
- **Score: 7/10** — Works well but very slow for long documents.

---

## 6. Cross-Cube Search

### 6a. Isolation
- **Tested:** Alpha user tries to read beta cube
- **Actual:** 403 "Access denied: user 'audit-alpha' cannot read cube 'audit-beta-cube'"
- **Score: 10/10** — Strict isolation enforced.

### 6b. CEO Multi-Cube Access
- **Tested:** CEO user (has access to research-cube + email-mkt-cube via provisioning)
- **Actual:** CEO can search research-cube. Isolation works correctly based on cube ownership/sharing.
- **Finding:** CEO cannot read audit-* cubes (not provisioned). Cross-cube access requires explicit cube sharing via `UserManager.add_user_to_cube()`.
- **Score: 9/10**

### 6c. Results Ranking
- **Finding:** When searching a single cube, results ranked by semantic similarity (relativity score). Multi-cube search merges results — not directly tested because cross-cube access requires provisioning.
- **Score: N/A**

---

## 7. Memory Types

### 7a. Text Memory (UserMemory / LongTermMemory)
- **Working.** Fast mode → UserMemory. Fine mode conversation → LongTermMemory.

### 7b. Preference Memory
- **Tested:** Fine mode with preference-type content ("I prefer dark mode interfaces and always use vim.")
- **Actual:** Extracted as `UserMemory` type (NOT a separate PreferenceMemory type via this path). The preference search via `include_preference=True` returns 1 result but with `memory_type: None`.
- **Finding:** Preference memories exist in the dashboard (`pref_mem` key) but the extraction path is unclear. The `ENABLE_PREFERENCE_MEMORY=true` env var and `PREFERENCE_ADDER_MODE=fast` suggest there's a separate adder, but it's not triggered by our test path.
- **Score: 5/10** — Preference extraction works partially.

### 7c. Tool Memory
- **Tested:** Message with `role: "tool"` and tool_call_id
- **Actual:** Stored as UserMemory type (not ToolMemory). The tool content wasn't separately classified.
- **Score: 4/10** — Tool messages stored but not semantically classified differently.

### 7d. Custom Tags/Info
- **Tested:** Adding memories with `custom_tags: ["finance", "quarterly"]` and `info: {"source_type": "web"}`
- **Expected:** Tags and info preserved in metadata, filterable in search
- **Actual:** Only `["mode:fast"]` appears in stored tags. Custom tags and info are LOST at write time.
- **This is a confirmed bug** — The `info` field metadata strip logic in `add_handler.py` filters out custom info fields to prevent confusion with system fields. Custom tags are overridden by the mode tag.
- **Score: 3/10** — Custom metadata not preserved despite being documented as working.

---

## 8. Feedback System

- **Tested:** POST `/product/feedback` with conversation history and feedback_content
- **Actual with `user_id` only (no writable_cube_ids):** 403 error — defaults to user_id as cube_id, which doesn't exist.
- **Actual with `writable_cube_ids: ["audit-alpha-cube"]`:** 200 success. Returns `{"answer": "", "record": {"add": [], "update": []}}` — empty record means no new memories were generated from the feedback in this case.
- **Finding:** Feedback endpoint works when cube IDs are provided correctly, but the response structure (empty add/update arrays) suggests feedback content may not have been novel enough to trigger extraction.
- **Score: 7/10** — Works when used correctly; cube_id defaulting bug causes confusion.

---

## 9. Scheduler

- **Tested:** GET `/product/scheduler/allstatus` and `/scheduler/task_queue_status`
- **Actual:**
  - `allstatus`: Returns scheduler_summary with all zeros (waiting, in_progress, pending, completed all = 0)
  - `task_queue_status`: 503 "Scheduler queue not connected to Redis"
  - `scheduler/wait`: Returns `{idle: true, running_tasks: 0}` immediately
- **Config:** `MOS_ENABLE_SCHEDULER=true`, `API_SCHEDULER_ON=true` but no Redis configured
- **Finding:** The scheduler is running but the Redis-based queue monitoring is unavailable. Async tasks are processed but can't be tracked via the queue API. The local queue (`MOS_SCHEDULER_CONSUME_INTERVAL_SECONDS=0.01`) works for actual processing.
- **Score: 5/10** — Functional for processing but monitoring/metrics are broken without Redis.

---

## 10. Chat Endpoint

- **Tested:** POST `/product/chat/complete` with user messages
- **Actual:** 422 error — missing `query` field. The APIChatCompleteRequest requires `query` not `messages`.
- **Config:** `ENABLE_CHAT_API=false` by default — the chat handler is `None`.
- **Finding:** Chat API is disabled in this deployment. Even if enabled, the request format differs from `/product/add`.
- **Score: 4/10** — Not enabled; format issues.

---

## 11. Authentication

### 11a. BCrypt Overhead
- **Measured:** ~1.1-1.3 seconds per request (after warmup)
- **Root cause:** BCrypt with 12 rounds × N agents = N × ~200ms per request
- **With 6 agents:** ~1.2s auth overhead on every request
- **This is a serious performance issue for production use.**
- **Score: 5/10** — Secure but prohibitively slow at scale.

### 11b. Spoof Protection
- **Tested:** Using alpha's key with beta's user_id
- **Actual:** 403 "Key authenticated as 'audit-alpha' but request claims user_id='audit-beta'. Spoofing not allowed."
- **Score: 10/10**

### 11c. Auto-Reload
- **Tested:** Added new keys to agents-auth.json, waited 3 seconds, tried the new key
- **Actual:** New key worked immediately — auto-reload is triggered on file mtime change.
- **Score: 10/10**

### 11d. Version 2 Format (BCrypt)
- The server upgraded from v1 (plaintext keys) to v2 (bcrypt hashes) at some point. The v2 format is more secure but significantly slower. The middleware correctly handles both formats.

---

## 12. Delete Memory

- **Tested:**
  - `DELETE /product/delete_memory` with `mem_cube_id` parameter → 403 (defaults to user_id as cube)
  - Same with `writable_cube_ids: ["audit-alpha-cube"]` and `memory_id` (singular) → 200 "Failed to delete memories"
  - Same with `memory_ids` (plural) → 200 "Memories deleted successfully"
- **Finding:** The delete endpoint has confusing parameter naming. `mem_cube_id` is ignored; `writable_cube_ids` is required. `memory_id` (singular) doesn't work; `memory_ids` (plural array) is required.
- **Score: 7/10** — Works when used correctly but API design is inconsistent with documented parameters.

---

## 13. Data Persistence

- **Tested:** Wrote 15+ memories, server was restarted (process ended and a new one started), re-queried.
- **Actual:** Data persists correctly — all memories survived the server restart.
- **Backend:** Neo4j (graph store) + Qdrant (vector store). Both are persistent.
- **Important caveat:** Data is NOT preserved if the Qdrant configuration changes (e.g., adding an API key changes the connection mode, making old data appear "not found" on restart failures). This caused significant confusion during our audit.
- **Score: 8/10** — Persistence is reliable when configuration is stable.

---

## 14. Edge Cases

| Case | Result |
|------|--------|
| 2-word content ("Hello world") | Stored successfully |
| URLs in content | Stored with full URL intact |
| Numbers and dates | Stored correctly, date format preserved |
| Code snippets | Stored as-is |
| HTML tags | Stored with tags intact (no sanitization) |
| JSON content | Stored as-is |
| Whitespace-only | Rejected with 400 "content must not be empty" ✓ |
| 1000-char single word | Stored correctly |
| Markdown | Not tested directly |

- **Score: 8/10** — Edge cases handled well. HTML not sanitized (could be security concern).

---

## Critical Bugs Found

### Bug 1: Qdrant+API Key SSL Handshake Failure (FIXED in source, env config issue)
- **Symptom:** Server fails to start when `QDRANT_API_KEY` is set and `QDRANT_URL` is empty/not set.
- **Root cause:** `qdrant_client` v1.17.1 assumes HTTPS when an API key is provided. The MemOS source code (`vec_dbs/qdrant.py`) already has a fix (`https=False` when using host+port), but the fix only works when the source is correctly loaded.
- **Workaround:** The fix is in the source code. Ensure server uses the patched `vec_dbs/qdrant.py`.

### Bug 2: Delete Memory API Design Confusion
- **Symptom:** `DELETE /product/delete_memory` with `mem_cube_id` parameter returns 403 (wrong cube).
- **Root cause:** The handler uses `writable_cube_ids` not `mem_cube_id`; and requires `memory_ids` (plural) not `memory_id`.
- **Impact:** Users following old API patterns will be unable to delete memories.

### Bug 3: Custom Tags/Info Not Persisted
- **Symptom:** `custom_tags` and `info` fields in add requests are not stored in memory metadata.
- **Root cause:** The add handler strips `info` fields that conflict with system fields, and custom_tags are overwritten by the mode tag.
- **Impact:** Metadata-based filtering (documented in OpenAPI spec) doesn't work for user-defined metadata.

### Bug 4: Search-Time Dedup Modes Non-Functional
- **Symptom:** `dedup: "no"`, `"sim"`, `"mmr"`, and `null` return identical results.
- **Impact:** The dedup search parameter has no observable effect.

### Bug 5: BCrypt Auth Overhead (~1.1s per request)
- **Symptom:** Every API request takes 1.1-1.3 seconds just for authentication.
- **Root cause:** BCrypt with rounds=12 is intentionally slow (security). With N=6 agents, the middleware must check up to 6 bcrypt hashes sequentially (600-1200ms) before reaching the actual memory operation.
- **Impact:** Makes all operations appear "slow" even for trivial queries. Incompatible with real-time use cases.

### Bug 6: Feedback Endpoint Cube Default
- **Symptom:** `POST /product/feedback` without `writable_cube_ids` fails with 403.
- **Root cause:** Defaults to `user_id` as cube_id, but the cube is named `{user_id}-cube`.
- **Impact:** Feedback endpoint requires explicit cube_id to function.

---

## Observations on System Design

1. **Fast mode is really "raw mode":** No extraction, no NLP, just timestamped raw text. Useful for debugging but not for semantic memory quality.

2. **Fine mode is really "expensive":** 10-50 seconds per write for any meaningful text. Not suitable for high-throughput applications. The 4000-token chunk size means large documents require multiple LLM calls.

3. **The 90% dedup threshold is aggressive.** "The Pacific Ocean covers approximately 46%" vs "about 46%" gets deduped. This is good for preventing duplicates but may lose nuance.

4. **Memory type system is partially implemented.** Dashboard shows `total_preference_nodes: 0` even after writing preference-type content. The `pref_mem` key in search results returns data but with `memory_type: None`.

5. **No Redis = no scheduler metrics.** The scheduler runs but has no visibility. `task_queue_status` returns 503.

6. **CEO cross-cube access requires explicit provisioning** (via `UserManager.add_user_to_cube()`). There's no auto-share mechanism. This is by design but must be done via the setup script, not the API.

7. **Data persistence is correct** when the server configuration is stable. The system correctly uses Qdrant (vector) + Neo4j (graph) as dual persistent stores.

8. **The `MirofishMemory` node type** appears in Neo4j (129 nodes for user `mirofish_*`) — these appear to be test/internal data from another user unrelated to the audit.

---

## Reproduction Steps for Key Findings

### To reproduce Bug 3 (custom_tags not persisted):
```bash
curl -X POST http://localhost:8001/product/add \
  -H "Authorization: Bearer <key>" \
  -d '{"user_id": "X", "writable_cube_ids": ["Y"], "messages": [{"role": "user", "content": "test"}], "custom_tags": ["my-tag"], "async_mode": "sync", "mode": "fast"}'
# Check returned memory - tags will show only ["mode:fast"], not ["my-tag", "mode:fast"]
```

### To reproduce Bug 4 (search dedup modes identical):
```bash
# Add 5 very similar sentences, then:
for dedup in no sim mmr; do
  curl -X POST http://localhost:8001/product/search \
    -d "{\"query\": \"...\", \"dedup\": \"$dedup\", \"top_k\": 10}"
  # All return same count
done
```

### To reproduce Bug 5 (bcrypt overhead):
```bash
time curl -X POST http://localhost:8001/product/search \
  -H "Authorization: Bearer ak_..." \
  -d '{"query": "test", "user_id": "X", "top_k": 1}'
# Will take 1.1-1.3 seconds even for empty cube
```
