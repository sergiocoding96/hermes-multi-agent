# 2026-05-11 — Remove the Paperclip CEO and the v2 MemOS hub

## TL;DR

Sergio's local hermes profile, using the new **Kanban feature in hermes-agent**, replaces the Paperclip CEO. The v2 MemOS hub (port 18992, `apps/memos-local-openclaw`) is also gone since its main consumer was the CEO MCP. MemOS v1 server (`:8001`) and the Hermes workers (`research-agent`, `email-marketing`) stay.

## Why

1. **Hermes Kanban makes Paperclip redundant.** The orchestration role the Paperclip CEO played — accepting a request, fanning it out, tracking status — is now native to hermes-agent. Running a second orchestrator on top adds operational surface for no gain.
2. **The hub's only live consumer was the CEO MCP.** With the CEO gone, the hub had no traffic worth its complexity.
3. **The hub had been losing reasons to exist.** The 2026-04-27 audit (`2026-04-27-v2-deprecated-revert-to-v1.md`) already killed the v2 plugin behind it. The MCP wrapper at `scripts/ceo/memos-hub-mcp/` had been kept under its old name purely for backcompat, talking to v1 underneath. Once the CEO leaves, that backcompat costs more than it's worth.

## What got removed

### Directories deleted

- `scripts/ceo/` — all CEO bash + MCP wrapper. CEO no longer exists, so its tooling doesn't either.
- `scripts/paperclip/` — Paperclip-side install, patch, SOUL.md, employee creation scripts.
- `scripts/migration/` — v2 hub bootstrap, sync daemon, plugin installer/patcher. (Exception: `symlink-badass-skills.sh` was salvaged to `scripts/symlink-badass-skills.sh` — it's a generic Claude Code skill-discovery helper, unrelated to the hub.)
- `scripts/worktrees/` — completed task briefs from prior sprints.
- `tests/v2/` — audit corpus for the deprecated v2 hub stack.
- `deploy/profiles/ceo.env.example` — CEO env template.
- `deploy/systemd/memos-hub.service` — v2 hub user unit.
- `deploy/cron/hermes-memos.crontab` — both cron entries pointed at deleted scripts (`refresh-ceo-token.sh`, `hub-sync.py`).
- `scripts/run-blind-audits.sh` — only ran v2-suite audits, all deleted.

### Code edits

- `hermes_lib.py` / `deploy/hermes_lib.py` — `dispatch_to_hermes()` is generic orchestrator→worker dispatch. Dropped the "Paperclip CEO" framing in the section header and docstring; function body unchanged.
- `deploy/scripts/setup-memos-agents.py` — removed the `ceo` user, `ceo-cube`, and `CEO_SHARES` block. Only `research-agent` and `email-marketing-agent` are provisioned now.
- `deploy/scripts/install-infra.sh` — rewritten to install only `memos-server.service`. Hub unit copy + cron-entry loop are gone.

### Docs rewritten

- `CLAUDE.md` — active-sprint header + architecture section. Orchestrator is now "Sergio's local hermes profile via Kanban."
- `README.md`, `deploy/ARCHITECTURE.md`, `deploy/README.md` — same direction. Architecture diagrams swapped from `CEO (Claude Opus 4.6, Paperclip)` to `Sergio's local hermes profile (orchestrator, via Kanban)`.
- `deploy/systemd/README.md` — `memos-hub.service` row removed from the unit table; legacy-removal stanza now references this doc instead of the 2026-04-27 v2-deprecation doc.
- Worker SOULs (`deploy/profiles/research-agent/SOUL.md`, `deploy/profiles/email-marketing/SOUL.md`) — "Your CEO (Claude Opus 4.6)" → "An orchestrator (Sergio's local hermes profile via Kanban)." "CEO depends on cross-cube search" lines removed since cross-cube is no longer assumed.
- Skills (`skills/research-coordinator/SKILL.md`, `skills/email-marketing-plusvibe/SKILL.md`) — "CEO and other agents" → "orchestrator and other agents."

## What stays

- MemOS v1 server at `:8001`, Qdrant, Neo4j — unchanged.
- Worker cubes: `research-cube` (owner: `research-agent`), `email-mkt-cube` (owner: `email-marketing-agent`).
- Credential-bound cube isolation (BCrypt + prefix bucketing, per 2026-04-27 fix at `agent_auth.py` + `server_router.py:467`).
- `memos-toolset` plugin in each worker profile.
- Web stack: Firecrawl `:3002`, SearXNG `:8888`, Camofox `:9377`.
- All skills in `skills/` and `~/Coding/badass-skills/`.
- Historical decision docs in `memos-setup/learnings/` — left untouched as the audit trail.

## What I did **not** do (explicit non-decisions)

- **Did not create an `orchestrator` MemOS user.** The CEO had ROOT + multi-cube grants to do CompositeCubeView. The new orchestrator is Sergio's local hermes profile, which talks to MemOS via the same `memos-toolset` plugin as workers — currently bound to whichever user/cube its profile env points at. If the orchestrator needs to read across `research-cube` + `email-mkt-cube`, add a single `orchestrator` user with multi-cube `add_user_to_cube` grants in `setup-memos-agents.py`. I deferred this — easy to add when the need is concrete, and the user explicitly said Kanban handles aggregation.
- **Did not rewrite the `paperclip` example queries inside `skills/github-research/SKILL.md` and `skills/reddit-research/SKILL.md`.** Those are illustrative search strings (e.g., `gh search repos "paperclip"`), not architectural dependencies. They still demonstrate the skill correctly.
- **Did not delete `tests/v1/`.** It's the current baseline audit. Some report files reference the hub in passing as historical observability context — that's accurate as-is.

## Outside this repo — operator-side cleanup (still to do)

These live outside `hermes-multi-agent` and are not modified by this PR:

```bash
# Remove the legacy systemd hub unit if it's still installed
systemctl --user disable --now memos-hub.service 2>/dev/null
rm -f ~/.config/systemd/user/memos-hub.service
systemctl --user daemon-reload

# Remove the CEO MCP env file and the registration block from ~/.claude.json
rm -f ~/.claude/memos-hub.env
# In ~/.claude.json, delete the "memos-hub" entry under mcpServers
```

In the MemOS fork (`sergiocoding96/MemOS`), the hub source under `apps/memos-local-openclaw/` and `apps/memos-local-plugin/src/hub/` can be deleted in a follow-up PR. They are no longer wired into anything from this repo.

Paperclip itself (`npm install paperclipai`, `~/.paperclip/`) can be uninstalled at your discretion — nothing in this repo references it anymore.

## Rollback path

If Kanban turns out not to cover the orchestration role:

1. `git revert` this commit on `claude/remove-memos-hub-2P4LC` — restores the CEO scripts, MCP wrapper, hub systemd unit, cron entries, and CEO user in `setup-memos-agents.py`.
2. Re-run `deploy/scripts/setup-memos-agents.py` to recreate the `ceo` user + `ceo-cube` + cross-cube shares.
3. Re-source the CEO env in `~/.claude/memos-hub.env` and re-register the MCP via `claude mcp add memos-hub …`.
4. The v2 hub source is no longer needed for the CEO MCP (the MCP wraps v1 since 2026-04-27); only the CEO + the MCP need to come back. The v2 hub itself can stay deleted.

If the workers themselves regress (auth, cube isolation), that's a separate rollback — see `2026-04-27-v2-deprecated-revert-to-v1.md`.

## Cross-links

- Active sprint header in [`CLAUDE.md`](../../CLAUDE.md)
- Previous strategic doc: [`2026-04-28-collapse-to-single-tier-memos.md`](2026-04-28-collapse-to-single-tier-memos.md)
- Previous strategic doc: [`2026-04-27-v2-deprecated-revert-to-v1.md`](2026-04-27-v2-deprecated-revert-to-v1.md)
