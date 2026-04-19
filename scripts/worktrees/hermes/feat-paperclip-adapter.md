# TASK: feat/paperclip-adapter — install hermes-paperclip-adapter

## Goal
Install `hermes-paperclip-adapter` in the Paperclip CEO instance so the Opus 4.6 CEO can dispatch tasks to Hermes MiniMax workers.

## Context
From [2026-04-08-status-review-and-next-steps.md](https://github.com/sergiocoding96/hermes-multi-agent/blob/main/memos-setup/learnings/2026-04-08-status-review-and-next-steps.md):
> hermes-paperclip-adapter not installed in Paperclip — CEO agent cannot spawn Hermes workers yet. This is the critical missing link for the full orchestration loop.

Paperclip runs on tower at `http://tower.taila4a33f.ts.net:3100`. The CEO instance path is in [CLAUDE.md](https://github.com/sergiocoding96/hermes-multi-agent/blob/main/CLAUDE.md):
> `~/.paperclip/instances/default/companies/.../agents/84a0aad9-.../instructions/SOUL.md`

The adapter registers as a tool in Paperclip's registry so the CEO's SOUL.md can call e.g. `hermes_dispatch(profile="research-agent", task="...")`.

## Pre-flight
- [ ] Paperclip process is running on tower. Confirm: `curl -sf http://localhost:3100/health` or equivalent health route.
- [ ] Find the adapter's source: check `~/Coding/` for `hermes-paperclip-adapter` or on npm/pypi. The name hints at a first-party tool — if it doesn't exist locally, check Paperclip's adapter SDK docs for how to build one.
- [ ] Confirm Hermes CLI works: `hermes -p research-agent chat -q "hello"` returns a response.

## Acceptance
- [ ] Adapter installed into Paperclip's adapter registry (exact path depends on Paperclip's layout — find it).
- [ ] CEO SOUL.md updated so it knows the adapter is available and when to call it.
- [ ] Dispatching a task from the CEO to `research-agent` profile works end-to-end:
  - CEO calls `hermes_dispatch(profile="research-agent", task="Research renewable energy trends 2026, brief summary only")`.
  - Adapter spawns `hermes -p research-agent chat -q "..."` (or uses Python library mode if supported).
  - Hermes returns a response within the configured timeout.
  - Response is surfaced back to the CEO as the adapter tool's result.
- [ ] Dispatching to `email-marketing-agent` profile also works.
- [ ] Timeout handling: if Hermes takes > N seconds, adapter returns a clear error to the CEO (not a silent hang).
- [ ] Error handling: if the profile doesn't exist, adapter returns a clear error.
- [ ] CEO can check if Hermes is healthy before dispatching (optional but recommended).

## Open question: CLI subprocess or Python library?
Two implementation options:
1. **CLI subprocess** (simpler) — adapter shells out to `hermes -p <profile> chat -q "..."` and captures stdout.
2. **Python library mode** (more reliable, planned as H8 anyway) — adapter imports `run_agent.AIAgent` and calls it in-process.

Pick **CLI subprocess** for this task (fastest to get working). Python library is a separate branch (`feat/python-library-adapter`).

## Test plan
```bash
# 1. Healthcheck (from tower):
curl -sf http://localhost:3100/health

# 2. From the CEO (via whatever Paperclip UI you use):
#    Dispatch a short research task to research-agent.
#    Confirm the response comes back in < 60s.

# 3. Error injection:
#    - Stop Hermes temporarily, dispatch again → adapter must return a clean error.
#    - Dispatch to a nonexistent profile → adapter must return a clean error.
#    - Pass a very long task that exceeds hermes' agent.max_turns → timeout gracefully.

# 4. Concurrency:
#    - Dispatch 2 tasks in parallel (different profiles). Both should succeed.
#    - Dispatch 2 tasks to the SAME profile. Check if Hermes tolerates concurrent sessions
#      (it should, each creates its own session). If not, document the limit.
```

## Commit / PR
Branch: `feat/paperclip-adapter`
PR title suggestion: `feat(paperclip): install hermes adapter for CEO → worker dispatch`

Include in PR body:
- Which adapter source/package was used
- Example CEO → Hermes dispatch log
- Known limits (concurrency, timeout)

## Out of scope
- Don't implement python-library mode (that's H8, separate branch).
- Don't wire the soft feedback loop yet (H4, separate branch).
- Don't add adapter auth between CEO and Hermes yet — tower is Tailscale-only, can defer.
