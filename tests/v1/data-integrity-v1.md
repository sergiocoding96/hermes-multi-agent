# MemOS v1 Data Integrity Audit

Paste this as your FIRST message into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`. No other context should be present.

---

## Prompt

The legacy MemOS server stores every memory across **three** stores that must agree:

1. **SQLite** at `~/.memos/data/memos.db` — users, cubes, ACL, and a row per memory.
2. **Qdrant** at `127.0.0.1:6333` — vector embeddings (one per memory or per chunk).
3. **Neo4j** at `bolt://127.0.0.1:7687` — tree-memory graph relationships.

Plus the Hermes plugin (`memos-toolset`) writes through the API and assumes round-tripping is lossless (URLs, JSON, code blocks, emoji, mixed-language content).

**Your job: prove the three stores agree under all conditions, and prove content fidelity end-to-end.** Score correctness 1-10, MIN across sub-areas. Adopt the stance: any inconsistency between stores or any byte change in round-trip is a bug.

Use marker `V1-DI-<unix-ts>` on every memory / cube / query you create.

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
  python3.12 -m memos.api.server_api > /tmp/memos-v1-di.log 2>&1 &
  sleep 5 && curl -s http://localhost:8001/health | jq .
)

export MEMOS_HOME=/tmp/memos-v1-audit-$(uuidgen)
mkdir -p "$MEMOS_HOME/data"
TS=$(date +%s)
python3.12 /home/openclaw/Coding/Hermes/deploy/scripts/setup-memos-agents.py \
  --output "$MEMOS_HOME/agents-auth.json" \
  --agents "audit-v1-di:V1-DI-$TS"
```

Teardown:
```bash
rm -rf "$MEMOS_HOME"
sqlite3 ~/.memos/data/memos.db <<SQL
DELETE FROM users WHERE user_id LIKE 'audit-v1-di%';
DELETE FROM cubes WHERE cube_id LIKE 'V1-DI-%';
SQL
# also clean up Qdrant collection rows tagged V1-DI- and Neo4j nodes
```

### Recon (first 5 minutes)

1. Read `src/memos/multi_mem_cube/single_cube.py` — find the write path. Are SQLite + Qdrant + Neo4j inserted in a transaction, or sequentially? What happens on partial failure?
2. Read `src/memos/vec_dbs/qdrant.py` and `src/memos/graph_dbs/neo4j.py`. Are operations idempotent on retry?
3. `sqlite3 ~/.memos/data/memos.db ".schema"` — list every table. Note FK constraints, CHECK constraints, indexes.
4. Inspect Qdrant collections (`curl -s http://localhost:6333/collections`). Any leftover collections from prior runs?
5. Inspect Neo4j schema (`MATCH (n) RETURN labels(n), count(*)`). Note labels + relationship types.

### Probe matrix

**Tri-store consistency on write.**
- Submit a memory, then within 1 ms read: (a) the SQLite row, (b) the Qdrant point, (c) the Neo4j node. All three exist? IDs cross-link cleanly?
- Submit 100 memories rapidly. Spot-check 10 random ones for tri-store presence. Any orphans (in one store, not another)?

**Partial-write recovery.**
- Force Qdrant offline (`docker stop qdrant`) mid-write. What's in SQLite and Neo4j? Bring Qdrant back. Does the system reconcile, or are these rows now permanently orphaned?
- Same for Neo4j outage during write.
- `kill -9` server during a multi-store write. Restart. What's the state? Recovered? Partial? Documented?

**Soft-delete idempotency.**
- Create memory M. Soft-delete. Verify: SQLite `is_active=False`; Qdrant point still present (or removed?); Neo4j node still present (or removed?). Is the soft-delete consistent across stores?
- Re-create M with identical content. Dedup catches it? Or does the soft-deleted vector cause a false-positive dedup?
- Hard-delete (admin path or DB cleanup): runs across all three stores?

**Content fidelity (raw text + structured fields).**
- Submit memories with: ASCII / Unicode emoji / CJK / RTL Hebrew/Arabic / mixed scripts. Round-trip via API and verify byte-for-byte equality.
- Submit a JSON blob, a Python code block, a multi-line URL, a string with embedded `\x00`, `\\n`, control chars. Round-trip integrity?
- Submit a memory whose `custom_tags` contain JSON-fragile chars (`"`, `\`, newlines). Round-trip?
- Submit a 50000-char memory. Is it chunked? On retrieval, do chunks reassemble correctly?

**Timestamp resolution + ordering.**
- Submit 100 memories in rapid succession. Are timestamps monotonic? Any collisions (same ms / same s)?
- Are timestamps stored as ISO-8601, epoch-ms, epoch-s, naive, or tz-aware? Convert across.
- Submit a memory dated in the future (LLM extraction creates a `2030-01-01` entry). Stored? Searchable? Conflicts with monotonicity assumptions?

**Embedding dimension + model lock-in.**
- What dim does the local embedder produce (`all-MiniLM-L6-v2` → 384)? `curl -s http://localhost:6333/collections/<col>/info` to confirm.
- Swap to a different embedding model in config and restart. What happens to existing rows? Re-embedded? Skipped? Errored?

**Search-time consistency.**
- Search for content that exists in SQLite but is missing in Qdrant (manually delete the Qdrant point). Does search hit it via FTS fallback or skip? Documented behaviour?
- Search for content via FTS query operator (`*`, `OR`, `AND`). Round-tripped correctly?

**ACL idempotency.**
- `UserManager.add_user_to_cube` — call twice with the same args. Idempotent (no duplicate rows)? Logged?
- Revoke + re-grant rapidly. Final state correct? Audit trail intact?

**Migration paths (if any).**
- Are there any DB migration scripts in `src/memos`? If so, run them on a non-empty DB. Do they preserve data?
- The Sprint 4 hub-sync.py (cross-agent sharing): if engaged, does it preserve dedup / tags / timestamps across the hop?

**Concurrent writes + dedup ordering.**
- Two writers submit identical content concurrently. Which one wins? Both stored? Audit trail?

**Backup + restore (no scripted path likely; document as an audit finding either way).**
- Stop the server. Copy `~/.memos/`. Snapshot Qdrant + Neo4j. Wipe everything. Restore. Does the system come back consistent? If there's no documented backup procedure, that's a finding.

### Reporting

For every finding:

- Class: tri-store-divergence / orphan / fidelity-loss / timestamp-anomaly / dedup-error / migration-error / no-backup-path.
- Reproducer: exact commands.
- Evidence: SQLite row + Qdrant point JSON + Neo4j node — all three side-by-side. Byte-diff for fidelity issues.
- Severity: Critical / High / Medium / Low / Info.
- One-sentence remediation.

Final summary table:

| Area | Score 1-10 | Key findings |
|------|-----------|--------------|
| Tri-store write consistency | | |
| Partial-write recovery | | |
| Soft-delete idempotency across stores | | |
| Content fidelity (text / JSON / code) | | |
| Unicode / emoji / CJK fidelity | | |
| Timestamp resolution + ordering | | |
| Embedding dimension lock-in | | |
| Search-time tri-store consistency | | |
| ACL idempotency | | |
| Migration safety | | |
| Concurrent dedup ordering | | |
| Backup / restore documented path | | |

**Overall data-integrity score = MIN.** Close with a one-paragraph judgement: would you trust this system to hold the only copy of important memories?

### Out of bounds (re-asserted)

Do NOT read `/tmp/` beyond files you created this run, `CLAUDE.md`, prior audit reports, plan files, learning docs, or any commit message that telegraphs prior findings.

### Deliver

```bash
git fetch origin tests/v1.0-audit-reports-2026-04-30
git switch tests/v1.0-audit-reports-2026-04-30
git pull --rebase origin tests/v1.0-audit-reports-2026-04-30
# write tests/v1/reports/data-integrity-v1-$(date +%Y-%m-%d).md
git add tests/v1/reports/data-integrity-v1-*.md
git commit -m "report(tests/v1.0): data-integrity audit"
git push origin tests/v1.0-audit-reports-2026-04-30
```

Do not open a PR. Do not modify any other file. Do not push to `main` or any other branch.
