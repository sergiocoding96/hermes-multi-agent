# Paperclip × Hermes adapter — authentication gap finding

**Date:** 2026-04-21
**Context:** Sprint 2 Stage 2, `wire/paperclip-employees` (PR #7 merged as `521952b`)
**Follow-up worktree:** `fix/paperclip-agent-auth`

## Summary

`hermes_local` (the Paperclip adapter that spawns Hermes workers) assumes Paperclip is in **unauthenticated** deployment mode. Our Paperclip is configured for **authenticated** mode. The adapter's default prompt template instructs agents to `curl` back to the Paperclip API to mark issues done, but no auth token is ever injected into the subprocess env. Agents thrash trying to authenticate, burn their full turn budget, and time out.

**Critical insight:** the adapter already captures subprocess `stdout` and returns it to Paperclip as the agent's reply. The curl-the-API-to-mark-done pathway is redundant. Overriding the prompt template to skip the API callback makes agents succeed in a single turn without any auth.

## What employee delegation actually does

1. Paperclip fires a wakeup (issue assign, heartbeat, comment).
2. `hermes_local` (inside `paperclipai`) spawns `hermes chat -q "<rendered prompt>" -Q` as a child process.
3. `buildPaperclipEnv()` exports three env vars to the child: `PAPERCLIP_AGENT_ID`, `PAPERCLIP_COMPANY_ID`, `PAPERCLIP_API_URL`. **No bearer token.** No signed JWT.
4. The default prompt template (`DEFAULT_PROMPT_TEMPLATE` in `hermes-paperclip-adapter/dist/server/execute.js`) tells the agent to `curl -X PATCH .../issues/<id> -d '{"status":"done"}'` and post a comment when finished.
5. Those curls return `{"error":"Board access required"}` because Paperclip is in `"deploymentMode":"authenticated"`.
6. The agent retries, burns 30 turns / 600s, timeout kills it.
7. But `execute.js` (lines 388-416) had already captured `stdout` and would have returned it as the result if the agent had just stopped after its first coherent answer.

## Where the gap lives upstream

- `hermes-paperclip-adapter` → `@paperclipai/adapter-utils/dist/server-utils.js` → `buildPaperclipEnv()`
- `hermes-paperclip-adapter` → `dist/server/execute.js` → `DEFAULT_PROMPT_TEMPLATE`

Neither file is ours; both are packaged with `paperclipai`. The adapter was shipped assuming unauthenticated Paperclip, which is the dev default but not the production-style config we chose.

## Why this wasn't obvious

- "Agent timed out" looked like a hang. It was actually a well-behaved agent running a doomed retry loop.
- The run log showed multi-turn coherent output, not error spam — masked the auth failure.
- The adapter's README doesn't mention the deployment-mode assumption.
- We didn't read the prompt template before shipping employee wiring.

## Fix options

### Option 1 — Prompt-template override (chosen for `fix/paperclip-agent-auth`)

Set `adapterConfig.promptTemplate` per agent to a template that doesn't call the Paperclip API at all. The agent's final `stdout` IS the completion — the adapter handles the rest. No auth, no secrets, no upstream patches.

### Option 2 — Inject long-lived `PAPERCLIP_BOARD_TOKEN` via `adapterConfig.env`

Works but leaks a powerful board-level token into every subprocess for its full lifetime. Security regression.

### Option 3 — Patch `buildPaperclipEnv()` to mint a short-lived scoped JWT

The correct upstream fix. Paperclip already has `PAPERCLIP_AGENT_JWT_SECRET` in its process env. The adapter should sign `{ agentId, companyId, exp: +10min }` and export as `PAPERCLIP_AGENT_JWT`. File upstream issue + PR against `hermes-paperclip-adapter`. Out of scope for this sprint.

### Option 4 — Run Paperclip in unauthenticated mode

Flip `deploymentMode` to `"unauthenticated"`. Curls work. Defensible only because Paperclip on tower is Tailscale-network-scoped. Not chosen because it removes a security control we deliberately enabled.

## Lessons (what to save)

1. **Third-party adapters can carry deployment-mode assumptions in their prompt templates.** Always read the prompt template source before relying on an adapter.
2. **stdout capture is the completion mechanism for subprocess-based adapters.** API-callback paths are convenience features, not requirements.
3. **"Agent timed out" has at least three distinct failure modes** — true hang, retry loop, genuine compute bound — distinguishable by whether the run log shows coherent work. Coherent work + timeout = retry loop.
4. **Process CWD matters.** When a long-lived parent process (Paperclip) is started from a directory that later gets deleted, Python subprocesses (`os.getcwd()`) crash instantly. Always set explicit `adapterConfig.cwd` for subprocess adapters. PR #7 bakes `cwd: $HOME` into both employee configs.

## Next step

Follow-up worktree `fix/paperclip-agent-auth` implements Option 1. Brief: `scripts/worktrees/migration/fix/paperclip-agent-auth.md`.
