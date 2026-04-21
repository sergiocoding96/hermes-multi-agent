# Hermes v2 Blind Audit Suite

10 blind audits for Product 2 — the `@memtensor/memos-local-hermes-plugin` running as both a local capture agent and an HTTP hub for shared memory + skills. Each audit runs in a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`. No session should have context from any other.

## Tests

| # | File | Category | Time |
|---|------|----------|------|
| 1 | `zero-knowledge-v2.md` | Security — auth surface, isolation, secret handling, injection | 20-30 min |
| 2 | `functionality-v2.md` | Core — capture, hybrid search, dedup, MMR, recency decay | 25-35 min |
| 3 | `resilience-v2.md` | Failure modes — hub down, DB corrupt, concurrent stress, crash | 20-30 min |
| 4 | `performance-v2.md` | Latency, throughput, scaling, memory footprint | 20-30 min |
| 5 | `data-integrity-v2.md` | Local↔hub consistency, fidelity, embedding drift, timestamps | 15-25 min |
| 6 | `observability-v2.md` | Logs, dashboard, metrics, health, audit trail | 10-20 min |
| 7 | `auto-capture-v2.md` | Pipeline correctness — message types, chunking, PII, abort recovery | 15-25 min |
| 8 | `skill-evolution-v2.md` | Generated skill quality, generalization, dedup, versioning | 25-35 min |
| 9 | `task-summarization-v2.md` | Boundary detection, summary fidelity, idle timeout | 15-25 min |
| 10 | `hub-sharing-v2.md` | Visibility levels, ACL, pairing, cross-agent recall, offline sync | 20-30 min |

## How to run

1. Open a **fresh** Claude Code Desktop session (no prior context, no CLAUDE.md injection).
2. Set working directory to `/home/openclaw/Coding/Hermes`.
3. Copy the entire content of one `.md` file as your **first** message.
4. Let it run to completion without steering.
5. Save the final report as `tests/v2/reports/<audit-name>-YYYY-MM-DD.md`.
6. Commit the report.
7. **Close the session completely** before starting the next one.

## Rules

- **One audit per session.** Never combine. Blind integrity depends on isolation.
- **Order-independent.** Run 1→10 or any order; they're mutually independent.
- **No context leakage.** Auditors must not read `/tmp/`, `CLAUDE.md`, previous audit reports, plan files, or existing test scripts.
- **Unique markers.** Each auditor creates its own test data (e.g., `SEC-AUDIT-<timestamp>`) to avoid collisions.
- **Restart on crash.** If an audit crashes the hub or plugin, restart before the next test.

## System under test (common to all audits)

- **Plugin source (per profile):** `~/.hermes/memos-plugin-<profile>/`
- **Plugin state (per profile):** `~/.hermes/memos-state-<profile>/`
  - `memos-local/memos.db` — local SQLite (WAL mode: `memos.db`, `memos.db-shm`, `memos.db-wal`)
  - `hub-auth.json` — hub auth secret + bootstrap admin token
  - `secrets/` — additional encrypted material
  - `skills-store/` — symlinked to `~/Coding/badass-skills/auto/`
  - `logs/` — plugin + hub logs
  - `hub.pid`, `bridge-daemon.pid` — running process PIDs
- **Hub HTTP server:** `http://localhost:18992` (default)
- **Bridge daemon:** `http://localhost:18990` (default)
- **Viewer dashboard:** `http://localhost:18901` (default)
- **Profiles on this machine:** `arinze`, `email-marketing`, `mohammed`, `research-agent`
- **Node version constraint:** `>=18 <25` (install-plugin.sh enforces)
- **Embedder:** Xenova all-MiniLM-L6-v2 (384d, local, no API)
- **Summarizer:** DeepSeek V3 via `openai_compatible` (config-dependent)

## Scoring

- **1-2:** Broken, unusable in production.
- **3-4:** Major defect or security gap. Needs rework before ship.
- **5-6:** Works for the happy path; concerning limitations on edge cases.
- **7-8:** Production-viable with documented caveats.
- **9-10:** Excellent; no remediation required for this area.

Evidence must accompany every score — HTTP status codes, response bodies, file paths, timing numbers, corrupted fields, etc.

## Combining reports

Overall production-readiness = **minimum** score across all 10 audits, not average.

A system that scores 10/10 on nine audits and 2/10 on security is a **2/10** system. The min-aggregation is deliberate: production is brittle to any single weak link, and averaging hides the failure mode.

## Final recommendation template

After all 10 complete:

1. Critical findings (score < 5) — blockers.
2. Medium findings (5-7) — design considerations.
3. Strong areas (8-10) — confidence builders.
4. Ship / Ship-with-caveats / Do-not-ship recommendation with justification.
