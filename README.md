# Hermes Multi-Agent Research System

Layered multi-agent research and execution architecture using **Paperclip + Hermes + MemOS** with autoresearch-style self-improving feedback loops.

## What This Is

A self-improving multi-agent system where:
- **CEO agent (Claude Opus 4.6)** orchestrates via Paperclip, with access to all agent memories
- **Specialized Hermes agents** (research, email, marketing, etc.) each with isolated MemOS memory cubes
- **Two feedback loops**: soft (user feedback → skill patches) + hard (Karpathy-style metric threshold → auto-patch → re-run)
- **Skills evolve** from execution history — every failed or suboptimal run improves the skill for next time

## Architecture

```
CEO (Claude Opus 4.6, Paperclip)
  └── issues ONE task → Hermes Worker (via hermes-paperclip-adapter)
          └── hermes chat -q "..." --resume {session_id}
                  └── sessions_spawn(≤3 parallel domain researchers)
                          └── writes to Hermes MEMORY.md + MemOS cube
                                  └── CEO searches all cubes for synthesis
```

Token burn prevention: agents communicate **only via MemOS shared state**, never agent-to-agent.

## Research Skills

| Skill | Purpose |
|-------|---------|
| [`research-coordinator`](skills/research-coordinator/SKILL.md) | Master orchestration — decomposes query into parallel streams, synthesizes intelligence brief |
| [`social-media-researcher`](skills/social-media-researcher/SKILL.md) | X/Twitter, YouTube, Reddit coverage |
| [`code-researcher`](skills/code-researcher/SKILL.md) | GitHub and Hugging Face ecosystem |
| [`academic-researcher`](skills/academic-researcher/SKILL.md) | arXiv papers, Hacker News technical discourse |
| [`market-intelligence-researcher`](skills/market-intelligence-researcher/SKILL.md) | Polymarket prediction markets + news |
| [`hn-research`](skills/hn-research/SKILL.md) | Hacker News thread discovery and extraction |
| [`web-research`](skills/web-research/SKILL.md) | General web with domain routing rules |

## Key Infrastructure

- **Hermes Agent** (MiniMax M2.7 default) — [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
- **Paperclip connector** — [NousResearch/hermes-paperclip-adapter](https://github.com/NousResearch/hermes-paperclip-adapter)
- **Firecrawl** (self-hosted at `localhost:3002`) — web scraping backbone
- **MemOS** — [MemTensor/MemOS](https://github.com/MemTensor/MemOS) — multi-agent memory with isolated cubes per agent

## Critical Configuration

```env
# ~/.hermes/.env
FIRECRAWL_API_URL=http://localhost:3002   # REQUIRED — without this all web_extract calls fail
```

```env
# firecrawl/.env
NUM_WORKERS_PER_QUEUE=4      # DO NOT set above 4 — causes CPU stall
MAX_CONCURRENT_JOBS=8
```

## Domain Routing Rules (baked into skills)

| Domain | Rule |
|--------|------|
| `reddit.com` | Always rewrite to `old.reddit.com` — www returns JS shell (0 chars) |
| `github.com` | Basic Firecrawl only — Playwright/mobile flags trigger GitHub block |
| `raw.githubusercontent.com` | Best for raw file content |
| Brave search | Max 3 parallel calls — rate limit ~10 req/min |

## Self-Improving Feedback Loops

### Soft Loop (subjective)
Your feedback → CEO interprets → `skill_manage(patch)` → skill updated for next run

### Hard Loop (Karpathy-style)
```
quality_score = source_count(25%) + domain_coverage(25%) + freshness(20%) + depth(20%) + zero_result_penalty(10%)
If score < threshold → CEO patches weakest stream → re-run → keep if improved, revert if not
```

Inspired by [karpathy/autoresearch](https://github.com/karpathy/autoresearch) (65k stars) — the same "define one metric, atomic change, keep if better, revert if not" loop applied to skills instead of ML training.

## MemOS Multi-Agent Memory Model

```python
# Each agent gets an isolated cube; CEO sees all
mos.create_user(user_id="ceo", role=UserRole.ROOT)           # ROOT sees all cubes
mos.create_user(user_id="research-agent", role=UserRole.USER) # USER sees own cube only
mos.create_cube_for_user(cube_name="research-cube", owner_id="research-agent")
mos.share_cube_with_user(cube_id="research-cube", target_user_id="ceo")
```

## Project State

Full session report (architecture, current state, next steps, all learnings): [`PROJECT-STATE-2026-04-05.md`](PROJECT-STATE-2026-04-05.md)

## Next Steps

1. Install `hermes-paperclip-adapter` in Paperclip adapter registry
2. Write MemOS provisioning script (users + cubes + CEO shares)
3. Add `quality_score` self-eval to `research-coordinator` skill
4. Add MemOS dual-write (`POST /add`) to skill output step
5. Add soft feedback handler to CEO `HEARTBEAT.md`
