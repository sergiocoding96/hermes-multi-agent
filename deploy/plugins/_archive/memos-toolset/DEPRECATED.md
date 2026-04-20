# DEPRECATED — memos-toolset

Archived: 2026-04-20 during Sprint 2 migration to `@memtensor/memos-local-hermes-plugin` (Product 2).

## Why archived

`memos-toolset` was the Hermes-side plugin for the MemOS server (Product 1) — a Qdrant + Neo4j + SQLite HTTP service at `localhost:8001`. Sprint 2 moves memory to a per-agent local SQLite plugin with an optional hub HTTP server. The new plugin provides auto-capture, task summarization, and skill evolution, which replace this toolset's explicit `memos_store` / `memos_search` calls.

## Rollback path

If the migration is aborted (gate fails or post-merge issues):

1. `git mv deploy/plugins/_archive/memos-toolset deploy/plugins/memos-toolset`
2. `git mv agents-auth.json.archived agents-auth.json`
3. `git mv setup-memos-agents.py.archived setup-memos-agents.py`
4. `git mv deploy/scripts/setup-memos-agents.py.archived deploy/scripts/setup-memos-agents.py`
5. Restart the MemOS server (`cd ~/Coding/MemOS && python -m memos.api.server`).
6. Re-run provisioning (`python setup-memos-agents.py`).

No data loss — the MemOS server's Qdrant + Neo4j + SQLite state remains on disk.

## Related migration artifacts

- Master plan: `memos-setup/learnings/2026-04-20-v2-migration-plan.md`
- Gate report: `memos-setup/learnings/2026-04-20-gate-report.md`
- Sprint 1 log: `memos-setup/learnings/2026-04-20-sprint-merge-log.md`
