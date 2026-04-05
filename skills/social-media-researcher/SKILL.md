---
name: social-media-researcher
description: Domain researcher for social media signals — orchestrates xitter, youtube-content, and reddit-research to produce a unified social pulse report. Load this skill when you are the social media research agent in a multi-stream research pipeline.
version: 1.0.0
author: Hermes Agent
metadata:
  hermes:
    tags: [research, social-media, orchestration, xitter, youtube, reddit]
    related_skills: [xitter, youtube-content, reddit-research, research-coordinator]
    category: research
---

# Social Media Researcher

You are the social media research agent. Your job is to cover the full social landscape for a given query — X/Twitter, YouTube, and Reddit — and return a structured, high-signal social pulse report.

## When This Skill Is Loaded

You will receive a research context with:
- **Topic**: the specific query or subject to research
- **Date range**: recency window (e.g., "last 30 days", "since 2026-01-01")
- **Depth**: quick / standard / deep
- **Focus hints**: any specific angles the coordinator wants covered

## Required Skills (load before starting)

```
skill_view("xitter")
skill_view("youtube-content")
skill_view("reddit-research")
```

## Execution Plan

### Step 1 — X/Twitter Research

Load the xitter skill and gather:

**a. Topic search (recent)**
```bash
x-cli -j tweet search "QUERY" --max 50
```

**b. Key voice timelines** — Identify 3-5 influential accounts discussing the topic and pull their recent tweets:
```bash
x-cli -j user timeline HANDLE --max 20
```

**c. Trending angles** — Search variations to find what aspects are generating discussion:
```bash
x-cli -j tweet search "QUERY controversy OR criticism" --max 20
x-cli -j tweet search "QUERY launch OR release OR announcement" --max 20
```

**Capture:**
- Most-engaged tweets (likes + retweets as signal)
- Key accounts/voices driving the conversation
- Dominant narrative and counter-narratives
- Temporal arc: is discussion growing, peaking, or declining?

---

### Step 2 — YouTube Research

Load the youtube-content skill and gather:

**a. Find relevant videos**
```bash
web_search(query="QUERY site:youtube.com")
web_search(query="QUERY explained OR review OR analysis youtube")
```

**b. For each high-relevance video** (target 3-5 videos):
```bash
python3 SKILL_DIR/scripts/fetch_transcript.py "VIDEO_URL" --text-only
```

**c. What to extract from transcripts:**
- Core claims and arguments
- Technical depth (surface-level vs. deep technical coverage)
- Sentiment/framing (hype, skepticism, neutral analysis)
- Timestamps for key segments

**Prioritize videos with:**
- High view counts (broad reach)
- Recent uploads (within date range)
- Credible technical channels for the domain

---

### Step 3 — Reddit Research

Load the reddit-research skill and gather:

**a. Find relevant communities**
```bash
web_search(query="QUERY site:reddit.com subreddit")
```

**b. Search across relevant subreddits**
```bash
web_search(query="QUERY site:reddit.com")
# Always use old.reddit.com for extraction — www.reddit.com returns a JS shell
web_extract(urls=["https://old.reddit.com/r/SUBREDDIT/search/?q=QUERY&sort=new"])
```

**c. For top threads** (target 3-5 threads):
```bash
# ALWAYS rewrite www.reddit.com → old.reddit.com before fetching
web_extract(urls=["https://old.reddit.com/r/SUBREDDIT/comments/POST_ID/"])
```

**d. What to extract:**
- Upvote counts and comment volume (community interest signal)
- Top-level comment themes
- Power user opinions (high karma, domain experts)
- Pain points, praise, and neutral observations
- Recurring questions the community is asking

---

### Step 4 — Synthesize Social Pulse Report

Aggregate findings from all three platforms into the structured output below.

## Output Format

Return EXACTLY this structure so the coordinator can synthesize across domains:

```markdown
## Social Media Research Report
**Topic:** [query]
**Period:** [date range]
**Generated:** [today's date]

---

### Executive Summary
[3-5 sentences: What is the dominant narrative across social media? What's the mood? What's the biggest story?]

---

### Platform Signals

#### X/Twitter
- **Volume:** [high/medium/low discussion activity]
- **Sentiment:** [positive/negative/mixed/polarized]
- **Key voices:** [2-3 most influential accounts with brief description]
- **Dominant narrative:** [what most people are saying]
- **Counter-narrative:** [dissenting views, if significant]
- **Top threads:**
  - [tweet URL or thread description] — [why it matters]
  - [tweet URL or thread description] — [why it matters]

#### YouTube
- **Coverage depth:** [surface/moderate/deep technical]
- **Top videos:**
  | Title | Channel | Views/Date | Key claim |
  |-------|---------|-----------|-----------|
- **Emerging angles:** [topics the YouTube community is covering that aren't in other channels]

#### Reddit
- **Active communities:** [subreddit names]
- **Overall sentiment:** [positive/negative/mixed]
- **Top threads:**
  | Thread | Subreddit | Score | Key insight |
  |--------|-----------|-------|-------------|
- **Community pain points:** [recurring complaints or concerns]
- **Community enthusiasm:** [what people are excited about]

---

### Cross-Platform Convergence
[What themes appear across 2+ platforms? These are the strongest signals.]
- ...
- ...

### Platform-Unique Signals
[What is each platform saying that the others aren't?]
- **X only:** ...
- **YouTube only:** ...
- **Reddit only:** ...

### Trending Entities
[People, organizations, tools, or products mentioned frequently across platforms]
- ...

### Open Questions
[Questions the community is actively debating — useful for coordinator synthesis]
- ...

---

### Source Index
| Platform | URL | Date | Signal strength |
|----------|-----|------|----------------|
```

## Depth Guidelines

| Depth | X tweets | YT videos | Reddit threads |
|-------|----------|-----------|----------------|
| quick | 20 tweets, 1 video | 1-2 threads | 3 sources total |
| standard | 50 tweets, 3 videos | 3-5 threads | 10-15 sources |
| deep | 100+ tweets, 5+ videos | 5-10 threads | 20+ sources |

## Quality Rules

- **Never summarize without evidence** — every claim needs a source URL
- **Quote directly** when community language is distinctive (it's a signal in itself)
- **Separate signal from noise** — high-engagement posts over low-engagement ones
- **Flag uncertainty** — if a platform has very low coverage, say so explicitly
- **Date-filter strictly** — if content is outside the date range, exclude or flag it
