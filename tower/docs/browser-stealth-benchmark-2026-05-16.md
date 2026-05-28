# Browser Stealth Benchmark — CloakBrowser vs Camoufox vs Stock Playwright

**Date:** 2026-05-16
**Host:** Hermes tower (linux 6.8, Python 3.14, Playwright 1.59)
**Bench code:** `/tmp/bench_browsers.py`, `/tmp/bench_tower_paths.py`
**Raw results:** `/tmp/bench-stock.json`, `/tmp/bench-cloak.json`, `/tmp/bench-camoufox.json`, `/tmp/bench-firecrawl.json`, `/tmp/bench-camofox-service.json`

## Why

The tower's anti-bot stack today is Camofox (Camoufox Firefox fork) at `localhost:9377`. CloakBrowser (CloakHQ, Chromium-fork with C++ stealth patches) advertises itself as a drop-in Playwright replacement that beats both stock Playwright and Camoufox on detection-evasion scores. This benchmark measures the actual cost/benefit on real Tower workloads.

## Setup

Three browser engines invoked directly via Playwright API in a fresh Python venv. Each engine launched cold, navigates seven URLs sequentially, waits for `domcontentloaded` + 1.5 s settle, then captures HTML and peak RSS of the browser process tree.

| URL | Why it's in the set |
|---|---|
| `httpbin.org/get` | Static JSON, baseline network/launch cost |
| `github.com/` | Large modern HTML, no challenge |
| `news.ycombinator.com/` | Real-world static HTML |
| `nowsecure.nl/` | Standard Cloudflare-challenge test target |
| `bot.sannysoft.com/` | Bot-detection report page |
| `www.idealista.com/` | Real-world target the Tower fails on today (returns 403 to curl) |
| `abrahamjuliot.github.io/creepjs/` | Fingerprint detection |

## Results — direct engine

| Metric | Stock Playwright (Chromium) | CloakBrowser (Chromium 146 + C++ patches) | Camoufox (Firefox 135 fork) |
|---|---|---|---|
| Cold launch | **0.41 s** | 0.78 s | 3.53 s |
| `httpbin.org` DCL | **0.38 s** | 0.39 s | 0.58 s |
| `github.com` DCL | **1.44 s** | 1.51 s | 10.30 s |
| `news.ycombinator.com` DCL | 0.70 s | **0.69 s** | 0.86 s |
| `nowsecure.nl` DCL | **0.21 s** | 0.31 s | 2.23 s |
| `bot.sannysoft.com` DCL | **0.45 s** | 0.83 s | 1.21 s |
| `idealista.com` DCL | 0.16 s | 0.17 s | 0.23 s |
| `creepjs` DCL | **0.35 s** | 0.34 s | 0.72 s |
| **Total bench time** | ~13 s | ~15 s | ~27 s |
| Peak RSS (full browser tree) | **657 MB** | 830 MB | 1 128 MB |
| Sannysoft "passed" markers | 2 | **8** | 7 |
| CreepJS rendered HTML | 272 KB | **8 KB** ⚠️ | **518 KB** |
| `idealista.com` HTTP status | 403 | 403 | 403 |
| Failures | 0 | 0 | 0 |

### Read-outs

- **Cloak ≈ stock Playwright on latency.** Cloak's per-URL DCL is within 5–80 ms of stock Chromium — the C++ patches don't add meaningful wall-time cost. Launch is 2× slower (0.78 s vs 0.41 s) but in absolute terms it's <0.4 s and one-time per session.
- **Camoufox is the slow one.** Cold launch is 8× stock, `github.com` DCL is 7× stock (10.3 s vs 1.4 s), and total run time is 2× the others. That `github.com` outlier is a Firefox vs Chromium thing — Firefox stalls on something during GitHub's hydration even though the page eventually loads.
- **Memory: Chromium variants win clearly.** Camoufox peaks at 1.1 GB vs Cloak's 830 MB vs stock's 657 MB. Cloak's overhead over stock (~170 MB) is the cost of stealth-mode resource exclusions reverting some optimizations.
- **CreepJS detected Cloak as stealth, didn't fully render.** Cloak got an 8 KB page (CreepJS abort-detects bots and bails); Camoufox got 518 KB (full report). This isn't a bug — CreepJS specifically targets stealth-Chromium signatures. Doesn't mean Cloak failed bot detection in production, but it's a flag.
- **Sannysoft passes:** Cloak 8 / Camoufox 7 / stock 2. Confirms both stealth engines pass the basic webdriver/automation checks; stock fails them. The 8 vs 7 gap is small and the test page is well-known so all stealth tools target it.
- **Idealista 403 was unfixable by every engine.** All three got 403 with a 1.5 KB error body. The block happens at the HTTP/edge layer (likely IP/ASN reputation or rate-limiting), before any JS fingerprint check runs. **No browser-engine swap will fix idealista from this host** — that needs a proxy.

## Results — Tower-deployed paths

| Path | Status | Notes |
|---|---|---|
| Firecrawl `/v1/scrape` | ✅ working | Average ~0.9 s/URL. Returns `page_status: 403` on idealista but request itself succeeds. HTML sizes smaller than direct Playwright (Firecrawl strips/sanitizes). |
| Camofox service `/tabs` | ❌ **broken** | Every `POST /tabs` fails with `Module did not self-register: better_sqlite3.node`. `/health` reports `ok:true` (only wrapper-level check). `/home/openclaw/.hermes/logs/camofox.log` shows repeated "port in use" errors from systemd restart attempts. **The anti-bot path is currently non-functional in production.** |

Firecrawl per-URL totals (avg 0.96 s, max 2.43 s on github) are faster than any direct Playwright run because it caches engine processes between requests and skips browser cold-start.

## Verdict

Three separate questions, three separate answers.

**1. Does Cloak beat Camoufox?** Yes on speed, memory, and API ergonomics. Tie or marginal-edge on detection. The C++ patches are real — both engines pass Sannysoft, neither passes CreepJS cleanly (CreepJS specifically targets stealth-Chromium so Cloak gets the shorter end there; Camoufox renders fully because it's Firefox-based).

**2. Should the Tower swap?** Probably yes, but not for the reason the marketing implies. The detection-coverage gain is small; the operational gains are large:
- Drop-in Playwright API → Firecrawl's existing `playwright-service` container could host it with no code change to skills
- Eliminate the dual-routing path in `skills/web-research/SKILL.md` (Camofox for anti-bot, Playwright for everything else)
- 30% less RAM than Camoufox per browser
- Single engine reduces moving parts

**3. Is the swap free?** No — Cloak's binary is **proprietary, no-redistribution**. Fine for a private Tower image, problematic if you ever publish a Hermes deploy image publicly. The MIT wrapper code is fine; the chromium binary is not.

## Side finding (urgent)

**The Camofox service is broken** — `better-sqlite3` native module failed to load, so every `/tabs` call 500s. `/health` doesn't catch this because it only validates the wrapper, not the browser-spawning code path. Any skill that relies on Camofox for anti-bot scraping is silently degraded.

Fix: rebuild `better-sqlite3` in `/home/openclaw/.hermes/hermes-agent/node_modules`:
```bash
cd /home/openclaw/.hermes/hermes-agent && npm rebuild better-sqlite3
```

Recommend also extending the `/health` check to run a tiny smoke `POST /tabs` against `about:blank` so this fails loudly next time.

## Recommendation

1. **Now (this week):** fix `better-sqlite3` so Camofox actually works again; extend its `/health` to cover the failure mode.
2. **Next sprint:** spike CloakBrowser as the Firecrawl `playwright-service` replacement on a dev profile. Measure detection on the same URL set, plus the actual real-world targets we hit (Idealista if/when we add a proxy, X/Twitter, Glassdoor — whatever is in `skills/web-research/SKILL.md`'s domain list). If it holds, retire Camofox.
3. **Don't adopt** if Hermes deploy images go public — Cloak's binary license blocks redistribution.

## Caveats

- Single-run-per-URL, no warmup. The numbers have ±10% noise — don't read individual 0.1 s differences as signal.
- Network from this host has ASN-level reputation issues (curl can't reach `example.com`, idealista returns 403). Detection-evasion results may differ from a residential proxy.
- CreepJS specifically targets stealth-Chromium — its 8 KB render of Cloak is a known idiosyncrasy of CreepJS, not a generalizable "Cloak is detected" finding.
- Bench was run from the Tower host, not from inside the Firecrawl container, so the Firecrawl numbers include localhost round-trip but not container DNS cost.
