# Hermes Multi-Agent Research System

## 🚨 Active sprint — read this first

**Removed the Paperclip CEO and the v2 MemOS hub on 2026-05-11. Hermes Kanban replaces the CEO. Single-tier MemOS (v1 server) stays. Workers stay.**

Any new agent working in this repo should read these before acting:

1. **Decision doc (current):** [`memos-setup/learnings/2026-05-11-remove-hub-and-paperclip-ceo.md`](memos-setup/learnings/2026-05-11-remove-hub-and-paperclip-ceo.md) — why the CEO + hub were removed, what's gone, what's left, rollback path
2. **Previous direction (still relevant context):** [`memos-setup/learnings/2026-04-28-collapse-to-single-tier-memos.md`](memos-setup/learnings/2026-04-28-collapse-to-single-tier-memos.md) — why holographic was deprecated
3. **Previous direction (still relevant context):** [`memos-setup/learnings/2026-04-27-v2-deprecated-revert-to-v1.md`](memos-setup/learnings/2026-04-27-v2-deprecated-revert-to-v1.md) — why v2 was deprecated, what was fixed in v1
4. **MVP-readiness brief:** [`tests/v1/reports/combined/v1-mvp-readiness-2026-04-26.pdf`](tests/v1/reports/combined/v1-mvp-readiness-2026-04-26.pdf) — pre-fix audit + remediation plan
5. **Two-repo team explainer:** [`docs/architecture/two-repos.pdf`](docs/architecture/two-repos.pdf) — how Hermes (this repo) and MemOS (`sergiocoding96/MemOS`, your fork) fit together
6. **Operator runbook:** [`tests/v1/STEP-BY-STEP.md`](tests/v1/STEP-BY-STEP.md) and [`tests/v1/CC-PROMPTS.md`](tests/v1/CC-PROMPTS.md) — phase-by-phase commands for fix → re-audit → ship
7. **Sprint 1 history (still relevant):** [`memos-setup/learnings/2026-04-20-sprint-merge-log.md`](memos-setup/learnings/2026-04-20-sprint-merge-log.md) — what was shipped in the original v1 hardening sprint

**Architecture status (2026-05-11):** Single orchestrator + workers. Sergio's local hermes profile orchestrates via the Kanban feature in hermes-agent (replaces the Paperclip CEO). Hermes workers (research-agent, email-marketing) keep their isolated MemOS cubes. The v2 team-sharing hub (port 18992) is gone — cross-cube reads, if needed, happen via Local API calls against MemOS v1 at `:8001`. The MemOS-hub MCP server, `scripts/ceo/`, `scripts/paperclip/`, `scripts/migration/`, and the v2 audit suite were deleted in the same PR.

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
Hermes Kanban-orchestrated multi-agent system. Sergio's local hermes profile dispatches tasks to specialized Hermes workers, each with isolated MemOS memory cubes. Two feedback loops: soft (user feedback → skill patches) and hard (Karpathy autoresearch-style metric threshold → auto-patch → re-run).

## Architecture
- **Orchestrator**: Sergio's local hermes profile, using the Kanban feature in hermes-agent to dispatch and track work
- **Worker Agents**: Hermes (MiniMax M2.7) — `research-agent`, `email-marketing-agent`
- **Memory**: MemOS (Qdrant + Neo4j + SQLite) at localhost:8001 — single-tier; per-profile `memory.provider: ''` (no external Tier 1 plugin)
- **Web search**: Firecrawl (localhost:3002) → SearXNG (localhost:8888) — free, unlimited, aggregates Google+Bing+DDG+Startpage
- **Web scraping**: Firecrawl (localhost:3002) with Playwright service for JS-rendered pages
- **Anti-bot browser**: Camofox (localhost:9377) — Camoufox Firefox fork with C++ fingerprint spoofing, bypasses Cloudflare/anti-bot
- **Token burn rule**: Agents communicate ONLY via MemOS shared state, never agent-to-agent

## Key Paths
- Hermes config: `~/.hermes/config.yaml`
- Hermes skills: `~/.hermes/skills/`
- Hermes env: `~/.hermes/.env` (FIRECRAWL_API_URL=http://localhost:3002)
- MemOS source: `/home/openclaw/Coding/MemOS/`
- Firecrawl env: `/home/openclaw/.openclaw/workspace/firecrawl/.env`

## MemOS Setup
- All agents: GeneralTextMemory + TreeTextMemory + Fine MemReader mode
- Email-marketing agent additionally gets PreferenceTextMemory
- Worker agents use SingleCubeView (isolated to own cube). If the orchestrator profile needs cross-cube reads, add an `orchestrator` user with multi-cube grants in `deploy/scripts/setup-memos-agents.py`.
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
| Anti-bot sites (Idealista, etc.) | Camofox `browser_navigate` + `browser_snapshot` | Camoufox fingerprint spoofing bypasses Cloudflare |
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
curl -s localhost:9377/health          # Camofox
curl -s localhost:8888/search?q=test&format=json  # SearXNG
curl -s localhost:3002/v1/search -X POST -H "Content-Type: application/json" -d '{"query":"test","limit":1}'  # Firecrawl search
```

## Self-Improvement
- quality_score = source_count(25%) + domain_coverage(25%) + freshness(20%) + depth(20%) + zero_result_penalty(10%)
- Soft loop: user feedback → orchestrator patches skill
- Hard loop: score < threshold → auto-patch → re-run → keep if improved, revert if not
