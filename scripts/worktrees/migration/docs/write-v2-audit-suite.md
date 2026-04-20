# TASK: docs/write-v2-audit-suite — Write the 10 blind-audit prompts for Product 2

## Goal

Produce `tests/v2/` with 10 audit prompt files following the same rigor as the Sprint 1 Product 1 audit suite. The prompts will be pasted into fresh Claude Code Desktop sessions (NOT worktree dev sessions) to produce blind audit reports scoring Product 2's correctness, security, resilience, performance, integrity, observability, and new capabilities.

## Context

The Sprint 1 audit suite lives at `tests/` with 6 audits + a README. Structure and philosophy:

- One audit per fresh Claude Code session (no context)
- Adversarial posture
- Each creates its own test data
- 1-10 score per area with evidence
- Overall score = MIN across audits (not average)

This worktree translates that philosophy to Product 2 (the `@memtensor/memos-local-hermes-plugin` + hub). The architecture is different (SQLite + FTS5 + hub HTTP vs Qdrant+Neo4j+MemOS server) so prompts must be rewritten, not just copy-pasted.

Read `tests/README.md`, `tests/zero-knowledge-audit.md`, `tests/blind-functionality-audit.md`, `tests/blind-resilience-audit.md`, `tests/blind-performance-audit.md`, `tests/blind-data-integrity-audit.md`, `tests/blind-observability-audit.md` before writing anything.

Prerequisite: [Stage 2 integration worktrees](../wire/) have merged. Plugin is installed, hub is running, badass-skills is wired, CEO access exists, Paperclip employees exist. The audits test this integrated system.

## Scope

Create the directory `tests/v2/` with:

- `tests/v2/README.md` — explains the suite (mirrors `tests/README.md` structure)
- 10 audit prompt files, each a standalone `.md` file designed to be pasted into a fresh Claude Code Desktop session

The 10 audits are already identified in the [migration master plan](../../../../memos-setup/learnings/2026-04-20-v2-migration-plan.md). Summary:

| # | File | Category | Replaces/adapts |
|---|------|----------|-----------------|
| 1 | `zero-knowledge-v2.md` | Security | tests/zero-knowledge-audit.md |
| 2 | `functionality-v2.md` | Functionality | tests/blind-functionality-audit.md |
| 3 | `resilience-v2.md` | Resilience | tests/blind-resilience-audit.md |
| 4 | `performance-v2.md` | Performance | tests/blind-performance-audit.md |
| 5 | `data-integrity-v2.md` | Integrity | tests/blind-data-integrity-audit.md |
| 6 | `observability-v2.md` | Observability | tests/blind-observability-audit.md |
| 7 | `auto-capture-v2.md` | NEW — auto-capture correctness | none |
| 8 | `skill-evolution-v2.md` | NEW — skill-generation quality | none |
| 9 | `task-summarization-v2.md` | NEW — task boundary detection + summary fidelity | none |
| 10 | `hub-sharing-v2.md` | NEW — group visibility + cross-agent recall | none |

Also create a `tests/v2/reports/` directory with a `.gitkeep` so blind audit sessions have a destination for their reports.

## Writing guidelines — follow Product 1's structure

Each prompt file must:

1. **Start with a clear header** naming the audit + a paste-target note: *"Paste this into a fresh Claude Code Desktop session at ~/Coding/Hermes."*
2. **Specify the system under test** — paths to plugin code, config files, hub HTTP endpoint, auth token location. Be explicit; the auditor has zero context.
3. **State the auditor's job** in a bold sentence. *"Find every X. Score 1-10 with evidence."*
4. **Instruct on isolation** — create own test data, unique markers, do not reuse prior data, do not read CLAUDE.md / previous test scripts / `/tmp/`.
5. **List the specific probes** to run. Be concrete but not over-prescriptive — the auditor should design its own scripts around the probes.
6. **Require 1-10 scoring per area** with explicit justification (not vibes).
7. **End with a summary table** and overall production-readiness assessment.
8. **Enforce adversarial posture** on the security audit specifically.

Per-audit specifics below.

### 1. zero-knowledge-v2.md (Security)

Focus on plugin + hub's security surface. Probes:

- Hub authentication: token types, allowlist enforcement, rate limiting
- Local SQLite: file permissions, path traversal, encryption at rest (if any)
- Memory capture: accidental capture of secrets (API keys in conversations?)
- Skill generation: malicious skill injection vector — can a conversation manipulate the LLM into producing a SKILL.md that executes arbitrary code?
- Hub pairing flow: can an unauthenticated client pair without admin approval?
- Telemetry: what leaves the machine? (plugin has opt-out telemetry — verify it actually opts out when configured)
- Viewer dashboard: auth, session handling, XSS on stored memory content

### 2. functionality-v2.md (Functionality)

Every claim from the plugin README:

- Auto-capture: does it actually fire on every turn? What's dropped?
- Smart dedup: write the same fact 5 times, how many land?
- Semantic chunking: does it split at paragraph/code block boundaries?
- Hybrid search: FTS5 keyword + vector, RRF fusion — test with queries that favor each and confirm fusion helps
- MMR diversity: write 5 near-duplicate memories + 5 distinct, verify search avoids near-dups
- Recency decay: write a fact today and a contradictory fact tomorrow — newer wins?
- Multi-provider embedding: test local Xenova vs OpenAI-compatible (if configured)

### 3. resilience-v2.md (Resilience)

What fails and how:

- Kill the hub HTTP server mid-request: what does the client see? Reconnect?
- Kill the hub and restart: is data preserved?
- Corrupt the SQLite file: does the client crash or recover?
- Disk full: what happens?
- 100 concurrent writes: any drops? Consistency?
- Malformed LLM response during skill evolution: graceful?
- Plugin process killed mid-capture: is the capture lost or replayed?

### 4. performance-v2.md (Performance)

- Write latency: capture overhead per turn
- Search latency: FTS5 vs vector vs hybrid
- Volume: 500 memories, 2000 memories, search latency degradation
- Concurrent load: when does it saturate?
- Memory footprint: RSS at idle, after 500 writes, after 2000 writes
- Disk usage growth per memory
- Skill evolution time (LLM-bound, but measure the wrapper overhead)
- Hub throughput: queries per second, ceiling

### 5. data-integrity-v2.md (Integrity)

- Local SQLite vs hub SQLite consistency: write locally, verify hub indexed it correctly
- Skill file on disk vs hub index: are they consistent?
- Task summary vs underlying chunks: does the summary accurately reflect its source chunks?
- Dedup correctness: `UPDATE` semantics — when the LLM judges "UPDATE", is the merge correct, losing no information?
- Embedding drift: switch embedding providers, re-index, what changes?
- Soft-delete: when a memory is marked inactive, is it removed from both local and hub indexes?
- Clock skew: timestamps across client-hub interactions
- Fidelity: round-trip numbers, URLs, code, unicode, markdown — what survives exactly?

### 6. observability-v2.md (Observability)

- Client logs: capture events, errors, skill gen — are they informative?
- Hub logs: request logs, rate-limit hits, auth failures
- Memory Viewer dashboard: can an operator diagnose "why didn't my memory land" from the UI alone?
- Health endpoints: hub `/health` — does it verify SQLite access? Embedder reachability?
- Metrics: Prometheus? Counts? Latencies?
- Audit trail: who wrote a memory, when, from which agent?

### 7. auto-capture-v2.md (NEW)

Probe the capture pipeline under many scenarios:

- Every message type captured: user, assistant, tool calls, tool results?
- Consecutive assistant messages — merged or separate?
- System messages / internal state — included or excluded? Should be excluded.
- Tool calls with huge outputs (e.g. 10k char Bash output) — captured in full or truncated?
- Abort mid-conversation (Ctrl-C) — are captured-so-far memories preserved?
- Session crash — same question
- Very long single turn (5000 words) — chunked correctly?
- Multi-language content (English + Spanish + Chinese) — embeddings + captures handle?
- PII-like content — captured or filtered? Document what the plugin does.

### 8. skill-evolution-v2.md (NEW)

Requires a corpus:

- Generate a corpus of 20+ simulated multi-turn conversations with realistic task patterns (e.g., "debug a Python error," "summarize a doc," "write a curl command to X")
- Let the plugin run its skill evolution pipeline over this corpus
- Inspect generated SKILL.md files:
  - Are they coherent — would a human find them useful?
  - Do they capture the RIGHT abstraction (generalized pattern, not overfit to one conversation)?
  - Does version upgrade across similar tasks improve the skill?
  - Are they deduplicated — do 5 similar conversations produce 5 skills or 1 good skill with versions?
  - Are low-quality skills filtered? (Plugin claims a quality filter)
- If the plugin writes to `~/Coding/badass-skills/auto/`, verify file structure matches expectations

### 9. task-summarization-v2.md (NEW)

- Seed a session with N clearly distinct tasks (e.g., "1) research X. 2) write code for Y. 3) summarize Z"). Does the plugin detect 3 task boundaries or 1 or 7?
- Over-split scenario: a single task with natural pauses (user goes idle 10 min mid-task) — does it over-split?
- Under-split scenario: two unrelated tasks in rapid succession with no clear break — does it merge them?
- Quality of structured summaries: Goal, Key Steps, Result, Key Details — are they faithful to the source?
- Detail preservation: URLs, file paths, error messages, code snippets — retained in summary?
- Idle timeout: plugin default is 2 hours. Confirm it works; test a boundary case right at 2h.

### 10. hub-sharing-v2.md (NEW)

- Two clients (research-agent, email-marketing) both in `ceo-team` group
- Write memory with visibility=local on client A → client B can see it? (should be NO)
- Write memory with visibility=group on client A → client B can see it? (should be YES)
- Write memory with visibility=public on client A → a client NOT in the group can see it? (should be YES)
- Pairing flow: add a new client, try to search before pairing — denied? After pairing — allowed?
- Allowlist: remove a client from the group, attempt search — denied?
- Cross-agent search relevance: client B searches for content client A wrote — relevance ranking sane?
- Skill sharing: A generates a skill with visibility=group → B sees it in hub skill listing? Can download it?
- Offline behavior: hub down while client is offline — can client still search local? When hub returns, does it sync back?

## Acceptance criteria

- [ ] `tests/v2/README.md` exists and follows the structure of `tests/README.md` (table of audits, rules, how to run, how to combine reports).
- [ ] All 10 `.md` audit files exist in `tests/v2/`.
- [ ] Each audit:
  - [ ] Starts with "Paste this into a fresh Claude Code Desktop session" note
  - [ ] Clearly specifies the system under test (paths, endpoints, tokens location)
  - [ ] Tells the auditor NOT to read CLAUDE.md, `/tmp/`, existing test scripts, or plan files
  - [ ] Enumerates specific probes
  - [ ] Requires 1-10 scoring per area with justification
  - [ ] Requires a final summary table
- [ ] `tests/v2/reports/.gitkeep` exists so the audit reports have a committed home.
- [ ] Length of each audit prompt: 60-200 lines. Too-short = under-specified. Too-long = unreadable.
- [ ] No prompt instructs the auditor to use information from Sprint 1 reports — each audit is blind.

## Test plan

Peer-review your own prompts by asking: if I knew nothing about this system and pasted this prompt, could I produce a rigorous report? If yes, ship. If no, tighten.

Do NOT actually run the audits in this session — that's Stage 4. Your job is to write the prompts, not execute them.

## Out of scope

- Do not write the audit REPORTS — those come from Stage 4's fresh sessions.
- Do not modify the existing Sprint 1 audits at `tests/`. Leave them as historical reference.
- Do not build any test tooling or runners — the audit sessions write their own scripts.

## Commit / PR

- Branch: as assigned
- PR title: `docs(tests): v2 blind audit suite — 10 prompts for Product 2 validation`
- PR body: list of 10 files created + a summary of what each covers.
