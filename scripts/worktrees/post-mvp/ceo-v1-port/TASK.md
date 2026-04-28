# Worktree — Replace v2 CEO scripts with v1 equivalents

> **Repo:** Hermes (`sergiocoding96/hermes-multi-agent`).
> **Branch:** `feat/ceo-v1-scripts` (off `origin/main`).
> **Worktree:** `~/Coding/Hermes-wt/feat-ceo-v1-scripts`.
> **Safe-parallel constraint:** a separate v2-cleanup task is concurrently DELETING `scripts/ceo/memos-search.sh`, `memos-write.sh`, `provision-ceo-token.sh`, `provision-worker-token.sh`, `refresh-ceo-token.sh`, and `memos-hub-mcp/`. **You must not touch any of those files.** Add NEW files alongside them (with explicit `-v1` suffixes or in a new sub-directory) and the two tasks will land cleanly in either merge order.

## Setup

```bash
cd /home/openclaw/Coding/Hermes
git fetch origin main
git worktree add ~/Coding/Hermes-wt/feat-ceo-v1-scripts -b feat/ceo-v1-scripts origin/main
cd ~/Coding/Hermes-wt/feat-ceo-v1-scripts
```

## Context

The CEO orchestrator currently uses scripts under `scripts/ceo/` that target the v2 hub:

| Script | What it does (v2) |
|---|---|
| `memos-search.sh` | Calls `$MEMOS_HUB_URL/memories/search` with `MEMOS_HUB_TOKEN` Bearer |
| `memos-write.sh` | Calls v2 hub `/memories/share` |
| `provision-ceo-token.sh` | Mints v2 hub-issued JWT (24h TTL) |
| `provision-worker-token.sh` | Same, for workers |
| `refresh-ceo-token.sh` | Daily cron'd refresh (because of the 24h TTL) |
| `memos-hub-mcp/` | Python MCP server wrapping v2 hub API for Claude Code |

With v2 deprecated (decision doc: `memos-setup/learnings/2026-04-27-v2-deprecated-revert-to-v1.md`), the CEO needs v1-targeting equivalents that talk to the v1 MemOS server at `localhost:8001`.

## Required outcome after this task ships

CEO has all the same capabilities, but against v1:

1. **Search across all agent cubes** via v1's `CompositeCubeView` — CEO authenticates with a long-lived BCrypt-hashed agent key (no token refresh needed), passes its readable cube list, and gets results from all of them tagged with `cube_id`.
2. **Write to its own `ceo-cube`** via v1's standard `/product/add`.
3. **No token refresh.** v1 keys don't expire. Daily cron entry can be removed (the parallel v2-cleanup task is removing it).
4. **CEO's MCP integration with Claude Code** — pick one (decision required, see deliverable 4 below):
   - (a) New `scripts/ceo/memos-server-mcp/` — Python MCP server wrapping v1 endpoints (drop-in replacement for the deleted `memos-hub-mcp/`).
   - (b) Document that the CEO uses the `memos-toolset` Hermes plugin like worker agents do, just with broader cube read scope. Drop the dedicated MCP server.

   **Recommendation: (b).** Simpler, fewer moving parts, identical UX through the plugin's `memos_store` / `memos_search` tools. Only choose (a) if there's a concrete CEO-specific tool need the plugin doesn't support.

## Deliverables

All NEW files (do NOT edit any existing v2 file). Suggested layout:

| Path | Purpose |
|---|---|
| `scripts/ceo/memos-search-v1.sh` | v1 replacement for `memos-search.sh`. Posts to `localhost:8001/product/search` with `Authorization: Bearer $MEMOS_API_KEY`. Reads `MEMOS_READABLE_CUBE_IDS` (comma-sep) and includes them in the request body. Returns the same JSON shape as the v2 version so any consumer is drop-in. Same arg surface (`"query" [--max N] [--raw]`). |
| `scripts/ceo/memos-write-v1.sh` | v1 replacement for `memos-write.sh`. Posts to `localhost:8001/product/add` writing to `ceo-cube`. Same arg surface as the v2 version (`--content "..." [--summary "..."] [--agent ceo] [--chunk-id ID]`). The `--summary` and `--chunk-id` semantics may differ in v1 — document any divergence in the script header. |
| `scripts/ceo/README-v1.md` | Usage doc for the v1 scripts. Mirrors the v2 README structure. Documents the env-var contract (`MEMOS_ENDPOINT`, `MEMOS_API_KEY`, `MEMOS_USER_ID`, `MEMOS_WRITABLE_CUBE_IDS`, `MEMOS_READABLE_CUBE_IDS`). Documents the chosen MCP path (a or b above). |
| `deploy/profiles/ceo.env.example` | Template for the CEO's profile env. Shows the five variables above. NO real keys committed (template only). |
| `scripts/ceo/memos-server-mcp/` (only if you choose option a) | Python MCP server wrapping v1 endpoints. Mirror the existing `memos-hub-mcp/` structure (server.py + requirements.txt + README.md). Tools exposed: `memos_search`, `memos_recent`, optionally `memos_list_skills` if v1 supports skill enumeration. |

## CEO provisioning verification

The CEO needs to exist as an agent in `agents-auth.json` with multi-cube read access. PR #15 restored `deploy/scripts/setup-memos-agents.py`. Verify:

1. The script can provision a CEO with `MEMOS_USER_ID=ceo`, `MEMOS_WRITABLE_CUBE_IDS=ceo-cube`, `MEMOS_READABLE_CUBE_IDS=research-cube,email-marketing-cube,ceo-cube` (or the actual deployed cube list).
2. The script grants the CEO read access to all worker cubes via `UserManager.add_user_to_cube`. If not, extend the script to support a `--ceo` flag that does this.
3. Document the exact invocation in `README-v1.md`. The operator runs this once; the BCrypt hash lands in `agents-auth.json` and the raw key is printed once.

## Tests

Add `scripts/ceo/tests-v1/`:

- `test_memos_search_v1.sh` — bats-style or plain bash. With `curl` swapped to a fake (e.g. set `MEMOS_ENDPOINT=http://127.0.0.1:0` and assert curl fails with the right error code), confirm the script forms the correct request shape, attaches the auth header, parses the response correctly. Cover: no readable cubes set; one cube; comma-separated multi-cube; the `--raw` flag; the `--max N` flag.
- `test_memos_write_v1.sh` — same shape, for write. Cover: minimal content; with `--summary`; with `--chunk-id`.
- `test_e2e_v1.sh` — end-to-end against a live `localhost:8001`. Skip cleanly if the env isn't set (`if ! curl -fs http://localhost:8001/health >/dev/null; then skip; fi`). When live: provision a test cube, write a memory, search for it, confirm the round-trip works end-to-end with the v1 server.

## What NOT to do

- **Do not edit or delete** `scripts/ceo/memos-search.sh`, `memos-write.sh`, `provision-ceo-token.sh`, `provision-worker-token.sh`, `refresh-ceo-token.sh`, or anything under `scripts/ceo/memos-hub-mcp/`. The v2-cleanup task is removing them.
- **Do not edit** `deploy/cron/hermes-memos.crontab`, `deploy/scripts/install-infra.sh`, or `deploy/systemd/memos-hub.service`. The v2-cleanup task is handling those.
- **Do not commit any real API keys.** The CEO's raw key is operator-side, printed once during provisioning, lives in the runtime profile env at `~/.hermes/profiles/ceo/.env` (chmod 600), never the repo.

## Working rules

- **Branch:** `feat/ceo-v1-scripts`
- Push to and PR against the **Hermes repo's `main`**
- PR title: `feat(ceo): v1 replacements for hub-targeted CEO scripts`
- PR body must cross-link the v2-cleanup PR (when its number is known) and explain the MCP decision (a or b).
- **Do not merge yourself.** Hand off for review.

## Deliver

```bash
cd ~/Coding/Hermes-wt/feat-ceo-v1-scripts
git push -u origin feat/ceo-v1-scripts
gh pr create --title "feat(ceo): v1 replacements for hub-targeted CEO scripts" --base main
```

## When you are done

Reply with:
- PR number
- List of files added
- The MCP-server decision (a or b) and one-sentence rationale
- Any v1-server endpoint signatures you needed to discover (e.g. exact request body shape for `/product/search` with multi-cube reads, or the `provision-CEO-with-multi-cube-access` flag in `setup-memos-agents.py` if you had to add one)
- Test-run output (unit tests passing; e2e tests passing if the live server was available)
- Any deferred follow-ups (things that should logically be in the v1-port but aren't in scope for this task)
