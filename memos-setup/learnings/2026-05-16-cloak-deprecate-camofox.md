# Decision: Cloak service replaces Camofox as primary stealth scraper

**Date:** 2026-05-16
**Author:** sergio + claude (collaborative session)
**Status:** Phase 1 + Phase 2 both deployed. Camofox kept hot as warm-rollback target; no longer in the production traffic path.

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

## Phase 2 — completed same day (2026-05-16)

All Camofox interactive endpoints now mirrored in the Cloak service:

| Endpoint | Camofox | Cloak (`localhost:9378`) | Notes |
|---|---|---|---|
| `POST /tabs` | ✓ | ✓ | per-(user, session) BrowserContext, full assets |
| `POST /tabs/:id/navigate` | ✓ | ✓ | networkidle wait + refs reset |
| `GET /tabs/:id/snapshot` | ✓ | ✓ | **byte-for-byte format match** — see diff-test below |
| `POST /tabs/:id/click` | ✓ | ✓ | with auto-refresh on stale ref + mouse-sequence fallback |
| `POST /tabs/:id/type` | ✓ | ✓ | click + clear + type (delay 30ms) + optional Enter |
| `POST /tabs/:id/scroll` | ✓ | ✓ | `page.mouse.wheel(0, ±600)` |
| `POST /tabs/:id/press` | ✓ | ✓ | `page.keyboard.press()` |
| `POST /tabs/:id/back` | ✓ | ✓ | `page.go_back()` + refresh refs |
| `GET /tabs/:id/screenshot` | ✓ | ✓ | PNG base64 |
| `DELETE /sessions/:userId` | ✓ | ✓ | closes all tabs + context |

**Implementation:** `/home/openclaw/.hermes/cloak-service/interactive.py` (~450 LOC). Uses Playwright Python's `page.locator('body').aria_snapshot()` which produces identical YAML to Camofox's Node Playwright. Refs are server-side state, built by parsing the YAML in document order and tagging interactive roles; `[eN]` markers injected into the snapshot text before return so `browser_camofox.py` parsing works unchanged.

### Diff-test result (HN homepage, same URL, same wall-clock)
- Camofox: `refsCount=222, totalChars=41004`
- Cloak:   `refsCount=222, totalChars=41004`
- Diff: 182 lines, **100% content drift** (HN updated story timestamps and vote counts between the two scrapes) — **0% format drift**
- Ref positions match: `e15` resolves to the same DOM node in both engines

### End-to-end validation
Full agent-style flow against Cloak (`/tmp/e2e_cloak_as_camofox.py`):
- `POST /tabs` (HN): 1.41 s
- `GET /snapshot`: 0.23 s, 222 refs with `[eN]` markers
- `POST /click` (ref=e3, "new" link): 5.61 s, navigated to `/news`
- `GET /snapshot` (post-click): 0.10 s
- `POST /navigate` (DDG): 1.22 s
- `POST /back`: 0.60 s
- `GET /screenshot`: 0.13 s, 270 KB PNG
- `DELETE /sessions/:userId`: 0.04 s

All assertions passed.

### Cutover (the actual production flip)
- Backed up `.env` to `~/.hermes/.env.pre-cloak-flip`
- Changed `CAMOFOX_URL=http://localhost:9377` → `http://localhost:9378`
- Restarted: `hermes-gateway`, `hermes-gateway-arinze`, `-hr-agent`, `-krati`, `-research-agent`, `-sergio` — all came back `active`
- Camofox service is **still running** as warm-rollback target, but receives no agent traffic. Decision: stop+disable only after ~1 week of clean production operation.

### Rollback (single command, ~30 s)
```bash
sed -i 's|^CAMOFOX_URL=http://localhost:9378$|CAMOFOX_URL=http://localhost:9377|' ~/.hermes/.env
systemctl --user restart hermes-gateway hermes-gateway-arinze hermes-gateway-hr-agent hermes-gateway-krati hermes-gateway-research-agent hermes-gateway-sergio
```
…or restore from `~/.hermes/.env.pre-cloak-flip`.

### Phase 3 — when ready
- After ~1 week of clean operation: stop + disable Camofox systemd, leave install in `node_modules/` for any future code reference
- Mark `tools/browser_camofox.py` as deprecated in its module docstring (don't rename — would break imports in `browser_tool.py`)
- Optionally move the Cloak service source from the Tower host into this repo under `tower/services/cloak-service/` so it's version-controlled

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
