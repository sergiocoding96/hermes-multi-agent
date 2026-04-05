---
name: deep-research
description: "Deep research protocol — ALWAYS load this skill before any research task. For multi-stream research with parallel domain agents, use research-coordinator instead."
---

# Deep Research Protocol

> **For comprehensive multi-stream research, load `research-coordinator` instead.** It orchestrates parallel domain researchers (social media, code/ML, academic, market intelligence) and synthesizes a full intelligence brief.

This skill covers the simpler case: single-agent research with direct skill access.

**MUST LOAD THIS SKILL BEFORE ANY RESEARCH TASK.**

## Required Skills (load ALL of these first)

| # | Skill | Purpose |
|---|-------|---------|
| 1 | `web-research` | Web search, scraping, extraction |
| 2 | `youtube-content` | YouTube transcripts and video research |
| 3 | `xitter` | X/Twitter discussions and sentiment |
| 4 | `github-research` | GitHub repos, stars, issues, activity |
| 5 | `reddit-research` | Reddit communities and discussions |

## Workflow

```
STEP 1: skill_view() each of the 5 skills above IN ORDER
         (web-research, youtube-content, xitter, github-research, reddit-research)

STEP 2: For each skill, note:
        - Required tools/commands
        - Rate limits or usage notes
        - Key gh commands (for github-research)

STEP 3: Plan research subagents
        - Assign specific skills to each subagent based on their research focus
        - Pass the relevant skill names in the skills parameter

STEP 4: Spawn subagents with skills=[...] attached
        Example:
        sessions_spawn(
          task: "Research X using web-research + github-research + xitter skills",
          skills: ["web-research", "github-research", "xitter"]
        )

STEP 5: Synthesize results from all subagents
```

## Common Mistakes to Avoid

❌ DO NOT spawn subagents with just `toolsets: ["web"]`
✅ ALWAYS load the 5 skills first, then pass skills to subagents

❌ DO NOT skip skill loading "to save time"
✅ Research quality depends on having the right tools available

❌ DO NOT skip xitter if the topic likely has X/Twitter discussion
✅ Social sentiment is part of comprehensive research

## Trigger Conditions

Automatically load this skill when user says:
- "deep research"
- "do research on"
- "research this topic"
- "find out about"
- "investigate"
- Any variant of research requests

## This Skill Is Mandatory

If a research task is requested and this skill was NOT loaded, go back and load it before proceeding. No exceptions.
