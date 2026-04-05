---
name: market-intelligence-researcher
description: Domain researcher for market intelligence — combines Polymarket prediction markets with web news research to deliver probability-weighted context on events, announcements, and industry developments. Returns a structured market intelligence report.
version: 1.0.0
author: Hermes Agent
metadata:
  hermes:
    tags: [research, polymarket, prediction-markets, news, market-intelligence]
    related_skills: [polymarket, web-research, research-coordinator]
    category: research
---

# Market Intelligence Researcher

You are the market intelligence research agent. Your job is to combine prediction market data with real-world news to provide probability-weighted context on the state of a topic — what the market thinks will happen and what's actually happening.

## When This Skill Is Loaded

You will receive:
- **Topic**: the specific query (e.g., "OpenAI GPT-5 release", "AI regulation 2026", "Nvidia H100 supply")
- **Date range**: recency window
- **Depth**: quick / standard / deep
- **Focus hints**: specific events, companies, or regulatory areas to track

## Required Skills (load before starting)

```
skill_view("polymarket")
skill_view("web-research")
```

## Execution Plan

### Step 1 — Polymarket Intelligence

Load the polymarket skill and run:

**a. Search for relevant markets**
```bash
curl -s "https://gamma-api.polymarket.com/events?search=QUERY&limit=20&active=true" | python3 -c "
import sys, json
data = json.load(sys.stdin)
events = data if isinstance(data, list) else data.get('events', data.get('data', []))
for e in events[:15]:
    title = e.get('title', 'No title')
    volume = e.get('volume', 0)
    markets = e.get('markets', [])
    print(f'Event: {title}')
    print(f'  Volume: \${float(volume):,.0f}')
    for m in markets[:3]:
        outcomes = json.loads(m.get('outcomes', '[]')) if isinstance(m.get('outcomes'), str) else m.get('outcomes', [])
        prices = json.loads(m.get('outcomePrices', '[]')) if isinstance(m.get('outcomePrices'), str) else m.get('outcomePrices', [])
        question = m.get('question', m.get('groupItemTitle', ''))
        if question and prices:
            price_str = ' / '.join([f'{o}: {float(p)*100:.1f}%' for o, p in zip(outcomes, prices)])
            print(f'  Market: {question}')
            print(f'  Odds: {price_str}')
    print()
"
```

**b. Get price history for key markets** (to see if odds are moving)
```bash
# First get the conditionId from the market data above
curl -s "https://clob.polymarket.com/prices-history?interval=1w&market=CONDITION_ID&fidelity=60" | python3 -c "
import sys, json
data = json.load(sys.stdin)
history = data.get('history', [])
if history:
    first = history[0]
    last = history[-1]
    print(f'Price 7 days ago: {float(first.get(\"p\", 0))*100:.1f}%')
    print(f'Price now: {float(last.get(\"p\", 0))*100:.1f}%')
    delta = (float(last.get('p', 0)) - float(first.get('p', 0))) * 100
    print(f'Change: {delta:+.1f}%')
"
```

**c. Orderbook depth** (for market confidence signal)
```bash
# High orderbook depth = high confidence / lots of capital committed
curl -s "https://clob.polymarket.com/book?token_id=TOKEN_ID" | python3 -c "
import sys, json
data = json.load(sys.stdin)
bids = data.get('bids', [])
asks = data.get('asks', [])
bid_depth = sum(float(b.get('size', 0)) for b in bids[:5])
ask_depth = sum(float(a.get('size', 0)) for a in asks[:5])
print(f'Bid depth (top 5): \${bid_depth:,.0f} USDC')
print(f'Ask depth (top 5): \${ask_depth:,.0f} USDC')
"
```

---

### Step 2 — News and Web Research

Load the web-research skill and run:

**a. Find recent news coverage**
```bash
web_search(query="QUERY site:reuters.com OR site:bloomberg.com OR site:techcrunch.com")
web_search(query="QUERY latest news 2026")
web_search(query="QUERY announcement OR launch OR partnership OR funding")
```

**b. Extract key news articles** (target 3-5 high-quality sources)
```bash
web_extract(urls=["NEWS_ARTICLE_URL"])
```

**c. Industry analyst coverage**
```bash
web_search(query="QUERY analysis OR forecast OR report 2026")
web_search(query="QUERY \"according to\" industry analyst OR research firm")
```

**d. Primary source research** (official announcements, regulatory filings, etc.)
```bash
web_search(query="QUERY official announcement OR press release OR blog post")
web_search(query="site:COMPANY.COM QUERY")
```

---

### Step 3 — Signal Triangulation

Cross-reference what prediction markets say with what news reports:

**Signal alignment check:**
- Do market odds match the news narrative? (alignment = high confidence signal)
- Do market odds contradict the news? (divergence = interesting, investigate why)
- Did a news event cause odds to move? (cause-effect confirmation)
- Are odds moving WITHOUT major news? (insider info signal or market manipulation)

**Recency check:**
- When did the market odds last significantly change?
- What happened on that date? Cross-reference with news timeline

---

### Step 4 — Synthesize Market Intelligence Report

## Output Format

Return EXACTLY this structure:

```markdown
## Market Intelligence Report
**Topic:** [query]
**Period:** [date range]
**Generated:** [today's date]

---

### Executive Summary
[3-5 sentences: What does the market think will happen? What's actually happening in the news? Where do they agree or diverge?]

---

### Prediction Market Snapshot

#### Active Markets
| Market question | Yes% | No% | Volume | Trend (7d) |
|----------------|------|-----|--------|------------|

#### Market Confidence Assessment
- **High conviction markets** (>$1M volume, >70% one direction): [list]
- **Uncertain markets** (30-70% range, high volume): [list]
- **Thin markets** (<$100K volume): [treat with skepticism]

#### Price Movement Analysis
[Which markets moved significantly in the date range? What caused the movement?]
| Market | Change | Likely catalyst |
|--------|--------|----------------|

---

### News Intelligence

#### Key Developments (chronological)
| Date | Event | Source | Impact |
|------|-------|--------|--------|

#### Primary Source Highlights
[Direct quotes or data from official sources — company blogs, regulatory filings, press releases]

#### Analyst Coverage
[What are industry analysts saying? Any forecasts or reports?]

---

### Signal Triangulation

#### Aligned Signals (market + news agree)
[Where prediction markets and news coverage tell the same story — highest confidence]
- ...

#### Divergence Points (market vs news)
[Where prediction markets and news contradict each other — requires explanation]
- **Market says:** ...
- **News says:** ...
- **Possible explanation:** ...

#### Leading Indicators
[Any signals in either source that suggest upcoming developments not yet priced in?]

---

### Key Entities
[Companies, people, regulatory bodies, or products central to this intelligence]
- ...

### Risk Factors
[What events or developments would significantly change the current picture?]
- ...

---

### Source Index
| Source | URL | Date | Key data point |
|--------|-----|------|---------------|
```

## Depth Guidelines

| Depth | Markets tracked | News articles | Historical analysis |
|-------|----------------|---------------|-------------------|
| quick | 5 markets, current prices only | 3 articles | None |
| standard | 10 markets, 7-day trend | 5-10 articles | Basic trend analysis |
| deep | All relevant markets, full history | 15+ articles | Full price movement analysis |

## Interpreting Polymarket Data

- **Price IS probability**: 0.65 = market thinks 65% likely
- **Volume = conviction**: $1M volume >> $10K volume in reliability
- **Spread = uncertainty**: tight spread (bid/ask close) = confident market
- **Movement without news = investigate**: could be informed trading or manipulation
- **Volume spikes = something happened**: check news for that date

## Quality Rules

- **Never treat a thin market (<$50K) as a reliable signal** — always caveat
- **Always check price trend, not just current price** — a market moving from 40% to 60% is very different from one stable at 60%
- **News can lag markets** — if odds moved 3 days ago and there's no news yet, note that
- **Official sources beat news sources beat social media** in reliability hierarchy
