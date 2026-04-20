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

<!-- next-entry -->

---

## Post-sprint re-audit (planned)

After all 8 merges land, re-run the blind functionality audit ([`tests/blind-audit-prompt.md`](../../tests/blind-audit-prompt.md)) and record the new score against the baseline 6.8/10 from [`tests/blind-audit-report.md`](../../tests/blind-audit-report.md). Target: every row ≥9/10.
