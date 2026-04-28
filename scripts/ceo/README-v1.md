# CEO v1 Scripts — Bash Access to MemOS v1

These scripts give the CEO Claude Code session read/write access to the MemOS
**v1 server** at `http://localhost:8001`. They replace the v2 hub-targeted
versions (`memos-search.sh`, `memos-write.sh`, `provision-*-token.sh`,
`refresh-ceo-token.sh`, `memos-hub-mcp/`) with a v1-native equivalent.

The relevant decision context is in
[`memos-setup/learnings/2026-04-27-v2-deprecated-revert-to-v1.md`](../../memos-setup/learnings/2026-04-27-v2-deprecated-revert-to-v1.md):
v2 was deprecated; v1 is the production target. v1 keys do not expire, so the
daily token-refresh cron is gone with v2.

---

## What's different from v2

| | v2 hub | v1 server |
|---|---|---|
| Endpoint | `localhost:18992/api/v1/hub/*` | `localhost:8001/product/*` |
| Auth | 24h JWT, daily cron refresh | Long-lived BCrypt-hashed agent key, no refresh |
| Cube model | Hub federates per-agent SQLite | Single MemOS server with `CompositeCubeView` for multi-cube reads |
| Cross-agent search | `/api/v1/hub/search` | `/product/search` with multiple `readable_cube_ids` |
| MCP server | Bundled `memos-hub-mcp/` | None (option **b** below) |

---

## MCP integration decision: **(b) — drop the dedicated MCP server**

The CEO uses the bash scripts in this directory directly via the Bash tool.
There is no `memos-server-mcp/` companion, by deliberate choice:

- The Hermes [`memos-toolset`](../../deploy/plugins/memos-toolset) plugin is
  single-cube. It already covers worker agents writing/searching their own
  cube. The CEO's distinguishing capability is *multi-cube reads*, which
  these bash scripts handle by accepting `MEMOS_READABLE_CUBE_IDS` and
  emitting them in the request body.
- Adding a v1 MCP server would duplicate the curl logic already in these
  scripts without buying any new capability. If a CEO-specific tool need
  surfaces later (e.g. server-side dedup, or cross-cube delete), revisit
  option (a) at that point.

If the CEO is ever bridged into a Hermes worker process, the existing
`memos-toolset` plugin works as-is for write paths against `MEMOS_CUBE_ID=ceo-cube`;
multi-cube reads still go through the bash scripts.

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
