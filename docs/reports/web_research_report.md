# Web Research Report: Autoresearch Integration with Agent Frameworks
## Research Date: April 5, 2026

---

## EXECUTIVE SUMMARY

This report covers web research on integrating autoresearch self-improving agent loops with multi-agent frameworks, specifically Paperclip organizational agents and Hermes agents. Key finding: **A direct integration bridge exists** between Hermes Agent and Paperclip via `hermes-paperclip-adapter`.

---

## 1. KEY BLOG POSTS AND TUTORIALS

### Autoresearch

| Title | Author/Source | URL | Key Insights |
|-------|---------------|-----|--------------|
| "A Guide to Andrej Karpathy's AutoResearch" | DataCamp | https://www.datacamp.com/tutorial/guide-to-autoresearch | Comprehensive tutorial on autoresearch. Agent edits train.py, research directions in markdown file, automated overnight experimentation. 21,000+ GitHub stars. |
| "Karpathy's Autoresearch for PMs: Complete Guide" | Aakash G (Substack) | https://www.news.aakashg.com/p/autoresearch-guide-for-pms | Practical guide explaining the loop: scoring runs programmatically, one file agent changes, human never touches train.py |
| "Autoresearch 101 Builder's Playbook" | Sid Saladi (Substack) | https://sidsaladi.substack.com/p/autoresearch-101-builders-playbook | Pattern adaptation guide: shows how autoresearch loop works on Claude skills, system prompts, agent workflows, content templates |
| "The Karpathy Loop: 700 experiments, 2 days" | Fortune | https://fortune.com/2026/03/17/andrej-karpathy-loop-autonomous-ai-agents-future/ | Industry analysis of autoresearch implications. 700 experiments in 2 days demonstrating the power of autonomous research loops. |
| "Autoresearch: Karpathy's Minimal Agent Loop" | Kingy AI | https://kingy.ai/ai/autoresearch-karpathys-minimal-agent-loop-for-autonomous-llm-experimentation/ | Technical deep-dive on implementation details |

### Paperclip Framework

| Title | Author/Source | URL | Key Insights |
|-------|---------------|-----|--------------|
| "What Is Paperclip? The Open-Source Framework for Zero-Human AI Companies" | MindStudio | https://www.mindstudio.ai/blog/what-is-paperclip-zero-human-ai-company-framework-2 | Multi-agent orchestration framework where AI agents hire other agents, set goals, allocate resources |
| "Paperclip: Run a Zero-Human Company with AI Agent Teams" | Zeabur | https://zeabur.com/blogs/deploy-paperclip-ai-agent-orchestration | Deployment guide. Orchestration platform for teams of AI agents operating with zero human intervention |
| "Paperclip AI Agent Orchestrator" | WebSearchAPI Blog | https://websearchapi.ai/blog/paperclip-ai-agent-orchestrator | Deep analysis of heartbeat system solving stateless agent problem. Covers orchestration patterns and security gaps. |
| "Paperclip: The Company OS" | Nervegna (Substack) | https://nervegna.substack.com/p/paperclip-the-company-os-your-agents | "Agents don't need better prompts. They need an org chart." 24k+ GitHub stars, MIT-licensed, self-hosted |
| "Paperclip AI Explained" | Towards AI | https://pub.towardsai.net/paperclip-the-open-source-operating-system-for-zero-human-companies-2c16f3f22182 | Mentions hermes-paperclip-adapter integration. Extensible adapter model. |

### Hermes Agent

| Title | Author/Source | URL | Key Insights |
|-------|---------------|-----|--------------|
| Hermes Agent Official Docs | Nous Research | https://hermes-agent.nousresearch.com/docs/ | Closed learning loop, agent-curated memory, autonomous skill creation, skills self-improve during use, FTS5 cross-session recall |
| GitHub Repository | Nous Research | https://github.com/NousResearch/hermes-agent | 200+ model support, TUI interface, multi-platform (Telegram, Discord, Slack, WhatsApp, Signal, CLI), persistent memory |
| "Awesome Hermes Agent" | 0xNyk | https://github.com/0xNyk/awesome-hermes-agent | Curated list of skills, tools, integrations. Links to hermes-paperclip-adapter and autonovel |

### Self-Improving Agents

| Title | Author/Source | URL | Key Insights |
|-------|---------------|-----|--------------|
| "Self-Improving Coding Agents" | Addy Osmani | https://addyosmani.com/blog/self-improving-agents/ | Treat system as living process. Monitor, tweak, apply human judgment frequently. Lean on model's training strengths. |
| "7 Tips to Build Self-Improving AI Agents" | Datagrid | https://datagrid.com/blog/7-tips-build-self-improving-ai-agents-feedback-loops | Combat reward hacking by rotating reward models, mixing human-scored samples. Design reflection feedback loops with sandbox testing. |
| "Self-Evolving Agents Cookbook" | OpenAI | https://developers.openai.com/cookbook/examples/partners/self_evolving_agents/autonomous_agent_retraining | Genetic-Pareto (GEPA) framework for self-evolving loops. Natural language reflection on agent trajectories. |
| "Loop Agents: Iterative Refinement" | Google ADK Training Hub | https://raphaelmansuy.github.io/adk_training/docs/loop_agents/ | LoopAgent pattern for iterative refinement, quality control, progressive enhancement |

---

## 2. DOCUMENTATION SOURCES

### Official Documentation

| Framework | Documentation URL | Notes |
|-----------|------------------|-------|
| **Autoresearch** | https://github.com/karpathy/autoresearch | Single file: train.py. Everything fair game: architecture, hyperparameters, optimizer, batch size. |
| **Paperclip** | https://paperclip.ing/ | Official site. Orchestrates agents into company with org charts, budgets, goals, governance, accountability |
| **Hermes Agent** | https://hermes-agent.nousresearch.com/docs/ | Full docs. Built by Nous Research. Works with Nous Portal, OpenRouter, OpenAI, or any endpoint. |
| **Hermes Self-Evolution** | https://github.com/NousResearch/hermes-agent-self-evolution | Evolutionary self-improvement using DSPy + GEPA for optimizing skills, prompts, and code |
| **Claude Code Subagents** | https://code.claude.com/docs/en/sub-agents | Custom subagent creation, multiple subagents in single call, session-specific agents |
| **OpenAI Agents SDK** | https://openai.github.io/openai-agents-python/multi_agent/ | Handoffs pattern, tool delegation, orchestration patterns |

### Framework Comparison Resources

| Resource | URL | Coverage |
|----------|-----|----------|
| CrewAI vs LangGraph vs AutoGen | https://www.datacamp.com/tutorial/crewai-vs-langgraph-vs-autogen | Human-in-the-loop hooks, workflow graphs, state management |
| Open Source AI Agent Frameworks Compared | https://openagents.org/blog/posts/2026-02-23-open-source-ai-agent-frameworks-compared | CrewAI for role-based teams, LangGraph for stateful workflows, AutoGen for conversational agents |

---

## 3. INTEGRATION PATTERNS DESCRIBED

### Pattern 1: Hermes-Paperclip Integration (CRITICAL FINDING)

**Repository:** https://github.com/NousResearch/hermes-paperclip-adapter

This is an **official adapter** that lets you run Hermes Agent as a managed employee in a Paperclip company. Features:
- Full Hermes Agent capabilities (30+ native tools)
- Persistent memory within Paperclip org
- Session persistence
- 80+ skills
- MCP support
- Managed as Paperclip "employee" with role, budget, goals

### Pattern 2: Autoresearch Loop Structure

From multiple sources, the core autoresearch pattern:
```
1. program.md      - Human writes research directions
2. train.py        - Single file agent CAN edit (everything else read-only)
3. score.py        - Automated evaluation (programmatic, runs overnight)
4. Git history     - Tracks validated improvements and failed attempts
```

**Key Insight:** Pattern applies to anything with measurable score: Claude skills, system prompts, agent workflows, content templates.

### Pattern 3: Supervisor-Based Architecture (Most Common Starting Point)

From O'Reilly Radar:
- Central agent plans, delegates work, decides completion
- Effective for tightly scoped, sequential reasoning problems
- Example: financial analysis workflows

### Pattern 4: Hierarchical Multi-Agent Pattern

From LangChain/AutoGen:
- Supervisor at top with specialized workers
- Each worker has own tools and context
- Handoffs between agents for task delegation
- Human-in-the-loop checkpoints

### Pattern 5: MCP as Universal Bridge

From Medium (Karan Bhutani):
- Model Context Protocol standardizes agent-tool interaction
- Universal adapter like USB-C for AI
- Once service adopts MCP, any compliant agent connects seamlessly
- Hermes Agent has MCP support built-in

### Pattern 6: Self-Evolution Loop (GEPA)

From OpenAI Cookbook:
- Sample agent trajectories
- Reflect on them in natural language
- Propose prompt revisions
- Evolve through iterative feedback loops
- Implemented in hermes-agent-self-evolution

---

## 4. BEST PRACTICES COMPILATION

### From Addy Osmani (Self-Improving Agents)
1. Treat the system as a living process
2. Monitor continuously, tweak frequently
3. Apply human judgment at key checkpoints
4. Lean on model's training strengths to save context
5. "Elbow grease" goes into tuning prompts and workflow integration

### From Datagrid (Feedback Loops)
1. Rotate reward models to prevent gaming
2. Mix human-scored samples during training
3. Design reflection feedback loops with sandbox testing
4. Focus on business outcomes, not observer rewards

### From O'Reilly (Multi-Agent Architecture)
1. Start with linear, supervisor-based architecture
2. Move to hierarchical only when complexity demands
3. Context management: Specialized knowledge per agent
4. Define clear boundaries between agent capabilities

### From Paperclip Ecosystem
1. Agents need org charts, not better prompts
2. Implement heartbeat system for stateless agent problem
3. Define budgets and approval gates
4. Use skills marketplace (skills.sh, agentskills.io) for capability discovery

### From Autoresearch Pattern
1. One file the agent can change, everything else read-only
2. Programmatic scoring (no human in the loop for evaluation)
3. Let experiments run overnight
4. Git history as audit trail
5. Human writes research directions (program.md), agent handles execution

---

## 5. ADAPTER LIBRARIES AND BRIDGES FOUND

| Library | URL | Purpose |
|---------|-----|---------|
| **hermes-paperclip-adapter** | https://github.com/NousResearch/hermes-paperclip-adapter | Run Hermes Agent as Paperclip employee |
| **hermes-agent-self-evolution** | https://github.com/NousResearch/hermes-agent-self-evolution | DSPy + GEPA evolutionary self-improvement |
| **databricks-ai-bridge** | https://pypi.org/project/databricks-ai-bridge/ | Databricks AI features integration |
| **Agent Bridge (Inspect AI)** | https://inspect.aisi.org.uk/agent-bridge.html | Integrates OpenAI Agents SDK, Pydantic AI, LangChain |
| **Microsoft Agent Framework** | https://github.com/microsoft/agent-framework | Workflows and orchestration with Azure integration |
| **CrewAI BYOA (Bring Your Own Agent)** | https://docs.crewai.com/en/learn/bring-your-own-agent | Convert external agents to CrewAI compatible format |

---

## 6. GAPS NOT COVERED BY OTHER RESEARCH STREAMS

Based on web coverage, these areas may need supplementation:

1. **Production Deployment Patterns**: While deployment tutorials exist (Zeabur), enterprise-scale deployment patterns for multi-agent autoresearch loops are sparse.

2. **Security in Agent Skill Ecosystems**: Noted as "unsolved security gaps" in WebSearchAPI analysis of Paperclip.

3. **Cost Management**: Limited guidance on managing API costs in continuous autoresearch loops.

4. **Failure Recovery**: Limited documentation on handling failed experiments and rollback strategies in autoresearch.

5. **Human Oversight Integration**: While human-in-the-loop patterns exist, specific patterns for integrating human oversight into autoresearch loops are underdocumented.

6. **Cross-Framework Memory Sharing**: How persistent memory transfers between Hermes and Paperclip during adapter use needs more documentation.

---

## 7. RECOMMENDED INTEGRATION ARCHITECTURE

Based on research, a recommended multi-layered setup:

```
Layer 1: PAPERCLIP ORCHESTRATION
├── Org structure, budgets, goals, governance
├── Agent hiring/firing, task delegation
└── Heartbeat system for state management

Layer 2: HERMES AGENTS (via hermes-paperclip-adapter)
├── 30+ native tools per agent
├── Persistent memory (FTS5 cross-session)
├── Autonomous skill creation
└── Self-improvement during use

Layer 3: AUTORESEARCH LOOPS
├── Applied to Hermes skills and prompts
├── Using hermes-agent-self-evolution (DSPy + GEPA)
├── Programmatic scoring functions
└── Git-tracked experiment history

Layer 4: CLAUDE CODE (Optional Parallel)
├── Custom subagents via --agents
├── Multi-agent coordination (7+ agents per workflow)
├── Code-specific tasks (security, deployment, etc.)
└── Session-specific agents for automation
```

---

## 8. KEY REPOSITORIES

| Repository | Stars | Purpose |
|------------|-------|---------|
| karpathy/autoresearch | 21,000+ | Original autoresearch implementation |
| NousResearch/hermes-agent | 23,000+ | Self-improving agent with learning loop |
| Paperclip (main) | 24,000+ | Zero-human company orchestration |
| NousResearch/hermes-paperclip-adapter | N/A | Integration bridge |
| NousResearch/hermes-agent-self-evolution | N/A | DSPy + GEPA self-improvement |
| wshobson/agents | N/A | Claude Code multi-agent orchestration |

---

## CONCLUSION

The web research reveals a maturing ecosystem with **direct integration paths**:

1. **Hermes Agent** provides the self-improving agent core with built-in learning loops
2. **Paperclip** provides organizational orchestration
3. **hermes-paperclip-adapter** bridges the two
4. **hermes-agent-self-evolution** adds autoresearch-style evolutionary improvement using DSPy + GEPA
5. **Claude Code** offers parallel multi-agent capabilities with custom subagents

The autoresearch pattern (one editable file + programmatic scoring + overnight experiments) can be applied to any measurable system, including the skills and prompts within Hermes Agent.
