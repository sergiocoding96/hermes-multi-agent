# Migration Plan — Product 1 (MemOS server) → Product 2 (local plugin)

**Date started:** 2026-04-20
**Branch:** `feat/migrate-to-local-plugin`
**Sprint 2 of the Hermes multi-agent project**

## TL;DR for future agents reading this cold

Sprint 1 (2026-04-20) patched and stress-tested MemOS the server (Product 1). Sprint 2 migrates away from that server and onto `@memtensor/memos-local-hermes-plugin` (Product 2) — a different product by the same team that adds auto-capture, task summarization, and skill evolution. Product 1 is archived but not deleted; the fork repo at `sergiocoding96/MemOS` stays intact as reference.

The migration is staged. A gate session validates Product 2 works at all before anything else starts. If the gate fails, the migration aborts and we continue using Product 1.

## Why migrate

See [2026-04-20-sprint-merge-log.md](./2026-04-20-sprint-merge-log.md) post-sprint analysis and the subsequent conversation. Short version:

- **What we gain:** automatic capture of every agent turn, LLM-driven task summarization, skill evolution (auto-distills reusable SKILL.md files from successful sessions), Memory Viewer dashboard, more sophisticated hybrid search (FTS5 + vector + RRF + MMR + recency decay), maintained-by-MemTensor upgrade path.
- **What we lose:** the MemOS server architecture we patched (bcrypt auth, cube ACL model, Qdrant/Neo4j backends). None of these capabilities are actively used by our agents beyond what Product 2 covers with a simpler model.
- **What becomes unnecessary:** all 6 Phase 2 remainder worktrees (`fix/feedback-default`, `fix/chat-endpoint`, `feat/preference-extraction`, `feat/scheduler-metrics`, `feat/tool-memory-type`, `feat/fine-mode-parallel`) — they fix a server we'd stop running.
- **What stays relevant:** 4 of 6 Phase 3 items (`feat/fallback-model`, `feat/mcp-integration`, `feat/python-library-adapter`, `feat/github-webhook`). The other two (`feat/soft-loop`, `feat/hard-loop`) are largely subsumed by Product 2's skill evolution.

## Architecture target

```
Hub (on tower)
  └── @memtensor/memos-local-hermes-plugin running as HUB
        → HTTP server for shared group/public memories + skills

Hermes workers (each a client of the hub)
  ├── default           (in "ceo-team" group)
  ├── research-agent    (in "ceo-team" group)
  └── email-marketing   (in "ceo-team" group)
        - auto-capture every turn → local SQLite + hub index
        - task summarization LLM pipeline
        - skill evolution → writes SKILL.md files → ~/Coding/badass-skills/

CEO (Claude Code session on tower, with --channels plugin:telegram)
  ├── ~/.claude/skills/ symlinks to ~/Coding/badass-skills/
  ├── reads hub via bash curl (Option 1, minimum)
  │   or MCP wrapper (Option 2, polish)
  └── delegates to Hermes workers via Paperclip

Paperclip (orchestration)
  └── claude_local for CEO, hermes_local for workers (all bundled, no custom install)
```

## The 5-stage execution plan

### Stage 1 — Gate (sequential, blocks all downstream work)

| Worktree | Gate passes if |
|----------|----------------|
| `feat/migrate-setup` | (1) Plugin installs cleanly on one Hermes profile. (2) Hub comes up healthy. (3) Auto-capture lands a conversation into local SQLite without manual calls. (4) Search retrieves it. (5) A trivial skill-evolution seed produces a generated SKILL.md. |

**Go criteria:** all 5 smoke probes pass.
**No-go criteria:** any single probe fails. Sprint aborts, write a failure learning doc, continue with Product 1.

### Stage 2 — Integration wiring (parallel, 3 worktrees)

Only starts after Stage 1 green. Each is independent and can run in parallel.

| Worktree | Scope |
|----------|-------|
| `wire/paperclip-employees` | Create Paperclip employees for `research-agent` and `email-marketing` using the built-in `hermes_local` adapter. Verify delegation CEO → employee → response works. |
| `wire/ceo-hub-access` | Claude Code CEO can read/write hub. Option 1 (bash curl) minimum; Option 2 (MCP wrapper) if time allows. |
| `wire/badass-skills-groundtruth` | Symlink `~/Coding/badass-skills/*` into `~/.claude/skills/`. Configure plugin skill-output directory to write into `~/Coding/badass-skills/`. Verify both runtimes (Hermes + Claude Code) see the same skills. |

### Stage 2.5 — Fix adapter auth gap discovered in Stage 2 (single worktree, blocks end-to-end validation)

Added post-hoc after Stage 2 merge. PR #7 shipped the employee wiring but delegation times out at 600s because the `hermes_local` adapter's default prompt tells agents to curl the Paperclip API and no bearer token is injected. Full analysis in [2026-04-21-paperclip-hermes-adapter-auth-gap.md](./2026-04-21-paperclip-hermes-adapter-auth-gap.md).

| Worktree | Scope |
|----------|-------|
| `fix/paperclip-agent-auth` | Override `adapterConfig.promptTemplate` per Hermes employee so the agent's stdout is the completion — no API callbacks, no bearer tokens, no upstream patches. Full brief: [paperclip-agent-auth.md](../../scripts/worktrees/migration/fix/paperclip-agent-auth.md). Completion criterion: delegation smoke test passes in < 60s with zero 401s in the run log. → **Merged as PR #8 (`f81f467`) with scope expansion to patch `hermes-paperclip-adapter` (Bugs A+B).** Finding C surfaced an unavoidable follow-up → Stage 2.6. |

### Stage 2.6 — Scoped JWT injection so issues transition to `done` (single worktree)

Added 2026-04-21 after PR #8's Finding C. Paperclip's run-handler never transitions issue status automatically — agents must `PATCH /api/issues/:id` themselves, which requires a bearer token. Stage 2.5 deliberately avoided injecting a board token (security regression). The correct path is short-lived scoped JWTs minted by the adapter using Paperclip's `PAPERCLIP_AGENT_JWT_SECRET`.

| Worktree | Scope |
|----------|-------|
| `fix/paperclip-scoped-jwt` | Patch `hermes-paperclip-adapter`'s `buildPaperclipEnv()` to sign a short-lived JWT (≤10min, scoped to `{agentId, companyId, runId}`) using `process.env.PAPERCLIP_AGENT_JWT_SECRET` and export as `PAPERCLIP_AGENT_JWT`. Update the prompt template to emit exactly one final `PATCH /issues/:id` call using that token. Full brief: [paperclip-scoped-jwt.md](../../scripts/worktrees/migration/fix/paperclip-scoped-jwt.md). Completion criterion: assigned issue transitions `todo → in_progress → done` automatically with zero board-token exposure. |

### Stage 3 — Write the v2 audit suite (single worktree)

| Worktree | Scope |
|----------|-------|
| `docs/write-v2-audit-suite` | Create `tests/v2/` with 10 audit prompt files following the Product 1 methodology: 6 adapted + 4 new-capability. Same rigor: fresh sessions, adversarial, 1-10 scoring per area, MIN aggregation. |

### Stage 4 — Execute 10 blind audits (parallel, fresh sessions)

**These are NOT dev worktrees.** Each audit is a fresh Claude Code Desktop session that pastes the audit prompt as first message and produces a report. The report is saved to `tests/v2/reports/<audit-name>-<date>.md` and committed.

| # | Audit | Adapted from / new |
|---|-------|--------------------|
| 1 | zero-knowledge-v2 | adapted from Sprint 1 zero-knowledge-audit.md |
| 2 | functionality-v2 | adapted from blind-functionality-audit.md |
| 3 | resilience-v2 | adapted from blind-resilience-audit.md |
| 4 | performance-v2 | adapted from blind-performance-audit.md |
| 5 | data-integrity-v2 | adapted from blind-data-integrity-audit.md |
| 6 | observability-v2 | adapted from blind-observability-audit.md |
| 7 | auto-capture-v2 | NEW — tests the capture pipeline under load |
| 8 | skill-evolution-v2 | NEW — tests generated skill coherence + upgrades |
| 9 | task-summarization-v2 | NEW — tests task boundary detection + summary quality |
| 10 | hub-sharing-v2 | NEW — tests group visibility + cross-client recall |

**Acceptance criteria:** all 10 audits score ≥ 7/10. Any audit < 5/10 is a blocker.

### Stage 5 — Still-relevant Phase 3 items (parallel, 4 worktrees)

Independent of the migration; can run in parallel with Stages 3+4 if desired.

| Worktree | Scope |
|----------|-------|
| `hermes/fallback-model` | Add fallback_providers to Hermes config (closes baseline audit resilience gap 2/10 → 5+/10). |
| `hermes/mcp-integration` | Wire external MCP servers for both Hermes and Claude Code runtimes. |
| `hermes/python-library-adapter` | Move Paperclip from CLI subprocess to Python library calls (if still relevant after Stage 2). |
| `hermes/github-webhook` | GitHub PR auto-review webhook handler. |

## Methodology — same as Sprint 1

- Worktrees under `~/Coding/Hermes-wt/` named after their branch.
- Each has a `TASK.md` dropped in at creation time.
- Claude Code Desktop sessions paste the initiation prompt, which tells them to read TASK.md and proceed.
- Session commits on its `claude/*` scratch branch (Desktop auto-created).
- Session pushes + opens PR when acceptance criteria pass.
- Human reviews + merges on GitHub.
- After merge, cleanup worktree + branch.
- Merge log at [2026-04-20-sprint-merge-log.md](./2026-04-20-sprint-merge-log.md) gets appended per merge.

## Audit execution (Stage 4 specifics)

1. Audit prompts live in `tests/v2/*.md`.
2. Open a fresh Claude Code Desktop session.
3. Set working directory to `~/Coding/Hermes`.
4. **Before** the first message, ensure the session has NO context: no CLAUDE.md injection, no prior conversation.
5. Paste the audit's full prompt as the first message.
6. Let it run to completion without steering.
7. Save the final report to `tests/v2/reports/<audit-name>-2026-04-XX.md`.
8. Commit the report.
9. Close the session before starting the next audit.

**One audit per session. Never combine.** Blind integrity depends on this.

## Acceptance criteria for the whole migration

Migration is *done* when:

- All Stage 1–3 worktrees merged.
- All 10 Stage 4 audits committed, each scoring ≥ 7/10.
- All still-relevant Stage 5 Phase 3 worktrees merged.
- MemOS server is stopped (but fork remains available as reference).
- `~/Coding/badass-skills/` receives auto-generated skills from at least one real session.
- CEO (via bash or MCP) can query hub and retrieve cross-agent memories.
- End-to-end smoke test: user sends Telegram message → CEO receives → delegates to research-agent → worker auto-captures + uses memory → CEO synthesizes → Telegram reply shows memory-informed context.

## Rollback plan

If at any stage the migration proves unworkable:

1. `git checkout main && git branch -D feat/migrate-to-local-plugin` — discard the branch.
2. Un-archive `deploy/plugins/memos-toolset/` from `_archive/`.
3. Restart MemOS server (installation unchanged, still editable-install from the fork).
4. Write a post-mortem at `memos-setup/learnings/2026-04-XX-migration-abort.md` with findings.
5. No data loss — the MemOS server's Qdrant + Neo4j + SQLite were never deleted.

## Open questions (resolved during gate — 2026-04-21)

- [x] **Embedding provider:** Xenova all-MiniLM-L6-v2 (local, 384d) — matches Sprint 1 setup.
- [x] **Summarizer model:** DeepSeek V3 via `openai_compatible` — reuses Sprint 1's MEMRADER key.
- [x] **Hub port:** `18992` free. *Important:* plugin's native default has `18992` = bridge daemon, hub = derived (`19003`). Gate overrides so hub = `18992`, daemon = `18990`, viewer = `18901`. All Stage 2 worktrees inherit this via `scripts/migration/bootstrap-hub.sh`.
- [x] **Skill output dir:** plugin writes to `stateDir/skills-store/` by default. Install-into-`~/Coding/badass-skills/` is `wire/badass-skills-groundtruth` scope.

## Gate findings that Stage 2+ sessions must know

The gate worktree (PR #4, commit [48f04f4](https://github.com/sergiocoding96/hermes-multi-agent/commit/48f04f4)) surfaced four things that were unknown when the plan was written. See the sprint merge log entry for full detail — summary:

1. **`bridge.cts --daemon` does NOT start HubServer.** The hub is only wired by the plugin's OpenHarness entry in `index.ts`. Use `scripts/migration/hub-launcher.cts` (shipped by gate) to instantiate HubServer directly.
2. **Port layout** — see Open Questions above. Canonical mapping lives in `scripts/migration/bootstrap-hub.sh`.
3. **Hub has no `/health` route.** Liveness probe = `GET /api/v1/hub/info` (200 + JSON, no auth).
4. **Node constraint `>=18 <25`.** `install-plugin.sh` detects and picks the right binary; don't override with Linuxbrew Node 25 on `$PATH`.

Any Stage 2 worktree that touches the hub or plugin should read these before coding to avoid re-discovery cost.
