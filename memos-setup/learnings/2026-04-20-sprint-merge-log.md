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

<!-- next-entry -->

---

## Post-sprint re-audit (planned)

After all 8 merges land, re-run the blind functionality audit ([`tests/blind-audit-prompt.md`](../../tests/blind-audit-prompt.md)) and record the new score against the baseline 6.8/10 from [`tests/blind-audit-report.md`](../../tests/blind-audit-report.md). Target: every row ≥9/10.
