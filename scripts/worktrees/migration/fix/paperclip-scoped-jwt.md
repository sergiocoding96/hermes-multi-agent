# TASK: fix/paperclip-scoped-jwt — Mint short-lived scoped JWT so agents can close issues

## Goal

Make Hermes employees transition their assigned issue to `status: "done"` automatically on successful completion. Today (post-PR #8), agents produce the correct reply as a comment via stdout, but the issue's `status` field stays `in_progress` and gets reconciled to `blocked` a few minutes later because Paperclip's run-handler never writes issue status — that's the agent's job.

Implement Option 3 from the [auth-gap learning doc](../../../../memos-setup/learnings/2026-04-21-paperclip-hermes-adapter-auth-gap.md): patch `hermes-paperclip-adapter`'s `buildPaperclipEnv()` to mint a short-lived JWT scoped to the current agent + run, export it as `PAPERCLIP_AGENT_JWT`, and update the prompt template to emit one final `PATCH /issues/:id` call using that token.

## Why this is needed

After PR #8's patch:
- Agent sees the task ✅
- Agent produces coherent reply ✅ (single turn, <15s)
- Reply lands as issue comment via stdout capture ✅
- Run status → `succeeded` ✅
- **Issue status → `done` ❌** — never written by any Paperclip code path. Reconciler demotes to `blocked` after ~2 minutes.

Proof-points for the architecture:
- `hermes-paperclip-adapter/dist/server/execute.js` does not PATCH the issue.
- `@paperclipai/server/dist/services/heartbeat.js` contains no `status.*done` write; the only hit is a READ at line 3530.
- `@paperclipai/adapter-claude-local` (the reference adapter) relies on the underlying Claude Code session calling the Paperclip API with its own auth — which Hermes doesn't have.

The Paperclip server process runs with `PAPERCLIP_AGENT_JWT_SECRET` in its env (verified from the launch command). That secret is what the adapter should use to mint subprocess JWTs.

## Scope

1. **Patch `buildPaperclipEnv()`** in `@paperclipai/adapter-utils/dist/server-utils.js` (bundled inside `paperclipai/node_modules/hermes-paperclip-adapter/node_modules/`). Sign a JWT with:
   - Algorithm: whatever Paperclip's auth middleware expects (inspect `@paperclipai/server/dist/middleware/auth.js` or similar). Likely HS256.
   - Claims: `{ sub: agent.id, companyId: agent.companyId, runId, scope: "agent-run", iat, exp }`.
   - Expiry: 10 minutes.
   - Secret: `process.env.PAPERCLIP_AGENT_JWT_SECRET` (fail hard if missing).
   - Export via `PAPERCLIP_AGENT_JWT` in the returned env dict.
2. **Script the patch.** Extend `scripts/paperclip/v2/patch-hermes-adapter.sh` (or write a peer `patch-hermes-adapter-jwt.sh`) to rewrite `buildPaperclipEnv()` in both global and bundled copies. Same safety invariants as PR #8: sentinel comment, timestamped backup, `node --check` post-write, exact-match replacement with abort-on-miss.
3. **Extend the prompt template.** After the "your final message IS the completion" block, add a single explicit final step:
   - `PATCH {{paperclipApiUrl}}/issues/{{taskId}} -H "Authorization: Bearer $PAPERCLIP_AGENT_JWT" -d '{"status":"done"}'`
   - Keep it minimal — one call, no "post a comment" step (comment already handled by stdout capture).
   - Still forbid all other API calls.
4. **Verify Paperclip accepts the JWT.** Mint one manually with the same logic, call `GET /api/companies/:id` with it, expect 200. If 401, the claim format is wrong — inspect the server-side verify function.
5. **End-to-end smoke test.** Assign a task, wait ≤60s, verify issue ends in `status: "done"`, run ends in `status: "succeeded"`, no 401s in the run log.

## Files to touch

- `scripts/paperclip/v2/patch-hermes-adapter-jwt.sh` (new) OR extend `patch-hermes-adapter.sh`
- `scripts/paperclip/v2/prompts/hermes-employee.mustache` — add the single PATCH step inside `{{#taskId}}`
- `scripts/paperclip/v2/README.md` — document the new env var and the run order change (patch → restart → apply)

**Do NOT touch:**
- `paperclipai` itself beyond the adapter patch.
- `deploymentMode`. Stay on `"authenticated"`.
- Any board-level API keys. Do NOT inject `PAPERCLIP_BOARD_TOKEN` — that's Option 2 which we rejected.

## Acceptance criteria

- [ ] JWT minted per agent-run, scope limited to `{ agentId, companyId, runId }`, exp ≤ 10min.
- [ ] Agent subprocess has `PAPERCLIP_AGENT_JWT` in its env (confirmed by logging the subprocess env through `redactEnvForLogs()`).
- [ ] Manual sanity call: `curl -H "Authorization: Bearer <minted>" .../api/companies/...` → HTTP 200.
- [ ] Delegation smoke test: assign a task to Research Agent → within 60s, issue status is `done` (not `blocked`).
- [ ] Delegation smoke test: same for Email Marketing Agent.
- [ ] Run log shows exactly one `PATCH /issues/:id` call, no 401s.
- [ ] Agent cannot read other agents' issues using the minted JWT (attempt it and verify 403) — scope is properly enforced.
- [ ] JWT expiry is respected (attempt a call using a JWT that was minted >10min ago, verify 401).

## Test plan

```bash
source ~/.paperclip/board-token.env   # for control-plane checks, not for agent
TS=$(date +%s); MARKER="SCOPED-JWT-$TS"

# Assign
curl -sf -X POST "$PAPERCLIP_URL/api/companies/$COMPANY_ID/issues" \
  -H "Authorization: Bearer $PAPERCLIP_BOARD_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"title\": \"$MARKER: one-sentence summary of TCP vs UDP\",
       \"assigneeAgentId\": \"$RESEARCH_AGENT_ID\",
       \"status\": \"todo\", \"priority\": \"high\"}" \
  | jq -r '.id' > /tmp/issue-id

sleep 60
# Inspect final state
curl -sf "$PAPERCLIP_URL/api/issues/$(cat /tmp/issue-id)" \
  -H "Authorization: Bearer $PAPERCLIP_BOARD_TOKEN" \
  | jq '{title, status, assigneeAgentId, completedAt}'
# Expected: status: "done"
```

## Out of scope

- Do NOT file the upstream issue against `hermes-paperclip-adapter` in this worktree — that's a separate documentation task (draft exists at `docs/upstream-issue-draft.md` after PR #8).
- Do NOT add scope claims beyond `{agentId, companyId, runId}`. Keep claims minimal.
- Do NOT rotate `PAPERCLIP_AGENT_JWT_SECRET` here. Rotation is a Paperclip-ops concern.
- Do NOT add a server-side reconciler. The scoped-JWT approach avoids needing one.

## Commit / PR

- Branch: as assigned (`claude/*` or `fix/paperclip-scoped-jwt`)
- PR title: `fix(paperclip): mint scoped JWT so hermes employees can transition issues to done`
- PR body: include the minted JWT claim shape (redacted signature), smoke test evidence (status: "done"), and the "scope enforcement" probe evidence (403 on other agent's issue).

## Appendix — JWT format discovery

Before writing the minter, inspect Paperclip's auth middleware to find the expected claim shape:

```bash
find /home/linuxbrew/.linuxbrew/lib/node_modules/paperclipai -path '*@paperclipai/server*' -name 'auth*.js' | head
grep -rhE "jwt\.(verify|sign)\b|PAPERCLIP_AGENT_JWT_SECRET|verifyJwt" \
  /home/linuxbrew/.linuxbrew/lib/node_modules/paperclipai/node_modules/@paperclipai/server/dist/ \
  2>/dev/null | head -30
```

Pick the algorithm and claim names Paperclip actually checks. If it only accepts one audience (`aud`) claim, mirror it. Do NOT guess — a wrong claim shape will look like "it works for most requests but 401s on a few" which is hard to debug.
