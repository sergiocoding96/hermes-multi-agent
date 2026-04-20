# Migration Sprint — Product 1 (MemOS server) → Product 2 (local plugin)

Parallel worktree plan for migrating away from the MemOS server to `@memtensor/memos-local-hermes-plugin`.

**Master plan:** [memos-setup/learnings/2026-04-20-v2-migration-plan.md](../../../memos-setup/learnings/2026-04-20-v2-migration-plan.md)

## How to execute

### 1. Bootstrap the worktrees

```bash
cd ~/Coding/Hermes
bash scripts/worktrees/migration/setup-migration-worktrees.sh --dry   # preview
bash scripts/worktrees/migration/setup-migration-worktrees.sh         # create
```

### 2. Launch Stage 1 — Gate (sequential, one session)

```
New Claude Code Desktop session →
  Working directory: ~/Coding/Hermes-wt/feat-migrate-setup
  First message: paste INITIATION-PROMPT.md content
```

Wait for the session to report gate passed or failed. **Do not launch other sessions until gate is green.**

### 3. If gate passes, launch Stage 2 — Integration (3 parallel sessions)

Spawn 3 fresh Claude Code Desktop sessions, one per worktree:

| Session name (your choice) | Working directory |
|----------------------------|-------------------|
| wire-paperclip | `~/Coding/Hermes-wt/wire-paperclip-employees` |
| wire-ceo-access | `~/Coding/Hermes-wt/wire-ceo-hub-access` |
| wire-badass-skills | `~/Coding/Hermes-wt/wire-badass-skills-groundtruth` |

Paste INITIATION-PROMPT.md into each.

### 4. Launch Stage 3 — Docs (one session, writes audit suite)

After Stage 2 merges, one session:

| Session | Directory |
|---------|-----------|
| docs-v2-audits | `~/Coding/Hermes-wt/docs-write-v2-audit-suite` |

### 5. Execute Stage 4 — 10 blind audits (10 fresh sessions, NOT worktrees)

Each audit runs as a fresh Claude Code Desktop session with NO context. Paste the audit prompt from `tests/v2/` as first message. One audit per session. Save report to `tests/v2/reports/`.

### 6. Launch Stage 5 — Phase 3 (4 parallel sessions)

Independent of Stages 3+4, can run in parallel.

| Session | Directory |
|---------|-----------|
| phase3-fallback | `~/Coding/Hermes-wt/hermes-fallback-model` |
| phase3-mcp | `~/Coding/Hermes-wt/hermes-mcp-integration` |
| phase3-python-lib | `~/Coding/Hermes-wt/hermes-python-library-adapter` |
| phase3-webhook | `~/Coding/Hermes-wt/hermes-github-webhook` |

## Worktree-to-task mapping

| Worktree short name | Branch | Task brief |
|---------------------|--------|------------|
| feat-migrate-setup | `feat/migrate-setup` | [gate/migrate-setup.md](gate/migrate-setup.md) |
| wire-paperclip-employees | `wire/paperclip-employees` | [wire/paperclip-employees.md](wire/paperclip-employees.md) |
| wire-ceo-hub-access | `wire/ceo-hub-access` | [wire/ceo-hub-access.md](wire/ceo-hub-access.md) |
| wire-badass-skills-groundtruth | `wire/badass-skills-groundtruth` | [wire/badass-skills-groundtruth.md](wire/badass-skills-groundtruth.md) |
| docs-write-v2-audit-suite | `docs/write-v2-audit-suite` | [docs/write-v2-audit-suite.md](docs/write-v2-audit-suite.md) |
| hermes-fallback-model | `hermes/fallback-model` | [phase3/fallback-model.md](phase3/fallback-model.md) |
| hermes-mcp-integration | `hermes/mcp-integration` | [phase3/mcp-integration.md](phase3/mcp-integration.md) |
| hermes-python-library-adapter | `hermes/python-library-adapter` | [phase3/python-library-adapter.md](phase3/python-library-adapter.md) |
| hermes-github-webhook | `hermes/github-webhook` | [phase3/github-webhook.md](phase3/github-webhook.md) |

## The initiation prompt

Every session gets [INITIATION-PROMPT.md](INITIATION-PROMPT.md). It tells the session to read its `TASK.md`, stay on the intended branch, commit as it goes, push + open PR when done, and NOT merge (human does that on GitHub).

## What happens when a task PR is opened

1. Session announces done, push, opens PR.
2. You review on GitHub.
3. Blind tests may or may not apply to each PR:
   - Stage 1 gate: built-in smoke tests
   - Stage 2 integration: has its own acceptance criteria in each TASK.md
   - Stage 3 docs: review the 10 audit prompts for coverage + quality
   - Stage 5 Phase 3: has its own acceptance in each TASK.md
4. Merge if green; re-open or revert if not.
5. Append one entry to `memos-setup/learnings/2026-04-20-sprint-merge-log.md`.

## When to run the Stage 4 blind audits

After ALL dev worktrees (Stages 1, 2, 3, 5) are merged. Stage 4 tests the integrated system, so it has to come last.

## Timing estimate

| Stage | Sessions | Rough time per session | Parallel? |
|-------|----------|------------------------|-----------|
| 1 | 1 | 3-4 hours | no |
| 2 | 3 | 2-4 hours each | yes |
| 3 | 1 | 2-3 hours | no |
| 4 | 10 (fresh sessions, not worktrees) | 30-60 min each | yes |
| 5 | 4 | 1-3 hours each | yes |

**Wall-clock with aggressive parallelization: ~1-2 days. Sequential: ~5-7 days.**
