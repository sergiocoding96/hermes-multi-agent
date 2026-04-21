# memos-hub MCP Server

Python MCP server wrapping the memos hub API. Gives Claude Code native tool access to hub
search, skill listing, and recent-activity browsing — without exposing credentials to the LLM.

## Tools

| Tool | Description |
|------|-------------|
| `memos_search` | FTS + vector search across all hub memories/chunks |
| `memos_list_skills` | List or search skills published by Hermes agents |
| `memos_recent` | Recent memories and shared tasks |

## Install

```bash
pip3 install -r scripts/ceo/memos-hub-mcp/requirements.txt --break-system-packages
```

## Register with Claude Code

```bash
# Source credentials first so the server can read them
source ~/.claude/memos-hub.env

# Register (Claude Code re-reads env from the shell that registers it)
claude mcp add memos-hub \
  --env MEMOS_HUB_URL="$MEMOS_HUB_URL" \
  --env MEMOS_HUB_TOKEN="$MEMOS_HUB_TOKEN" \
  -- python3 "$(pwd)/scripts/ceo/memos-hub-mcp/server.py"
```

Verify registration:
```bash
claude mcp list
```

## Usage (from a Claude Code session)

Once registered, the tools are available in any Claude Code session without
writing any Bash or passing credentials:

```
Use memos_search("hydrazine rocket fuel") to find relevant memories.
```

## Credential security

- `MEMOS_HUB_TOKEN` and `MEMOS_HUB_URL` are read from the process environment.
- They are **never** passed to the LLM as tool arguments or returned in results.
- The server uses them only in the `Authorization` header for hub HTTP calls.
- Credentials rotate independently of MCP registration; update via:
  `claude mcp remove memos-hub && (re-register with new token)`
