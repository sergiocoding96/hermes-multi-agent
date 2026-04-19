# TASK: feat/memos-dual-write — skills write to MemOS

## Goal
After every research output, the research-coordinator skill persists the result to the agent's MemOS cube so memory compounds across sessions.

## Context
From [2026-04-08-status-review-and-next-steps.md](https://github.com/sergiocoding96/hermes-multi-agent/blob/main/memos-setup/learnings/2026-04-08-status-review-and-next-steps.md):
> Dual-write not in skills — Research output is not persisted to MemOS after skill runs. Memory does not compound yet.

CLAUDE.md also specifies:
> Skills must chunk long output into ≤500-word blocks before POSTing to MemOS for best extraction quality.

Once [feat/fast-mode-chunking](../memos/feat-fast-mode-chunking.md) lands, the server will chunk for us. Until then, keep the client-side chunking.

## Prerequisite
**This task depends on [feat/memos-provisioning](feat-memos-provisioning.md) being merged first.** You need:
- A valid `MEMOS_API_KEY` in each profile's `.env`
- A valid cube (e.g. `research-agent-cube`) already provisioned

Verify before starting:
```bash
cat ~/.hermes/profiles/research-agent/.env | grep MEMOS_API_KEY
curl -sf http://localhost:8001/health
```

## Files to change
- `~/.hermes/skills/research/research-coordinator/SKILL.md` (and the dev copy at `skills/research/research-coordinator/SKILL.md` in this repo)
- `deploy/plugins/memos-toolset/` already exists — prefer calling its `memos_store` tool over raw curl. That's the whole point of the plugin (identity injected from env, zero credentials in the LLM context).
- Same pattern for `plusvibe.ai` email-marketing skill

## Acceptance
- [ ] research-coordinator, after producing its final brief, calls `memos_store(content=<chunk>, tags=[...])` for every ≤500-word chunk of the brief.
- [ ] Chunks tagged with: `topic=<derived>`, `source=research-coordinator`, `session_id=<id>`, `quality_score=<0-1>` (from the existing self-eval).
- [ ] plusvibe email-marketing skill does the same on campaign summaries.
- [ ] Failures on the MemOS call do NOT fail the skill — log warning, continue. Memory is best-effort.
- [ ] Success: a fresh research run produces N memories visible in MemOS within 10 seconds (sync mode).
- [ ] CEO (via MemOS search) can retrieve the memories across sessions.
- [ ] Trigger the blind audit § 6 — cross-cube access still works correctly with the new compounding data.

## Approach
Look at how the `memos-toolset` plugin is invoked from existing skills (if any). If it's a Hermes native tool registration, the skill just calls `memos_store(...)` as a tool. If it's currently unused, wire the plugin first.

Chunking: reuse the chunking function from the plugin, or import `tiktoken` / do a naive 500-word split.

## Test plan
```bash
# 1. Run research-coordinator end to end:
hermes -p research-agent chat -q "Research AI agent frameworks 2026 — brief, ≤800 words"

# 2. Immediately after, query MemOS for the session's memories:
KEY=$(grep MEMOS_API_KEY ~/.hermes/profiles/research-agent/.env | cut -d= -f2)
curl -sS -X POST http://localhost:8001/product/search \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"query":"AI agent frameworks","user_id":"research-agent","top_k":10}' \
  | jq '.data[] | {content: .content[:100], tags}'

# expect: multiple memories tagged source=research-coordinator with content excerpts
# from the brief. Tags should include the session_id and topic.

# 3. CEO retrieval:
CEO_KEY=<ceo-key>
curl -sS -X POST http://localhost:8001/product/search \
  -H "Authorization: Bearer $CEO_KEY" -H "Content-Type: application/json" \
  -d '{"query":"AI agent frameworks","user_id":"ceo","top_k":10}' \
  | jq '.data[] | {cube_id, content: .content[:100]}'
# expect: same memories, tagged with cube_id research-agent-cube.

# 4. Failure mode:
#    Temporarily point MEMOS_API_KEY to garbage. Run research-coordinator again.
#    Skill MUST still produce a brief. Only MemOS write should fail silently with a warn.
```

## Commit / PR
Branch: `feat/memos-dual-write`
Two commits recommended:
1. `feat(skills): research-coordinator persists brief chunks to MemOS`
2. `feat(skills): plusvibe persists campaign summaries to MemOS`

Include before/after memory counts in the PR body.

## Out of scope
- Don't implement the hard feedback loop (quality_score → auto-patch). That's H5.
- Don't implement the soft feedback loop (user feedback → skill patch). That's H4.
- Don't change the memos-toolset plugin itself unless a clear bug blocks you.
