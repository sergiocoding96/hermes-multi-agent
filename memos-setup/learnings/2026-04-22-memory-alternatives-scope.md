# Memory Alternatives Scoping — Hedge Against Product 2

**Date:** 2026-04-22
**Context:** Product 2 (`@memtensor/memos-local-hermes-plugin`) scored 1/10 MIN across a 10-axis blind audit. If Sprint 2 hardening does not raise MIN to ≥ 6, we need a drop-in replacement. This document is the decision input for that choice — not a vendor shootout, not a benchmark paper. Target: pick 1-2 systems to prototype against within the next 2 weeks.

Hermes needs: auto-capture of agent turns, chunking, hybrid retrieval (FTS + vector + rerank), exact + semantic dedup, per-conversation LLM summaries, skill evolution (auto `SKILL.md` generation from patterns), cross-agent sharing with per-agent visibility, local-first (no cloud), multi-agent (CEO + 4 workers on one store). An abstraction layer is already planned, so API shape is a soft constraint.

---

## Comparison Table

| System | License | Local-first | Capture | Chunking | Hybrid retrieval | Summarize | Skill evolution | Sharing | Last release | Stars | Days to prototype |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **Letta** (letta-ai/letta) | Apache-2.0 | Partial (Postgres+Docker req) | Auto | Built-in | Vector + FTS (pgvector) | Yes (recursive) | No (manual blocks) | Yes (shared blocks) | 0.16.7 (2026-03-31) | 22.2k | ~7 |
| **Mem0** (mem0ai/mem0) | Apache-2.0 | Yes (SQLite+Qdrant local) | Auto (`add(messages=…)`) | Auto | Vector + graph, no built-in rerank | Yes (LLM extract+consolidate) | No | Yes (user_id / agent_id / run_id) | openclaw-v1.0.7 (2026-04-20) | 53.8k | **~3-5** |
| **Zep OSS** (getzep/zep) | Apache-2.0 (legacy) | **Deprecated** — community edition moved to `legacy/`, unsupported | — | — | — | — | — | — | zep-crewai-v1.1.1 (2025-09-11) | 4.5k | N/A (do not use) |
| **Cognee** (topoteretes/cognee) | Apache-2.0 | Partial (Neo4j/Postgres or lightweight defaults; KuzuDB + LanceDB local possible) | Manual (`cognee.add()`) | Built-in (ECL pipeline) | Graph + vector | Yes (cognify) | No | Decorator per-agent | v1.0.1 (2026-04-18) | 16.6k | ~10 |
| **Graphiti** (getzep/graphiti) | Apache-2.0 | Partial (Neo4j / FalkorDB / Kuzu required) | Episodes (manual) | Built-in | BM25 + vector + graph traversal | No (temporal facts, not summaries) | No | Per-group | mcp-v1.0.2 (2026-03-11) | 25.2k | ~10 |
| **txtai** (neuml/txtai) | Apache-2.0 | Yes (SQLite + local embeddings) | Manual | Yes | Sparse+dense vector, graph | Yes (pipeline) | No | Manual indexes | v9.7.0 (2026-03-20) | 12.4k | ~8 (build memory layer on top) |
| **LangMem** (langchain-ai/langmem) | MIT | Partial (requires LangGraph store; Postgres or in-memory) | Auto via LangGraph | Yes | Vector | Yes (reflection) | Yes (procedural memory = prompt updates) | Yes (namespaces) | continuous | 1.4k | ~7 (if already on LangGraph) |
| **OMEGA / MemPalace / Engram** | Varies (source-available, some MIT) | Yes (SQLite + ONNX) | Auto | Yes | Hybrid | Yes | Partial | Yes | active 2026 | <2k each | ~5-7 (unknown maturity) |
| **Pinecone Assistant** (commercial) | Proprietary | No (cloud only; BYOC preview on AWS) | Auto | Yes | Hybrid + rerank | Yes | No | Namespaces | SaaS | — | ~3 (but kills local-first) |
| **Weaviate Agents** (commercial+OSS core) | BSD-3 core + proprietary agents | Partial (OSS core local; Agents run on Weaviate Cloud) | Varies | Yes | Hybrid built-in | Personalization agent | No | Multi-tenancy | continuous | 11k+ core | ~5 |

Citations and caveats follow per-candidate.

---

## 1. Letta (formerly MemGPT)

**Maturity:** 22,220 stars, 2,351 forks, 153+ contributors (GitHub contributors-endpoint Link header pagination). 100+ commits in the last 6 months (API-capped, so likely several hundred). Backed by Letta Inc (VC-funded, ex-Berkeley SkyLab). Last release `0.16.7` on 2026-03-31. 79 open issues — low for repo size. Apache-2.0.

**Architecture fit:** Strong on paper — MemGPT-style tiered memory (core / recall / archival), agents manage their own context via tool calls. Auto-captures conversation turns. `memory_insert` / `memory_apply_patch` tools. Supports shared memory blocks across agents (the "CEO sees worker memory" pattern maps cleanly). Built-in LLM summarization (recursive summary of recall memory). Hybrid retrieval is pgvector-backed vector + Postgres FTS; no cross-encoder rerank by default, you'd add that.

**Skill evolution: no first-party feature.** Closest analog is MemFS (git-backed memory filesystem) — agents can write/patch files, which could be coerced into `SKILL.md` generation, but it's not a native concept.

**Local-first:** **Partial.** Requires Postgres + pgvector, runs under Docker. No SQLite path. Optional E2B sandbox for tool exec, optional Git sidecar. LLM can be Ollama (fully local model) but the server stack is heavier than "one SQLite file." This is the main friction point for Hermes.

**Benchmarks:** Letta's own blog reports **Letta Filesystem = 74.0% on LoCoMo** (GPT-4o-mini) vs "Mem0 graph 68.5%". Third-party 2026 leaderboards place Letta in the 74-78% LoCoMo band. No first-party LongMemEval numbers.

**Migration cost:** ~7 days. Concepts map well to Hermes (CEO + workers = agents with shared blocks). Main work: Postgres provisioning, wiring the summarization hook, adding a rerank stage. MiniMax / DeepSeek / Ollama are all supported via the LLM provider abstraction.

**Risks:** Postgres dependency breaks "SQLite-preferred" constraint. VC-backed company — roadmap is visibly cloud-forward (Letta Cloud is the commercial story). The OSS server is a deliberate on-prem offering, but long-term incentives favor the cloud. Large surface area — you inherit their whole agent runtime, not just a memory lib.

---

## 2. Mem0

**Maturity:** 53,784 stars (largest in the category), 6,035 forks, 305+ contributors, 100+ commits in the last 6 months (API-capped), 224 open issues. `openclaw-v1.0.7` released 2026-04-20 — **actively releasing this week**. Apache-2.0. Mem0 Inc (VC-backed, Y Combinator).

**Architecture fit:** Best out-of-box fit for Hermes's capture + dedup + summarization triad. `m.add(messages=[…], user_id=…, agent_id=…, run_id=…)` does auto-extraction, chunking, LLM-based fact extraction, smart dedup (both exact via hashing and semantic via similarity threshold), and consolidation (merging/updating old memories with new). `m.search(query, user_id=…)` returns ranked results. Multi-level memory: User, Session, Agent — maps 1:1 to Hermes CEO + 4 workers.

**Skill evolution: no first-party feature.** Mem0 stores extracted facts, not reusable procedures. You'd build `SKILL.md` generation as a separate job that reads from Mem0 periodically.

**Local-first:** **Yes, genuinely.** OSS defaults create files at `~/.mem0/vector_store.db` (SQLite-backed embeddings) and `~/.mem0/history.db` (SQLite). Default vector store is local Qdrant on disk at `/tmp/qdrant`, but Chroma (directory-only) is a drop-in. Ollama for both LLM (llama3.1:8b) and embeddings (nomic-embed-text) is documented — zero API keys, zero cloud.

**Benchmarks:** Mem0's own site reports **91.6% on LoCoMo** using ~6,950 tokens per retrieval call (vs 25,000+ for full-context baselines, ~3-4× token savings). Earlier third-party reproductions put Mem0 at ~66.9% with 0.71s median / 1.44s p95 latency — the delta is the new token-efficient algorithm. Zep's published rebuttal claims **Zep 75.14% vs Mem0 ~66%** on a corrected harness; Mem0's rebuttal claims the opposite. Both sides contest methodology. Honest read: Mem0 sits somewhere in the 65-91% LoCoMo band depending on config, comparable to Zep within error bars. No published LongMemEval numbers from Mem0.

**Migration cost:** ~3-5 days. Smallest surface area among serious candidates. Python SDK + REST server, both trivial to wire to Hermes's abstraction layer. No schema migration needed — Mem0 owns its storage, you talk to it via `add()`/`search()`.

**Risks:** (1) Commercial tier is where the flagship features live — Mem0 Platform has webhooks, memory export, dashboard, analytics, custom categories; OSS lacks those. Not blockers for Hermes's current use case, but a signal about where the roadmap flows. (2) Graph memory in OSS is "self-configured" — needs Neo4j/Memgraph wiring if you want the graph features, which Mem0 markets heavily. Without it, you have vector memory + extraction only (still plenty for Hermes). (3) `gpt-5-mini` is the default LLM; swapping to DeepSeek/Ollama is documented but adds config complexity. (4) No cross-encoder rerank by default — if retrieval quality disappoints, you'd bolt on your own reranker.

---

## 3. Zep (OSS) — **Do Not Use**

**Status:** `getzep/zep` README explicitly states *"Zep Community Edition is no longer supported and has been deprecated. The Community Edition code has been moved to the `legacy/` folder."* 36 commits last 6mo, mostly examples/integrations for Zep Cloud. Last meaningful OSS release was 2025-09. 17 contributors total.

**Decision:** Rule out. This is an abandoned-upstream risk — any bug you hit lives with you forever. The Zep team is all-in on the cloud product.

**Note:** Graphiti (same org, actively maintained) is the viable Zep-org option. See below.

---

## 4. Cognee

**Maturity:** 16,618 stars, 1,717 forks, 146+ contributors, 100+ commits in last 6 months (actively shipping — dev releases every few days, `v1.0.1.dev4` on 2026-04-21). 85 open issues. Apache-2.0. Backed by topoteretes (startup, Polish team).

**Architecture fit:** Knowledge-engine framing rather than conversation-memory framing. ECL pipeline (Extract-Cognify-Load) ingests docs → builds knowledge graph → retrieves via graph + vector hybrid. Four primitives: `remember`, `recall`, `forget`, `improve`. Ingestion is **manual** (`cognee.add(text)` then `cognee.cognify()`), not auto-capture of conversation turns — you'd wrap your own turn-capture hook. Has session memory cache + background graph sync. No first-party conversation summarization, no skill-evolution concept.

**Local-first:** **Partial but flexible.** Docs say "ships with lightweight defaults that run locally" and third-party writeups confirm it can run with KuzuDB (embedded graph) + LanceDB (embedded vector) + SQLite. Production path assumes Neo4j + Postgres + Qdrant/Weaviate. Cognee Cloud exists but is optional.

**Benchmarks:** Cognee markets graph-based retrieval for enterprise data. No LoCoMo/LongMemEval numbers I can find from Cognee directly. Third-party 2026 comparison articles include it among "vector + graph" systems but do not cite head-to-head numbers.

**Migration cost:** ~10 days. You'd be re-framing Hermes turns as "documents," wiring a capture hook, and taking on a heavier graph-DB dependency than you currently have with MemOS. The ECL pipeline is powerful but opinionated — more to learn, more to misconfigure.

**Risks:** Aimed at knowledge-graph-for-docs use cases; Hermes's chat-turn/skill workflow is a sidegrade, not the happy path. Roadmap velocity is high (daily dev releases) which cuts both ways — active development, but API churn risk. No public benchmark positioning you can quote to stakeholders.

---

## 5. Graphiti (Zep org, OSS, maintained)

**Maturity:** 25,246 stars, 2,506 forks, 40+ contributors, 100+ commits last 6mo (API-capped — very active). 361 open issues (high, suggests fast-moving issue intake outstripping triage). Last release `mcp-v1.0.2` on 2026-03-11. Apache-2.0.

**Architecture fit:** Temporal knowledge graph — every fact has a validity window (when it became true, when superseded). Episode provenance: every entity traces back to source. Hybrid retrieval = BM25 + semantic embedding + graph traversal (no LLM-in-the-loop at query time). No built-in conversation management ("build your own user/message infra"). No native summarization (facts, not summaries). No skill evolution.

**Local-first:** **Partial.** Requires a graph DB — Neo4j, FalkorDB, Kuzu, or Neptune. Kuzu is embedded/single-file which is the closest to local-first. No SQLite path.

**Benchmarks:** Zep's LoCoMo numbers (75.14% contested) are built on Graphiti's architecture, so effectively the strongest third-party-validated number in this document maps to Graphiti. Zep's published LongMemEval paper uses the same engine.

**Migration cost:** ~10 days. Heavier conceptual load — you buy into the temporal-KG worldview, which is a different shape than MemOS's chunked-text-with-metadata. If Hermes wants "what does the CEO believe about this user/project right now and when did that change" the fit is excellent. If it mostly wants "give me relevant chunks," Graphiti is overkill.

**Risks:** Same parent org as deprecated Zep OSS — but Graphiti is where the getzep team's current energy goes, and it's the engine behind their commercial product. That's a double-edged sword: it will be maintained, but features are driven by Zep Cloud's needs. Building conversation capture + summarization on top is real work.

---

## 6. txtai

**Maturity:** 12,413 stars, 802 forks, 23+ contributors (smallest of the group — essentially a single maintainer, David Mezzetti / NeuML). 100+ commits last 6mo (API-capped). **6 open issues — remarkably low**, signals disciplined maintenance. Last release `v9.7.0` on 2026-03-20. Apache-2.0. Funded by NeuML (bootstrapped consultancy).

**Architecture fit:** Not an agent memory system — it's a search + LLM orchestration framework. You'd use it as a hybrid-search primitive and build the memory layer on top. Has embeddings (sparse + dense), graph networks, summarization pipelines, and agent/workflow abstractions. No auto-capture of conversation turns. No skill evolution.

**Local-first:** **Yes.** Pure Python + SQLite + local transformer models. No services required. This is the most truly-local-first option in the list.

**Benchmarks:** No LoCoMo/LongMemEval numbers — not marketed as a memory system.

**Migration cost:** ~8 days. You'd be building Hermes's memory layer yourself on top of txtai's hybrid search. Upside: total control, zero opinions imposed. Downside: you're rebuilding capture, dedup, summarization, skill evolution — which is most of what we're trying to outsource.

**Risks:** Single maintainer (bus factor). If you want a battery-included memory system, this is not it. If you want the cleanest hybrid-search primitive to build on, it's arguably the best pick.

---

## 7. LangMem (LangChain team)

**Maturity:** 1,409 stars, MIT, 55 open issues, actively maintained (last push 2026-04-21). Smaller community than the others but backed by LangChain Inc, which has commercial scale.

**Architecture fit:** SDK over LangGraph's store. Primitives for episodic memory (past interactions as few-shot examples) and procedural memory (instructions that update the agent's prompt). **Procedural memory is the closest match to Hermes's "skill evolution" requirement in the entire field** — LangMem provides `metaprompt`, `gradient`, and `prompt_memory` algorithms that rewrite agent instructions from conversation patterns. Reflection-based summarization is built in. Auto-capture works if you're on LangGraph.

**Local-first:** **Partial.** Requires a LangGraph store — in-memory (non-persistent), Postgres, or vector DB. SQLite via LangGraph's SQLite checkpointer is possible but documented less.

**Benchmarks:** One third-party number: **p95 search latency of 59.82 seconds** — this is flagged as a disqualifier for real-time agents. No LoCoMo score published.

**Migration cost:** ~7 days if Hermes adopts LangGraph, **15+ days if not**. Hermes is not currently on LangGraph, so adoption is the real cost — buying into an orchestration framework, not just a memory lib.

**Risks:** (1) The 60s p95 search latency, if reproducible, makes it a non-starter for CEO→worker routing. (2) Couples Hermes to LangGraph's lifecycle. (3) Only candidate with real procedural-memory / skill-evolution story, though.

---

## 8. Lightweight SQLite-first systems: OMEGA, MemPalace, Engram

A cluster of small, recent projects targeting the exact gap Hermes sits in (local-first, SQLite, zero-dependency). Stars typically <2k each; maturity signals are weaker than the big four.

- **OMEGA** — SQLite + ONNX local embeddings, no Docker, no Neo4j. Self-reports **95.4% on LongMemEval at 50ms retrieval**. Vendor-reported; no independent reproduction found.
- **MemPalace** — MIT, local-first, 19 MCP tools, self-reports **96.6% on LongMemEval**. Vendor-reported.
- **Engram** — 80.0% LoCoMo with 96.6% fewer tokens vs full-context.

**Risk:** all three are vendor-benchmarked, small-community, <1 year old. Zero third-party validation. Could be excellent or could be abandoned in 6 months. **Not recommended as primary**, but worth 1 day of prototyping if Mem0 fails and you want a SQLite-native option with even smaller footprint.

---

## 9. Commercial fallbacks

**Pinecone Assistant:** Billed $0.05/assistant-hour + $5/1M context-processed tokens + $3.60/GB/mo storage + $50-150/mo capacity. Independent analysis puts a 10-agent / 10M-vector system at **$99-199/mo calculated, 3-5× that in production** due to write-unit saturation on agent workloads. BYOC on AWS is in preview. Violates local-first hard constraint.

**Weaviate Agents:** Weaviate OSS core is BSD-3 and runs locally. Agents (including Query Agent, Personalization Agent) are Weaviate Cloud features — **not available self-hosted**. Cloud starts $45/mo Flex, $280/mo Plus, $400/mo Premium. If you adopt Weaviate OSS as the store, you build the memory layer yourself on top (similar shape to the txtai path).

**Mem0 Platform:** Paid tier of the same product — graph memory managed, dashboard, webhooks, analytics. $249/mo Pro for graph. Useful as "if OSS retrieval quality is close enough we stay OSS; if we need the graph polish we upgrade without switching vendors."

---

## Notes on benchmarks

LoCoMo and LongMemEval numbers are **heavily contested** and **vendor-published**. Two independent observations:

1. Zep vs Mem0 publicly accuse each other of methodology errors. Zep corrected its own 84% down to 75.14%; Mem0 claims Zep actually gets 58-66% on a different harness. Every system currently publishes a number in the 74-92% LoCoMo band using cloud LLMs. The differences within that band are smaller than the differences caused by LLM choice.
2. The `xiaowu0162/LongMemEval` repo and ICLR 2025 paper provide the only neutral harness. Vendor numbers not reproduced against it should be treated as marketing.

**Don't pick based on the benchmark number. Pick based on architecture fit + deployment friction + upstream health.**

---

## Recommendations

### 1. If Product 2 hardening fails → **Mem0 OSS**

It's the closest match to Hermes's requirements out of the box, the biggest community (53k stars, 305 contributors, weekly releases), genuinely local-first with SQLite + local Qdrant + Ollama, and has the lowest prototype cost (3-5 days). It does auto-capture (`add(messages=...)`), LLM extraction, semantic + exact dedup, and consolidation — which is 60-70% of what Product 2 was supposed to do. You give up: first-party skill evolution (build as a cron job that reads Mem0 and emits `SKILL.md`), and cross-encoder rerank (add separately if retrieval disappoints). Upgrade path to paid Mem0 Platform exists if OSS limitations bite.

**Trigger to start:** Product 2 MIN audit < 6 after one more hardening sprint.

### 2. Second choice → **Letta**

If Mem0's retrieval quality turns out weaker than Product 2 in A/B, Letta is the stronger architectural fit for the multi-agent shape (CEO + workers as a ring of Letta agents with shared memory blocks). Apache-2.0, 22k stars, VC-backed but on-prem-friendly, best first-party support for "agent manages its own memory" which plays well with the hard-loop auto-patch idea. Cost: Postgres dependency breaks the "one SQLite file" ideal, and surface area is much larger (you adopt an agent runtime, not just a memory lib). Prototype ~7 days.

**Trigger to start:** Mem0 prototype shows retrieval gaps that require the tiered core/recall/archival structure to fix.

### 3. Commercial fallback → **Mem0 Platform ($249/mo Pro tier)**

Same SDK as OSS. If retrieval quality or graph features become load-bearing and you don't want to operate Neo4j yourself, flip the config. Roughly **$3k/year** — tolerable for a small team, covers dashboard + webhooks + managed graph memory + analytics. The migration surface is essentially a config change because you stayed inside the Mem0 abstraction. Use this if headcount time is the binding constraint, not cash.

Alternative commercial fallback: **Pinecone Assistant** at est. **$300-1000/mo** for Hermes scale — better rerank, but violates local-first and has known write-heavy pricing pathologies for agent workloads. Only choose if you abandon local-first entirely.

---

## Out of scope but noted

- **Graphiti** is the right answer if Hermes pivots to temporal-reasoning-heavy use cases (who said what when, across sessions). Not a drop-in for chunked-text memory, but keep it in the back pocket for a future sprint that needs "when did the CEO last believe X" queries.
- **LangMem's procedural memory** is the only off-the-shelf implementation of skill-evolution-as-prompt-rewriting. If skill evolution becomes the thing that's actually hard, lift that algorithm out of LangMem regardless of which memory store you use underneath.
- **OMEGA / MemPalace** deserve 1 day of spike-prototyping as contingency — they're SQLite-native and vendor-benchmark well on LongMemEval. Don't bet the project on them without independent reproduction.

---

## Decision framework (tl;dr)

| If… | Then… |
|---|---|
| Product 2 MIN ≥ 6 after hardening | Keep Product 2. This doc goes in the drawer. |
| Product 2 MIN < 6 and retrieval quality is the issue | Prototype Mem0 OSS for 5 days. Compare A/B on a Hermes-realistic eval. |
| Mem0 ships, quality is good, skill evolution is the remaining gap | Build skill-evolution as a job on top of Mem0. Or lift LangMem's procedural memory algorithm. |
| Mem0 retrieval quality is weaker than needed | Prototype Letta in a second 7-day spike. |
| Headcount is the binding constraint | Upgrade to Mem0 Platform Pro ($249/mo) and move on. |
| Local-first is abandoned | Pinecone Assistant — but this is a strategy pivot, not a memory-system choice. |

---

## Sources

- GitHub API (repos endpoint, commits endpoint, contributors Link header pagination) for all OSS maturity signals — retrieved 2026-04-22.
- Letta self-hosting docs (Postgres + pgvector requirement, Docker, optional E2B/Git sidecars).
- Letta blog, "Benchmarking AI Agent Memory: Is a Filesystem All You Need?" — Letta Filesystem 74% LoCoMo.
- Mem0 docs: `/platform/platform-vs-oss`, `/open-source/overview`, Qdrant integration page — SQLite history DB, local Qdrant, Ollama path.
- Mem0 research page — 91.6% LoCoMo, 6,950 mean tokens per call.
- `blog.getzep.com` — "Lies, Damn Lies, Statistics: Is Mem0 Really SOTA?" — Zep 75.14% ±0.17, Mem0 best config ~66%; disputed methodology.
- `getzep/zep` README — Community Edition deprecated, code moved to `legacy/`.
- Graphiti README — Neo4j/FalkorDB/Kuzu/Neptune backends; BM25 + vector + graph hybrid.
- `docs.cognee.ai/core-concepts` — ECL pipeline, `remember/recall/forget/improve`, lightweight local defaults.
- `neuml.github.io/txtai` — hybrid sparse/dense, summarization pipeline, agent primitives.
- LangMem docs and `blog.langchain.com/langmem-sdk-launch/` — metaprompt/gradient/prompt_memory algorithms; LangGraph store dependency.
- 2026 comparison articles (vectorize.io, atlan.com, machinelearningmastery.com, dev.to) — used for triangulation only, not as primary evidence.
- Pinecone docs + costbench.com — Assistant pricing $0.05/hr + $5/1M tokens + $3.60/GB.
- Weaviate Cloud pricing page — Flex $45, Plus $280, Premium $400/mo.
- `xiaowu0162/LongMemEval` (ICLR 2025) — neutral benchmark harness.

**Information gaps noted in the text** where no independent source exists (OMEGA/MemPalace/Engram vendor-only benchmarks; Cognee has no published LoCoMo; Graphiti summarization/conversation features require building your own layer).
