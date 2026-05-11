# TODO — Hermes Multi-Agent System

## Sprint 3 (2026-05-11) — Remove hub + Paperclip CEO

See [`memos-setup/learnings/2026-05-11-remove-hub-and-paperclip-ceo.md`](memos-setup/learnings/2026-05-11-remove-hub-and-paperclip-ceo.md) for context.

- [x] Delete `scripts/ceo/`, `scripts/paperclip/`, `scripts/migration/` (except `symlink-badass-skills.sh`)
- [x] Delete `tests/v2/` and `scripts/worktrees/migration/`
- [x] Delete `deploy/systemd/memos-hub.service`
- [x] Strip CEO/Paperclip mentions from `hermes_lib.py`, SOUL files, skills
- [x] Rewrite `CLAUDE.md`, `README.md`, `deploy/README.md`, `deploy/ARCHITECTURE.md`
- [x] Replace `ceo` user with `orchestrator` in `deploy/config/agents-auth.example.json`
- [ ] Regenerate the live `agents-auth.json` with the new `orchestrator` principal
- [ ] Provision `orchestrator` MemOS principal with read grants to `research-cube` + `email-mkt-cube`
- [ ] Wire Hermes Kanban as the dispatch surface on the user's local Hermes profile
- [ ] Operator-side cleanup on each host:
  - [ ] `systemctl --user disable --now memos-hub.service`
  - [ ] Remove `~/.claude/memos-hub.env` and the `memos-hub` block from `~/.claude.json`
  - [ ] Archive `~/.paperclip/instances/default/` (or uninstall `paperclipai`)

## Always-on infra (status)

- [x] MemOS server running at localhost:8001 (Qdrant + Neo4j + SQLite)
- [x] Firecrawl + SearXNG at localhost:3002 + 8888
- [x] Camofox at localhost:9377
- [x] Worker profiles (`research-agent`, `email-marketing`) with `memos-toolset` plugin
- [x] Shared `badass-skills` via `external_dirs`

## Open work (carried over)

- [ ] Add error handling to MemOS writes (retry on 500, timeout on sync)
- [ ] Monitor Qdrant/Neo4j resource usage under sustained agent load
- [ ] Document runbook for starting full stack (Neo4j → Qdrant → MemOS → Firecrawl → Hermes)
- [ ] Add webhook route for GitHub PR auto-review
- [ ] Add Discord + WhatsApp to messaging gateway
