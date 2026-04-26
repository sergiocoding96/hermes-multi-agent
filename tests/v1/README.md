# MemOS v1 Blind Audit Suite

8 blind, adversarial, evidence-based audits for the **v1 stack** — the legacy MemOS server (`/home/openclaw/Coding/MemOS`) + Hermes plugin (`memos-toolset`) + OpenClaw plugin (`memos-local-openclaw`) — as it stood before the Sprint 2 migration to `@memtensor/memos-local-plugin` v2.

This suite exists to redo the v1 audit with the same rigor the v2 suite (`tests/v2/`) used. The original v1 audit (`tests/blind-audit-report.md`, score 9.1/10) was context-contaminated: the auditor could read `CLAUDE.md`, prior reports, learning docs, and reused throwaway profiles. This suite forbids all of that.

The audits are deliberately the same shape as the v2 ones, so the resulting scores compare apples-to-apples.

## Tests

| # | File | Category | Scope | Time |
|---|------|----------|-------|------|
| 1 | `zero-knowledge-v1.md` | Security | BCrypt auth + cache, cube ACL, loopback, Qdrant/Neo4j bind, secret redaction, file perms | 25-35 min |
| 2 | `functionality-v1.md` | Core | Write paths (fast/fine/async), MemReader extraction, write-dedup, search modes (no/sim/mmr), custom_tags, cross-cube isolation, **auto-capture (folded in from v2 #7)** | 30-40 min |
| 3 | `resilience-v1.md` | Failure modes | LLM/embedder outages, Qdrant/Neo4j outages, SQLite corruption, malformed config, process crash, concurrent writes, soft-delete races | 25-35 min |
| 4 | `performance-v1.md` | Latency / scaling | BCrypt cold/warm, search latency (fast vs fine), chunking cost, throughput under load | 20-30 min |
| 5 | `data-integrity-v1.md` | Correctness | Multi-store consistency (API ↔ Qdrant ↔ Neo4j ↔ SQLite ACL), dedup idempotency, fidelity (URLs/emoji/CJK/code), orphans | 20-30 min |
| 6 | `observability-v1.md` | Logs / introspection | Log sinks, Bearer redaction, health endpoint, file perms, debug toggles | 15-25 min |
| 7 | `plugin-integration-v1.md` | Hermes ↔ MemOS | `memos-toolset` plugin, profile `.env` injection, multi-agent routing, identity-from-env (not LLM), per-agent cube isolation | 15-25 min |
| 8 | `provisioning-v1.md` | Setup workflow | `setup-memos-agents.py`, key rotation, BCrypt-on-disk, UserManager.add_user_to_cube, CEO multi-cube cross-read | 15-20 min |

The 4 v2 audits with no v1 analog (skill-evolution, task-summarization, hub-sharing, plus auto-capture-as-its-own-test) are dropped or folded; auto-capture is folded into functionality-v1.

## How to run

1. Open a **fresh** Claude Code session (no prior context, no CLAUDE.md injection).
2. Working directory: `/home/openclaw/Coding/Hermes`.
3. Either copy the entire content of one `.md` file as your **first** message, OR use the matching block from `RUNBOOK.md` (which switches to the suite branch then reads the prompt). Each prompt's `### Deliver` section tells the session exactly how to push its report to the shared branch.
4. Let it run to completion without steering.
5. **Close the session completely** before starting the next audit.

All 8 sessions can run in parallel — each pushes to the same branch and rebases on conflict. Reports converge on `tests/v1.0-audit-reports-2026-04-26`.

## Rules — these matter for blind integrity

- **One audit per session.** Blind integrity depends on isolation.
- **Order-independent.** Run 1→8 or any order; audits are mutually independent.
- **Throwaway profile per run.** Every audit must `export MEMOS_HOME=/tmp/memos-v1-audit-$(uuidgen)` before touching the system, and `rm -rf "$MEMOS_HOME"` at teardown. Reusing a profile is the #1 way contamination crept into the previous v1 audit.
- **Unique markers.** Each auditor creates its own test data (`V1-ZK-<unix-ts>`, `V1-FN-<unix-ts>`, etc.) so concurrent runs never collide.
- **Restart on crash.** If an audit corrupts the daemon / DB, restart from a clean install before the next audit.
- **No production data.** Audits run against the throwaway profile only.

## ZERO-KNOWLEDGE CONSTRAINT (cited in every audit prompt)

Auditors **must not** read any of:

- `/tmp/**` beyond files they created this run
- `CLAUDE.md` at any level (project, user, agent)
- `tests/v1/reports/**` and `tests/v2/reports/**`
- `tests/blind-*`, `tests/zero-knowledge-audit.md`, `tests/security-remediation-report.md`
- `memos-setup/learnings/**`
- any `TASK.md` or plan file
- any commit message that mentions "audit", "score", "fix", or "remediation"
- prior `perf-audit-*.mjs` or similar scripts in the repo

Inputs allowed: this prompt, the live system at `http://localhost:8001`, source under `/home/openclaw/Coding/MemOS/src/memos/**`, the Hermes plugin under `~/.hermes/plugins/memos-toolset/**`, and standard man pages / docs. Discover everything else.

## Throwaway-profile precondition

Every audit prompt cites this bootstrap. Reproduced here for reference:

```bash
# Start MemOS (one-time per audit machine)
cd /home/openclaw/Coding/MemOS
set -a && source .env && set +a
python3.12 -m memos.api.server_api > /tmp/memos-v1-audit.log 2>&1 &
sleep 5 && curl -s http://localhost:8001/health | jq .

# Per-audit: provision a throwaway profile
export MEMOS_HOME=/tmp/memos-v1-audit-$(uuidgen)
mkdir -p "$MEMOS_HOME/data"
cd /home/openclaw/Coding/Hermes  # work from here
python3.12 deploy/scripts/setup-memos-agents.py \
  --output "$MEMOS_HOME/agents-auth.json" \
  --agents "audit-v1-<category>:V1-<TAG>-$(date +%s)"

# Teardown after audit (ALWAYS — even on failure)
rm -rf "$MEMOS_HOME"
sqlite3 ~/.memos/data/memos.db <<'SQL'
DELETE FROM users WHERE user_id LIKE 'audit-v1%';
DELETE FROM cubes WHERE cube_id LIKE 'V1-%';
SQL
```

## System under test — key source locations

Auditors may read any of these. They are part of the system under test.

- `src/memos/api/server_api.py` — HTTP API surface, route registration
- `src/memos/api/middleware/agent_auth.py` — BCrypt auth + cache + rate limit
- `src/memos/multi_mem_cube/single_cube.py` — write-dedup, cube ACL, single-cube view
- `src/memos/multi_mem_cube/composite_cube_view.py` — CEO cross-cube reads
- `src/memos/templates/mem_reader_prompts.py` — extraction prompts (DeepSeek V3)
- `src/memos/vec_dbs/qdrant.py` — vector store wrapper
- `src/memos/graph_dbs/neo4j.py` — graph store wrapper
- `src/memos/users/user_manager.py` — UserManager + cube sharing API
- `~/.hermes/plugins/memos-toolset/` — Hermes-side plugin (`memos_store`, `memos_search`)
- `~/.hermes/profiles/<agent>/.env` — per-agent identity (`MEMOS_API_KEY`, `MEMOS_USER_ID`, `MEMOS_CUBE_ID`)
- `deploy/scripts/setup-memos-agents.py` — provisioning + key rotation

## Default ports (loopback / `127.0.0.1`)

| Surface | Default port |
|---|---|
| MemOS HTTP API + health | `8001` |
| Qdrant vector DB | `6333` |
| Neo4j Bolt | `7687` |
| SearXNG (web stack, optional) | `8888` |
| Firecrawl (web stack, optional) | `3002` |

## Scoring

- **1-2** Broken, unusable in production.
- **3-4** Major defect or security gap. Needs rework before ship.
- **5-6** Happy path works; edge cases concerning.
- **7-8** Production-viable with documented caveats.
- **9-10** Excellent; no remediation required for this area.

Every finding MUST carry evidence — HTTP status + body, SQLite row, file perms, timing in ms, log line, stack trace. Scores without evidence are invalid.

## Combining reports

**Overall production-readiness = MIN across all 8 audits.** A 10/10 on seven audits and a 2/10 on one is a 2/10 system. Min-aggregation is deliberate: production is brittle to any single weak link, and averaging hides the failure mode.

This is the same rule the v2 suite used (`tests/v2/README.md` line 115), so the v1↔v2 comparison is direct.

## Final recommendation template

After all 8 complete:

1. **Critical** (score < 5) — ship blockers.
2. **Medium** (5-7) — design considerations / documented caveats.
3. **Strong** (8-10) — confidence builders.
4. **Decision tied to MIN score** vs. the v2 suite's MIN of 1/10:
   - v1 MIN ≥ 7/10 → revert to v1 cleanly; v2 stays as dormant spike.
   - v1 MIN 5–6 → patch v1 weak spots (likely cheaper than v2's 30+ issues), then revert.
   - v1 MIN < 5 → both stacks weak; reassess from scratch.
