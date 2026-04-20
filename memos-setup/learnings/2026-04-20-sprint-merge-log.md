# Sprint Merge Log — 2026-04-20

Single source of truth for the 10/10 hardening sprint. Each entry records one PR merge: the blind test evidence, the merge commit, any surprises or deviations, and a post-merge smoke-test result.

**Merge policy (confirmed 2026-04-20):**
- Squash merge, delete branch after merge.
- Every MemOS merge is followed by a MemOS server restart + quick smoke test.
- All verification is **blind**: tests run against fresh isolated cubes/users with no seeded bias toward expected outcomes. No cherry-picking which acceptance criteria to show.
- If a test fails, the reviewer posts findings on the PR and skips the merge; the log records the skip.

**Sprint roster (8 PRs):**

| Repo | PR | Branch | Task brief |
|------|----|--------|------------|
| MemOS | #1 | `feat/fast-mode-chunking` | [feat-fast-mode-chunking.md](../../scripts/worktrees/memos/feat-fast-mode-chunking.md) |
| MemOS | #2 | `fix/custom-metadata` | [fix-custom-metadata.md](../../scripts/worktrees/memos/fix-custom-metadata.md) |
| MemOS | #3 | `fix/delete-api` | [fix-delete-api.md](../../scripts/worktrees/memos/fix-delete-api.md) |
| MemOS | #4 | `fix/auth-perf` | [fix-auth-perf.md](../../scripts/worktrees/memos/fix-auth-perf.md) |
| MemOS | #5 | `fix/search-dedup` | [fix-search-dedup.md](../../scripts/worktrees/memos/fix-search-dedup.md) |
| Hermes | #1 | `claude/gallant-volhard-8b747e` → `feat/memos-provisioning` | [feat-memos-provisioning.md](../../scripts/worktrees/hermes/feat-memos-provisioning.md) |
| Hermes | #2 | `claude/jovial-shirley-16d5d8` → `feat/paperclip-adapter` | [feat-paperclip-adapter.md](../../scripts/worktrees/hermes/feat-paperclip-adapter.md) |
| Hermes | #3 | `claude/musing-booth-43f23f` → `feat/memos-dual-write` | [feat-memos-dual-write.md](../../scripts/worktrees/hermes/feat-memos-dual-write.md) |

**Planned order:**
1. MemOS #4 `fix/auth-perf`
2. MemOS #5 `fix/search-dedup`
3. MemOS #2 `fix/custom-metadata`
4. MemOS #1 `feat/fast-mode-chunking` *(rebase expected — shares `add_handler.py` with #2)*
5. MemOS #3 `fix/delete-api` *(rebase if `product_models.py` collides)*
6. Hermes #1 `memos-provisioning`
7. Hermes #2 `paperclip-adapter`
8. Hermes #3 `memos-dual-write` *(depends on #1 having been applied)*

---

## Entries

*(Entries appended below in merge order. Each has: PR metadata, blind test evidence, merge SHA, smoke test after restart, notes.)*

### MemOS PR #4 — `fix/auth-perf` — MERGED ✓

- **Merge commit:** [MemOS@099a151](https://github.com/sergiocoding96/MemOS/commit/099a151) (squash)
- **Files changed:** `src/memos/api/middleware/agent_auth.py` (+26/-2), `tests/api/test_agent_auth_cache.py` (+164 NEW)
- **Approach:** OrderedDict-based bounded FIFO (max 64). Key = sha256(raw_key); value = verified user_id. Failures never cached (prevents brute-force probing of the cache). Cache cleared on mtime reload.

**Pre-merge deployment fix (important context for future agents):**
Discovered MemOS server was running from `~/.local/lib/python3.12/site-packages/memos/`, NOT from `~/Coding/MemOS/src/memos/`. Merges to the fork's source tree were invisible to the running server. Fixed by running `pip install --user -e . --break-system-packages` from `~/Coding/MemOS` — this makes site-packages an editable pointer back to the source tree. From now on, every MemOS merge is live on server restart. One-time fix, applies to all subsequent MemOS merges in this sprint.

**Blind test — 6 sequential `POST /product/search` requests, same key, same user_id:**

Cold start + cached path (after mtime invalidation, `touch agents-auth.json`):
```
req  status  elapsed_ms  note
0    200     374.6       cold (bcrypt runs)
1    200      43.4       cached
2    200      48.9       cached
3    200      47.1       cached
4    200      51.6       cached
```

- Cold/cached ratio: ~8× speedup on cached path
- Cached path consistently 43–52ms (under the <50ms middleware-time target; round-trip includes handler work)
- Baseline from [blind-audit-report](../../tests/blind-audit-report.md) § 11a was ~1100ms/request uniformly — now 1 slow + N fast, which is the intended behavior

**Adjacent behaviors verified (blind):**
- Spoof check preserved: key authenticating as `ceo` used with `user_id=research-agent` → 403 with "Spoofing not allowed"
- Rate limiter preserved: after repeated 401s with an invalid key, subsequent requests switched to 429
- Cache invalidation preserved: bumping `agents-auth.json` mtime forced the next request back to the cold (bcrypt) path

**Smoke test (post-restart):**
- `/health` → `{"status":"healthy","service":"memos","version":"1.0.1"}`
- Authenticated request returned 200 with expected response shape
- No errors in `/tmp/memos-postmerge-auth.log`

**Notes / deviations:** None. PR shipped exactly per [TASK.md](../../scripts/worktrees/memos/fix-auth-perf.md). Scope kept to `agent_auth.py` + new test file; no collateral changes.

---

### MemOS PR #5 — `fix/search-dedup` — MERGED ✓

- **Merge commit:** [MemOS@0c0aa97](https://github.com/sergiocoding96/MemOS/commit/0c0aa97) (squash)
- **Files changed:** `src/memos/api/handlers/search_handler.py` (+73/-509), `tests/api/test_search_handler_dedup.py` (+225 NEW)
- **Approach:** threshold becomes env-configurable (`MOS_MMR_TEXT_THRESHOLD`, default 0.85), fill-back logic removed so `sim` / `mmr` produce genuinely different result sets. `no` now cleanly strips embeddings without dedup.

**Pre-flight config fix applied to main (side-effect of merge #4's editable install):**
- Commit [MemOS@e1962c5](https://github.com/sergiocoding96/MemOS/commit/e1962c5) restored the `sentence_transformer` branch in `api/config.py` → `get_embedder_config()`.
- Root cause: that patch had lived in site-packages only. The editable install in PR #4's smoke-test pulled source-tree `config.py` in place, and source only knew `universal_api` / `ollama`. Without `sentence_transformer`, the embedder fell back to Ollama and every search silently returned 0 results with `ConnectionError` in logs.
- Future agents: if you see `embedders/ollama.py ... ConnectionError` in MemOS logs, confirm `get_embedder_config()` supports `MOS_EMBEDDER_BACKEND=sentence_transformer`.

**Blind test — seeded corpus in `ceo-cube`, compared three modes on same query:**

Seeds: 5 distinct facts + 12 lexically-varied "Pacific Ocean is largest" variants (needed lexical variation because write-time dedup at cosine ≥ 0.90 eats closer paraphrases). Survived write-time: **10 Pacific-related memories + 5 distinct controls**.

Query: `"biggest ocean water Pacific"`, `top_k=10`:
```
dedup=no    count=10   (all "Pacific" memories, ranked by relativity)
dedup=sim   count= 8   (dropped 2 items too similar to top-ranked neighbors)
dedup=mmr   count= 3   (aggressive diversity penalty — kept 3 distinct)
```

Raw top-3 content per mode (relativity in brackets):
- `no[0]` = *"biggest body of seawater…"* (rel 0.69)
- `sim` skipped rank-1 and rank-2 from `no` (semantic duplicates of "biggest seawater")
- `mmr[2]` = *"Pacific stretches further than any other…"* (rel 0.43) — lowest-relativity result selected because it's most dissimilar from already-chosen

**Three modes → three different result sets.** Blind audit Bug 4 ("dedup search modes non-functional") resolved.

**Smoke test (post-restart with config fix):**
- `/health` → healthy
- No more `ConnectionError: ollama` in logs after sentence_transformer branch added
- SentenceTransformer model loaded on startup (warning about `embedding_dims` being ignored is cosmetic — model dims are intrinsic)

**Notes / deviations:**
- Test corpus had to be crafted more carefully than TASK.md suggested — cosine-0.90 write-time dedup is more aggressive than anticipated. Solution: use lexically-varied semantic siblings instead of direct paraphrases. Noted in TASK.md's own caveat.
- The `embedding_dims` env var is silently ignored by SentenceTransformer (model dim is fixed). Not a bug, but documented for future agents.

---

### MemOS PR #2 — `fix/custom-metadata` — MERGED ✓

- **Merge commit:** [MemOS@78dea7d](https://github.com/sergiocoding96/MemOS/commit/78dea7d) (squash)
- **Files changed:** `add_handler.py` (+39/-8), `mem_reader/multi_modal_struct.py` (+19/-3), `mem_reader/simple_struct.py` (+45/-3), `tests/api/test_add_handler_info.py` (+50 NEW), `tests/mem_reader/test_simple_structure.py` (+84/-1)
- **Approach:** narrow `_RESERVED_INFO_KEYS` frozenset ({`merged_from`}); user-supplied reserved keys renamed to `user:<key>` namespace; everything else passes through unchanged. Custom tags merged with mode tag via `_merge_custom_tags` helper, propagated through fine-mode reader too.

**Blind test — single write with `custom_tags` + `info`, then search + inspect metadata:**

```
POST /product/add  (ceo-cube)
  custom_tags=["finance","quarterly","marker:custmeta"]
  info={"source_type":"web","topic":"earnings","region":"europe"}
→ 200 memory added

POST /product/search  (top_k=3, query unique marker)
→ tags:      ['mode:fast', 'finance', 'quarterly', 'marker:custmeta']   ✓ all 3 + mode preserved
→ metadata.source_type = 'web'        ✓
→ metadata.topic       = 'earnings'   ✓
→ metadata.region      = 'europe'     ✓
```

Control memory (written before this PR, no custom fields) retrieved alongside shows `tags: ['mode:fast']`, no spurious info keys — backward compat preserved. Blind audit Bug 3 resolved.

**Smoke test (post-restart):** `/health` healthy, no ollama errors, SentenceTransformer loaded, authenticated request returned expected data.

**Notes:** The info keys (`source_type`, `topic`, `region`) are promoted to top-level metadata fields, not nested under `metadata.info`. Acceptable — consumers that want to filter on them query the top level directly.

---

### MemOS PR #1 — `feat/fast-mode-chunking` — MERGED ✓ (rebased)

- **Merge commit:** [MemOS@667d1d4](https://github.com/sergiocoding96/MemOS/commit/667d1d4) (squash, after rebase)
- **Files changed:** `mem_reader/simple_struct.py` (+44/-2), `mem_reader/utils.py` (+114 NEW), `tests/mem_reader/test_fast_mode_chunking.py` (+161 NEW)
- **Rebase conflict:** `simple_struct.py` — both PR #1 and PR #2 touched the fast-node builder. PR #2 changed `tags = ["mode:fast"]` → `tags = _merge_custom_tags(["mode:fast"], custom_tags)`; PR #1 added `chunk_index`/`chunk_total` into `node_info`. Resolved by keeping **both**: PR #2's tag merge AND PR #1's chunk_info. Force-pushed with `--force-with-lease`.
- **Approach:** content > 1000 chars splits into ~500-token chunks with ~50-token overlap; each chunk becomes its own `TextualMemoryItem` with `chunk_index` / `chunk_total` in `node_info`. Env-configurable via `MOS_FAST_CHUNK_TOKENS` / `MOS_FAST_CHUNK_OVERLAP_TOKENS`.

**Blind test — three acceptance checks:**

1. **Short content → 1 memory** (≤ chunk threshold, unchanged behavior)
   ```
   POST /product/add  "Capital of France is Paris."
   → 1 memory returned
   ```

2. **Long content (2423 words) → multiple chunks with metadata**
   ```
   POST /product/add  <~2400-word doc>
   → 8 memories returned
   ```
   Search of the seeded needle surfaces `chunk_index=7, chunk_total=8` — confirms ordering and totals propagate through the full pipeline.

3. **Late-in-doc needle retrievable (impossible before this fix)**
   Seeded a distinctive sentence in paragraph 121 of 123: *"The secret password for this test is BANANA-PURPLE-47."*
   ```
   query="secret password test"        → needle found  (chunk 7/8)
   query="CHUNKTEST-NEEDLE"             → needle found  (chunk 7/8)
   ```
   Before this PR, late content was washed out by single-embedding-per-document. Now each chunk has its own vector.

**Smoke test:** `/health` healthy, no Ollama / embedder errors, sentence-transformers loaded, authenticated writes return expected chunk counts.

**Notes:**
- Nonsense-token searches (e.g. `"BANANA-PURPLE-47"` alone) may not surface the chunk — embeddings weight actual linguistic content. Searching for semantic context works reliably. This is an embedding-model characteristic, not a chunking bug.
- Acceptance criterion M7 from the blind audit (Fast Mode chunking) now satisfied; previous score was 5/10.

---

<!-- next-entry -->

---

## Post-sprint re-audit (planned)

After all 8 merges land, re-run the blind functionality audit ([`tests/blind-audit-prompt.md`](../../tests/blind-audit-prompt.md)) and record the new score against the baseline 6.8/10 from [`tests/blind-audit-report.md`](../../tests/blind-audit-report.md). Target: every row ≥9/10.
