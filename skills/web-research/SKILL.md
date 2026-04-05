---
name: web-research
description: "General-purpose web research protocol for any research task. Use when collecting data from the web, scraping pages, finding contact information, looking up companies, or any research requiring page access. Escalates through 5 methods: (1) sitemap.xml for site discovery, (2) Brave search for URL finding, (3) Firecrawl OSS for page scraping, (4) JSON API detection for dynamic content, (5) Playwright for JS-rendered pages. Triggers on: research, look up, find, check, scrape, fetch, investigate, analyze, or any task requiring web data extraction."
---

# Web Research Protocol

Generic escalation chain for any web research task.

## Domain Routing (Read Before Fetching)

Different domains require different strategies. Check this table first — using the wrong method will fail silently or return empty content.

| Domain | Method | Critical notes |
|--------|--------|---------------|
| `github.com/*` | `web_extract()` — basic only | **NEVER add Playwright/mobile flags** — GitHub detects and blocks them. Basic Firecrawl works fine. |
| `raw.githubusercontent.com` | `web_extract()` | Best way to get raw file content (READMEs, source files) |
| `reddit.com` | Use `old.reddit.com` | `www.reddit.com` returns a JS shell. Always rewrite URLs to `old.reddit.com` |
| `arxiv.org/abs/*` | `web_extract()` or `curl` API | Both work. For bulk paper lookup prefer the arXiv REST API |
| `news.ycombinator.com` | `web_extract()` | Plain HTML, works reliably |
| `youtube.com` | Use `youtube-content` skill | Firecrawl can't get transcripts — use the dedicated skill |
| Everything else | `web_extract()` standard | Default approach |

### Reddit URL rewrite rule
```python
# Always transform before fetching:
url = url.replace("www.reddit.com", "old.reddit.com")
url = url.replace("reddit.com/r/", "old.reddit.com/r/")
```

## Search Rate Limit Rule

**Do not fire more than 3 `web_search()` calls simultaneously.** Brave rate-limits at ~10 req/min per session. When running parallel research:
- Batch searches in groups of 3 max
- If you get a rate limit error (empty result or connection error), wait 15s before retrying
- Space out search batches rather than firing all at once

## URL Discovery (Always Do This First)

**No URL? Find it with Brave Search:**
```
web_search(query)
```
- Use when you don't know the exact URL
- Use when you need to verify a company's current info
- Use when you need to find the right page to scrape

**Know the domain? Try sitemap.xml first:**
```bash
curl -s "<url>/sitemap.xml" | grep -oP '<loc>\K[^<]+'
curl -s "<url>/sitemap.xml.gz" | zcat | grep -oP '<loc>\K[^<]+'
```
- **Best for:** Site-wide research, discovering all pages on a domain
- **Speed:** ~1-2 seconds for entire site
- **Fallback:** If no sitemap, use Brave Search to find individual pages

## 1. Firecrawl OSS (Primary Scraper)
Self-hosted, already running at `localhost:3002`.
```bash
curl -X POST http://localhost:3002/v1/scrape \
  -H "Content-Type: application/json" \
  -d '{"url":"<url>","formats":["markdown"]}'
```
**Best for:** Articles, docs, product pages, news, static HTML
**Speed:** ~2-5 seconds

## 2. JSON API Detection & Parsing
For pages with dynamically-loaded content or structured data. Many modern sites (SaaS platforms, directories, sports sites, fintech dashboards) load data via JSON APIs.

### Step 2a: Look for JSON Endpoints
Common patterns:
```bash
# API suffixes
curl -s "<url>/api/v1/<endpoint>"
curl -s "<url>/api/v2/<endpoint>"
curl -s "<url>/data.json"
curl -s "<url>/api/<resource>s"

# Query parameters
curl -s "<url>?format=json"
curl -s "<url>&callback=processData"

# GraphQL (for fintech/SaaS)
curl -s -X POST <url> -H "Content-Type: application/json" -d '{"query":"{ company { name } }"}'
```

### Step 2b: Detect Platform & Known APIs
Many platforms have predictable structures:

| Platform Type | Common Patterns |
|--------------|----------------|
| Sports/Athletics | PrestoSports, Sidearm - try `?lang=en` |
| Fintech/Finance | Stripe, Plaid - often `/api/v1/` |
| SaaS/Directories | Often `/api/data`, `/api/<resource>` |
| Job Boards | LinkedIn, Indeed - JSON in page source |
| News/Media | Content API at `/api/` or `/data/` |
| Government/Data | Often public JSON at `/data/` |

### Step 2c: Parse the Response
```python
import json
import requests

response = requests.get(url)
data = response.json()  # If valid JSON

# Navigate the structure
for item in data.get('results', []):
    name = item.get('name') or item.get('title')
    # extract what you need
```

### Step 2d: Quick Fetch
```bash
# Use web_fetch to get raw content, then parse
web_fetch(url="<url>", extractMode="text", maxChars=20000)
```

## 3. Playwright (JS-Rendered Pages)
When the above fail and the page requires JavaScript to render content.
- Use via Firecrawl's playwright-service (Docker stack)
- Or directly: `playwright chromium <url>`

**Best for:**
- Dashboards with live data
- Pages that load on scroll
- Sites with anti-bot protection that need full browser

## Decision Tree

```
START
  │
  ▼
No URL? ──────────────► Brave Search → URLs found
  │                                      │
  │                                      ▼
  │                              Firecrawl OSS
  │                                      │
  │                                      ├─ Success ─► Parse & extract
  │                                      │
  │                                      └─ Fail ───► JSON API → Playwright
  │
  Yes (have URL)
  │
  ▼
Sitemap.xml? ────Found──► Batch process with Firecrawl
  │
  ├─No sitemap
  │
  ▼
Firecrawl OSS ──────────► JSON API ────► Playwright
       │                      │
       │                      └─ Success ─► Parse & extract
       │
       └─ Success ─► Parse & extract
```

## Rate Limit Handling

| Code | Meaning | Action |
|------|---------|--------|
| 429 | Rate limited | Wait 30s, retry once |
| 420 | Firecrawl queue | Wait 60s, retry |
| 403/401 | Auth required | Skip to next method |
| 5xx | Server error | Retry with backoff |

```bash
# Exponential backoff
curl -X POST http://localhost:3002/v1/scrape \
  --retry 3 --retry-delay 30 \
  -H "Content-Type: application/json" \
  -d '{"url":"<url>","formats":["markdown"]}'
```

## Batch Processing (Large Tasks)

When research involves **more than 10-12 items**, split into batches to avoid timeouts.

### Batch Sizing
- **10-12 items per subagent** = safe within 10-min timeout
- **6-8 concurrent subagents** = covers 60-96 items per wave
- Each Firecrawl fetch takes ~2-5 seconds; 12 items fits in 10 min

### How to Batch

**Step 1: Split work into chunks of 10-12**
```
Batch 1: Items 1-12
Batch 2: Items 13-24
Batch 3: Items 25-36
...
```

**Step 2: Spawn subagents per batch (parallel)**
```bash
sessions_spawn(
  task: "Research these URLs using web-research protocol: [list URLs]",
  label: "batch-1-research",
  runTimeoutSeconds: 600
)
```

**Step 3: Synthesize results**
- Collect results from all subagents
- Merge into final output (CSV, report, etc.)
- Update your research file

### Sequential Fallback
If subagent spawning isn't available:
- Work in groups of 10-12
- Report progress between groups
- Use `read` to check existing state before each batch

## Key Rules

1. **Brave Search first** — don't guess URLs, search for them
2. **Sitemap for site-wide** — 1-2s beats crawling
3. **Firecrawl OSS primary** — self-hosted, reliable
4. **Escalate, don't skip** — try each step before moving to next
5. **JSON first when likely** — for known platforms, try API before HTML
6. **Batch large tasks** — never try 20+ pages in one turn
7. **Parse what you need** — don't just dump raw content, extract structured data
8. **Rate limits** — respect 429/420, use backoff

## Quick Reference

| Task | Start With | Fallback |
|------|------------|----------|
| Find URL | Brave Search | - |
| Find all pages on site | Sitemap.xml | Brave → crawl |
| Scrape article/docs | Firecrawl OSS | JSON API |
| Scrape contact pages | Firecrawl OSS | Playwright |
| Get financial data | JSON API | Firecrawl → Playwright |
| Research people | Brave Search | Firecrawl |
| Extract job listings | JSON API | Playwright |
| Anti-bot protected | Firecrawl | Playwright |
