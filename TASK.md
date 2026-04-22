# Spike: Mem0 OSS as a drop-in for memos-local-plugin

**Worktree:** `/home/openclaw/Coding/Hermes-wt/spike-mem0-prototype/`
**Branch:** `spike/mem0-prototype` (cut from `main` / `aad6d79`)
**Timebox:** 3-5 days of focused work. If the spike exceeds 7 days, stop and report.
**Posture:** **Hedge, not migration.** This spike produces a working prototype and an A/B readout against the v2.0 plugin — not a ship decision. The ship decision is made by the human after reading the readout alongside the v2.0 audit reports.

---

## Why this exists

`@memtensor/memos-local-plugin` (Product 2) scored **MIN 1/10** on the 2026-04-21 blind-audit round (see `tests/v2/reports/AGGREGATE-VERDICT-2026-04-21.md` on `tests/v2-audit-reports-2026-04-21`). Upstream shipped a v2.0 rewrite hours later that fixes some of the floor findings; a fresh 10-audit round is running in parallel on `tests/v2.0-audit-reports-2026-04-22`.

If v2.0's MIN does not clear 6/10 in that second round, we need a drop-in. Memory-alternatives scoping (`memos-setup/learnings/2026-04-22-memory-alternatives-scope.md` on `docs/memory-alternatives-scope`) landed on:

1. **Primary OSS:** Mem0 (53k ★, Apache-2.0, genuinely local with SQLite + local Qdrant + Ollama, lowest prototype cost). **This spike.**
2. **Secondary OSS:** Letta — escalate if Mem0 retrieval quality is insufficient.
3. **Commercial fallback:** Mem0 Platform Pro ($249/mo) — same SDK, flip a config.

The point of prototyping now (in parallel with the v2.0 audits) is so the ship decision has real comparative data, not two different flavours of speculation.

---

## What "done" looks like

At end of spike, produce:

1. **A working prototype** that captures + retrieves memory for one Hermes agent via Mem0 OSS, fully local (no cloud, no API keys).
2. **An adapter layer** (`hermes_lib/memory_backend/`) with a provider interface that `memos-local-plugin` v2.0 *could* also plug into. The interface must be narrow enough that swapping Mem0 → Letta → Mem0 Platform is a config change, not a rewrite.
3. **An A/B report** (`reports/mem0-vs-v2.0-<date>.md`) against the same 10 axes as the v2.0 audit suite (see `tests/v2/*.md` on `docs/write-v2.0-audit-suite`). Same evidence standard: reproducers, numbers, logs.
4. **A decision memo** (`reports/decision-<date>.md`) — keep v2.0 / adopt Mem0 / escalate to Letta / buy Mem0 Platform — with the trigger each branch requires.

No code merges to `main` from this branch until the readout is reviewed.

---

## Scope — what to prototype

Hermes today expects a memory system to do seven things. Prototype the first four end-to-end; stub the rest and measure quality on real traffic shape.

### Must demonstrate
1. **Auto-capture of conversation turns.** Mem0's `m.add(messages=[...], user_id=<agent>, run_id=<session>)` does LLM-based fact extraction + exact-hash dedup + semantic-similarity consolidation automatically. Wire it into the Hermes `MemoryProvider` `add_turn` hook.
2. **Hybrid retrieval.** Mem0's `m.search(query, user_id=<agent>, limit=...)` returns ranked facts. Compare against v2.0's tier1/tier2/tier3 retrieval on a fixed 50-query set drawn from real Hermes research-agent traffic (see `~/.hermes/memos-state-research-agent/memos-local/memos.db` for shape — do NOT mutate; snapshot to `/tmp/mem0-spike/`).
3. **Per-agent isolation.** Hermes has CEO + 4 workers. Mem0's `user_id` / `agent_id` / `run_id` trinity should map to `ceo` / `<worker-name>` / `<session-id>`. Prove that agent A cannot see agent B's memory unless explicitly shared via `m.get_all(user_id=..., agent_id=...)` with both IDs set.
4. **Local-only operation.** Zero API keys, zero cloud. Stack: Ollama (llama3.1:8b + nomic-embed-text) + SQLite history DB + local Qdrant (on-disk at `/tmp/mem0-spike/qdrant`) or Chroma (directory-only) as the vector store.

### Stub + measure
5. **Skill evolution.** Mem0 has no first-party SKILL.md generation. For the spike: write a simple cron-style job (`scripts/crystallize_skills.py`) that reads Mem0's consolidated memories every N turns, passes any high-support cluster to a DeepSeek-backed prompt, and drops `SKILL.md` under `~/Coding/badass-skills/auto/`. Measure output quality on 5 real agent transcripts — adequate for the A/B, not a full replacement for Reflect2Evolve.
6. **Cross-agent sharing / hub.** Not in scope for the 5-day spike. Note Mem0's `m.get_all(user_id="shared")` pattern in the report.
7. **Task summarization.** Mem0's consolidation does implicit summarization. Do NOT write a separate summariser. Measure whether consolidation output is adequate on a sample of 10 multi-turn sessions.

---

## Architecture — the adapter layer is the deliverable

The prototype code is throwaway. The **adapter layer** survives whatever we decide — even if we keep v2.0, the abstraction makes future swaps cheap.

Build a thin Python package inside this worktree:

```
hermes_lib/memory_backend/
├── __init__.py
├── base.py            # abstract MemoryBackend: add_turn, search, get_all, forget, summarise
├── mem0_backend.py    # concrete: wraps mem0.Memory with the Hermes translations
├── v2_backend.py      # concrete: wraps the v2.0 plugin's bridge (stdio JSON-RPC)
├── factory.py         # picks backend from config; default = mem0
└── README.md          # boundary + swap recipe
```

The interface names must match whatever Hermes's existing `MemoryProvider` hook actually wants (read `/home/openclaw/Coding/Hermes/hermes_lib.py` or the `adapters/hermes/memos_provider/` tree for shape). Do NOT invent a new protocol — align to the existing one so a Mem0 prototype runs against real Hermes unchanged.

Decisions to record explicitly in `hermes_lib/memory_backend/README.md`:
- What Mem0's `user_id` / `agent_id` / `run_id` map to in Hermes terms, and why.
- Which Hermes behaviours the abstraction *cannot* express (e.g. v2.0's L3 world-model abstraction has no Mem0 equivalent — surface this as a `NotImplementedError` with a link to the Letta/v2.0 path).
- The exact boundary at which we'd switch from Mem0 OSS to Mem0 Platform (config key, not a code change).

---

## Prerequisites on the host

```bash
# Ollama models (if not already present)
ollama pull llama3.1:8b            # Mem0 default LLM
ollama pull nomic-embed-text        # Mem0 default embedder

# Python deps (venv inside this worktree)
python3 -m venv .venv
. .venv/bin/activate
pip install 'mem0ai[all]' 'qdrant-client' httpx pydantic pytest

# Spike data dir (everything lives here; deleted at end of spike)
mkdir -p /tmp/mem0-spike/{qdrant,history,logs}
```

Keep the spike's state outside `~/.hermes` and `~/.openclaw` so it cannot accidentally contaminate production profiles.

---

## A/B evaluation harness

The readout must compare Mem0 against v2.0 on Hermes-realistic traffic, not synthetic Q&A. Required harness:

1. **Corpus.** Snapshot ~2,000 turns from the research-agent profile (read-only: `sqlite3 ~/.hermes/memos-state-research-agent/memos-local/memos.db '.dump chunks'` → `/tmp/mem0-spike/corpus.sql`). Do NOT write back.
2. **Queries.** 50 queries drawn from the last 7 days of actual research-agent prompts (extract from `api_logs`). Categorise: exact-keyword (15), semantic (20), multi-hop (15).
3. **Metrics.** Per backend, per query category:
   - P50 / P95 / P99 retrieval latency (wall clock)
   - Recall@5 against a human-labelled gold set (label once, share between backends)
   - Token cost per retrieval (Mem0's claimed advantage)
   - Memory footprint RSS under the full corpus
4. **Honesty constraint.** Use the **same LLM** for both backends' fact extraction / summarization (DeepSeek V3 or local llama3.1:8b — pick one, state it). Retrieval-quality deltas must be attributable to the memory engine, not the LLM.
5. **Hermes-shape stress.** Replay 50 concurrent turns through each backend. Measure whether either hits the event-loop starvation failure mode v1.0.3 had (v1 score: 3/10 on performance; drain rate 40 chunks/s).

Harness script: `scripts/ab_eval.py`. Output: `reports/mem0-vs-v2.0-<date>.md` with the same evidence standard as the audit reports.

---

## What to read before writing code

**Don't skip — spike quality depends on this being grounded, not vibes.**

1. Mem0 OSS quickstart + local setup: `https://docs.mem0.ai/open-source/overview` and `https://docs.mem0.ai/open-source/quickstart`. Pay attention to the **per-operation concurrency limits** and the **history DB semantics** — these drive the A/B design.
2. Mem0's multi-level memory: `user_id` / `agent_id` / `run_id` — the trinity is documented at `/open-source/features/memory-types`.
3. Graph memory is optional and **out of scope** for this spike (requires Neo4j/Memgraph wiring). Note the config key for future reference.
4. v2.0 plugin architecture: `/home/openclaw/Coding/MemOS/apps/memos-local-plugin/ARCHITECTURE.md` on `upstream/main` (in the MemOS fork). This is what we're swapping out — read it so the adapter boundary is honest.
5. Hermes existing provider contract: `adapters/hermes/memos_provider/` on `upstream/main`. Python shape only — the adapter this spike produces must be interchangeable at that boundary.
6. Alternatives scoping doc: `memos-setup/learnings/2026-04-22-memory-alternatives-scope.md` on `docs/memory-alternatives-scope`. The context behind this spike lives there — read §2 (Mem0) and the "Decision framework" tl;dr.
7. The v1.0.3 blind-audit aggregate: `tests/v2/reports/AGGREGATE-VERDICT-2026-04-21.md` on `tests/v2-audit-reports-2026-04-21`. Understand what failed so the A/B captures whether Mem0 regresses on the same axes.

---

## Invariants

- **Local-first is non-negotiable.** If Mem0 refuses to run without a cloud key in any codepath this spike touches, that is itself a finding — write it up and do not work around it by supplying a key.
- **No production contamination.** Spike state lives in `/tmp/mem0-spike/` and this worktree. If you need to probe real Hermes DBs, snapshot read-only.
- **No commits to `main` from this branch.** PR review gate.
- **Evidence discipline.** A/B numbers without reproducer scripts don't count. Same rule as the v2.0 audit suite.
- **Timebox.** 3-5 days. Day 6 is a report, day 7 is buffer. Past day 7, stop and escalate — the question becomes "do we need Letta?" not "can we get Mem0 to work?"

---

## Deliverables at end of spike

Commit to `spike/mem0-prototype`:

1. `hermes_lib/memory_backend/` — the adapter layer (core deliverable, survives the spike).
2. `scripts/ab_eval.py` + the gold query set — the harness.
3. `scripts/crystallize_skills.py` — the stub skill-evolution job.
4. `reports/mem0-vs-v2.0-<YYYY-MM-DD>.md` — the A/B readout.
5. `reports/decision-<YYYY-MM-DD>.md` — the keep-v2.0 / adopt-Mem0 / escalate-to-Letta / buy-Platform recommendation with the trigger each branch requires.
6. Push the branch. Open a **draft PR** titled `spike(mem0): prototype + A/B readout — DO NOT MERGE` with the readout inlined in the PR body. Human reviews.

Do **not**:
- Merge to main.
- Modify anything in `~/.hermes/` or `~/.openclaw/` beyond read-only snapshots.
- Invent new abstractions in `hermes_lib/` beyond `memory_backend/`.
- Bring in cloud dependencies (except as a documented fallback escape hatch that is disabled by default).

---

## If blocked

Common blockers and the escape hatch:

- **Ollama too slow to keep up with Mem0 extraction:** switch to DeepSeek V3 for fact extraction (same LLM v1.0.3 used), keep Ollama for embeddings. Record the decision.
- **Qdrant local won't start cleanly:** fall back to Chroma (directory-only, pure Python). Mem0 supports it out of the box. Re-run the A/B on Chroma; the vector-store choice is orthogonal to Mem0's capture/consolidation quality.
- **Recall@5 gold labelling takes longer than 1 day:** drop to 20 queries instead of 50, note the smaller sample size in the readout.
- **Mem0 OSS surface is too narrow for Hermes's needs:** that is the signal to escalate to Letta. Write it up and stop — don't hack around missing features.

Escalation path: write a short "found a wall" note in `reports/blocker-<date>.md`, commit, and report back.
