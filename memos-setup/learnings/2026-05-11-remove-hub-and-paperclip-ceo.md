# 2026-05-11 — Remove the MemOS hub and the Paperclip CEO

## Decision

We are removing two layers from the stack:

1. **The MemOS v2 plugin / "hub"** (`@memtensor/memos-local-hermes-plugin`) and everything we built around it during the Sprint 2 migration — hub launcher, hub-sync cron, the v2 plugin patches, the v2 audit suite, the v2 worktree plan.
2. **The Paperclip CEO** (Claude Opus 4.6 on Paperclip) and the `hermes-paperclip-adapter` integration that fanned tasks out to workers.

The MemOS server (Product 1, localhost:8001) **stays** — it is the authoritative memory backend. The worker profiles (`research-agent`, `email-marketing`) **stay**. The web stack (Firecrawl, SearXNG, Camofox) **stays**.

## Replacement

Orchestration moves to **the user's local Hermes profile, driven via Hermes Kanban**. Kanban handles task dispatch + aggregation; the local profile reads across worker cubes for synthesis.

A neutrally-named `orchestrator` MemOS principal replaces the CEO's CompositeCubeView role — same cross-cube read grants, no special protocol.

## Why

- **Hub migration was high-risk for low marginal value.** Sprint 2 was 5 stages and 10 blind audits to swap an authoritative server for an embedded plugin. The server is fine. The audits weren't scoring well (mean 2.4/10 on the 2026-04-26 v2.0 run, min 1/10), and the fix work was bloating. Rolling back is cheaper than finishing.
- **Paperclip CEO was an integration cost without a payoff.** The bundled `hermes-paperclip-adapter` needed re-patching on every `paperclipai` version bump (`ctx.config` → `ctx.context` bug), JWT scoping, employee creation scripts, SOUL maintenance. Hermes Kanban does the same dispatch directly inside the Hermes profile we already maintain.
- **Two orchestration layers were one too many.** With Kanban, there is one orchestrator (the local profile) and N workers. No CEO-vs-worker SOUL drift, no inter-process auth, no token refresh cron.

## What was deleted

| Removed | Was used for |
|---|---|
| `scripts/ceo/` | CEO MCP server, token provisioning + refresh scripts |
| `scripts/paperclip/` | Paperclip employee creation, adapter patches, CEO SOUL |
| `scripts/migration/` (almost all) | v2 hub bootstrap, hub-sync, plugin install + patches |
| `scripts/worktrees/migration/` | Sprint 2 worktree plan + per-task briefs |
| `tests/v2/` | v2 blind-audit suite + reports |
| `deploy/systemd/memos-hub.service` | systemd unit for the v2 hub |
| `scripts/worktrees/hermes/feat-paperclip-adapter.md` | adapter integration brief |

Kept: `scripts/symlink-badass-skills.sh` (moved up from `scripts/migration/`) — still useful for Claude Code skill discovery, not hub-related.

## What was edited

- `hermes_lib.py` + `deploy/hermes_lib.py` — `dispatch_to_hermes` kept; docstring generalized from "Paperclip CEO → Hermes worker" to "local orchestrator → worker".
- `deploy/scripts/install-infra.sh` — dropped `memos-hub.service` install block; cron loader retained.
- `deploy/cron/hermes-memos.crontab` — dropped CEO token refresh + hub-sync entries.
- `deploy/profiles/research-agent/SOUL.md`, `deploy/profiles/email-marketing/SOUL.md` — CEO references replaced with "orchestrator".
- `skills/research-coordinator/SKILL.md`, `skills/email-marketing-plusvibe/SKILL.md` — same.
- `CLAUDE.md`, `README.md`, `deploy/README.md`, `deploy/ARCHITECTURE.md` — rewrote the architecture sections.

## Operator-side cleanup (outside this repo)

- `~/.claude/memos-hub.env` — delete
- `mcpServers.memos-hub` block in `~/.claude.json` — remove
- `~/.paperclip/instances/default/...` — uninstall or archive the Paperclip CEO instance
- `systemctl --user disable --now memos-hub.service` on every host that ran it
- `npm uninstall paperclipai` if no longer needed
- In the `sergiocoding96/MemOS` fork: `apps/memos-local-openclaw/` and `apps/memos-local-plugin/src/hub/` can go

## Rollback

If Kanban-led orchestration turns out worse than expected, the rollback is to re-introduce the worker-dispatch layer from a separate orchestrator agent. The Hermes profile mechanism doesn't change — `dispatch_to_hermes` still works. Nothing about the worker contract (SOUL + MemOS writes) changed in this sprint, so any orchestrator can plug back in.

The MemOS hub is harder to bring back — its v2 plugin patches were ahead of upstream. If we ever need it, we'd re-fork from current upstream.

## Branch

`claude/nice-mclaren-13f017` (this worktree).
