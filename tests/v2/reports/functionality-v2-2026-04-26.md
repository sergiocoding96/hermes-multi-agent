# memos-local-plugin v2.0.0-beta.1 — Functionality Blind Audit

**Marker:** FN-AUDIT-1777210065  
**Date:** 2026-04-26  
**Plugin source:** `/home/openclaw/Coding/MemOS/apps/memos-local-plugin`  
**Throwaway home:** `/tmp/memos-fn-1777210065`  
**Method:** Static source analysis + full test suite execution (vitest, 810 tests)

---

## Recon findings

### MemoryCore interface — public methods
`agent-contract/memory-core.ts` exposes the following methods:

**Lifecycle:** `init`, `shutdown`, `health`  
**Session/episode:** `openSession`, `closeSession`, `openEpisode`, `closeEpisode`  
**Per-turn pipeline:** `onTurnStart`, `onTurnEnd`, `submitFeedback`, `recordToolOutcome`  
**Memory queries:** `searchMemory`, `getTrace`, `updateTrace`, `deleteTrace`, `deleteTraces`, `shareTrace`, `getPolicy`, `getWorldModel`, `listPolicies`, `listWorldModels`, `setPolicyStatus`, `deletePolicy`, `editPolicyGuidance`, `deleteWorldModel`, `sharePolicy`, `shareWorldModel`, `updatePolicy`, `updateWorldModel`, `archiveWorldModel`, `unarchiveWorldModel`, `listEpisodes`, `listEpisodeRows`, `timeline`, `listTraces`, `listApiLogs`  
**Skills:** `listSkills`, `getSkill`, `archiveSkill`, `deleteSkill`, `reactivateSkill`, `updateSkill`, `shareSkill`  
**Config (viewer):** `getConfig`, `patchConfig`  
**Analytics:** `metrics`  
**Export/import:** `exportBundle`, `importBundle`  
**Observability:** `subscribeEvents`, `getRecentEvents`, `subscribeLogs`, `forwardLog`

### RPC_METHODS — canonical method names
`core.init`, `core.shutdown`, `core.health`, `session.open`, `session.close`, `episode.open`, `episode.close`, `turn.start`, `turn.end`, `feedback.submit`, `memory.search`, `memory.get_trace`, `memory.get_policy`, `memory.get_world`, `memory.list_episodes`, `memory.timeline`, `memory.list_traces`, `skill.list`, `skill.get`, `skill.archive`, `retrieval.query`, `config.get`, `config.patch`, `hub.status`, `hub.publish`, `hub.pull`, `logs.tail`, `logs.forward`, `events.subscribe`, `events.unsubscribe`, `events.notify`

### Storage migrations (13 total)
`001-initial.sql` — sessions, episodes, traces, policies, l2_candidate_pool, world_model, skills, feedback, decision_repairs, audit_events, kv  
`002-trace-tags.sql` — tags column on traces  
`003-world-model-structure.sql` — title/body split  
`004-trace-error-signatures.sql` — error_code, primary_tag, secondary_tag  
`005-trace-summary.sql` — LLM-generated summary  
`006-trace-sharing.sql` — share_scope/target/shared_at  
`007-api-logs.sql` — api_logs table  
`008-skill-version.sql` — version monotonic counter on skills  
`009-share-and-edit.sql` — policies/world_model/skills share+edit fields  
`010-search-fts.sql` — FTS5 trigram + CJK bigram virtual tables  
`011-trace-agent-thinking.sql` — agent_thinking column  
`012-status-unification.sql` — status vocabulary alignment  
`013-trace-turn-id.sql` — turn_id grouping column

### Server routes
`GET/POST /api/v1/system` (health), `GET/PATCH /api/v1/config`, `GET /api/v1/memory/traces`, `GET /api/v1/memory/policies`, `GET /api/v1/memory/world`, `GET /api/v1/skills`, `POST /api/v1/feedback`, `GET /api/v1/retrieval/preview`, `GET /api/v1/hub/*`, `GET /api/v1/changelog`, `GET /api/v1/logs/tail`, `GET /events` (SSE), `GET /api/v1/metrics`, `GET /api/v1/sessions/episodes`, `GET /api/v1/traces/*`, `GET /api/v1/policies/*`, `GET /api/v1/models`, `GET /api/v1/admin/*`, `POST /api/v1/migrate` (diag)

---

## Test suite execution

```
npm test  (vitest, node v25.8.2)
Test Files: 4 failed | 107 passed (111)
Tests:      6 failed | 802 passed | 2 skipped (810)
Duration:   63.48s
```

TypeScript strict compile (`tsc --noEmit`) additionally surfaced **10 type errors** (detailed below).

---

## Functional probes

### 1. Turn pipeline round-trip (adapter boundary)

**Method:** `tests/unit/bridge/methods.test.ts` (8 tests), `tests/unit/bridge/stdio.test.ts` (3 tests), `tests/unit/adapters/openclaw-bridge.test.ts` (31 tests), `tests/unit/adapters/hermes-protocol.test.ts` (7 tests) — **all 49 pass**.

**What was tested and expected:** The JSON-RPC bridge dispatches every `RPC_METHODS` name to the correct `MemoryCore` method and returns a `JsonRpcSuccess` envelope. The stdio transport framing (newline-delimited JSON) is exercised. DTO shapes on `turn.start`, `turn.end`, `feedback.submit` match `agent-contract/dto.ts` — `InjectionPacket` fields (`snippets`, `rendered`, `packetId`, `sessionId`, `episodeId`, `tierLatencyMs`, `ts`) all present.

**Actual behavior:** All 49 tests pass. `turnStartRetrieve` returns an empty-but-valid `InjectionPacket` on a cold DB (no panics, no missing fields). Cold-start probe: `snippets: []`, `rendered: ""`, `tierLatencyMs: {tier1:N, tier2:N, tier3:N}` — correctly shaped.

**Note:** Live bridge startup via `--experimental-strip-types` fails because the bridge `.cts` imports compiled `.js` files that don't exist without a `tsc` build step. The bridge is not runnable directly from source. Tests use vitest's in-process transformer instead. No compiled `dist/` output exists in the repository.

**Score: 8** — Protocol correct; bridge unusable without a build step (no `dist/`).

---

### 2. Capture pipeline

**Method:** `tests/unit/capture/*.test.ts` — 71 tests, **70 pass, 1 fail**.

**What was tested and expected:**
- Step extraction → normalization → reflection extraction → α-scoring → embed → persist: correct per-step trace rows.
- `synthReflections: true` (default): LLM fills reflection, α > 0.
- `synthReflections: false`: α = 0, `usable = false`.
- Batch mode `"auto"` ≤12 steps: ONE LLM call covers the episode.
- Tool-merge: assistant + tool turn in same segment → ONE trace row with `tool_calls_json`.
- Synthetic fallback for turns with no assistant response: skeletal trace inserted.

**Actual behavior — passing:** Step extractor, normalizer, reflection extractor, α-scorer, embedder, batch-scorer, reflection-synth, tagger all pass their unit tests fully. Batch mode `"auto"` verified via `capture-batch.test.ts` (8/8): under 12 steps triggers one `op:"capture.batch"` LLM call; over 12 falls back per-step.

**Actual behavior — failing (1 test):**

> `capture/pipeline (end-to-end) > emits capture.started for both phases and capture.done at topic end`

Expected event sequence: `["capture.started", "capture.started", "capture.done"]`  
Actual: `["capture.started", "capture.lite.done", "capture.started", "capture.done"]`

**Root cause:** The lite pass now emits `capture.lite.done` (added to populate `api_logs` per-turn without triggering reward). This is an intentional addition documented in `core/capture/capture.ts:222`: *"Emit `capture.lite.done` so the api_logs table gets a per-turn `memory_add` row."* The `CaptureEvent` union in `core/capture/types.ts` includes `capture.lite.done`. However, the test comment says *"stays silent on done"* and asserts the old 3-event topology. The test was not updated when `capture.lite.done` was added.

**Severity:** Test stale — implementation behavior is intentional. The concern is that the `CaptureEventBus` listener count and subscriber code must not accidentally treat `capture.lite.done` as a reward trigger. Confirmed: `core/pipeline/memory-core.ts:389` explicitly excludes `capture.lite.done` from the reward chain gate. Logic is correct; the test assertion is wrong.

**Score: 7** — Core mechanics all correct; event topology test stale; live end-to-end blocked by build issue.

---

### 3. Reward + backprop

**Method:** `tests/unit/reward/*.test.ts` — 35 tests; **3 pass, 3 fail** (reward.integration). Plus backprop.test.ts (9/9), human-scorer.test.ts (9/9), task-summary.test.ts (5/5), subscriber.test.ts (8/8) all pass.

**What was tested and expected:**
- `reward.runner.run` populates `episode.r_task` + per-trace `value`.
- LLM rubric: `R_human = 0.45·goal + 0.30·process + 0.25·satisfaction`, clamped to [-1,1].
- Backprop: `V_T = R_human`; `V_t = α_t·R_human + (1−α_t)·γ·V_{t+1}`.
- Priority decay: `max(V, 0) · 0.5^(Δt/halfLife)`.
- `submitFeedback` before window → immediate `reward.updated`.
- Feedback merge: caller-provided list + repo rows deduplicated by id.
- Zero-trace episodes: still scores `R_human` but skips backprop.

**Actual behavior — passing:** The backprop formula itself is **correct** (all 9 backprop unit tests pass including hand-computed V values at tolerance 1e-6). The human-scorer LLM path is correct (9/9 unit tests). The subscriber fires `reward.updated` on both explicit feedback and timer paths.

**Actual behavior — failing (3 tests):**

All 3 integration failures share one root cause: `decideSkipReason` fires before scoring, returning `rHuman=0` and `feedbackCount=0`.

**Root cause analysis:**

`core/reward/reward.ts::decideSkipReason` contains two unconditional guards that cannot be disabled via config:

1. **No-user-messages check (line 394):** `if (userTurns === 0) return "该任务没有用户消息..."`. Tests that seed traces with empty `userText: ""` get userTurns=0 and are immediately skipped. Config `minExchangesForCompletion: 0` does NOT bypass this.

2. **Hardcoded non-CJK content floor (line 403):** `const minContentLen = hasCJK ? cfg.minContentCharsForCompletion : Math.max(cfg.minContentCharsForCompletion, 200)`. Setting `minContentCharsForCompletion: 0` still enforces a 200-char minimum for non-CJK content. This contradicts the documented expectation that the config controls the gate.

**Specific failures:**

- *"writes updated V/priority to traces"*: `rHuman` expected ≈ 0.815, got 0. Episode skipped because traces have `userText: ""` → userTurns=0.
- *"episodes with no traces still score R_human"*: `rHuman` expected < 0 (negative feedback, no traces), got 0. Episode skipped — no user turns from traces, no snapshot turns.
- *"merges feedback from repo with caller list"*: `feedbackCount` expected 2, got 0. Episode skipped before any feedback processing.

**Impact:** This same bug causes the E2E test and OpenClaw integration test to fail (`traces.some(t => t.value > 0) === false`). Any realistic deployment that produces traces with non-empty userText would not trigger this gate — but the gate silently skips episodes without surfacing a warning visible to the caller (the `skipped: true` flag is buried inside `RewardResult.backprop`).

**Score: 3** — Backprop math is correct; the triviality gate's non-configurable guards silently eat episodes in minimal-trace scenarios and cannot be bypassed even with explicit config, causing 3 integration test failures and both full-chain test failures downstream.

---

### 4. L2 induction + gain + archive

**Method:** `tests/unit/memory/l2/*.test.ts` + `l2.integration.test.ts` — **all 42 tests pass**.

**What was tested and expected:**
- After `reward.updated`, L2 subscriber associates high-V traces with existing policies via cosine+signature blended score.
- Unmatched traces → `l2_candidate_pool` keyed by `primaryTag|secondaryTag|tool|errCode`.
- ≥ `minEpisodesForInduction` (2) distinct episodes sharing a signature → `l2.induction` prompt → `policies` row with `status=candidate`.
- Gain: `weightedMean(with) − mean(without)` verified against DB.
- Archive: policy with gain < `archiveGain` (-0.05) transitions to `retired`.

**Actual behavior:** All 42 tests pass. The `l2.integration.test.ts` (2 tests) confirms end-to-end: traces → candidate pool → induction across 3 episodes → `policies.status='candidate'` row inserted → `l2.induced` event emits. Gain formula verified at tolerance 1e-6. Archive transition fires correctly when gain drops below threshold.

**Score: 9** — Full L2 chain working; gain formula, candidate pool, subscriber, archive transition all verified.

---

### 5. L3 abstraction + merge + cooldown

**Method:** `tests/unit/memory/l3/*.test.ts` — **all 24 tests pass**.

**What was tested and expected:**
- Gather active L2s (gain/support floors), cluster by domain key + centroid cosine.
- Per-cluster: call `l3.abstraction` prompt (JSON mode + validator), produce `(ℰ, ℐ, C)` draft.
- Merge into nearest existing world model (cosine ≥ θ) or insert new; per-cluster cooldown via kv.
- Malformed LLM response → validator rejects → world model NOT written.
- `confidenceDelta: 0.05` on merges.

**Actual behavior:** All 24 tests pass. `l3.integration.test.ts` (4 tests) confirms: 3 active L2 policies → L3 abstraction call → `world_model` row inserted. Merge test: overlapping policy sets merge into existing row (no duplicate). Cooldown: second cluster run within cooldown window skipped (kv gate confirmed). Malformed LLM response rejection confirmed via `abstract.test.ts` — validator rejects and DB write does not occur.

**Score: 9** — L3 fully working; merge, cooldown, and validator all verified.

---

### 6. Skill crystallization + verifier

**Method:** `tests/unit/skill/*.test.ts` — **all 35 tests pass**.

**What was tested and expected:**
- Eligibility: `status === 'active' ∧ gain ≥ 0.1 ∧ support ≥ 2` AND no non-retired skill cites the policy.
- `skill.crystallize` LLM draft → normalization → heuristic verifier (command-token coverage ≥ 50%, evidence resonance ≥ `minResonance` 0.5).
- Packager writes `skills` row with `invocationGuide`, `procedureJson`, `vec`, `eta` seeded from policy gain.
- `status = 'probationary'` on creation.

**Actual behavior:** All 35 tests pass. `skill.integration.test.ts` (5 tests): eligible policy → `skill.crystallize` call → verifier passes → `skills` row inserted with `status='probationary'`. Verifier correctly rejects drafts with coverage < 50% or resonance < 0.5. `packager.test.ts` confirms `version` field starts at 1, increments on rebuild.

**Score: 9** — Crystallization + verifier working; eligibility guards correct.

---

### 7. Skill lifecycle (Beta η, status transitions)

**Method:** `tests/unit/skill/lifecycle.test.ts` (7 tests) — **all pass**.

**What was tested and expected:**
- Pass `probationaryTrials` (3) `trial.pass` → transitions to `active`.
- Fail 3 → transitions to `retired`.
- η moves via Beta(1,1) posterior: `η = (passed+1)/(attempts+2)`.
- `user.positive` increments η by `etaDelta` (0.1); `user.negative` decrements.
- Below `retireEta` (0.25) → retired.
- Each transition fires `skill.status.changed` event.

**Actual behavior:** All 7 lifecycle tests pass. Beta posterior formula confirmed: after 3 passes, `η = 4/5 = 0.8`. After 3 failures, `η = 1/5 = 0.2 < retireEta` → retired. User signals correctly push η. `skill.status.changed` SSE event fires on every transition.

**Score: 9** — Lifecycle correct; Beta posterior formula verified.

---

### 8. Three-tier retrieval + RRF + MMR

**Method:** `tests/unit/retrieval/*.test.ts` — **all 72 tests pass**.

**What was tested and expected:**
- `turnStart`: Tier-1 (skills, topK=3) + Tier-2 (trace+episode, topK=5) + Tier-3 (world-model, topK=2).
- Multi-channel RRF: `vec_summary` / `vec_action` / `fts` / `pattern` / `structural` channels; per-channel scores fused. Dual-channel hit ranks higher than single-channel.
- Adaptive threshold: `relativeThresholdFloor: 0.4` drops weak matches.
- MMR diversity: `λ = weightCosine` (default 0.7); near-duplicates reduced.
- Smart seed: low-η skill + unrelated query → NOT force-seeded.
- LLM filter fail-closed: unreachable endpoint → fallback keeps ≥1 item at `0.7·topScore` mechanical cutoff.
- Skill injection modes: `"summary"` (name + η + 1-line) vs `"full"` (guide truncated to 640 chars).

**Actual behavior:** All 72 retrieval tests pass. Specific confirmations:
- `ranker.test.ts` (15): RRF fusion + MMR diversification correct; near-duplicate suppression verified with seeded corpus.
- `llm-filter.test.ts` (11): fail-closed path keeps at least 1 item; `0.7·topScore` cutoff applied.
- `integration.test.ts` (7): full three-tier pipeline with real SQLite; tier latencies populated.
- `tier2.test.ts` (5): FTS channel hits verified; vec_summary and vec_action channels tested separately.
- `injector.test.ts` (7): `skillInjectionMode: "summary"` vs `"full"` confirmed; packet `rendered` field correct.

**Score: 9** — All retrieval invariants hold; RRF, MMR, LLM filter fail-closed, injection modes all verified.

---

### 9. LLM filter fail-closed

Covered under §8 above. Confirmed: `llm-filter.test.ts` (11/11). When `llmFilterEnabled: true` and provider unreachable → `MemosError(embedding_unavailable)` caught → fallback applies `0.7·topScore` mechanical cutoff → at least 1 snippet retained → no crash.

**Score: 9** — Fail-closed path verified.

---

### 10. Decision-repair trigger + attach

**Method:** `tests/unit/feedback/*.test.ts` — **all 60 tests pass**.

**What was tested and expected:**
- `feedback.signals.bumpFailure(toolId)` fires; ≥ `failureThreshold` (3) same-tool failures within `failureWindow` (5 steps) → `feedback.decision_repair.generated` → `decision_repairs` row.
- Next turn: stashed repair packet merges into `InjectionPacket`.
- Classifier: "use X instead of Y" → `preference`; "wrong" → `negative`; "great" → `positive`.
- `attachRepairToPolicies: true` → `@repair` block in `boundary` field; idempotent on re-run.

**Actual behavior:** All 60 tests pass. `feedback.integration.test.ts` (11 tests): burst of 3 tool failures → `decision_repair.generated` event → DB row inserted with `preference` and `anti_pattern` fields → next turn retrieval merges packet. `classifier.test.ts` (18): polarity/preference/antipattern classification correct for all documented patterns. `signals.test.ts` (7): threshold + window logic correct. `evidence.test.ts` (7): high-V / low-V trace selection for repair packet verified.

**Score: 9** — Decision-repair full chain working.

---

### 11. DTO + error-code stability

**Method:** `tests/unit/bridge/methods.test.ts`, `tests/unit/server/http.test.ts` (49 tests) — **all pass**. TypeScript compiler (`tsc --noEmit`) reports **10 type errors** (does not prevent runtime test execution under vitest).

**DTO shape verification:** Every `JsonRpcSuccess` response from the bridge carries the expected result shape matching `agent-contract/dto.ts`. HTTP routes (`server/routes/*.ts`) translate `MemosError.code` to documented numeric JSON-RPC codes via `rpcCodeForError`. All 7 required error codes (`invalid_argument`, `not_found`, `session_not_found`, `trace_not_found`, `llm_unavailable`, `unknown_method`, `protocol_error`) are present in `errors.ts::ERROR_CODES` and exercised in bridge tests.

**TypeScript type drift (10 errors):**

| File | Error |
|------|-------|
| `tests/integration/adapters/openclaw-full-chain.test.ts` (×2) | Implicit `any` params |
| `tests/integration/adapters/openclaw-full-chain.test.ts` | `HostLogger.trace` method missing from mock |
| `tests/unit/retrieval/integration.test.ts` (×2) | `SkillRow.version` missing — not updated after migration 008 |
| `tests/unit/retrieval/tier1.test.ts` | `RetrievalConfig` missing `llmFilterEnabled`, `llmFilterMaxKeep`, `llmFilterMinCandidates` |
| `tests/unit/retrieval/tier2.test.ts` | Same — `RetrievalConfig` 3 missing fields |
| `tests/unit/retrieval/tier3.test.ts` | Same — `RetrievalConfig` 3 missing fields |
| `tests/unit/skill/packager.test.ts` | `SkillRow.version` missing |
| `tests/unit/storage/end-to-end.test.ts` | `SkillRow.version` missing |
| `tests/unit/storage/repos.test.ts` (×2) | `SkillRow.version` missing |

Six test fixtures reference `SkillRow` without the `version` field added in migration 008. Three retrieval test configs pre-date the `llmFilterEnabled` addition. These are compile-time regressions — vitest runs them anyway (unchecked casts), so tests still pass at runtime.

**Score: 6** — Protocol and error codes correct at runtime; type drift on 6 fixtures (`SkillRow.version`) and 3 retrieval configs (`llmFilterEnabled` et al) represents a real contract staleness risk.

---

### 12. Provider plumbing (LLM + embed)

**Method:** `tests/unit/embedding/*.test.ts` (34 tests), `tests/unit/llm/*.test.ts` (33 tests) — **all 67 pass**.

**What was tested and expected:**
- Local embedder (Xenova MiniLM): `dim=384`, L2-normalized.
- `openai_compatible` unreachable → `MemosError(embedding_unavailable)` → capture continues with `vec=null`.
- LLM providers: openai-compat, anthropic, gemini, bedrock, host, local_only tested.
- `llm.fallbackToHost: true` → `HostLlmBridge` routes through OpenClaw host LLM.
- `local_only` → LLM-dependent stages (capture synth, reward rubric, l2-induction, etc.) degrade to heuristic fallbacks.
- Retry: 500 retries up to `maxRetries`; 429 → `LLM_RATE_LIMITED` after exhaustion.

**Actual behavior:** All 67 tests pass.
- `embedding/providers.test.ts` (13): local MiniLM confirmed dim=384, L2-norm verified (`∑vi²=1.0` at 1e-6).
- `embedding/embedder.test.ts` (14): unreachable provider → `embedding_unavailable` → `vec=null` written (capture proceeds).
- `llm/providers.test.ts` (9): all 6 providers instantiate and handle failure modes.
- `llm/fetcher.test.ts` (10): retry-on-500 verified; 429 after exhaustion raises `LLM_RATE_LIMITED`.
- `llm/client.test.ts` (14): `HostLlmBridge` route confirmed; `local_only` prevents real HTTP calls.

**Score: 9** — Provider plumbing fully working; failure modes and fallbacks correct.

---

### 13. Content fidelity round-trip

**Method:** `tests/unit/storage/end-to-end.test.ts` (1 test), `tests/unit/storage/fts-keyword.test.ts` (9 tests), `tests/unit/storage/repos.test.ts` (10 tests) — **all pass**.

**What was tested and expected:** Unicode + emoji, CJK (中文), 10k-char paragraphs, JSON blobs, HTML fragments (`<script>`), URLs, floats, empty strings, null — all survive `getTrace(id)` byte-for-byte. FTS5 trigram and CJK bigram channels both work.

**Actual behavior:** All 20 storage tests pass. FTS5 trigram tested for English keyword exact match. CJK bigram LIKE pattern tested for 中文 queries. `fromJsonText`/`toJsonText` round-trips verified for all JSON column types. `STRICT` table mode in SQLite (set in all migrations) enforces type correctness at DB level. Float precision: REAL column stores double; round-trip confirms `3.14159265` survives exactly.

**Score: 9** — Content fidelity correct.

---

## Summary table

| Area | Score 1-10 | Key finding |
|------|-----------|-------------|
| Turn pipeline (JSON-RPC round-trip) | 8 | Protocol + DTOs correct; bridge unrunnable without compiled `dist/` |
| Capture (steps, reflection, α, batch) | 7 | Core correct; `capture.lite.done` breaks event topology test (test stale) |
| Reward (R_human, backprop, priority) | 3 | Backprop math correct; triviality gate non-configurable, silently skips minimal-trace episodes — breaks 3 integration + 2 chain tests |
| L2 induction + gain + archive | 9 | Full chain verified; gain formula correct at 1e-6 |
| L3 abstraction + merge + cooldown | 9 | Full chain verified; merge + cooldown + validator all work |
| Skill crystallization + verifier | 9 | Full chain verified; coverage + resonance thresholds enforced |
| Skill lifecycle (Beta η, status) | 9 | Beta posterior formula correct; all transitions fire SSE events |
| Three-tier retrieval + RRF + MMR | 9 | All 72 tests pass; RRF, MMR, LLM filter fail-closed all verified |
| LLM filter fail-closed | 9 | Fail-closed path confirmed; `0.7·topScore` cutoff applied |
| Decision-repair trigger + attach | 9 | Full chain verified; threshold, classifier, idempotent attach all correct |
| DTO + error-code stability | 6 | Runtime correct; 10 TypeScript type errors (6× `SkillRow.version`, 3× `RetrievalConfig`, 1× `HostLogger`) |
| Provider plumbing (LLM + embed) | 9 | All 6 providers + retry/fallback correct; `vec=null` graceful degradation |
| Content fidelity | 9 | Storage passes all content types; FTS5 + CJK bigram working |

**Overall functionality score = MIN = 3**

---

## Critical bugs

### BUG-1 (Severity: HIGH) — Reward triviality gate non-configurable
**File:** `core/reward/reward.ts::decideSkipReason`  
**Lines:** 394 (`userTurns === 0` unconditional), 403 (`Math.max(minContentCharsForCompletion, 200)` hardcoded floor)  
**Symptom:** Setting `minExchangesForCompletion: 0` + `minContentCharsForCompletion: 0` does NOT fully disable the gate. Any episode whose traces have empty `userText` (or any non-CJK episode under 200 chars total) silently returns `rHuman=0`, skips backprop, leaves all `traces.value=0`. Downstream L2/L3/Skill pipeline receives zero-value traces and cannot build useful policies.  
**Failing tests:** `reward.integration.test.ts` (3/5), `v7-full-chain.e2e.test.ts` (1), `openclaw-full-chain.test.ts` (1).  
**Fix direction:** Either make both guards configurable (add `minUserMessageLen: 0` flag) or document clearly that the gate cannot be disabled and fix the test fixtures to use realistic non-empty userText.

### BUG-2 (Severity: MEDIUM) — TypeScript type drift: `SkillRow.version` and `RetrievalConfig`
**Files:** 6 test fixtures missing `version` after migration 008; 3 test configs missing `llmFilterEnabled`, `llmFilterMaxKeep`, `llmFilterMinCandidates`.  
**Symptom:** `tsc --noEmit` produces 10 errors. Vitest runs tests anyway (unchecked casts), masking the type regression.  
**Fix direction:** Update test fixtures and test configs to match current type definitions; add `tsc` check to CI before vitest run.

### BUG-3 (Severity: LOW) — `capture.lite.done` event topology assertion stale
**File:** `tests/unit/capture/capture.test.ts:351`  
**Symptom:** Test asserts 3-event sequence; implementation now emits 4 (adds `capture.lite.done`). Implementation is intentional and logically correct.  
**Fix direction:** Update assertion to include `capture.lite.done`.

### BUG-4 (Severity: LOW) — E2E test expects session ID to change on `new_task`
**File:** `tests/e2e/v7-full-chain.e2e.test.ts:536`  
**Symptom:** `expect(s2Ep1.sessionId).not.toBe(s1Ep1.sessionId)` fails because the orchestrator intentionally keeps the same session ID on `new_task` to prevent orphan episodes.  
**Fix direction:** Update the E2E test to reflect the stable-session-on-new-task design; test the session-stable behavior explicitly.

---

## Out-of-bounds note

Bridge live runtime could not be probed (missing `dist/`). All probes are test-based. The plugin is not runnable from source without a `tsc` build step — this is a deployment readiness gap.
