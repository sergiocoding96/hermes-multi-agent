# Decision: collapse two-tier memory to single-tier (MemOS only)

**Date:** 2026-04-28
**Author:** sprint summary captured from Claude Code session
**Status:** Implemented (config flipped on local profiles, holographic plugin tombstoned)

## TL;DR

The system was carrying a two-tier memory architecture by default:

1. **Tier 1 (per-agent, in-process):** `holographic` memory provider plugin — local SQLite + FTS5 + HRR compositional retrieval, owned by `hermes-agent`.
2. **Tier 2 (shared, cross-agent):** MemOS server on `localhost:8001` — Qdrant + Neo4j + SQLite, accessed via the `memos-toolset` plugin's `memos_store` / `memos_search` tools.

Investigation showed Tier 1 was empty in every profile (zero facts in 21 days for `research-agent`, 8 days for `email-marketing`, no DB at all for `arinze`/`mohammed`). The agents have only ever used MemOS. The two-tier design was aspirational, not load-bearing.

After challenging the assumption ("would Tier 1 actually pay for itself if used?"), we concluded:

- **Latency is irrelevant for this workload.** Sessions are LLM- and web-I/O-dominated; ~100ms per memory hit is ~1% overhead, not a bottleneck.
- **Isolation is not a Tier 1 advantage in this deployment.** All agents run as the same OS user (`openclaw`), so filesystem-level isolation buys nothing. MemOS now has credential-based authentication (`agent_auth.py`) with cube-ownership checks (`server_router.py:467`), which is at least as strong.
- **The promotion problem (Tier 1 → Tier 2) is genuinely hard** — it's the bulk of the agentic-memory research literature — and we'd need to solve it without empirical signal about what to promote.
- **Operating two stacks costs more than the marginal benefit** for a solo-operator demo system.
- **Re-introducing a Tier 1 later is cheap.** The plugin code remains in git history; the architecture decision can be revisited if usage patterns demand it.

**Decision: single-tier MemOS architecture. Holographic deprecated and tombstoned.**

## How we got here

**2026-04-27** — `@memtensor/memos-local-plugin` v2 deprecated. v1 MemOS server reinstated as production target. Five v1 fixes shipped across PRs Hermes #14/#15/#16, MemOS #6/#7/#8.

**2026-04-28** — During v2 cleanup investigation, we audited what actually serves agent memory traffic. Found:

- v1 MemOS server (PID 3326100) live on `:8001`, healthy
- `memos-toolset` plugin (`~/.hermes/plugins/memos-toolset/`) symlinked into every profile — provides `memos_store` / `memos_search`
- `holographic` plugin (`~/.hermes/hermes-agent/plugins/memory/holographic/`) selected as `memory.provider:` in 2 of 4 profiles — but every backing SQLite was empty (0 rows in `facts`, `entities`, `fact_entities`, `memory_banks`)
- v2 plugin (`@memtensor/memos-local-plugin`) tombstoned in same session — see [`2026-04-27-v2-deprecated-revert-to-v1.md`](2026-04-27-v2-deprecated-revert-to-v1.md)

The two-tier architecture had never produced a single Tier 1 row in production. Three plausible reasons:

1. Agent SOUL.md files don't reference the `fact_store` / `fact_feedback` tools, only MemOS POSTs.
2. `auto_extract: false` is the holographic default; `on_session_end` extraction never ran.
3. Demo agents run discrete tasks that fit one session; cross-session continuity is handled by MemOS at the org level, not by per-agent local memory.

Conclusion: the design assumed a usage pattern that never materialized.

## What was considered before deciding

We explicitly considered three options:

**A) Leave holographic in place, dormant.** Cost: ~1,800 LOC of unused Python and a config field that lies about what's running. Benefit: zero work, easy to enable later. Rejected because "honest about what's running" matters for a small team.

**B) Remove holographic, single-tier MemOS.** What this doc captures.

**C) Make holographic actually work** — update SOUL.md, enable `auto_extract`, define what belongs in personal vs shared memory. Rejected as premature: there's no production workload to inform what the boundary should be. Adding an architectural tier without an empirical reason is the kind of thing that creates maintenance debt without earning its keep.

**D) Single-tier MemOS with cube scoping (personal cubes per agent).** Effectively a Tier-1-equivalent inside MemOS. Deferred — not necessary now, can be added without re-introducing a second stack if a real workload demands it. The current cubes (`research-cube`, `email-mkt-cube`) are sufficient.

We picked B with explicit room to add D later if needed.

## What changed

### Strategic
- This decision doc
- CLAUDE.md sprint header updated to point here
- CLAUDE.md line 64 fix: stale `"No API-level cube isolation — trust-based via SOUL.md only"` corrected. The merged `agent_auth.py` (PR MemOS #7) gives credential-bound user_id and the `/product/add` handler enforces cube ownership at `server_router.py:467`. Trust-via-SOUL is no longer the only line of defense.

### Profile configs (`~/.hermes/profiles/<agent>/config.yaml`)
- `research-agent`: `provider: holographic` → `provider: ''`
- `email-marketing`: `provider: holographic` → `provider: ''`
- `arinze`, `mohammed`: already `provider: ''`, no change

`memory_enabled: true` retained on all profiles. The hermes-agent built-in memory layer (always-on, per `agent/memory_provider.py:6-9`) continues to work; only the external Tier 1 plugin is removed.

### Filesystem (`~/.hermes/`)
- `~/.hermes/hermes-agent/plugins/memory/holographic/` → tombstoned at `~/.hermes/_holographic-tombstone-2026-04-28/holographic/`
- `~/.hermes/profiles/research-agent/memory_store.db` (64 KB, empty schema) → tombstoned
- `~/.hermes/profiles/email-marketing/memory_store.db` (64 KB, empty schema) → tombstoned
- Tombstone MANIFEST.md documents restore steps

### Git history (`~/.hermes/hermes-agent/plugins/memory/holographic/`)
Untouched. The plugin source remains recoverable from any prior tag. Tombstoning is a runtime cleanup, not a code deletion.

## What did NOT change

- v1 MemOS server (PID 3326100, port 8001) — unchanged
- `memos-toolset` plugin — still active in every profile, still provides `memos_store` / `memos_search`
- Other memory providers in `~/.hermes/hermes-agent/plugins/memory/` (byterover, hindsight, honcho, mem0, openviking, retaindb) — unused but preserved as registry options
- Agent SOUL.md files — they were already MemOS-only in their memory instructions, so no change needed
- MEMOS_API_URL, MEMOS_API_KEY, MEMOS_USER_ID, MEMOS_CUBE_ID in profile `.env` files — unchanged
- Cube structure on the MemOS server (`research-cube`, `email-mkt-cube`, etc.) — unchanged

## How agent memory works after this change

```
┌────────────────────────────────────────────────────────────────────┐
│ At decision time (every turn), the model's prompt contains:         │
│                                                                      │
│ 1. SOUL.md (identity, MemOS write rules)                            │
│ 2. Tool descriptions (incl. memos_search, memos_store)              │
│ 3. Conversation history (this session)                              │
│ 4. Built-in memory's prefetch (always-on, hermes-agent core)        │
│ 5. Latest user message                                              │
│                                                                      │
│ Org context (cross-agent, persistent) comes from MemOS only,        │
│ accessed by explicit memos_search calls — not auto-injected.        │
└────────────────────────────────────────────────────────────────────┘
```

Agents read MemOS when starting a task ("what does the team know about X?") and write MemOS after completing one ("here's what I found"). No second tier.

## Failure modes accepted by this design

1. **MemOS down → agents memory-blind.** No graceful degradation through a local Tier 1. Acceptable given v1 server stability and the operator-driven session model.
2. **MEMRADER (DeepSeek-V3) cost on every memory write.** Including small notes that might not be worth structured extraction. Watch the bill if scaling up agents or sessions; revisit if cost becomes material.
3. **No HRR compositional queries.** Holographic's algebraic `fact_store reason` action is gone. We never used it.

## Rollback path

If we decide later that personal scratch memory is needed:

**Cheap rollback** (re-enable existing holographic):
```bash
mv ~/.hermes/_holographic-tombstone-2026-04-28/holographic \
   ~/.hermes/hermes-agent/plugins/memory/

# In each profile config.yaml, change:
#   provider: ''
# to:
#   provider: holographic
```

**Better rollback** (single-tier with personal cubes — option D from above):
- Provision `research-cube-personal`, `email-mkt-personal` etc. in MemOS
- Add `MEMOS_PERSONAL_CUBE_ID` to each profile `.env`
- Update SOUL.md to write personal scratch to the personal cube
- No code change needed — uses existing memos-toolset

## Verification performed

- v1 server health: `{"status":"healthy","service":"memos","version":"1.0.1"}` (post-tombstone)
- Profile config syntax: `provider: ''` confirmed valid via existing `arinze` / `mohammed` profiles
- Loader behavior with empty provider: `load_memory_provider('')` returns None (existing test coverage in `tests/agent/test_memory_provider.py:547-549`)
- Built-in memory still active: per `agent/memory_provider.py:6-9` docstring — *"Built-in memory is always active as the first provider and cannot be removed"*

## Follow-up flagged but not done

- **`~/.hermes/plugins/memos-toolset/DEPRECATED.md`** — leftover from when v2 migration was planned. The toolset itself is the active path under v1. Worth removing or rewriting in a follow-up.
- **Personal cubes** — `research-cube-personal`, `email-mkt-personal`. Not needed yet, but if usage shows agents are polluting `research-cube` with task-internal scratch that other agents don't care about, this is the natural next step (option D in the rollback section).
- **Cube-ownership audit** — confirmed `server_router.py:467` enforces it for `/product/add`. Audit other write paths (`/product/feedback`, `/chat`, etc.) for the same check in a follow-up PR.

## Cross-references

- Previous direction (v2 deprecated): [`2026-04-27-v2-deprecated-revert-to-v1.md`](2026-04-27-v2-deprecated-revert-to-v1.md)
- Original v2 migration plan (now historical): [`2026-04-20-v2-migration-plan.md`](2026-04-20-v2-migration-plan.md)
- Memory alternatives scope (older context): [`2026-04-22-memory-alternatives-scope.md`](2026-04-22-memory-alternatives-scope.md)
