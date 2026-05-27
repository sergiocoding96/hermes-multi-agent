# Hermes Multi-Agent Research System

## 🚨 Active sprint — read this first

**Memory architecture: v2 `@memtensor/memos-local-plugin` only. Paperclip + CEO orchestration retired 2026-05-17. v1 MemOS server stopped + disabled — kept on disk for rollback only.**

**2026-05-27 — durable fixes landed + memory-quality overhaul + roadmap.** The 05-26 "STILL PENDING" items are **done**: idempotency guard (`traces_idempotent_turn` BEFORE INSERT trigger — duplicate `(episode_id,turn_id)` inserts silently dropped), bridge `session.open` timeout 30→120s, the dangerous `pkill -f 'bridge\.cts'` band-aids replaced by `scripts/lib-bridge-safe-cleanup.sh` (never kills the `:18800` daemon), and the `:18800` daemon promoted to `hermes-memos-daemon.service` (systemd, Restart=always). Plus a memory-quality overhaul (now **22 patches**): failure-avoidance L2 induction, world-model embedding-merge dedup, error-outcome reward penalty, skill crystallization bar (minSupport 1→3) + usage-on-retrieval tracking; DB deduped 95,174→~324 real traces + VACUUM. Viewer: login routing fix, console-error fixes, map memories-toggle + reward-heat + bubble drill-down. **Remaining work is phased in the roadmap** ([`memos-setup/learnings/2026-05-27-memory-roadmap.md`](memos-setup/learnings/2026-05-27-memory-roadmap.md)): Phase 1 stability (background boot-reflection, serialize bridge boots, auto-prune skills), Phase 2 feedback loop (per-step verifier, implicit human signal), Phase 3 shared single daemon. **Standing process:** every memory change now updates the comprehensive report — edit `docs/architecture/2026-05-27-memory-comprehensive-report-deck.html`, run `tools/build-memory-report.sh`, commit, refresh the Drive Doc.

**2026-05-26 — capture outage RCA + recovery; extraction LLM is DeepSeek (not Gemini). ⚠️ one durable fix still pending.** Memory *looked* reset but nothing was deleted — the v2 store simply only goes back to its birth on 2026-05-12, and capture had stalled. Two root causes found & the acute damage repaired: (1) a runaway arinze capture loop wrote **65,741 trace rows for 6 real turns** (timed-out `subagent.record` re-inserting non-idempotently; cost was trivial ~$0.01, the damage was DB bloat) — **purged** (95,174→27,927 traces, FTS rebuilt, backup `memos.db.bak-20260526-061139`); (2) each gateway bridge cold-loads BGE-large, and concurrent boots starve the CPU past the bridge `session.open` timeout → respawn → **process-leak/CPU death-spiral** (29 leaked `bridge.cts`). Stopped the spiral and restarted gateways **staggered** (load 7.93→0.57, bridges stable, daemon healthy). **STILL PENDING (needs a decision):** the durable bridge-concurrency fix (raise timeouts / serialize boots / make gateways thin clients of one daemon), idempotent capture retry, and neutralizing the dangerous `pkill -f 'bridge\.cts'` band-aid scripts. Also: extraction + skillEvolver LLMs were **reverted Gemini → DeepSeek on 2026-05-25** (account refunded). Decision doc: [`memos-setup/learnings/2026-05-26-capture-outage-rca-recovery.md`](memos-setup/learnings/2026-05-26-capture-outage-rca-recovery.md).

**2026-05-24 — memory extraction LLM switched DeepSeek → Gemini 2.5 Flash-Lite; tower resource cleanup.** *(Superseded 2026-05-25: reverted to DeepSeek — see the 2026-05-26 entry above.)* DeepSeek hit $0 balance → every memory call `402`'d, the boot-time rescore looped on retries (584 failed calls), blocked the daemon's `server.started`, and was the high memos CPU under investigation. Switched the plugin `llm:` block to `gemini-2.5-flash-lite` via the AI Studio free tier (no `<think>` pollution — Gemini reasoning is separate metadata, not inline). Same session: stopped retired v1 MemOS containers (`neo4j-docker`, `qdrant`) and orphaned Camoufox, stopped the idle Firecrawl stack, and added an on-demand Firecrawl wrapper (`tools/firecrawl-ctl.sh` + `firecrawl-idle-monitor.timer`). RAM free 189 MiB → ~10 GiB, load 83 → ~1. Decision doc: [`memos-setup/learnings/2026-05-24-deepseek-402-gemini-switch.md`](memos-setup/learnings/2026-05-24-deepseek-402-gemini-switch.md).

**2026-05-25 — boot-hang follow-up RESOLVED: bounded capture-pipeline LLM calls.** The "oversized boot-backlog batches" follow-up previously flagged here is fixed durably. The batched reflection scorer now chunks a closed episode into `≤ batchThreshold`-step calls (`scoreBatchChunk` in `core/capture/capture.ts`), caps the per-step `tool_calls` array at 24 with a hard `maxTokens` (4096) on the response (`core/capture/batch-scorer.ts`), and the reflect-pass orphan-fallback skips the LLM (heuristic summaries — `core/capture/summarizer.ts`). A cold bridge boot over a synthetic 100-step dirty episode completes in seconds with zero `malformed`/`timedOut` warnings; every batch call stays ≤12 steps. Same session also folded the bridge keepalive `10→90s` + close-on-failed-boot patches into the patch set, and repointed `skillEvolver` → NVIDIA integrate API in `config.yaml` (secret key stays in user config, not committed). Decision doc: [`memos-setup/learnings/2026-05-25-bounded-capture-llm-boot-hang.md`](memos-setup/learnings/2026-05-25-bounded-capture-llm-boot-hang.md). See patches 5–7 in the v2-plugin-patches section.

**2026-05-21 — CTO agent added (on Claude Code, not Hermes).** A standalone CTO persona lives at `~/Coding/Hermes-CTO`, wired to the v2 plugin as a new `cto` profile (memory tools via MCP + auto-capture hooks, all over the stdio bridge). It advises, delegates to the Hermes agents (`scripts/delegate-agent.sh` → `hermes -z`), and is callable by them (`scripts/ask-cto.sh` → `claude -p`). This re-introduces *peer* cross-agent interaction but **no central orchestrator and no cross-machine routing** — the v2-only stance otherwise holds. Same session also fixed the dirty-episode cold-boot stall (7 episodes marked `reward.skipped`) that caused the bridge process leak.

Any new agent working in this repo should read these before acting:

1. **Roadmap + latest state (start here):** [`memos-setup/learnings/2026-05-27-memory-roadmap.md`](memos-setup/learnings/2026-05-27-memory-roadmap.md) — phased plan (stability → feedback loop → shared daemon); paired RCA [`2026-05-26-capture-outage-rca-recovery.md`](memos-setup/learnings/2026-05-26-capture-outage-rca-recovery.md). Full end-to-end report: [`docs/architecture/Hermes-Memory-System-Comprehensive-Report-2026-05-27.pdf`](docs/architecture/Hermes-Memory-System-Comprehensive-Report-2026-05-27.pdf) (source deck `.html` alongside; rebuild with `tools/build-memory-report.sh`).
2. **Earlier decision doc (CTO agent + dirty-episode fix):** [`memos-setup/learnings/2026-05-21-cto-agent-on-claude-code.md`](memos-setup/learnings/2026-05-21-cto-agent-on-claude-code.md) — CTO-on-Claude-Code, memory wiring, cross-agent invocation, cold-boot fix
2. **Memory architecture decision:** [`memos-setup/learnings/2026-05-17-v2-only-bge-shares.md`](memos-setup/learnings/2026-05-17-v2-only-bge-shares.md) — drop CEO/Paperclip, commit to v2, BGE-large embedder, share_scope policy
3. **Previous decision (single-tier MemOS):** [`memos-setup/learnings/2026-04-28-collapse-to-single-tier-memos.md`](memos-setup/learnings/2026-04-28-collapse-to-single-tier-memos.md) — superseded by the May 17 doc; preserved for context on what was tried before
4. **Previous direction (v1 audit + remediation):** [`memos-setup/learnings/2026-04-27-v2-deprecated-revert-to-v1.md`](memos-setup/learnings/2026-04-27-v2-deprecated-revert-to-v1.md) — historical; v2 is now the chosen path despite the original audit
5. **Merged architecture brief (start here for slides):** [`docs/architecture/2026-05-17-memory-system-brief.pdf`](docs/architecture/2026-05-17-memory-system-brief.pdf) — 34-slide consolidated brief: decisions + orphan-cron root cause + plugin patches + tooling + speaker attribution + final state. Merge of the two source decks below, dedup'd. Editable source: [`2026-05-17-memory-system-brief.pptx`](docs/architecture/2026-05-17-memory-system-brief.pptx).
   - Source A: [`2026-05-17-memory-system-decisions.pptx`](docs/architecture/2026-05-17-memory-system-decisions.pptx) — original architectural review deck
   - Source B: [`2026-05-17-session-summary.pptx`](docs/architecture/2026-05-17-session-summary.pptx) — one-day overhaul summary deck
6. **MVP-readiness brief (historical):** [`tests/v1/reports/combined/v1-mvp-readiness-2026-04-26.pdf`](tests/v1/reports/combined/v1-mvp-readiness-2026-04-26.pdf) — pre-fix v1 audit; relevant only if you ever revisit v1
7. **Two-repo team explainer:** [`docs/architecture/two-repos.pdf`](docs/architecture/two-repos.pdf) — how this repo and the MemOS fork relate
8. **Superseded — historical only:** [`memos-setup/learnings/2026-04-20-v2-migration-plan.md`](memos-setup/learnings/2026-04-20-v2-migration-plan.md)

If you are working inside a **worktree** under `~/Coding/Hermes-wt/`, read the `TASK.md` in that directory — it's your full brief.

**Architecture status (2026-05-17):** Single machine, single memory tier, single plugin. Every agent runs on this box (`hostname` = `sergio`, Tailnet DNS name = `tower.taila4a33f.ts.net` — same machine, two names). Each Hermes agent has its own profile dir (`~/.hermes/profiles/<agent>/`). The v2 plugin provides isolation via row-level namespace tuples — no cubes, no API keys to manage. Skills + world_model are shared across agents (`share_scope: local`); traces, episodes, and policies are per-agent private. v1 MemOS server (Qdrant + Neo4j + SQLite) and Paperclip/CEO are retired.

## Working Rules
- **ALWAYS use parallel agents for independent tasks.** When multiple fixes, tests, or investigations can run simultaneously, launch them all in one message. Never serialize work that can be parallelized.
- **ALWAYS read entire documentation before creating skills or integrations.** Use Firecrawl (localhost:3002) if WebFetch struggles with JS-rendered docs. Never create a skill based on partial information.
- When given a docs URL, scrape every page. Use Firecrawl's `/v1/scrape` endpoint for JS-heavy sites.
- **CLAUDE.md is the canonical sprint state — keep it current in the same PR that changes direction.** Any PR that changes the project's strategic direction (new sprint kickoff, deprecating a product, switching backends, audit results that overturn a prior plan, major architectural decision) MUST in the same PR:
  1. Update the "🚨 Active sprint" header at the top of this file to reflect the new direction
  2. Add a decision doc at `memos-setup/learnings/<YYYY-MM-DD>-<topic>.md` capturing the why
  3. Cross-link the two

  **Reviewers:** block PRs that change strategic direction without these updates.

  **Agents starting a fresh session:** before doing anything else, spot-check that the "🚨 Active sprint" header matches the most recent decision doc in `memos-setup/learnings/` (sort by date) and the most recent strategic merge commits on `main`. If the header is stale, flag it to the operator and propose an update before continuing the requested task. Stale strategic context is the failure mode this rule exists to prevent.

## What This Is

Multi-agent Hermes setup running on a single workstation. The OS hostname is `sergio`; the Tailnet DNS name for the same box is `tower.taila4a33f.ts.net`. Operators usually SSH in from other devices, so the Tailnet name is the one you'll see in browser URLs and the local hostname is the one you'll see in shell prompts. **They are the same machine.** There is no separate Tower.

Each agent has its own profile, its own systemd gateway service, and its own namespace inside the v2 memory plugin. Agents do not orchestrate each other — they share knowledge through the memory plugin's shared layers (skills + world_model) and stay private on raw experience (traces/episodes/policies).

There is no CEO, no Paperclip, no cross-machine routing.

## Architecture

- **Agents:** `sergio`, `hr-agent`, `mohammed`, `krati`, `arinze`, `research-agent`, `email-marketing`, `lucas` — each runs as its own `hermes-gateway-<agent>.service` with its own `~/.hermes/profiles/<agent>/` directory. **`lucas`** added 2026-05-18: a MiniMax-M2.7-backed agent (`provider: minimax`, `https://api.minimax.io/anthropic`) with Discord channels; runs as `hermes-gateway-lucas.service`.
- **Memory:** `@memtensor/memos-local-plugin` v2 — single daemon on `127.0.0.1:18800`, single SQLite at `~/.hermes/memos-plugin/data/memos.db`, row-level multi-tenancy via `(owner_agent_kind, owner_profile_id, share_scope)`
- **Memory UI:** `https://tower.taila4a33f.ts.net/` (Tailscale Serve proxies tailnet HTTPS 443 → loopback `:18800`). Local equivalent: `http://localhost:18800`. Password-gated; reset via `rm ~/.hermes/memos-plugin/.auth.json`.
- **Embedder:** `Xenova/bge-large-en-v1.5` (1024-dim, local ONNX via Transformers.js). Picked 2026-05-17 after 3-way benchmark vs MiniLM and gemini-embedding-2 — see decision doc.
- **Memory LLM (extraction/summarisation):** DeepSeek V3 (`deepseek-chat` via `https://api.deepseek.com`) — **reverted Gemini → DeepSeek on 2026-05-25** once the DeepSeek account was refunded (balance verified $6.82, endpoint healthy 2026-05-26). DeepSeek is non-thinking (no `<think>` pollution) and has no free-tier RPM throttling, which the bursty capture load needs. Gemini 2.5 Flash-Lite was a 2026-05-24 stopgap while DeepSeek was at $0 (402). Rollback configs: `config.yaml.bak-deepseek-memory-2026-05-25` and the Gemini stopgap `config.yaml.bak-deepseek-2026-05-24`. See [`memos-setup/learnings/2026-05-24-deepseek-402-gemini-switch.md`](memos-setup/learnings/2026-05-24-deepseek-402-gemini-switch.md) (switch) + [`memos-setup/learnings/2026-05-26-capture-outage-rca-recovery.md`](memos-setup/learnings/2026-05-26-capture-outage-rca-recovery.md) (revert + RCA).
- **Skill crystallisation / skillEvolver LLM:** DeepSeek-R1 (`deepseek-reasoner` via `https://api.deepseek.com`) — **repointed to DeepSeek on 2026-05-25** (account refunded). Thinking-mode reasoning for structured skill synthesis + L2 induction; `<think>` output collapsed into YAML in post-processing. Prior hops: MiniMax M2.7 (Anthropic-compat), then NVIDIA integrate API (2026-05-25, throttled). Rollback: `config.yaml.bak-skillevolver-2026-05-25`.
- **Web search:** Firecrawl (localhost:3002) → SearXNG (localhost:8888) — free, unlimited, multi-engine aggregation
- **Web scraping (default):** Firecrawl (localhost:3002) with Playwright service for JS-rendered pages
- **Stealth scraping + interactive browser tool:** **Cloak service (localhost:9378)** — CloakBrowser stealth Chromium 146, C++ fingerprint patches, persistent per-domain cookies, request pacing, CapSolver captcha fallback, full interactive surface (`/tabs/*` endpoints: snapshot/click/type/scroll/back/screenshot). `CAMOFOX_URL` env points at port 9378 since 2026-05-16.
- **Camofox (retired 2026-05-16):** systemd unit stopped + disabled. Source still on disk under `~/.hermes/hermes-agent/node_modules/@askjo/camofox-browser/` for reference. The `tools/browser_camofox.py` filename is kept (renaming would touch too many `browser_tool.py` call sites) but its module docstring is a deprecation notice — it talks to Cloak. See `tower/docs/browser-stealth-benchmark-2026-05-16.md` and `memos-setup/learnings/2026-05-16-cloak-deprecate-camofox.md`.

### Retired components (kept for rollback only)

- **Paperclip / CEO orchestration** — retired 2026-05-17. The CEO-on-Tower pattern was dropped along with the multi-machine architecture.
- **v1 MemOS server** (`memos-server.service`) — stopped + disabled 2026-05-16. Source remains at `/home/openclaw/Coding/MemOS/`. Cube was empty when stopped; no data loss. Restart with `systemctl --user start memos-server.service` if you ever revisit it.
- **memos-toolset (v1 client plugin)** — `plugin.yaml.disabled-2026-05-12`. Hermes doesn't load it.
- **memos-hub.service** — disabled 2026-05-16. Was thrashing in an auto-restart loop attempting to spawn a hub mode that the v2 plugin doesn't implement upstream.

## Memory Sharing Policy

| Table | `share_scope` | Effect |
|---|---|---|
| `traces` | `private` | Each agent sees only its own turn-by-turn captures |
| `episodes` | `private` | Session boundaries stay per-agent |
| `policies` | `private` | L2 candidate patterns are local experiments per agent |
| `world_model` | `local` | Environment + operator facts shared across agents |
| `skills` | `local` | Crystallised callable procedures shared across agents |

Per-row attribution is automatic via the `owner_profile_id` column — when an agent reads a shared skill, the row carries the originating profile id.

**`isVisibleTo` rule** (`core/runtime/namespace.ts:136`): a row is visible to a caller if `share_scope ∈ {local, public, hub}` OR `(owner_agent_kind, owner_profile_id)` matches the caller's namespace.

**Auto-promotion root cause (resolved 2026-05-17):** a cron job from Sprint 3 (added 2026-05-12) ran every 15 minutes and bulk-promoted every `private` row to `local` by writing directly to SQLite — bypassing the plugin's HTTP API and namespace filter entirely. The script lived in an orphan Claude worktree (`.claude/worktrees/nice-mclaren-13f017/scripts/promote-memos-shares.py`) and was written for the (now-retired) Paperclip/CEO architecture so the orchestrator could read across cubes. Disabled in crontab on 2026-05-17 with the comment `# DISABLED 2026-05-17 (Paperclip/CEO retired …)`. Forensic audit triggers in `tools/forensic-audit.sql` capture any future re-emergence of the same pattern — apply with `sqlite3 ~/.hermes/memos-plugin/data/memos.db < tools/forensic-audit.sql`, inspect via `python3.12 tools/memos-explorer.py audit`.

## v2 plugin patches (applied 2026-05-17)

The bundled `@memtensor/memos-local-plugin@2.0.0` ships with no public repo, so our changes live in `tools/plugin-patches/` and are copied into the install dir by `tools/postinstall-patches.sh`. Run that script after every `npm install/update` of the plugin. Use `--check` for a read-only verification.

Eight logical patches (patches 6–8 added 2026-05-25):

1. **Shared-skill attribution.** `renderSkill` now appends `(learned by <profile>)` to the rendered prompt title so other agents see which profile crystallised a shared skill. Files: `core/retrieval/types.ts`, `tier1-skill.ts`, `injector.ts`, `core/pipeline/retrieval-repos.ts`.
2. **Per-request "view as <profile>" override.** A new `core/runtime/request-namespace.ts` module wraps every HTTP handler in an AsyncLocalStorage namespace context parsed from `?as_profile=<id>` or `X-As-Profile: <id>`. `effectiveNamespace()` in `memory-core.ts` prefers the ALS namespace over the daemon's startup-bound `activeNamespace`. `traces.ts` `listTurnKeys`/`countTurns` apply the override at SQL time so paginated turn-key results actually contain the requested profile's rows. Files: `core/runtime/request-namespace.ts` (new), `core/pipeline/memory-core.ts`, `core/storage/repos/traces.ts`, `server/http.ts`.
3. **Bundled-viewer UI overlay.** `web/dist/index.html` loads a small overlay script that injects a floating "VIEW AS …" picker top-right, fetches `/api/v1/diag/namespace`, and intercepts `window.fetch` to add `X-As-Profile`. Files: `web/dist/index.html`, `web/dist/hermes-profile-switcher.js` (new).
4. **Skill packager default share-scope.** Newly crystallised skills now default to `share_scope='local'` so they join the shared layer at write time (instead of landing `private` and needing manual promotion). Rebuilds preserve any explicit prior share state. File: `core/skill/packager.ts`.
5. **Named-speaker memory summaries (multi-human).** `MEMOS_HUMANS` env var in `~/.hermes/.env` lists the humans on this team (e.g. `Sergio:sergiopalacio96,Krati,Mohammed,Arinze`). The capture-pipeline summarizer reads it at startup and instructs the LLM to identify the speaker from `[handle]` markers prepended to user_text by the messaging gateway, then use the corresponding human's name in the summary (`"Krati asked about X"`, `"Sergio prefers Y"`). Falls back to omitting the speaker if it can't tell. Puts identity into the embedding space for sharper per-user retrieval. A small dotenv loader in `bridge.cts` reads `~/.hermes/.env` (and `~/.hermes/memos-plugin/.env` if present) so the var is visible regardless of how the daemon is spawned. Files: `core/capture/summarizer.ts`, `bridge.cts`.
6. **Chunked batch reflection (boot-hang prevention).** `runBatchScoring` splits a closed episode into `≤ batchThreshold`-step batch calls (`scoreBatchChunk`); a chunk whose batched call fails degrades to per-step for that chunk alone. `shouldBatch` now batches for both `auto` and `per_episode` (chunking, not degrade-to-per-step, keeps the prompt bounded). The reflect-pass orphan-fallback inserts use heuristic summaries (`summarizer.ts` `heuristicOnly`) so it doesn't fire one LLM call per orphan step at boot. Files: `core/capture/capture.ts`, `core/capture/summarizer.ts`.
7. **Per-step tool-call cap + maxTokens.** `core/capture/batch-scorer.ts` bounds the per-step `tool_calls` array (`capToolCalls`, keeps head+tail above 24) and forwards `maxTokens = 4096` as a hard ceiling on the batched-reflection response — the two N-scaling dimensions that produced `[llm.json] malformed op="capture.reflection.batch.v2"`. File: `core/capture/batch-scorer.ts`.
8. **Bridge keepalive / process-leak fix.** `adapters/hermes/memos_provider/__init__.py` blocks 90s (was 10s) for a cold boot so it doesn't respawn the bridge mid-boot and leak node procs, and closes a failed/timed-out bridge subprocess before dropping the handle. File: `adapters/hermes/memos_provider/__init__.py`. (The same-session `skillEvolver → NVIDIA` switch was itself superseded 2026-05-25 — skillEvolver is now `deepseek-reasoner`; see the Architecture LLM bullets. Secret keys live in user config, not committed.) **⚠️ Known-incomplete (2026-05-26):** patch #8's keepalive uses 90s, but the *initial* `session.open` path still defaults to 30s and a transport-close reconnect to 4s; under concurrent gateway cold-boots (each loading BGE-large) these short timeouts still fire → respawn/leak. See the durable-fix options in [`memos-setup/learnings/2026-05-26-capture-outage-rca-recovery.md`](memos-setup/learnings/2026-05-26-capture-outage-rca-recovery.md).

See [`memos-setup/learnings/2026-05-25-bounded-capture-llm-boot-hang.md`](memos-setup/learnings/2026-05-25-bounded-capture-llm-boot-hang.md) for the root-cause analysis and test.

Verify everything is wired:

```bash
bash tools/postinstall-patches.sh --check        # patches present
bash tools/stress-test.sh                        # 36 end-to-end checks
```

## Key Paths
- Hermes config: `~/.hermes/config.yaml`
- Hermes per-agent profiles: `~/.hermes/profiles/<agent>/config.yaml`
- Hermes skills: `~/.hermes/skills/` (plus per-profile skill dirs)
- Hermes env: `~/.hermes/.env` (FIRECRAWL_API_URL=http://localhost:3002, GEMINI_API_KEY, MINIMAX_API_KEY)
- v2 plugin install: `~/.hermes/memos-plugin/`
- v2 plugin config: `~/.hermes/memos-plugin/config.yaml`
- v2 plugin DB: `~/.hermes/memos-plugin/data/memos.db`
- v2 plugin auth: `~/.hermes/memos-plugin/.auth.json` (delete to reset viewer password)
- v2 plugin logs: `~/.hermes/memos-plugin/logs/`
- MemOS v1 source (retired): `/home/openclaw/Coding/MemOS/`
- Firecrawl env: `/home/openclaw/.openclaw/workspace/firecrawl/.env`

## Demo Agents
1. **research-agent** — research-coordinator skill orchestrating sub-researchers
2. **email-marketing-agent** — plusvibe.ai email marketing agent
3. **hr-agent**, **sergio**, **mohammed**, **krati**, **arinze**, **lucas** — operational agents with per-profile gateways (`lucas` is MiniMax-M2.7-backed, added 2026-05-18)

## Commands

```bash
# Bootstrap web stack (Firecrawl + SearXNG + Cloak)
./setup-web-stack.sh

# Inspect memory plugin state
curl -s localhost:18800/health
sqlite3 ~/.hermes/memos-plugin/data/memos.db "SELECT owner_profile_id, share_scope, COUNT(*) FROM traces GROUP BY 1,2"

# Open the memory viewer (either URL works — same daemon)
xdg-open http://localhost:18800              # when sitting at the box
xdg-open https://tower.taila4a33f.ts.net/    # via Tailnet from any device
# Password set in ~/.hermes/memos-plugin/.auth.json

# 3D Memory Map (full graph: traces ↘ policies ↘ skills + cluster labels)
# Served by the same daemon as a static page; sidebar tab in the bundled viewer
xdg-open https://tower.taila4a33f.ts.net/memory-map.html
# memory-graph.json is auto-refreshed by the WAL watcher (debounce 5min, floor 15min)
systemctl --user status memory-graph-watcher          # daemon health
journalctl --user -u memory-graph-watcher -n 30 --no-pager
# Manual one-off regen:
~/.hermes/tools-venv/bin/python tools/memos-explorer.py graph-export \
  --out tools/memory-graph.json

# Reset memory viewer password
rm ~/.hermes/memos-plugin/.auth.json
# (then re-open the viewer; it will prompt for a new password)

# Restart a specific Hermes agent (picks up plugin config / profile changes)
systemctl --user restart hermes-gateway-sergio.service

# Restart all Hermes agents
systemctl --user restart hermes-gateway.service \
  hermes-gateway-sergio.service hermes-gateway-hr-agent.service \
  hermes-gateway-mohammed.service hermes-gateway-krati.service \
  hermes-gateway-arinze.service hermes-gateway-research-agent.service \
  hermes-gateway-lucas.service

# Verify web stack health
curl -s localhost:9378/health          # Cloak (primary stealth scraper)
curl -s localhost:8888/search?q=test&format=json   # SearXNG
curl -s localhost:3002/v1/search -X POST -H "Content-Type: application/json" \
  -d '{"query":"test","limit":1}'   # Firecrawl search

# Stealth scrape via Cloak
curl -s -X POST localhost:9378/v1/scrape -H "Content-Type: application/json" \
  -d '{"url":"https://www.idealista.com/venta-viviendas/estepona-malaga/","formats":["html","markdown"]}'

# Service management
systemctl --user status cloak-service.service
systemctl --user restart cloak-service.service
journalctl --user -u cloak-service.service -n 50 --no-pager
```

## Web Stack Setup (for new deployments)

Run `./setup-web-stack.sh` to bootstrap. Manual steps:

1. **SearXNG**: in Firecrawl docker-compose, port 8888
2. **Firecrawl**: `cd ~/.openclaw/workspace/firecrawl && docker compose up -d`
3. **Cloak**: `systemctl --user start cloak-service.service`, port 9378
4. **Hermes config**: `web.backend: firecrawl` in `~/.hermes/config.yaml`
5. **Brave API key**: kept in `.env` as fallback but NOT active (credits exhausted at ~6 days/month)

### When to use which tool

| Task | Tool | Why |
|---|---|---|
| `web_search()` | Firecrawl → SearXNG | Free, unlimited, multi-engine aggregation |
| `web_extract()` | Firecrawl → Playwright | Handles JS-rendered pages |
| Anti-bot sites (Idealista, Ticketmaster, Glassdoor — anything returning `server: DataDome` or Cloudflare Turnstile) | Cloak service `localhost:9378/v1/scrape` | CloakBrowser C++ stealth patches + persistent cookies + CapSolver fallback. ~3.9s/page on clean IPs. |
| Interactive browse (click/type/snapshot) via agent's `browser` skill | Cloak service `/tabs/*` endpoints (called transparently via `browser_camofox.py` — module name kept for backward compatibility, talks to Cloak since 2026-05-16) | Chromium-based, lower latency than the old Firefox-fork path, same ARIA-snapshot format byte-for-byte. |
| Simple static pages | Firecrawl `/v1/scrape` | Fast, no browser overhead |

## Domain Routing Rules (enforced in skills)
- `reddit.com` → always rewrite to `old.reddit.com`
- `github.com` → basic Firecrawl only (no Playwright/mobile flags)
- SearXNG search → no rate limit (self-hosted), but be reasonable with parallel calls

## Self-Improvement
- quality_score = source_count(25%) + domain_coverage(25%) + freshness(20%) + depth(20%) + zero_result_penalty(10%)
- Soft loop: user feedback → skill patch (no CEO involvement post-2026-05-17 — patches authored directly)
- Hard loop: score < threshold → auto-patch → re-run → keep if improved, revert if not
