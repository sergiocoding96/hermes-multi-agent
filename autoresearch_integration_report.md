# Autoresearch Technical Internals & Multi-Agent Integration Report

## Executive Summary

This report provides a technical deep-dive on Karpathy's autoresearch, its architecture, extension points, forks, and patterns for integrating with multi-agent frameworks like Paperclip and Hermes.

---

## 1. AUTORESEARCH ARCHITECTURE BREAKDOWN

### Core Loop Structure

Autoresearch implements a minimal but powerful self-improvement loop:

```
LOOP (indefinitely):
  1. Agent reads program.md instructions
  2. Agent modifies train.py (ONLY editable file)
  3. Execute: uv run train.py (5-min wall-clock budget)
  4. Read val_bpb (validation bits per byte) from output
  5. DECISION:
     - If val_bpb < previous_best -> KEEP (commit, advance)
     - If val_bpb >= previous_best -> DISCARD (git reset)
  6. Log to results.tsv
  7. Repeat
```

### File Structure

```
autoresearch/
├── prepare.py      # FIXED - Data prep, tokenizer, evaluation. DO NOT MODIFY
├── train.py        # EDITABLE - GPT model, optimizer (Muon + AdamW), training loop
├── program.md      # Agent instructions (the "orchestration framework")
├── results.tsv     # Experiment log (commit, val_bpb, memory_gb, status, description)
└── README.md       # Repository context
```

### Key Architectural Decisions

1. **Single Metric**: val_bpb (bits per byte) - vocab-size-independent for fair comparison
2. **Fixed Time Budget**: 5 minutes wall-clock (excluding startup/compilation)
3. **Git-Based State**: Each experiment is a branch `autoresearch/<tag>`
4. **Evolutionary Single-Lineage**: No population, LLM acts as mutation + selection operator
5. **Results.tsv Tracking**: Tab-separated log with columns:
   - commit hash, val_bpb, memory_gb, status (keep/discard/crash), description

### Accept/Reject Logic (from program.md)

```
KEEP: val_bpb < current_best
  -> Commit changes
  -> Update best baseline
  -> Continue from new state

DISCARD: val_bpb >= current_best
  -> git reset --hard HEAD~1
  -> Log failure reason
  -> Try different approach

CRASH: Training fails (OOM, syntax error, etc.)
  -> Log as crash with val_bpb=0.0, memory=0.0
  -> git reset
  -> Analyze and avoid in future
```

---

## 2. CODE HOOKS AND EXTENSION POINTS

### Native Extension Points

1. **program.md** - The primary hook. Modify agent instructions to:
   - Change optimization targets
   - Add constraints
   - Modify keep/discard logic
   - Add reporting requirements

2. **results.tsv** - Append-only log that agents can read for:
   - Historical context
   - Learning from past experiments
   - Avoiding redundant work

3. **Git History** - Agents read `git log` for context on what was tried

4. **Branch Naming** - `autoresearch/<tag>` allows external orchestrators to:
   - Track multiple parallel experiments
   - Coordinate across agents

### External Control APIs (via forks)

**n-autoresearch (iii-hq)** adds REST API hooks:
```
POST /api/experiment/register   - Record hypothesis before training
POST /api/experiment/complete   - Record metrics, auto keep/discard
POST /api/search/suggest        - Get guidance on what to try next
POST /api/report/summary        - Full stats for a run tag
```

**autoresearch-at-home** adds coordination endpoints:
- Experiment claiming (prevent duplicates)
- Best-config syncing across agents
- Hypothesis exchange
- Semantic similarity checking

### Claude Code Integration Hooks

Claude Code provides **PreToolUse** and **PostToolUse** hooks:
```javascript
// PreToolUse hook example (cage.sh pattern)
- Intercept file operations
- Enforce boundaries (agent can't read/write outside directory)
- Inject context before operations

// PostToolUse hook
- Validate outputs
- Trigger external systems
- Log to external services
```

The **uditgoenka/autoresearch** skill wraps the pattern for Claude Code:
- Supports MCP servers during loop
- Multi-mode: init, update, check, summarize
- Auto-remediation with --fix flag
- Dynamic doc discovery

---

## 3. FORKS AND VARIANTS FOUND

### Multi-Agent & Coordination Forks

| Repository | Key Features |
|------------|--------------|
| **Human-Agent-Society/CORAL** | Multi-agent self-evolution infrastructure. 5 components: Agent Pool, Note Repository, Skill Library, Heartbeat Mechanism, Communication Layer |
| **mutable-state-inc/autoresearch-at-home** | SETI@home-style collaborative. Experiment claiming, shared best-config syncing, hypothesis exchange, swarm coordination |
| **iii-hq/n-autoresearch** | Multi-GPU parallelism, REST API orchestration, 21 Python functions for tracking, GPU worker pool (Rust) |
| **ArmanJR/autoautoresearch** | Isolated experiment directories, PreToolUse hooks (cage.sh), sandboxed agents |

### Platform Variants

| Repository | Key Features |
|------------|--------------|
| **jsegov/autoresearch-win-rtx** | Windows + consumer NVIDIA GPUs, tiered VRAM floors by architecture |
| **SkyPilot/examples/autoresearch** | Kubernetes cluster scaling, parallel experiments across nodes |

### Generalization Forks

| Repository | Key Features |
|------------|--------------|
| **jmilinovich/goal-md** | Generalizes to GOAL.md pattern for any repo. Agent constructs fitness function first, then optimizes |
| **james-s-tayler/lazy-developer** | Orchestrates autoresearch across multiple optimization goals (coverage, test speed, build speed, complexity, LOC, performance) |
| **uditgoenka/autoresearch** | Claude Autoresearch Skill - brings pattern to general software iteration |
| **codex-autoresearch** | Codex skill for metric-driven software iteration |

---

## 4. CORAL: Multi-Agent Self-Evolution Framework

CORAL (arxiv paper 2604.01658) is specifically built for autoresearch multi-agent scenarios.

### Architecture (5 Components)

1. **Agent Pool** - Multiple autonomous agents exploring different hypotheses
2. **Note Repository** - Shared knowledge base for discoveries
3. **Skill Library** - Reusable solution patterns
4. **Heartbeat Mechanism** - Periodic reflection and redirection
5. **Communication Layer** - Inter-agent coordination

### Key Mechanisms

- **Knowledge Retrieval**: Agents retrieve from shared repository
- **Knowledge Contribution**: Successful experiments become notes
- **Skill Distillation**: Patterns extracted as reusable skills
- **Heartbeat Reflection**: Periodic self-assessment for stuck agents
- **Multi-Agent Communication**: Prevents redundant exploration

---

## 5. PAPERCLIP FRAMEWORK INTEGRATION

### Paperclip Architecture

Paperclip is a "Company OS" for AI agents with:
- **Org Charts** with reporting lines
- **Goal Alignment** cascading from mission to task
- **Budget Controls** per agent
- **Heartbeat Scheduling** for agent check-ins
- **Ticket-Based Communication** with audit trails
- **Governance Gates** for human approval

### Integration Pattern: Autoresearch as Paperclip Employee

```
PAPERCLIP COMPANY
├── CEO Agent (strategic decisions, board approval)
├── CTO Agent (technical priorities)
└── Research Team
    ├── Autoresearch Agent #1 (GPU-0)
    │   └── Runs autoresearch loop
    │   └── Reports to CTO via tickets
    ├── Autoresearch Agent #2 (GPU-1)
    │   └── Different hypothesis space
    └── Analysis Agent
        └── Reviews results.tsv
        └── Synthesizes findings
```

### Key Integration Points

1. **Heartbeat**: Autoresearch reports val_bpb progress at intervals
2. **Tickets**: Each experiment creates a ticket for tracking
3. **Governance**: Strategic pivots require CTO/CEO approval
4. **Budget**: Token/compute budget enforced per agent
5. **Goal Alignment**: Company mission → Research objective → val_bpb target

---

## 6. HERMES AGENT INTEGRATION

### Hermes Architecture

Hermes Agent (Nous Research) features:
- 40+ bundled skills (MLOps, GitHub, research)
- Multi-provider model access (OpenRouter, OpenAI, Anthropic, etc.)
- Autonomous skill creation and self-improvement
- FTS5 cross-session recall
- MCP server support

### hermes-paperclip-adapter

Official adapter to run Hermes as Paperclip employee:
- Connects to Paperclip task management
- Receives work via ticket system
- Reports via heartbeat
- Subject to governance controls

### hermes-agent-self-evolution

Evolutionary self-improvement using:
- **DSPy** - Declarative prompting framework
- **GEPA** - Genetic Evolution of Prompt Architectures
- Skill optimization during use
- Code improvement via evolutionary pressure

### Integration Pattern: Hermes + Autoresearch

```
HERMES AGENT
├── Skills
│   ├── autoresearch.skill       # Wraps autoresearch loop
│   ├── github-research.skill    # Finds relevant repos
│   └── ml-ops.skill            # Deployment
├── Memory
│   └── Cross-session recall of experiments
└── MCP Servers
    └── External tools (Sentry, GitHub, etc.)
```

---

## 7. COMPLETE INTEGRATION ARCHITECTURE

### Recommended Multi-Layer Setup

```
LAYER 1: GOVERNANCE (Paperclip)
├── Board: Human approval for strategic decisions
├── CEO: Sets research priorities
├── Budget: Compute/token allocation
└── Governance Gates: Checkpoint approvals

LAYER 2: COORDINATION (CORAL or autoresearch-at-home)
├── Experiment Claiming: Prevents duplicate work
├── Hypothesis Exchange: Agents share promising directions
├── Best-Config Sync: Winners propagate to all
└── Note Repository: Shared knowledge base

LAYER 3: EXECUTION (Hermes + Autoresearch)
├── Hermes Agent #1
│   └── autoresearch loop on GPU-0
│   └── Reports via hermes-paperclip-adapter
├── Hermes Agent #2
│   └── autoresearch loop on GPU-1
│   └── Different search strategy
├── Hermes Agent #3
│   └── Analysis and synthesis
│   └── hermes-agent-self-evolution for prompt optimization
└── Claude Code Agent
    └── uditgoenka/autoresearch skill
    └── General software iteration

LAYER 4: INFRASTRUCTURE
├── n-autoresearch REST API
├── GPU Worker Pool
└── Experiment Database
```

### Key Code Hooks for Integration

```python
# 1. Experiment Registration (pre-training)
POST /api/experiment/register
{
  "agent_id": "hermes-gpu0",
  "hypothesis": "increase batch size 2x",
  "parent_commit": "a1b2c3d"
}

# 2. Experiment Completion (post-training)
POST /api/experiment/complete
{
  "experiment_id": "exp-123",
  "val_bpb": 0.993200,
  "memory_gb": 44.2,
  "train_py_source": "<full source>"
}

# 3. Paperclip Heartbeat
POST /api/paperclip/heartbeat
{
  "agent_id": "hermes-gpu0",
  "status": "running",
  "progress": {
    "experiments": 47,
    "best_val_bpb": 0.9932,
    "improvement": "2.3%"
  }
}

# 4. Governance Gate Check
GET /api/paperclip/governance/check
{
  "action": "switch_search_strategy",
  "current_strategy": "random",
  "proposed_strategy": "adaptive"
}
# Returns: {"approved": true/false, "requires_human": true/false}
```

---

## 8. KEY FINDINGS AND RECOMMENDATIONS

### What Makes Autoresearch Work

1. **Simplicity**: No complex frameworks, just program.md + git
2. **Clear Metric**: Single val_bpb number for decisions
3. **Safe Exploration**: Git reset provides instant rollback
4. **Full Context**: Agent can read entire codebase and history

### For Multi-Agent Integration

1. **Use CORAL or autoresearch-at-home** for coordination layer
2. **Use Paperclip** for governance and organizational structure
3. **Use Hermes** for capable agents with skill libraries
4. **Use n-autoresearch** for REST API orchestration
5. **Use GOAL.md pattern** for generalizing beyond ML training

### Code Integration Checklist

- [ ] Set up Paperclip company with Research department
- [ ] Install hermes-paperclip-adapter on Hermes agents
- [ ] Configure CORAL Note Repository for knowledge sharing
- [ ] Set up n-autoresearch REST API for experiment tracking
- [ ] Define governance gates for strategic decisions
- [ ] Configure heartbeat intervals for progress reporting
- [ ] Set up budget limits per agent
- [ ] Create GOAL.md file defining optimization target

---

## 9. REPOSITORIES REFERENCE

### Core
- https://github.com/karpathy/autoresearch

### Multi-Agent
- https://github.com/Human-Agent-Society/CORAL
- https://github.com/mutable-state-inc/autoresearch-at-home
- https://github.com/iii-hq/n-autoresearch

### Frameworks
- https://github.com/paperclipai/paperclip
- https://github.com/NousResearch/hermes-agent
- https://github.com/NousResearch/hermes-paperclip-adapter
- https://github.com/NousResearch/hermes-agent-self-evolution

### Skills & Generalizations
- https://github.com/uditgoenka/autoresearch (Claude Autoresearch Skill)
- https://github.com/jmilinovich/goal-md
- https://github.com/james-s-tayler/lazy-developer

### Curated Lists
- https://github.com/alvinreal/awesome-autoresearch
- https://github.com/yibie/awesome-autoresearch
- https://github.com/0xNyk/awesome-hermes-agent

---

*Report generated: April 5, 2026*
*Research depth: Standard*
*Focus: Technical internals, hooks, integration patterns*
