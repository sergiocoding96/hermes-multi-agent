# MemOS Audit Test Suite

Six blind audits, each run in a fresh Claude Code session at `/home/openclaw/Coding/Hermes`. No session should have context from any other.

## Tests

| # | File | What it tests | Time estimate |
|---|------|---------------|---------------|
| 1 | `zero-knowledge-audit.md` | Security — auth, isolation, infrastructure exposure | 15-25 min |
| 2 | `blind-functionality-audit.md` | Core features — write, search, extraction, dedup, cross-cube | 20-30 min |
| 3 | `blind-resilience-audit.md` | Failure recovery — DB down, restart, concurrent stress, resource exhaustion | 15-25 min |
| 4 | `blind-performance-audit.md` | Latency, throughput, bottleneck profiling, scaling limits | 15-20 min |
| 5 | `blind-data-integrity-audit.md` | Cross-layer consistency (API vs Qdrant vs Neo4j), data fidelity, orphans | 15-25 min |
| 6 | `blind-observability-audit.md` | Logging, error messages, health checks, debugging, audit trail | 10-15 min |

## How to run

1. Open a fresh Claude Code session (no prior context)
2. Copy-paste the content of one `.md` file as your first message
3. Let it run to completion
4. Save the final report
5. Close the session completely before starting the next one

## Rules

- One test per session. Never combine.
- Run in order 1→6 only if you want — order doesn't matter, they're independent.
- Do NOT tell the auditor what scores you expect or what was recently fixed.
- If a test crashes the MemOS server, restart it before the next test.

## After all 6 complete

Combine the reports into a single document. The overall production-readiness score is the **minimum** of all 6 individual scores, not the average. A system that scores 10/10 on functionality but 2/10 on security is a 2/10 system.
