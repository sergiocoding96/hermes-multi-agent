# MemOS Security & Reliability Blind Audit

Paste this entire prompt into a fresh Claude Code session opened at `/home/openclaw/Coding/Hermes`. Do not provide any additional context.

---

## Prompt

You are conducting an independent security and reliability audit of a MemOS memory system. You have no prior context about this system's quality, known issues, or recent changes. Your job is to discover the truth, not confirm anything.

### System under test

- **MemOS API** runs at `http://localhost:8001` (confirm with `/health` first — if down, start it: `cd /home/openclaw/Coding/MemOS && set -a && source .env && set +a && python3.12 -m memos.api.server_api > /tmp/memos_audit.log 2>&1 &` then wait 12s)
- **Provisioning script**: `/home/openclaw/Coding/Hermes/setup-memos-agents.py`
- **Agent key config**: `/home/openclaw/Coding/Hermes/agents-auth.json`
- **MemOS env**: `/home/openclaw/Coding/MemOS/.env`
- **Patched MemOS files** (the audit target):
  - `/home/openclaw/.local/lib/python3.12/site-packages/memos/api/middleware/agent_auth.py`
  - `/home/openclaw/.local/lib/python3.12/site-packages/memos/api/handlers/search_handler.py`
  - `/home/openclaw/.local/lib/python3.12/site-packages/memos/api/handlers/add_handler.py`
  - `/home/openclaw/.local/lib/python3.12/site-packages/memos/api/handlers/component_init.py`
  - `/home/openclaw/.local/lib/python3.12/site-packages/memos/api/server_api.py`
  - `/home/openclaw/.local/lib/python3.12/site-packages/memos/api/product_models.py`
  - `/home/openclaw/.local/lib/python3.12/site-packages/memos/multi_mem_cube/single_cube.py`
  - `/home/openclaw/.local/lib/python3.12/site-packages/memos/templates/mem_reader_prompts.py`

### What to audit

Conduct the following in order. Write a Python test script for each category. Each test must create its own users/cubes (unique prefix with timestamp to avoid collisions), run the test, and tear down after. Do not reuse data from previous tests.

**1. Read the patched code first.** Understand what security controls exist before testing them. Read every patched file. Take notes on what you find — mechanisms, gaps, assumptions.

**2. Authentication audit.** The system claims to have per-agent API keys. Test:
- What happens with no Authorization header?
- What happens with a valid key + matching user_id?
- What happens with a valid key + wrong user_id? (cross-agent spoofing)
- What happens with an invalid/fake key?
- What happens with a malformed Authorization header (no Bearer prefix, empty, extra spaces)?
- Can you bypass auth by using deprecated fields like `mem_cube_id`?
- Is user_id validated independently of the key, or only when a key is present?
- What is the security model when MEMOS_AUTH_REQUIRED=false vs true?

**3. Cube isolation audit.** The system claims per-agent cube isolation. Test:
- Can agent A read agent B's cube?
- Can agent A write to agent B's cube?
- What happens with `mem_cube_id` (deprecated field) instead of `readable_cube_ids`/`writable_cube_ids`?
- What happens when no cube_ids are provided (fallback path)?
- Can a nonexistent user access real cubes?
- Can a real user access nonexistent cubes?
- Does shared access (e.g., admin shared to multiple cubes) work correctly?
- What happens if you send cube_id with path traversal characters (`../../../etc/passwd`)?

**4. Memory quality audit.** The system uses an LLM (DeepSeek) for memory extraction. Test:
- Write a known fact, search for it — does it come back?
- Write 5 diverse facts, search with a vague/semantic query — how many return?
- Write a 2000+ word document with 7 distinct findings — how many get extracted as separate memories?
- Write the same fact 5 times — how many duplicates are stored?
- Is the output in English or does it contain Chinese characters?
- Write content, then read it back — is the data intact (key names, numbers, dates)?

**5. Edge case audit.** Test:
- Empty message content
- 10KB+ single string
- Unicode, emoji, CJK characters
- SQL injection in user_id field
- Concurrent writes from two different agents

**6. Architectural weakness analysis.** After running all tests, answer:
- Is the authentication model sound or can it be trivially bypassed?
- Are there any TOCTOU (time-of-check-time-of-use) vulnerabilities?
- What happens if the agents-auth.json file is deleted while the server is running?
- Is there any rate limiting on auth failures?
- Are API keys stored in plaintext or hashed?
- What's the blast radius if one key is compromised?

### Output format

For each category, report:
- Number of subtests run
- Pass/fail for each with the HTTP status code or result
- A 1-10 score with explicit justification (not vibes)
- Any vulnerabilities discovered

End with a summary table and an overall assessment of production-readiness.

### Rules

- Do NOT read any previous test scripts in `/tmp/`. Write your own from scratch.
- Do NOT read CLAUDE.md, MEMORY.md, or any plan files — they contain the developer's perspective.
- Base your scores purely on observed behavior, not documentation claims.
- If a test crashes the server, that's a finding — report it.
- Be adversarial. Try to break things. The goal is to find flaws, not confirm quality.
