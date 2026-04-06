# MemOS Resilience Blind Audit

Paste this into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

There is a memory storage API at `http://localhost:8001` backed by Neo4j (port 7687), Qdrant (port 6333), and SQLite. Source: `/home/openclaw/.local/lib/python3.12/site-packages/memos/`. Config: `/home/openclaw/Coding/MemOS/.env`. Agent keys: `/home/openclaw/Coding/Hermes/agents-auth.json`.

Your job: **Break this system and see how it recovers.** You are testing resilience — what happens when dependencies fail, when the server restarts, when resources are exhausted, when things go wrong at runtime.

Start by understanding the architecture: what databases are used, what services are running, what the data flow looks like. Then systematically test failure scenarios.

Test the following (create your own test users/cubes, don't reuse existing data):

**Dependency failure:**
- Write 5 memories, verify they're searchable. Then stop Qdrant (`docker stop` or kill the process). Try to search. Try to write. What errors do you get? Are they informative or generic 500s? Start Qdrant again — do the 5 memories still exist? Can you search again without restarting MemOS?
- Same test with Neo4j down.
- What happens if both are down simultaneously?
- What if the SQLite file is locked by another process?

**Server restart:**
- Write 10 memories. Kill the MemOS server (`kill -9`). Restart it. Are all 10 memories still searchable? Are any lost? Is there a warm-up period where search quality is degraded?

**Data durability:**
- Where is data actually stored on disk? Is it in `/tmp`? What survives a reboot?
- Are there any in-memory-only data structures that are lost on restart?
- Does the scheduler maintain state across restarts?

**Concurrent stress:**
- Send 20 write requests simultaneously from different agents. Do any fail? Do any corrupt data? Do any produce duplicate memories?
- Send 50 search requests simultaneously. Do response times degrade? Do any timeout? Do any return wrong results?
- Send writes and searches simultaneously. Do searches return partially-written data?

**Resource exhaustion:**
- Write 1000 memories to a single cube. Does search still work? How does latency change?
- Send a 1MB payload. Does the server handle it gracefully or crash?
- Open 100 concurrent HTTP connections. Does the server stay responsive?

**Error recovery:**
- Send a request that causes a 500 error. Does the next request work normally or is the server in a broken state?
- Write a memory with the DeepSeek API key invalid/expired. Does the error propagate cleanly? Does it affect other requests?
- What happens if agents-auth.json is malformed JSON? Does the server crash on startup or handle it gracefully?

**Timeout behavior:**
- How long does a fine-mode write take? What if DeepSeek is slow (>30s)? Is there a timeout? Does the client get a response or hang forever?
- The scheduler runs background tasks — what happens if a scheduled task fails? Does it retry? Does it block other tasks?

For each test, report: the scenario, what happened, how long recovery took, and whether data was lost. Score each area 1-10.

Do not read `/tmp/`, `CLAUDE.md`, or existing test scripts.
