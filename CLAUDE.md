# Hermes Multi-Agent Research System

## 🚨 Active sprint — read this first

**Sprint 2 in progress: migrating from MemOS server (Product 1) to `@memtensor/memos-local-hermes-plugin` (Product 2).**

Any new agent working in this repo (especially on branches starting with `feat/migrate-*`, `wire/*`, `docs/write-v2-*`, `hermes/*`) should read these before acting:

1. **Master plan:** [`memos-setup/learnings/2026-04-20-v2-migration-plan.md`](memos-setup/learnings/2026-04-20-v2-migration-plan.md) — why we're migrating, 5-stage plan, rollback
2. **Execution guide:** [`scripts/worktrees/migration/README.md`](scripts/worktrees/migration/README.md) — which session runs what, in what order
3. **Sprint 1 history:** [`memos-setup/learnings/2026-04-20-sprint-merge-log.md`](memos-setup/learnings/2026-04-20-sprint-merge-log.md) — what we shipped in the server-hardening sprint (scored 9.1/10)

If you are working inside a **worktree** under `~/Coding/Hermes-wt/`, read the `TASK.md` in that directory — it's your full brief.

Sprint 2 replaces the MemOS server with a local plugin. Don't assume the server is authoritative — check the master plan for current state.

## Working Rules
- **ALWAYS use parallel agents for independent tasks.** When multiple fixes, tests, or investigations can run simultaneously, launch them all in one message. Never serialize work that can be parallelized.
- **ALWAYS read entire documentation before creating skills or integrations.** Use Firecrawl (localhost:3002) if WebFetch struggles with JS-rendered docs. Never create a skill based on partial information.
- When given a docs URL, scrape every page. Use Firecrawl's `/v1/scrape` endpoint for JS-heavy sites.

## What This Is
Layered multi-agent system: CEO (Claude Opus 4.6 via Paperclip) orchestrates specialized Hermes agents, each with isolated MemOS memory cubes. Two feedback loops: soft (user feedback → skill patches) and hard (Karpathy autoresearch-style metric threshold → auto-patch → re-run).

## Architecture
- **CEO Agent**: Claude Opus 4.6 on Paperclip (http://tower.taila4a33f.ts.net:3100)
- **Worker Agents**: Hermes (MiniMax M2.7) spawned via hermes-paperclip-adapter
- **Memory**: MemOS (Qdrant + Neo4j + SQLite) at localhost:8001
- **Web search**: Firecrawl (localhost:3002) → SearXNG (localhost:8888) — free, unlimited, aggregates Google+Bing+DDG+Startpage
- **Web scraping**: Firecrawl (localhost:3002) with Playwright service for JS-rendered pages
- **Anti-bot browser**: Camofox (localhost:9377) — Camoufox Firefox fork with C++ fingerprint spoofing, bypasses Cloudflare/anti-bot
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
- **IMPORTANT:** No API-level cube isolation — trust-based via SOUL.md only. Agents are told to only access their own cubes.
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
- Soft loop: user feedback → CEO patches skill
- Hard loop: score < threshold → auto-patch → re-run → keep if improved, revert if not
