# MemOS v1 — Is It Ready for an MVP?

**A plain-language verdict from the post-fix re-audit (8 blind audits)**
Run date: 2026-04-30
Audience: a founder making a ship / wait decision today

---

## The one-paragraph answer

**Yes — you can ship an internal MVP today.** After **one 30-minute config change** (rate-limit), the system handles your actual demo path: CEO + per-team Hermes agents + Telegram, single-memory writes per turn, stable tower. **No** — don't push this to 5+ external teams unattended. That's a different bar and you'd want a ~1 week of polish first. The fix sprint cleanly closed the original Phase 6 ship-blockers (auth restoration, secret redaction, retry queue, auto-capture, systemd guard); the post-fix audit found new latent issues at edges of the system, but only **two of them touch your actual demo path**.

---

## The headline numbers

The strict rule (lowest sub-area in each audit, averaged) says 2.0. The honest measure (every sub-area scored) says 5.7. Neither is the right number for **your** question. The right number is "what actually breaks the demo path I'm shipping?" — and that's a much shorter list.

| How you measure | Pre-fix (Apr 26) | Post-fix (Apr 30) |
|---|---|---|
| **Strict rule** (mean of MINs across 8 audits) | 1.25 / 10 | **2.0 / 10** |
| **Honest mean** (every sub-area scored, averaged across 93 checks) | 5.2 / 10 | **5.7 / 10** |
| **Sub-areas scoring 7+ ("works well")** | 47 / 100 (47%) | **40 / 93 (43%)** |
| **Sub-areas scoring 1–2 ("broken")** | 17 / 100 (17%) | **15 / 93 (16%)** |
| **Sub-areas in your demo path that score 7+** | n/a | **most of them** |

**A note on why the strict rule didn't move much.** The post-fix audit was *tougher* than the pre-fix one — auditors probed concurrent writes, edge cases, and load patterns the original audit didn't. New findings ≠ regressions. The fixes you shipped (auth, redaction, retry queue, auto-capture, systemd guard) all landed and work. What lowered some scores was genuinely new probes catching latent issues that were always there in the code. **Both audits assessed the same v1 server; the post-fix numbers are stricter, not worse infrastructure.**

---

## What works for your demo path (you can rely on these today)

These scored 7+ in the post-fix audit. Real wins from the sprint.

- **Authentication.** BCrypt verify works with key-prefix bucketing — bad-key DoS attack from 3.6 s down to ~0 ms (PR #7 + #15). Score: **9/10**.
- **Cube isolation.** Research-agent's memories cannot leak to email-marketing-agent. Tested every plausible bypass; the wall held. Score: **9/10**.
- **Identity from environment, not LLM.** Plugin reads agent identity from profile env. The LLM cannot override or impersonate via prompt injection. Score: **10/10**.
- **Network exposure.** Everything bound to localhost. Nothing reachable from the internet by default. Score: **9/10**.
- **Secret redaction across 4 storage layers.** State.db (PR #6), Hermes profile USER.md/MEMORY.md (PR #26 + #27), session JSON dumps (PR #27), and MemOS storage all redact bearer tokens, API keys, JWTs, AWS keys, PEM blocks, emails, SSNs, cards before write *and* on context-load read. The cross-turn leak that was T2 in Phase 6 is now closed.
- **Auto-capture.** Plugin captures turn content via `post_llm_call` hook with no explicit `memos_store` calls (PR #14). Identity from env, durable retry queue if MemOS is down, dedup ring of 3 per session. Score: **8/10**.
- **CEO multi-cube reads.** MCP server (re-pointed at v1 in PR #21) and bash scripts both work. The CEO can search across all worker cubes through `CompositeCubeView`. Score: **10/10** for the tool surface, with one nit at 6/10 — see "Concerning but won't break your demo" below.
- **Memory writes for normal load.** Single memory per turn lands cleanly. Fast-mode writes ~84 ms, search ~5–7 ms, async writes return to caller in ~5 ms. The retry queue catches transient Qdrant outages. Score: **6–9/10** depending on sub-area.
- **MemOS auto-restart on crash** (PR #25, RES/9). `kill -9 → service back up within 12 s`. Closes the operational risk where a crash meant manual intervention.
- **Database protection from injection.** Parameterized queries throughout. SQL-injection attempts fail at the auth gate. Score: **9/10**.

If your demo is one CEO orchestrator + a few team agents storing memories one at a time, recalling them across sessions, and the CEO synthesizing across cubes — **most of it works.**

---

## What actually breaks your demo path (must-fix before shipping)

Of the 15 sub-areas scoring 1–2 across all audits, exactly **two** affect your actual MVP demo. Total fix time: ~half a day.

### 1. Rate limit caps at 100 requests / 60 s globally per IP (~30 min)

**The problem in plain terms:** All your agents on the same Hermes host share one budget — 100 calls every minute. Three teams active at once = one team can stall for the next minute every time they hit limit. Demo target is 100 qps; today's cap is ~1.7/s.

**Your demo impact:** Email-marketing-agent batch-sending personalized emails per recipient → first one succeeds, then 429 for the next minute. CEO reading 5 cubes in parallel for a synthesis → one cube's worth of data, then throttled. **Visibly broken** within minutes of multiple teams using the system.

**The fix:** Either (a) raise the env var `MEMOS_RATE_LIMIT_PER_MINUTE` from 100 to a higher number like 1000–10000, or (b) re-key the rate limiter from per-IP to per-authenticated-user (~half-day of code; the env var is ~30 minutes). For an internal MVP, the env var bump is enough.

### 2. Phone-redactor over-matches numeric content (~4 hours)

**The problem in plain terms:** The phone-number regex was written aggressively to catch real phone numbers, but it also matches any 10–14 digit run. Unix timestamps, DOIs like `2024-1234567890`, campaign IDs — all get corrupted to `[REDACTED:phone]` *before* storage. The original number is gone.

**Your demo impact:** If your agents handle prose without numeric IDs (chat, research summaries about non-numeric topics), this never triggers. If they store anything with timestamps, paper DOIs, order numbers, campaign IDs → those memories are corrupted on the way in. Research-agent quoting a paper with a DOI → broken.

**The fix:** Tighten the phone regex to require explicit phone-shape (`+`, hyphens, parentheses) instead of bare digit runs, OR move redaction to display-time with a tokenized reversible mapping. Half-day at most.

If your demo's content is non-numeric prose, you can ship without this fix and document it as a known limitation. If your demo will store DOIs / timestamps / campaign IDs in memory bodies, fix this first.

---

## Concerning but won't break your demo (document and defer)

These are real findings the auditors caught, but they don't affect your specific demo path. Note them in your "known limitations" page; revisit when you scale beyond MVP.

- **Concurrent batch writes silently dedup at 0.90 cosine threshold.** If a research agent stores 50 memories in one turn, only ~7 land — the other 43 are silently considered duplicates. **You only hit this if agents do batch-store of many memories at once.** Workaround: have agents write one memory per turn (which is the natural flow anyway).
- **Neo4j split-brain on outage.** A Neo4j hiccup mid-write can leave Qdrant and Neo4j out of sync; orphans don't auto-reconcile. Stable tower means rare; deal with it manually if you see search results come back inconsistent.
- **Legacy Qdrant orphans (33% on research-cube).** Historical leftover from before the fixes — about a third of old Neo4j entries lack matching Qdrant points. Doesn't affect new writes; doesn't affect demo content stored fresh. Defer cleanup.
- **No `/metrics` Prometheus endpoint.** Operations watches logs. Fine for an internal MVP where you're the operator. Add later if you onboard a real ops team.
- **CEO multi-cube search loses `cube_id` provenance in results.** When CEO synthesizes across research + email-marketing cubes, results don't carry "which agent said this." Workaround: CEO can ask each agent directly for source attribution. 4-hour fix when you want it.
- **Provisioning script has rough edges.** Adding a new team agent isn't a one-line script today — it's manual editing + run + chmod. One-time pain per team, not demo-blocking.
- **`agents-auth.json` deployed at 0664 (world-readable).** Run `chmod 600` at deploy time and forget. Any local user could read the BCrypt hashes; not a key extraction risk, but tighten the perm.
- **Per-IP rate-limit aggregation across all agents on the same Hermes host.** Already covered as the must-fix above; mentioning here to flag that a per-user rekeying is the long-term answer.

---

## What it looks like in a real demo

Concrete scenarios with your actual planned use case.

### Scenario 1 — CEO orchestrating a research synthesis

You ask the CEO: *"Have the research agent summarize Q1 results, store them, and tell me what stands out."*

**Today (post-fixes, after the rate-limit bump):**
1. Research agent stores findings via auto-capture. Memories land cleanly.
2. CEO calls `memos_search("Q1 results")` via the MCP server. Returns hits across the research cube.
3. CEO synthesizes and replies.
4. **Edge case:** if research-agent's findings include DOI citations, those numbers may be corrupted in storage. Fix the phone regex if that matters for your content.

**Pre-fix (before the sprint):**
1. Same prompt. Auth fails immediately (`agents-auth.json` was missing) — every API call returned 401. Demo broken on step 2.

### Scenario 2 — Secret in a chat turn

A team agent stores a memory containing *"the SendGrid test key is sk-test-DEMO123ABC"*.

**Today:**
1. Hermes session DB redacts the secret before INSERT (PR #26).
2. USER.md and session JSON dumps also get redacted (PR #27).
3. MemOS storage redacts (PR #6).
4. Cross-turn recall: agent says `[REDACTED:sk-key]`, not the raw value.
5. **Demo passes:** security review can't catch this leak.

**Pre-fix:**
1. Secret lands raw in 4 separate places.
2. Agent recalls it verbatim across turns.
3. **Demo fails:** any security review fails on day one.

### Scenario 3 — MemOS Qdrant briefly unreachable

Qdrant flaps for 5 seconds during a fine-mode extraction.

**Today:**
1. Sync write returns HTTP 503 (PR #8 — fail-loud).
2. Caller can retry.
3. Async extraction lands in retry queue, drains when Qdrant comes back.
4. **No silent loss.** Demo robust to a transient hiccup.

**Pre-fix:**
1. HTTP 200 returned to caller.
2. Extraction silently lost.
3. Demo *appears* to work but the memory is gone — discovered later when CEO can't find it.

### Scenario 4 — Three teams active at once

Three agents writing memories concurrently to their own cubes.

**Today (without the rate-limit bump):**
1. First few requests work. Then HTTP 429s start hitting all three teams.
2. **Visibly broken** — agents stall waiting for the rate-limit window.

**Today (with the rate-limit bump — the 30-min config change):**
1. All three teams write freely up to the new cap.
2. Demo holds for a stretch session with a few teams active.

---

## What the previous PDF said vs what this one says

| Question | 2026-04-26 PDF | 2026-04-30 PDF |
|---|---|---|
| Headline verdict | Fixable in 1–2 weeks | **Ship-ready today after a 30-min config change (internal MVP)** |
| Strict MIN of MINs | 1.25 | 2.0 |
| Mean of all sub-areas | 5.2 | 5.7 |
| Number of must-fix items | 5 | **2 for your demo path; ~5 if you want the strict-rule MIN to clear 4** |
| Top wins called out | none yet | Auth, redaction across 4 layers, retry queue, auto-capture, systemd guard, CEO MCP |
| Top remaining gaps | auth, redaction, retry queue, auto-capture, delete cleanup, rate limiter | Rate limiter (config), phone redactor (4 hours), concurrent dedup (deferrable), Neo4j split-brain (deferrable) |

**The story changed from "infrastructure broken" to "infrastructure works; one config tweak away from a working demo."**

---

## My recommendation

### Ship the internal MVP this week. Two things to do first:

1. **30-min config change**: bump `MEMOS_RATE_LIMIT_PER_MINUTE` (or the equivalent env var) from 100 to a comfortable number (1000+ for a friendly-team demo). Confirm with a quick smoke test: 200 requests in a minute should all succeed.
2. **Decide on the phone redactor**: if your demo content is prose without numeric IDs → ship and defer the fix. If it has DOIs / timestamps / IDs → spend 4 hours tightening the regex first.

Then ship. Document these as known limitations in a 1-pager for operators:
- Don't have agents do batch-store of many memories in one turn (write one per turn instead — natural pattern anyway).
- If MemOS infra hiccups (Qdrant or Neo4j brief outage), check for memory-search inconsistencies and re-store anything that didn't land.
- Rate limit set to N per minute — alert if you see 429s; raise the cap if you scale up.

### Don't ship to 5+ external teams unattended yet.

For that bar, the auditors' 5-day sprint plan is the right scope:
- Re-key rate limit by authenticated user (not per-IP)
- Neo4j split-brain prevention (re-raise on outage instead of partial commit)
- Dedup response shape (so the API tells callers when a write was deduped vs created)
- PII redactor tightening (production-grade)
- Prometheus `/metrics` endpoint + per-request `user_id` binding

That work isn't blocking your internal MVP. Schedule it for the week after you ship.

### Don't restart from scratch on a different memory system.

The fix sprint validated v1's architecture. The remaining issues are tactical, not architectural. v2 (the deprecated plugin) and any third-party alternative would put you back at zero on the bug-shaking work you've already done.

---

## Per-audit one-liners

For your records and for anyone who wants the per-area breakdown.

| # | Audit | MIN | Mean of sub-areas | Pre-fix MIN | Headline |
|---|---|---:|---:|---:|---|
| 1 | Zero-Knowledge Security | 5 | 7.9 | 3 | Auth, isolation, identity-from-env, redaction across 4 layers all working. Some perimeter rough edges (XFF spoofing, world-readable auth file). |
| 2 | Functionality | 1 | 6.2 | 0 | Core write/search/dedup happy path works. Concurrent batch writes silently dedup (rare in your use case). |
| 3 | Resilience | 2 | 4.6 | 2 | Retry queue works on Qdrant outage. Neo4j split-brain on outage; LLM extraction silent-drop. Stable infra masks both. |
| 4 | Performance | 2 | 6.0 | 1 | Latency excellent (84ms write, 5–7ms search). Rate limit is the bottleneck — config-change fix. |
| 5 | Data Integrity | 1 | 4.4 | 1 | Fresh writes consistent across stores. Legacy data has 33% Qdrant orphans (historical). PII filter destroys numeric content. |
| 6 | Observability | 1 | 4.0 | 1 | No `/metrics`. Operator watches logs. Acceptable for internal MVP, not for production. |
| 7 | Plugin Integration | 3 | 7.7 | 1 | Tool contract and identity model excellent. Auto-capture solid. Hub URL allowlist is one perimeter gap. |
| 8 | Provisioning | 1 | 4.5 | 1 | Manual provisioning works once you know the steps. Painful per-team setup. One-time, not demo-blocking. |

**Aggregates:** strict mean-of-MINs = 2.0, mean of all 93 sub-areas = 5.7. Cross-cutting wins from the fix sprint clearly landed; remaining issues are concentrated outside the demo path.

---

## When you are ready to ship

- 30-min config change (rate limit) ✅
- Decide on phone redactor ✅
- Smoke test: CEO + 2 team agents, single-memory-per-turn, no batches ✅
- Known-limitations page published with the 3 caveats above ✅
- Operator (you) on-call for the first week ✅

Then ship the internal MVP.

For the broader rollout, the auditors' 5-day sprint is the path. Not now; not blocking now.
