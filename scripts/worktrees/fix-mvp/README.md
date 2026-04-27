# MVP Fix Sprint — make v1 ship-ready in 1–2 weeks

Parallel-worktree plan for the **5 must-fix items** from the v1 MVP-readiness report (`tests/v1/reports/combined/v1-mvp-readiness-2026-04-26.pdf`).

Four worktrees run in parallel. Each is a self-contained brief — paste one kickoff block per fresh Claude Code session and let it run to completion.

## The four worktrees — repo split

The bugs span **two repos** because the v1 stack is split:

- **Hermes** (`/home/openclaw/Coding/Hermes`, GitHub: `sergiocoding96/hermes-multi-agent`) — provisioning scripts, profile envs, the `memos-toolset` plugin
- **MemOS** (`/home/openclaw/Coding/MemOS`) — the actual server source under `src/memos/...`

Each TASK.md banner specifies exactly which repo its agent edits in. The setup script creates Hermes-side worktrees as project-management artifacts; agents whose work is MemOS-side then create their own MemOS worktree from the MemOS repo (the TASK.md banner has the exact `git worktree add` command).

| # | Worktree (briefing dir) | Branch | Repo for code edits | Bugs fixed | Effort |
|---|---|---|---|---|---|
| A | `fix-storage` | `fix/v1-storage-resilience` | **MemOS** | Bug 2 (silent data loss on dep outage), Bug 4 (delete leaves Qdrant orphans) | 2–3 days |
| B | `fix-auth` | `fix/v1-auth-ratelimit` | **BOTH** (Hermes for script-restoration + chmod; MemOS for startup gate + rate limiter) | Bug 1, Bug 5 | 1–2 days |
| C | `fix-redaction` | `fix/v1-log-redaction` | **MemOS** | Bug 3 (secrets in logs + secrets in extracted memories) | 1 day |
| D | `fix-auto-capture` | `fix/v1-auto-capture` | **Hermes** (un-archive `deploy/plugins/_archive/memos-toolset` first) | Functionality MIN driver | 2–3 days |

These four together address every P0 from the audit synthesis. Worktree B opens **two PRs** (one per repo); the others open one PR each, totaling **5 PRs**. **Zero file overlap between any two worktrees** → no merge conflicts during parallel work.

## Quick start

```bash
cd ~/Coding/Hermes
bash scripts/worktrees/fix-mvp/setup-fix-worktrees.sh --dry   # preview
bash scripts/worktrees/fix-mvp/setup-fix-worktrees.sh         # create
```

Then open four fresh Claude Code Desktop sessions, one per worktree. For each session:

1. Set working directory to the worktree path printed by the setup script (e.g. `~/Coding/Hermes-wt/fix-storage`).
2. Paste the matching kickoff block from `tests/v1/FIX-RUNBOOK.md` as the FIRST message.
3. Let the session run to completion. It will branch, code, commit, and push.

## Order

All four can run in parallel. **No dependency between them** at the source-edit level — each worktree owns its own files.

**One operational dependency:** Worktree D (auto-capture) needs `agents-auth.json` to exist for its smoke test to pass; that file comes from B's Hermes-side PR. So:

- D's code work can start any time.
- D's smoke test should run **after** B's Hermes-side PR merges.

If you must serialize for cost reasons:
- **First:** B (`fix-auth`) — fastest fix, unblocks every other audit (without `agents-auth.json` the system is 401-on-everything)
- **Then:** A, C, D in any order

## What this sprint delivers

After all four worktrees merge:

| Audit | MIN before | MIN after (estimate) |
|---|---|---|
| Zero-Knowledge | 3 | **6–7** (log redaction, file perms) |
| Functionality | 0 | **6–7** (auto-capture exists; MIN now driven by `info` round-trip at 5) |
| Resilience | 2 | **5–6** (silent data loss fixed; process supervisor still missing) |
| Performance | 1 | **5–6** (rate limiter fixed; 5+ agent concurrency cliff still open) |
| Data Integrity | 1 | **4–5** (delete cleanup; no backup procedure yet) |
| Observability | 1 | **2** (redaction helps; no `/metrics` yet — see optional Worktree E below) |
| Plugin Integration | 1 | **6–7** (auth file restored, auto-capture exists) |
| Provisioning | 1 | **5–6** (script restored; key rotation still undocumented) |

**Strict MIN-of-MINs:** 1.25 → ~2 (still pulled down by Observability)
**Mean of all sub-area scores:** 5.2 → **~7** (the honest MVP-readiness measure)

If you want the strict MIN above 4 too, add **optional Worktree E** below.

## Optional Worktree E — `/metrics` endpoint

Adds a Prometheus-compatible `/metrics` route that exposes 6–8 counters/histograms. Fix lifts Observability MIN from 1 to 4–5, which lifts the strict MIN-of-MINs from 2 to **4–5**. Effort: 1–2 days. Recommended if you have headcount; skip if you don't.

## Re-auditing after the fixes land

**You re-run the same blind audit suite — no rewrites needed.** The audit prompts on `docs/write-v1.0-audit-suite` are designed for re-runnability:

- Each prompt forbids reading prior reports (contamination ban).
- Each uses a throwaway profile (`MEMOS_HOME=/tmp/memos-v1-audit-<uuid>`) so no state carries over.
- Probes ask the auditor to discover surfaces — no hard-coded file paths to break when fixes change source.

The only change for the re-run: bump the report-branch date in `tests/v1/RUNBOOK.md`. E.g. for a 2026-05-10 re-run, change `tests/v1.0-audit-reports-2026-04-26` → `tests/v1.0-audit-reports-2026-05-10` everywhere it appears in the RUNBOOK and in each audit prompt's Deliver section. Then push to a fresh convergence branch and dispatch the 8 sessions exactly as before.

After the re-run, regenerate the combined PDF the same way:

```bash
python3 /tmp/render_pdf.py   # adjust input/output paths to the new date
```

## Files in this directory

- `README.md` — this file
- `setup-fix-worktrees.sh` — automation
- `storage/TASK.md`, `auth/TASK.md`, `redaction/TASK.md`, `auto-capture/TASK.md` — per-worktree briefs
- (See `tests/v1/FIX-RUNBOOK.md` for the copy-paste kickoff blocks)
