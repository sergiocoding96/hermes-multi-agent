# Hermes Agent — Full Feature Audit & Setup Rating

**Date:** 2026-04-06
**Version:** Hermes Agent v0.7.0 (121 commits behind)
**User:** Sergio Palacio
**System:** Ubuntu 24.04, Node v25.8.2, Python 3.12
**Model:** MiniMax M2.7 via minimax provider

---

## Scoring Key

| Score | Meaning |
|-------|---------|
| 9-10 | Excellent — fully configured, actively used, optimized |
| 7-8 | Good — working, minor improvements possible |
| 5-6 | Partial — configured but gaps or issues |
| 3-4 | Minimal — barely set up or partially broken |
| 1-2 | Present but unused or broken |
| 0 | Feature exists in Hermes but completely untouched |

**Importance** is rated specifically for Sergio's use case (multi-agent research system, Paperclip CEO + Hermes workers + MemOS, email marketing agent, real estate research).

---

## TIER 1 — CRITICAL (Core to your multi-agent system)

### 1. Skills System
**Score: 9/10** | **Importance: ★★★★★**

| What you have | What's missing |
|---------------|----------------|
| ~90+ skills across 30 categories | `skills.external_dirs: []` — no shared skill dir |
| 15 research skills (academic, code, social, market, HN, reddit, arxiv, polymarket) | Not using Skills Hub (`hermes skills browse`) |
| Custom research-coordinator with multi-stream synthesis | No well-known endpoint discovery |
| Agent can create/patch/delete skills via `skill_manage` | |
| Progressive disclosure (L0→L1→L2) working | |

**Your use case:** The research-coordinator orchestrates 5 specialized sub-researchers in parallel. Skills ARE your agent's brain. When you create `hermes-deploy`, the skills directory is the most valuable asset to version-control.

**Quick wins:**
- Set `skills.external_dirs: ["~/.agents/skills"]` for cross-tool sharing
- Run `hermes skills browse --source official` to see what you're missing
- Run `hermes skills check` to see if installed hub skills have updates

---

### 2. Web Search & Scraping (Firecrawl + SearXNG)
**Score: 8/10** | **Importance: ★★★★★**

| What you have | What's missing |
|---------------|----------------|
| Firecrawl at localhost:3002 (scrape + search + Playwright) | Firecrawl API occasionally needs restart |
| SearXNG at localhost:8888 (Google+Bing+DDG+Startpage, free, unlimited) | No health monitoring / auto-restart |
| `web.backend: firecrawl` in config | SearXNG occasionally returns noise (zhihu.com for English queries) |
| Docker-compose with all services | Could tune SearXNG engine weights |
| @reboot cron for persistence | |

**Your use case:** Every research agent runs `web_search()` and `web_extract()` dozens of times per research brief. This is the backbone of your autoresearch pipeline. The switch from Brave ($5/month burned in 6 days) to SearXNG saves you from being dead in the water mid-month.

**Quick wins:**
- Add a SearXNG health check to your cron or a simple watchdog script
- Tune `searxng-settings.yml` to disable engines that return non-English results for English queries

---

### 3. Browser / Anti-Bot (Camofox)
**Score: 9/10** | **Importance: ★★★★★**

| What you have | What's missing |
|---------------|----------------|
| Camofox (Camoufox Firefox fork) at localhost:9377 | `managed_persistence: false` — no cross-session cookies/logins |
| C++ fingerprint spoofing, bypasses Cloudflare | `allow_private_urls: false` — blocks localhost browsing |
| Tested and proven on Idealista | No VNC setup for visual debugging |
| Accessibility tree snapshots for agent interaction | |
| systemd user service + @reboot cron | |

**Your use case:** Idealista, real estate portals, any Cloudflare-protected site. Your agents can navigate, click, scroll, and extract data from anti-bot sites. This is a major competitive advantage for your research agents vs. simple API-based scrapers.

**Quick wins:**
- Set `browser.camofox.managed_persistence: true` to keep cookies across sessions (skip cookie banners on revisits)
- Set `browser.allow_private_urls: true` if you need agents to browse localhost services

---

### 4. Delegation (Sub-agents)
**Score: 6/10** | **Importance: ★★★★★**

| What you have | What's missing |
|---------------|----------------|
| `delegate_task` and `sessions_spawn` working | No dedicated delegation model (subagents use MiniMax M2.7) |
| Up to 3 concurrent subagents | No dedicated delegation provider |
| Default toolsets: terminal, file, web | Could set a cheaper model for simple subtasks |
| Research-coordinator uses parallel dispatch | Max iterations: 50 (may be low for deep research) |

**Your use case:** This is HOW your CEO dispatches work to Hermes workers. The research-coordinator spawns 3 sub-researchers in batch 1, then 2 more in batch 2. Every research brief depends on delegation working well.

**Quick wins:**
- Set `delegation.model` and `delegation.provider` to a cheaper/faster model for simple subtasks (saves tokens on your main MiniMax budget)
- Increase `delegation.max_iterations` to 90 to match your main `agent.max_turns`

---

### 5. Memory (Built-in)
**Score: 7/10** | **Importance: ★★★★★**

| What you have | What's missing |
|---------------|----------------|
| MEMORY.md populated (environment, projects, infra) | No external memory provider |
| USER.md populated (Sergio, preferences, timezone) | Memory is shared across ALL platforms — no per-agent isolation |
| Session search via SQLite FTS5 | `memory_char_limit: 2200` may be tight for multi-project context |
| Auto-flush after 6 turns | |
| Nudge every 10 turns | |

**Your use case:** Memory is how Hermes knows who you are, what you're building, and what conventions to follow. It persists across CLI, Telegram, and cron sessions. The MemOS integration adds structured knowledge on top, but built-in memory is always the first thing in the system prompt.

**Quick wins:**
- Enable `holographic` memory provider (free, local, zero deps) — adds trust scoring, entity graph, contradiction detection ON TOP of MEMORY.md
- Consider raising `memory_char_limit` to 3000 if you find context getting crowded

---

### 6. Fallback & Resilience
**Score: 2/10** | **Importance: ★★★★★**

| What you have | What's missing |
|---------------|----------------|
| Single MiniMax M2.7 provider | No `fallback_model` — MiniMax down = everything dead |
| Single API key | No credential pools (no key rotation) |
| `fallback_providers: []` | No cross-provider failover |
| | OPENROUTER_API_KEY is corrupted (`[B`) |

**Your use case:** If MiniMax has an outage at 2 AM while your cron research job is running, it silently fails. Your Telegram bot stops responding. Your CEO can't dispatch. Everything stops. For a system that should be autonomous, this is the biggest risk.

**Quick wins:**
- Fix `OPENROUTER_API_KEY` in `.env` (it's a terminal escape character, not a real key)
- Add `fallback_model: { provider: openrouter, model: nousresearch/hermes-3-llama-3.1-70b }` to config.yaml
- Add a second MiniMax key via `hermes auth add minimax` for credential pool rotation

---

## TIER 2 — HIGH VALUE (Directly improves your agents)

### 7. Cron Jobs (Scheduled Tasks)
**Score: 7/10** | **Importance: ★★★★☆**

| What you have | What's missing |
|---------------|----------------|
| Multiple active cron jobs (visible in session_cron_* files) | `timezone: ''` — empty, may affect scheduling |
| Blogwatcher and periodic research running | No audit of which crons are still useful |
| Jobs can attach skills, deliver to Telegram | Cron sessions can't create more crons (by design) |

**Your use case:** Your daily briefing bot, blogwatcher, and periodic research runs. Crons are how your system generates value while you sleep. The autoresearch hard loop (score < threshold → auto-patch → re-run) would be implemented as a cron.

**Quick wins:**
- Set `timezone: "Europe/Madrid"` (or your actual TZ) in config.yaml
- Run `hermes cron list` and clean up stale jobs

---

### 8. Messaging (Telegram)
**Score: 7/10** | **Importance: ★★★★☆**

| What you have | What's missing |
|---------------|----------------|
| Telegram fully working (bot token, allowed_users, home_channel) | Not using `hermes gateway install` (proper systemd) |
| Auto-thread enabled | Discord partially configured but no token |
| DM pairing working | WhatsApp, Slack, Signal all unconfigured |
| 32 Telegram sessions | Home Assistant integration unused |
| Cron results delivered to Telegram | |

**Your use case:** Telegram is your primary interface to Hermes when not at the terminal. Research briefs, cron results, alerts all come through here. The gateway needs to be rock-solid.

**Quick wins:**
- Run `hermes gateway install` to get a proper systemd service instead of ad-hoc process management
- Remove unused platform entries from `platform_toolsets` to reduce config noise

---

### 9. Profiles (Multi-Agent Personas)
**Score: 3/10** | **Importance: ★★★★☆**

| What you have | What's missing |
|---------------|----------------|
| Single default profile | No research-agent profile |
| All agents share same memory/config | No email-marketing-agent profile |
| | No per-profile memory isolation |
| | No per-profile SOUL.md customization |

**Your use case:** You have conceptually distinct agents (research, email-marketing, CEO) but they all run as the same Hermes profile. Profiles would give each agent its own MEMORY.md, USER.md, config overrides, and SOUL.md personality. The research agent shouldn't know about email marketing, and vice versa.

**Quick wins:**
- `hermes profile create research-agent --clone` — isolated memory + config for research
- `hermes profile create email-marketing --clone` — isolated for plusvibe work
- Each profile gets its own `$HERMES_HOME` directory

---

### 10. Context Files (CLAUDE.md / SOUL.md / AGENTS.md)
**Score: 8/10** | **Importance: ★★★★☆**

| What you have | What's missing |
|---------------|----------------|
| CLAUDE.md well-maintained, updated today | No SOUL.md (agent identity/personality file) |
| Documents architecture, web stack, MemOS, commands | No AGENTS.md |
| Firecrawl, SearXNG, Camofox all documented | |

**Your use case:** CLAUDE.md is loaded into every session that touches this project directory. It's how any AI assistant (Claude Code, Hermes) knows your system architecture. Adding SOUL.md would define Hermes's personality and role at the system prompt level.

**Quick wins:**
- Create `SOUL.md` with your agent's identity: "You are a research agent specialized in multi-domain intelligence gathering..."
- Consider `AGENTS.md` for multi-agent coordination rules

---

### 11. Compression & Context Management
**Score: 8/10** | **Importance: ★★★★☆**

| What you have | What's missing |
|---------------|----------------|
| Enabled, threshold 0.5, target 0.2 | External dependency on Google (gemini-3-flash-preview) |
| Protect last 20 messages | No local compression model fallback |
| Summary model: gemini-3-flash-preview | |
| Iterative re-compression (updates summaries across compressions) | |

**Your use case:** Research sessions can be VERY long (90 turns). Compression keeps the context window manageable. The Gemini Flash model summarizes old context into structured summaries. Without this, deep research sessions would hit context limits and crash.

**Quick wins:**
- Consider setting a local compression model as fallback in case Google API goes down
- Your settings are well-tuned, no immediate changes needed

---

### 12. Memory (MemOS Integration)
**Score: 6/10** | **Importance: ★★★★☆**

| What you have | What's missing |
|---------------|----------------|
| MemOS architecture fully understood | Dual-write (Hermes → MemOS) not automated |
| Provisioning script exists (`setup-memos-agents.py`) | MemOS not confirmed running right now |
| DeepSeek MEMRADER configured | No native Hermes memory provider plugin for MemOS |
| Local embedder (all-MiniLM-L6-v2) | Skills must manually chunk output for MemOS |

**Your use case:** MemOS is your structured knowledge layer — MemCubes per agent, CEO with CompositeCubeView sees all. This is the long-term memory that survives beyond MEMORY.md's 2200-char limit. The gap is that it's manual/skill-based, not a native Hermes memory provider.

**Quick wins:**
- Verify MemOS is running: `curl -s localhost:8001/health`
- Consider building a MemOS Hermes plugin (the plugin system supports this)
- Or use the existing Holographic provider for local memory while MemOS handles cross-agent knowledge

---

## TIER 3 — MEDIUM VALUE (Would improve quality of life)

### 13. Hooks (Event Handlers)
**Score: 2/10** | **Importance: ★★★☆☆**

| What you have | What's missing |
|---------------|----------------|
| Nothing | Gateway hooks for logging, alerts, webhooks |
| | Plugin hooks for tool interception, metrics, guardrails |
| | Could log all agent activity to a file |
| | Could send Telegram alerts on errors |

**Your use case:** Your autoresearch hard loop needs to know when a research run scores below threshold. A hook on `agent:end` could check the quality_score and trigger auto-patching. Without hooks, you can't close the feedback loop automatically.

**Quick wins:**
- Create `~/.hermes/hooks/activity-logger/` with a simple HOOK.yaml + handler.py that logs all agent steps
- Create a quality-score hook that triggers re-runs when score < threshold

---

### 14. Plugins
**Score: 2/10** | **Importance: ★★★☆☆**

| What you have | What's missing |
|---------------|----------------|
| Nothing | Custom tools via `ctx.register_tool()` |
| | Custom hooks via `ctx.register_hook()` |
| | CLI command extensions |
| | Message injection |

**Your use case:** A MemOS plugin could register `memos_store`, `memos_search`, `memos_query` as native Hermes tools — making MemOS a first-class citizen instead of a manual skill integration. A quality-score plugin could automatically evaluate research output.

**Quick wins:**
- Create a minimal MemOS plugin at `~/.hermes/plugins/memos/` that wraps MemOS REST API as Hermes tools

---

### 15. Webhooks
**Score: 0/10** | **Importance: ★★★☆☆**

| What you have | What's missing |
|---------------|----------------|
| Nothing | GitHub PR auto-review routes |
| | GitLab MR routes |
| | Event-driven agent activation |
| | `hermes webhook subscribe` for dynamic routes |

**Your use case:** When someone opens a PR on your repos, Hermes could auto-review it using the `github-code-review` skill you already have installed. Results posted as PR comments. Could also trigger research when specific events happen.

**Quick wins:**
- `hermes webhook subscribe github-pr --events "pull_request" --prompt "Review this PR" --skills github-code-review --deliver github_comment`

---

### 16. Security
**Score: 5/10** | **Importance: ★★★☆☆**

| What you have | What's missing |
|---------------|----------------|
| `redact_secrets: true` | `redact_pii: false` |
| Tirith policy engine enabled (fail_open) | Website blocklist disabled |
| Manual approval mode | FAL_KEY is placeholder (`efefeefef`) |
| Memory injection scanning | OPENROUTER_API_KEY corrupted (`[B`) |
| | Telegram bot token in plaintext .env |

**Your use case:** You're security-conscious (require audit before skill installs). But your .env has corrupted keys that could cause confusing errors, and PII redaction is off. For a system that handles research data and potentially personal information, this matters.

**Quick wins:**
- Fix or remove `OPENROUTER_API_KEY=[B` and `FAL_KEY=efefeefef`
- Set `redact_pii: true`
- Run `hermes doctor` to catch other config issues

---

### 17. MCP (Model Context Protocol)
**Score: 0/10** | **Importance: ★★★☆☆**

| What you have | What's missing |
|---------------|----------------|
| Nothing | No `mcp_servers` in config.yaml |
| | Could connect GitHub, Notion, databases, etc. as tools |
| | Per-server tool filtering available |
| | Both stdio and HTTP transport supported |

**Your use case:** MCP could expose your Notion workspace, GitHub repos, or MemOS as native tools without writing plugins. If you use Notion for project management, an MCP server would let Hermes read/write Notion pages directly.

**Quick wins:**
- Add the filesystem MCP server for project access
- Add the GitHub MCP server if you want agent-driven repo management

---

### 18. Voice / TTS / STT
**Score: 7/10** | **Importance: ★★★☆☆**

| What you have | What's missing |
|---------------|----------------|
| Edge TTS (free, Microsoft) | Auto-TTS disabled |
| Local Whisper STT (base model) | Could upgrade Whisper to medium/large for Spanish |
| Voice recording via ctrl+b | |
| en-US-MichelleNeural voice | Not using Spanish voice despite being Spanish-speaking |

**Your use case:** You use voice-to-text input (observed speech-to-text artifacts in messages). The STT is important for your workflow. Edge TTS is fine for output. The Whisper base model may struggle with your Spanish — upgrading to medium would help.

**Quick wins:**
- Change STT model to `medium` for better Spanish transcription: `stt.local.model: medium`
- Consider adding a Spanish voice for TTS: `es-ES-ElviraNeural`

---

### 19. Checkpoints & Rollback
**Score: 8/10** | **Importance: ★★★☆☆**

| What you have | What's missing |
|---------------|----------------|
| Enabled, max 50 snapshots | Nothing major |
| `/rollback` available in sessions | |
| Automatic snapshots before file changes | |

**Your use case:** Safety net when agents modify files. If a skill patch goes wrong, you can roll back. Works well, no changes needed.

---

### 20. Session Management
**Score: 7/10** | **Importance: ★★★☆☆**

| What you have | What's missing |
|---------------|----------------|
| 147 sessions stored | No regular session pruning |
| Reset mode: both (idle + time-based) | |
| 24h idle timeout, reset at 4 AM | |
| Group sessions per user | |
| SQLite FTS5 session search | |

**Your use case:** Sessions accumulate over time. The FTS5 search lets you find past conversations. The 4 AM reset clears stale sessions.

**Quick wins:**
- Periodically run `hermes sessions prune` to clean old sessions

---

## TIER 4 — NICE TO HAVE (Lower priority for your use case)

### 21. Provider Routing
**Score: 3/10** | **Importance: ★★☆☆☆**

| What you have | What's missing |
|---------------|----------------|
| Using MiniMax directly (not OpenRouter) | Provider routing only works with OpenRouter |
| No sort/whitelist/blacklist config | If you switch to OpenRouter, you could optimize for cost/speed |
| Duplicate minimax entry in custom_providers | |

**Your use case:** Not relevant unless you move to OpenRouter as your primary provider. If you did, you could route simple queries to cheap models and complex ones to Claude.

---

### 22. Credential Pools
**Score: 1/10** | **Importance: ★★☆☆☆**

| What you have | What's missing |
|---------------|----------------|
| Single MiniMax key | No key rotation |
| `fill_first` strategy (fine for 1 key) | No automatic failover on rate limits |

**Your use case:** If you're hitting MiniMax rate limits during heavy research runs, adding a second key would let Hermes auto-rotate. Low priority if you're not hitting limits.

---

### 23. Personality / SOUL.md
**Score: 7/10** | **Importance: ★★☆☆☆**

| What you have | What's missing |
|---------------|----------------|
| 13 personalities defined | No SOUL.md identity file |
| Active: kawaii | Personality is cosmetic, not functional |
| | Per-profile SOUL.md would specialize agent behavior |

**Your use case:** Kawaii is fun but doesn't help research quality. A research-agent SOUL.md could enforce "always cite sources, always include confidence levels, always structure output as briefs" at the identity level.

---

### 24. Vision
**Score: 4/10** | **Importance: ★★☆☆☆**

| What you have | What's missing |
|---------------|----------------|
| Provider: auto (resolves from main model) | No dedicated vision model configured |
| Camofox supports `browser_vision` (screenshot + AI analysis) | All auxiliary vision settings empty |

**Your use case:** Vision matters when Camofox encounters pages that need visual analysis (CAPTCHAs, image-heavy real estate listings). The auto provider works if MiniMax supports vision; otherwise you need a dedicated model.

---

### 25. Code Execution
**Score: 7/10** | **Importance: ★★☆☆☆**

| What you have | What's missing |
|---------------|----------------|
| Enabled, timeout 300s, max 50 tool calls | Nothing major |
| Local backend | |
| `execute_code` tool available | |

**Your use case:** Agents use `execute_code` for data processing, PDF generation, and programmatic tool access. Works fine.

---

### 26. Image Generation
**Score: 1/10** | **Importance: ★☆☆☆☆**

| What you have | What's missing |
|---------------|----------------|
| `FAL_KEY=efefeefef` (placeholder) | Real FAL.ai API key |
| | Completely broken |

**Your use case:** Low priority. Research briefs don't need generated images. Fix or remove the fake key to stop potential error noise.

---

### 27. Python Library Mode
**Score: 0/10** | **Importance: ★★☆☆☆**

| What you have | What's missing |
|---------------|----------------|
| Nothing | `from run_agent import AIAgent` available but unused |
| | Could power FastAPI endpoints, CI/CD steps |
| | Could replace CLI invocations in Paperclip adapter |

**Your use case:** The Paperclip CEO could call Hermes workers as Python library calls instead of CLI subprocesses. More reliable, lower overhead, better error handling. Medium-term improvement for your architecture.

---

### 28. API Server Mode
**Score: 0/10** | **Importance: ★☆☆☆☆**

| What you have | What's missing |
|---------------|----------------|
| Nothing | `hermes serve` exposes OpenAI-compatible HTTP endpoint |
| | Could connect Open WebUI, LobeChat, LibreChat |

**Your use case:** Low priority unless you want a web UI for Hermes. You already have Telegram and CLI.

---

### 29. Skins & Themes
**Score: 5/10** | **Importance: ★☆☆☆☆**

| What you have | What's missing |
|---------------|----------------|
| Default skin | Custom branding |
| | Not important for functionality |

**Your use case:** Cosmetic. Skip.

---

### 30. RL Training
**Score: 0/10** | **Importance: ★☆☆☆☆**

| What you have | What's missing |
|---------------|----------------|
| Nothing | Atropos + Tinker pipeline available |
| | TerminalBench2, YC-Bench environments |
| | GRPO with LoRA training |

**Your use case:** Future potential — you could train a custom model on your research agent's successful trajectories. But this requires GPU infrastructure and is a separate project.

---

### 31. Batch Processing
**Score: 0/10** | **Importance: ★☆☆☆☆**

| What you have | What's missing |
|---------------|----------------|
| Nothing | Run prompts in bulk for training data |
| | ShareGPT-format trajectory output |

**Your use case:** Could generate training data from your research agent's sessions. Low priority.

---

### 32. ACP (IDE Integration)
**Score: 0/10** | **Importance: ★☆☆☆☆**

| What you have | What's missing |
|---------------|----------------|
| Nothing | VS Code / JetBrains integration |

**Your use case:** You use Claude Code in VS Code already. ACP would let you use Hermes inside VS Code too. Niche.

---

### 33. Git Worktrees
**Score: 0/10** | **Importance: ★☆☆☆☆**

| What you have | What's missing |
|---------------|----------------|
| Nothing | Isolated git worktrees for parallel coding tasks |

**Your use case:** Not relevant — your agents do research, not concurrent code changes.

---

### 34. Docker Deployment
**Score: 3/10** | **Importance: ★☆☆☆☆**

| What you have | What's missing |
|---------------|----------------|
| Docker image configured but unused (backend=local) | Not running Hermes in Docker |
| Firecrawl stack runs in Docker | |

**Your use case:** Only relevant when you create `hermes-deploy` for other machines. Local backend is fine for your setup.

---

## SUMMARY

### Overall Score: 5.2 / 10

### Score Distribution

```
9/10  ██████████████████ Skills, Browser/Camofox
8/10  ████████████████   Web Search, Context Files, Compression, Checkpoints
7/10  ██████████████     Memory (built-in), Cron, Telegram, Voice/TTS, Sessions, Code Exec, Personality
6/10  ████████████       Delegation, MemOS Integration
5/10  ██████████         Security, Skins
4/10  ████████           Vision
3/10  ██████             Profiles, Provider Routing, Docker
2/10  ████               Hooks, Plugins, Fallback/Resilience
1/10  ██                 Credential Pools, Image Gen
0/10                     Webhooks, MCP, Python Library, API Server, RL Training, Batch, ACP, Worktrees
```

### Priority Action Plan (ordered by impact × effort)

| # | Action | Impact | Effort | Fixes |
|---|--------|--------|--------|-------|
| 1 | Add `fallback_model` to config.yaml | ★★★★★ | 1 min | Resilience (2→5) |
| 2 | Fix corrupted keys in .env | ★★★★ | 2 min | Security (5→6) |
| 3 | Run `hermes gateway install` | ★★★★ | 2 min | Telegram (7→8) |
| 4 | Enable holographic memory provider | ★★★★ | 1 min | Memory (7→8) |
| 5 | Create research-agent profile | ★★★★ | 5 min | Profiles (3→6) |
| 6 | Set timezone in config | ★★★ | 30 sec | Cron (7→8) |
| 7 | Create activity-logger hook | ★★★ | 10 min | Hooks (2→5) |
| 8 | Create MemOS plugin | ★★★★ | 30 min | Plugins (2→6), MemOS (6→8) |
| 9 | Set up GitHub webhook route | ★★★ | 10 min | Webhooks (0→5) |
| 10 | Upgrade Whisper STT to medium | ★★ | 1 min | Voice (7→8) |
| 11 | Set `redact_pii: true` | ★★ | 30 sec | Security (5→6) |
| 12 | Update Hermes (121 commits behind) | ★★★ | 5 min | Everything |
