# memos-hub MCP Server (v1 backend)

Python MCP server giving the Claude Code CEO session native tool access to MemOS — search, store, skill listing, and recent-activity browsing — without exposing credentials to the LLM.

> **History:** This server used to wrap the v2 hub at port 18992. v2 was deprecated 2026-04-27 (see `memos-setup/learnings/2026-04-27-v2-deprecated-revert-to-v1.md`). The MCP interface is preserved unchanged — same server name (`memos-hub`), same tool names, same parameter signatures, same response shapes — only the backend flips from v2 hub to v1 server. Existing `claude.json` registrations keep working without re-registration.

## Tools

| Tool | Description |
|------|-------------|
| `memos_search` | Search across all configured cubes (CompositeCubeView) — FTS + vector |
| `memos_store` | Write a memory into `MEMOS_WRITABLE_CUBE_IDS` (default `ceo-cube`). `summary` and `chunk_id` are stored as `custom_tags` since v1 has no first-class fields for them. |
| `memos_recent` | Recent memories across configured cubes |
| `memos_list_skills` | List skills from the [badass-skills](https://github.com/sergiocoding96/badass-skills) repo clone at `BADASS_SKILLS_DIR`. Reads `<skill>/SKILL.md` YAML frontmatter; supports a substring query filter. |

## Install

```bash
pip3 install -r scripts/ceo/memos-hub-mcp/requirements.txt --break-system-packages
```

## Configure the env (CEO's profile)

The server reads config from environment variables. Create `~/.hermes/profiles/ceo/.env` (mode 600) using `deploy/profiles/ceo.env.example` as a template:

```bash
MEMOS_ENDPOINT=http://localhost:8001
MEMOS_API_KEY=<raw bearer token printed once during setup-memos-agents.py provisioning>
MEMOS_USER_ID=ceo
MEMOS_WRITABLE_CUBE_IDS=ceo-cube
MEMOS_READABLE_CUBE_IDS=research-cube,email-marketing-cube,ceo-cube
BADASS_SKILLS_DIR=/home/openclaw/Coding/badass-skills
```

`BADASS_SKILLS_DIR` is only consumed by `memos_list_skills` and defaults to `/home/openclaw/Coding/badass-skills` when unset. Keep the clone fresh with `git -C "$BADASS_SKILLS_DIR" pull --ff-only origin main`.

The CEO agent must be provisioned in `agents-auth.json` with multi-cube read access via `UserManager.add_user_to_cube`. `deploy/scripts/setup-memos-agents.py` already supports this (root role + cube grants); see `scripts/ceo/README-v1.md` for the exact invocation.

## Register with Claude Code

```bash
# Source the CEO profile env so the MCP server inherits it
source ~/.hermes/profiles/ceo/.env

claude mcp add memos-hub \
  --env MEMOS_ENDPOINT="$MEMOS_ENDPOINT" \
  --env MEMOS_API_KEY="$MEMOS_API_KEY" \
  --env MEMOS_USER_ID="$MEMOS_USER_ID" \
  --env MEMOS_READABLE_CUBE_IDS="$MEMOS_READABLE_CUBE_IDS" \
  --env MEMOS_WRITABLE_CUBE_IDS="$MEMOS_WRITABLE_CUBE_IDS" \
  -- python3 "$(pwd)/scripts/ceo/memos-hub-mcp/server.py"
```

Verify:

```bash
claude mcp list
```

If you previously registered this server against the v2 hub, **no re-registration is needed** — the server name and tool names are unchanged. The new env vars will be picked up on the next Claude Code session start, but for cleanliness you may want to remove the old v2-era env vars (`MEMOS_HUB_URL`, `MEMOS_HUB_TOKEN`) from `~/.claude.json` since they're no longer read.

## Usage (from a Claude Code session)

Once registered, the tools are available in any Claude Code session without writing any Bash or passing credentials:

```
Use memos_search("quarterly revenue") to find relevant memories across all
cubes the CEO has read access to.

Use memos_recent(limit=10) to see the latest 10 memories across those
cubes.
```

## Backend differences from the v2 era

The MCP interface is identical, but the backend behavior differs in three places. None of these are typically visible to the LLM — they're documented here for operator awareness:

| Aspect | v2 hub backend | v1 server backend (current) |
|---|---|---|
| `memos_search` source | RRF across hub-aggregated memories | CompositeCubeView across `MEMOS_READABLE_CUBE_IDS` |
| `memos_store` | (was bash-only) | New tool — writes to `MEMOS_WRITABLE_CUBE_IDS` via `/product/add` |
| `memos_list_skills` | Hub-issued skill registry | Walks the `badass-skills` repo clone (the source of truth) |
| `memos_recent` | Separate `/memories` and `/tasks` endpoints | `/product/search` with empty query; `tasks` field is always empty |

The response shape (`hits[]` with `rank`, `summary`, `excerpt`, `ownerName`, `sourceAgent`, `taskTitle`, `visibility`, `remoteHitId`) is preserved by an in-server projection so any consumer coded against v2 sees the same fields.

## Credential security

- `MEMOS_API_KEY` is read from the process environment at startup.
- It is **never** passed to the LLM as a tool argument or returned in tool results.
- The server uses it only in the `Authorization: Bearer` header for outbound HTTP calls to MemOS.
- The server refuses to start if the key is unset — fail-loud, not warn-and-continue.
- v1 keys do not expire (they're BCrypt-hashed entries in `agents-auth.json`); no daily refresh is needed (unlike the v2 hub's 24h-TTL JWTs).

## Operator-side fallback

The Bash scripts at `scripts/ceo/memos-search-v1.sh` and `scripts/ceo/memos-write-v1.sh` cover the same surface for shell-level work (debugging, cron, manual probing). They read the same env vars and call the same v1 endpoints. Use whichever fits your context — MCP for the LLM session, Bash for the shell.
