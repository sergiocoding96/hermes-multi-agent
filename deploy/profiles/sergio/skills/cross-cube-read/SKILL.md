---
name: cross-cube-read
description: Read across all Hermes profile cubes in the memos-local-plugin store. Use ONLY for orchestration/debugging — see another agent's private traces, episodes, sessions. Day-to-day, use `memory_search` instead (it already sees the shared pool).
allowed_tools: ["bash", "file"]
---

# cross-cube-read — orchestrator read access across profiles

## When to use this skill

**You're sergio.** This skill exists because you orchestrate the other agents. By default, your normal `memory_search` already sees:
- Your own private memory
- Everything anyone has promoted to `share_scope='local'` (the cron promoter does this every 15 min for traces, policies, skills, world-models)

Use this skill **only** when:
- You need to inspect another agent's *private* memory (raw L1 traces, the un-promoted stuff) for debugging — "why did research-agent's last task go wrong?"
- You need to enumerate ALL profiles and see what each has been doing
- You need to find a specific row by some criterion and the standard `memory_search` isn't surfacing it

For everything else, prefer `memory_search` or dispatch a task back to the source agent via Hermes Kanban. Asking research-agent "give me the timeline of episode X" gets you their full context — better than peeking at the raw DB.

## How it works

The 2.0 plugin enforces per-profile namespace isolation at the storage layer. A row owned by `research-agent` is invisible to `sergio`'s `memory_search` unless promoted to `local`.

This skill uses a small Python helper (`peek.py`) that opens the shared SQLite directly **read-only** with no namespace filter. It exposes four queries:

- `peek.py profiles` — list every profile that has ever written
- `peek.py search <query>` — full-text search across all cubes (no FTS, just LIKE)
- `peek.py timeline <profile> [n]` — last N traces from a specific profile (default 20)
- `peek.py episode <episode_id>` — full timeline of one episode, regardless of owner

## Usage

The helper lives at `~/.hermes/profiles/sergio/skills/cross-cube-read/peek.py`.

```bash
# List profiles in the store
python3 ~/.hermes/profiles/sergio/skills/cross-cube-read/peek.py profiles

# Search across all cubes
python3 ~/.hermes/profiles/sergio/skills/cross-cube-read/peek.py search "competitor pricing"

# Last 20 traces from research-agent
python3 ~/.hermes/profiles/sergio/skills/cross-cube-read/peek.py timeline research-agent

# Full episode timeline
python3 ~/.hermes/profiles/sergio/skills/cross-cube-read/peek.py episode ep_7s382nyfjcbs
```

Output is JSON. Pipe to `jq` if you want it pretty.

## Privacy note

This bypasses the plugin's privacy model. The other agents have no idea you read their private traces. Use it sparingly. If you find yourself running this multiple times a day, that's a signal to fix the underlying problem — either promote more aggressively in the cron script, or rely on Kanban dispatch instead.

## Upgrade safety

`peek.py` reads core columns from migrations 001 (`traces.user_text/agent_text/summary/episode_id/owner_profile_id/ts`, `episodes.id/owner_profile_id/session_id/started_at`, `sessions.id`). These columns are unlikely to change across minor plugin versions; upstream adds columns rather than renaming them. If a future major version renames any of these, the script breaks loudly and we update it.
