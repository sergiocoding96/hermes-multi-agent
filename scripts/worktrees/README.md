# Worktree Sprint — 10/10 Hardening

Goal: bring MemOS from **6.8/10** ([blind audit](../../tests/blind-audit-report.md)) and Hermes from **7.3/10** ([setup audit](../../HERMES-SETUP-AUDIT-2026-04-06.md)) to 10/10 by fixing known bugs and closing integration gaps in parallel Claude sessions.

## How it works

- One worktree = one branch = one Claude Code session.
- Each worktree contains a `TASK.md` with the gap, file to touch, acceptance criteria, and test plan.
- Sessions run in parallel tmux windows on tower (see [`TMUX-CHEATSHEET.md`](TMUX-CHEATSHEET.md)).
- No coordination needed — worktrees share `.git` but each has an isolated working tree and branch.

## Bootstrap

```bash
# Preview:
bash scripts/worktrees/setup-worktrees.sh --dry

# Create all 8 worktrees:
bash scripts/worktrees/setup-worktrees.sh
```

## Included in this batch (8 worktrees)

### MemOS fork — Phase 2 bug fixes (parallelizable, independent files)
| Brief | Branch | Fixes |
|-------|--------|-------|
| [fix-auth-perf](memos/fix-auth-perf.md) | `fix/auth-perf` | BCrypt ~1.1s/request overhead (blind audit Bug 5) |
| [fix-custom-metadata](memos/fix-custom-metadata.md) | `fix/custom-metadata` | `custom_tags` + `info` not persisted (Bug 3) |
| [fix-delete-api](memos/fix-delete-api.md) | `fix/delete-api` | Delete endpoint param confusion (Bug 2) |
| [fix-search-dedup](memos/fix-search-dedup.md) | `fix/search-dedup` | `no`/`sim`/`mmr` dedup modes identical (Bug 4) |
| [feat-fast-mode-chunking](memos/feat-fast-mode-chunking.md) | `feat/fast-mode-chunking` | Long docs stored as single embedding |

### Hermes — Phase 1 integration unblockers
| Brief | Branch | Unblocks |
|-------|--------|----------|
| [feat-memos-provisioning](hermes/feat-memos-provisioning.md) | `feat/memos-provisioning` | Cubes + shared roles for each agent (prereq for dual-write) |
| [feat-paperclip-adapter](hermes/feat-paperclip-adapter.md) | `feat/paperclip-adapter` | CEO → Hermes worker spawning |
| [feat-memos-dual-write](hermes/feat-memos-dual-write.md) | `feat/memos-dual-write` | Research output compounds in MemOS |

## Future worktrees (add when ready)

These aren't included in the bootstrap script yet. Add them by extending the arrays in [`setup-worktrees.sh`](setup-worktrees.sh) and writing a brief.

**MemOS Phase 2 remaining:**
- `fix/feedback-default` — feedback endpoint cube default (Bug 6)
- `fix/chat-endpoint` — chat API signature / enablement (Bug 7)
- `feat/preference-extraction` — wire preference memory path (M8)
- `feat/scheduler-metrics` — Redis-less queue visibility (M10)
- `feat/tool-memory-type` — tool message classification (M9)
- `feat/fine-mode-parallel` — parallelize fine-mode extraction to reduce 48s/500w latency (M11)

**Hermes Phase 3:**
- `feat/fallback-model` — add fallback_providers to config.yaml (H6)
- `feat/soft-loop` — CEO HEARTBEAT feedback handler (H4)
- `feat/hard-loop` — quality_score auto-patch loop (H5)
- `feat/mcp-integration` — connect MCP servers (H7)
- `feat/python-library-adapter` — switch Paperclip from CLI subprocess to library (H8)
- `feat/github-webhook` — PR auto-review route (H9)

## Close-out flow per worktree

When a Claude session says its task is done:

```bash
# From the worktree directory
git push -u origin <branch>
gh pr create --title "..." --body "..."

# You review on GitHub, then merge.
# After merge, clean up:
cd ~/Coding/<repo>              # main checkout
git pull
git worktree remove ~/Coding/<repo>-wt/<short-name>
git push origin --delete <branch>
```

## Scoring — how we know we hit 10/10

Re-run the blind audit ([`tests/blind-audit-prompt.md`](../../tests/blind-audit-prompt.md)) after each phase closes out. Track the score-per-area table from [`tests/blind-audit-report.md`](../../tests/blind-audit-report.md) — goal is every row at 9+/10.
