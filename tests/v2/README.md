# memos-local-plugin v2.0 Blind Audit Suite

10 blind, adversarial, evidence-based audits for `@memtensor/memos-local-plugin` **v2.0.0-beta.1** — the rewritten Reflect2Evolve memory core that replaced the legacy `memos-local-hermes` server + `memos-local-openclaw` plugin. Each audit runs in a fresh Claude Code session at `/home/openclaw/Coding/Hermes`. No session should carry context from any other.

## Tests

| # | File | Category | Scope | Time |
|---|------|----------|-------|------|
| 1 | `zero-knowledge-v2.md` | Security | Loopback model, API-key gate, password gate + `.auth.json`, redaction, XSS, RPC auth, process isolation | 25-35 min |
| 2 | `functionality-v2.md` | Core | Turn pipeline, L1/L2/L3/Skill crystallization, three-tier retrieval w/ MMR + RRF, DTO contract | 30-40 min |
| 3 | `resilience-v2.md` | Failure modes | LLM/embedder outages, DB corruption, partial migration, concurrent writes, process crash | 25-35 min |
| 4 | `performance-v2.md` | Latency / scaling | Turn-start retrieval latency, embedding cache, batched α-scoring, vector scan cost, log rotation | 20-30 min |
| 5 | `data-integrity-v2.md` | Correctness | Migration order, FK cascade, WAL fsync, embedding dim mismatch, clock skew, `schema_version` | 20-30 min |
| 6 | `observability-v2.md` | Logs / viewer | Channel taxonomy, 6 log sinks, SSE `/api/v1/events`, redaction before sink, viewer views | 15-25 min |
| 7 | `auto-capture-v2.md` | Pipeline | step-extractor, reflection resolution, α-scorer, embedder, synthetic fallback, batch mode | 20-30 min |
| 8 | `skill-evolution-v2.md` | Reflect2Evolve | L1→L2 induction, L3 abstraction, skill eligibility/verifier/packager, η lifecycle (Beta posterior) | 25-35 min |
| 9 | `task-summarization-v2.md` | Reward | Episode finalization, R_human rubric, reflection-weighted backprop, priority decay | 20-30 min |
| 10 | `hub-sharing-v2.md` | Multi-agent peer | Peer registry (`/api/v1/hub/peers`), port fallback, `core/hub/` team-sharing stub, auth flow | 20-30 min |

## How to run

1. Open a **fresh** Claude Code session (no prior context, no CLAUDE.md injection).
2. Working directory: `/home/openclaw/Coding/Hermes`.
3. Copy the entire content of one `.md` file as your **first** message. The prompt ends with a `### Deliver` section that tells the session exactly how to push the report to the shared branch.
4. Let it run to completion without steering. The session will:
   - Check out shared branch `tests/v2.0-audit-reports-2026-04-22` (exists on origin; cut from this suite).
   - Save the report to `tests/v2/reports/<audit-name>-YYYY-MM-DD.md`.
   - Commit + push to that branch.
5. **Close the session completely** before starting the next audit.

All 10 sessions can run in parallel — each pushes to the same branch and rebases on conflict. Reports converge on [https://github.com/sergiocoding96/hermes-multi-agent/tree/tests/v2.0-audit-reports-2026-04-22](https://github.com/sergiocoding96/hermes-multi-agent/tree/tests/v2.0-audit-reports-2026-04-22).

## Rules

- **One audit per session.** Blind integrity depends on isolation.
- **Order-independent.** Run 1→10 or any order; audits are mutually independent.
- **No context leakage.** Auditors MUST NOT read `/tmp/`, `CLAUDE.md`, `tests/v2/reports/`, `memos-setup/learnings/`, previous audit reports, or any plan / TASK.md file.
- **Unique markers.** Each auditor creates its own test data (e.g. `SEC-AUDIT-<timestamp>`, `FN-AUDIT-<timestamp>`) so concurrent runs never collide.
- **Restart on crash.** If an audit corrupts the daemon / DB, restart from a clean install before the next audit.
- **No production data.** Audits run against a **throwaway profile** (see precondition below).

## Precondition: install on a throwaway profile

Before any audit, a fresh install must exist:

```bash
# Option A: npm install from registry (when the package is published)
npm install -g @memtensor/memos-local-plugin
memos-local-plugin install hermes      # or: openclaw

# Option B: local tarball (offline / development)
cd /home/openclaw/Coding/MemOS/apps/memos-local-plugin
npm pack
bash ./install.sh --version ./memtensor-memos-local-plugin-*.tgz
```

After install the runtime layout is:

```
~/.hermes/plugins/memos-local-plugin/       # plugin SOURCE (node_modules + core + adapters)
~/.hermes/memos-plugin/                     # runtime state (this is what audits probe)
├── config.yaml                             # chmod 600 — the ONLY config (no .env layer)
├── data/memos.db                           # SQLite (WAL mode)
├── skills/                                 # crystallized skill packages
├── logs/
│   ├── memos.log                           # human-readable; rotate + gzip
│   ├── error.log                           # WARN/ERROR/FATAL across channels
│   ├── audit.log                           # never deleted (monthly gzip)
│   ├── llm.jsonl                           # every LLM call
│   ├── perf.jsonl                          # every `log.timer()` close
│   ├── events.jsonl                        # every CoreEvent
│   └── self-check.log
└── daemon/                                 # bridge pid/port files
```

OpenClaw has the same layout under `~/.openclaw/plugins/memos-local-plugin/` + `~/.openclaw/memos-plugin/`.

Ports (all loopback / `127.0.0.1` by default):

| Surface | Default port | Config key |
|---|---|---|
| HTTP server + viewer + SSE | `18799` | `viewer.port` |
| Bridge daemon (TCP mode) | `18911` | `bridge.port` (when `bridge.mode: "tcp"`) |
| Hub server (team-sharing role) | `18912` | `hub.port` (only when `hub.enabled: true` and `hub.role: "hub"`) |

Note: the viewer port auto-fallback walks `+1..+10` when the configured port is busy (see `docs/MULTI_AGENT_VIEWER.md` — multiple agents can run on the same box). The actually-bound port is reported by `GET /api/v1/health`.

## System under test — key source locations

Plugin source of truth (all relative to the **installed** plugin root at `~/.<agent>/plugins/memos-local-plugin/`):

- `agent-contract/` — stable DTO + JSON-RPC method list (`jsonrpc.ts`) + error codes (`errors.ts`) + event catalogue (`events.ts`) + `MemoryCore` facade (`memory-core.ts`). **This is the audit boundary.**
- `core/` — agent-agnostic algorithm (capture, memory/l1, memory/l2, memory/l3, skill, retrieval, reward, feedback, session, episode, pipeline, hub, storage, embedding, llm, logger, config, telemetry). Every subdirectory has a `README.md`.
- `core/storage/migrations/001-*.sql` … `012-status-unification.sql` — additive-only schema migrations, applied idempotently by `core/storage/migrator.ts`.
- `server/` — Node stdlib HTTP server. Routes under `server/routes/`; middleware `auth.ts`, `io.ts`, `static.ts`.
- `bridge.cts` + `bridge/methods.ts` + `bridge/stdio.ts` — line-delimited JSON-RPC (used by the Hermes Python adapter).
- `adapters/openclaw/` (TypeScript, in-process) and `adapters/hermes/memos_provider/` (Python, over stdio JSON-RPC).
- `web/` — Vite SPA (views: Overview / Memories / Policies / WorldModels / Tasks / Skills / Analytics / Logs / Admin / Settings / Help / Import).
- `docs/` — developer-facing docs. **Actually present:** `DATA-MODEL.md`, `LOGGING.md`, `CONFIG-ADVANCED.md`, `MULTI_AGENT_VIEWER.md`, `ALGORITHM_ALIGNMENT.md`, `E2E_TEST_SCENARIO.md`, `MANUAL_E2E_TESTING.md`. (Some prose elsewhere in the repo references `ALGORITHM.md`, `EVENTS.md`, `BRIDGE-PROTOCOL.md`, `PROMPTS.md`, `ADAPTER-AUTHORING.md`, `RELEASE-PROCESS.md`, `FRONTEND-VALIDATION.md` — these do NOT currently exist on `upstream/main` at the time this suite was cut; auditors should flag any broken links they rely on.)

Audits may read any of the above. They are part of the system under test.

## Scoring

- **1-2** Broken, unusable in production.
- **3-4** Major defect or security gap. Needs rework before ship.
- **5-6** Happy path works; edge cases concerning.
- **7-8** Production-viable with documented caveats.
- **9-10** Excellent; no remediation required for this area.

Every finding MUST carry evidence — HTTP status + body, SQLite row, file perms, timing in ms, log line, stack trace. Scores without evidence are invalid.

## Combining reports

Overall production-readiness = **MIN** across all 10 audits. A 10/10 on nine audits and a 2/10 on one is a 2/10 system. Min-aggregation is deliberate: production is brittle to any single weak link, and averaging hides the failure mode.

## Final recommendation template

After all 10 complete:

1. **Critical** (score < 5) — ship blockers.
2. **Medium** (5-7) — design considerations / documented caveats.
3. **Strong** (8-10) — confidence builders.
4. **Ship / Ship-with-caveats / Do-not-ship** recommendation with justification tied to the min-score.
