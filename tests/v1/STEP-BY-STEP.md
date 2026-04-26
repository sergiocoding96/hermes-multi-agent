# v1 MVP Fix — Step by Step

You are here:
- **Done:** v2 audit, v1 audit, MVP-readiness PDF, 4-worktree fix plan committed
- **Next:** execute the fix sprint, re-audit, regenerate the PDF, decide on shipping the MVP

This doc is the runbook from "fix plan committed" to "MVP shipped or not".

---

## Phase 0 — Prerequisites (5 min check)

You need:

- A shell on the box where MemOS runs — typically `/home/openclaw/Coding/Hermes` (the audit-runner box)
- Claude Code Desktop installed and signed in
- ~$30–$80 of Anthropic credit for the fix sprint (4 parallel sessions × 1–2 weeks of agent work)
- A separate ~$10–$30 for the re-audit (8 parallel sessions × 2–3 hours)
- Push permission to `sergiocoding96/hermes-multi-agent` on `main`

If any of those are missing, sort them now. Don't start the sprint and stall halfway.

---

## Phase 1 — Land the fix plan on `main` (one-time, ~5 min)

The fix plan currently lives on `claude/analyze-audit-test-results-qZwKx`. The worktrees need it on `main` so they branch from the latest server code AND find their TASK.md briefs. Merge it.

```bash
cd ~/Coding/Hermes
git fetch origin
git checkout main
git pull --rebase origin main
git merge --no-ff origin/claude/analyze-audit-test-results-qZwKx \
  -m "merge: v1 audit suite + reports + MVP-readiness PDF + fix plan"
git push origin main
```

Verify the merge landed:

```bash
ls scripts/worktrees/fix-mvp/                  # README.md + 4 TASK.md dirs + setup script
ls tests/v1/reports/combined/                  # PDF + source MD
cat tests/v1/FIX-RUNBOOK.md | head -20         # sanity check
```

If all three show files, you're good.

---

## Phase 2 — Bootstrap the 4 worktrees (one-time, ~1 min)

```bash
cd ~/Coding/Hermes
bash scripts/worktrees/fix-mvp/setup-fix-worktrees.sh --dry   # preview
bash scripts/worktrees/fix-mvp/setup-fix-worktrees.sh         # create
```

Confirm the four worktree directories exist:

```bash
ls ~/Coding/Hermes-wt/
# expect: fix-storage  fix-auth  fix-redaction  fix-auto-capture
```

Each worktree has its own `TASK.md` at the root, copied from the briefs. Each is checked out on its own branch off `origin/main`.

---

## Phase 3 — Dispatch the 4 fix sessions (2–4 hours of your time, 1–2 weeks of agent time)

Open **four fresh** Claude Code Desktop sessions. Use a fresh window each time (no shared context with the audit sessions or with each other).

For each session:

1. Set the working directory to one of the four worktree paths.
2. Paste the matching block from `tests/v1/FIX-RUNBOOK.md` as the FIRST message.
3. Hit enter and walk away.

The four kickoff blocks (also in `FIX-RUNBOOK.md`):

### Session A — Storage

```
cd ~/Coding/Hermes-wt/fix-storage && git pull --rebase
Read TASK.md and execute it end-to-end. Two bugs to fix on this branch (fix/v1-storage-resilience): the delete-leaves-Qdrant-orphans regression (start here, 2-hour fix) and the silent-data-loss-on-Qdrant/Neo4j-outage architectural fix (return 503 on dep down + durable retry queue + /health/deps). Do not touch any file outside the storage layer or the scheduler. Follow the Deliver section exactly.
```

### Session B — Auth

```
cd ~/Coding/Hermes-wt/fix-auth && git pull --rebase
Read TASK.md and execute it end-to-end. Two bugs to fix on this branch (fix/v1-auth-ratelimit): restore agents-auth.json (un-archive the provisioning script, run it, add a startup gate that refuses to start without a valid auth file) and fix the rate limiter (make Redis URL configurable, fail loud once at startup if Redis missing, fix the AgentAuthMiddleware O(N) BCrypt-loop with key-prefix lookup). Do not touch any file outside the api/middleware layer or the provisioning script. Follow the Deliver section exactly.
```

### Session C — Redaction

```
cd ~/Coding/Hermes-wt/fix-redaction && git pull --rebase
Read TASK.md and execute it end-to-end. One bug area on this branch (fix/v1-log-redaction): build a redactor module covering Bearer/sk-/AKIA/PEM/email/phone/JWT/card/SSN patterns; apply it pre-extraction (before MemReader sees content), post-extraction (on MemReader output), and as a logging Filter (defense in depth). Do not touch storage, middleware, or the plugin. Follow the Deliver section exactly.
```

### Session D — Auto-capture

```
cd ~/Coding/Hermes-wt/fix-auto-capture && git pull --rebase
Read TASK.md and execute it end-to-end. One feature on this branch (fix/v1-auto-capture): implement the v1.0.3 auto-capture hook in the memos-toolset Hermes plugin so agents do not need explicit memos_store calls. Filter rules + local retry queue + identity-from-env. Do not touch the MemOS server source. Follow the Deliver section exactly.
```

**If you want to save cost, run these serially instead** — start B first (fastest, unblocks everything else), then C, A, D in sequence. Each takes 1–3 days. Total wall-clock: ~1 week serial vs ~3 days parallel.

---

## Phase 4 — Monitor while sessions run (light-touch, daily)

You don't need to babysit. Check in once a day:

```bash
cd ~/Coding/Hermes
git fetch origin
git log --oneline origin/fix/v1-storage-resilience      | head -5
git log --oneline origin/fix/v1-auth-ratelimit          | head -5
git log --oneline origin/fix/v1-log-redaction           | head -5
git log --oneline origin/fix/v1-auto-capture            | head -5
```

If a session has been silent for 12+ hours, it's probably stuck. Open it and paste:

```
Status update? Show me the last 10 git commits on this branch and the current state of the PR. Then continue from where you left off.
```

Each session opens a PR when done. Watch for the four PRs to appear.

---

## Phase 5 — Merge the PRs in safe order (~30 min per PR)

When a PR is ready, review the diff yourself (or have a code reviewer do it). Then merge in this order — safest first:

### 5.1 — Merge B (`fix/v1-auth-ratelimit`) first

This unblocks every other audit (the system is currently 401-on-everything because `agents-auth.json` is missing).

```bash
# After merging B's PR via the GitHub UI:
cd ~/Coding/Hermes
git checkout main
git pull --rebase origin main
# Restart MemOS
sudo systemctl restart memos   # or whatever your restart command is
# Smoke test:
curl -H "Authorization: Bearer <your-research-agent-key>" http://localhost:8001/product/health
# expect 200
```

If that 200 lands, B is good.

### 5.2 — Merge C (`fix/v1-log-redaction`)

```bash
# After PR merged:
git pull --rebase origin main
sudo systemctl restart memos
# Smoke test: store a memory containing "Bearer abc123def456"
curl -X POST -H "Authorization: Bearer <key>" \
  -d '{"content":"test Bearer abc123def456ghi789"}' \
  http://localhost:8001/product/memories
# Then check the log file:
grep -i "abc123def456" ~/.memos/logs/memos.log
# expect: NO match (the secret was redacted before reaching the log)
```

### 5.3 — Merge A (`fix/v1-storage-resilience`)

```bash
# After PR merged:
git pull --rebase origin main
sudo systemctl restart memos
# Smoke test: stop Qdrant, submit a write
docker stop qdrant-docker
curl -X POST -H "Authorization: Bearer <key>" \
  -d '{"content":"test resilience"}' \
  http://localhost:8001/product/memories
# expect: HTTP 503, not 200
docker start qdrant-docker
# Wait 30s, then submit again — expect 200 + the queued write completes
```

### 5.4 — Merge D (`fix/v1-auto-capture`)

```bash
# After PR merged:
git pull --rebase origin main
# Restart Hermes (the plugin is on Hermes side, not MemOS):
hermes restart    # or your restart command
# Smoke test: open a sandbox research-agent session, ask it to remember 3 things
hermes chat -q "Research React server components and remember the key takeaways"
# Then in a fresh session:
hermes chat -q "What did you find out about React server components?" --skill research-coordinator
# expect: the agent recalls the prior session's findings via memory, NOT via context
```

If all four smoke tests pass, you're MVP-functional.

---

## Phase 6 — Live demo smoke test (30 min)

Run a real 30-minute live demo of the three demo agents. You're looking for:

- **No silent failures.** Every memory you ask the agents to store actually gets stored.
- **No secrets in logs.** Submit a memory containing a fake API key; verify it doesn't land in `~/.memos/logs/memos.log` raw.
- **Memory-reads-back-from-fresh-session.** Close a session, open a new one, ask the agent about something it stored earlier. It should retrieve it.
- **CEO can read across both worker cubes.** Ask CEO a question that requires synthesizing research-agent + email-marketing-agent memories. It should answer correctly.

If all four pass, you have an MVP-grade system. If any fail, file a bug, decide whether it's a launch-blocker or a known-limitation, and proceed accordingly.

---

## Phase 7 — Re-run the blind audit (parallel, 2–3 hours wall clock)

Same suite as before. The contamination ban + throwaway profiles + surface-discovery probes mean nothing about the prompts depends on the previous run. Only the report-branch date changes.

### 7.1 — Bump the date in the audit prompts

```bash
NEW_DATE=$(date +%Y-%m-%d)   # or pick a specific date like 2026-05-10
cd ~/Coding/Hermes
git switch docs/write-v1.0-audit-suite
git pull --rebase
sed -i "s|tests/v1.0-audit-reports-2026-04-26|tests/v1.0-audit-reports-${NEW_DATE}|g" \
  tests/v1/*.md
git add tests/v1/
git commit -m "chore(audit): bump v1 audit re-run target to ${NEW_DATE}"
git push origin docs/write-v1.0-audit-suite
# Cut the empty convergence branch:
git push origin docs/write-v1.0-audit-suite:tests/v1.0-audit-reports-${NEW_DATE}
```

### 7.2 — Open 8 fresh Claude Code sessions

Use the existing `tests/v1/RUNBOOK.md`. Same 8 blocks as the first run — they now point at the new date branch. One block per session, fresh window each time, no CLAUDE.md context.

The 8 sessions can all run in parallel. Each pushes to the same convergence branch and rebases on conflict. After 2–3 hours, all 8 reports are in.

### 7.3 — Pull the reports locally

```bash
cd ~/Coding/Hermes
git fetch origin tests/v1.0-audit-reports-${NEW_DATE}
git checkout origin/tests/v1.0-audit-reports-${NEW_DATE} -- tests/v1/reports/
ls tests/v1/reports/*-${NEW_DATE}.md
# expect 8 files
```

---

## Phase 8 — Regenerate the combined PDF (~5 min)

```bash
cd ~/Coding/Hermes
# If render_pdf.py isn't around, recreate it from the previous run.
# Edit it to point at the new date's input/output:
sed -i "s|2026-04-26|${NEW_DATE}|g" /tmp/render_pdf.py
python3 /tmp/render_pdf.py
ls -la tests/v1/reports/combined/v1-mvp-readiness-${NEW_DATE}.pdf
```

The PDF will follow the same structure as the first one but with new scores reflecting the fixes. Open it and look at:

- **Mean of all sub-area scores** — should be ≥ 7 (was 5.2)
- **Strict MIN-of-MINs** — should be ≥ 2 (was 1.25); ≥ 4 if you also did optional Worktree E (`/metrics`)
- **Per-audit MINs** — should match or beat the estimates in `FIX-RUNBOOK.md` Phase 4

---

## Phase 9 — The decision

After the new PDF is in front of you:

| Result | Decision |
|---|---|
| Mean ≥ 7 AND MIN ≥ 4 | **Ship MVP** with a published "known limitations" page |
| Mean ≥ 7 AND MIN < 4 | **Ship MVP** if the bug pulling MIN down is in a deferrable area (e.g. Observability) and document it loudly |
| Mean 5–7 | **Triage** the remaining low scorers; one more 1-week sprint targeting them |
| Mean < 5 | **Stop and reassess** — the fixes didn't hold. Probably need to look at architectural choices |

---

## Reality checks along the way

- If a fix session goes dark for 12+ hours, that's the signal to step in. Sometimes agents get into a loop. Restart the session with the "status update" prompt.
- If two PRs touch the same file (they shouldn't with this split, but if they do), merge the smaller one first and rebase the second.
- The smoke tests in Phase 5 are non-negotiable. Don't merge a PR if the smoke test fails — even if the agent's own tests pass. The smoke test is closer to what your demo will hit.
- The live demo in Phase 6 is the actual MVP gate. The audit is a number; the demo is the thing customers see. If the demo doesn't work, the audit score doesn't matter.

---

## When you are done

You should have:

- All 4 PRs merged to `main`
- A passing 30-minute live demo
- A new combined PDF showing scores in the green band
- A published "known limitations" page for whatever you didn't fix this sprint

That's MVP-ready.
