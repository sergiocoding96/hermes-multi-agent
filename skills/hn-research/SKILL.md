---
name: hn-research
description: Research Hacker News stories, discussions, and community sentiment using web_search and web_extract. Use when you want to find HN threads about a topic, gauge technical community reaction, or find Ask HN / Show HN posts.
version: 1.0.0
author: Hermes Agent
metadata:
  hermes:
    tags: [hackernews, hn, community, tech-discourse]
    category: research
---

# Hacker News Research

Research Hacker News using `web_search` and `web_extract` — the same stack used across all Hermes research skills.

## Quick Start

```
# Find HN discussions about a topic
web_search(query="site:news.ycombinator.com TOPIC")

# Find recent Ask HN threads
web_search(query="site:news.ycombinator.com \"Ask HN\" TOPIC")

# Find Show HN posts
web_search(query="site:news.ycombinator.com \"Show HN\" TOPIC")

# Extract a specific thread (story + comments)
web_extract(urls=["https://news.ycombinator.com/item?id=ITEM_ID"])
```

## Research Workflow

### Step 1 — Discover threads

```
web_search(query="site:news.ycombinator.com TOPIC")
web_search(query="site:news.ycombinator.com TOPIC 2026")
```

Skim the results for:
- Thread titles with high comment counts (shown in search snippets)
- Ask HN threads ("Ask HN: Anyone using X?") — these reveal real practitioner experience
- Show HN posts — these are launches/demos that got community attention

### Step 2 — Extract high-signal threads

For each thread worth reading:

```
web_extract(urls=["https://news.ycombinator.com/item?id=ITEM_ID"])
```

Firecrawl renders the page and returns the story + top-level comments as markdown. Read the top 10-20 comments for signal.

### Step 3 — Broaden if needed

```
# Search for the topic in HN comments (not just titles)
web_search(query="site:news.ycombinator.com TOPIC criticism OR alternative OR broken")
web_search(query="site:news.ycombinator.com TOPIC vs OR compared OR benchmark")
```

### Step 4 — Check for specific paper/repo discussions

If you're researching an arXiv paper or GitHub repo:
```
web_search(query="site:news.ycombinator.com \"PAPER TITLE\"")
web_search(query="site:news.ycombinator.com \"github.com/OWNER/REPO\"")
```

## Common Patterns

| Goal | Query |
|------|-------|
| Community reaction to a tool | `site:news.ycombinator.com TOOL_NAME` |
| Real-world usage reports | `site:news.ycombinator.com "Ask HN" TOPIC` |
| Launch discussions | `site:news.ycombinator.com "Show HN" TOPIC` |
| Criticism / issues | `site:news.ycombinator.com TOPIC criticism OR issues OR problems` |
| Paper discussion | `site:news.ycombinator.com "arxiv" TOPIC` |

## Sentiment Signals

When reading threads, look for:
- **Top comment tone** — sets the frame for the whole discussion
- **Vote patterns** — high points + high comments = strong interest; high comments + implied low points = controversial
- **Recurring complaints** — same issue mentioned by multiple commenters = real problem
- **Expert identity signals** — "I work at X", "we built this" comments carry more weight
- **Ask HN answer quality** — a question with many detailed responses = practitioners actively using this

## Output Format

When reporting HN findings, structure as:

```markdown
## Hacker News Signals: [Topic]

### Top Threads
1. [Thread title] — [date if visible]
   URL: https://news.ycombinator.com/item?id=...
   Summary: [1-2 sentences on what the community said]

### Community Sentiment
[positive / negative / mixed / polarized — and why]

### Key Themes from Comments
- ...

### Ask HN Insights
[Any Ask HN threads revealing real-world usage or practitioner experience]
```

## Tips

- Search snippets often show comment counts — prioritize threads with 100+ comments
- HN indexes fast; recent launches (days old) often already have threads
- Use `web_extract` on the item page rather than trying to paginate comments — Firecrawl gets the top fold cleanly
- If a thread is very long (500+ comments), `web_extract` will get the top comments which are usually the highest quality
