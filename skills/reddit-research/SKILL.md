---
name: reddit-research
description: Research Reddit communities, discussions, sentiment, and trends. Use when user wants to understand community reactions, find discussions about a topic, or gather Reddit data for research.
---

# Reddit Research Skill

Research Reddit communities, discussions, and sentiment using web extraction and search.

## Quick Start

### Using web_extract (Primary Method)
```bash
# Extract subreddit info
web_extract(urls: ["https://old.reddit.com/r/PaperclipAI/"])

# Extract specific post
web_extract(urls: ["https://old.reddit.com/r/LocalLLaMA/comments/example/"])

# Search Reddit via web
web_search(query: "Paperclip AI agents site:reddit.com")
```

### Using web_search for Reddit
```bash
# Find discussions about a topic
web_search(query: "Paperclip AI orchestration reddit discussion")
web_search(query: "site:reddit.com paperclip zero human companies")
```

## Research Workflow

1. **Find communities**: Search for relevant subreddits
2. **Extract discussions**: Use web_extract on subreddit/post URLs
3. **Analyze sentiment**: Read comments for opinions, pain points, enthusiasm
4. **Track trends**: Check multiple posts for recurring themes

## Common Patterns

| Task | Approach |
|------|----------|
| Find subreddit | `web_search("PaperclipAI subreddit")` then extract |
| Hot posts | `web_extract("https://www.reddit.com/r/subreddit/hot/")` |
| Search posts | `web_search("paperclip AI agents site:reddit.com")` |
| Post comments | `web_extract("https://www.reddit.com/r/.../comments/...")` |

## Subreddit Discovery

```bash
# Find related subreddits
web_search(query: "site:reddit.com AI agent orchestration communities")
web_search(query: "site:reddit.com multi-agent framework discussion")
```

## Critical: Always Use old.reddit.com

**`www.reddit.com` returns a JavaScript shell — Firecrawl gets nothing useful.**
**Always use `old.reddit.com`** — it's plain HTML and Firecrawl returns 50K+ chars of real content.

```python
# Rewrite any reddit URL before fetching:
url = url.replace("www.reddit.com", "old.reddit.com")
# e.g. https://www.reddit.com/r/MachineLearning/ → https://old.reddit.com/r/MachineLearning/
```

Update the patterns table above accordingly:
| Hot posts | `web_extract("https://old.reddit.com/r/subreddit/hot/")` |
| Post comments | `web_extract("https://old.reddit.com/r/.../comments/...")` |

## Tips

- Always rewrite to `old.reddit.com` before any `web_extract` call
- Check both hot/new for complete picture of community sentiment
- Look at posts with high comment counts for major discussions
- Search using `site:reddit.com` in web_search for URL discovery, then rewrite to `old.` for extraction
