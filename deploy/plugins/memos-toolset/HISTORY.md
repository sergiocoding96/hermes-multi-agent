# memos-toolset — history

The Hermes-side client plugin for the MemOS server (v1, "Product 1") at `localhost:8001`. **Currently active as of 2026-04-27** at v1.0.3 (added the `post_llm_call` auto-capture hook in Hermes PR #14).

## Timeline

| Date | Event |
|---|---|
| 2026-04-20 | Archived to `deploy/plugins/_archive/memos-toolset/` during the original Sprint 2 plan to migrate to `@memtensor/memos-local-plugin` v2 |
| 2026-04-26 | v2 audit results (mean 2.4/10, min 1/10) prompted a strategic reverse — see `memos-setup/learnings/2026-04-27-v2-deprecated-revert-to-v1.md` |
| 2026-04-27 | Un-archived back to `deploy/plugins/memos-toolset/` (commit `c2a64bb`) and updated to v1.0.3 with auto-capture (PR #14) |

## Why this plugin (and not the v2 plugin)

`memos-toolset` is the Hermes-side client that talks to the v1 MemOS server (Qdrant + Neo4j + SQLite at `localhost:8001`). The v2 plugin (`@memtensor/memos-local-plugin`) was a self-contained per-agent local SQLite store that bypassed the server entirely. v2's audit failed (architectural issues — no ANN index, dead viewer, missing subsystems) and was deprecated. v1 server + this client plugin is the production target.

If you're confused about why there's a "memos" plugin in Hermes plus a separate MemOS server in another repo, read [`docs/architecture/two-repos.pdf`](../../../docs/architecture/two-repos.pdf).

## Rollback path (kept for reference, not the current plan)

If for some reason v1 is abandoned again (unlikely given the post-fix system; this section exists to preserve institutional memory):

1. `git mv deploy/plugins/memos-toolset deploy/plugins/_archive/memos-toolset`
2. Whatever v2 (or successor) deployment process is adopted.

## Related artifacts

- **Decision doc (current):** `memos-setup/learnings/2026-04-27-v2-deprecated-revert-to-v1.md`
- **Original v2 migration plan (superseded):** `memos-setup/learnings/2026-04-20-v2-migration-plan.md`
- **Sprint 1 v1 hardening log:** `memos-setup/learnings/2026-04-20-sprint-merge-log.md`
- **MVP-readiness brief:** `tests/v1/reports/combined/v1-mvp-readiness-2026-04-26.pdf`
- **Two-repo team explainer:** `docs/architecture/two-repos.pdf`
