# CEO v1 Interfaces — MCP + Bash Access to MemOS v1

This directory gives the CEO Claude Code session read/write access to the MemOS **v1 server** at `http://localhost:8001`. It replaces the v2 hub-targeted setup (`memos-search.sh`, `memos-write.sh`, `provision-*-token.sh`, `refresh-ceo-token.sh`, and the v2-hub backend behind `memos-hub-mcp/`) with v1-native equivalents.

The relevant decision context is in [`memos-setup/learnings/2026-04-27-v2-deprecated-revert-to-v1.md`](../../memos-setup/learnings/2026-04-27-v2-deprecated-revert-to-v1.md): v2 was deprecated; v1 is the production target. v1 keys do not expire, so the daily token-refresh cron is gone with v2.

---

## Two interfaces, two audiences

| Interface | Audience | Primary use |
|---|---|---|
| **MCP server** at `memos-hub-mcp/` | The CEO Claude Code session on Paperclip | Native LLM tool calls — `memos_search`, `memos_recent`, `memos_list_skills` |
| **Bash scripts** (`memos-search-v1.sh`, `memos-write-v1.sh`) | Operators in a shell, cron, manual probing | Shell-level work, debugging, scripted writes |

Both layers read the same env vars and call the same v1 endpoints. They're complementary, not redundant: MCP for the LLM session because Claude Code consumes MCP tools natively; Bash for everything that runs outside an LLM context.

The MCP server preserves the original v2-era server name (`memos-hub`) and tool signatures so any existing `claude.json` registration keeps working without re-registration. See [`memos-hub-mcp/README.md`](memos-hub-mcp/README.md) for the MCP-side usage details.

---

## What's different from v2

| | v2 hub | v1 server |
|---|---|---|
| Endpoint | `localhost:18992/api/v1/hub/*` | `localhost:8001/product/*` |
| Auth | 24h JWT, daily cron refresh | Long-lived BCrypt-hashed agent key, no refresh |
| Cube model | Hub federates per-agent SQLite | Single MemOS server with `CompositeCubeView` for multi-cube reads |
| Cross-agent search | `/api/v1/hub/search` | `/product/search` with multiple `readable_cube_ids` |
| MCP server | `memos-hub-mcp/` (called the v2 hub) | `memos-hub-mcp/` (calls v1 server, same interface) |
| Skills enumeration | `/api/v1/hub/skills` | Not yet supported on v1; tool returns empty + note |

The MCP server's tool surface is identical between the two backends — same names, same parameters, same response shapes (the v1 backend projects v1 responses onto the v2-shaped `hits[]` array internally so consumers see no change).

---

## Prerequisites

1. **MemOS v1 server running** at `localhost:8001`
   ```bash
   cd /home/openclaw/Coding/MemOS && python -m memos.api.server
   ```

2. **CEO provisioned in `agents-auth.json`.** The provisioning script already
   supports the CEO out of the box — no `--ceo` flag is needed:

   ```bash
   python3.12 deploy/scripts/setup-memos-agents.py
   ```

   The script creates the `ceo` user (role: `root`), the `ceo-cube`, and
   shares `research-cube` and `email-mkt-cube` into the CEO via
   `UserManager.add_user_to_cube`. A bcrypt-hashed key is written to
   `agents-auth.json`; the raw key is printed once and must be saved into
   `~/.hermes/profiles/ceo/.env` (chmod 600). See
   [`deploy/scripts/setup-memos-agents.py`](../../deploy/scripts/setup-memos-agents.py)
   for the source of truth.

3. **CEO env profile** at `~/.hermes/profiles/ceo/.env`. Template is
   `deploy/profiles/ceo.env.example`. Required variables:

   ```sh
   MEMOS_ENDPOINT=http://localhost:8001
   MEMOS_API_KEY=ak_...                  # raw key, printed once by the script above
   MEMOS_USER_ID=ceo
   MEMOS_WRITABLE_CUBE_IDS=ceo-cube
   MEMOS_READABLE_CUBE_IDS=ceo-cube,research-cube,email-mkt-cube
   ```

   `chmod 600 ~/.hermes/profiles/ceo/.env`.

---

## Quick start

### From a Claude Code session (CEO)

If the MCP server is registered (see [`memos-hub-mcp/README.md`](memos-hub-mcp/README.md) for the one-time `claude mcp add` command), Claude Code can just call the tools:

```
Use memos_search("hydrazine rocket fuel") to find what research-agent and
email-marketing-agent know about this.

Use memos_recent(limit=10) to see the last 10 memories across all cubes
the CEO has read access to.
```

No bash, no credentials in the LLM context.

### From a shell (operator)

```bash
# 1. Source the CEO profile (the scripts auto-load it if CEO_ENV_FILE is unset
#    and ~/.hermes/profiles/ceo/.env exists).
export CEO_ENV_FILE=~/.hermes/profiles/ceo/.env

# 2. Search across all cubes the CEO can read.
bash scripts/ceo/memos-search-v1.sh "hydrazine rocket fuel"

# 3. Write to the CEO's own cube.
bash scripts/ceo/memos-write-v1.sh \
  --content "CEO note: confirmed hydrazine monopropellant used on Northrop Grumman LEO sats." \
  --summary "CEO note: hydrazine propellant confirmation"
```

---

## Scripts

### `memos-search-v1.sh`

Searches the v1 server's `/product/search` endpoint, passing every cube id in
`MEMOS_READABLE_CUBE_IDS` to invoke the `CompositeCubeView`. Output is
projected onto the same JSON shape as the v2 hub variant — `{ query,
totalHits, hits, meta }` — so existing CEO consumers (`jq '.hits[].summary'`)
keep working. v1 fields the v2 shape exposed but v1 doesn't (e.g. taskTitle)
are surfaced as `null`.

```bash
bash scripts/ceo/memos-search-v1.sh "query"
bash scripts/ceo/memos-search-v1.sh "query" --max 20
bash scripts/ceo/memos-search-v1.sh "query" --raw | jq '.data.text_mem[0]'
```

`--raw` returns the unfiltered v1 response (useful for debugging the
adapter). Without `--raw`, results are normalized.

### `memos-write-v1.sh`

Writes to the v1 server's `/product/add` endpoint targeting the cubes in
`MEMOS_WRITABLE_CUBE_IDS` (default `ceo-cube`). The v2 script's `--summary`
and `--chunk-id` flags are kept for arg-compatibility, but v1's `/product/add`
has no first-class summary or external dedup-key field, so they are stored as
`custom_tags` (`summary:<text>`, `chunk_id:<id>`). Search consumers can still
filter by tag.

```bash
bash scripts/ceo/memos-write-v1.sh \
  --content "Full memory text here" \
  --summary "Short summary" \
  --agent "ceo" \
  --chunk-id "stable-id"
```

`--mode {fine,fast}` controls MemReader extraction. Default is `fine`. Use
`fast` for transient/raw notes the CEO doesn't expect to be re-extracted.

---

## v1 endpoint reference (raw curl)

```bash
source ~/.hermes/profiles/ceo/.env

# Search across cubes
curl -s -X POST "$MEMOS_ENDPOINT/product/search" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $MEMOS_API_KEY" \
  -d '{
    "query": "your query",
    "user_id": "ceo",
    "readable_cube_ids": ["ceo-cube","research-cube","email-mkt-cube"],
    "top_k": 10,
    "relativity": 0.05,
    "dedup": "mmr"
  }' | jq '.data.text_mem[].memories[] | { content: .memory, cube: .metadata.cube_id }'

# Write
curl -s -X POST "$MEMOS_ENDPOINT/product/add" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $MEMOS_API_KEY" \
  -d '{
    "user_id": "ceo",
    "writable_cube_ids": ["ceo-cube"],
    "messages": [{"role":"assistant","content":"Memory body"}],
    "async_mode": "sync",
    "mode": "fine",
    "custom_tags": ["agent:ceo","summary:Short summary"]
  }' | jq '.'
```

---

## Tests

Unit and end-to-end checks live in [`tests-v1/`](tests-v1/):

```bash
bash scripts/ceo/tests-v1/test_memos_search_v1.sh
bash scripts/ceo/tests-v1/test_memos_write_v1.sh
bash scripts/ceo/tests-v1/test_e2e_v1.sh   # skips if localhost:8001 not reachable
```

The unit tests run a small in-process Python `http.server` that records the
request shape, so they don't need a live MemOS instance.

---

## Security notes

- `MEMOS_API_KEY` is the raw bcrypt-pre-image. Never commit it. Live in
  `~/.hermes/profiles/ceo/.env` (mode 0600) only. The hash in
  `agents-auth.json` is what the server verifies against.
- The CEO is provisioned with role `root`; the v1 server applies cube ACLs
  via `UserManager`, not role gating, so the practical access surface is
  exactly the cubes the CEO has been added to (`ceo-cube`, `research-cube`,
  `email-mkt-cube`).
- Rotate by deleting the `ceo` entry from `agents-auth.json` and re-running
  the provisioning script. Update `~/.hermes/profiles/ceo/.env` with the
  new raw key.
