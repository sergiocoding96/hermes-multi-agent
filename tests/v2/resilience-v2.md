# Hermes v2 Resilience Blind Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

There is a local memory plugin (`@memtensor/memos-local-hermes-plugin`). Per-profile SQLite at `~/.hermes/memos-state-<profile>/memos-local/memos.db` (WAL-mode). Hub HTTP server on `http://localhost:18992`. Bridge daemon on `http://localhost:18990`. Hub process PID in `~/.hermes/memos-state-<profile>/hub.pid`. Plugin source at `~/.hermes/memos-plugin-<profile>/`.

Your job: **Break this system in every way you can think of, and measure how it recovers.** Score resilience 1-10 with evidence.

Approach: test dependency failure, resource exhaustion, concurrent stress, process kills, and corruption. Create your own test data with marker `RES-AUDIT-<timestamp>`. Restart the hub and profile stores between scenarios so each test is isolated.

### Recon

Understand before breaking:

- Read `package.json` to learn runtime version + key deps.
- Find the retry / backoff logic in the capture pipeline. Is there a dead-letter queue? An outbox pattern?
- Find the hub's upstream dependencies: embedder (local Xenova), summarizer (remote LLM like DeepSeek), disk, fs.
- Map the failure blast radius: if SQLite is locked, what's blocked — writes only, or also reads? What about hub requests from other clients?

### Failure scenarios

**Hub process kill:**
- Write 10 memories via a client. Get the hub PID from `~/.hermes/memos-state-<profile>/hub.pid`. `kill -9 <pid>`. What does the client see mid-request? A clean 5xx, a hang, an infinite retry?
- Restart the hub. Are the 10 memories still present? Searchable? Is there a warm-up during which results are incomplete?

**Bridge daemon kill:**
- Same drill on port 18990. What functionality degrades when only the bridge is down but the hub is up?

**SQLite corruption:**
- Stop the plugin. Truncate the last 1024 bytes of `memos.db`. Restart the plugin. Does it crash, rebuild from WAL, rebuild from scratch, or silently lose data?
- Repeat with `memos.db-wal` truncated. Repeat with `memos.db-shm` deleted.
- Append random bytes to `memos.db` mid-file. Does the plugin detect it on next read?

**Concurrent writes:**
- Fire 100 parallel POST requests to the hub capture endpoint with unique markers. Count rows landed in SQLite. Any drops? Any rows with corrupted fields?
- While those 100 run, fire 50 read queries. Are any reads delayed by writes (lock contention)? Any deadlock timeouts?

**Disk pressure:**
- Fill the disk to 99% full (in a scratch location that can be cleaned). Attempt a capture. Clean behavior (5xx) or corruption?
- Fill it to 100%. What happens?
- Clean up: delete the fill file, restart. Does the plugin recover without manual intervention?

**File-descriptor exhaustion:**
- Open ~1000 HTTP connections to the hub and hold them. Does the hub stop accepting new connections cleanly, or does something crash?

**Malformed requests:**
- POST raw binary garbage to the capture endpoint. Response?
- POST valid JSON with wrong fields (missing `content`, extra fields, wrong types). Does the server 400 or crash?
- POST a 100MB payload. Rate-limited? Memory-bloated?

**Network chaos (if you can safely):**
- Simulate slow link on `localhost:18992` (e.g. `tc qdisc` if privileged, or an iptables rate limit). Does the client timeout gracefully?
- Drop packets. Does the client retry sanely?

**Summarizer failure:**
- Plugin uses a remote LLM (DeepSeek or similar) for task summarization. Point the env var to an unreachable host (or block egress). Does the plugin queue, skip, crash, or retry-forever?
- Restore the summarizer. Does it catch up on the queued summaries?

**Embedder failure:**
- Xenova embedder is local. What happens if the model file is missing or corrupted? (Rename the model cache, restart.)

**Plugin process kill mid-capture:**
- Start writing a large 10k-word capture. While it's mid-flight, `kill -9` the plugin. On restart, is the partial capture present, absent, or corrupt?
- Same but with `kill -TERM` (graceful). Does graceful shutdown save in-flight captures?

**Rapid restart cycles:**
- Restart the hub 50 times in a row with minimal delay. Does state stay consistent? Any zombie processes? Port conflicts?

**Power-cut simulation:**
- Inject a `SIGKILL` to the whole plugin + `sync` blocked (hard to simulate perfectly, but approximate with `kill -9` immediately after a capture). Is the WAL flushed or lost?

### Reporting

For each scenario:

- Scenario description
- Command / action used to induce failure
- Observed behavior (errors, timing, data state)
- Recovery path (automatic, manual, data-loss)
- Score 1-10

Summary table:

| Failure mode | Score 1-10 | Recovery | Data loss |
|--------------|-----------|----------|-----------|
| Hub kill | | | |
| Bridge daemon kill | | | |
| SQLite corruption | | | |
| Concurrent writes | | | |
| Disk full | | | |
| FD exhaustion | | | |
| Malformed requests | | | |
| Summarizer failure | | | |
| Embedder failure | | | |
| Mid-capture kill | | | |
| Restart cycles | | | |

**Overall resilience score = MIN of above.** Justify the overall score in one paragraph.

### Out of bounds

Do not read `/tmp/`, `CLAUDE.md`, other audit reports, plan files in `memos-setup/learnings/`, or existing test scripts. Clean up any test data / disk-fill files you created.
