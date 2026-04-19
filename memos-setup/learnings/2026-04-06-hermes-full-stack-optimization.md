# Hermes Full Stack Optimization — 2026-04-06 to 2026-04-07

## What Happened

A comprehensive audit and optimization of the entire Hermes Agent setup. Started with the user reporting Brave Search credit exhaustion and Camofox browser crashes. Expanded into a full 99-page documentation review, 34-area feature audit, and systematic optimization that raised the setup score from **5.2/10 to 7.3/10**.

---

## Phase 1: Critical Fixes (2026-04-06)

### Problem: Brave Search credits exhausted
- Brave API returning `402 USAGE_LIMIT_EXCEEDED` — $5/month limit hit in 6 days
- `x-ratelimit-remaining: 0` with 24 days left in billing cycle
- Every `web_search()` call in research skills was burning paid credits

**Solution: SearXNG meta-search engine (free, unlimited)**
- Added SearXNG Docker container to existing Firecrawl docker-compose
- SearXNG aggregates Google + Bing + DuckDuckGo + Startpage + AOL
- Results scored by cross-engine agreement (found by 3+ engines = high confidence)
- Connected to Firecrawl via `SEARXNG_ENDPOINT=http://searxng:8080`
- Changed `web.backend: brave → firecrawl` in config.yaml
- Tested: 40+ results per query, relevant and well-ranked

**Key learning:** SearXNG returns ~40 results per query vs Brave's 5-10. Quality is comparable. Occasionally surfaces noise (irrelevant foreign-language results) but agents filter these during synthesis. For agentic use, the volume advantage outweighs the noise.

### Problem: Camofox crashing on navigation
- `better-sqlite3` native module compiled for wrong Node.js version
- Health endpoint worked (no sqlite needed) but any tab creation → crash: `Module did not self-register`
- Node v25.8.2 (Linuxbrew) vs v22.22.1 (system)

**Solution:**
1. `npm rebuild better-sqlite3` in hermes-agent directory
2. Restarted Camofox via the correct Node binary (`/home/linuxbrew/.linuxbrew/bin/node`)
3. Tested on Idealista (Cloudflare-protected) — full page content loaded, cookie banner visible, property listings accessible
4. Created systemd user service + @reboot cron for boot persistence

**Key learning:** When Node.js is updated (especially major versions via Homebrew/Linuxbrew), native modules like better-sqlite3 must be rebuilt. The symptom is "Module did not self-register" — always fix with `npm rebuild <module>`.

### Problem: Firecrawl API was stopped
- Redis, RabbitMQ, Postgres running but the API container had received SIGINT and stopped
- `docker compose up -d api` brought it back

**Key learning:** Firecrawl API doesn't auto-restart after a graceful shutdown. Docker compose `restart: unless-stopped` should be added to the API service.

---

## Phase 2: Full Documentation Audit (2026-04-06)

### Process
1. Used Firecrawl `/v1/map` to discover all 99 doc pages on hermes-agent.nousresearch.com
2. Batch-scraped all 99 pages using Firecrawl `/v1/scrape` with parallel requests (15 concurrent)
3. Cross-referenced every documented feature against actual config.yaml + .env + running services
4. Used a parallel subagent to audit config while reading docs

### Findings
- 34 scoreable feature areas identified
- 14 areas scoring 0-2 (completely unused or broken)
- Key broken items: corrupted `OPENROUTER_API_KEY` (terminal escape char `^[[B`), fake `FAL_KEY` (`efefeefef`)
- Key missing: no fallback provider (MiniMax down = everything dead), no memory provider, no hooks, no plugins, no webhooks, no MCP
- Key strengths: Skills (90+), browser (Camofox working), cron jobs active

**Key learning:** Hermes has far more features than most users configure. The docs reveal 7 memory providers, 14 messaging platforms, webhook routes, RL training, batch processing, Python library mode, and an OpenAI-compatible API server — most of which were completely unused.

---

## Phase 3: Systematic Optimization (2026-04-06 to 2026-04-07)

### Config changes (17 settings modified)

| Setting | Before | After | Rationale |
|---------|--------|-------|-----------|
| `web.backend` | brave | firecrawl | Free unlimited search via SearXNG |
| `fallback_providers` | empty | deepseek-chat | Auto-failover on MiniMax errors |
| `memory.provider` | empty | holographic | Trust scoring, entity graph, contradiction detection |
| `memory.memory_char_limit` | 2200 | 3000 | More room for multi-project context |
| `terminal.timeout` | 60s (.env override) | 600s | Long research tasks were timing out |
| `delegation.max_iterations` | 50 | 90 | Match main agent turns for deep research |
| `delegation.default_toolsets` | terminal,file,web | +skills | Subagents can now load skills |
| `auxiliary.vision` | auto/empty | gemini-2.5-flash-preview | MiniMax M2.7 has no vision support |
| `compression.summary_model` | gemini-3-flash | MiniMax-M2.7 | Eliminate external Google dependency |
| `stt.provider` | local/whisper-base | deepgram | Better Spanish, $200 free credit |
| `browser.camofox.managed_persistence` | false | true | Keep cookies across sessions |
| `browser.allow_private_urls` | false | true | Agents can browse localhost |
| `privacy.redact_pii` | false | true | Scrub personal data before API |
| `timezone` | empty | Europe/Madrid | Correct cron scheduling |
| `display.show_cost` | true | true | Track token spend |
| `skills.external_dirs` | empty | badass-skills repo | Shared skills across all profiles |
| Duplicate minimax provider | 2 entries | 1 entry | Config cleanup |

### API keys added
- `DEEPSEEK_API_KEY` — fallback LLM + MemOS MEMRADER
- `GEMINI_API_KEY` — vision + future image generation
- `DEEPGRAM_API_KEY` — STT with $200 free credit

### API keys cleaned
- `OPENROUTER_API_KEY=^[[B` — removed (corrupted terminal escape character)
- `FAL_KEY=efefeefef` — removed (placeholder)

### New cron jobs created
- **Daily System Health Audit** (7 AM, ∞ repeats) — checks Camofox, Firecrawl, SearXNG, MemOS
- **Weekly Session Cleanup** (Sun 3 AM) — prunes sessions older than 30 days
- **Nightly Trajectory Export** (3:30 AM) — exports sessions to JSONL for RL training data

### New plugin created
- **quality-monitor** (`~/.hermes/plugins/quality-monitor/`) — hooks into `post_tool_call`, logs all tool calls to `activity.jsonl`, captures quality scores to `quality.jsonl`, warns on low scores

### Profile configs updated
- `research-agent` and `email-marketing` profiles updated with all new settings (fallback, holographic memory, 3000 char limit, badass-skills external dir, 600s timeout, delegation with skills)
- SOUL.md for research-agent updated with SearXNG web stack info (replacing Brave references)

### Skills installed
- `nano-banana-2` from skills.sh — image generation via Gemini 3.1 Flash (inference.sh CLI)
- `infsh` CLI installed for Nano Banana

### Infrastructure deployed
- **Open WebUI** — Docker container on port 3001, connected to Hermes API server
- **Hermes API server** — enabled via `API_SERVER_ENABLED=true`, OpenAI-compatible at port 8642
- **Python library** — `hermes_lib.py` created with `hermes_chat()`, `hermes_research()`, `hermes_email()`, `dispatch_to_hermes()`, and `hermes_api_chat()` functions

### GitHub repos
- **sergiocoding96/hermes-deploy** (private) — created and pushed. Contains config.yaml, .env.template, profiles, plugins, setup scripts, SearXNG settings, install.sh, hermes_lib.py, ARCHITECTURE.md
- **sergiocoding96/badass-skills** — cloned locally, linked as external_dirs in all profiles

---

## Phase 4: Knowledge Transfer (2026-04-07)

### 27 user questions answered comprehensively
Key topics covered:
1. **Skills Hub** — marketplace for installing community skills from skills.sh, GitHub, well-known endpoints
2. **SearXNG language handling** — `default_lang: auto` serves multilingual queries correctly; disabling engines would hurt coverage without meaningful quality gain
3. **Plugin vs Skill** — skill = markdown instructions the LLM reads (uses tokens); plugin = Python code that runs silently (zero tokens, adds tools/hooks)
4. **Profile isolation** — each profile gets own memory, config, SOUL.md; improvements don't spill over; shared skills via external_dirs
5. **MiniMax vision** — M2.7 has no vision model; Gemini 2.5 Flash used as auxiliary
6. **RL training value** — collect trajectories now (free), fine-tune later; eliminates API dependency, model learns YOUR specific workflows
7. **Holographic vs MemOS** — complementary: Holographic for per-agent local facts with trust scoring, MemOS for cross-agent shared knowledge with vector search

---

## Key Architectural Decisions

### 1. SearXNG over Brave
Free, unlimited, multi-engine. Brave credits exhausted too fast for agentic workloads. SearXNG's cross-engine scoring provides natural quality ranking. Trade-off: occasional noise from engine disagreement.

### 2. MiniMax for compression instead of Gemini
Eliminates external dependency. You're already paying for MiniMax tokens. Compression is summarization — M2.7 is good enough. No reason to add a second API dependency for a non-critical auxiliary task.

### 3. Holographic + MemOS (not either/or)
Holographic = agent's personal learning (trust, entities, contradictions, within-profile). MemOS = organizational knowledge (cross-agent, CEO reads all cubes). They serve different scopes and complement each other.

### 4. Profile isolation with shared skills
Memory isolated (agents don't leak context to each other). Skills shared (improvements propagate via external_dirs + GitHub repo). This mirrors how human teams work: private notes, shared playbooks.

### 5. Trajectory collection without immediate RL
Zero cost to collect. High cost not to have when needed. Every session is potential training data for a future fine-tuned model that knows your exact research methodology.

---

## Score Progression

```
Start of session:   ████████████████████████░░░░░░░░░░░░░░░░  5.2/10
After optimization: ██████████████████████████████████████░░░  7.3/10
                                                        ▲
                                                   +2.1 improvement
```

### Remaining gaps for 8.0+
- Webhooks (0/10) — GitHub PR auto-review
- MCP (0/10) — external tool servers
- MemOS integration (6/10) — needs native plugin
- Discord/WhatsApp messaging — planned

---

## Files Modified

### Config files
- `~/.hermes/config.yaml` — 17 settings changed
- `~/.hermes/.env` — 3 keys added, 2 removed, 1 timeout fixed
- `~/.hermes/profiles/research-agent/config.yaml` — full rewrite with optimizations
- `~/.hermes/profiles/email-marketing/config.yaml` — full rewrite with optimizations
- `~/.hermes/profiles/research-agent/SOUL.md` — web stack section updated
- `~/.openclaw/workspace/firecrawl/.env` — added SEARXNG_ENDPOINT
- `~/.openclaw/workspace/firecrawl/docker-compose.yaml` — added SearXNG service
- `~/.openclaw/workspace/firecrawl/searxng-settings.yml` — created (lang: auto)

### New files created
- `~/Coding/Hermes/setup-web-stack.sh` — bootstrap script for Firecrawl + SearXNG + Camofox
- `~/Coding/Hermes/hermes_lib.py` — Python library wrapper for programmatic access
- `~/Coding/Hermes/HERMES-SETUP-AUDIT-2026-04-06.md` — full 34-area feature audit
- `~/Coding/Hermes/HERMES-SETUP-AUDIT-2026-04-06.pdf` — formatted PDF of audit
- `~/.hermes/plugins/quality-monitor/plugin.yaml` — plugin manifest
- `~/.hermes/plugins/quality-monitor/__init__.py` — quality monitoring code
- `~/.config/systemd/user/camofox.service` — systemd service for Camofox

### Repos created/updated
- `sergiocoding96/hermes-deploy` — created (private), pushed with all configs
- `sergiocoding96/badass-skills` — cloned locally, linked in all profiles
- `~/Coding/Hermes` — README.md rewritten with full architecture documentation
