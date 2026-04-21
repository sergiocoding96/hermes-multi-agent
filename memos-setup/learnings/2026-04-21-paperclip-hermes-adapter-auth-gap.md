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

## Findings added during `fix/paperclip-agent-auth` execution (2026-04-21)

Option 1 alone was insufficient. Implementing it surfaced two more adapter bugs
that were masked by the original auth failure:

### Bug A — `hermes-paperclip-adapter` reads wake context from the wrong object

`hermes-paperclip-adapter/dist/server/execute.js:100-107, 333` reads
`cfgString(ctx.config?.taskId)` (plus `taskTitle`, `taskBody`, `commentId`,
`wakeReason`, `companyName`, `projectName`). Paperclip's heartbeat service
(`@paperclipai/server/dist/services/heartbeat.js:3151-3169`) calls
`adapter.execute({ runId, agent, runtime, config: runtimeConfig, context, ... })`.
`runtimeConfig` is the resolved agent config (workspace + skills + env) —
it does NOT contain wake-context fields. Those live on `context`
(the `contextSnapshot`).

Concrete evidence: querying
`GET /api/heartbeat-runs/:runId` on a wake with `wakeReason=issue_assigned`
returns `contextSnapshot.taskId`, `contextSnapshot.wakeReason`,
`contextSnapshot.paperclipWake.issue.title` all populated correctly.
`runtimeConfig` contains none of those keys. So the adapter's `buildPrompt`
always sees `taskId=""` and renders the `{{#noTask}}` branch of its
template — regardless of whether Paperclip actually assigned an issue.

Compare with `@paperclipai/adapter-claude-local/dist/server/execute.js:66`:
that adapter correctly reads `context.taskId` / `context.issueId` /
`context.paperclipWake`. Only the hermes adapter has this bug.

Fix: the `patch-hermes-adapter.sh` script in this worktree rewrites the 8
affected reads to `ctx.context?.*` and adds fallbacks to
`ctx.context.paperclipWake.issue.{id,title,body}` so that taskTitle/taskBody
populate from the wake payload when the direct fields aren't set.

### Bug B — paperclipai bundles its own copy of `hermes-paperclip-adapter`

`paperclipai` installs a *local copy* of `hermes-paperclip-adapter` inside
`node_modules/paperclipai/node_modules/hermes-paperclip-adapter/`. When
`paperclipai run` executes, Node resolves the adapter from that bundled
copy — the top-level global install at
`/home/linuxbrew/.linuxbrew/lib/node_modules/hermes-paperclip-adapter/` is
ignored.

Fix: `patch-hermes-adapter.sh` auto-discovers every
`*/hermes-paperclip-adapter/dist/server/execute.js` under the npm global
root and patches all of them. Idempotent via a `patched-by-…-v1` sentinel
comment.

### Finding C — Paperclip does not auto-transition issues to `done`

After bugs A + B were patched, agents correctly saw their assigned task and
produced coherent task-specific replies in a single turn (<15 s). Paperclip
captured the reply as a comment on the issue. BUT the issue did not
transition to `done` — it went to `blocked` a few minutes later with the
system comment *"Paperclip automatically retried continuation for this
assigned in_progress issue after its live execution disappeared, but it
still has no live execution path."*

Root cause: Paperclip's run-handler sets *the run's* status to `succeeded`,
not the issue's status. There is no code path in
`@paperclipai/server/dist/services/heartbeat.js` that transitions an
issue's `status` field to `"done"` based on adapter stdout. That transition
is the agent's responsibility — via `PATCH /api/issues/:id` with
`{"status":"done"}`. That's what the stock adapter prompt's curl step was
doing.

This contradicts the original premise of this learning doc ("stdout capture
is the completion mechanism" — point 2 of the "Lessons" section above).
Revised understanding:

- stdout capture → **issue comment** (yes, automatically).
- issue status → `done` → **only** via agent self-PATCH, or external
  reconciliation. No stdout protocol exists for this.

Consequence for TASK.md acceptance criterion 6 — `"issue status transitions
to done via Paperclip's own run-handler (NOT via agent-initiated API
call)"`: literally impossible with current Paperclip. The criterion is
built on an incorrect assumption about Paperclip's behavior.

### Open follow-up (not handled in `fix/paperclip-agent-auth`)

To achieve true end-to-end delegation that leaves the issue in `done`,
Option 3 from this doc (scoped JWT injection) is the correct fix, plus a
prompt template that has the agent emit a single final `PATCH
/issues/:id` call using the injected token. Short-lived (≤ 10 min),
scoped to `{ agentId, companyId, runId }`. Out of scope for the current
worktree.

Alternative (less clean): add a server-side reconciler that watches for
`adapter.exit_code === 0` on an `in_progress` issue with a captured
comment and auto-transitions the issue to `done`. Would need design review
with the Paperclip maintainers.

## Next step

Follow-up worktree `fix/paperclip-agent-auth` implements Option 1 **plus**
the adapter patch for Bug A (via `patch-hermes-adapter.sh`). Brief:
`scripts/worktrees/migration/fix/paperclip-agent-auth.md`. Option 3 remains
open as a separate follow-up.
