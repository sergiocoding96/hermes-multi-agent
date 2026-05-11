# Hermes Multi-Agent Research System

## 🚨 Active sprint — read this first

**Sprint 3 in progress: removing the MemOS hub (v2 plugin) and the Paperclip CEO. Orchestration moves to the user's local Hermes profile, driven via Hermes Kanban.**

Any new agent working in this repo should read these before acting:

1. **Decision doc:** [`memos-setup/learnings/2026-05-11-remove-hub-and-paperclip-ceo.md`](memos-setup/learnings/2026-05-11-remove-hub-and-paperclip-ceo.md) — why we ripped out both layers, what replaces them
2. **Sprint 1 history:** [`memos-setup/learnings/2026-04-20-sprint-merge-log.md`](memos-setup/learnings/2026-04-20-sprint-merge-log.md) — last green sprint (server hardening, 9.1/10)

The MemOS server (Product 1, localhost:8001) is still the authoritative memory backend. We're keeping it. We're dropping the v2 plugin migration and the Paperclip CEO that orchestrated it.

## Working Rules
- **ALWAYS use parallel agents for independent tasks.** When multiple fixes, tests, or investigations can run simultaneously, launch them all in one message. Never serialize work that can be parallelized.
- **ALWAYS read entire documentation before creating skills or integrations.** Use Firecrawl (localhost:3002) if WebFetch struggles with JS-rendered docs. Never create a skill based on partial information.
- When given a docs URL, scrape every page. Use Firecrawl's `/v1/scrape` endpoint for JS-heavy sites.

## What This Is
Layered multi-agent system. The user's local Hermes profile orchestrates (via Hermes Kanban) and fans tasks out to specialized worker profiles, each with isolated MemOS memory cubes. Two feedback loops: soft (user feedback → skill patches) and hard (Karpathy autoresearch-style metric threshold → auto-patch → re-run).

## Architecture
- **Orchestrator:** the user's local Hermes profile, driven via Hermes Kanban. Spawns worker tasks and reads cross-cube memory for synthesis.
- **Worker Agents:** Hermes profiles (`research-agent`, `email-marketing`) — MiniMax M2.7 primary, DeepSeek V3 fallback.
- **Memory:** MemOS server (Qdrant + Neo4j + SQLite) at localhost:8001. Workers talk to it via the `memos-toolset` plugin (per-profile bcrypt-authed API key).
- **Web search:** Firecrawl (localhost:3002) → SearXNG (localhost:8888) — free, unlimited, aggregates Google+Bing+DDG+Startpage
- **Web scraping:** Firecrawl with Playwright service for JS-rendered pages
- **Anti-bot browser:** Camofox (localhost:9377) — Camoufox Firefox fork, C++ fingerprint spoofing, bypasses Cloudflare
- **Token burn rule:** agents communicate ONLY via MemOS shared state, never agent-to-agent

## Key Paths
- Hermes config: `~/.hermes/config.yaml`
- Hermes skills: `~/.hermes/skills/`
- Hermes env: `~/.hermes/.env` (FIRECRAWL_API_URL=http://localhost:3002)
- MemOS source: `/home/openclaw/Coding/MemOS/`
- Firecrawl env: `/home/openclaw/.openclaw/workspace/firecrawl/.env`

## MemOS Setup
- All worker agents: GeneralTextMemory + TreeTextMemory + Fine MemReader mode
- Email-marketing agent additionally gets PreferenceTextMemory
- Workers use SingleCubeView (isolated to own cube)
- The local-Hermes orchestrator uses its own MemOS principal with read grants to all worker cubes (replacing the old CEO CompositeCubeView role)
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

# Test a worker agent directly
hermes -p research-agent chat -q "Research [topic]" --skill research-coordinator

# Verify web stack health
curl -s localhost:9377/health          # Camofox
curl -s localhost:8888/search?q=test&format=json  # SearXNG
curl -s localhost:3002/v1/search -X POST -H "Content-Type: application/json" -d '{"query":"test","limit":1}'  # Firecrawl search
```

## Self-Improvement
- quality_score = source_count(25%) + domain_coverage(25%) + freshness(20%) + depth(20%) + zero_result_penalty(10%)
- Soft loop: user feedback → orchestrator patches skill
- Hard loop: score < threshold → auto-patch → re-run → keep if improved, revert if not
