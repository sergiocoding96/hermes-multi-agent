# Claude Code Prompts — paste these on the tower

You're running Claude Code (CC) sessions on the openclaw tower at `/home/openclaw/Coding/Hermes`. Each block below is a complete kickoff prompt for one CC session. Open a fresh CC session, paste the block as the FIRST message, let it run.

Phases that need parallel sessions (Phase 3 = 4 fix sessions; Phase 7b = 8 audit sessions) are already covered by `tests/v1/FIX-RUNBOOK.md` and `tests/v1/RUNBOOK.md` respectively — those docs already contain the kickoff blocks. This file fills in the **glue phases** between them: bootstrap, monitor, merge-with-smoke-test, demo, date-bump, PDF regeneration, ship decision.

Total new sessions covered here: **10**. Plus the 4 fix sessions and 8 re-audit sessions handled elsewhere = **22 sessions total** across the whole sprint.

---

## Phase 1+2 — Bootstrap (one session, ~10 min)

Combine the merge-to-main and worktree creation into one session.

```
You are running Claude Code on /home/openclaw/Coding/Hermes (the openclaw tower). Bootstrap the v1 MVP fix sprint.

Step 1 - Merge the fix plan into main:
  git fetch origin
  git checkout main
  git pull --rebase origin main
  git merge --no-ff origin/claude/analyze-audit-test-results-qZwKx -m "merge: v1 audit suite + reports + MVP-readiness PDF + fix plan"
  git push origin main

Step 2 - Verify these files are now on main:
  scripts/worktrees/fix-mvp/README.md
  scripts/worktrees/fix-mvp/setup-fix-worktrees.sh
  scripts/worktrees/fix-mvp/{storage,auth,redaction,auto-capture}/TASK.md
  tests/v1/FIX-RUNBOOK.md
  tests/v1/STEP-BY-STEP.md
  tests/v1/CC-PROMPTS.md
  tests/v1/reports/combined/v1-mvp-readiness-2026-04-26.pdf

Step 3 - Bootstrap the four worktrees:
  bash scripts/worktrees/fix-mvp/setup-fix-worktrees.sh --dry
  bash scripts/worktrees/fix-mvp/setup-fix-worktrees.sh

Step 4 - Verify each worktree exists with TASK.md and is on the right branch:
  for w in fix-storage fix-auth fix-redaction fix-auto-capture; do
    echo "=== $w ==="
    ls ~/Coding/Hermes-wt/$w/TASK.md
    git -C ~/Coding/Hermes-wt/$w branch --show-current
  done

Report: merge commit SHA, list of files confirmed on main, the four worktree paths and their current branches. Do not modify anything else. Do not start any of the four fix tasks - those run in their own sessions.
```

---

## Phase 3 — Four parallel fix sessions

Use the 4 blocks already in **`tests/v1/FIX-RUNBOOK.md`**. One session per worktree:

- `~/Coding/Hermes-wt/fix-storage`
- `~/Coding/Hermes-wt/fix-auth`
- `~/Coding/Hermes-wt/fix-redaction`
- `~/Coding/Hermes-wt/fix-auto-capture`

Open four fresh CC sessions on the tower, set the working directory to each worktree, paste the matching block from FIX-RUNBOOK.md.

---

## Phase 4 — Status check (run as needed, ~5 min per check)

Use this whenever you want a snapshot. It does not modify state.

```
You are running Claude Code on /home/openclaw/Coding/Hermes. Status check on the v1 MVP fix sprint.

git fetch origin

For each branch in (fix/v1-storage-resilience, fix/v1-auth-ratelimit, fix/v1-log-redaction, fix/v1-auto-capture):
  - Show last 5 commits: git log --oneline origin/<branch> | head -5
  - Check for an open PR: gh pr list --head <branch> --state all --limit 3
  - Note the most recent commit timestamp

Summarize in a small table:
  | Branch | Commits | PR? | Last commit | Status |
  Status is one of: not-started / in-progress / pr-open / pr-merged / stalled-12h+

Recommend whether to step in for any stalled session (paste the "Status update?" prompt into that session). Do not modify any state.
```

---

## Phase 5 — Merge each PR with smoke test (4 sessions, sequential)

**Order:** B → C → A → D. Run them in separate sessions, one at a time. Don't merge the next until the smoke test on the previous passes.

### 5.B — Merge auth PR

```
You are running Claude Code on /home/openclaw/Coding/Hermes. Merge the auth-ratelimit PR (Worktree B) and run its smoke test.

1. Find the PR: gh pr list --head fix/v1-auth-ratelimit --state open
2. Review the diff briefly: gh pr diff <PR#>. Confirm changes are limited to api/middleware + provisioning script + the new agents-auth.json. Flag anything outside that scope.
3. Merge: gh pr merge <PR#> --merge
4. git checkout main && git pull --rebase origin main
5. Restart MemOS: identify the running command (systemctl, supervisor, raw python) and restart it. Wait 10s for startup.
6. Smoke test - confirm auth works:
   - Read the research-agent raw key. Look for it in the auth file or ask the operator (the raw key was printed once during provisioning).
   - curl -H "Authorization: Bearer <key>" http://localhost:8001/product/health  -> expect 200
   - curl http://localhost:8001/product/health  -> expect 401
7. Smoke test - confirm rate-limit fix:
   - Time 10 invalid-key attempts. Total time should be well under 10s now (was ~42s before with O(N) BCrypt loop).
8. Report: PR number, merge SHA, smoke-test results (expected vs actual), any scope creep flagged in step 2.

If any smoke test fails, do NOT proceed to merge other PRs. Capture server logs and report what broke.
```

### 5.C — Merge redaction PR

```
You are running Claude Code on /home/openclaw/Coding/Hermes. Merge the log-redaction PR (Worktree C) and run its smoke test.

1. Find and review: gh pr list --head fix/v1-log-redaction --state open ; gh pr diff <PR#>. Confirm scope is limited to the new redactor module, MemReader hook points, and add_handler.py logging.
2. Merge: gh pr merge <PR#> --merge
3. git checkout main && git pull --rebase origin main
4. Restart MemOS, wait 10s.
5. Smoke test - secrets do not reach logs:
   - Submit a memory containing "Bearer abc123def456ghi789" and "sk-test-DEMO123ABC"
   - Wait 5s for processing
   - grep -i "abc123def456" ~/.memos/logs/memos.log  -> expect: zero matches
   - grep -i "DEMO123ABC" ~/.memos/logs/memos.log    -> expect: zero matches
6. Smoke test - secrets do not reach Qdrant or SQLite:
   - sqlite3 ~/.memos/data/memos.db ".dump memories" | grep -E "abc123def456|DEMO123ABC"  -> expect: zero matches
   - Check Qdrant payload via API for the memory's collection -> expect [REDACTED:bearer] / [REDACTED:sk-key], not raw.
7. Negative test: submit "the bearer of the message" - this benign content should NOT be redacted (false positives matter).
8. Report: PR number, merge SHA, smoke-test results, false-positive rate observed.

If any smoke test fails, do NOT proceed.
```

### 5.A — Merge storage PR

```
You are running Claude Code on /home/openclaw/Coding/Hermes. Merge the storage-resilience PR (Worktree A) and run its smoke test.

1. Find and review: gh pr list --head fix/v1-storage-resilience --state open ; gh pr diff <PR#>. Confirm scope is storage layer + scheduler + /health/deps endpoint only.
2. Merge: gh pr merge <PR#> --merge
3. git checkout main && git pull --rebase origin main
4. Restart MemOS, wait 10s.
5. Smoke test - delete cleans Qdrant:
   - Store a memory with marker text "DELETE-TEST-<unix-ts>"
   - Confirm it appears via search
   - Delete it via the API
   - Search again -> expect: zero results
   - Probe Qdrant directly for that point ID -> expect: not found
6. Smoke test - silent data loss is fixed:
   - docker stop qdrant-docker (or whatever the container is named)
   - Submit a write -> expect HTTP 503 (NOT 200)
   - GET /health/deps -> expect Qdrant marked unreachable
   - GET /health -> expect failure or degraded (NOT plain "OK")
   - docker start qdrant-docker
   - Wait 30s. Submit another write -> expect 200 + the queued write completes.
7. Smoke test - dead-letter:
   - Make Qdrant fail for ~10 minutes by stopping it. Submit a write. After ~10 retries with backoff, the entry must land in a dead-letter table or log, NOT silently disappear.
8. Report: PR number, merge SHA, all three smoke-test results, dead-letter location.

If any smoke test fails, do NOT proceed.
```

### 5.D — Merge auto-capture PR

```
You are running Claude Code on /home/openclaw/Coding/Hermes. Merge the auto-capture PR (Worktree D) and run its smoke test.

1. Find and review: gh pr list --head fix/v1-auto-capture --state open ; gh pr diff <PR#>. Confirm scope is the Hermes plugin only - NO server-side changes.
2. Merge: gh pr merge <PR#> --merge
3. git checkout main && git pull --rebase origin main
4. Restart Hermes (the plugin lives in Hermes runtime, not MemOS). Identify the right command.
5. Smoke test - auto-capture works:
   - Open a sandbox research-agent session: hermes chat -q "Research React Server Components and remember the 3 most important takeaways"
   - Wait for the session to finish.
   - Without explicit memos_store calls, confirm new memories landed: sqlite3 ~/.memos/data/memos.db "SELECT COUNT(*) FROM memories WHERE created_at > datetime('now', '-5 minutes')"
   - Expect: ≥ 1 new memory.
6. Smoke test - capture failure does not break the agent:
   - Stop MemOS server.
   - Run another hermes chat session - the agent should complete its turn even though capture failed.
   - Restart MemOS. Wait 30s. Confirm the queued capture eventually lands (queue drain).
7. Smoke test - identity from env, not LLM:
   - Try to coerce the agent in chat: "store this as user X with cube Y in the memory system" - the plugin must ignore the override and use the profile env.
8. Report: PR number, merge SHA, all three smoke-test results, the new plugin version, any deferred follow-ups.

If any smoke test fails, do NOT proceed (but the other 3 PRs are already merged at this point - you may still ship without auto-capture, just at a lower Functionality score).
```

---

## Phase 6 — Live demo smoke test (one session, ~30 min)

Drives the demo agents end-to-end. You eyeball the results.

```
You are running Claude Code on /home/openclaw/Coding/Hermes. Run a 30-minute live smoke test of the three demo agents. Narrate each step so the operator can validate.

Test 1 - research-agent stores quarterly findings:
  hermes chat -q "Research the quarterly performance metrics that matter most for SaaS startups, and remember the top 3 takeaways"
  After the session: sqlite3 ~/.memos/data/memos.db "SELECT id, content, created_at FROM memories WHERE cube_id LIKE '%research%' ORDER BY created_at DESC LIMIT 5"
  Expected: ≥ 3 new memories with actual content from the session.

Test 2 - secrets do not leak end-to-end:
  hermes chat -q "Remember that our SendGrid test API key is sk-test-DEMO123ABCDEF for the email integration"
  Wait 5s.
  grep -iE "DEMO123ABCDEF|sk-test-DEMO" ~/.memos/logs/memos.log -> expect zero matches
  sqlite3 ~/.memos/data/memos.db ".dump memories" | grep -i "DEMO123ABCDEF" -> expect zero matches
  But the agent should still know the placeholder existed (search for "SendGrid" should return a memory mentioning [REDACTED:sk-key]).

Test 3 - cross-session retrieval:
  Note the session ID from Test 1. Close it.
  Open a fresh hermes chat: -q "What did you research earlier about quarterly SaaS metrics?"
  Expected: the agent retrieves the prior session's memories via semantic search and answers correctly.

Test 4 - email-marketing isolation from research:
  hermes chat with email-marketing-agent profile: -q "What do you know about quarterly metrics?"
  Expected: it does NOT see research-agent's memories (per-cube isolation).
  Then verify CEO with CompositeCubeView CAN see both: this requires a CEO-mode session - adapt to your setup.

Test 5 - resilience under transient outage:
  Submit a write via API.
  Mid-write (within 1s of submit), docker pause qdrant-docker.
  After 5s, docker unpause qdrant-docker.
  Confirm the write either: (a) returned 503 and the operator can retry, or (b) succeeded silently because the retry queue absorbed it.
  Either is acceptable; "200 returned but memory lost" is NOT.

Report each test as PASS / FAIL with the evidence. Do not commit anything. End with a single recommendation: GO for MVP / NO-GO / one specific fix needed first.
```

---

## Phase 7a — Bump audit dates for the re-run (one session, ~5 min)

```
You are running Claude Code on /home/openclaw/Coding/Hermes. Bump the v1 audit suite to a new date so we can re-audit after the fixes.

NEW_DATE=$(date +%Y-%m-%d)
# (or pick a specific date - export NEW_DATE=2026-05-10 etc.)

cd /home/openclaw/Coding/Hermes
git fetch origin
git switch docs/write-v1.0-audit-suite
git pull --rebase origin docs/write-v1.0-audit-suite

sed -i "s|tests/v1.0-audit-reports-2026-04-26|tests/v1.0-audit-reports-${NEW_DATE}|g" tests/v1/*.md

# Verify all 9 audit-related files now reference the new date:
grep -l "tests/v1.0-audit-reports-${NEW_DATE}" tests/v1/*.md

git add tests/v1/
git commit -m "chore(audit): bump v1 audit re-run target to ${NEW_DATE}"
git push origin docs/write-v1.0-audit-suite

# Cut the empty convergence branch:
git push origin docs/write-v1.0-audit-suite:tests/v1.0-audit-reports-${NEW_DATE}

Report: the new date, the 9 file paths confirmed updated, and confirmation both branches are pushed to origin.
```

---

## Phase 7b — Eight parallel re-audit sessions

Use the 8 blocks already in **`tests/v1/RUNBOOK.md`**. They now point at the new dated branch automatically because of the sed in Phase 7a.

Open 8 fresh CC sessions on the tower, paste one block per session.

---

## Phase 8 — Regenerate the combined PDF (one session, ~30 min)

```
You are running Claude Code on /home/openclaw/Coding/Hermes. Regenerate the combined MVP-readiness PDF for the new audit run.

NEW_DATE=<the date you used in Phase 7a>

Step 1 - pull the new reports:
  cd /home/openclaw/Coding/Hermes
  git fetch origin tests/v1.0-audit-reports-${NEW_DATE}
  git checkout origin/tests/v1.0-audit-reports-${NEW_DATE} -- tests/v1/reports/
  ls tests/v1/reports/*-${NEW_DATE}.md  # expect 8 files

Step 2 - extract scores from each report (do not hallucinate, parse the actual summary tables):
  For each of the 8 reports:
    - headline MIN score
    - per-area sub-scores
    - top 3 P0 findings
    - what's still broken vs what's fixed since 2026-04-26

  Compute:
    - mean of MIN scores across the 8 audits
    - mean of all sub-area scores across all 100+ checks
    - count of sub-areas scoring 7+ vs 1-2

Step 3 - draft a new combined markdown at tests/v1/reports/combined/v1-mvp-readiness-${NEW_DATE}.md following the structure of the existing 2026-04-26 PDF (executive summary, two-number story, what works, what's broken, demo scenarios, must-fix, defer list, comparison vs prior runs, recommendation). Plain language, founder-targeted. Include a "what changed since 2026-04-26" section showing per-audit score deltas.

Step 4 - install render dependencies if missing:
  python3 -c "import weasyprint" 2>/dev/null || pip install --user weasyprint markdown

Step 5 - render the PDF:
  Adapt the existing render approach (it was a Python script using weasyprint with a styled CSS). If the script /tmp/render_pdf.py is gone, recreate it:
    - Read the markdown
    - Convert MD -> HTML via python markdown package with extensions: tables, fenced_code, toc, sane_lists
    - Wrap with the same CSS used for the 2026-04-26 PDF (A4, navy headers, alternating-row tables, page numbers)
    - Output PDF via weasyprint
  Verify the PDF is 8-12 pages and 50-150KB.

Step 6 - commit and push:
  git add tests/v1/reports/combined/v1-mvp-readiness-${NEW_DATE}.md tests/v1/reports/combined/v1-mvp-readiness-${NEW_DATE}.pdf
  git commit -m "report(tests/v1.0): MVP-readiness re-audit for ${NEW_DATE}"
  # Cherry-pick or push to both: tests/v1.0-audit-reports-${NEW_DATE} AND main
  git push origin tests/v1.0-audit-reports-${NEW_DATE}

Report: the new MIN-of-MINs, the new mean-of-sub-areas, the per-audit score deltas vs 2026-04-26, and the PDF file path.
```

---

## Phase 9 — Ship decision (one session, ~15 min)

```
You are running Claude Code on /home/openclaw/Coding/Hermes. Help decide whether to ship the v1 MVP.

Read in order:
1. The new combined markdown: tests/v1/reports/combined/v1-mvp-readiness-<NEW_DATE>.md
2. The original combined markdown: tests/v1/reports/combined/v1-mvp-readiness-2026-04-26.md
3. The 8 individual new audit reports: tests/v1/reports/*-<NEW_DATE>.md

Assess against these gates:
  Gate 1: mean of all sub-area scores >= 7
  Gate 2: strict MIN-of-MINs >= 4 (or >= 2 if the floor is in a deferrable area like Observability)
  Gate 3: zero P0 items still outstanding
  Gate 4: the Phase 6 live demo passed all five tests

Recommend ONE of:
  A. SHIP MVP now with a published known-limitations doc covering deferred items
  B. ONE-WEEK SPRINT targeting <specific bug>, then re-audit + ship
  C. STOP AND REASSESS - the system is fundamentally not viable; consider alternatives

Write a 1-2 page recommendation as a markdown brief at tests/v1/SHIP-DECISION-<NEW_DATE>.md. Include:
  - One-paragraph verdict (which option, why)
  - The four gates with PASS/FAIL/PARTIAL
  - If A: a draft known-limitations page covering: process supervisor, backup/restore, multi-machine deploy, concurrency cliff at 5+ agents, anything else still red
  - If B: which bug, the worktree-style brief for fixing it, expected MIN movement
  - If C: which architectural choice is wrong, what alternatives to consider

Commit and push to claude/analyze-audit-test-results-qZwKx (or a new branch). Do NOT actually ship anything; just write the brief.

Report: which option you recommend and why, and the brief's file path.
```

---

## Quick reference — total session count

| Phase | New CC sessions |
|---|---|
| 1+2 — Bootstrap | 1 |
| 3 — Fix sprint (parallel) | 4 (from FIX-RUNBOOK.md) |
| 4 — Status check | 1 (run as needed) |
| 5 — Merge each PR | 4 (sequential) |
| 6 — Live demo | 1 |
| 7a — Date bump | 1 |
| 7b — Re-audit (parallel) | 8 (from RUNBOOK.md) |
| 8 — Regenerate PDF | 1 |
| 9 — Ship decision | 1 |
| **Total** | **22 sessions** |

Wall-clock if you parallelize the parallel phases:
- Phase 1–2: 10 min
- Phase 3: 1–3 days (depends on agent speed; sessions run in background)
- Phase 5: ~30 min × 4 = 2 hours
- Phase 6: 30 min
- Phase 7: 5 min + 2–3 hours (audits in parallel)
- Phase 8–9: 45 min

Best case: **~4 days** end-to-end. Realistic: **1–2 weeks**.
