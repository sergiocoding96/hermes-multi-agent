# memos-local-plugin v2.0 Functionality Blind Audit

Paste this as your FIRST message into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`. No other context should be present.

---

## Prompt

`@memtensor/memos-local-plugin` v2.0.0-beta.1 is installed on this machine for at least one agent host. The plugin implements Reflect2Evolve V7 across four memory layers:

- **L1 trace** (`core/memory/l1/` + `core/capture/`) — per-step grounded records with fields `value` (V_t), `alpha` (α_t), `priority`, `r_human`, plus `vec_summary` + `vec_action` embeddings.
- **L2 policy** (`core/memory/l2/`) — cross-task strategies induced by clustering traces on signature + cosine similarity, then LLM-packing with the `l2.induction` prompt. Status: `candidate → active → retired`.
- **L3 world model** (`core/memory/l3/`) — compressed environment cognition clustered from active L2s via the `l3.abstraction` prompt.
- **Skill** (`core/skill/`) — callable capabilities crystallised from eligible L2 policies with the `skill.crystallize` prompt, verified heuristically (command-token coverage + evidence resonance), and lifecycle-governed by Beta(1,1) posterior η.

Retrieval at inference time is **three-tier** (`core/retrieval/`): Tier-1 skills + Tier-2 trace/episode + Tier-3 world model, fused via **per-channel Reciprocal Rank Fusion** across `vec_summary` / `vec_action` / `fts` (FTS5 trigram, migration `010-search-fts.sql`) / `pattern` (CJK bigram LIKE) / `structural` (error-signature replay) channels, then **MMR** diversified (`λ = weightCosine` default 0.7). Five entry points: `turnStart`, `toolDriven`, `skillInvoke`, `subAgent`, `repair`.

Your job: **determine whether the capture → reward → induce → crystallize → retrieve loop actually works**, end-to-end, and whether every advertised algorithmic invariant holds. You are testing functionality, not security.

Use marker `FN-AUDIT-<unix-ts>`. Install into a throwaway profile (`MEMOS_HOME=/tmp/memos-fn-<ts>` + point `bash install.sh` at it) so you can nuke and retry without contaminating other runs.

### Recon (10 min — do this first)

1. Read `apps/memos-local-plugin/README.md`, `ARCHITECTURE.md`, `AGENTS.md`, `CHANGELOG.md` in the installed source tree.
2. Read every `README.md` under `core/` — at minimum `capture/`, `memory/l2/`, `memory/l3/`, `skill/`, `retrieval/`, `reward/`, `feedback/`, `pipeline/`, `session/`, `episode/`.
3. Enumerate `agent-contract/memory-core.ts` — this is the facade. List every method.
4. Enumerate `agent-contract/jsonrpc.ts::RPC_METHODS` — list every RPC name.
5. Enumerate `core/storage/migrations/*.sql` — what tables + indexes exist?
6. Enumerate `server/routes/*.ts` — list every `METHOD /path`.

### Functional probes

**Turn pipeline round-trip (adapter boundary).**
- Drive a turn via the JSON-RPC bridge (or the OpenClaw in-process API). Call `session.open` → `episode.open` → `turn.start` → `turn.end` → `feedback.submit`. Confirm each returns the DTO shape documented in `agent-contract/dto.ts`.
- Via `bridge/stdio.ts` (spawn `node --experimental-strip-types bridge.cts --agent=hermes`), send one line per request and assert JSON-RPC 2.0 envelopes on the response.
- Confirm `turn.start` returns a `RetrievalResultDTO` with a non-empty `packet` when memories exist, and an empty-but-valid packet on a cold DB.

**Capture pipeline (`core/capture/`).**
- Drive ~5 turns with explicit reflection blocks (`### Reasoning:` or `<reflection>…</reflection>`) in the assistant text. Verify exactly 5 `traces` rows land (`sqlite3 data/memos.db 'SELECT id, value, alpha, priority, r_human FROM traces'`).
- Run 5 turns WITHOUT reflection. With `capture.synthReflections: true` (default), confirm the synth LLM fills `reflection` and α is non-zero. With `synthReflections: false`, confirm α=0 and `usable=false`.
- Batch mode: set `capture.batchMode: "auto"` and episode length ≤ 12 steps — verify ONE LLM call covers the whole episode (grep `logs/llm.jsonl` for `op:"capture.batch"`). For > 12 steps, confirm per-step fallback.
- Tool-merge rule: send an assistant turn followed by a `tool` turn within the same segment. Confirm they produce ONE trace with a `tool_calls_json` entry, not two traces.
- Synthetic fallback: send a user turn with no assistant response. Confirm one skeletal trace is still produced (so reward has something to attach to).

**Reward + backprop (`core/reward/`).**
- After an episode finalises, confirm `capture.done` fires, then (by default) `feedbackWindowSec: 30` later `reward.runner` runs and populates `episode.r_task` + per-trace `value`.
- Submit explicit feedback via `feedback.submit` before the window closes — confirm `reward.updated` fires immediately (no timer wait).
- Formula check: `V_T = R_human`; `V_t = α_t · R_human + (1 − α_t) · γ · V_{t+1}`. For a 3-step episode with known α values and R_human, compute V_t by hand and assert the DB matches (tolerance 1e-6).
- Priority: `priority = max(V, 0) · 0.5^(Δt_days / decayHalfLifeDays)`. Insert a trace with a past `ts`, run backprop, confirm priority decays accordingly.

**L2 induction (`core/memory/l2/`).**
- After each `reward.updated`, the L2 subscriber associates high-V traces with existing policies, drops unmatched traces into `l2_candidate_pool` keyed by `signature = primaryTag|secondaryTag|tool|errCode`, and (when ≥ `minEpisodesForInduction` = 2 distinct episodes share a signature) calls the `l2.induction` prompt to mint a candidate.
- Drive 3 episodes that share a signature. Confirm: (a) a row appears in `l2_candidate_pool`, (b) after the third, a `policies` row with `status=candidate` lands, (c) `l2.induced` event fires on SSE.
- Gain check: `gain = weightedMean(with) − mean(without)`. After induction, verify the DB's `policies.gain` matches a manual computation from the contributing traces.
- Archive path: a policy whose `gain` drops below `archiveGain: -0.05` should transition to `retired`. Induce, then inject low-V traces matching the policy; confirm the transition.

**L3 abstraction (`core/memory/l3/`).**
- Drive enough activity to promote ≥ 3 L2 policies to `active` with `gain ≥ 0.1, support ≥ 1`. L3 listens to `l2.policy.induced` and, subject to `cooldownDays: 1` per cluster, clusters active policies by centroid cosine and calls `l3.abstraction`.
- Confirm: a `world_model` row appears with `policy_ids_json` covering the cluster. `confidenceDelta: 0.05` on merges — verify a second run on overlapping policies merges instead of creating a duplicate.
- `l3.abstraction` uses JSON mode + a validator. Inject a malformed LLM response (via a fake-llm harness or by temporarily switching to a provider that returns garbage) — confirm the validator rejects and the world model is NOT written.

**Skill crystallization (`core/skill/`).**
- Eligibility (`eligibility.ts`): `policy.status === 'active' ∧ gain ≥ minGain (0.1) ∧ support ≥ minSupport (2)` AND no non-retired skill cites the policy (or the existing skill is older than the policy → rebuild).
- Drive an eligible policy. Confirm: (a) `skill.crystallize` LLM draft, (b) heuristic verifier (`verifier.ts`) runs coverage + resonance — coverage ≥ 50%, resonance ≥ `minResonance` (0.5), (c) packager writes a `skills` row with `status='probationary'`, `eta` seeded from policy gain.
- Lifecycle: invoke the skill (`skill.invoke` path or synthesize a trial via `applySkillFeedback`). Pass `probationaryTrials` (default 3) `trial.pass` → expect transition to `active`. Fail 3 → expect `retired`. Verify η moves via Beta posterior `(passed+1)/(attempts+2)`.
- User signals: `user.positive` increments η by `etaDelta` (0.1); `user.negative` decrements. Below `retireEta` (0.25) → retired. Verify each transition fires `skill.status.changed` on SSE.

**Three-tier retrieval (`core/retrieval/`).**
- `turnStart` entry point: run Tier-1 + Tier-2 + Tier-3 against a query. Confirm the `InjectionPacket` has snippets from up to 3 tiers, topK=3/5/2 respectively.
- Multi-channel RRF: write a memory that matches a query via BOTH `vec_summary` AND `fts` (exact rare keyword). Write another matching only vector. Confirm the dual-channel hit ranks higher — inspect `retrieval.tier2.hit` events for the `channels` field.
- Adaptive threshold: with `relativeThresholdFloor: 0.4`, write memories of varying relevance. Confirm weakly-relevant items are dropped; a strong query's top-N respects `topRelevance · 0.4`.
- MMR diversity: seed 5 near-duplicate traces + 5 distinct relevant ones. Request top-5 via `turnStart`. Confirm ≤ 2 near-duplicates survive MMR.
- Smart seed: with `smartSeed: true`, a stale Tier-1 skill whose best candidate is below the relative threshold must NOT be force-seeded. Create that condition (e.g. low-η skill, unrelated query) and verify.
- LLM filter (`llm-filter.ts`): with `llmFilterEnabled: true` and `llmFilterMinCandidates: 2`, confirm the filter runs on packets of ≥ 2 candidates. Then kill the LLM (point the provider at an unreachable endpoint) — confirm fail-closed fallback keeps at least 1 item and applies the `0.7·topScore` mechanical cutoff.
- Skill injection mode: with `skillInjectionMode: "summary"` (default), the packet carries `name + η + status + 1-line summary + skill_get hint`, NOT the full `invocationGuide`. With `skillInjectionMode: "full"`, the guide inlines (truncated to 640 chars).

**Decision-repair (`core/feedback/`).**
- Fire ≥ `failureThreshold` (3) tool-outcome failures for the same `toolId` within `failureWindow` (5 steps). Confirm `feedback.decision_repair.generated` event, a row in `decision_repairs`, and — on the NEXT turn — the repair packet merges into the injection (`repairRetrieve`).
- Classify user feedback: send "use X instead of Y" — confirm `classifier.ts` emits `preference` with `prefer=X, avoid=Y`. Send "wrong" — `negative`. Send "great" — `positive` (no repair).
- `attachRepairToPolicies: true` — confirm a `@repair` block appears in the source policies' `boundary` field, idempotently (re-run: no duplicate lines).

**DTO stability (the contract).**
- Every response from `agent-contract/*` must match the documented shape. For each of `TraceDTO, PolicyDTO, WorldModelDTO, SkillDTO, FeedbackDTO, EpisodeListItemDTO, RetrievalResultDTO, InjectionPacket, CoreHealth, ModelHealth`, issue a request returning it and diff against `agent-contract/dto.ts` + `memory-core.ts`. Missing, extra, or mis-typed fields are bugs.
- Error contract: trigger each error code documented in `agent-contract/errors.ts::ERROR_CODES` (at minimum `invalid_argument`, `not_found`, `session_not_found`, `trace_not_found`, `llm_unavailable`, `unknown_method`, `protocol_error`). Confirm each returns `error.data.code === "<code>"` over JSON-RPC and matches over HTTP (`server/routes/*` translate via the same codes).

**Embedder + LLM provider plumbing.**
- `core/embedding/providers/` — local (Xenova MiniLM), openai-compat, gemini, cohere, voyage, mistral. With `provider: "local"`, confirm dim=384 and `normalize.ts` L2-normalises. Switch to `openai_compatible` with an unreachable endpoint; confirm a clear `embedding_unavailable` error and capture continues with `vec=null`.
- `core/llm/providers/` — openai-compat, anthropic, gemini, bedrock, host, local_only. With `llm.fallbackToHost: true`, confirm `HostLlmBridge` routes through the OpenClaw host LLM when the primary provider is unset. With `local_only`, confirm LLM-dependent stages (capture synth, reward rubric, l2-induction, l3-abstraction, skill-crystallize, decision-repair, retrieval-filter) degrade gracefully per each module's fallback (heuristic reward, α=0 capture, template synthesize, etc.).

**Content fidelity round-trip.**
- Write: Unicode + emoji 🔥, CJK (中文), 10k-char single paragraph, fenced code blocks, JSON blobs, HTML-trigger text (`<script>`), URLs with query strings + fragments, numbers `3.14159265`, empty strings, `null`. Each survives `getTrace(id)` byte-for-byte?

### Scoring

For each probe:
- What you tested + expected behaviour (from source).
- Actual behaviour (DB rows, event stream, timing).
- 1-10 with a one-line justification.

Summary table:

| Area | Score 1-10 | Key finding |
|------|-----------|-------------|
| Turn pipeline (JSON-RPC round-trip) | | |
| Capture (steps, reflection, α, batch) | | |
| Reward (R_human, backprop, priority) | | |
| L2 induction + gain + archive | | |
| L3 abstraction + merge + cooldown | | |
| Skill crystallization + verifier | | |
| Skill lifecycle (Beta η, status) | | |
| Three-tier retrieval + RRF + MMR | | |
| LLM filter fail-closed | | |
| Decision-repair trigger + attach | | |
| DTO + error-code stability | | |
| Provider plumbing (LLM + embed) | | |
| Content fidelity | | |

**Overall functionality score = MIN of all sub-areas.**

### Out of bounds

Do NOT read `/tmp/` beyond files you created this run, `CLAUDE.md`, other reports under `tests/v2/reports/`, plan files under `memos-setup/learnings/`, existing `perf-audit-*.mjs` / `PERF-AUDIT-REPORT.md` / `scripts/worktrees/INITIATION-PROMPT.md`, or the previous round's aggregate verdict. Form conclusions from the plugin source + runtime behaviour only.


### Deliver — end-to-end (do this at the end of the audit)

Reports land on the shared branch `tests/v2.0-audit-reports-2026-04-22` (at https://github.com/sergiocoding96/hermes-multi-agent/tree/tests/v2.0-audit-reports-2026-04-22). Every audit session pushes to it directly — that's how the 10 concurrent runs converge.

1. From `/home/openclaw/Coding/Hermes`, ensure you are on the shared branch:
   ```bash
   git fetch origin tests/v2.0-audit-reports-2026-04-22
   git switch tests/v2.0-audit-reports-2026-04-22
   git pull --rebase origin tests/v2.0-audit-reports-2026-04-22
   ```
2. Write your report to `tests/v2/reports/functionality-v2-$(date +%Y-%m-%d).md`. Create the directory if it does not exist. The filename MUST use the audit name (matching this file's basename) so aggregation scripts can find it.
3. Commit and push:
   ```bash
   git add tests/v2/reports/<your-report>.md
   git commit -m "report(tests/v2.0): functionality audit"
   git push origin tests/v2.0-audit-reports-2026-04-22
   ```
   If the push fails because another audit pushed first, `git pull --rebase` and push again. Do NOT force-push.
4. Do NOT open a PR. Do NOT merge to main. The branch is a staging area for aggregation.
5. Do NOT read other audit reports on the branch (under `tests/v2/reports/`). Your conclusions must be independent.
6. After pushing, close the session. Do not run a second audit in the same session.
