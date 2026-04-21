# Hermes v2 Blind Audit Suite

10 blind audits for Product 2 (`@memtensor/memos-local-hermes-plugin` + hub), each run in a fresh Claude Code session at `/home/openclaw/Coding/Hermes`. No session should have context from any other.

## Tests

| # | File | What it tests | Duration |
|---|------|---------------|----------|
| 1 | `zero-knowledge-v2.md` | Security — auth, isolation, secrets protection, injection vectors | 20-30 min |
| 2 | `functionality-v2.md` | Core features — capture, search, dedup, skill evolution, summarization | 25-35 min |
| 3 | `resilience-v2.md` | Failure recovery — hub down, corrupt DB, concurrent stress, plugin crash | 15-25 min |
| 4 | `performance-v2.md` | Latency, throughput, scaling, memory footprint, search performance | 20-30 min |
| 5 | `data-integrity-v2.md` | Local vs hub consistency, fidelity, embeddings, soft-delete, timestamps | 15-25 min |
| 6 | `observability-v2.md` | Logging, error messages, dashboard UX, metrics, audit trail | 10-15 min |
| 7 | `auto-capture-v2.md` | Capture pipeline correctness — every message type, chunking, PII, abort recovery | 15-20 min |
| 8 | `skill-evolution-v2.md` | Generated skill quality, coherence, dedup, versioning, file structure | 20-25 min |
| 9 | `task-summarization-v2.md` | Task boundary detection, summary quality, detail preservation, idle timeout | 15-20 min |
| 10 | `hub-sharing-v2.md` | Group visibility, cross-agent recall, pairing flow, allowlist, offline sync | 20-30 min |

## How to run

1. Open a fresh Claude Code Desktop session (no prior context)
2. Set working directory to `/home/openclaw/Coding/Hermes`
3. **Before** first message: ensure no CLAUDE.md injection, no memory, no plan context
4. Copy-paste the content of one `.md` file as your first message
5. Let it run to completion without steering
6. Save the final report to `tests/v2/reports/<audit-name>-YYYY-MM-DD.md`
7. Commit the report
8. Close the session completely before starting the next one

## Rules

- **One test per session.** Never combine. Each audit's isolation is essential.
- **Run in any order.** Tests are independent; order doesn't matter.
- **Do NOT read CLAUDE.md, /tmp/, existing test scripts, or plan files.** Form conclusions from code and observed behavior only.
- **Create your own test data.** Use unique markers (e.g., `AUDIT-7-<timestamp>`) to avoid collisions with other audits.
- **Restart the hub if you crash it.** Subsequent audits assume it's healthy.

## Combining reports

When all 10 complete:

1. Compute the overall score as the **minimum** across all 10 audits (not average).
   - A system that scores 10/10 on everything except 2/10 on security is a 2/10 system.
2. List critical findings (score < 5) — those are blockers for production.
3. List medium findings (5-7) — design considerations, not blockers.
4. List positive findings (8-10) — confidence builders.
5. Write a final recommendation: Ship / Ship with caveats / Do not ship.

## System under test

- **Plugin:** `@memtensor/memos-local-hermes-plugin` installed in each Hermes agent profile
- **Hub:** HTTP server (default port 18992), serves shared group/public memories + skills
- **Backend:** Local SQLite + FTS5 (client-side) + Xenova embeddings (local, no API)
- **Skills:** Auto-generated SKILL.md files written to `~/Coding/badass-skills/auto/`
- **Capture:** Automatic on every agent turn, task summarization, skill evolution pipeline
- **Integration:** Hermes agents + Paperclip CEO + Telegram gateway (if configured)

## Prerequisites

- All Stage 2 integration worktrees merged (plugin installed, hub running, CEO access, employees wired)
- `~/.hermes/profiles/research-agent/` and `~/.hermes/profiles/email-marketing/` configured
- `~/Coding/badass-skills/` directory exists
- Hub running on `http://localhost:18992` (or check the TASK.md in the audit for override instructions)
- Hermes agents can start and accept tasks via Paperclip

## Audit methodology

Each audit:
1. Discovers the system under test (paths, endpoints, config)
2. Designs targeted probes based on the audit's scope
3. Creates own test data with unique markers
4. Reports findings with evidence (status codes, output, code paths)
5. Scores 1-10 per area tested, with justification
6. Provides overall readiness assessment

Scoring guide:
- **1-2:** Broken, unusable
- **3-4:** Major issues, unreliable
- **5-6:** Works but has gaps or concerning limitations
- **7-8:** Good, minor issues
- **9-10:** Excellent, production-ready
