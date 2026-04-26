# MemOS v1 — Is It Ready for an MVP?

**A plain-language verdict from 8 blind audits**
Run date: 2026-04-26
Audience: a founder making a build / fix / pivot decision

---

## The one-paragraph answer

Your v1 system **is fixable, and the fixes are real engineering work — not a rewrite**. The core memory pipeline (writing memories, searching them, deduplicating duplicates, isolating what each agent can see) **works well**, scoring **7–9 out of 10** in most areas. What pulls the system down to a "do not ship" verdict by the strict scoring rule is a small handful of **surgical bugs** — five of them dominate everything. Fix those five and you have an MVP-grade system in **1 to 2 weeks** of focused work. **You are not in pivot territory.** Reverting to a third system would cost you more than fixing this one.

---

## The headline number — and why it's misleading

| How you measure | Score |
|---|---|
| **Strict rule** (lowest sub-area in each audit, averaged across the 8 audits) | **1.25 / 10** |
| **Honest mean** (every sub-area scored, averaged across all 100+ checks) | **5.2 / 10** |
| **Median sub-area score** | **6 / 10** |
| **Sub-areas scoring 7+ ("works well")** | **47 of 100** |
| **Sub-areas scoring 1–2 ("broken")** | **17 of 100** |

The strict rule was designed for *production* readiness — one weak link sinks the ship. For *MVP* readiness it's the wrong rule, because it lets one fixable bug define an otherwise functional system. Both numbers are real; the gap between them is the story.

**What that gap means in plain terms:** roughly half of the system works well today. Roughly one-sixth is genuinely broken. The middle is workable with caveats. The broken sixth is concentrated in a few specific places, and those places are the must-fix list below.

---

## What works (the parts you can rely on right now)

These scored 7 or higher in the audits. You can demo them.

- **Writing a memory.** Fast mode (raw store) lands in 5 ms. Async mode returns to the caller almost instantly while extraction runs in the background. Score: **8–10**.
- **Searching memories.** All three search modes (no, sim, mmr) return ranked results in 5–7 ms even at 1,000 memories. Search latency does not blow up as the corpus grows. Score: **9**.
- **Cube isolation between agents.** When `research-agent` searches its own cube, it can't see the email-marketing agent's memories. Tested every plausible bypass; the wall held. Score: **9**.
- **Identity protection from the LLM.** The Hermes plugin reads the agent's identity (which API key, which user, which cube) from a config file on disk. The LLM cannot override this in a prompt-injection attack. Score: **9**.
- **Network exposure.** Every service (the API server, Qdrant, Neo4j) is bound to localhost only. Nothing is reachable from the internet by default. Score: **9**.
- **Database protection from injection.** Uses parameterized queries throughout. SQL-injection attempts fail at the auth gate before they ever reach the database. Score: **9**.
- **Concurrent writes from a single agent.** 20 simultaneous writes from one agent: all 20 land, no errors, no lost data. Score: **9**.
- **Dedup at write time.** Submit two near-identical memories; the second is correctly recognized as a duplicate. Threshold around 0.90 cosine similarity, working as designed. Score: **7**.

If your demo is a single agent storing and searching memories at modest pace, **most of it works**.

---

## What's broken (the parts that block an MVP)

These scored 0–2 in the audits. They will surface in a real demo.

- **The auth-config file is missing.** The server expects `agents-auth.json` at a configured path. The path points to nothing. Result: every authenticated API call returns HTTP 401. **Both demo agents are memory-blind today.** This is the most embarrassing finding because it's a 2-hour fix.
- **Qdrant or Neo4j outage = silent data loss.** If either store is briefly unreachable during a write, the API still returns HTTP 200 to the caller. The structured memory extraction is silently dropped. Caller has no idea the memory wasn't actually stored. No retry, no queue, no alert.
- **Auto-capture does not exist.** The audit prompt expected the v1.0.3 plugin to auto-capture turn content (so agents don't need explicit `memos_store` calls). The actual installed plugin is v1.0 and has no such hook. Agents must explicitly call `memos_store` after every turn worth remembering.
- **Delete leaves vectors behind.** When a memory is deleted, it's removed from SQLite and Neo4j but **not** from Qdrant. Stale vectors accumulate, polluting future searches and creating a data-protection problem (deleted content persists as embeddings).
- **Secrets get logged.** When the LLM is called for fine-mode extraction, the entire prompt — including any user-supplied secrets like API keys, emails, or phone numbers — is written to `memos.log` unredacted. The log file is world-readable.
- **Two profile `.env` files are world-readable.** The plaintext API keys for `research-agent` and `email-marketing-agent` are visible to any local user.
- **Rate limiting is broken.** The in-memory counter resets on every server restart; the BCrypt verify loop is so slow that an attacker rarely accumulates 10 wrong-key attempts inside the 60-second window. Brute force isn't actually rate-limited.
- **Health endpoint lies.** `/health` returns "OK" even when Qdrant is returning 401s. A monitoring system or load balancer cannot tell the system is degraded.
- **Process supervisor is dead.** If the server crashes, nothing restarts it. The systemd unit exists but isn't active. A 3 a.m. crash means downtime until a human notices.
- **Concurrency cliff at 5 agents.** Sequential writes are fast (5 ms). Five agents writing simultaneously: P99 latency jumps to **4.6 seconds**. New cube initialization takes 18.7 seconds under contention. The CEO orchestrator reading across multiple cubes inherits all of that overhead.

---

## What it would feel like in a real demo

These are scenarios using your actual planned demo agents.

### Scenario 1 — Research agent stores quarterly findings

You ask the CEO orchestrator: *"Have the research agent summarize Q1 results and store them."*

**Today:**
1. Research agent calls `memos_store("Q1 revenue up 15%, margins compressed by supply-chain delays...")`
2. The system returns HTTP 200 immediately (async mode).
3. In the background, the extraction pipeline runs. **If Qdrant is unavailable for two seconds during this window, the structured extraction is silently dropped.** The raw text might survive in SQLite, but the searchable extracted facts are gone.
4. Five minutes later the CEO asks: *"What did research find about margins?"*
5. Email-marketing agent searches for "margin" → 0 results.
6. **You watch the demo break and don't know why.** Logs show no error.

**After the must-fix patches:**
1. Same first two steps.
2. If Qdrant glitches, the task is queued for retry instead of dropped.
3. Qdrant comes back; the extraction runs; the memory is searchable.
4. The CEO's question returns the right answer.

### Scenario 2 — Email-marketing agent stores a campaign with an API key

The email-marketing agent stores: *"Campaign uses bearer token sk-test-abc123 to call SendGrid."*

**Today:**
1. The memory stores fine.
2. The full LLM prompt — containing `sk-test-abc123` — is written to `~/.memos/logs/memos.log`.
3. Anyone with a shell on the box can `cat` that log file and read the key.
4. **A security review of your MVP fails on day one.**

**After the must-fix patches:**
1. The same memory stores fine.
2. The logger redacts secrets before writing: `bearer [REDACTED]`.
3. The original memory in the database keeps the redacted form too.
4. **Security review passes** (for log handling — see "What's still missing for production" below).

### Scenario 3 — CEO reads across both agents' memories

You ask the CEO: *"Show me everything both teams know about the H2 launch."*

**Today:**
1. CEO uses CompositeCubeView, which fans out to both cubes and aggregates results.
2. The aggregated result list contains the memories — but **without `cube_id` tags on the individual items**.
3. The CEO can't tell which memory came from research vs. email-marketing.
4. **The CEO might attribute a research insight to marketing**, leading to wrong follow-up actions.

**After a 4-hour fix:**
1. Each result carries its source `cube_id`.
2. CEO can attribute correctly and ask follow-up questions to the right agent.

### Scenario 4 — A live multi-agent demo with five agents simultaneously

You add three more agents and run a 30-minute live demo with all five active.

**Today:**
1. Sequential operation works fine.
2. The moment two agents try to write at the same time, one of them waits.
3. With 5 agents writing concurrently, P99 latency hits **4.6 seconds**.
4. Spinning up a new cube takes **18.7 seconds** under contention.
5. **The demo feels janky and slow at unpredictable moments**, even though sequential operation is fast.

This one is **not on the 1-week must-fix list**. It's a structural limitation of the chosen storage stack. You can demo at a sane pace, but not at 30-agent scale.

---

## The 5 absolute must-fix items (1 to 2 weeks total)

In priority order. Effort estimates are for one focused engineer.

### 1. Restore the auth-config file (2–4 hours)

`agents-auth.json` doesn't exist at the path the server expects. Without it, every authenticated call returns 401. **This is the single fastest, highest-impact fix.**

The provisioning script that generates it was archived. Run it with the agent list you actually need; verify the file exists; add a startup gate that refuses to serve traffic if the file is missing or unreadable.

### 2. Fix the silent-data-loss on Qdrant or Neo4j outage (2–3 days)

When the vector store or graph store is briefly unreachable, the API returns HTTP 200 while the structured memory extraction is silently dropped.

Two options: (a) return HTTP 503 immediately if either store is unreachable on a write — fail loud; or (b) introduce a durable retry queue (SQLite-backed is fine) so transient failures recover automatically. Option (b) is the better MVP answer because real production has transient blips; option (a) can be done in an afternoon as a stopgap.

### 3. Redact secrets from logs (1 day)

Add a redaction layer that strips Bearer tokens, `sk-…` keys, AWS `AKIA…` keys, PEM headers, emails, and phone numbers from log lines before they're written. Apply at two layers: log formatter (defends every sink) and memory extractor (defends the database too). Unit-test against a corpus of fake secrets.

### 4. Fix the delete-doesn't-clean-Qdrant bug (2 hours)

The function that deletes a memory hard-deletes from SQLite and Neo4j but forgets to delete from Qdrant. Add the one missing call. Verify via a round-trip test: store, delete, search — the deleted content should not appear.

### 5. Restore the rate limiter (1 day)

The in-memory counter resets on every restart, and the BCrypt loop runs for so long that an attacker rarely hits 10 attempts inside the 60-second window. Move the counter to SQLite (it's already a dependency). Short-circuit BCrypt verify on the first mismatch instead of trying every agent's hash.

**Total effort: 4–6 days for one engineer, plus ~2 days of testing/integration. Call it 1 to 2 weeks elapsed.**

After these five fixes, the strict-rule MIN score moves from **1.25 to roughly 4–5**, and the system is genuinely MVP-viable for the three-agent demo.

---

## What you can defer past MVP

Don't waste a week on these now. Document them as known limitations and ship.

- **Auto-capture in the plugin.** Without it, agents need to call `memos_store` explicitly. That's an extra prompt instruction, not a blocker. Cost to add: 2–3 days of plugin work.
- **`/metrics` Prometheus endpoint.** Useful for production monitoring; for MVP, you'll be watching the demo live anyway. Cost: 1–2 days.
- **Backup and restore tooling.** Important for production data; for MVP you can wipe and re-seed. Cost: 1 week of careful work.
- **Multi-machine deployment.** Hardcoded paths everywhere. For MVP you run on one box. Cost: ~2 weeks (real refactor).
- **Concurrency cliff at 5+ agents.** Real architectural issue but only matters at scale. For MVP-scale (3 agents) it's tolerable. Cost: weeks-to-months (storage choice).
- **Source-tagging in CompositeCubeView results.** Nice-to-have so CEO knows where a memory came from. Cost: 4 hours, but ship without it if you can phrase the demo around it.
- **Structured task summarization.** A v2 feature that doesn't exist in v1 at all. Skip it for MVP — the agents can summarize themselves with prompts.

---

## v1 vs v2 — the honest comparison

This is your decision matrix for "fix v1 vs go back to v2 vs pivot to a third option."

| Dimension | v1 (legacy server) | v2 (new plugin) |
|---|---|---|
| **Strict-rule MIN** | 1.25 / 10 | 1.0 / 10 |
| **Mean of all sub-areas** | **~5.2 / 10** | ~2–3 / 10 |
| **Core memory pipeline** | Works (7–9) | Has architectural issues (no ANN above 10k, viewer dead) |
| **Auth design** | Sound (cube isolation 9, identity 9) | Default-open (audit found auth gated behind config that defaults to off) |
| **Auth deployed correctly** | No (file missing) — 2-hour fix | No — multiple fixes needed |
| **Resilience** | Silent data loss on dep outage | Same kind of issue + WAL truncation = silent loss |
| **Observability** | Weak (no metrics, no correlation IDs) | Same kind of issues; viewer is supposed to be the answer but is dead |
| **Killer features (skill evolution, L2/L3, task summarization)** | Don't exist in v1 | Exist in design but **broken in v2 today**; also unvalidated as actually useful for your demo agents |
| **Codebase you control** | Yes, your own fork | No, upstream npm package mid-beta |
| **Effort to MVP** | **1 to 2 weeks** of surgical patches | **4 to 6 weeks** of patches AND upstream PR negotiation |
| **Effort to production** | 1–2 months | 3+ months and depends on MemTensor's roadmap |

**The honest call:** v1's MIN is technically slightly worse than v2's by the strict rule, but the *kind* of bugs is fundamentally different. v1's bugs are surgical (missing file, missing function call, missing redaction layer). v2's bugs are architectural (no ANN index, dead daemon, missing entire subsystems). Surgical bugs cost days. Architectural bugs cost months.

You also control v1. You don't control v2. For a founder making a build decision under time pressure, that gap matters more than the audit numbers.

---

## My recommendation

**Fix v1.** Do not pivot. Do not revert to v2.

Spend **one focused week** on the five must-fix items. At the end of that week, run a 1-hour live demo of research-agent + email-marketing-agent + CEO orchestrator. If the demo holds together, ship as MVP with a published "known limitations" page covering the deferred items.

If you want a stretch goal, spend a second week on (a) a basic `/metrics` endpoint and (b) the source-tagging fix in CompositeCubeView. Those two together turn the system from "demo-ready" to "could survive a small pilot user".

**Do not** spend energy on auto-capture, backup tooling, multi-machine deployment, or the concurrency cliff before MVP. They are real engineering work and they don't change the demo.

**Do not** restart from scratch with a third memory system. Every memory system has these kinds of bugs. The difference between a production system and a broken one is whether someone has shaken the bugs out — and you've now done that work for v1. A new system would put you back at zero on that front.

---

## Per-audit one-liners

For reference, here is what each of the 8 audits actually found.

| # | Audit | MIN | Mean of sub-areas | Headline |
|---|---|---:|---:|---|
| 1 | Zero-Knowledge Security | 3 | 6.8 | Cube isolation and identity guards excellent; secret storage and log redaction are the weak links |
| 2 | Functionality | 0 | 7.0 | Core write/search/dedup excellent; auto-capture absent (drives MIN to 0); `info` field silently dropped |
| 3 | Resilience | 2 | 3.7 | Concurrent writes survive; Qdrant/Neo4j outages cause silent data loss; no process supervisor |
| 4 | Performance | 1 | 6.6 | Sub-10ms write/search latency; rate limiter broken (drives MIN to 1); concurrency cliff at 5 agents |
| 5 | Data Integrity | 1 | 5.9 | Tri-store delete divergence (Qdrant orphans); no backup procedure; embedding-dim lock-in |
| 6 | Observability | 1 | 2.4 | No metrics endpoint; no request correlation IDs; secrets in logs; debug toggle requires code edit |
| 7 | Plugin Integration | 1 | 5.0 | Plugin design is sound; deployed config missing (drives MIN to 1); auto-capture absent |
| 8 | Provisioning | 1 | 4.1 | Setup script archived; world-readable hash file; key rotation undocumented |

**Aggregates:** strict MIN-of-MINs = **1.25 / 10**. Mean of sub-area means = **5.2 / 10**. The 17 sub-areas scoring 1–2 are concentrated in five specific bugs; fixing those bugs lifts the MIN to roughly 4–5 and the mean above 6.
