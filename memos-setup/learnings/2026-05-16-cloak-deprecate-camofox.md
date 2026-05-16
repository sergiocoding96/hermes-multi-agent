# Decision: Cloak service replaces Camofox as primary stealth scraper

**Date:** 2026-05-16
**Author:** sergio + claude (collaborative session)
**Status:** Phase 1 deployed; Phase 2 (Camofox interactive endpoint mirror) planned

## TL;DR

We benchmarked CloakBrowser (Chromium 146 + C++ stealth patches) against Camoufox (Firefox fork with C++ patches) and stock Playwright. **All three engines handle DataDome's silent JS challenge** when IP reputation is clean; only the stealth engines pass. Cloak edges Camoufox on speed (~3.9 s vs ~4.8 s per page on Idealista), launch (0.78 s vs 3.53 s), RAM (830 MB vs 1.13 GB), and crucially exposes a **drop-in Playwright API** that lets us consolidate the web stack on one engine.

Camofox stays in place as the interactive browser backend (`browser_*` agent tools) until Cloak service grows feature parity in Phase 2. All new scrape work routes to Cloak.

## Why this change

### Benchmark findings (`tower/docs/browser-stealth-benchmark-2026-05-16.md`)

| Engine | Cold launch | Avg DCL | Peak RSS | Idealista (clean IP) |
|---|---|---|---|---|
| Stock Playwright | 0.41 s | 0.53 s | 657 MB | ❌ blocked, 3 retries on DataDome challenge |
| CloakBrowser | 0.78 s | 0.61 s | 830 MB | ✅ 124 KB real page, 3.9 s |
| Camoufox | 3.53 s | 2.30 s | 1.13 GB | ✅ 224 KB real page, 4.8 s |

The Chromium-vs-Firefox engine difference is the main speed gap (`github.com` took 10.3 s in Firefox vs 1.5 s in either Chromium variant). Detection-evasion is roughly tied between stealth engines.

### Operational problems with current setup

1. **Camofox service was broken** on production Tower — `better-sqlite3` native module failed to load, `/tabs` endpoint returned 500, `/health` lied with `ok: true`. Fixed via `npm rebuild` in same session but reveals brittleness.
2. **Firecrawl's `playwright-service`** uses stock Chromium — fails on every DataDome-protected site. Skills had to manually domain-route.
3. **Two stealth stacks to maintain**: Camofox (Node + Camoufox + Firefox) and stock Playwright (Chromium). Duplicate code paths in `skills/web-research/SKILL.md` domain-routing tables.

### The IP reputation reality

During benchmarking we ran 20+ sequential requests from the Tower's home IP and triggered DataDome's `t:'fe'` interactive captcha mode. **Both stealth engines fail equally** in this state — it's not engine-discriminable. The fix is hygiene (persistent context, pacing, fingerprint stickiness, referer chains) and/or CapSolver fallback, both of which we built into the Cloak service rather than retrofitting Camofox.

## What changed (Phase 1, today)

### New: Cloak scraping service
- **Path:** `/home/openclaw/.hermes/cloak-service/`
- **Port:** 9378
- **systemd unit:** `~/.config/systemd/user/cloak-service.service` (enabled, auto-restart)
- **Endpoints:**
  - `GET /health` — service + browser status + warm-domain list
  - `POST /v1/scrape` — Firecrawl-compatible scrape (returns `{success, data: {html, markdown, metadata}, challenge}`)
  - `POST /v1/save-pdf` — render URL to PDF on disk
  - `GET /v1/balance` — CapSolver credit balance
- **Features built in:**
  - Per-domain `BrowserContext` with persistent cookies in `cloak-service/profiles/<domain>/cookies.json`
  - Per-domain pacing (`CLOAK_MIN_DOMAIN_INTERVAL_S=8` default)
  - Asset blocking (images/CSS/fonts) — cuts bandwidth ~80%
  - DataDome challenge detection + optional CapSolver retry
  - Spanish locale + Europe/Madrid timezone defaults (matches Tower's home IP geo)

### CapSolver integration
- Library: `capsolver==1.0.7` Python SDK
- Activated by setting `CAPSOLVER_API_KEY` env var
- Drop-in template at `~/.config/systemd/user/cloak-service.service.d/capsolver.conf.example`
- Currently **disabled** (no API key set). Cost at projected volume: ~$1/month.

### Skill and docs updates
- `skills/web-research/SKILL.md` — adds §4 "Cloak Stealth Service", lists DataDome / Imperva / Cloudflare Turnstile domains routing here
- `CLAUDE.md` — Architecture section updated, "When to use which tool" table updated, Commands section gets Cloak health-check + systemd commands

### Interim fix to Camofox
- Rebuilt `better-sqlite3` via `npm rebuild` in `/home/openclaw/.hermes/hermes-agent/`
- Camofox `/tabs` confirmed working again
- Restored interactive browser tool while Phase 2 is pending

## What's deferred (Phase 2)

The Cloak service does not yet expose the interactive `/tabs/:id/{snapshot,click,type,scroll,press,back,screenshot}` endpoints that `tools/browser_camofox.py` requires for the agent's `browser_*` skill calls. The accessibility-snapshot format (refs + tree extraction) is ~400 LOC of careful Playwright wrapping and was out of scope today.

**Phase 2 plan:**
1. Mirror Camofox's `/tabs/:id/snapshot` using `page.accessibility.snapshot()` + a ref-assignment shim
2. Mirror `/tabs/:id/{click,type,scroll,press,back,screenshot}` (thin Playwright wrappers)
3. Switch `CAMOFOX_URL` env to point at port 9378 (Cloak service)
4. Stop + disable `camofox.service`
5. Mark `~/.hermes/hermes-agent/tools/browser_camofox.py` as deprecated (keep file for rollback)

Estimated effort: 1 focused day. Risk: ARIA snapshot format mismatch breaks `browser_*` skill flows until tuned. Should be done on a feature branch with the existing Camofox e2e tests as the regression bar.

## Rollback path

If Cloak service misbehaves in production:
1. `systemctl --user stop cloak-service.service`
2. `systemctl --user disable cloak-service.service`
3. Revert `skills/web-research/SKILL.md` (the §4 addition + domain-routing table edits)
4. Revert `CLAUDE.md` Architecture + tool-table sections
5. Camofox is untouched in Phase 1 — interactive browser keeps working without action

Cloak service has no shared state with Camofox or Firecrawl. Failure is fully contained.

## Tier 1 cost projection

Current scrape volume across Hermes skills: ~hundreds of pages/day, mixed domains, low single-digit percent hitting DataDome.

| Component | Cost |
|---|---|
| CloakBrowser | $0 (open source wrapper, free binary) |
| Cloak service hosting | $0 (runs on Tower) |
| CapSolver (when enabled, ~30 captchas/mo) | ~$0.72/mo |
| **Tier 1 total** | **~$1/mo** |

Scaling ceiling from single Tower IP without proxy rotation: ~10–20k pages/day to a single anti-bot domain. Beyond that → Tier 2 (ISP proxies, ~$30/mo) or Tier 3 (rotating residential, ~$150/mo). Not currently needed.

## Cross-references

- Benchmark report: `tower/docs/browser-stealth-benchmark-2026-05-16.md`
- Skill doc: `skills/web-research/SKILL.md` §4
- Service source: `/home/openclaw/.hermes/cloak-service/cloak_service.py`
- systemd unit: `/home/openclaw/.config/systemd/user/cloak-service.service`
- Camofox tool (still active): `/home/openclaw/.hermes/hermes-agent/tools/browser_camofox.py`
