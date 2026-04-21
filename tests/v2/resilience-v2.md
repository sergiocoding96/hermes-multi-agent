# Hermes v2 Resilience Blind Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## System Under Test

Same as functionality audit. Focus: what breaks and how does it recover?

## Your Job

**Verify the system handles failures gracefully — hub down, DB corrupt, concurrent load, process crash.** Score resilience 1-10.

Create unique test markers: `RES-AUDIT-<timestamp>`.

## Probes

1. **Hub restart during capture:** Start a Hermes session. While it's running, kill the hub process. What does the agent see? Does it retry? After hub restart, is the captured data still there?

2. **Corrupt SQLite:** Kill the agent, corrupt its local SQLite file (truncate 100 bytes), restart. Does the agent crash or gracefully recover? Can it still search?

3. **Disk full:** While capturing, fill the agent's disk to capacity. What happens? Does it error gracefully or lose data?

4. **100 concurrent writes:** Start 5 Hermes agents simultaneously, each writing 20 messages rapidly. Any dropped captures? DB corruption?

5. **Malformed LLM response during skill evolution:** If the plugin calls an LLM to generate skills, what happens if the response is invalid JSON or missing required fields? Graceful fallback?

6. **Agent process killed mid-capture:** Write a message, then `kill -9` the agent process immediately. Is the partial capture lost or replayed on restart?

7. **Hub SQL injection attempts:** Try to craft search queries that would SQL-inject the hub's SQLite. Does it sanitize inputs?

8. **Memory pressure:** Write 10k memories (simulated via bulk insert). Can the agent still search? Does performance degrade gracefully?

9. **Concurrent search and capture:** While capturing, repeatedly search. Any race conditions? Lost updates?

10. **Partial hub sync:** Agent offline, write to local DB. Reconnect hub. Does it sync back correctly? Any dupes?

## Report

For each failure mode: test description, expected recovery, actual behavior, evidence, and 1-10 resilience score.

Summary table with overall resilience score.
