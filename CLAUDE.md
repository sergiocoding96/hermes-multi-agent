# Hermes Multi-Agent Research System

## Working Rules
- **ALWAYS read entire documentation before creating skills or integrations.** Use Firecrawl (localhost:3002) if WebFetch struggles with JS-rendered docs. Never create a skill based on partial information.
- When given a docs URL, scrape every page. Use Firecrawl's `/v1/scrape` endpoint for JS-heavy sites.

## What This Is
Layered multi-agent system: CEO (Claude Opus 4.6 via Paperclip) orchestrates specialized Hermes agents, each with isolated MemOS memory cubes. Two feedback loops: soft (user feedback → skill patches) and hard (Karpathy autoresearch-style metric threshold → auto-patch → re-run).

## Architecture
- **CEO Agent**: Claude Opus 4.6 on Paperclip (http://tower.taila4a33f.ts.net:3100)
- **Worker Agents**: Hermes (MiniMax M2.7) spawned via hermes-paperclip-adapter
- **Memory**: MemOS (Qdrant + Neo4j + SQLite) at localhost:8001
- **Web scraping**: Firecrawl at localhost:3002
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

## Domain Routing Rules (enforced in skills)
- `reddit.com` → always rewrite to `old.reddit.com`
- `github.com` → basic Firecrawl only (no Playwright/mobile flags)
- Brave search → max 3 parallel calls (~10 req/min rate limit)

## Demo Agents
1. **research-agent** — research-coordinator skill orchestrating sub-researchers
2. **email-marketing-agent** — plusvibe.ai email marketing agent

## Commands
```bash
# Start MemOS server
cd /home/openclaw/Coding/MemOS && python -m memos.api.server

# Run provisioning (after server is up)
python setup-memos-agents.py

# Test research agent
hermes chat -q "Research [topic]" --skill research-coordinator
```

## Self-Improvement
- quality_score = source_count(25%) + domain_coverage(25%) + freshness(20%) + depth(20%) + zero_result_penalty(10%)
- Soft loop: user feedback → CEO patches skill
- Hard loop: score < threshold → auto-patch → re-run → keep if improved, revert if not
