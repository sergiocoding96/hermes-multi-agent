# TASK: wire/paperclip-employees — Create Paperclip employees for Hermes workers

## Goal

Using Paperclip's built-in `hermes_local` adapter (already a dependency of Paperclip, no install needed), create employees in Paperclip for the `research-agent` and `email-marketing` Hermes profiles. Verify the CEO can delegate tasks to them.

## Context

Paperclip's `server/package.json` and `ui/package.json` declare `hermes-paperclip-adapter` as a dependency. When Paperclip installs, the adapter ships with it. No need to run an install script — the adapter type `hermes_local` is registered out of the box.

What's missing is **employees** using that adapter. You'll create them either via Paperclip's UI or its HTTP API.

Prerequisite: [Stage 1 gate](../gate/migrate-setup.md) must have merged. Plugin is installed on at least `research-agent`.

## Scope

1. Discover Paperclip's company ID + CEO agent ID (already present, see `~/.paperclip/instances/default/workspaces/`).
2. Get a Paperclip BOARD_TOKEN from its UI (user action — document the path for them).
3. Create employee `research-agent` with adapter `hermes_local` pointed at Hermes profile `research-agent`.
4. Create employee `email-marketing-agent` with adapter `hermes_local` pointed at Hermes profile `email-marketing`.
5. Verify each employee is present via the API.
6. Verify delegation: ask the CEO via Paperclip UI to assign a trivial task to each employee, wait for completion, inspect the response.

## Files to touch

**New scripts:**
- `scripts/paperclip/v2/create-research-employee.sh` — creates the `research-agent` employee via Paperclip API.
- `scripts/paperclip/v2/create-email-employee.sh` — same for email-marketing.
- `scripts/paperclip/v2/README.md` — replaces the older `install-hermes-adapter.sh` flow. Document: (a) no adapter install needed, (b) how to get BOARD_TOKEN, (c) how to run the employee-create scripts.

**Archive:**
- Move `scripts/paperclip/install-hermes-adapter.sh` → `scripts/paperclip/_archive/` with a note explaining it's obsolete (adapter is built into Paperclip).
- Leave `scripts/paperclip/create-hermes-employees.sh`, `apply-ceo-soul.sh` — those are still useful references.

## Acceptance criteria

- [ ] Paperclip BOARD_TOKEN documented (path to retrieve, NOT committed).
- [ ] `GET /api/adapters` shows `hermes_local` registered (evidence: JSON output).
- [ ] `POST /api/companies/<id>/agents` returns 200 for each employee creation.
- [ ] `GET /api/companies/<id>/agents` lists both new employees.
- [ ] From Paperclip UI, the CEO can assign a trivial task (e.g., "write a one-sentence summary of HTTP status codes") to `research-agent` employee. The task completes within 60s and returns a response.
- [ ] Same delegation test for `email-marketing-agent`.
- [ ] Response content is sane (not an error message, not a silent hang).

## Test plan

Use a unique marker `PAPERCLIP-WIRE-<timestamp>` in test task descriptions so delegations don't collide with real traffic.

```bash
# Pattern for employee creation:
PAPERCLIP_URL="http://localhost:3100"
BOARD_TOKEN="${PAPERCLIP_BOARD_TOKEN}"  # user-supplied, not committed
COMPANY_ID="${COMPANY_ID}"              # discover via /api/companies

curl -sS -X POST "$PAPERCLIP_URL/api/companies/$COMPANY_ID/agents" \
  -H "Authorization: Bearer $BOARD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "research-agent",
    "title": "Research specialist (Hermes + MiniMax)",
    "adapter": {
      "type": "hermes_local",
      "config": {
        "profile": "research-agent",
        "timeoutSec": 600,
        "maxTurnsPerRun": 30
      }
    }
  }'
```

Adjust the payload shape based on Paperclip's actual schema — peek at its source at `~/Coding/paperclip/packages/adapters/claude-local/src/` for a similar reference, or at `/api/adapters` output for the schema.

## Out of scope

- Do NOT set up Telegram channels.
- Do NOT wire CEO hub access (separate worktree).
- Do NOT move Paperclip to Python-library mode (that's Stage 5 Phase 3).
- Do NOT create employees for profiles beyond research + email-marketing.

## Commit / PR

- Branch: as assigned (`claude/*` or `wire/paperclip-employees`)
- PR title: `wire(paperclip): create research + email employees via built-in hermes_local adapter`
- PR body: include the two delegation smoke-test results.
