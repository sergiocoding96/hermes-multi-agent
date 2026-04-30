# MemOS v1 Hermes Plugin Integration Audit

Paste this as your FIRST message into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`. No other context should be present.

---

## Prompt

The Hermes side of the v1 stack is the `memos-toolset` plugin at `~/.hermes/plugins/memos-toolset/`. It exposes memory operations (likely `memos_store`, `memos_search`, possibly `memos_delete`) to Hermes agents and is configured via a per-agent profile at `~/.hermes/profiles/<agent>/.env` containing `MEMOS_API_KEY`, `MEMOS_USER_ID`, `MEMOS_CUBE_ID`, and possibly `MEMOS_ENDPOINT`. The plugin is the **only path** an agent has to MemOS — there is no direct HTTP access from agent prompts. (OpenClaw has an analogous plugin under `~/.openclaw/`.)

Two demo agents (per the project goal) use this:
- **research-agent** — multi-turn research with the `research-coordinator` skill.
- **email-marketing-agent** — plusvibe.ai email marketing.

The CEO orchestrator on Paperclip reads across agent cubes via `CompositeCubeView`.

**Your job: prove the plugin contract holds end-to-end and find every place where the boundary leaks.** Score 1-10, MIN across sub-areas. Adopt the stance: anything the LLM can do that bypasses the profile-env identity model is a bug.

Use marker `V1-PI-<unix-ts>` on every memory / cube / query you create.

### Zero-knowledge constraint

Do NOT read any of:
- `/tmp/**` beyond files you created this run
- `CLAUDE.md` at any level
- `tests/v1/reports/**`, `tests/v2/reports/**`
- `tests/blind-*`, `tests/zero-knowledge-audit.md`, `tests/security-remediation-report.md`
- `memos-setup/learnings/**`
- any `TASK.md` or plan file
- any commit message that mentions "audit", "score", "fix", or "remediation"

Inputs allowed: this prompt, the live system, source under `/home/openclaw/Coding/MemOS/src/memos/**`, the Hermes plugin under `~/.hermes/plugins/memos-toolset/**`, and Hermes core docs under `~/.hermes/skills/` if needed for plugin invocation. Discover everything else.

### Throwaway profile (provision before any probe)

The plugin reads identity from the profile env, so we provision two distinct profiles for cross-isolation testing:

```bash
curl -s http://localhost:8001/health | jq . || (
  cd /home/openclaw/Coding/MemOS
  set -a && source .env && set +a
  python3.12 -m memos.api.server_api > /tmp/memos-v1-pi.log 2>&1 &
  sleep 5
)

export MEMOS_HOME=/tmp/memos-v1-audit-$(uuidgen)
mkdir -p "$MEMOS_HOME/data"
TS=$(date +%s)
python3.12 /home/openclaw/Coding/Hermes/deploy/scripts/setup-memos-agents.py \
  --output "$MEMOS_HOME/agents-auth.json" \
  --agents \
    "audit-v1-pi-alpha:V1-PI-A-$TS" \
    "audit-v1-pi-beta:V1-PI-B-$TS"

# stand up two throwaway profiles under a temp Hermes home
export HERMES_HOME=/tmp/hermes-v1-pi-$(uuidgen)
mkdir -p "$HERMES_HOME/profiles/alpha" "$HERMES_HOME/profiles/beta"
# write profile env files using the keys printed by setup-memos-agents.py
# (each .env should contain MEMOS_API_KEY, MEMOS_USER_ID, MEMOS_CUBE_ID, MEMOS_ENDPOINT)
chmod 600 "$HERMES_HOME/profiles/alpha/.env" "$HERMES_HOME/profiles/beta/.env"
```

Teardown:
```bash
rm -rf "$MEMOS_HOME" "$HERMES_HOME"
sqlite3 ~/.memos/data/memos.db <<SQL
DELETE FROM users WHERE user_id LIKE 'audit-v1-pi%';
DELETE FROM cubes WHERE cube_id LIKE 'V1-PI-%';
SQL
```

### Recon (first 5 minutes)

1. Inventory the plugin directory: `ls -la ~/.hermes/plugins/memos-toolset/`. What entry points (`SKILL.md`, scripts, configs)? What does the SKILL.md tell the LLM?
2. Find the identity-loading code in the plugin. Is it strictly `os.environ.get("MEMOS_API_KEY")`, or does it also accept arguments from the LLM?
3. Find the HTTP client. What endpoint does it default to? How does it discover the MemOS port?
4. Look for any tool that the LLM could call to "switch user / cube" — that would be a privilege-escalation vector if present.
5. Note the OpenClaw plugin (`~/.openclaw/plugins/...`) and note structural differences vs Hermes — they should both follow the same model.

### Probe matrix

**Tool surface exposure.**
- List every tool the plugin exposes to the agent. Names, arg schemas, return shapes.
- For each tool: does the schema include any "user_id" or "cube_id" parameter? If yes, can the LLM override the env-derived identity? Try in a sandbox session.
- Are there any "admin" tools (clear, delete-all, switch-cube) accessible from a normal agent?

**Identity-from-env enforcement.**
- Run a sandbox Hermes agent that loads a profile with cube `V1-PI-A-<ts>`. Have the agent call `memos_store("hello", cube_id="V1-PI-B-<ts>")` (or however the override is shaped). Did the plugin honor the override (escalation), refuse, or silently coerce to the env value?
- Mutate the profile env mid-session (touch the .env file). Does the plugin re-read or hold the original? Document the security impact.

**Auth header propagation.**
- Capture the HTTP request the plugin sends. Confirm `Authorization` (or `X-API-Key`) is the BCrypt-hashed-key reference, not the raw key in any logged form.
- Confirm the API key never appears in a tool result returned to the LLM (would leak it into agent context window → into model traces).

**Round-trip from agent to MemOS and back.**
- Agent stores a memory via `memos_store("V1-PI-roundtrip-A")`. Verify the SQLite row exists with the correct `user_id` and `cube_id` from the env.
- Agent searches via `memos_search("V1-PI-roundtrip")`. Result includes only its own cube's memories?
- Switch profiles, repeat. Result set should be disjoint.

**Auto-capture path (v1.0.3).**
- Confirm the plugin auto-captures turn content without an explicit tool call. Find the hook (likely a session-end / turn-end callback in the Hermes harness).
- Submit content the agent shouldn't capture (e.g. tool-call boilerplate, system prompts). Is it filtered? On what criteria?
- Force a capture failure (block port 8001 for 1 s). Does the plugin queue, retry, or drop? Is the agent informed (returns an error to its tool-call loop), or kept blind?

**Concurrent agents on the same machine.**
- Run two sandbox agents in parallel (alpha + beta profiles). Each writes 50 memories. Verify isolation — search results are disjoint, no cross-profile leakage in logs.
- The Sprint 4 hub-sync.py path (cross-agent sharing) — if engaged, confirm it respects per-cube ACL and only replicates what the source cube allows.

**CompositeCubeView from CEO side.**
- Simulate the CEO Paperclip path that uses CompositeCubeView. Reads must be tagged with `cube_id`. Verify the tag round-trips through the plugin to the LLM-visible result.
- Try to write via CompositeCubeView path — the CEO should not write to worker cubes. Confirm.

**Endpoint discovery / failover.**
- Set `MEMOS_ENDPOINT=http://wrong-host:8001` in a profile. Does the plugin error fast and clearly, or hang?
- Set `MEMOS_ENDPOINT` to a malicious URL (e.g. `http://attacker.example`). Does the plugin send the API key there? It SHOULD have an allowlist or scheme/host validation. If not, that's a finding.

**Plugin update / reload.**
- Modify a file under `~/.hermes/plugins/memos-toolset/` while the agent is mid-session. Is the change picked up, or does it require restart?
- Same for `~/.hermes/profiles/<agent>/.env` — already tested above; document explicitly.

**Logging & observability (plugin side).**
- Where does the plugin log? Per-profile or global? Are tool calls logged with input + output, or summarized?
- Does the plugin redact the API key, or does the raw key end up on disk?

### Reporting

For every finding:

- Class: identity-leak / privilege-escalation / silent-coercion / cross-profile-leak / unredacted-secret / capture-loss / discovery-failure.
- Reproducer: exact agent invocation + plugin call.
- Evidence: HTTP request + headers, plugin log, agent transcript, DB row.
- Severity: Critical / High / Medium / Low / Info.
- One-sentence remediation.

Final summary table:

| Area | Score 1-10 | Key findings |
|------|-----------|--------------|
| Tool surface (no admin / no escalation) | | |
| Identity-from-env enforcement | | |
| Auth header propagation + redaction | | |
| Agent ↔ MemOS round-trip correctness | | |
| Auto-capture (v1.0.3) reliability | | |
| Concurrent-agent isolation | | |
| CompositeCubeView (CEO) read-only | | |
| Endpoint discovery + URL allowlist | | |
| Plugin reload behaviour | | |
| Plugin-side logging + secret redaction | | |

**Overall plugin-integration score = MIN.** Close with a one-paragraph judgement: do the demo agents (research-agent + email-marketing-agent + CEO orchestrator) get correct, isolated, observable memory access through this plugin?

### Out of bounds (re-asserted)

Do NOT read `/tmp/` beyond files you created this run, `CLAUDE.md`, prior audit reports, plan files, learning docs, or any commit message that telegraphs prior findings.

### Deliver

```bash
git fetch origin tests/v1.0-audit-reports-2026-04-30
git switch tests/v1.0-audit-reports-2026-04-30
git pull --rebase origin tests/v1.0-audit-reports-2026-04-30
# write tests/v1/reports/plugin-integration-v1-$(date +%Y-%m-%d).md
git add tests/v1/reports/plugin-integration-v1-*.md
git commit -m "report(tests/v1.0): plugin-integration audit"
git push origin tests/v1.0-audit-reports-2026-04-30
```

Do not open a PR. Do not modify any other file. Do not push to `main` or any other branch.
