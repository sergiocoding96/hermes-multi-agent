# MemOS v1 Functionality Audit — 2026-04-30

**Marker:** `V1-FN-1777576075`
**Auditor:** blind audit (zero-knowledge, isolated worktree)
**Target:** MemOS server v1.0.1 at `http://localhost:8001` (`memos.api.server_api`, PID 2667993, Python 3.12)
**Throwaway agents:** `audit-v1-fn-a-1777576075` → cube `V1-FN-A-1777576075`; `audit-v1-fn-b-1777576075` → cube `V1-FN-B-1777576075`
**Source read:** `/home/openclaw/Coding/MemOS/src/memos/**`, `~/.hermes/plugins/memos-toolset/**` only.

---

## Executive summary

Of the **seven claims** the system advertises, **two are clean** (per-cube isolation under search, soft delete + recreate), **two are partly broken** (extraction language fidelity, custom `info` round-trip), and **three have at least one Critical or High defect** (silent PII redaction destroying user content, write-time dedup squashing parallel writes, contract drift in mode/dedup field naming).

**Overall functionality score = 2/10** (MIN of sub-areas, dragged down by the silent-data-loss class).

The two demo agents (`research-agent`, `email-marketing-agent`) **would not work as designed** against this system today: a research-agent emitting parallel findings will lose ≈86 % of them to write-time dedup before the user ever sees them, and any user content containing a 10-digit number (Unix timestamp, order ID, IBAN, the audit's own marker) is silently rewritten to `[REDACTED:phone]` on the way in.

---

## Findings

### F1 — `[REDACTED:phone]` silently rewrites any 10-digit run in user content
**Class:** silent-failure / data-loss
**Severity:** **Critical**
**Reproducer:**
```bash
curl -s -X POST http://localhost:8001/product/add \
  -H "Authorization: Bearer $KEY_A" -H "Content-Type: application/json" \
  -d '{"user_id":"audit-v1-fn-a-1777576075","writable_cube_ids":["V1-FN-A-1777576075"],
       "messages":[{"role":"user","content":"V1-FN-1777576075 fast probe: paella in Valencia uses bomba rice and saffron."}],
       "async_mode":"sync","mode":"fast"}'
```
**Evidence:** stored memory body =
`"user: [07:17 PM on 30 April, 2026]: V1-FN-[REDACTED:phone] fast probe: paella in Valencia uses bomba rice and saffron.\n"` — the audit's own correlation token `1777576075` is gone. A second probe confirms emails (`test@example.com → [REDACTED:email]`) and any digit run that matches `\+?\d{1,3}[\s\-.]?\(?\d{2,4}\)?[\s\-.]?\d{3,4}[\s\-.]?\d{3,4}` (`src/memos/core/redactor.py:99-103`).
**Why it matters:** the redactor's contract (file docstring) says it is for "secret redaction for logs and stored memories" with "intentionally low" false-positive cost. In practice the regex is so permissive that any Unix timestamp, RFC 822 message-id, GitHub issue reference, IBAN tail, order number, or phone-number-shaped ID becomes unrecoverable. A research agent that stores findings citing `[2024-1234567890]`-shaped DOIs or arXiv IDs will lose the citation to the bucket sentinel. Spec claim 1 ("byte-for-byte fast write") is broken.
**Remediation:** narrow `_PHONE` to require an explicit `+`, parens, or separator (no run of bare 10 digits); add an opt-out for `messages.content` redaction so user payload is preserved verbatim while logs are still scrubbed.

### F2 — Write-time dedup silently drops 43/50 parallel "distinct" writes
**Class:** dedup-error / data-loss
**Severity:** **Critical**
**Reproducer:** 50-thread fan-out of `POST /product/add` with `mode=fast`, content `f"V1FN concurrent2 seed-{i}: distinct widget {i} fact."`, after waiting one full rate-limit window so 429 is not the limiter.
**Evidence:**
- API result: `elapsed=6.99s, ok_with_data=7, ok_empty=43, non200=0, rate_limited_429=0`. All 50 returned `code: 200, "Memory added successfully"` but **43 returned `data: []`** with no signal in `message`.
- Confirmation via `/product/search top_k=50, dedup=no`: only seeds `[2, 4, 5, 7, 13, 14, 17]` survived in the cube.
- Root cause: `single_cube.py:732` runs `graph_store.search_by_embedding(threshold=0.90)` against existing memories before insert. The fast-mode raw memories share enough lexical/semantic prefix that the cosine-similarity floor of 0.90 fires for everything after the first ~7 land. There is no per-request `n_dropped` field in the response, no log line surfaced to the caller, and no audit row in SQLite — the only trace is a server-side `[DEDUP] Skipping near-duplicate` `WARNING` in the process log.
**Why it matters:** spec claim 1 is "Submit X in fast mode → row appears immediately". The contract is silently violated for any high-ingest workload (research-agent fan-out, email-marketing-agent batch sends, CEO post-turn capture under load). Spec claim 9 ("all 50 land") is broken.
**Remediation:** (a) return the dedup decision in the response (`{"data": [...stored], "deduped": [{"reason": "near-duplicate", "matched_id": "..."}]}`); (b) gate dedup behind `enable_dedup=true` per request, default off in fast mode (raw input); (c) raise the threshold to ≥ 0.95 for embedding-as-text-prefix style payloads or keep dedup fine-mode-only.

### F3 — `info` field is silently dropped on write (round-trip broken)
**Class:** contract-mismatch / data-loss
**Severity:** **High**
**Reproducer:**
```bash
curl -s -X POST http://localhost:8001/product/add ... \
  -d '{...,"info":{"project":"X","trace_id":"abc"},"custom_tags":["alpha","beta"]}'
# returns 200 with memory_id
curl -s http://localhost:8001/product/get_memory/<id> ...
```
**Evidence:** `metadata.tags` contains `["...llm-generated...", "alpha", "beta"]` (custom_tags merged correctly), but `metadata.info` is `null`. The trace_id and project key the caller sent are gone — there is no other field they were stashed under.
**Why it matters:** the audit doc and the `APIADDRequest` field documentation both promise round-trip. Any caller relying on `info` for `agent_id` / `app_id` / `source_url` (the docstring's own example) is silently dropping observability data. Spec claim 4's "structured fields ... `info` populated" is broken.
**Remediation:** persist `info` to `metadata.info` on insert and surface it in `/product/get_memory*` payloads; add a regression test in `tests/api/test_add_memory.py`.

### F4 — Spanish (and presumably any non-EN/non-ZH) input is silently translated to English
**Class:** spec-violation / extraction-error
**Severity:** Medium
**Reproducer:** `add` with content `"Quiero comprar un coche electrico antes de septiembre y mi presupuesto es 35000 euros."`, `mode=fine`.
**Evidence:** stored memory `"The user wants to buy an electric car before September 2026, with a budget of 35,000 euros..."` — extraction language is English, not Spanish. Chinese input correctly stays Chinese (`"用户喜欢..."`).
**Why it matters:** `templates/mem_reader_prompts.py` line 43–46 explicitly instructs the model: *"Always respond in the same language as the input conversation."* — but the prompt's example pair is EN/ZH only, and DeepSeek V3 falls through to English for any third language. Search recall on Spanish queries against Spanish-input memories will be partially broken (the embedding sees the English paraphrase). Spec claim 4's "language enforcement" is broken for non-EN/non-ZH locales.
**Remediation:** detect input locale and pass it explicitly to the prompt (`"Respond in {detected_locale}"`); add fixtures for ES, FR, DE, PT, JA in `tests/mem_reader/test_locale.py`.

### F5 — `mode` and `dedup` field names diverge from the audit doc / common usage
**Class:** contract-mismatch
**Severity:** Low
**Reproducer:** the audit prompt asks for search modes `no / sim / mmr`. In the live API, those are values of the **`dedup`** field (`product/search` request). The `mode` field is a `SearchMode` enum with values `fast / fine / mixture` (`memos/types/general_types.py:90`). Similarly, `add` accepts `mode: "fast"|"fine"` AND `async_mode: "sync"|"async"` — two orthogonal axes that are easy to confuse.
**Evidence:** see source above; `mode=no` returns HTTP 422 ("Input should be 'fast', 'fine' or 'mixture'").
**Why it matters:** any operator following the documented "three search modes: no / sim / mmr" hits 422; it is also confusing that `mode=fine` on `/add` triggers extraction while `mode=fine` on `/search` triggers a heavier ranker.
**Remediation:** rename `dedup` → `result_dedup` in the public schema and document the matrix `(write.mode, write.async_mode, search.mode, search.dedup)` in one table.

### F6 — Per-cube isolation is **loud** (HTTP 403), not silent zero-results
**Class:** spec-violation (positive direction)
**Severity:** **Info** (security-positive deviation)
**Reproducer:** key for user A, body `readable_cube_ids: ["V1-FN-B-..."]` → `403 Access denied: user 'audit-v1-fn-a-...' cannot read cube 'V1-FN-B-...'` (`server_router.py:_enforce_cube_access` via `single_cube` validation, `server_router.py:115-128`). Spoofing `user_id` while keeping the wrong key → `403 Key authenticated as 'audit-v1-fn-a-...' but request claims user_id='audit-v1-fn-b-...'. Spoofing not allowed.`
**Why it matters:** the audit prompt expected "zero results, not 403 (silent isolation)". The implementation is stricter than the spec — explicit refusal beats silent confusion for debugging. Logging this as a **spec-vs-impl divergence**, not a vulnerability. Cross-cube write attempts also bounce with 403 (verified at write path: `_enforce_cube_access` runs before insert).
**Remediation:** either (a) update the spec to say "loud isolation" or (b) change the router to drop the offending `cube_id` from the search set silently. Prefer (a).

### F7 — `/product/get_memory/<deleted_id>` returns HTTP 200 with `data: null`, not 404
**Class:** contract-mismatch
**Severity:** Low
**Reproducer:** `delete_memory` then `GET /product/get_memory/<id>` → `{"code": 200, "message": "Memory with ID ... not found", "data": null}`.
**Why it matters:** clients that branch on HTTP status (the Hermes plugin does — see `handlers._post`) treat this as success-with-null and may store NULL into downstream caches. `delete_memory` for a non-existent id correctly returns 404 (verified earlier in development), but the GET path is inconsistent.
**Remediation:** return `404` from the GET branch when `memory_id` is missing or soft-deleted; the response body envelope is fine.

### F8 — Auto-capture (`post_llm_call` hook in v1.0.3 plugin) — implementation review
**Class:** Info (no live execution path probed end-to-end; static review only)
**Severity:** Low
**Evidence:** `~/.hermes/plugins/memos-toolset/auto_capture.py`:
- Hook point: `post_llm_call` lifecycle hook, registered by the Hermes plugin loader at agent boot.
- Filters: `_MIN_CHARS=50` (skip turns shorter than 50 chars combined), `_NO_CAPTURE_SENTINEL="[no-capture]"`, in-memory dedup ring of last 3 captures per session (`_DEDUP_WINDOW=3`).
- Identity: read from env vars `MEMOS_API_URL/_API_KEY/_USER_ID/_CUBE_ID` at hook invocation; `_build_payload` ignores any kwargs — the LLM **cannot** override cube_id (confirmed by code inspection).
- Failure isolation: errors caught and queued via `CaptureQueue` (SQLite-backed retry), drained on next successful capture. The hook never raises.
- Trivial filter test ("what's 2+2?"): assistant response `"2+2 = 4"` is 8 chars and would be filtered by `_MIN_CHARS=50`. Combined with `User: ...\n\nAssistant: ...` formatting it can sneak past 50 chars for a 25-char user message + short reply, so the filter is not airtight against trivial Q&A.
- Failure mode (port 8001 down): `_post` returns `{"error": "connection_failed"}`, the queue gets the payload, log warns, hook returns. **Not** dropped, **not** raised.
**Remediation:** raise `_MIN_CHARS` to 200, or use a token-based filter; expose a metric (`memos_capture_skipped_total{reason}`) for production monitoring.

### F9 — Hermes plugin contract: API key never leaks to LLM
**Class:** contract-confirmed
**Severity:** Info
**Evidence:** `handlers.py:_get_config()` reads `MEMOS_API_KEY` from env on every call; `memos_store` / `memos_search` tool definitions in `plugin.yaml` only expose content/query/tags args. The schemas file (`schemas.py`) does not include any `api_key` field. The agent has no path to set or read the key. Tool args (`mode`, `tags`, `top_k`) are all clamped (`top_k = min(max(int(...), 1), 50)`). Agent-supplied `cube_id` is ignored — `_build_payload` always uses env. ✅

### F10 — Concurrent write rate limit is per-key, 100/60s sliding window
**Class:** Info
**Severity:** Low (operational)
**Evidence:** `memos/api/middleware/rate_limit.py:41` — `RATE_LIMIT=100`, `RATE_WINDOW=60`. Single key burst of 50 writes after a quiet window: 0/50 hit 429. Same burst 5 s later: 100 % 429s ("retry_after": 2). Means a research agent that writes 60 findings in one second exhausts headroom for the next minute. Combined with **F2** (silent dedup of the writes that did make it through), the loss surface is large.
**Remediation:** raise default to 600/60 for trusted agent keys; surface `X-RateLimit-Remaining` in every 200 response (currently only on 429); document the limit in `agents-auth.json` schema.

---

## CompositeCubeView (CEO multi-cube) — code-level verification

`composite_cube.py:40-77` fan-outs `search_memories` to each constituent `SingleCubeView` via a `ContextThreadPoolExecutor(max_workers=2)`, then merges the per-cube buckets. Each bucket entry already carries `cube_id` (set by `SingleCubeView.search_memories`), so the result is structurally tagged at the bucket-level (`{cube_id, memories: [...]}`). Could not exercise live: the only ROOT key on disk is the production CEO key (bcrypt-hashed; raw not held by this audit). Implementation is sound; live correctness depends on the CEO's user→cube ACL rows in `~/.memos/data/memos_users.db` (`user_cube_association`).

---

## Final summary table

| Area | Score 1-10 | Key findings |
|------|-----------|--------------|
| Fast write path | 2 | F1 (PII redactor mangles 10-digit runs in user content), F2 (parallel writes silently deduped) |
| Fine write path (MemReader extraction) | 5 | Atomic granularity OK (5 facts → 5 memories); F1 also applies; F4 locale fall-through to English |
| Async write path | 7 | API returns 88 ms; background scheduler runs fine extraction within ~8 s; OK |
| Auto-capture (v1.0.3 plugin) | 7 | F8 — sound code, identity safe, but `_MIN_CHARS=50` not airtight against trivial turns |
| Write-time dedup (cosine threshold) | 3 | Threshold=0.90 (env `MOS_DEDUP_THRESHOLD`); paraphrases at ~0.9 NOT deduped (R1 vs R4 both stored), but distinct-content prefix-shared writes ARE silently dropped (F2) |
| Cross-cube dedup boundary | 9 | Verified: same content stored independently in cube A and cube B, both rows present |
| Search `mode=fast` | 8 | Returns expected ranking, relativity score populated |
| Search `mode=fine` / `mixture` | n/t | Not exercised end-to-end (rate-limited); contract surface verified |
| Search `dedup=no/sim/mmr` | 8 | Verified: `no` → 10, `sim` → 9 (1 near-dup dropped), `mmr` → 5 (visible diversity) |
| Relativity / score threshold | 9 | 0.99→0, 0.0→full, 0.3→2 above threshold; behaves as documented |
| Per-cube isolation under search | 8 | F6 — loud 403 (security-positive), spec asks for silent zero-results |
| CompositeCubeView (CEO multi-cube) | 7 | Code-level verified; bucket-level cube_id tagging; not exercised live (no test ROOT key) |
| Custom tags + info round-trip | 4 | tags merge OK; **F3 — `info` silently dropped** |
| Delete + soft-delete | 6 | Delete works; recreate works (no dedup-vs-deleted); F7 — get-after-delete returns 200/null instead of 404 |
| Concurrent writes | 1 | F2 — 43/50 silently dropped under default config |
| Hermes plugin contract | 9 | F9 — clean: API key never reaches LLM, cube_id non-overridable |

**Overall functionality score = MIN = 1/10** (concurrent-writes data loss).

---

## Would the demo agents work today?

**No.** The two demo agents listed in `CLAUDE.md` (`research-agent`, `email-marketing-agent`) both ingest content shaped like:

- structured findings with citations carrying numeric IDs (DOIs, arXiv refs, ticket numbers) — F1 will silently rewrite these to `[REDACTED:phone]`;
- many parallel memory writes per turn (the research-coordinator's fan-out skill, the email-marketing-agent's per-recipient log) — F2 will silently drop the majority once the cosine-prefix collisions kick in;
- arbitrary `info` metadata (source URL, agent_id, app_id) — F3 drops this round-trip.

A demo recorded today would look ~OK on a single-user happy path but would visibly fail the moment the agent emitted >7 closely-shaped memories in one turn or stored a memory containing a Unix timestamp. Recommend **shipping no demo** until F1 and F2 are remediated; F3, F4, F7 can ship as Known Issues. F6, F8, F9, F10 are documentation tasks.
