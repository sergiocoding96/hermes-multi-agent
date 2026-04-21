# CEO Hub Access — Bash Scripts

These scripts give the Claude Code CEO session read/write access to the memos hub at
`http://localhost:18992`. Two options: bash curl (minimum, always works) and MCP server
(polish, gives Claude Code native tool access).

---

## Prerequisites

1. Hub must be running: `bash scripts/migration/bootstrap-hub.sh research-agent`
2. CEO token must be provisioned (one-time): `bash scripts/ceo/provision-ceo-token.sh`

Both produce artifacts under `~/.hermes/memos-state-research-agent/` (secrets) and
`~/.claude/memos-hub.env` (CEO token). None of these are committed.

---

## Quick start

```bash
# 1. Start hub (if not already running)
cd ~/Coding/Hermes
bash scripts/migration/bootstrap-hub.sh research-agent

# 2. Provision CEO token (one-time)
bash scripts/ceo/provision-ceo-token.sh

# 3. Source credentials
source ~/.claude/memos-hub.env

# 4. Search
bash scripts/ceo/memos-search.sh "hydrazine rocket fuel"

# 5. Write
bash scripts/ceo/memos-write.sh \
  --content "CEO note: confirmed hydrazine monopropellant used on Northrop Grumman LEO sats." \
  --summary "CEO note: hydrazine propellant confirmation"
```

---

## Scripts

### `provision-ceo-token.sh`

Mints a CEO-specific hub token (role: `member`, not admin) and saves it to
`~/.claude/memos-hub.env` (0600). Safe to re-run: idempotent via stable `identityKey`.

```bash
bash scripts/ceo/provision-ceo-token.sh
```

### `memos-search.sh`

Searches hub memories and shared chunks. Returns JSON with hits ranked by
FTS + vector RRF. Each hit includes `summary`, `excerpt`, `ownerName`, `sourceAgent`,
`taskTitle`, and `remoteHitId` (for fetching full content via `memory-detail`).

```bash
# Basic search
bash scripts/ceo/memos-search.sh "query"

# Return up to 20 results
bash scripts/ceo/memos-search.sh "query" --max 20

# Raw JSON (useful for piping)
bash scripts/ceo/memos-search.sh "query" --raw | jq '.hits[0].excerpt'
```

**Useful jq patterns:**

```bash
# Get all source agents in results
bash scripts/ceo/memos-search.sh "topic" | jq '[.hits[].sourceAgent] | unique'

# Print summaries
bash scripts/ceo/memos-search.sh "topic" | jq '.hits[].summary'

# Filter to a specific agent's memories
bash scripts/ceo/memos-search.sh "topic" | jq '[.hits[] | select(.sourceAgent == "research-agent")]'
```

### `memos-write.sh`

Shares a memory to the hub from the CEO session. Always goes through the hub HTTP API
(never writes SQLite directly). Memories are `public` and visible to all hub members.

```bash
bash scripts/ceo/memos-write.sh \
  --content "Full memory text here" \
  --summary "Short summary for search" \
  --agent "ceo"            # optional, defaults to "ceo"
  --chunk-id "stable-id"   # optional, defaults to random UUID
```

---

## Hub API — raw curl patterns

If you prefer raw curl (e.g., in one-shot CEO Bash tool calls):

```bash
# Source credentials first
source ~/.claude/memos-hub.env

# List recent memories
curl -s "$MEMOS_HUB_URL/api/v1/hub/memories?limit=20" \
  -H "Authorization: Bearer $MEMOS_HUB_TOKEN" | jq '.memories'

# Search
curl -s -X POST "$MEMOS_HUB_URL/api/v1/hub/search" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $MEMOS_HUB_TOKEN" \
  -d '{"query":"your query","maxResults":10}' | jq '.hits'

# List hub skills
curl -s "$MEMOS_HUB_URL/api/v1/hub/skills/list" \
  -H "Authorization: Bearer $MEMOS_HUB_TOKEN" | jq '.skills'

# List recent hub tasks
curl -s "$MEMOS_HUB_URL/api/v1/hub/tasks" \
  -H "Authorization: Bearer $MEMOS_HUB_TOKEN" | jq '.tasks'

# Write a memory
curl -s -X POST "$MEMOS_HUB_URL/api/v1/hub/memories/share" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $MEMOS_HUB_TOKEN" \
  -d '{
    "memory": {
      "sourceChunkId": "unique-id-for-dedup",
      "sourceAgent": "ceo",
      "role": "assistant",
      "content": "Memory content here",
      "summary": "Short summary",
      "kind": "paragraph"
    }
  }' | jq '.'
```

---

## MCP Server (optional polish)

See `memos-hub-mcp/README.md` for the Python MCP server that wraps these APIs as
Claude Code native tools (`memos_search`, `memos_list_skills`, `memos_recent`).

With MCP registered, the CEO session can call `memos_search` directly as a tool without
writing any Bash — credentials never appear in tool-call args or LLM context.

---

## Security notes

- The CEO token is a `member`-role hub token. It cannot approve users, delete others'
  resources, or access admin endpoints.
- The token is stored at `~/.claude/memos-hub.env` (0600). It is excluded from git via
  `scripts/ceo/.gitignore`.
- The admin token at `~/.hermes/memos-state-research-agent/secrets/hub-admin-token` is
  only needed for `provision-ceo-token.sh` and is never exposed to the LLM.
- Token expiry: CEO token has a default TTL (~1 year for member tokens). Re-run
  `provision-ceo-token.sh` to rotate if needed.
