# Hermes Multi-Agent Research System

## 🚨 Active sprint — read this first

**Single-tier memory architecture: MemOS only. Holographic Tier 1 deprecated 2026-04-28. v1 (MemOS server) remains the production target.**

Any new agent working in this repo should read these before acting:

1. **Decision doc (current):** [`memos-setup/learnings/2026-04-28-collapse-to-single-tier-memos.md`](memos-setup/learnings/2026-04-28-collapse-to-single-tier-memos.md) — why holographic was deprecated, what's gone, what's left, rollback path
2. **Previous direction (still relevant context):** [`memos-setup/learnings/2026-04-27-v2-deprecated-revert-to-v1.md`](memos-setup/learnings/2026-04-27-v2-deprecated-revert-to-v1.md) — why v2 was deprecated, what was fixed in v1
3. **MVP-readiness brief:** [`tests/v1/reports/combined/v1-mvp-readiness-2026-04-26.pdf`](tests/v1/reports/combined/v1-mvp-readiness-2026-04-26.pdf) — pre-fix audit + remediation plan
4. **Two-repo team explainer:** [`docs/architecture/two-repos.pdf`](docs/architecture/two-repos.pdf) — how Hermes (this repo) and MemOS (`sergiocoding96/MemOS`, your fork) fit together
5. **Operator runbook:** [`tests/v1/STEP-BY-STEP.md`](tests/v1/STEP-BY-STEP.md) and [`tests/v1/CC-PROMPTS.md`](tests/v1/CC-PROMPTS.md) — phase-by-phase commands for fix → re-audit → ship
6. **Sprint 1 history (still relevant):** [`memos-setup/learnings/2026-04-20-sprint-merge-log.md`](memos-setup/learnings/2026-04-20-sprint-merge-log.md) — what was shipped in the original v1 hardening sprint
7. **Superseded — historical only:** [`memos-setup/learnings/2026-04-20-v2-migration-plan.md`](memos-setup/learnings/2026-04-20-v2-migration-plan.md) (the original v2 migration plan)

If you are working inside a **worktree** under `~/Coding/Hermes-wt/` or `~/Coding/MemOS-wt/`, read the `TASK.md` in that directory — it's your full brief.

**Architecture status (2026-04-28):** Single-tier MemOS. Two-tier holographic+MemOS design was aspirational — Tier 1 (`holographic`) had zero rows in every profile after weeks of operation. Collapsed to one stack: agents read/write MemOS via `memos-toolset`, plus the always-on built-in memory layer in hermes-agent core. v2 plugin (`@memtensor/memos-local-plugin`) remains deprecated.

**Sprint 2 status (2026-04-27):** v2 audit failed (mean 2.4/10, min 1/10). v1 audit (clean re-run) found a fixable system at mean 5.2/10 with five surgical bugs. All five fixed across 6 PRs (Hermes #14/#15/#16, MemOS #6/#7/#8). v2 stays as a dormant spike; do not enable in production.

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
Layered multi-agent system: CEO (Claude Opus 4.6 via Paperclip) orchestrates specialized Hermes agents, each with isolated MemOS memory cubes. Two feedback loops: soft (user feedback → skill patches) and hard (Karpathy autoresearch-style metric threshold → auto-patch → re-run).

## Architecture
- **CEO Agent**: Claude Opus 4.6 on Paperclip (http://tower.taila4a33f.ts.net:3100)
- **Worker Agents**: Hermes (MiniMax M2.7) spawned via hermes-paperclip-adapter
- **Memory**: MemOS (Qdrant + Neo4j + SQLite) at localhost:8001 — single-tier; per-profile `memory.provider: ''` (no external Tier 1 plugin)
- **Web search**: Firecrawl (localhost:3002) → SearXNG (localhost:8888) — free, unlimited, aggregates Google+Bing+DDG+Startpage
- **Web scraping (default)**: Firecrawl (localhost:3002) with Playwright service for JS-rendered pages
- **Stealth scraping + interactive browser tool**: **Cloak service (localhost:9378)** — CloakBrowser stealth Chromium 146 with C++ fingerprint patches, persistent per-domain cookies, request pacing, CapSolver captcha fallback, **and** the full interactive surface (`/tabs/*` endpoints: snapshot/click/type/scroll/back/screenshot) that `browser_camofox.py` calls. `CAMOFOX_URL` env points at port 9378 since 2026-05-16.
- **Camofox (retired 2026-05-16)**: systemd unit stopped + disabled. Source still installed under `~/.hermes/hermes-agent/node_modules/@askjo/camofox-browser/` for reference; not started. The `tools/browser_camofox.py` filename is kept (renaming would touch too many `browser_tool.py` call sites) but its module docstring is now a deprecation notice — it talks to Cloak. See `tower/docs/browser-stealth-benchmark-2026-05-16.md` and `memos-setup/learnings/2026-05-16-cloak-deprecate-camofox.md` for the rollback procedure if a regression appears.
- **Token burn rule**: Agents communicate ONLY via MemOS shared state, never agent-to-agent

## Key Paths
- Hermes config: `~/.hermes/config.yaml`
- Hermes skills: `~/.hermes/skills/`
- Hermes env: `~/.hermes/.env` (FIRECRAWL_API_URL=http://localhost:3002)
- MemOS source: `/home/openclaw/Coding/MemOS/`
- Paperclip CEO SOUL: `~/.paperclip/instances/default/companies/.../agents/84a0aad9-.../instructions/SOUL.md`
- Firecrawl env: `/home/openclaw/.openclaw/workspace/firecrawl/.env`

## MemOS Setup
- All agents: GeneralTextMemory + TreeTextMemory + Fine MemReader mode
- Email-marketing agent additionally gets PreferenceTextMemory
- CEO uses CompositeCubeView (reads all cubes, results tagged with cube_id)
- Worker agents use SingleCubeView (isolated to own cube)
- async_mode: "sync" for all skill writes
- visibility: "private" on all memory items
- Scheduler: enabled, local queue (no Redis)
- **Embedder:** local sentence-transformers (all-MiniLM-L6-v2, 384 dim) — no API dependency
- **MEMRADER:** DeepSeek V3 (deepseek-chat) — MiniMax broke extraction with `<think>` tags
- **Chunk size:** 4000 tokens (was 1600 — too small for research briefs)
- **Cube isolation:** credential-based since 2026-04-27. `agent_auth.py` middleware binds each API key to a `user_id` (BCrypt-verified, prefix-bucketed); the `/product/add` handler enforces cube ownership at `server_router.py:467`. SOUL.md instructions still tell agents to only address their own cubes, but the API layer now enforces it on writes — not trust-only.
- **IMPORTANT:** Skills must chunk long output into ≤500-word blocks before POSTing to MemOS for best extraction quality.

## Web Stack Setup (for new deployments)
Run `./setup-web-stack.sh` to bootstrap everything. Manual steps:
1. **SearXNG**: added to Firecrawl docker-compose, runs on port 8888
2. **Firecrawl**: `cd ~/.openclaw/workspace/firecrawl && docker compose up -d` (search + scrape + Playwright)
3. **Camofox**: started by hermes-agent or via `@reboot` cron, port 9377
4. **Hermes config**: `web.backend: firecrawl` in `~/.hermes/config.yaml`
5. **Brave API key**: kept in `.env` as fallback but NOT the active backend (credits exhausted at ~6 days/month)

### When to use which tool
| Task | Tool | Why |
|------|------|-----|
| `web_search()` | Firecrawl → SearXNG | Free, unlimited, multi-engine aggregation |
| `web_extract()` | Firecrawl → Playwright | Handles JS-rendered pages |
| Anti-bot sites (Idealista, Ticketmaster, Glassdoor — anything returning `server: DataDome` or Cloudflare Turnstile) | **Cloak service `localhost:9378/v1/scrape`** | CloakBrowser C++ stealth patches + persistent cookies + CapSolver fallback. ~3.9s/page on clean IPs. |
| Interactive browse (click/type/snapshot) via agent's `browser` skill | **Cloak service** `/tabs/*` endpoints (called transparently via `browser_camofox.py` — module name kept for backward compatibility, talks to Cloak since 2026-05-16) | Chromium-based, lower latency than the old Firefox-fork path, same ARIA-snapshot format byte-for-byte. |
| Simple static pages | Firecrawl `/v1/scrape` | Fast, no browser overhead |

## Domain Routing Rules (enforced in skills)
- `reddit.com` → always rewrite to `old.reddit.com`
- `github.com` → basic Firecrawl only (no Playwright/mobile flags)
- SearXNG search → no rate limit (self-hosted), but be reasonable with parallel calls

## Demo Agents
1. **research-agent** — research-coordinator skill orchestrating sub-researchers
2. **email-marketing-agent** — plusvibe.ai email marketing agent

## Commands
```bash
# Bootstrap web stack (Firecrawl + SearXNG + Camofox)
./setup-web-stack.sh

# Start MemOS server
cd /home/openclaw/Coding/MemOS && python -m memos.api.server

# Run provisioning (after server is up)
python setup-memos-agents.py

# Test research agent
hermes chat -q "Research [topic]" --skill research-coordinator

# Verify web stack health
curl -s localhost:9378/health          # Cloak (primary stealth scraper)
curl -s localhost:9377/health          # Camofox (legacy interactive browser)
curl -s localhost:8888/search?q=test&format=json  # SearXNG
curl -s localhost:3002/v1/search -X POST -H "Content-Type: application/json" -d '{"query":"test","limit":1}'  # Firecrawl search

# Stealth scrape via Cloak
curl -s -X POST localhost:9378/v1/scrape -H "Content-Type: application/json" \
  -d '{"url":"https://www.idealista.com/venta-viviendas/estepona-malaga/","formats":["html","markdown"]}'

# Service management
systemctl --user status cloak-service.service
systemctl --user restart cloak-service.service
journalctl --user -u cloak-service.service -n 50 --no-pager

# Add CapSolver API key (when you have one):
#   cp ~/.config/systemd/user/cloak-service.service.d/capsolver.conf.example \
#      ~/.config/systemd/user/cloak-service.service.d/capsolver.conf
#   edit the file, then: systemctl --user daemon-reload && systemctl --user restart cloak-service
```

## Self-Improvement
- quality_score = source_count(25%) + domain_coverage(25%) + freshness(20%) + depth(20%) + zero_result_penalty(10%)
- Soft loop: user feedback → CEO patches skill
- Hard loop: score < threshold → auto-patch → re-run → keep if improved, revert if not
