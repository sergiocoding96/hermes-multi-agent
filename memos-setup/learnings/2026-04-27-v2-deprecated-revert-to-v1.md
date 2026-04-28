# Decision: v2 deprecated, reverting to v1

**Date:** 2026-04-27
**Author:** sprint summary captured from Claude Code session
**Status:** Implemented (fix sprint complete, deployment switch pending operator confirmation)

## TL;DR

The Sprint 2 migration to `@memtensor/memos-local-plugin` v2 was abandoned after the v2 blind-audit suite scored mean 2.4/10, min 1/10. A clean v1 audit (run with the same rigor against the legacy MemOS server) found the v1 stack scored mean 5.2/10 across 100+ sub-areas — broken in five specific places, all surgically fixable. **Decision: fix v1, deprecate v2 to a dormant spike.** All five fixes have shipped (4 worktrees, 6 PRs across two repos). v2 is no longer the target.

## How we got here

**2026-04-20** — Sprint 2 launched: migrate from MemOS server (v1, "Product 1") to `@memtensor/memos-local-plugin` v2.0.0-beta.1 ("Product 2"). Master plan: [`2026-04-20-v2-migration-plan.md`](2026-04-20-v2-migration-plan.md). Goal: skill evolution + task summarization + auto-capture as headline features.

**2026-04-23 to 2026-04-26** — Ran the 10-audit blind suite against v2 (`tests/v2/`). Results:

- Mean: 2.4 / 10
- Min: 1 / 10 (Observability)
- Verdict: **DO NOT SHIP**

Headline killers: open authentication by default, world-readable SQLite, SSRF in `/api/v1/models/test`, no ANN vector index (O(N) scan above 10k rows), WAL truncation = silent total data loss, missing `core/hub/` files (auth, server, user-manager — entire team-sharing subsystem unimplemented), viewer/bridge daemon dead, no `/metrics` endpoint.

Full results: `tests/v2/reports/*-2026-04-26.md`. Combined PDF: `tests/v1/reports/combined/v1-mvp-readiness-2026-04-26.pdf`.

**2026-04-26** — The previous v1 audit was discovered to be context-contaminated (auditor could read CLAUDE.md, prior reports, learning docs, reused throwaway profiles). To make a fair comparison, we authored a clean v1 blind-audit suite (`tests/v1/`, 8 audits with the same contamination ban + throwaway-profile bootstrap as v2), ran it against the legacy server, and got:

- Mean of MIN scores: 1.25 / 10 (the strict suite rule — one weak link defines the system)
- Mean of all 100+ sub-area scores: 5.2 / 10 (the honest measure of overall function)
- 47 sub-areas scored 7+ ("works well")
- 17 sub-areas scored 1–2 ("broken") — concentrated in **5 specific bugs**

Full results: `tests/v1/reports/*-2026-04-26.md`. Combined PDF: `tests/v1/reports/combined/v1-mvp-readiness-2026-04-26.pdf`.

## Why v1 over v2

The decision was driven by three factors:

1. **The kind of bugs.** v1's bugs are surgical (missing function call, missing config file, missing redaction layer). v2's bugs are architectural (no ANN index, missing entire subsystems, WAL truncation = silent data loss). Surgical bugs cost days; architectural bugs cost months.

2. **Control.** v1 is your fork at `sergiocoding96/MemOS`. v2 is an upstream npm package (`@memtensor/memos-local-plugin`) mid-beta. Patches against v1 land in your repo immediately; patches against v2 either become upstream PRs (slow, dependent on MemTensor's roadmap) or local rot-prone overrides.

3. **Validated vs aspirational.** v2's headline features (skill evolution, L2/L3 abstraction, Beta-posterior lifecycle, R_human reward) are designed for 100+ similar episodes — not for the demo agents' actual usage pattern (research-agent + email-marketing-agent + CEO orchestrator running ≤20 episodes). They were architectural bets, not validated wins.

The intersection of {v2-exclusive features} ∩ {working today in v2} ∩ {high-importance to actual demo} is **empty.** v2's potential value is real but not yet realized; v1's actual function is good enough today.

Full v1↔v2 feature delta with importance ratings: `tests/v1/reports/combined/v1-mvp-readiness-2026-04-26.md` (section "v1 ↔ v2 Feature Delta").

## What was fixed

Five must-fix items from the v1 MVP-readiness report, sprint-fixed across four parallel worktrees:

| # | Bug | Worktree | PR(s) | Status |
|---|---|---|---|---|
| 1 | Missing `agents-auth.json` (system 401-on-everything) | B (auth) | Hermes #15 | ✅ |
| 2 | Silent data loss on Qdrant/Neo4j outage | A (storage) | MemOS #8 + Hermes #16 | ✅ |
| 3 | Secrets in logs and extracted memories | C (redaction) | MemOS #6 | ✅ |
| 4 | `delete_node_by_prams` leaves Qdrant orphans | A (storage) | MemOS #8 | ✅ |
| 5 | Rate limiter broken (Redis fallback + O(N) BCrypt) | B (auth) | MemOS #7 | ✅ |
| — | Plus: v1.0.3 auto-capture in plugin (Functionality MIN driver) | D (auto-capture) | Hermes #14 | ✅ |
| — | Plus: retry-queue worker (closes the at-least-once contract) | A.5 (follow-up) | MemOS #8 | ✅ |

**6 PRs total** across both repos. All merged on `main`. 4 of 4 worktrees shipped clean. Plus 4 pre-existing fixes on MemOS (`fix-auth-perf`, `fix-delete-api`, `fix-custom-metadata`, `fix-search-dedup`, `fix-fast-mode-chunking`) merged independently — they don't conflict with our fixes; they layer cleanly.

Total v1 fixes on MemOS `main`: **10 PRs.**

## Expected post-fix scores

After the v1 fix sprint:

| Audit | Pre-fix MIN | Post-fix MIN (estimate) |
|---|---|---|
| Zero-Knowledge | 3 | 6–7 |
| Functionality | 0 | 6–7 |
| Resilience | 2 | 5–6 |
| Performance | 1 | 5–6 |
| Data Integrity | 1 | 4–5 |
| Observability | 1 | 2 (still pulled down by missing `/metrics` — deferred) |
| Plugin Integration | 1 | 6–7 |
| Provisioning | 1 | 5–6 |

- Strict MIN-of-MINs: 1.25 → ~2 (Observability floors)
- Mean of all sub-area scores: 5.2 → ~7 (the honest MVP-readiness measure)

Optional next step: implement Prometheus `/metrics` endpoint (1–2 days). That lifts Observability MIN from 1 to 4–5, which lifts the strict MIN-of-MINs to ~4–5. Recommended if there's headcount; skippable for MVP-now.

## What's deferred (not blocking MVP)

- Process supervisor for the MemOS server (Resilience report Item 7)
- `/metrics` Prometheus endpoint (Observability)
- Backup/restore tooling (Data Integrity)
- Multi-machine deployment (hardcoded paths in deploy/)
- Concurrency cliff at 5+ simultaneous agents (architectural — SQLite WAL serialization)
- Source-tagging in `CompositeCubeView` results (CEO can still infer from context)
- Polardb/postgres parent-class delete bug (theoretical — your stack is Neo4j-only)
- Semantic dedup in plugin auto-capture (current is exact-match-per-session)
- Cross-session dedup in plugin
- Tamper-evident queue payload signing
- Wiring the new `/health/deps` endpoint into plugin auto-capture for outage-aware short-circuit
- Dispatcher classifier duplication in MemOS (cosmetic refactor)

These should be documented as "known limitations" on the MVP shipping page.

## What this means for the deployment

**Strategic:** v2 (`@memtensor/memos-local-plugin`) is now a dormant spike. Do not enable in production. Revisit if MemTensor ships v2.1 stable in 3+ months and the architectural issues are resolved upstream.

**Operational:**
- v1 server (`sergiocoding96/MemOS`) is the production target.
- Both clones (`sergiocoding96/hermes-multi-agent` and `sergiocoding96/MemOS`) need to be pulled to `main` on the deployment box.
- v1 server needs to be the active backend that demo agents talk to. If v2 plugin processes / data dirs (`~/.hermes/memos-plugin/`, `~/.hermes/memos-state-*/memos-local/`) are still active on the box, they need to be deactivated (or the agents reconfigured to route through the v1 server on `localhost:8001`).
- Plugin runtime at `~/.hermes/plugins/memos-toolset/` should reflect the un-archived v1 client plugin (commit `c2a64bb` un-archived it; `deploy/install.sh` should mirror it to the runtime location).

A separate operator-side runbook (`tests/v1/STEP-BY-STEP.md` / `tests/v1/CC-PROMPTS.md`) covers the mechanical steps. This document is the strategic record.

## What needs to change in the docs

- [x] This decision doc (you're reading it)
- [ ] `CLAUDE.md` — flip the "Sprint 2 in progress: migrating to v2" header (separate commit in this PR)
- [ ] `deploy/plugins/memos-toolset/DEPRECATED.md` — file is misleading (plugin is no longer archived); remove or rename to `HISTORY.md` with revised content
- [ ] `deploy/systemd/memos-hub.service` — was for v2 hub; either deactivate or document as legacy

## Re-audit gate

Before declaring v1 MVP-ready, re-run the same v1 blind audit suite (`tests/v1/`) against the post-fix system. Same prompts; only the report-branch date changes. Phase 7 of the runbook covers this.

If post-fix mean ≥ 7 and strict MIN ≥ 4 (or ≥ 2 with Observability documented as a known limitation), ship the MVP. Otherwise: one-week sprint targeting the remaining low scorers, then re-audit, then ship.

## References

- Audit suite source: `tests/v1/*.md` and `tests/v2/*.md`
- Audit reports: `tests/v1/reports/*-2026-04-26.md`, `tests/v2/reports/*-2026-04-26.md`
- Combined v1 MVP-readiness PDF: `tests/v1/reports/combined/v1-mvp-readiness-2026-04-26.pdf`
- Two-repo team explainer: `docs/architecture/two-repos.pdf`
- Original v2 migration plan (now superseded): `memos-setup/learnings/2026-04-20-v2-migration-plan.md`
- Memory alternatives evaluation: `memos-setup/learnings/2026-04-22-memory-alternatives-scope.md`
- v2 acceptance amendment (final attempt to make v2 work before reverting): `memos-setup/learnings/2026-04-25-v2-acceptance-amendment.md`
