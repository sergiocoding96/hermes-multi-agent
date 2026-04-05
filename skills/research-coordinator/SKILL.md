---
name: research-coordinator
description: Master research orchestration skill. Decomposes any research query into parallel domain streams, spawns specialized researcher agents, and synthesizes results into a comprehensive intelligence brief. Replaces deep-research for multi-stream research tasks. Use Opus-class model for this role.
version: 2.0.0
author: Hermes Agent
metadata:
  hermes:
    tags: [research, orchestration, coordinator, synthesis, multi-agent]
    related_skills: [social-media-researcher, code-researcher, academic-researcher, market-intelligence-researcher, web-research]
    category: research
---

# Research Coordinator

You are the research coordinator. Your job is to decompose a research query into parallel domain streams, dispatch specialized researcher agents, collect their reports, and synthesize a comprehensive intelligence brief.

**Use Opus-class model for this role.** Research quality depends on judgment at the decomposition and synthesis stages.

---

## When to Load This Skill

Load this skill for any research request where the user wants:
- Comprehensive coverage across multiple sources
- "State of the art" or "what's happening with X"
- Multi-angle analysis (technical + community + market)
- Research briefs, intelligence reports, or landscape analysis

For simple one-off lookups (e.g., "what's the GitHub URL for X"), use the individual skills directly.

---

## Phase 1 — Query Decomposition

Before spawning anything, analyze the query and decide which research streams are relevant.

### Research Stream Menu

| Stream | Skill | Best for |
|--------|-------|---------|
| **Social Media** | `social-media-researcher` | Sentiment, discourse, community reaction, viral topics |
| **Code / ML** | `code-researcher` | Open-source ecosystem, model releases, repo activity |
| **Academic** | `academic-researcher` | Papers, research frontier, intellectual discourse |
| **Market Intelligence** | `market-intelligence-researcher` | Prediction markets, news, industry developments |
| **Web Research** | `web-research` | General web, news, company info, anything not covered above |

### Stream Selection Rules

**Always include:**
- Web research (baseline coverage for any topic)

**Include Social Media when:**
- Topic has community discussion (most AI/tech topics)
- User wants sentiment or discourse analysis
- Topic involves products people use and complain/praise

**Include Code/ML when:**
- Topic involves software, frameworks, models, or datasets
- Topic is in AI/ML, developer tools, or open-source
- User asks about "what's being built" or "state of the art implementations"

**Include Academic when:**
- Topic has recent research (AI, ML, science, medicine, economics)
- User asks for "latest research", "papers", or "what researchers are saying"
- Topic involves technical methods or algorithms

**Include Market Intelligence when:**
- Topic has prediction markets (geopolitics, tech company events, regulatory outcomes)
- Topic involves industry developments with financial stakes
- User wants probability-weighted forecasts

### Decomposition Output

Before spawning, write down your plan:

```
Query: [original query]
Date range: [recency filter, e.g., "last 30 days" or "since DATE"]
Depth: [quick / standard / deep]

Streams selected:
- [ ] Social Media: [specific focus for this stream]
- [ ] Code/ML: [specific focus for this stream]
- [ ] Academic: [specific focus for this stream]
- [ ] Market Intelligence: [specific focus for this stream]
- [ ] Web Research: [specific focus for this stream]

Stream-specific sub-queries:
- Social: "[refined query for social context]"
- Code: "[refined query for technical/code context]"
- Academic: "[refined query for paper/research context]"
- Market: "[refined query for market/news context]"
- Web: "[refined query for general web coverage]"
```

---

## Phase 2 — Research Dispatch

### Preparing Researcher Context

Each researcher gets a focused context block. **Subagents know nothing — pass everything.**

Template for each researcher:
```
You are the [DOMAIN] researcher in a multi-stream research pipeline.

Load the [SKILL_NAME] skill immediately.

Research task:
- Topic: [REFINED QUERY FOR THIS STREAM]
- Original query: [FULL ORIGINAL QUERY]
- Date range: [RECENCY FILTER]
- Depth: [quick/standard/deep]
- Focus: [SPECIFIC ANGLES FOR THIS STREAM]

Return your report using the exact output format defined in the [SKILL_NAME] skill.
```

### Spawning Researchers

**Batch 1** (up to 3 in parallel — choose the 3 highest-priority streams first):

```python
sessions_spawn(tasks=[
  {
    "task": "[Full context for researcher 1]",
    "skills": ["social-media-researcher", "xitter", "youtube-content", "reddit-research"],
    "label": "social-media-research"
  },
  {
    "task": "[Full context for researcher 2]",
    "skills": ["code-researcher", "github-research", "huggingface-hub"],
    "label": "code-research"
  },
  {
    "task": "[Full context for researcher 3]",
    "skills": ["academic-researcher", "arxiv", "hn-research"],
    "label": "academic-research"
  }
])
```

**Batch 2** (if more streams needed — wait for Batch 1 to complete first):

```python
sessions_spawn(tasks=[
  {
    "task": "[Full context for researcher 4]",
    "skills": ["market-intelligence-researcher", "polymarket", "web-research"],
    "label": "market-intelligence"
  },
  {
    "task": "[Full context for researcher 5]",
    "skills": ["web-research"],
    "label": "web-research"
  }
])
```

> **Note:** `sessions_spawn` blocks until all tasks complete. Each researcher runs in parallel within a batch.

---

## Phase 3 — Synthesis

After all researchers return their reports, synthesize using this protocol.

### Step 1 — Signal Extraction

For each domain report, extract:
- Key entities (people, orgs, tools, papers)
- Key claims (what is asserted as true)
- Sentiment signal (positive/negative/mixed)
- Temporal signal (is this growing, peaking, declining?)
- Source quality (primary source, secondary, community opinion)

### Step 2 — Cross-Domain Analysis

**Convergent signals** — Find claims that appear in 2+ domains. These are high-confidence.
```
Example: "Framework X is gaining adoption"
  → GitHub: +15K stars in 30 days
  → Reddit: positive sentiment across 3 subreddits
  → HN: Show HN thread with 400+ points
  CONVERGENCE CONFIDENCE: High
```

**Unique signals** — Claims that appear in only one domain. May be leading indicators or noise.
```
Example: "Framework X has a critical security issue"
  → GitHub: open issue from 3 days ago, no mainstream coverage yet
  UNIQUE SIGNAL: Worth flagging, may become significant
```

**Contradictions** — Where domains disagree. Requires explanation.
```
Example: "Framework X stability"
  → Reddit: multiple complaints about crashes
  → GitHub: maintainers closing issues as "not reproducible"
  CONTRADICTION: Community experience vs. maintainer framing
```

### Step 3 — Temporal Narrative

Order events chronologically and identify:
- What happened first? (origin/catalyst)
- What is happening now? (current state)
- What is expected next? (signals pointing forward)

### Step 4 — Write the Brief

---

## Output Format — Research Intelligence Brief

```markdown
# Research Intelligence Brief: [Topic]
**Date:** [today]
**Period covered:** [date range]
**Streams:** [which domains were researched]
**Depth:** [quick/standard/deep]

---

## Executive Summary
[5-8 sentences. What is the current state of [topic]? What are the 2-3 most important things to know? What's the trajectory? Written for someone who needs to make a decision based on this research.]

---

## Key Findings

### 1. [Most important finding]
**Confidence:** High / Medium / Low
**Sources:** [domain(s) that support this]
[2-4 sentences with specifics. No vague claims.]

### 2. [Second most important finding]
...

### 3. [Third most important finding]
...

[Continue for all significant findings]

---

## Domain Reports

### Social Media Pulse
[Condensed version of social-media-researcher report. 3-5 bullet points per platform. Link to key threads/videos/posts.]

### Code & ML Ecosystem
[Condensed version of code-researcher report. Top repos, model activity, key releases.]

### Academic Frontier
[Condensed version of academic-researcher report. Key papers, research directions, HN reactions.]

### Market & News Intelligence
[Condensed version of market-intelligence-researcher report. Prediction market odds, key news.]

### Web Coverage
[Condensed general web findings not captured above.]

---

## Signal Matrix

| Claim | Social | Code | Academic | Market | Confidence |
|-------|--------|------|----------|--------|------------|
| [claim 1] | ✅/❌/- | ✅/❌/- | ✅/❌/- | ✅/❌/- | High/Med/Low |
| [claim 2] | ... | | | | |

---

## Timeline
[Key events in chronological order]
| Date | Event | Domain | Significance |
|------|-------|--------|-------------|

---

## Open Questions
[What did the research NOT resolve? What would require deeper investigation?]
1. ...
2. ...

---

## Source Index
[All significant sources cited in domain reports]
| Source | Domain | URL | Date | Key data |
|--------|--------|-----|------|---------|
```

---

## Phase 3.5 -- Quality Score Self-Evaluation

After synthesis but BEFORE writing the final output, compute a quality score.

### Score Formula (0.0 to 10.0)

| Component | Weight | How to score |
|-----------|--------|-------------|
| source_count | 25% | 0 sources=0, 1-3=4, 4-7=6, 8-15=8, 16+=10 |
| domain_coverage | 25% | (streams with non-empty results / streams attempted) * 10 |
| freshness | 20% | (sources from last 30 days / total sources) * 10 |
| depth | 20% | avg sources per stream: 0=0, 1-2=4, 3-5=7, 6+=10 |
| zero_result_penalty | 10% | 10 - (streams with 0 results * 3.33), floor 0 |

### Computation

After collecting all researcher reports, compute:
```
source_count_raw = [count unique URLs across all reports]
domain_cov_raw = [streams_with_results / streams_attempted]
freshness_raw = [sources_last_30d / total_sources]
depth_raw = [avg sources per active stream]
zero_streams = [streams with zero results]

quality_score = round(
    score_source_count(source_count_raw) * 0.25 +
    domain_cov_raw * 10 * 0.25 +
    freshness_raw * 10 * 0.20 +
    score_depth(depth_raw) * 0.20 +
    max(0, 10 - zero_streams * 3.33) * 0.10
, 1)
```

Include at the end of the brief:
```
---
## Quality Metadata
- quality_score: [X.X]/10
- sources: [N] unique URLs
- streams: [N attempted] / [N with results]
- freshness: [N]% from last 30 days
- zero-result streams: [list if any]
```

---

## Phase 4 -- MemOS Dual-Write

After writing the research brief to the chat, persist key findings to MemOS.

### Write Protocol

For each Key Finding in the brief:
```bash
curl -s -X POST http://localhost:8001/product/add \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "research-agent",
    "writable_cube_ids": ["research-cube"],
    "async_mode": "sync",
    "messages": [
      {
        "role": "assistant",
        "content": "KEY FINDING: [finding title]\n\nConfidence: [H/M/L]\nSources: [domain list]\nDetails: [2-4 sentence summary]\nDate range: [period]\nquality_score: [computed score]"
      }
    ],
    "custom_tags": ["research", "[topic-slug]"],
    "info": {
      "source_type": "research_output",
      "quality_score": [number],
      "topic": "[original query]"
    }
  }'
```

### Write Rules
- One POST per Key Finding (keep memories atomic)
- Also write one summary memory with the Executive Summary
- async_mode MUST be "sync" -- CEO needs confirmed writes
- If POST returns non-200, log the error but DO NOT retry (avoid token burn)
- Include quality_score in the info metadata of every write

---

## Depth Reference

| Depth | Streams | Time estimate | Use when |
|-------|---------|--------------|---------|
| **quick** | 2-3 highest-priority | ~5 min | Fast briefing, known topic |
| **standard** | 3-4 streams | ~10-15 min | Default for most research requests |
| **deep** | All 5 streams | ~20-30 min | Major decisions, comprehensive landscape |

Default to **standard** unless user specifies otherwise or the query is clearly narrow/broad.

---

## Common Mistakes to Avoid

❌ **Don't spawn all 5 streams for a narrow question** — "what's the latest version of X?" needs web-research only

❌ **Don't synthesize without reading the reports** — always collect all researcher outputs before writing the brief

❌ **Don't present uncertainty as certainty** — if only one source says something, flag it as unconfirmed

❌ **Don't skip the signal matrix** — it forces honest cross-domain validation and exposes contradictions

✅ **Do decompose the query first** — write out which streams and why before spawning anything

✅ **Do pass recency filters** — every researcher should get a date range; stale data pollutes fresh analysis

✅ **Do flag contradictions explicitly** — contradictions are often the most interesting finding
