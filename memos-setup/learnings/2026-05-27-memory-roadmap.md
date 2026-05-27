# 2026-05-27 — Memory system roadmap (post-recovery)

Plan for the open items after the 2026-05-26/27 capture-outage recovery + quality overhaul
(see [`2026-05-26-capture-outage-rca-recovery.md`](2026-05-26-capture-outage-rca-recovery.md)).
Three "bridge" items are one root problem — **N gateways each spawn a full `bridge.cts` memos
core that loads BGE-large**, and `bridge.cts` runs `bootstrapMemoryCoreFull()` (incl. dirty-episode
reflection) **before** `server.listen`. So there's a cheap-mitigation vs proper-fix choice.

**Process note (standing):** every future memory change updates the comprehensive memory report —
edit `docs/architecture/2026-05-27-memory-comprehensive-report-deck.html`, run
`tools/build-memory-report.sh` to regenerate the PDF, commit, and refresh the Drive Doc.

## Phase 1 — Stability relief (low-risk, first)
- **1.1 Background the boot-reflection** (S/Low) — start the HTTP server first, then run dirty-episode
  reflection on a capped background task. Files: `bridge.cts`, `core/pipeline/bootstrap*.ts`, `core/capture/capture.ts`.
  Verify: `:18800` answers 200 within seconds even with N dirty episodes.
- **1.2 Serialize bridge boots** (S–M/Low) — `flock` on `~/.hermes/memos-plugin/.bridge-boot.lock`
  around the cold-boot so only one BGE-large load runs at a time. Files: `adapters/hermes/memos_provider/daemon_manager.py`, `__init__.py`.
  Verify: restart all 8 gateways → boots serialize, load bounded, no leak. *(Phase 3 removes this.)*
- **1.3 Auto-prune dead skills** (S/Low) — archive skills with `usage_count=0` + low support/gain after
  a grace window (never delete). Files: `tools/` maintenance script, `core/storage/repos/skills.ts`.
- **1.4 Stress-test web-stack non-fatal when idle** (XS) — SKIP (not FAIL) Firecrawl/SearXNG when the
  on-demand stack is stopped. File: `tools/stress-test.sh`.

## Phase 2 — Close the feedback loop (medium)
- **2.1 Auto per-step verifier** (M/Med) — on episode close, an LLM judge scores each step → writes
  `feedback` rows via `feedback.submit` → `runRepair` makes failure-avoidance repairs. Route to
  NVIDIA-free fallback (background). Files: `core/feedback/feedback.ts`, `core/capture/capture.ts`, `core/feedback/subscriber.ts`.
- **2.2 Implicit next-turn human signal** (M/Med) — next user turn labels the prior agent turn
  (correction/re-ask → negative; acceptance → positive) as a `UserFeedback` row, no extra LLM call.
  Files: `core/capture/capture.ts`, `core/reward/human-scorer.ts`.

## Phase 3 — Proper architecture (large; schedule deliberately)
- **3.1 Shared single daemon** (L/Med-High) — expose capture/retrieval RPCs over the `:18800` daemon
  HTTP API; convert the Python adapter from bridge-spawner to **HTTP client** of that one daemon.
  One model load total; per-gateway bridges retired. **Supersedes 1.2 and mostly 1.1.**
  Files: `server/http.ts`, `bridge.cts`, `adapters/hermes/memos_provider/*`, `daemon_manager.py`.
- **3.2 Explicit 👍/👎 channel** (S–M/Low) — Discord reactions / slash-command on agent replies →
  `feedback.submit` with polarity. Pairs with 2.1/2.2.

## Sequencing & decision
Do **Phase 1 now** (ends the spiral + slow boots), then **Phase 2** (outcome-graded reward), then
schedule **Phase 3** (the real fix). Key decision: **1.2 serialize-boots (cheap, now) vs 3.1
shared-daemon (proper, later)** — do both, in that order; 1.2 buys safety while 3.1 is planned/tested.
All plugin changes go through `tools/plugin-patches/` + `postinstall-patches.sh`, with daemon restart
+ `tools/stress-test.sh` per change.
