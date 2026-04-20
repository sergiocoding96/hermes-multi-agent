# TASK: feat/migrate-setup — Gate session for the v2 migration

## Goal

Prove that `@memtensor/memos-local-hermes-plugin` works at all in this environment. Get plugin + hub running for ONE Hermes profile (`research-agent`), pass 5 smoke probes. If all probes pass, the migration continues. If any probe fails, abort the migration and we stay with Product 1.

## Context

See [migration master plan](../../../../memos-setup/learnings/2026-04-20-v2-migration-plan.md) for full context. The short version:

- Product 1 = MemOS server we patched in Sprint 1 (currently running at localhost:8001). Heavy: Qdrant + Neo4j + SQLite.
- Product 2 = `@memtensor/memos-local-hermes-plugin`, a self-contained TypeScript plugin for Hermes. Lightweight: per-agent SQLite + optional hub HTTP server. Adds auto-capture, task summarization, skill evolution.
- We are migrating to Product 2. This session gates the migration.

## Scope

Do ALL of the following in this worktree:

1. **Archive old memory code** (don't delete — we need rollback).
2. **Install `@memtensor/memos-local-hermes-plugin`** into `research-agent` profile.
3. **Start the hub server** in hub mode, with the `ceo-team` group created and a token issued.
4. **Run 5 blind smoke probes** against the running hub + client.
5. **Write a gate report** that records pass/fail per probe with evidence.
6. **Open a PR** with the archive, install scripts, hub bootstrap script, and report.

## Files to touch

**Archive (not delete):**
- Move `deploy/plugins/memos-toolset/` → `deploy/plugins/_archive/memos-toolset/` and add `deploy/plugins/_archive/memos-toolset/DEPRECATED.md` explaining why.
- Move `agents-auth.json` → `agents-auth.json.archived`.
- Move `setup-memos-agents.py` → `setup-memos-agents.py.archived`.
- Move `deploy/scripts/setup-memos-agents.py` → `deploy/scripts/setup-memos-agents.py.archived` if it exists.

**New scripts:**
- `scripts/migration/install-plugin.sh` — installs `@memtensor/memos-local-hermes-plugin` into a Hermes profile. Parameterized by profile name. Idempotent.
- `scripts/migration/bootstrap-hub.sh` — starts the hub server with initial config (group, admin token, allowed clients).

**New docs:**
- `deploy/plugins/_archive/memos-toolset/DEPRECATED.md` — 10-15 lines explaining the archival reason, rollback path.
- `memos-setup/learnings/2026-04-20-gate-report.md` — the gate session's final report.

## Acceptance criteria (the 5 probes)

Each probe must pass with raw evidence. Use fresh test data with unique markers (timestamps). Report the raw commands you ran and the raw outputs.

### Probe 1 — Plugin installs cleanly

- [ ] `scripts/migration/install-plugin.sh research-agent` runs with exit code 0.
- [ ] The plugin is present in `~/.hermes/memos-plugin/` (or wherever the install script places it — document this).
- [ ] `node --version` and `bun --version` both work (plugin requires Bun or Node 18+).
- [ ] No error in install log.

### Probe 2 — Hub starts healthy

- [ ] `scripts/migration/bootstrap-hub.sh` runs with exit code 0.
- [ ] Hub HTTP server responds on its port (default 18992): `curl -sf http://localhost:18992/health` returns 200 with a JSON body containing `status: "healthy"` or similar.
- [ ] The `ceo-team` group exists in the hub (verify via the hub's user-listing endpoint or the internal `HubUserManager`).
- [ ] A bootstrap admin token is issued and saved to a file with `0600` permissions (NOT committed).

### Probe 3 — Auto-capture lands a conversation

- [ ] Using `research-agent` profile with the plugin loaded, run ONE Hermes chat session with at least 3 turns (e.g., `hermes -p research-agent chat -q "Unique marker <timestamp>: the capital of France is Paris. Follow-up: when was the Eiffel Tower built?"`).
- [ ] DO NOT call `memos_store` or any explicit memory tool. We are testing auto-capture.
- [ ] After the session completes, query the plugin's SQLite directly OR via its search API. Verify the unique marker's content is present.
- [ ] Verify chunking: the conversation is stored as multiple chunks if it exceeded the configured size, and the chunks preserve the unique marker.

### Probe 4 — Search retrieves the capture

- [ ] Search for the unique marker via the plugin's search API (MCP tool `memos_search` OR direct HTTP to hub if exposed).
- [ ] Result count ≥ 1.
- [ ] Top result has relevance score > 0.5.
- [ ] Retrieved content includes the marker string verbatim.

### Probe 5 — Trivial skill evolution produces something

- [ ] Run 2–3 additional Hermes sessions on variations of a small realistic task (e.g., "write a Python function that reads a CSV and prints the first 5 rows").
- [ ] Wait for the plugin's skill evolution pipeline to run (may need to trigger manually — check the plugin's docs/config for how).
- [ ] Verify at least 1 `SKILL.md` file exists in the plugin's skill output directory.
- [ ] Read the generated SKILL.md — confirm it's non-empty, has YAML frontmatter with `name` and `description`, and contains at least one executable step or reusable pattern.

**If any probe fails:** the gate has failed. Document the failure, close the PR as "gate failed — migration aborted," and hand back to the user.

## Test plan (isolated to this worktree)

- Do ALL tests against a fresh research-agent configuration. Do not reuse any existing MemOS server state.
- Use a unique marker `GATE-<timestamp>` in every test write so nothing collides with real agent data.
- Keep the MemOS server (Product 1) running during this session if it's already running — we do not stop it until Stage 1 passes and the user approves.

## Out of scope

- Do NOT modify the existing MemOS server or its fork (`~/Coding/MemOS/`). Leave it running or not running, whatever state it's in.
- Do NOT install the plugin on other profiles (default, email-marketing) — that happens in Stage 2.
- Do NOT set up `ceo-team` group client subscriptions for other agents yet — this is single-client gate.
- Do NOT create Paperclip employees yet.
- Do NOT wire CEO (Claude Code) access yet.
- Do NOT write the v2 audit suite — that's Stage 3.

## Environment prerequisites (check first, document findings)

- [ ] Node 18+ installed (`node --version`)
- [ ] Bun installed (`bun --version`) — plugin needs this per README
- [ ] Existing MemOS server running or not — document status
- [ ] Hermes CLI works (`hermes profile list`)
- [ ] `research-agent` profile exists

If any prerequisite is missing, install it (document the commands), or abort the gate with a clear note.

## Commit / PR

- Branch: `feat/migrate-setup` (or `claude/*` scratch as assigned by Desktop)
- Commits: chunked — "archive old memory code", "add install-plugin.sh", "add bootstrap-hub.sh", "gate report"
- PR title: `feat(migration): gate session — install plugin, bootstrap hub, run 5 probes`
- PR body: include the gate report summary + probe-by-probe pass/fail table + the raw evidence.

## When to stop

Stop after the PR is open. Do NOT merge. Do NOT launch Stage 2 worktrees. The human reviews the gate and decides whether the migration continues.
