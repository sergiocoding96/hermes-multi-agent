# Project State Report: Paperclip + Hermes + MemOS Multi-Agent System
**Date:** April 5, 2026  
**Session:** Context-limit recovery document — contains everything needed to resume on any system  
**Author:** Claude Sonnet 4.6 (claude-code) synthesizing the full session

---

## Table of Contents
1. [Project Objective](#1-project-objective)
2. [Architecture Overview](#2-architecture-overview)
3. [Current State](#3-current-state)
4. [Infrastructure Configuration](#4-infrastructure-configuration)
5. [Skills Created](#5-skills-created)
6. [Key Technical Learnings](#6-key-technical-learnings)
7. [Karpathy Autoresearch — Full Summary](#7-karpathy-autoresearch--full-summary)
8. [MemOS Architecture — Full Summary](#8-memos-architecture--full-summary)
9. [Hermes Memory System — Full Summary](#9-hermes-memory-system--full-summary)
10. [Paperclip ↔ Hermes Connector](#10-paperclip--hermes-connector)
11. [The Two Feedback Loops](#11-the-two-feedback-loops)
12. [Next Steps (Ordered)](#12-next-steps-ordered)
13. [Open Questions](#13-open-questions)

---

## 1. Project Objective

Build a **layered multi-agent research and execution system** with self-improving feedback loops:

- **Many specialized Hermes agents** (research, email, marketing, code, etc.) each with isolated memory
- **CEO agent (Claude Opus 4.6)** as the top-level orchestrator with access to all agent memories
- **Dual memory system**: Hermes internal memory (operational) + MemOS (structured knowledge, cross-agent sharing)
- **Two feedback loops**:
  - **Soft loop**: User feedback → CEO interprets → skill patches → better next run
  - **Hard loop**: Karpathy autoresearch style — metric threshold → keep if improved, revert if not → automatic
- **Self-improving skills**: After every task, skills are evaluated and upgraded based on execution evidence

The guiding insight from Karpathy's autoresearch: *Define one metric, make one atomic change, verify, keep if improved, revert if not, repeat forever.* This pattern generalizes beyond ML training to any domain with a measurable objective — including the skills themselves.

---

## 2. Architecture Overview

```
YOU
  │ task + feedback
  ▼
CEO (Claude Opus 4.6, Paperclip)
  ├── Receives task, sets quality threshold (e.g. score ≥ 7.5/10)
  ├── Decomposes task into one delegation
  ├── Receives result + quality_score
  ├── Soft loop: interprets your feedback → patches skill via skill_manage
  └── Hard loop: if score < threshold → auto-patch → re-run → escalate
        │ one task via Paperclip issue queue
        ▼
HERMES WORKER AGENT (hermes-paperclip-adapter)
  adapterType: "hermes_local"
  model: MiniMax M2.7 (cheap, capable)
  persistSession: true
        │ spawns hermes chat -q "..." --resume {session_id}
        ▼
HERMES SESSION
  ├── Runs domain skill (e.g. research-coordinator)
  ├── sessions_spawn(≤3 parallel sub-researchers)
  ├── Computes quality_score
  ├── Writes to Hermes MEMORY.md (agent-private operational facts)
  ├── skill_manage(patch) if any skill failed or had routing errors
  └── POST /add → MemOS {user_id: "research-agent", cube_id: "research-cube"}
        │ dual-write
        ▼
MEMOS (Qdrant + Neo4j + SQLite, localhost:8001)
  ├── research-cube    → owned by research-agent (GeneralText + TreeText)
  ├── email-mkt-cube   → owned by email-marketing-agent (GeneralText + TreeText + PreferenceText)
  └── ceo-cube         → ROOT role, CompositeCubeView across ALL cubes
        │ CEO searches across all cubes via CompositeCubeView
        ▼
CEO retrieves cross-agent synthesis when needed:
  POST /product/search {user_id: "ceo", readable_cube_ids: ["research-cube", "email-mkt-cube", ...]}
```

**Key token-burn principle:** Paperclip agents communicate ONLY via MemOS (shared state), never agent-to-agent. CEO sends ONE task. Hermes handles all parallelism internally via `sessions_spawn`. No Paperclip orchestration overhead on sub-tasks.

---

## 3. Current State

### What Is Done ✅

| Item | Status | Location |
|------|--------|----------|
| research-coordinator skill | ✅ Created | `~/.hermes/skills/research/research-coordinator/SKILL.md` |
| social-media-researcher skill | ✅ Created | `~/.hermes/skills/research/social-media-researcher/SKILL.md` |
| code-researcher skill | ✅ Created | `~/.hermes/skills/research/code-researcher/SKILL.md` |
| academic-researcher skill | ✅ Created | `~/.hermes/skills/research/academic-researcher/SKILL.md` |
| market-intelligence-researcher skill | ✅ Created | `~/.hermes/skills/research/market-intelligence-researcher/SKILL.md` |
| hn-research skill | ✅ Created (simplified) | `~/.hermes/skills/research/hn-research/SKILL.md` |
| web-research skill (domain routing) | ✅ Modified | `~/.hermes/skills/openclaw-imports/web-research/SKILL.md` |
| Firecrawl env configured | ✅ Fixed | `~/.openclaw/workspace/firecrawl/.env` |
| FIRECRAWL_API_URL set | ✅ Fixed | `~/.hermes/.env` |
| Test research run completed | ✅ Done | 4 reports in `/tmp/` |
| Research PDF compiled | ✅ Done | `/home/openclaw/research-autoresearch-integration-2026-04-05.pdf` |
| hermes-paperclip-adapter discovered | ✅ Confirmed real | `NousResearch/hermes-paperclip-adapter` (599 stars) |
| MemOS installed locally | ✅ Exists | `/home/openclaw/Coding/MemOS/` |
| MemOS architecture fully understood | ✅ Researched | See section 8 |

### What Is NOT Done Yet ❌

| Item | Blocked on |
|------|-----------|
| hermes-paperclip-adapter installed in Paperclip | Needs adapter registry edit |
| MemOS user/cube provisioning script | Needs to be written |
| Dual-write (Hermes → MemOS) in skills | Needs MemOS POST /add added to skill |
| quality_score self-evaluation in coordinator | Needs to be added to skill |
| Soft feedback handler in CEO HEARTBEAT | Needs to be written |
| Hard feedback loop (score < threshold → repatch) | Needs to be added to CEO HEARTBEAT |
| X/Twitter credentials configured | User said ignore for now |

---

## 4. Infrastructure Configuration

### Firecrawl (self-hosted web scraper)
**Location:** `/home/openclaw/.openclaw/workspace/firecrawl/`  
**Running on:** `http://localhost:3002`  
**Config file:** `/home/openclaw/.openclaw/workspace/firecrawl/.env`

```env
PORT=3002
HOST=0.0.0.0
USE_DB_AUTHENTICATION=false
BULL_AUTH_KEY=sergio-local-firecrawl
MAX_CONCURRENT_JOBS=8
NUM_WORKERS_PER_QUEUE=4
CRAWL_CONCURRENT_REQUESTS=8
```

> **Critical:** `NUM_WORKERS_PER_QUEUE=4` is the correct value. Do NOT increase to 16+ — that caused 97% CPU / 87% RAM stall and worker stalls during a test run.

### Hermes Environment
**Config file:** `~/.hermes/.env`  
**Critical variable:**
```env
FIRECRAWL_API_URL=http://localhost:3002
```
> Without this, Hermes calls cloud Firecrawl (which times out with no API key). This was the root cause of all `web_extract` failures in the first two test runs.

### Hermes Model Config
**File:** `~/.hermes/config.yaml`
```yaml
model:
  default: MiniMax-M2.7
  provider: minimax
  base_url: https://api.minimax.io/anthropic
memory:
  memory_enabled: true
  memory_char_limit: 2200
  user_char_limit: 1375
```

### Paperclip
**Running on:** `http://tower.taila4a33f.ts.net:3100`  
**Database:** Embedded PostgreSQL on port 54329  
**Company ID:** `a5e49b0d-bd58-4239-b139-435046e9ab91`  
**CEO Agent ID:** `84a0aad9-5249-4fd6-a056-a9da9b4d1e01`  

### MemOS (local)
**Installed at:** `/home/openclaw/Coding/MemOS/`  
**Python package:** `memos` (installed at `~/.local/lib/python3.12/site-packages/memos`)  
**OpenClaw plugin:** `/home/openclaw/Coding/MemOS/apps/memos-local-openclaw/` (port 18799, OpenClaw-specific)  
**Python REST server port:** `http://localhost:8001`  
**Start command:** `cd /home/openclaw/Coding/MemOS && poetry run uvicorn memos.api.server_api:app --host 0.0.0.0 --port 8001`  
**Dependencies already running:** Neo4j (bolt://localhost:7687) + Qdrant (localhost:6333)  
**Config:** `/home/openclaw/Coding/MemOS/.env` — uses MiniMax M2.7 for LLM + embo-01 for embeddings, tree_text memory type with Neo4j backend

---

## 5. Skills Created

All skills live at `~/.hermes/skills/research/`. Each is a SKILL.md file that Hermes loads on demand.

### research-coordinator
**Path:** `~/.hermes/skills/research/research-coordinator/SKILL.md`  
**Role:** Master orchestration. Decomposes any query into parallel domain streams, spawns up to 3 parallel researcher subagents via `sessions_spawn()`, synthesizes a structured intelligence brief.  
**Key mechanism:** Two batches of `sessions_spawn()` (max 3 per batch, blocking). Batch 1 = top 3 priority streams. Batch 2 = remaining streams if needed.  
**Output:** Research Intelligence Brief with Executive Summary, Key Findings, Signal Matrix, Domain Reports, Source Index.

### social-media-researcher
**Path:** `~/.hermes/skills/research/social-media-researcher/SKILL.md`  
**Role:** Covers X/Twitter, YouTube, Reddit for a given query.  
**Critical fix:** Always rewrite `www.reddit.com` → `old.reddit.com`. www returns a JS shell (0 chars); old returns full HTML (~55K chars).  
**Sub-skills loaded:** `xitter`, `youtube-content`, `reddit-research`

### code-researcher
**Path:** `~/.hermes/skills/research/code-researcher/SKILL.md`  
**Role:** GitHub and Hugging Face ecosystem coverage.  
**Critical fix:** Never pass Playwright/mobile flags to GitHub — it detects and blocks them. Use `gh` CLI for structured data. Use `raw.githubusercontent.com` for file content.  
**Sub-skills loaded:** `github-research`, `huggingface-hub`

### academic-researcher
**Path:** `~/.hermes/skills/research/academic-researcher/SKILL.md`  
**Role:** arXiv paper discovery, Semantic Scholar citation analysis, Hacker News technical discourse.  
**Sub-skills loaded:** `arxiv`, `hn-research`

### market-intelligence-researcher
**Path:** `~/.hermes/skills/research/market-intelligence-researcher/SKILL.md`  
**Role:** Polymarket prediction markets + web news for probability-weighted context.  
**Sub-skills loaded:** `polymarket`, `web-research`

### hn-research
**Path:** `~/.hermes/skills/research/hn-research/SKILL.md`  
**Role:** Hacker News thread discovery and comment extraction.  
**Implementation:** Uses `web_search(query="site:news.ycombinator.com TOPIC")` + `web_extract()`. No Algolia API needed — the standard web stack works fine for HN.

### web-research (modified)
**Path:** `~/.hermes/skills/openclaw-imports/web-research/SKILL.md`  
**Key additions:**
- Domain routing table at top (GitHub → no Playwright, Reddit → old.reddit.com, etc.)
- Max 3 parallel `web_search()` calls — Brave rate-limits at ~10 req/min
- 15s backoff on rate limit errors

---

## 6. Key Technical Learnings

### Who does what in this system

| Agent | Role | Model | Persistent? |
|-------|------|-------|------------|
| You | Give tasks + feedback | — | — |
| CEO (Paperclip) | Orchestrate, delegate, feedback loop | Claude Opus 4.6 | ✅ Paperclip heartbeat |
| Hermes worker | Execute skills, research, code | MiniMax M2.7 | ✅ Session resume |
| Hermes subagents | Domain research (sessions_spawn) | MiniMax M2.7 | ❌ Ephemeral |
| Claude Code (me) | Debug, synthesize, write/patch files | Claude Sonnet 4.6 | ❌ Per-session |

### Hermes delegation limits (hard limits, not configurable)
- `sessions_spawn()`: max **3 parallel** subagents per call
- Depth limit: **2** (coordinator → researcher, researchers cannot spawn further subagents)
- Blocking: `sessions_spawn()` **blocks** until all spawned sessions complete
- Skills must be passed explicitly to subagents (they inherit nothing)

### The decisive factor in multi-agent success: grounding
From community research (r/LLMDevs, 155 upvotes):
> "The deciding factor wasn't the model, the framework, or the prompts — it was **grounding**"

Agents operating on hallucinated or stale state fail silently and confidently. Fix: shared state files + verification steps before each action.

### Stigmergy over direct messaging
From community research (r/LocalLLaMA):
- Agents leave state in shared environment (files, MemOS, git)
- Other agents read state and act — no direct message passing
- Claimed: **80% token reduction** vs explicit agent-to-agent communication
- More robust: agent failures don't cascade to communication failures

### Firecrawl worker scaling
- `NUM_WORKERS_PER_QUEUE=16` → **97% CPU, 87% RAM, worker stall** (catastrophic)
- `NUM_WORKERS_PER_QUEUE=4, MAX_CONCURRENT_JOBS=8` → stable, efficient

### Reddit URL routing
- `www.reddit.com` → Firecrawl gets JS shell, **0 usable chars**
- `old.reddit.com` → Firecrawl gets full HTML, **~55K usable chars**
- Always rewrite before any `web_extract()` call

### GitHub + Playwright = blocked
- GitHub detects Playwright user agent (and `mobile:true` flag)
- Basic Firecrawl works fine on GitHub
- For structured data, use `gh` CLI or GitHub REST API directly
- For raw file content, use `raw.githubusercontent.com`

### Brave search rate limiting
- ~10 requests/minute per session
- Max 3 `web_search()` calls in parallel
- 15-second backoff on rate limit errors
- Space out search batches — don't fire all at once

---

## 7. Karpathy Autoresearch — Full Summary

**Repository:** https://github.com/karpathy/autoresearch  
**Stars:** 65,685 | **Forks:** 9,392 | **Created:** March 2026  

### The Core Loop (from program.md lines 94–112)
```
LOOP FOREVER:
  1. Read git state (current branch/commit)
  2. Make ONE atomic change to train.py
  3. git commit
  4. Run: uv run train.py > run.log 2>&1  (5-minute budget)
  5. Extract: grep "^val_bpb:\|^peak_vram_mb:" run.log
  6. If crash → read traceback, fix, log crash
  7. Record to results.tsv
  8. If val_bpb IMPROVED → keep commit (advance branch)
  9. If val_bpb EQUAL/WORSE → git reset --hard HEAD~1
 10. REPEAT FOREVER (never pause to ask the human)
```

### The Three-File Architecture
```
prepare.py   — FIXED: data prep, evaluation (DO NOT MODIFY)
train.py     — MUTABLE: model, optimizer, training loop (agent modifies)
program.md   — Agent instructions / "skill file" (human edits strategy)
results.tsv  — Machine-readable experiment log
```

### Key Design Principles
- **Single mutable file**: Narrows agent action space, prevents scope creep
- **Fixed time budget** (5 min): Enables fair comparison
- **One metric** (val_bpb, lower is better): Unambiguous success/failure
- **Simplicity criterion**: "A 0.001 improvement from 20 lines of hacky code? Probably not worth it. A 0.001 improvement from deleting code? Definitely keep."
- **Git as experiment history**: Every kept change is a traceable commit

### Generalizing to Any Domain
The pattern applies to any domain with a mechanical metric:

| Domain | Metric | Mutable target |
|--------|--------|---------------|
| ML training | val_bpb (lower) | train.py |
| Test coverage | % lines covered | test suite |
| Bundle size | KB gzipped | webpack config |
| API response time | p95 latency ms | service code |
| Lighthouse score | 0–100 | HTML/CSS/JS |
| SQL performance | query execution ms | .sql files |
| Agent accuracy | eval score (higher) | prompt/skill files |
| CUDA throughput | TFLOPS (higher) | kernel code |

### The agenthub Branch (Multi-Agent Coordination)
Karpathy's own `origin/agenthub` branch provides a complete hub server:

```
REST API:
POST /api/register              — Agent registration
POST /api/git/push              — Push git bundle
GET  /api/git/fetch/<hash>      — Fetch specific commit
GET  /api/git/commits           — List recent commits
GET  /api/git/leaves            — Get frontier (uncommitted tips)
POST /api/channels/<name>/posts — Post to channel
GET  /api/channels/<name>/posts — Read channel

Channels:
#results    — Structured: "commit:a1b2c3 val_bpb:0.9932 | hypothesis"
#discussion — Freeform hypotheses, ideas, cross-agent conversation
```

### Key Forks

**darwin-derby** (github.com/kousun12/darwin-derby, 48 stars)
- Generalizes autoresearch to ANY domain with a scoring function
- Essay quality, website performance, TSP, agent prompts
- `derby init my-problem --direction minimize`
- Pattern: `problem.yaml` defines metric + direction

**autoresearch-at-home** (github.com/mutable-state-inc/autoresearch-at-home, 462 stars)
- SETI@home-style distributed swarm with claim/publish protocol
- `coord.claim_experiment(description)` — semantic dedup, race resolution
- `coord.publish_result(exp_key, val_bpb, ...)` — includes full train.py source
- Shared namespace: results/, claims/ (15-min TTL), best/, hypotheses/

**auto-agent** (github.com/alfonsograziano/auto-agent)
- Applies autoresearch to improving an AI agent's own code
- Two-repo architecture: orchestrator + target agent
- Files: `MEMORY.md` (accumulated learnings), `REPORT.md` (CONTINUE/ROLLBACK decision)

### Proven Results (from awesome-autoresearch)
| Domain | Result | Method |
|--------|--------|--------|
| LLM training | 20+ improvements overnight | Original |
| Shopify Liquid engine | 53% faster, 61% fewer allocations | 93 automated commits |
| CUDA kernels | 18 → 187 TFLOPS | autokernel variant |
| Voice agent prompts | 0.728 → 0.969 score | LLM-as-judge |
| RL post-training | 0.475 → 0.550 eval | Hyperparameter opt |
| Vesuvius scrolls | 2× cross-scroll generalization | 4-agent 24/7 swarm |

---

## 8. MemOS Architecture — Full Summary

**Repository:** https://github.com/MemTensor/MemOS  
**Local install:** `/home/openclaw/Coding/MemOS/`  
**arXiv paper:** 2507.03724  
**Status:** Already installed locally

### What MemOS Is

A Memory Operating System for LLMs — provides unified store/retrieve/manage for long-term memory across agents. Three memory planes:
- **ActivationMem**: KV cache (working context, ephemeral)
- **ParametricMem**: Model weights (fine-tuning, LoRA)
- **ExternalMem**: SQLite + vector store (what matters for us)

### The MemCube Model
Each agent gets one **MemCube** — an isolated memory container. A MemCube contains:
- `text_mem`: textual memories (hybrid FTS5 + vector search)
- `pref_mem`: preference/behavioral memories
- `act_mem`: activation memory (KV cache snapshots)
- `para_mem`: parametric memory (model adaptation)

### Memory Type Decisions (finalized April 5)

**Architecture:** MOS v2.0 — legacy `MOS` class deprecated. Use `Components + Handlers` with `SingleCubeView` (per agent) and `CompositeCubeView` (CEO reads all cubes, results include `cube_id` for source identification).

**Memory types per agent (all agents get GeneralText + TreeText):**

| Agent | `GeneralTextMemory` | `TreeTextMemory` | `PreferenceTextMemory` | MemReader Mode |
|-------|:---:|:---:|:---:|:---:|
| CEO | ✅ | ✅ | ❌ | Fine |
| research-agent | ✅ | ✅ | ❌ | Fine |
| email-marketing-agent | ✅ | ✅ | ✅ | Fine |

**Rationale:** MiniMax tokens are cheap. TreeText (Neo4j graph) gives vector + graph traversal search on every agent — strictly better recall. Fine MemReader mode uses LLM to extract structured facts/entities/metadata from every write. PreferenceText only on email-marketing (user communication style memory).

**MemReader modes:**
- **Fast mode**: No LLM call, just chunking + embedding. Millisecond latency. For operational/transient writes.
- **Fine mode**: LLM extracts structured facts, entities, confidence, metadata. Used for all agent writes since MiniMax is cheap.

**Scheduler:** Enabled, local queue (`DEFAULT_USE_REDIS_QUEUE=false`). Manages working memory → long-term memory flow. No Redis needed.

**Write mode:** `async_mode: "sync"` for all skill writes (confirmed write before CEO reads). `async` only for background bulk imports.

**Visibility:** `"private"` on all memory items. Access control at cube level via ACL.

### Multi-Agent Isolation Model
```python
# Role hierarchy
class UserRole(Enum):
    ROOT  = "ROOT"   # CEO — owns everything, sees all cubes
    ADMIN = "ADMIN"  # Team lead
    USER  = "USER"   # Worker agent — private cube only + explicit shares

# Access check (from user_manager.py)
def validate_user_cube_access(user_id, cube_id):
    # True if: user is owner OR user is in cube.users (many-to-many)
    return cube.owner_id == user_id or user in cube.users

# What search() does internally:
def search(query, user_id):
    accessible_cubes = user_manager.get_user_cubes(user_id)
    # Searches all accessible cubes in parallel (ThreadPoolExecutor)
    # Returns merged results from all cubes the user can access
```

### Infrastructure Requirements (VERIFIED)

MemOS Python server needs these services — **all already running locally:**
- **Neo4j** → `bolt://localhost:7687` ✅ (confirmed listening)
- **Qdrant** → `localhost:6333` ✅ (v1.17.1 confirmed running)
- **MiniMax API** → used for LLM + embeddings (configured in .env)

**Two separate MemOS systems — do NOT confuse them:**
1. **OpenClaw plugin** (`memos-local-openclaw`, port 18799) — SQLite-only, works with OpenClaw agents via plugin hooks. Already installed. Cannot receive arbitrary HTTP POSTs from Hermes.
2. **Python REST server** (port 8001) — full multi-user/multi-cube system with Qdrant+Neo4j. This is what Hermes skills call via `curl`. Needs to be started.

### Setup for Your Multi-Agent System

```python
# setup-memos-agents.py — run once to provision users and cubes
# Relies on the Python API, not the REST server

from memos.mem_os.main import MOS
from memos.mem_user.user_manager import UserRole
import os

os.chdir("/home/openclaw/Coding/MemOS")

mos = MOS.from_config(config)  # config loaded from .env

# Create users (one per Paperclip/Hermes agent)
mos.create_user(user_id="ceo",               role=UserRole.ROOT)
mos.create_user(user_id="research-agent",    role=UserRole.USER)
mos.create_user(user_id="email-agent",       role=UserRole.USER)
mos.create_user(user_id="marketing-agent",   role=UserRole.USER)
# Add more agents as needed — one user + one cube per agent

# Create isolated cubes (one per agent)
mos.create_cube_for_user(cube_name="research-cube",   owner_id="research-agent",  cube_id="research-cube")
mos.create_cube_for_user(cube_name="email-cube",       owner_id="email-agent",     cube_id="email-cube")
mos.create_cube_for_user(cube_name="marketing-cube",   owner_id="marketing-agent", cube_id="marketing-cube")
mos.create_cube_for_user(cube_name="ceo-cube",         owner_id="ceo",             cube_id="ceo-cube")

# Grant CEO read access to all agent cubes
mos.share_cube_with_user(cube_id="research-cube",   target_user_id="ceo")
mos.share_cube_with_user(cube_id="email-cube",       target_user_id="ceo")
mos.share_cube_with_user(cube_id="marketing-cube",   target_user_id="ceo")

# Result:
# research-agent → sees ONLY research-cube (isolated, private)
# email-agent    → sees ONLY email-cube (isolated, private)
# ceo (ROOT)     → sees ALL cubes in parallel search automatically
```

### REST API — Verified from OpenAPI spec + examples

**Server:** `http://localhost:8001`  
**All endpoints have `/product/` prefix**

```bash
# ⚠️ CRITICAL: mem_cube_id and memory_content are DEPRECATED.
# Use writable_cube_ids (list) and messages (list) instead.

# Write a memory from Hermes skill — use async_mode=sync to confirm write
curl -X POST http://localhost:8001/product/add \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "research-agent",
    "writable_cube_ids": ["research-cube"],
    "async_mode": "sync",
    "messages": [
      {
        "role": "assistant",
        "content": "KEY FINDING: autoresearch loop pattern — val_bpb metric, 5-min budget, git keep/revert"
      }
    ],
    "custom_tags": ["research", "autoresearch"],
    "info": {"source_type": "research_output", "task_id": "TASK_ID_HERE"}
  }'

# CEO cross-agent search — readable_cube_ids scopes the search
curl -X POST http://localhost:8001/product/search \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "ceo",
    "query": "what has the research agent found this week",
    "readable_cube_ids": ["research-cube", "email-cube", "marketing-cube"],
    "top_k": 10,
    "mode": "fast",
    "include_preference": false
  }'

# All endpoints:
POST /product/add           — write memory
POST /product/search        — vector+FTS5 search
POST /product/get_all       — list all memories for user/cube
POST /product/get_memory    — get specific memory by ID
POST /product/delete_memory — delete memory
POST /product/feedback      — rate memories up/down (improves future retrieval)
POST /product/chat/stream   — chat with memory injection (SSE stream)
POST /product/chat/complete — chat with memory injection (complete response)
GET  /product/scheduler/allstatus — monitor async add queue
```

**⚠️ Known issue (from docs/product-api-tests.md):** `/product/search` may return empty results if Qdrant indexes weren't created. They auto-create on restart — if search returns empty, restart the MemOS server once.

### Smart Deduplication (happens automatically on every write)
1. Exact content-hash check → skip if duplicate
2. Top-5 similar chunks (threshold 0.75) → LLM judge: DUPLICATE / UPDATE / NEW
3. UPDATE → merge summary + append content (tracks merge history)
4. NEW → chunk by semantic boundary, embed, index in FTS5 + vector

### Task → Skill Evolution Pipeline (automatic)
1. MemOS detects task boundary (2-hour idle OR explicit signal)
2. Rule filter: too few chunks / turns / trivial content → skip
3. LLM evaluates: "is this task worth distilling into a skill?"
4. If yes → multi-step LLM pipeline generates SKILL.md + scripts + evals
5. If similar task appears later → existing skill auto-upgraded (refine/extend/fix)
6. Quality scored 0–10; <6 = draft
7. Auto-install into workspace

### Memory Retrieval (injection into agent context)
- Injected via `before_agent_start` hook (invisible to user)
- **Hybrid search**: FTS5 keyword + vector semantic with RRF fusion
- **MMR diversity**: Maximal Marginal Relevance prevents near-duplicate results
- **Recency decay**: 14-day half-life biases toward recent memories
- **Query rewriting**: `get_query_rewrite()` rewrites query against chat history before searching

---

## 9. Hermes Memory System — Full Summary

**Source:** `/home/openclaw/.hermes/hermes-agent/`

### Four-Layer Architecture

```
Layer 1: MEMORY.md + USER.md (always in context)
  ~/.hermes/memories/MEMORY.md  — 2,200 char limit, agent's operational facts
  ~/.hermes/memories/USER.md    — 1,375 char limit, user profile
  Injected as frozen snapshot at session start (preserves prefix cache)
  Agent writes via memory(add/replace/remove) — immediate disk write, next session reads it

Layer 2: Session Database (unlimited, searchable)
  ~/.hermes/state.db (SQLite + FTS5)
  Every message from every session stored
  Searched via session_search tool when recalling past conversations
  Includes: cost tracking, model used, token counts, session chains

Layer 3: Memory Consolidation (daily auto-summary)
  ~/.hermes/memory_consolidation/YYYY-MM-DD.md
  Auto-generated after sessions: summarizes key findings, decisions, skill gaps
  Already running — reviewed all April 5 research sessions and wrote structured summary

Layer 4: External Provider (optional, ONE at a time)
  Options: Honcho, OpenViking, Mem0, Hindsight, Holographic, RetainDB, ByteRover
  Runs alongside built-in memory, never replaces it
  Config: memory.provider in ~/.hermes/config.yaml
  Currently: disabled (memory.provider: '')
```

### Skill Self-Management (agents CAN write their own skills)

```python
# Available actions in skill_manage tool:
skill_manage(action="create", name="my-skill", content="...")  # new SKILL.md
skill_manage(action="edit",   name="my-skill", content="...")  # full rewrite
skill_manage(action="patch",  name="my-skill", 
             file="SKILL.md",
             old="wrong instruction", 
             new="correct instruction")                         # targeted fix
skill_manage(action="delete", name="my-skill")

# Security scanning: agent-created skills get same scrutiny as hub installs
# Skills live at: ~/.hermes/skills/ (source of truth)
```

The system prompt guidance says:
> "After completing a complex task (5+ tool calls), save the approach as a skill. When using a skill and finding it outdated, patch it immediately — don't wait to be asked. Skills that aren't maintained become liabilities."

In practice, MiniMax M2.7 doesn't do this proactively — it must be explicitly told to in the skill instructions.

### Memory vs Session Search

| Feature | MEMORY.md | Session Search |
|---------|-----------|---------------|
| Capacity | ~1,300 tokens total | Unlimited |
| Speed | Instant (in system prompt) | Requires FTS5 + LLM summarization |
| Use case | Key facts always available | Finding specific past conversations |
| Management | Manually curated by agent | Automatic — all sessions stored |
| Token cost | Fixed per session | On-demand |

---

## 10. Paperclip ↔ Hermes Connector

**Repository:** https://github.com/NousResearch/hermes-paperclip-adapter  
**Stars:** 599 | **Updated:** 2026-04-05 (updated today — actively maintained)  
**License:** MIT

### What It Does

Runs Hermes as a native Paperclip agent. The adapter:
1. Spawns `hermes chat -q "..." -Q --resume {session_id}` as child process
2. Parses structured transcript into typed `TranscriptEntry` objects (tool cards with status icons)
3. Post-processes Hermes ASCII formatting into clean GFM markdown
4. Reclassifies benign stderr (MCP init, structured logs) as non-errors
5. Tags sessions as `tool` source (separate from interactive history)
6. Reports results back to Paperclip with cost, usage, session state

### Adapter Config (per agent in Paperclip UI)

```json
{
  "name": "Research Agent",
  "adapterType": "hermes_local",
  "adapterConfig": {
    "model": "minimax/MiniMax-M2.7",
    "maxIterations": 50,
    "timeoutSec": 600,
    "persistSession": true,
    "enabledToolsets": ["terminal", "file", "web", "skills"]
  }
}
```

For CEO:
```json
{
  "name": "CEO",
  "adapterType": "hermes_local",
  "adapterConfig": {
    "model": "anthropic/claude-opus-4-6",
    "maxIterations": 20,
    "timeoutSec": 120,
    "persistSession": true,
    "enabledToolsets": ["terminal", "skills"]
  }
}
```

### Installation

```bash
git clone https://github.com/NousResearch/hermes-paperclip-adapter
cd hermes-paperclip-adapter
npm install && npm run build

# Register in Paperclip's adapter registry:
# server/src/adapters/registry.ts — add hermes_local adapter
```

---

## 11. The Two Feedback Loops

### Loop A — Soft (Subjective, Your Feedback)

**Trigger:** You say anything evaluative to CEO  
**Who decides what to patch:** CEO (Claude Opus 4.6)  
**What changes:** Specific SKILL.md lines, not wholesale rewrites  

```
You: "The social media section was thin, Reddit wasn't well-covered"
    ↓
CEO: "What in the skill caused thin Reddit coverage?
      social-media-researcher limits to 3 Reddit threads.
      Fix: increase minimum to 5 threads, require at least 2 deep-dives."
    ↓
CEO → Hermes worker: skill_manage(patch, "social-media-researcher",
                      old="target 3-5 threads",
                      new="minimum 5 threads, at least 2 full deep-dives")
    ↓
Skill patched. CEO writes to memory: "User flagged thin Reddit coverage 2026-04-05.
Watch in next 2 runs."
```

### Loop B — Hard (Objective, Karpathy-Style)

**Trigger:** quality_score returned by Hermes vs threshold set by CEO  
**Who decides:** Automated — CEO patches and re-runs  
**What changes:** Same autoresearch pattern — keep if metric improves, revert if not  

```
CEO sets threshold at task start: quality_score ≥ 7.5

Hermes runs → returns quality_score = 6.2
    ↓
CEO: "Below threshold. What was weakest stream?"
Hermes: "Web researcher failed (Brave rate limits), score pulled down"
    ↓
CEO patches web-research skill (atomic change):
  "Add exponential backoff: 15s → 30s → 60s on rate limit"
    ↓
Re-run ONLY the web researcher stream
    ↓
New score = 7.8 → above threshold → keep patch → commit to skill
If still below after 3 attempts → escalate to you
```

### Quality Score Formula (to be implemented in research-coordinator)

```python
quality_score = (
  source_count          * 0.25 +  # ≥15 sources=10, <5=0
  domain_coverage       * 0.25 +  # all 5 streams completed=10
  source_freshness      * 0.20 +  # sources <30 days old=10
  depth_score           * 0.20 +  # avg chars per source (10k=10)
  zero_result_penalty   * 0.10    # -2 per stream that returned empty
)
# Scale: 0–10. CEO sets threshold at task start (default: 7.0)
```

---

## 11b. MemOS Startup Checklist

Before any agent can write/read MemOS, run this sequence:

```bash
# 1. Verify dependencies (should already be running)
curl http://localhost:6333  # Qdrant → {"title":"qdrant","version":"1.17.1",...}
nc -z localhost 7687 && echo "Neo4j OK"  # Neo4j

# 2. Start MemOS Python server
cd /home/openclaw/Coding/MemOS
poetry run uvicorn memos.api.server_api:app --host 0.0.0.0 --port 8001

# 3. Provision users/cubes (first time only)
cd /home/openclaw/Coding/MemOS
poetry run python setup-memos-agents.py

# 4. Verify server is up
curl http://localhost:8001/product/scheduler/allstatus

# 5. Test a write
curl -X POST http://localhost:8001/product/add \
  -H "Content-Type: application/json" \
  -d '{"user_id":"research-agent","writable_cube_ids":["research-cube"],"async_mode":"sync","messages":[{"role":"assistant","content":"test memory"}]}'
```

**If search returns empty results:** restart the server once — Qdrant indexes auto-create on startup.

---

## 12. Next Steps (Ordered)

### Phase 1 — Complete the Core Loop (1–2 days)

**Step 1:** Add quality_score self-evaluation to research-coordinator skill  
File: `~/.hermes/skills/research/research-coordinator/SKILL.md`  
Add at end of Phase 3 (after synthesis): compute quality_score from stream completion stats

**Step 2:** Add MemOS dual-write to research-coordinator skill  
After synthesis, add:
```bash
curl -X POST http://localhost:8080/add \
  -d '{"user_id":"research-agent","mem_cube_id":"research-cube","memory_content":"..."}'
```

**Step 3:** Write MemOS provisioning script  
File: `/home/openclaw/Coding/Hermes/setup-memos-agents.py`  
Creates users, cubes, shares. Run once per new agent added.

**Step 4:** Install hermes-paperclip-adapter in Paperclip  
```bash
cd /path/to/paperclip/server
npm install hermes-paperclip-adapter
# Edit src/adapters/registry.ts to add hermes_local
```

**Step 5:** Add soft feedback handler to CEO HEARTBEAT.md  
When `PAPERCLIP_WAKE_REASON=comment` and comment contains evaluative language:
→ extract what failed → issue skill patch task to Hermes worker

### Phase 2 — Multi-Agent Expansion (1 week)

**Step 6:** Create specialized agent skills beyond research  
- `email-agent/SKILL.md` — email drafting, outreach, follow-up
- `marketing-agent/SKILL.md` — copy, campaign analysis, competitor monitoring
- Each with domain-specific quality metrics

**Step 7:** Create Hermes agents in Paperclip for each specialty  
`adapterType: hermes_local`, separate session per agent, isolated MemOS cube per agent

**Step 8:** Add hard feedback loop to CEO HEARTBEAT  
If quality_score < threshold → issue re-run task with `patch_hint` included

### Phase 3 — Full Autoresearch Loop (1–2 weeks)

**Step 9:** Apply autoresearch pattern to skill improvement  
- Metric: quality_score averaged over last 5 runs
- Mutable: SKILL.md files
- Evaluator: CEO judges patches
- Loop: patch → run → score → keep/revert → repeat

**Step 10:** Configure MemOS external provider for Hermes  
Set `memory.provider: openviking` (self-hosted, free) in `~/.hermes/config.yaml`  
This adds semantic search + structured knowledge graph to Hermes's built-in memory

---

## 13. Open Questions

1. **MemOS server port**: The MemOS Python library exposes a REST server but the exact startup command and default port needs verification. The OpenClaw plugin uses port 18799. The Python server may use 8080. Verify before implementing dual-write.

2. **Hermes adapter registry location**: Paperclip's adapter registry is at `server/src/adapters/registry.ts` per the adapter README, but this needs to be located in the actual Paperclip installation at `tower.taila4a33f.ts.net`.

3. **X/Twitter credentials**: x-cli is installed (`uv tool install git+https://github.com/Infatoshi/x-cli.git`) but API credentials are not configured. Skipped per user instruction.

4. **sessions_spawn depth limit of 2**: Confirmed hard limit — researchers cannot spawn further subagents. If a researcher needs to sub-delegate, it must do so sequentially within the same session. This constrains the research hierarchy.

5. **quality_score calibration**: The formula above is a starting point. It needs to be tuned based on actual run data — what score corresponds to "the research was good enough"?

---

*Report generated: April 5, 2026*  
*Session continuity: resume from this document on any system*  
*Research PDF: `/home/openclaw/research-autoresearch-integration-2026-04-05.pdf`*
