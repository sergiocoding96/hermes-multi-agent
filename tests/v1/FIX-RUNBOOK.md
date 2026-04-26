# v1 MVP Fix Sprint — Runbook

Bootstrap the worktrees, then open **4 fresh** Claude Code Desktop sessions and paste one block per session as the FIRST message. All four sessions run in parallel; no file overlap means no merge conflicts.

For full context: `scripts/worktrees/fix-mvp/README.md`. For the per-worktree brief each session reads: `scripts/worktrees/fix-mvp/<area>/TASK.md`.

---

## Step 0 — Bootstrap (run once)

```bash
cd ~/Coding/Hermes
bash scripts/worktrees/fix-mvp/setup-fix-worktrees.sh --dry   # preview
bash scripts/worktrees/fix-mvp/setup-fix-worktrees.sh         # create
```

This creates four worktrees under `~/Coding/Hermes-wt/` (`fix-storage`, `fix-auth`, `fix-redaction`, `fix-auto-capture`) and copies the matching `TASK.md` into each.

---

## Step 1 — Open 4 sessions and paste these blocks

### A. Storage write path (Bugs 2 + 4)

```
cd ~/Coding/Hermes-wt/fix-storage && git pull --rebase
Read TASK.md and execute it end-to-end. Two bugs to fix on this branch (fix/v1-storage-resilience): the delete-leaves-Qdrant-orphans regression (start here, 2-hour fix) and the silent-data-loss-on-Qdrant/Neo4j-outage architectural fix (return 503 on dep down + durable retry queue + /health/deps). Do not touch any file outside the storage layer or the scheduler. Follow the Deliver section exactly.
```

### B. Auth + rate limiter (Bugs 1 + 5)

```
cd ~/Coding/Hermes-wt/fix-auth && git pull --rebase
Read TASK.md and execute it end-to-end. Two bugs to fix on this branch (fix/v1-auth-ratelimit): restore agents-auth.json (un-archive the provisioning script, run it, add a startup gate that refuses to start without a valid auth file) and fix the rate limiter (make Redis URL configurable, fail loud once at startup if Redis missing, fix the AgentAuthMiddleware O(N) BCrypt-loop with key-prefix lookup). Do not touch any file outside the api/middleware layer or the provisioning script. Follow the Deliver section exactly.
```

### C. Log redaction (Bug 3)

```
cd ~/Coding/Hermes-wt/fix-redaction && git pull --rebase
Read TASK.md and execute it end-to-end. One bug area on this branch (fix/v1-log-redaction): build a redactor module covering Bearer/sk-/AKIA/PEM/email/phone/JWT/card/SSN patterns; apply it pre-extraction (before MemReader sees content), post-extraction (on MemReader output), and as a logging Filter (defense in depth). Do not touch storage, middleware, or the plugin. Follow the Deliver section exactly.
```

### D. Auto-capture in the plugin

```
cd ~/Coding/Hermes-wt/fix-auto-capture && git pull --rebase
Read TASK.md and execute it end-to-end. One feature on this branch (fix/v1-auto-capture): implement the v1.0.3 auto-capture hook in the memos-toolset Hermes plugin so agents do not need explicit memos_store calls. Filter rules + local retry queue + identity-from-env. Do not touch the MemOS server source. Follow the Deliver section exactly.
```

---

## Step 2 — While the four sessions run

Each session will: branch off `origin/main`, code, test, commit, push, open a PR. Each pushes to a distinct branch; no merge conflicts between worktrees.

You don't need to babysit. Recommended check-ins:

- After ~20 minutes: each session should have read its TASK.md and committed at least the test scaffolding.
- After session reports done: review the PR; merge after spot-check.

If a session gets stuck, paste:

```
Status update? Show me the last 10 git commits on this branch and the current state of the PR. Then continue from where you left off.
```

---

## Step 3 — Merge order (when PRs are ready)

Recommended order — safest first:

1. **Merge B first** (`fix/v1-auth-ratelimit`). It's the smallest blast radius and unblocks every other audit (without `agents-auth.json`, the system is 401-on-everything).
2. **Merge C** (`fix/v1-log-redaction`). New module + thin hook points; minimal risk to anything already running.
3. **Merge A** (`fix/v1-storage-resilience`). Larger surface area; smoke-test the durable retry queue against a real Qdrant restart before merging.
4. **Merge D** (`fix/v1-auto-capture`). Plugin-side; affects agent runtime behaviour. Smoke-test with a sandbox `research-agent` session before announcing.

After all four merge:

```bash
cd ~/Coding/Hermes
git checkout main
git pull --rebase origin main
# Restart MemOS + verify smoke tests pass
```

---

## Step 4 — Re-run the blind audit (no rewrites needed)

The audit suite at `docs/write-v1.0-audit-suite` is **re-runnable as-is**. The contamination ban + throwaway profiles + surface-discovery probes mean nothing about the prompts depends on the previous run. The only thing to bump is the report-branch date.

### 4a — Bump the report branch date

Edit `tests/v1/RUNBOOK.md` and the 8 audit prompts' `### Deliver` sections. Replace `tests/v1.0-audit-reports-2026-04-26` with the new date branch — e.g. `tests/v1.0-audit-reports-2026-05-10` (or whatever date you re-run).

```bash
NEW_DATE=2026-05-10   # set this
cd ~/Coding/Hermes
git switch docs/write-v1.0-audit-suite
git pull --rebase
sed -i "s|tests/v1.0-audit-reports-2026-04-26|tests/v1.0-audit-reports-${NEW_DATE}|g" tests/v1/*.md
git add tests/v1/
git commit -m "chore(audit): bump v1 audit re-run target to ${NEW_DATE}"
git push origin docs/write-v1.0-audit-suite
git push origin docs/write-v1.0-audit-suite:tests/v1.0-audit-reports-${NEW_DATE}
```

### 4b — Open 8 fresh Claude Code sessions

Use the existing `tests/v1/RUNBOOK.md`. The 8 blocks in there now point at the new date. Same procedure as the first run — no edits to the actual audit prompts.

### 4c — Regenerate the combined PDF

After all 8 reports land:

```bash
cd ~/Coding/Hermes
git fetch origin tests/v1.0-audit-reports-${NEW_DATE}
git checkout origin/tests/v1.0-audit-reports-${NEW_DATE} -- tests/v1/reports/
# Edit /tmp/render_pdf.py to point at the new date's input/output, then:
python3 /tmp/render_pdf.py
```

---

## Expected post-fix scores

If all four worktrees ship cleanly:

| Audit | MIN before | MIN after (estimate) |
|---|---|---|
| Zero-Knowledge | 3 | **6–7** |
| Functionality | 0 | **6–7** (auto-capture lands) |
| Resilience | 2 | **5–6** |
| Performance | 1 | **5–6** |
| Data Integrity | 1 | **4–5** |
| Observability | 1 | **2** (still no `/metrics` — see optional Worktree E) |
| Plugin Integration | 1 | **6–7** |
| Provisioning | 1 | **5–6** |

- **Strict MIN-of-MINs:** 1.25 → ~2 (Observability still floors it)
- **Mean of all sub-area scores:** 5.2 → **~7** (the honest measure for MVP-readiness)

If you want the strict MIN above 4 too, run optional **Worktree E** (`/metrics` Prometheus endpoint, 1–2 days) — that lifts Observability to 4–5 and the strict MIN-of-MINs to ~4–5.

## When you are MVP-ready

- All 4 (or 5) PRs merged to main
- Re-audit MIN ≥ 4 OR mean ≥ 7 (pick the criterion you trust)
- One successful 30-minute live demo of research-agent + email-marketing-agent + CEO orchestrator with no silent failures and no secrets in logs

Then ship the MVP with a published "known limitations" page covering what was deferred (process supervisor, backup/restore, multi-machine, concurrency cliff at 5+ agents).
