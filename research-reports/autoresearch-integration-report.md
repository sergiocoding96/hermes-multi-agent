# Autoresearch Integration & Multi-Agent Frameworks Research Report

**Date:** April 2026  
**Topic:** Integrating autoresearch self-improving loops with multi-agent systems  

---

## EXECUTIVE SUMMARY

This report covers the current landscape of autoresearch patterns and multi-agent frameworks
for building self-improving AI systems. Key findings include:

1. **Karpathy's Autoresearch** - The definitive self-improving research loop pattern (65K+ stars)
2. **Paperclip Pantheon** - 21-agent organizational framework for AI companies
3. **Orchestrum** - Multi-agent orchestration combining Claude, Claude Code, Hermes, and Codex
4. **Microsoft AutoGen** - Production-ready multi-agent framework
5. **CrewAI** - High-level multi-agent crew orchestration

---

## 1. AUTORESEARCH (karpathy/autoresearch)

**Repository:** https://github.com/karpathy/autoresearch  
**Stars:** 65,685 | **Forks:** 9,392 | **Created:** March 2026

### What It Is

Autoresearch is Andrej Karpathy's self-improving AI research system. An AI agent autonomously
experiments with LLM training code overnight - modifying code, training for 5 minutes,
evaluating results, keeping improvements, and repeating.

### Core Architecture

```
Key Files:
- prepare.py   -- Fixed constants, data prep, runtime utilities (NOT modified)
- train.py     -- Model, optimizer, training loop (AGENT MODIFIES THIS)
- program.md   -- Agent instructions / "skill file" (HUMAN MODIFIES THIS)
```

### How It Works

1. Agent reads program.md (lightweight skill/instruction file)
2. Agent proposes modification to train.py
3. System runs 5-minute training experiment
4. Agent evaluates val_bpb metric (lower = better)
5. Keep or discard changes
6. Repeat (~12 experiments/hour, ~100 overnight)

### Key Design Principles

- **Single file to modify** - Agent only touches train.py
- **Fixed time budget** - 5 minutes per experiment ensures fair comparison
- **Self-contained** - No distributed training, one GPU, one file, one metric
- **program.md as skill** - Human programs the research organization through markdown

### Integration Pattern

```bash
# Setup
uv sync && uv run prepare.py

# Autonomous mode
# Point Claude/Codex at the repo, prompt:
"Hi have a look at program.md and let's kick off a new experiment!"
```

### Notable Forks

- miolini/autoresearch-macos (MacOS)
- trevin-creator/autoresearch-mlx (MacOS MLX)
- jsegov/autoresearch-win-rtx (Windows)
- andyluo7/autoresearch (AMD)

---

## 2. PAPERCLIP PANTHEON (JG003/paperclip-pantheon)

**Repository:** https://github.com/JG003/paperclip-pantheon  
**Purpose:** 21-agent AI workforce framework for running companies

### Architecture

```
CEO:
  Ponos - Chief Executive Officer + Council Chairman

21 Operatives across 6 divisions:
  Strategy & Intelligence: Athena, Argos, Prometheus, Mnemosyne
  Build & Ship: Daedalus, Hephaestus, Iris
  Market & Brand: Calliope, Hermes, Erato, Aether, Hestia
  Operations: Demeter, Charon, Persephone
  Revenue & Deals: Chrysus, Apollo, Themis, Tyche
  Experience & Support: Terpsichore, Asclepius

Council of 5 (Strategic Advisors):
  Momus - The Contrarian (downside risk)
  Eos - The Expansionist (upside potential)
  Metis - First Principles Thinker
  Nike - The Executor
  Proteus - The Outsider (keeps everyone honest)
```

### Integration with Paperclip

Designed for use with Paperclip orchestration platform by Dotta:
- SOUL files (identity, mission, responsibilities, voice)
- HEARTBEAT files (cadence, checklists, escalation protocols)
- Framework documents (Pantheon, Council of 5, Hiring Plan)

### Agent Activation Tiers

**Always Active:** Ponos, Argos, Calliope, Hermes, Iris, Tyche, Mnemosyne  
**Usually Active:** Athena, Apollo, Daedalus, Hephaestus, Themis, Hestia, Asclepius  
**Conditional:** Prometheus, Demeter, Chrysus, Persephone, Charon, Aether, Erato, Terpsichore

### Key Pattern: Nominative Determinism

Greek mythology names encode function - hearing "Athena" immediately conveys research role.
Family relationships encode dependencies (Mnemosyne/memory is mother of Calliope/content).

---

## 3. ORCHESTRUM (Optimal-Living-Systems/orchestrum)

**Repository:** https://github.com/Optimal-Living-Systems/orchestrum  
**Purpose:** Multi-agent orchestration combining Claude + Claude Code + Hermes + Codex

### Architecture

```
You (voice/text) → Claude → Plan / Architecture / Docs
                                    ↓
                               AGENTS.md written
                               lab-context/ updated
                                    ↓
                         ┌──────────┴──────────┐
                         ↓                      ↓
                Claude Code (CC)          Hermes Agent
                reads AGENTS.md           reads AGENTS.md
                builds pipelines          runs research/cron
                commits to GitHub         monitors datasets
                         ↓                      ↓
                Roborev auto-reviews      Hermes alerts
                every commit via          via Signal
                Codex (adversarial)
                         ↓                      ↓
                Pass? → continue          Findings → lab-context/
                Fail? → CC fixes
                         ↓                      ↓
                         └──────────┬──────────┘
                                    ↓
                         You review outputs
                                    ↓
                         Back to Claude for next cycle
```

### Agent Roles

| Agent | Role | What it owns |
|---|---|---|
| Claude (Project Folders) | Strategist / Institutional Brain | Architecture, AGENTS.md, planning |
| Claude Code | Primary Builder | Kestra YAML, Python pipelines, code |
| Hermes Agent | Operator / Researcher | Scheduled research, monitoring, cron |
| Codex / Roborev | Adversarial Quality Gate | Cross-model code review |

### Three Core Principles

1. **Adversarial Review** - Codex reviews every commit Claude Code produces
2. **Shared Context** - All agents read same AGENTS.md files and lab-context/
3. **Bounded Autonomy** - Agents propose, humans approve, Kestra executes

### Tech Stack

- **Orchestration:** Kestra (Docker)
- **Vector Storage:** LanceDB
- **Embeddings:** BGE-M3 (local)
- **LLM Routing:** LiteLLM + Ollama
- **Code Review:** Roborev v0.48.0
- **Agent Runtime:** Hermes Agent

---

## 4. MICROSOFT AUTOGEN

**Repository:** https://github.com/microsoft/autogen  
**Stars:** Major framework for agentic AI

### Installation

```bash
pip install -U "autogen-agentchat" "autogen-ext[openai]"
```

### Multi-Agent Orchestration Pattern

```python
from autogen_agentchat.agents import AssistantAgent
from autogen_agentchat.tools import AgentTool
from autogen_ext.models.openai import OpenAIChatCompletionClient

async def main():
    model_client = OpenAIChatCompletionClient(model="gpt-4.1")

    # Create specialist agents
    math_agent = AssistantAgent("math_expert", model_client=model_client,
        system_message="You are a math expert.",
        description="A math expert assistant.")
    
    chemistry_agent = AssistantAgent("chemistry_expert", model_client=model_client,
        system_message="You are a chemistry expert.",
        description="A chemistry expert assistant.")
    
    # Wrap as tools
    math_tool = AgentTool(math_agent, return_value_as_last_message=True)
    chem_tool = AgentTool(chemistry_agent, return_value_as_last_message=True)
    
    # Main orchestrator
    orchestrator = AssistantAgent("assistant",
        system_message="You are a general assistant. Use expert tools when needed.",
        model_client=model_client,
        tools=[math_tool, chem_tool],
        max_tool_iterations=10)
    
    await orchestrator.run(task="What is the integral of x^2?")
```

### Key Features

- **Core API** - Message passing, event-driven agents, distributed runtime
- **AgentChat API** - Simpler API for rapid prototyping
- **Extensions API** - First and third-party extensions
- **AutoGen Studio** - No-code GUI for multi-agent apps
- **MCP Support** - Model Context Protocol integration

---

## 5. CREWAI

**Website:** https://docs.crewai.com  
**Purpose:** Production-ready multi-agent platform

### Key Concepts

- **Agents** - Compose with tools, memory, knowledge, structured outputs
- **Crews** - Coordinate agents for complex tasks
- **Flows** - Orchestrate start/listen/router steps, manage state, persist execution

### Enterprise Features

- Deploy automations with monitoring
- Triggers: Gmail, Slack, Salesforce, HubSpot integration
- Team management with RBAC
- Human-in-the-loop triggers

---

## 6. INTEGRATION PATTERNS FOR SELF-IMPROVING LOOPS

### Pattern A: Autoresearch + Paperclip Pantheon

Combine Karpathy's autonomous research loop with organizational agents:

```
Athena (Research Agent)
    ↓ reads research goals
Prometheus (R&D Experiment Runner)
    ↓ runs autoresearch loop
    ↓ modifies train.py
    ↓ evaluates val_bpb
Mnemosyne (Knowledge Manager)
    ↓ stores successful experiments
    ↓ maintains institutional memory
Ponos (CEO)
    ↓ reviews daily progress
    ↓ sets next research priorities
```

### Pattern B: Orchestrum Integration

Use Orchestrum's adversarial review for autoresearch experiments:

```
Claude (Planning)
    → writes program.md research goals
    → updates lab-context/

Claude Code (Building)
    → runs autoresearch experiments
    → commits train.py changes

Codex/Roborev (Review)
    → adversarially reviews changes
    → catches different blindspots

Hermes (Monitoring)
    → tracks experiment metrics
    → alerts on breakthroughs/failures
```

### Pattern C: AutoGen Self-Improving Loop

```python
# Researcher proposes experiments
researcher = AssistantAgent("researcher",
    system_message="You propose ML experiments based on program.md")

# Executor runs experiments  
executor = AssistantAgent("executor",
    system_message="You modify train.py and run experiments")

# Evaluator scores results
evaluator = AssistantAgent("evaluator", 
    system_message="You evaluate val_bpb and decide keep/discard")

# Memory agent tracks history
memory = AssistantAgent("memory",
    system_message="You maintain experiment history and patterns")

# Orchestrate the loop
orchestrator = AssistantAgent("orchestrator",
    tools=[AgentTool(researcher), AgentTool(executor), 
           AgentTool(evaluator), AgentTool(memory)])
```

---

## 7. IMPLEMENTATION RECOMMENDATIONS

### For Quick Start

1. Clone karpathy/autoresearch
2. Set up program.md with your research goals
3. Point Claude Code at the repo
4. Let it run overnight

### For Production Multi-Agent

1. Use Paperclip Pantheon structure for organizational hierarchy
2. Integrate Orchestrum's adversarial review pattern
3. Use Hermes Agent for monitoring and alerts
4. Implement AGENTS.md as shared context

### Key Files to Create

```
project/
├── AGENTS.md              # Shared context for all agents
├── program.md             # Autoresearch skill/instructions
├── souls/
│   ├── researcher-SOUL.md
│   ├── executor-SOUL.md
│   └── evaluator-SOUL.md
├── heartbeats/
│   ├── researcher-HEARTBEAT.md
│   └── monitor-HEARTBEAT.md
└── lab-context/
    ├── experiment-history.json
    └── current-priorities.md
```

---

## 8. KEY RESOURCES

### Repositories

- https://github.com/karpathy/autoresearch (65K stars)
- https://github.com/JG003/paperclip-pantheon
- https://github.com/Optimal-Living-Systems/orchestrum
- https://github.com/microsoft/autogen
- https://github.com/crewAIInc/crewAI

### Documentation

- https://docs.crewai.com
- https://microsoft.github.io/autogen/
- https://paperclip.ing

### Related Tools

- Roborev: https://github.com/wesm/roborev (adversarial code review)
- Hermes Agent: https://github.com/NousResearch/hermes-agent
- Kestra: https://kestra.io (workflow orchestration)
- LiteLLM: Model routing
- LanceDB: Vector storage

---

## CONCLUSION

The self-improving agent loop pioneered by Karpathy's autoresearch can be integrated into
multi-layered agent setups using:

1. **Paperclip Pantheon** for organizational structure (CEO, Council, Operatives)
2. **Orchestrum** patterns for adversarial review and bounded autonomy
3. **AutoGen** or **CrewAI** for technical multi-agent orchestration
4. **Shared context files** (AGENTS.md, program.md, SOUL/HEARTBEAT files)

The key insight is that agents should have **bounded autonomy** - they propose changes,
but humans approve at critical gates. The autoresearch loop works because the scope is
narrowly constrained (one file, one metric, fixed time budget).

---

*Report generated by web research subagent, April 2026*
