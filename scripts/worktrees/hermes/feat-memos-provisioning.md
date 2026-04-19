# TASK: feat/memos-provisioning — provision MemOS cubes for all agents

## Goal
Run the provisioning script against the live MemOS server, verify every agent has its own cube, the CEO has cross-cube access, and each profile's `.env` is populated with the raw API key. This unblocks dual-write (H3) and every Phase 3 loop.

## Context
From [2026-04-08-status-review-and-next-steps.md](https://github.com/sergiocoding96/hermes-multi-agent/blob/main/memos-setup/learnings/2026-04-08-status-review-and-next-steps.md):
> `setup-memos-agents.py` exists but cubes have not been created for each agent. MemOS is live; just needs the script to run.

Note: the server uses v2 bcrypt auth. The script generates raw keys once and writes bcrypt hashes to `agents-auth.json` — raw keys are printed to stdout and must be captured.

## Files to read/run
- `setup-memos-agents.py` — the provisioning script (at the Hermes repo root)
- `agents-auth.json` — existing registry (back up before running)
- `deploy/profiles/research-agent/.env` and `deploy/profiles/email-marketing/.env` — where to put raw keys

## Pre-flight
- [ ] MemOS health check passes: `curl -sf http://localhost:8001/health`
- [ ] Backup existing `agents-auth.json`: `cp agents-auth.json agents-auth.json.bak.$(date +%s)`
- [ ] Confirm admin key is set: `echo $MEMOS_ADMIN_KEY` (or in ~/.memos/secrets.env.age)

## Acceptance
- [ ] After running, `agents-auth.json` has entries for: `ceo`, `research-agent`, `email-marketing-agent` (minimum). Audit-*/test entries preserved.
- [ ] Each of the 3 agents has its own cube (named per the script's convention — `research-agent-cube`, etc.). Verified by listing cubes as each agent.
- [ ] CEO has **read access** to research-agent-cube AND email-marketing-cube (via explicit `share_cube_with_user`).
- [ ] Cross-cube search test: CEO searches for content written by research-agent, gets it with `cube_id: "research-agent-cube"` in the result metadata.
- [ ] Isolation test: research-agent cannot read email-marketing-cube → 403.
- [ ] Each profile's `.env` has `MEMOS_API_KEY=ak_...` filled in (raw key from script output).
- [ ] `~/.hermes/.env` (NOT `deploy/config/.env.template`) also updated if CEO runs via global profile.
- [ ] Run the blind audit § 6 — cross-cube isolation and CEO multi-cube access must still score 9-10.

## Test plan
From `~/Coding/Hermes-wt/feat-memos-provisioning`:

```bash
# 1. Run the script (captures output):
python3 setup-memos-agents.py 2>&1 | tee provisioning-$(date +%s).log

# 2. Capture the raw keys from the log output. They're printed ONCE.
#    Example output line: "research-agent: ak_abc123def456..."

# 3. Write a memory as each agent:
for AGENT in research-agent email-marketing-agent; do
  KEY=<raw-key-from-log>
  curl -sS -X POST http://localhost:8001/product/add \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d "{\"user_id\":\"$AGENT\",\"writable_cube_ids\":[\"${AGENT}-cube\"],\"messages\":[{\"role\":\"user\",\"content\":\"Seed from provisioning verification\"}],\"async_mode\":\"sync\",\"mode\":\"fast\"}"
done

# 4. CEO cross-cube search:
CEO_KEY=<ceo-raw-key>
curl -sS -X POST http://localhost:8001/product/search \
  -H "Authorization: Bearer $CEO_KEY" -H "Content-Type: application/json" \
  -d '{"query":"seed","user_id":"ceo","top_k":10}' \
  | jq '.data[] | {content, cube_id}'
# expect results from BOTH cubes, each tagged with its cube_id.

# 5. Isolation test (should 403):
RESEARCH_KEY=<research-raw-key>
curl -i -X POST http://localhost:8001/product/search \
  -H "Authorization: Bearer $RESEARCH_KEY" -H "Content-Type: application/json" \
  -d '{"query":"anything","user_id":"research-agent","writable_cube_ids":["email-marketing-agent-cube"],"top_k":5}'
# expect HTTP 403.
```

## Handling results
The script prints raw keys ONCE. If you lose them:
- Re-run the script only after deleting `agents-auth.json` (you'll lose all history of previous keys).
- Or use the admin router to `rotate_key` for a specific agent.

## Commit / PR
Branch: `feat/memos-provisioning`
Commits to make:
1. `chore(memos): run provisioning against live server — <date>` — commits the new `agents-auth.json` (bcrypt hashes only; **never** commit the raw keys or the log file).
2. `chore(deploy): placeholder .env updates for profiles` — only if you want to update the template files.

**Do not commit the raw API keys anywhere.** Add `provisioning-*.log` to `.gitignore` if not already.

## Out of scope
- Don't create new agents beyond what's in `setup-memos-agents.py`.
- Don't change the bcrypt cost factor in the script.
- Don't touch MemOS source. This is pure ops.
