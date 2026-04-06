# MemOS Observability Blind Audit

Paste this into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

There is a memory storage API at `http://localhost:8001`. Source: `/home/openclaw/.local/lib/python3.12/site-packages/memos/`. Config: `/home/openclaw/Coding/MemOS/.env`. Logs output to stderr/stdout of the server process.

Your job: **Determine whether an operator can understand what this system is doing, diagnose problems, and respond to incidents.** You're evaluating logging, error messages, monitoring, and debuggability.

**Logging quality:**
- Trigger a successful write, a successful search, a 403 (auth failure), a 401 (bad key), a 400 (empty content), and a 500 (if you can trigger one). Read the server log. For each:
  - Is the event logged at all?
  - Is the log level appropriate (INFO/WARNING/ERROR)?
  - Does the log contain enough context to diagnose the issue (user_id, cube_id, error detail)?
  - Does the log contain too much context (API keys, full memory content, PII)?
  - Is there a trace/request ID that correlates related log entries?

**Error messages to callers:**
- For each error status code (400, 401, 403, 422, 500), is the error message helpful to the caller without leaking internal details?
- Does a 500 error expose stack traces, file paths, or internal state?

**Health monitoring:**
- Does `/health` actually verify backend connectivity (Neo4j, Qdrant) or just return a static 200?
- If Neo4j is down, does `/health` still say healthy?
- Is there a metrics endpoint? Prometheus? StatsD?
- Is there a way to check scheduler status without reading logs?

**Debugging a production issue:**
- Simulate: a user reports "my search returns nothing." With only API access and logs, can you determine: Is the memory written? Is the embedding correct? Is the search finding candidates but filtering them out? Is it a reranker issue?
- Simulate: a user reports "write takes 30 seconds." Can you determine from logs whether the bottleneck is the LLM, embedding, or DB write?

**Audit trail:**
- Can you determine from logs/DB who wrote a specific memory, when, and from what request?
- Can you determine who searched for what and when?
- If a memory was deleted, is there a record of who deleted it?

Score 1-10 on whether an operator can run this system confidently. Report specific gaps.

Do not read `/tmp/`, `CLAUDE.md`, or existing test scripts.
