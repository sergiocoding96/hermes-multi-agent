# MemOS v1 Resilience Audit

Paste this as your FIRST message into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`. No other context should be present.

---

## Prompt

The legacy MemOS server at `http://localhost:8001` runs against three external dependencies — Qdrant (`:6333`), Neo4j (`:7687`), and a local SQLite at `~/.memos/data/memos.db` — plus an LLM provider for fine-mode extraction (DeepSeek) and an embedder (sentence-transformers `all-MiniLM-L6-v2`, local). The Hermes plugin (`memos-toolset`) and OpenClaw plugin both call the server over HTTP.

**Your job: break it.** Force every dependency to fail in every plausible way and observe what the system does. Score recoverability and graceful degradation 1-10, MIN across sub-areas. Adopt a "chaos monkey" stance.

Use marker `V1-RES-<unix-ts>` on every memory / cube / query you create.

### Zero-knowledge constraint

Do NOT read any of:
- `/tmp/**` beyond files you created this run
- `CLAUDE.md` at any level
- `tests/v1/reports/**`, `tests/v2/reports/**`
- `tests/blind-*`, `tests/zero-knowledge-audit.md`, `tests/security-remediation-report.md`
- `memos-setup/learnings/**`
- any `TASK.md` or plan file
- any commit message that mentions "audit", "score", "fix", or "remediation"

Inputs allowed: this prompt, the live system, source under `/home/openclaw/Coding/MemOS/src/memos/**`. Discover everything else.

### Throwaway profile (provision before any probe)

```bash
curl -s http://localhost:8001/health | jq . || (
  cd /home/openclaw/Coding/MemOS
  set -a && source .env && set +a
  python3.12 -m memos.api.server_api > /tmp/memos-v1-res.log 2>&1 &
  sleep 5 && curl -s http://localhost:8001/health | jq .
)

export MEMOS_HOME=/tmp/memos-v1-audit-$(uuidgen)
mkdir -p "$MEMOS_HOME/data"
TS=$(date +%s)
python3.12 /home/openclaw/Coding/Hermes/deploy/scripts/setup-memos-agents.py \
  --output "$MEMOS_HOME/agents-auth.json" \
  --agents "audit-v1-res:V1-RES-$TS"
```

Teardown:
```bash
rm -rf "$MEMOS_HOME"
sqlite3 ~/.memos/data/memos.db <<SQL
DELETE FROM users WHERE user_id LIKE 'audit-v1-res%';
DELETE FROM cubes WHERE cube_id LIKE 'V1-RES-%';
SQL
```

### Recon (first 5 minutes)

1. `docker ps` — what containers run for Qdrant + Neo4j? How are they restarted on crash (compose policy)?
2. Read `src/memos/vec_dbs/qdrant.py` and `src/memos/graph_dbs/neo4j.py`. What's the retry / timeout / circuit-breaker behaviour?
3. Read `src/memos/api/server_api.py` for global error-handling. Are `502 Bad Gateway` / `503 Service Unavailable` returned when deps fail, or does the server 500?
4. `grep -rn "try:\|except" src/memos/multi_mem_cube/ | head -40` — where are silent excepts? Catch-all `except Exception:` paths?
5. Find the embedder load path. What happens if the model file is missing / corrupt?

### Probe matrix

**LLM provider outage (fine-mode extraction).**
- Set `DEEPSEEK_API_KEY` to garbage, restart server. Submit a memory in fine mode. What happens? 5xx? 200 with empty extraction? Memory dropped?
- Block outbound to `api.deepseek.com` (`iptables -A OUTPUT -d <ip> -j DROP` or equivalent). Submit fine-mode write. Does it time out? Fall back to fast/raw mode? Queue?
- Restore. Does the queue drain?

**Embedder failure.**
- `chmod 000` the local sentence-transformers cache (`~/.cache/sentence-transformers/`). Restart. Does the server start? What's the failure mode on first write that needs an embedding?
- Run two writes concurrently while the embedder is failing. Race conditions?

**Qdrant outage.**
- `docker stop <qdrant-container>`. Submit a write. Submit a search. Document responses (status, body, log).
- Restart Qdrant. Does the server reconnect automatically, or require its own restart?
- Mid-write Qdrant crash: kill Qdrant exactly when a write is committing. Is the SQLite row written without the corresponding vector? Are these reconciled on reconnect?

**Neo4j outage.**
- `docker stop <neo4j-container>`. Submit a write. Submit a search. Same as Qdrant — document the response and recovery.
- Tree-memory operations specifically: do they fail loud, or silently skip the graph layer?

**SQLite corruption.**
- Take a controlled corruption (e.g. truncate `~/.memos/data/memos.db` to 1 KB while server is stopped). Start server. Does it detect, refuse, or panic?
- Lock the DB (`sqlite3 ~/.memos/data/memos.db ".timeout 60000"` in another shell holding a write lock). Submit a write. Does the server retry with backoff? Honor `busy_timeout`?
- WAL recovery: on a clean shutdown, no WAL artifacts should remain. Force-kill (`kill -9`) during write. Restart. Are uncommitted entries recovered (good) or lost (acceptable but should log)?

**Concurrent writes / SQLITE_BUSY handling.**
- 100 parallel writes from one client. P50/P95 latency? Any caller-visible `SQLITE_BUSY`? Any silent drops?
- 100 parallel writes from 5 different agents (different cubes). Same questions.

**Configuration malformed / perms.**
- Make the MemOS `.env` malformed (non-UTF8 byte). Restart. Loud error or crash loop?
- `chmod 644` `agents-auth.json` (BCrypt hashes). Does the server refuse to start? Warn? Silently accept?

**Process crash / auto-restart.**
- `kill -9` the MemOS process while a write is in flight. Restart manually. Is the in-flight memory present? Partially written?
- If a process supervisor (systemd, supervisord) is configured, observe whether it auto-restarts. If not, document.

**Soft-delete teardown collisions.**
- Create memory M, soft-delete it, create another with identical content. Then run a teardown SQL that hard-deletes by `is_active=False`. Does dedup state stay consistent?

**Hub / cross-agent sync (Sprint 4 hub-sync.py path).**
- If a `hub-sync.py` or equivalent is configured: kill the receiver, then write on the sender. Does the sender block, drop, queue?

**Plugin retry behaviour.**
- Block port 8001 for 2s while the Hermes plugin tries an auto-capture. Does the plugin retry? Drop? Queue locally?
- Block port 8001 for 60s. Does the plugin enter a degraded state (visible to the agent), or fail silently?

**Resource exhaustion.**
- Disk fill: `dd if=/dev/zero of=~/.memos/filler bs=1M count=<until 95% full>` then submit writes. Does the server detect ENOSPC and fail loud? WAL behaviour?
- File-descriptor exhaustion: open 10000 sockets to `:8001`. Does the server stay up? Recover when sockets close?

### Reporting

For every finding:

- Class: data-loss / silent-failure / no-recovery / wedge / cascading-failure / leak.
- Reproducer: exact commands.
- Evidence: log excerpt before + after fault, DB state diff, HTTP status sequence, container exit code.
- Severity: Critical / High / Medium / Low / Info.
- One-sentence remediation.

Final summary table:

| Area | Score 1-10 | Key findings |
|------|-----------|--------------|
| LLM (DeepSeek) outage handling | | |
| Embedder failure handling | | |
| Qdrant outage + reconnect | | |
| Neo4j outage + reconnect | | |
| SQLite corruption detection | | |
| SQLite WAL recovery | | |
| Concurrent-write handling (SQLITE_BUSY) | | |
| Config malformed / perms enforcement | | |
| Process crash + restart consistency | | |
| Soft-delete teardown collisions | | |
| Hub / cross-agent sync resilience | | |
| Hermes plugin retry / queue | | |
| Disk-full / FD-exhaustion behaviour | | |

**Overall resilience score = MIN.** Close with a one-paragraph judgement on whether the system can survive a typical production day with one or two transient dep outages.

### Out of bounds (re-asserted)

Do NOT read `/tmp/` beyond files you created this run, `CLAUDE.md`, prior audit reports, plan files, learning docs, or any commit message that telegraphs prior findings.

### Deliver

```bash
git fetch origin tests/v1.0-audit-reports-2026-04-26
git switch tests/v1.0-audit-reports-2026-04-26
git pull --rebase origin tests/v1.0-audit-reports-2026-04-26
# write tests/v1/reports/resilience-v1-$(date +%Y-%m-%d).md
git add tests/v1/reports/resilience-v1-*.md
git commit -m "report(tests/v1.0): resilience audit"
git push origin tests/v1.0-audit-reports-2026-04-26
```

Do not open a PR. Do not modify any other file. Do not push to `main` or any other branch.
