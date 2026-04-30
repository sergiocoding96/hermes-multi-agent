# MemOS v1 Observability Audit

Paste this as your FIRST message into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`. No other context should be present.

---

## Prompt

The legacy MemOS server at `http://localhost:8001` has logging, a `/health` endpoint, and (possibly) more. The Hermes plugin (`memos-toolset`) emits its own log lines locally. The CEO orchestrator (Paperclip) consumes these for its monitoring loop.

**Your job: assess whether an operator can detect, diagnose, and resolve real production incidents using only the surfaces this system exposes.** Score 1-10, MIN across sub-areas. Adopt the stance of a 3 a.m. on-call engineer.

Use marker `V1-OBS-<unix-ts>` on every memory / cube / query you create.

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
  python3.12 -m memos.api.server_api > /tmp/memos-v1-obs.log 2>&1 &
  sleep 5 && curl -s http://localhost:8001/health | jq .
)

export MEMOS_HOME=/tmp/memos-v1-audit-$(uuidgen)
mkdir -p "$MEMOS_HOME/data"
TS=$(date +%s)
python3.12 /home/openclaw/Coding/Hermes/deploy/scripts/setup-memos-agents.py \
  --output "$MEMOS_HOME/agents-auth.json" \
  --agents "audit-v1-obs:V1-OBS-$TS"
```

Teardown:
```bash
rm -rf "$MEMOS_HOME"
sqlite3 ~/.memos/data/memos.db <<SQL
DELETE FROM users WHERE user_id LIKE 'audit-v1-obs%';
DELETE FROM cubes WHERE cube_id LIKE 'V1-OBS-%';
SQL
```

### Recon (first 5 minutes)

1. Find every log sink: `grep -rn "logging\.getLogger\|logger = \|FileHandler\|RotatingFileHandler" src/memos | head -30`. Where do logs go (file paths, stdout, stderr, syslog)?
2. Read `/health`, `/info`, `/metrics` (any of these existent). Schema?
3. `grep -rn "log\.info\|log\.warn\|log\.error" src/memos/api | head -40`. What's instrumented at INFO vs WARN vs ERROR?
4. Find log rotation config: `grep -rn "rotation\|backup_count\|max_bytes"`.
5. Note the structured-vs-unstructured choice (JSON lines vs plain).

### Probe matrix

**Log sinks + content.**
- Submit a successful memory write. Tail every log file. Which sink captured it? Does the line contain `request_id` / `user_id` / `cube_id` / latency_ms?
- Submit a failing write (bad payload). Same — is the failure logged at ERROR? Stack trace included?
- Submit an unauthenticated request. Auth-failure logged? With which fields?

**Health endpoint.**
- `GET /health` — what does it return? Plain `OK`, structured JSON, version + dep statuses?
- Force Qdrant offline. Does `/health` reflect this, or still return 200?
- Same for Neo4j.
- Same for the LLM provider (DeepSeek key invalid).
- Submit a bogus DB lock to make SQLite unhealthy. Does `/health` notice?

**Metrics.**
- Is there a `/metrics` endpoint? Prometheus-format? Counters / histograms / gauges?
- If absent, are the equivalent counters reachable via DB query (`SELECT COUNT(*) FROM ...`) or log scraping? Document the gap.

**Request correlation.**
- Submit a write. Find the corresponding log line. Is there a unique `request_id` that propagates from API entry through SQLite → Qdrant → Neo4j? Or is the trail broken?
- The Hermes plugin client side: does it stamp a request_id and forward it? Check the `Authorization` / `X-Request-ID` headers it sends.

**Bearer / secret redaction in logs.**
- Submit a memory whose body or headers contain a Bearer token, an `sk-…` key, an email, a phone number. Tail every sink. Anything reach disk unredacted?
- Submit a fine-mode write that contains a secret in user content. Does the LLM-extraction log path emit unredacted prompt / completion?

**Log rotation + retention.**
- Look at log file sizes. Any in danger of growing unbounded?
- Force-write 10000 log entries (e.g. submit 10000 trivial requests). Does the file rotate at the documented threshold?
- After rotation, are old files compressed / archived / deleted? Documented retention?

**Debug toggles.**
- Find any env var or config that enables verbose logging. Does it work without a restart? Is verbose mode safe (no secret leak) or dangerous (full prompt + completion in plaintext)?
- Are there feature flags for trace logs / profile mode? Probe.

**Hermes-side observability.**
- The plugin emits its own logs (likely under `~/.hermes/logs/`). What does it log on capture success? On failure? On retry?
- Does the plugin expose a tool the agent can use to query "did my memory get stored?" Or is the agent flying blind?

**Daemon + container observability.**
- `docker logs <qdrant-container>` and `<neo4j-container>` — what's emitted? Anything that helps diagnose a degraded MemOS?

**Per-scenario diagnostic capability.**
For each of the following plausible incidents, walk through the steps an operator would take using only the system's surfaces. Score whether they can reach a diagnosis in <10 minutes.

- "A memory I just stored isn't searchable" — can the operator confirm it's in SQLite + Qdrant + Neo4j?
- "Search is slow today" — can they break down latency by sub-system?
- "Auth keeps failing for one agent" — can they find the request, see the failure reason, and verify the rate limit?
- "Disk is filling up" — what's filling it? Logs? WAL? Vector cache?
- "MemOS keeps restarting" — exit code, last log line, dep status before crash?
- "An LLM extraction returned garbage" — can they see the prompt + completion + cost?
- "A duplicate slipped through dedup" — can they confirm the dedup decision was made and on what evidence?

### Reporting

For every finding:

- Class: missing-signal / silent-failure / unredacted-secret / no-correlation-id / no-rotation / no-metrics / poor-coverage.
- Reproducer: exact commands and which log sink to inspect.
- Evidence: log excerpt, file size, missing-field grep.
- Severity: Critical / High / Medium / Low / Info.
- One-sentence remediation.

Final summary table:

| Area | Score 1-10 | Key findings |
|------|-----------|--------------|
| Log sinks + content quality | | |
| Health endpoint depth | | |
| Metrics endpoint (Prometheus or equiv) | | |
| Request correlation IDs | | |
| Secret redaction across all sinks | | |
| Log rotation + retention | | |
| Debug toggles | | |
| Hermes plugin observability | | |
| Per-incident diagnostic capability | | |

**Overall observability score = MIN.** Close with a one-paragraph judgement: at 3 a.m. with one incident, can the operator find and fix the problem with what this system surfaces today?

### Out of bounds (re-asserted)

Do NOT read `/tmp/` beyond files you created this run, `CLAUDE.md`, prior audit reports, plan files, learning docs, or any commit message that telegraphs prior findings.

### Deliver

```bash
git fetch origin tests/v1.0-audit-reports-2026-04-30
git switch tests/v1.0-audit-reports-2026-04-30
git pull --rebase origin tests/v1.0-audit-reports-2026-04-30
# write tests/v1/reports/observability-v1-$(date +%Y-%m-%d).md
git add tests/v1/reports/observability-v1-*.md
git commit -m "report(tests/v1.0): observability audit"
git push origin tests/v1.0-audit-reports-2026-04-30
```

Do not open a PR. Do not modify any other file. Do not push to `main` or any other branch.
