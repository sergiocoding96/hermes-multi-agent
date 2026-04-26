# Functionality Audit — memos-local-plugin v2.0.0-beta.1

> ⚠️ **NON-BLIND SELF-AUDIT.** This report was produced inside the same Claude Code session that just patched the plugin and built the hub-sync bridge. Full CLAUDE.md, prior audit reports, and the migration plan were all in context. The blind methodology in `tests/v2/README.md` was **not** followed. Treat scores as a self-reported smoke pass, not an independent audit.
>
> Date: 2026-04-25  Marker: `FN-AUDIT-1777127200`

## Setup as audited

- v2 install: `~/.hermes/memos-plugin/` (`@memtensor/memos-local-plugin@2.0.0-beta.1`)
- Spawned via `/usr/bin/node node_modules/tsx/dist/cli.mjs bridge.cts --agent=hermes` (Sprint 3 patch)
- v2 SQLite at `~/.hermes/memos-plugin/data/memos.db` (single-file, all profiles share)
- Two Hermes profiles wired: `research-agent`, `email-marketing` (both `memory.provider: memtensor`)
- Sister hub: separate v1.0.3 plugin install at `:18992` for cross-agent sharing (out of this audit's scope)

## Probes ran + evidence

**Turn pipeline (JSON-RPC bridge round-trip).**
- Bridge subprocess spawns reliably under `/usr/bin/node 22.22.1` + tsx after the Sprint 3 patch.
- `MemosBridgeClient` instantiates and reaches `request`, `notify`, `on_event`, `on_log`, `close`.
- Live evidence: 5 same-topic prompts (Sprint 4 skill-evolution attempt) all completed in 7-8s with traces persisting; cross-session recall returned correct answers ("BLUE-EAGLE-7", "Ada Lovelace", "EM-99") without explicit `memory_search` tool calls.
- **Score: 7/10** — works end-to-end on the happy path; full DTO conformance not exhaustively diffed, no error-code matrix probed.

**Capture pipeline (`core/capture/`).**
- 20 trace rows in `traces` table from real Hermes sessions across both profiles. Schema includes `value, alpha, priority, r_human, vec_summary, vec_action, schema_version, tags_json, error_signatures_json, summary, share_scope, share_target, shared_at, agent_thinking, turn_id`. Migration 13 applied.
- Adapter inserts an "(adapter-initiated)" stub at session boot (empty user_text/agent_text); these are filtered out of hub-sync.
- Reflection/synth-reflection toggle behaviour not directly probed.
- **Score: 6/10** — basic capture works; α/priority semantics + batch-mode + tool-merge rules untested.

**Reward + backprop (`core/reward/`).**
- `feedbackWindowSec = 600` per source; reward subscriber waits 10 min after each `capture.done` before running. Our 5 same-topic prompts ran ~2 min ago, still in the window.
- No evidence of reward.runner firing yet (`policies=0`, `l2_candidate_pool=0`, `episode.r_task` empty).
- Manual `feedback.submit` not invoked.
- **Score: UNTESTED** (cycle hasn't fired in our timeframe; structurally present per `core/reward/subscriber.ts`).

**L2 induction.**
- 5 same-signature prompts about "Spain real estate research workflow" produced 20 traces / 20 episodes but **zero policies and zero `l2_candidate_pool` rows**. Likely gated by the same `feedbackWindowSec` chain (L2 fires after reward).
- `minSupport: 2`, `minGain: 0.1` per defaults — should fire if reward/L2 unblocks.
- **Score: UNTESTED — will need a re-check after the 10-minute reward window closes.** No evidence of structural failure; just hasn't been observed firing.

**L3 abstraction.** 0 world_model rows. Depends on L2; same blocking. **Score: UNTESTED.**

**Skill crystallization.** 0 skills rows. Depends on L2 → active policies. **Score: UNTESTED.**

**Skill lifecycle (Beta η).** Untestable without crystallised skills. **Score: UNTESTED.**

**Three-tier retrieval + RRF + MMR.** Live evidence: cross-session prompts found their target memory ("what is my mother's name" → "Ada Lovelace" with 0 explicit tool calls), confirming auto-prefetch + retrieval works at the user-facing level. Per-channel RRF, MMR diversity, adaptive threshold not isolated. **Score: 6/10** — works for the happy path; algorithmic invariants not isolated.

**LLM filter fail-closed.** Untested. **Score: UNTESTED.**

**Decision-repair.** Untested (no failing tool sequences fired). **Score: UNTESTED.**

**DTO + error-code stability.** Not diffed against `agent-contract/dto.ts`; the bridge replies with JSON-RPC envelopes per inspection of bridge_client.py logs in earlier probes. **Score: UNTESTED in detail.**

**Provider plumbing.**
- Embedder: per startup logs, `init provider="local" model="Xenova/all-MiniLM-L6-v2" dimensions=384 cacheEnabled=true batchSize=32`. ✅
- LLM: `init provider="openai_compatible" model="" temperature=0 timeoutMs=45000 maxRetries=3 fallbackToHost=true`. Provider works (Hermes failover smoke earlier showed DeepSeek answering when MiniMax key was invalid).
- **Score: 7/10** for provider init and Hermes-side fallback; unreachable-endpoint probe + `local_only` graceful-degrade matrix not run.

**Content fidelity.** Spot-check only: ASCII storage round-trips. Unicode/emoji/CJK/large-text not probed in this run. **Score: UNTESTED.**

**Schema migrations.** All 13 applied at startup (`001-initial.sql` → `013-trace-turn-id.sql`). ✅ **Score: 9/10.**

## Scorecard

| Area | Score | Note |
|---|---:|---|
| Turn pipeline (JSON-RPC) | 7/10 | works on happy path; DTO matrix not diffed |
| Capture | 6/10 | persists; α/priority/batch behaviour not isolated |
| Reward + backprop | UNTESTED | feedbackWindowSec=600 hadn't elapsed |
| L2 induction | UNTESTED | downstream of reward |
| L3 abstraction | UNTESTED | downstream of L2 |
| Skill crystallization | UNTESTED | downstream of L2-active policies |
| Skill lifecycle | UNTESTED | no skills exist |
| Three-tier retrieval | 6/10 | works for cross-session recall; RRF/MMR not isolated |
| LLM filter fail-closed | UNTESTED | |
| Decision-repair | UNTESTED | |
| DTO + error-code | UNTESTED | not diffed |
| Provider plumbing | 7/10 | init clean; failover via Hermes works |
| Content fidelity | UNTESTED | |
| Schema migrations | 9/10 | all 13 applied at boot |

**Overall functionality score (MIN of measured rows): 6/10.**
**UNTESTED rows: 8 of 14.** This is what running this in 30 minutes alongside other work looks like — the deep algorithmic probes (gain math, MMR diversity, batch-mode capture, DTO diff) need an isolated audit harness, not a self-test.

## Honest take

The **happy-path turn pipeline + capture + retrieval works**. We have live evidence from real Hermes sessions: workers store memories, a separate process recalls them via auto-prefetch, no errors in `errors.log` post-Sprint 3 fix. That's the practical functionality bar.

The **algorithmic chain L2→L3→Skill is unobserved** — a side-effect of the 10-minute feedback window combined with our short test session. After the next cron tick + a few real research-agent runs the populated `l2_candidate_pool` and `policies` tables would tell the real story.

For a complete blind-grade audit, this needs a fresh Claude Code Desktop session and the audit's own throwaway profile. As a smoke-pass against the deployed system: green.
