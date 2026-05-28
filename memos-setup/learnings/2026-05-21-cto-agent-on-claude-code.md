# 2026-05-21 — CTO agent on Claude Code + dirty-episode boot fix

## Decision

Introduce a **CTO agent that runs on Claude Code** (not Hermes), living in its
own repo at `~/Coding/Hermes-CTO`. It owns the team's technical stack: advises
the operator, **delegates to** the Hermes specialist agents, and **is callable
by** them. It shares the team brain via the v2 memory plugin as a new `cto`
profile.

This **partially reintroduces cross-agent interaction**, which the
2026-05-17 v2-only decision retired along with the CEO/Paperclip layer. The
distinction: there is still **no central orchestrator and no cross-machine
routing**. The CTO is a peer technical lead that uses the same local invocation
primitives any operator could use — it does not own or schedule the agents.

## Why

The operator wants a single, memory-backed technical authority that (a) carries
team context across sessions, (b) can fan work out to the specialist agents, and
(c) can be consulted by those agents for technical decisions — all on the
Claude Code runtime they already drive.

## Architecture

- **Memory link:** the HTTP API on `:18800` is password-gated, so the CTO talks
  to the v2 plugin over the **unauthenticated stdio bridge** as profile `cto`.
  A small loopback daemon (`mcp/cto_mem_daemon.py`, `127.0.0.1:18810`) owns ONE
  bridge; the MCP server (`mcp/cto_memory_mcp.py`) and the auto-capture hooks
  share it via `mcp/cto_mem_client.py`. Profile `cto` is created implicitly on
  first write. Reads automatically include the shared `world_model` + `skills`
  (`share_scope=local`); writes stay `private` to `cto`.
- **Memory tools (MCP):** `memory_search`, `memory_note`, `memory_record_turn`.
- **Auto-capture (hooks):** `UserPromptSubmit` → recall + inject; `Stop` →
  capture the exchange. Both are best-effort and never block the prompt on a
  cold bridge boot (warm-in-background, act-when-warm).
- **CTO → agent:** `scripts/delegate-agent.sh <agent> "<task>"` wraps
  `hermes --profile <agent> -z`; durable handoffs use `hermes kanban`.
- **agent → CTO:** `scripts/ask-cto.sh "<question>"` runs the CTO headlessly via
  `claude -p` from the CTO project dir (so its CLAUDE.md + MCP + hooks load).
- **Form:** standalone persona — `~/Coding/Hermes-CTO/CLAUDE.md` is the charter.

## Side fix: dirty-episode boot stall (root cause from the 2026-05-21 RAM incident)

While wiring the bridge we hit the same boot stall that caused the earlier
process leak: every cold bridge boot re-ran reflection on **7 permanently-dirty
closed episodes** (`rTask=null`, finalized, with traces) whose reflection LLM
calls fail (malformed JSON / provider timeout), so they never clear. We marked
them with the recognised clean-state `meta.reward = {skipped: true}` (and cleared
any `rewardDirty`), which makes `episodeRewardIsDirty` (`core/pipeline/memory-core.ts:972`)
return false. Raw traces preserved; backup at
`~/.hermes/memos-plugin/dirty-episodes-backup-2026-05-21.json`. Cold boots now
complete in seconds for every agent.

## Open follow-ups

- The reflection LLM (MiniMax) still emits malformed JSON for some episodes —
  fix the JSON-parse resilience so future episodes don't get stuck.
- The keepalive-timeout patch from 2026-05-21 (`__init__.py` 10s→90s) and this
  CTO bridge client both live on the installed plugin/adapter under `~/.hermes`
  and are not yet tracked in `tools/plugin-patches/`. Make durable before any
  plugin reinstall.

## Related

- [[2026-05-17-v2-only-bge-shares]] — the v2-only decision this extends.
- 2026-05-21 RAM incident (keepalive timeout fix) — same dirty-episode root cause.
