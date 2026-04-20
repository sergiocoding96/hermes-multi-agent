# TASK: wire/ceo-hub-access — CEO (Claude Code) can read/write the memos hub

## Goal

Give the Claude Code CEO session the ability to query and optionally write to the MemOS plugin hub. Two paths: minimum viable (bash-based), and clean (MCP-wrapped). Ship minimum viable; upgrade to MCP only if time allows in this worktree.

## Context

- Hub is running at `http://localhost:18992` (default) after Stage 1 gate.
- CEO is a Claude Code session — either long-lived on tower or spawned by Paperclip's `claude_local` adapter.
- Claude Code has MCP support; Hermes plugin writes to SQLite + hub but has no MCP server of its own.
- Hub auth: token-based. The bootstrap admin token was issued in gate; we need either that or a dedicated CEO token.

Prerequisite: [gate](../gate/migrate-setup.md) has merged and hub is running.

## Scope

### Minimum (must ship)

Option 1 — CEO queries hub via Bash `curl`:

1. Mint a CEO-specific hub token (via admin API or config) — not the admin token, a regular user token.
2. Save the CEO token to `~/.claude/memos-hub.env` with `0600` perms (NOT committed).
3. Document the 2–3 most useful curl patterns for the CEO: search, write, list-groups.
4. Add a slash-command-like alias or helper script `scripts/ceo/memos-search.sh` that wraps the curl call. CEO can invoke via Bash tool.

### Polish (nice to have, attempt only if Minimum ships)

Option 2 — MCP server wrapping hub API:

1. Write `scripts/ceo/memos-hub-mcp/server.py` — a Python MCP server exposing `memos_search`, `memos_list_skills`, `memos_recent` tools. Credentials from env, never exposed to LLM.
2. Register with Claude Code: `claude mcp add memos-hub python <path>/server.py`
3. Test from a Claude Code session: invoke `memos_search` with a known-seeded query, verify results.

## Files to touch

**Minimum path:**
- `scripts/ceo/memos-search.sh` — bash wrapper for hub search
- `scripts/ceo/memos-write.sh` — bash wrapper for hub write (optional)
- `scripts/ceo/README.md` — document how CEO uses these

**Polish path (if doing Option 2):**
- `scripts/ceo/memos-hub-mcp/server.py`
- `scripts/ceo/memos-hub-mcp/requirements.txt`
- `scripts/ceo/memos-hub-mcp/README.md`

**Never commit:**
- The CEO hub token itself. Use `.gitignore` to exclude `*.env` in `scripts/ceo/`.

## Acceptance criteria

### For minimum path

- [ ] A CEO-level hub token exists, saved to `~/.claude/memos-hub.env` (not committed).
- [ ] `scripts/ceo/memos-search.sh "some query"` returns matching hub results as JSON.
- [ ] The returned results include cross-agent memories (from at least 2 different source agents) if the hub has such data.
- [ ] The script's output is usable by the CEO (i.e., `jq`-friendly or human-readable, documented).
- [ ] Unit test: seed a memory as `research-agent` → search via CEO's script → find it.

### For polish path (optional)

- [ ] MCP server starts without error.
- [ ] Registered in Claude Code (verify with `claude mcp list`).
- [ ] From a fresh Claude Code session, `memos_search` tool is available and returns results.
- [ ] Credentials never appear in tool-call args or results shown to the LLM.

## Test plan

Seed a unique memory as `research-agent` via that profile's plugin (Hermes CLI):

```bash
hermes -p research-agent chat -q "Unique marker CEO-ACCESS-<ts>: rocket fuel is made of hydrazine." --no-memory-on-exit
```

Wait 5s for auto-capture. Then from a shell:

```bash
bash scripts/ceo/memos-search.sh "CEO-ACCESS-<same ts>"
```

Expected: the memory appears in the result JSON, including the marker string.

## Out of scope

- Do NOT touch Paperclip. CEO access works via direct hub HTTP — Paperclip orchestration is a separate worktree.
- Do NOT modify the plugin itself.
- Do NOT build a memory write tool for the CEO that bypasses the hub — always go through the hub HTTP API.

## Commit / PR

- Branch: as assigned
- PR title: `wire(ceo): CEO access to memos hub via bash (+ optional MCP)`
- PR body: include the seeded-memory retrieval evidence. If MCP done, include tool registration + invocation screenshot/transcript.
