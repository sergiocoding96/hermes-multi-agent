# Paperclip ↔ Hermes adapter setup

Wire Paperclip up so the Opus 4.6 CEO can delegate work to specialist Hermes
workers (`research-agent`, `email-marketing`) via the standard Paperclip
issue assignment flow. This is the operator-facing companion to the
`hermes-paperclip-adapter` npm package.

## What this installs

Three things, in order:

1. **The `hermes_local` adapter** — pulled from npm (`hermes-paperclip-adapter`),
   registered with Paperclip's external-adapter plugin system so it appears
   in the adapter picker alongside `claude_local`, `codex_local`, etc.
2. **Two Paperclip employees** — `Research Agent` and `Email Marketing Agent`,
   each configured with `adapterType=hermes_local` and an `extraArgs`
   pointing at the matching Hermes profile. Both report to the CEO agent.
3. **An updated CEO SOUL.md** — adds a *Your Workforce* section and a
   *Delegating work* section so the CEO knows who the new employees are and
   how to hand off to them using Paperclip's normal issue-assignment flow.

The CEO does **not** get a new function/tool called `hermes_dispatch`.
Delegation is the normal Paperclip pattern: `POST /api/companies/:companyId/issues`
with `assigneeAgentId` set to the worker; the heartbeat scheduler then wakes
the worker and the adapter spawns Hermes for that run.

## Prerequisites

| Requirement | How to check |
|-------------|--------------|
| `paperclipai >= 2026.4.x` (needs external-adapter API at `/api/adapters`) | `curl -sf http://localhost:3100/api/adapters` returns 200 |
| `hermes` CLI on PATH with profiles `research-agent` and `email-marketing` | `hermes profile list` |
| MemOS running on `localhost:8001` with cubes `research-cube` and `email-mkt-cube` | `curl -sf http://localhost:8001/` |
| The CEO agent exists at the expected path (see below) | `ls ~/.paperclip/instances/default/companies/*/agents/*/instructions/SOUL.md` |

If `curl /api/adapters` returns 404 your paperclipai is too old — upgrade it
first (`npm i -g paperclipai@latest` and restart the server).

## Run order

```bash
cd scripts/paperclip

# 1. Register the hermes_local adapter with Paperclip
./install-hermes-adapter.sh

# 2. Create the two employee agents in the CEO's company
COMPANY_ID=a5e49b0d-bd58-4239-b139-435046e9ab91 \
CEO_AGENT_ID=84a0aad9-5249-4fd6-a056-a9da9b4d1e01 \
  ./create-hermes-employees.sh

# 3. Apply the updated CEO SOUL.md
./apply-ceo-soul.sh
```

All three scripts are idempotent and safe to re-run.

### Environment variables

Shared by all scripts unless noted:

- `PAPERCLIP_URL` — defaults to `http://localhost:3100`
- `PAPERCLIP_BOARD_TOKEN` — only needed for non-local deployments; local Paperclip uses `local_implicit` board auth
- `COMPANY_ID` — target company (defaults to the CEO's)
- `CEO_AGENT_ID` — used as `reportsTo` when creating employees
- `HERMES_BIN` — path to the `hermes` binary
- `HERMES_TIMEOUT_SEC` — per-run timeout (default 600)
- `HERMES_MAX_TURNS` — `--max-turns` cap (default 30)

### Tuning employee configs

`create-hermes-employees.sh` sets sensible defaults. To customize (e.g.
switch to Anthropic for one agent, enable worktree mode, pass extra args)
either edit the script in place before running it, or create the agents via
the Paperclip UI once the adapter is installed — the UI exposes the full
`adapterConfig` schema the adapter publishes through
`/api/adapters/hermes_local/config-schema`.

## Verifying end to end

After running the three scripts:

```bash
# Adapter is registered
curl -s http://localhost:3100/api/adapters | jq '.[] | select(.type=="hermes_local")'

# Both employees exist
curl -s http://localhost:3100/api/companies/$COMPANY_ID/agents \
  | jq '.[] | select(.adapterType=="hermes_local") | {id, name}'

# Dispatch a trivial research task from the CEO
curl -s -X POST http://localhost:3100/api/companies/$COMPANY_ID/issues \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Smoke test — research renewable energy trends 2026, 3 bullets max",
    "assigneeAgentId": "<research-agent-id>",
    "status": "todo",
    "priority": "high"
  }'
```

Paperclip's heartbeat scheduler (default cadence ~60s) will wake the
employee on its next tick; you can also force a wake from the UI. Check the
run log in the Paperclip UI or via `GET /api/issues/:id/runs`.

## Error and timeout handling

The adapter inherits Paperclip's standard runtime safety rails:

- **Timeout** — `adapterConfig.timeoutSec` (default 600). On timeout the
  child is SIGTERM'd, gets `graceSec` to exit cleanly, then SIGKILL. The
  run is marked `timedOut: true` and surfaces as a failed heartbeat —
  never a silent hang.
- **Missing profile** — if `hermes -p <profile>` errors (unknown profile,
  missing config, etc.) stderr is captured, `exitCode` is non-zero, and
  the adapter reports a failed run back to Paperclip.
- **Hermes not running / binary missing** — the adapter's
  `testEnvironment` check surfaces this; you can run it from the UI
  (Settings → Adapters → hermes_local → Test) or via
  `POST /api/companies/:companyId/adapters/hermes_local/test-environment`.

## Known limits

- **Concurrency per profile.** Hermes creates a new CLI session per
  invocation, so two concurrent runs to different profiles are fine. Two
  concurrent runs to the *same* profile work (independent sessions) but
  `persistSession: true` means they'll each try to resume the last session
  id; if that matters for your use case, disable `persistSession` or run
  them serially.
- **No prompt history in MemOS until the worker writes there.** MemOS
  entries come from the worker's own skills, not the adapter. The CEO
  cannot see worker output through MemOS until the worker has committed
  it. For immediate verification, watch the Paperclip run log, not MemOS.
- **Hermes bin must be on the server's `$PATH`.** Override with
  `adapterConfig.hermesCommand` if the binary is somewhere unusual.

## Rolling back

```bash
# Remove the adapter and its two employees
curl -X DELETE http://localhost:3100/api/adapters/hermes_local
# Then in the UI delete the Research Agent and Email Marketing Agent
# employees, or restore the previous SOUL.md from the .bak created by
# apply-ceo-soul.sh.
```

## References

- `hermes-paperclip-adapter` (npm): https://www.npmjs.com/package/hermes-paperclip-adapter
- Paperclip external-adapter docs: `paperclip-desktop/docs/adapters/external-adapters.md`
- Paperclip delegation pattern: `paperclip-desktop/docs/guides/agent-developer/task-workflow.md` (§ Delegation Pattern)
