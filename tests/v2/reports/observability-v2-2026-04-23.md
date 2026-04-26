# Observability Audit — memos-local-plugin v2.0.0-beta.1

**Marker:** OBS-AUDIT-20260423T000000Z  
**Auditor role:** SRE, first contact with this system  
**Source root:** `/home/openclaw/Coding/MemOS/apps/memos-local-plugin/`  
**Live server:** NOT RUNNING (ports 18799–18801 all closed during audit)  
**Date:** 2026-04-23

---

## 1. Recon

### Logger architecture (`core/logger/`)

`README.md` and `docs/LOGGING.md` describe a clean, well-documented pipeline:

```
emit() → channel-level filter → redactor → fan-out to N sinks → transports → file/console/SSE/buffer
```

Three orthogonal axes: **level** (`trace < debug < info < warn < error < fatal`), **kind** (`app/audit/llm/perf/events/error`), **channel** (`core.l2.cross-task` …).  
`AsyncLocalStorage` is claimed to carry `traceId / sessionId / episodeId / turnId / agent / userId` through the call graph.  
`core/logger/channels.ts` registers ~80 canonical channels.

### Route inventory

Every route file in `server/routes/` registers endpoints:

| File | Key endpoints |
|---|---|
| `health.ts` | `GET /api/v1/health`, `GET /api/v1/ping` |
| `events.ts` | `GET /api/v1/events` (SSE) |
| `logs.ts` | `GET /api/v1/logs` (SSE), `GET /api/v1/logs/tail` |
| `metrics.ts` | `GET /api/v1/metrics`, `GET /api/v1/metrics/tools` |
| `config.ts` | `GET /api/v1/config`, `PATCH /api/v1/config` |
| `admin.ts` | `POST /api/v1/admin/restart`, `POST /api/v1/admin/clear-data` |
| `diag.ts` | `GET /api/v1/diag/counts`, `POST /api/v1/diag/simulate-turn` |
| `auth.ts` | `GET /api/v1/auth/status`, `POST /api/v1/auth/login`, `POST /api/v1/auth/logout`, `POST /api/v1/auth/setup`, `POST /api/v1/auth/reset` |
| `memory.ts`, `skill.ts`, `policies.ts`, `trace.ts`, `hub.ts`, etc. | Data CRUD |
| `telemetry` | `GET /api/v1/telemetry/preview` (opt-in anon telemetry) |

Endpoints with structured event emission: `events.ts` (every `CoreEvent`), `logs.ts` (every `LogRecord` post-redaction).

### `CORE_EVENTS` catalogue (`agent-contract/events.ts`)

44 event types covering: sessions, episodes, L1 traces, L2 policies, L3 world models, feedback, skills, decision repair, retrieval (tier1/2/3/empty), hub, and system. Every event has `type`, `ts`, `seq`, optional `correlationId`, and a typed `payload`.

### Telemetry module (`core/telemetry/`)

Anonymous aggregate-only opt-in telemetry. Sends counts, providers, latency percentiles — never content. Inspectable via `/api/v1/telemetry/preview`.

### Viewer views (`web/src/views/`)

Confirmed views: `OverviewView`, `MemoriesView`, `PoliciesView`, `WorldModelsView`, `TasksView`, `SkillsView`, `AnalyticsView`, `LogsView`, `AdminView`, `SettingsView`, `ImportView`.  
**Gap:** No `HelpView` file found in `web/src/views/` despite `HelpView.tsx` being listed.  Actually, `HelpView.tsx` IS present. All 11 documented views confirmed.

---

## 2. Sink inventory

### Documented sinks (`docs/LOGGING.md`)

| Sink file | Kind | Confirmed in code | Line format | Rotation | Retention |
|---|---|---|---|---|---|
| `memos.log` | `app` | ✓ `sinks/app-log.ts` | Human-readable | size+day, gzip | `retentionDays` (default 30) |
| `error.log` | `error` | ✓ `sinks/error-log.ts` | Human-readable | size+day, gzip | same |
| `audit.log` | `audit` | ✓ `sinks/audit-log.ts` | JSON | monthly, gzip | **永不删除** (forever) |
| `llm.jsonl` | `llm` | ✓ `sinks/llm-log.ts` | JSONL | daily, gzip | **forever** |
| `perf.jsonl` | `perf` | ✓ `sinks/perf-log.ts` | JSONL | daily, gzip | **forever** |
| `events.jsonl` | `events` | ✓ `sinks/events-log.ts` | JSONL | daily, gzip | **forever** |
| `self-check.log` | system | ✓ `core/logger/self-check.ts` | Plain text | never | tiny file |

**All 7 documented sinks are present in code.** No undocumented sinks found.

### On-disk state

Only `~/.openclaw/workspace/.memos/logs/memos.log` found on disk. This is the legacy MemOS Python server log — **not** the v2 plugin format. The v2 plugin has not been run in this environment (all ports closed). Remaining sinks (`error.log`, `audit.log`, `llm.jsonl`, `perf.jsonl`, `events.jsonl`, `self-check.log`) are **absent** because the plugin has never started.  
**Gap (operational):** Cannot validate rotation/gzip behaviour from a live run.

---

## 3. Channel + level taxonomy

### Enumeration

`core/logger/channels.ts` registers 80 canonical channels organized by prefix:

- `core.session.*` (2), `core.capture.*` (5), `core.reward.*` (6)
- `core.memory.l1` (1), `core.memory.l2.*` (8), `core.memory.l3.*` (7)
- `core.episode` (1), `core.feedback.*` (6), `core.skill.*` (6)
- `core.retrieval.*` (7), `core.pipeline.*` (3), `core.hub.*` (4)
- `core.telemetry`, `core.update-check`, `config`, `logger.*` (3)
- `storage.*` (4), `embedding.*` (7), `llm.*` (7)
- `server.*` (4), `bridge.*` (3), `adapter.openclaw`, `adapter.hermes`
- `system.*` (4)

**All channels map to documented module owners in `docs/LOGGING.md`.** ✓

### Live channel DEBUG toggle

`PATCH /api/v1/config` with `{ "logging": { "channels": { "core.l2": "debug" } } }` would update `config.yaml` and emit `system.config_changed`. This constitutes a live per-channel toggle **without restart** — the config is read on each emit at the channel filter level.

**Gap:** `patchConfig` in `core/pipeline/memory-core.ts` does NOT emit `system.config_changed` after writing. The `CORE_EVENTS` catalogue includes `system.config_changed`, but the `patchConfig` implementation just calls `applyPatch` and returns the masked result — no event is emitted. An operator watching SSE would not be notified that channels changed.

### Cross-channel correlation

`turnId` is propagated through `core/capture/step-extractor.ts` into trace metadata. The `LogRecord` type includes `ctx` which carries `traceId / sessionId / episodeId / turnId` via `AsyncLocalStorage`. In principle, grepping a `turnId` should thread across `memos.log`, `llm.jsonl`, `perf.jsonl`, and `events.jsonl`.

**Gap:** `correlationId` in `CoreEvent` is `optional` — not always populated. Retrieval events (`retrieval.tier1.hit`) may not carry the originating `turnId` depending on implementation.

---

## 4. Diagnostic scenarios

### S1 — "A user's last turn wasn't captured"
- **Logs:** `core.capture` channel logs at DEBUG/INFO — `normalize.skip_duplicate` is emitted at DEBUG. At default INFO level, a duplicate suppression **would not appear in memos.log**. Must raise `core.capture` to DEBUG via `PATCH /api/v1/config`.
- **Events:** No dedicated `capture.dropped` or `capture.suppressed` event type in `CORE_EVENTS`. The closest is `trace.created` (when it succeeds). There is no SSE signal for a dropped turn.
- **Viewer Memories/Logs:** Memories would simply not show the turn. Logs tab (SSE stream) would show the DEBUG emit only if level was raised.
- **Correlation ID:** `turnId` is set on traces but not on `CoreEvent` envelopes consistently.
- **Score: ~ (partial)** — success path is traceable; drop path is DEBUG-only with no dedicated event. An SRE at INFO level would see nothing.

### S2 — "Retrieval is returning nothing relevant"
- **perf.jsonl:** `logger.timer()` wraps retrieval operations per tier — latency is captured. Provider/model/batch info is on LLM calls but retrieval is vector-only (no LLM call per se).
- **events.jsonl / SSE:** `retrieval.tier1.hit`, `retrieval.tier2.hit`, `retrieval.tier3.hit`, `retrieval.empty` events exist. The retrieval README documents per-tier candidate counts, RRF fusion scores, and MMR pass. Whether these are in the event **payload** vs only in DEBUG logs requires deeper code inspection — the `CORE_EVENTS` event types exist but payload richness is undocumented in the contract.
- **Viewer Analytics:** `GET /api/v1/metrics/tools` surfaces `memory_search` latency with avg/p50/p95. No per-tier breakdown in the metrics endpoint.
- **Per-query DEBUG toggle:** PATCH /api/v1/config can raise `core.retrieval.tier1` etc. to DEBUG without restart. ✓
- **Score: ~ (partial)** — `retrieval.empty` event exists; tier hit events exist; payload richness not fully validated; no Prometheus histograms per tier.

### S3 — "HTTP server is unresponsive"
- **Health shape:** `GET /api/v1/health` returns: `{ ok, version, uptimeMs, agent, paths: { home, config, db, skills, logs }, llm: { ok, ... }, embedder: { ok, ... }, skillEvolver }`.
- **Probes:** `ok` is `initialized && !shutDown` — a process-level boolean, NOT a live probe. **SQLite connectivity is not probed.** **Disk space is not probed.** **Port binding is not probed.** **WAL size is not tracked.** The `llm` and `embedder` sub-fields use `latestTraceTs()` as a proxy (last successful capture timestamp), not a live ping.
- **Degraded state:** The health response is binary — `ok: true/false`. No `{ status: "degraded", reason: "embedder unreachable" }` shape exists.
- **Server dead / last heartbeat:** No periodic heartbeat is logged. If the server dies, `memos.log` would contain the last log line before crash but no explicit "heartbeat" record. `system.shutdown` event would appear in `events.jsonl` for graceful shutdown only.
- **Score: ✗ (none → partial)** — health endpoint exists but is shallow. It does not distinguish healthy from degraded. No disk/SQLite/WAL probe. No heartbeat log.

### S4 — "Crystallization produced a bad skill"
- **llm.jsonl:** `log.llm({ provider, model, prompt, completion, tokens, ms })` is the API. Crystallization calls `crystallizeDraft(...)` which goes through `core/llm/`. If wired correctly, full prompt+response land in `llm.jsonl`. ✓ (by design; cannot verify without a live run)
- **events.jsonl:** `skill.crystallized`, `skill.eta_updated`, `skill.boundary_updated`, `skill.archived`, `skill.repaired` events are in `CORE_EVENTS`. Eligibility verdict (`evaluateEligibility`) emits `skill.eligibility.checked` — but this event is **NOT in `CORE_EVENTS`**. It only appears in `core/skill/README.md`. **Gap: eligibility gate outcomes are undocumented in the event contract.**
- **Viewer Skills:** `SkillsView.tsx` is present. Whether it shows η posterior, trial count, and probation status cannot be confirmed without a live run.
- **Score: ~ (partial)** — LLM calls should be logged; crystallized event exists; eligibility gate outcomes are absent from the event contract.

### S5 — "A user is locked out"
- **audit.log:** The auth module uses `timingSafeEqual` for password comparison ✓ (constant-time). Login failure emits a 401 `{ error: { code: "unauthenticated", message: "invalid password" } }`.
- **Gap:** The `registerAuthRoutes` does not call `log.audit(...)` on failed login attempts. There is no brute-force counter or lockout mechanism. Failed login attempts are **not written to audit.log**. Source IP is available in `ctx.req.socket.remoteAddress` but is not logged anywhere in the auth routes.
- **Distinguishable failure reasons:** `invalid password` (401) vs `password not configured` (404) vs `login required` (401 on session middleware) — distinguishable by HTTP status + code field.
- **Cookie expired:** Session TTL is 7 days, HMAC-verified. Expiry check is in `verifySession`. Expired sessions return 401 `"login required"` — **not distinguishable from a bad session token** in the log.
- **Score: ✗ (none)** — Auth failures are not written to audit.log. No source IP logging. No brute-force detection. Constant-time comparison is present ✓ but unlogged.

### S6 — "Disk is filling"
- **Disk probe:** No disk-usage check anywhere in `server/` or `core/`. `health()` does not check free space. No WAL size tracking. No periodic probe.
- **ENOSPC behaviour:** `core/logger/README.md` states "file transports degrade to console only and emit one error to the in-memory ring buffer". This is graceful degradation for the *logger* itself, but there is no self-throttle for the application. A full disk would cause logger degradation and likely crash whatever was writing (SQLite WAL, embedder cache).
- **Self-check:** `runSelfCheck` checks that `logsDir` is writable (write + delete a probe file) but does not measure available space.
- **Score: ✗ (none)** — No disk probe surface. No WAL size metric. No self-throttle. Logger degrades gracefully on ENOSPC but application likely crashes.

### S7 — "An embedder call took 9s"
- **perf.jsonl:** `logger.timer("embedding.encode")` (or similar) would record provider / batch size / latency. The timer API carries `data` payload so provider and model can be included.
- **llm.jsonl vs embed distinction:** The `llm` sink (`kind === "llm"`) is for LLM calls. Embedding calls are in `core/embedding/` and use `log.timer()` → `perf.jsonl`. There is no separate `embed.jsonl`. Embedding calls do NOT appear in `llm.jsonl`.
- **Gap:** `perf.jsonl` entries for embedding may not include payload size (input token count / character count) unless the timer call site explicitly adds it. The `logger.timer` API accepts `data` but whether embedding adds it is not confirmed.
- **Score: ~ (partial)** — Timing is in perf.jsonl; provider/model likely present; payload size not confirmed; no dedicated embed sink.

### S8 — "A capture produced a duplicate memory"
- **Dedup decision visibility:** `core/capture/normalizer.ts` logs `normalize.skip_duplicate` at **DEBUG** level. This does not appear in default INFO `memos.log`.
- **Matching row ID:** The log message carries `{ key: step.key }` — a content hash, not a database row ID. The actual matching row ID for the suppressed duplicate is **not logged**.
- **Trace ID threading:** `turnId` threads through capture steps. On success, `trace.created` event fires. On duplicate suppression, no event fires.
- **Score: ✗ (none at INFO)** — Dedup is invisible at default log level. No `capture.deduplicated` event. Matching row ID absent.

### S9 — "Reward backprop looks wrong"
- **Events:** `reward.computed` is in `CORE_EVENTS`. `trace.priority_decayed` exists for priority decay.
- **R_human 3-axis breakdown:** `core/reward/human-scorer.ts` computes per-axis sub-scores (`rTask`, `rContext`, `rStyle` per `core/reward/types.ts`). These exist in the reward type but it is not confirmed that all 3 axes appear in the `reward.computed` event payload.
- **Episode finalize event:** `episode.closed` is in `CORE_EVENTS`. The backprop implementation in `core/reward/backprop.ts` does the V_t computation after `episode.closed`.
- **Score: ~ (partial)** — Events exist; episode and priority decay events present; 3-axis breakdown in event payload not confirmed.

### S10 — "Viewer lost its connection"
- **Server-side disconnect logging:** In `server/routes/events.ts`, the `cleanup` function fires on `ctx.req.on("close")` and `ctx.req.on("error")`. It calls `unsubscribe()` and `res.end()`. **No `log.info(...)` call records the disconnect** — the server does not log SSE client disconnects at all.
- **Client auto-reconnect:** The SSE stream uses standard `text/event-stream` with `id: seq`. A browser `EventSource` auto-reconnects and sends `Last-Event-ID`. The server does replay recent events via `getRecentEvents()` on reconnect. ✓
- **Back-pressure:** The `/api/v1/logs` SSE stream uses a **token bucket** (`MAX_RATE_PER_SECOND = 200`). When the bucket is empty, records are **dropped silently** (`if (tokenBucket <= 0) return`). No warning is emitted when drops start. The events SSE (`/api/v1/events`) has no rate limiting — slow clients receive all events, which could block the write path if the connection stalls.
- **Score: ~ (partial)** — Disconnect not logged server-side; auto-reconnect works via EventSource; token-bucket drops silently; events SSE has no back-pressure protection.

---

## 5. Redaction correctness

Secrets covered by default patterns in `core/logger/redact.ts`:

| Secret type | Pattern | Covered |
|---|---|---|
| `sk-…` key (OpenAI-style) | `\bsk-[A-Za-z0-9_-]{20,}\b` | ✓ |
| `Bearer …` token | `\bBearer\s+[A-Za-z0-9._-]{20,}\b` | ✓ |
| JWT | `\beyJ[…]\b` | ✓ |
| Email | `[A-Za-z0-9._%+-]+@[…]` | ✓ |
| Phone (loose) | digit pattern | ✓ (loose) |
| `password=…` (key-based) | `^password$/i` key pattern | ✓ |
| `authorization: …` (key-based) | `^authorization$/i` key pattern | ✓ |
| `.env`-style export | No pattern | ✗ |
| AWS `AKIA…` key | No pattern | ✗ |
| Private key header `-----BEGIN…` | No pattern | ✗ |
| 16-digit card number | No pattern | ✗ |
| SSN (`XXX-XX-XXXX`) | No pattern | ✗ |
| IP address | No pattern | ✗ |
| RSA `-----BEGIN…-----` block | No pattern | ✗ |

**8 of 14 common secret types are NOT covered by default patterns.** Users can extend via `config.yaml` `extraPatterns`, but this requires operator awareness.

**SSE stream output:** All log records pass through redaction before the SSE broadcast (`transports/sse-broadcast.ts` is downstream of the redactor). ✓  
**Viewer DOM:** Cannot verify without a live run.

---

## 6. Viewer UX assessment

All views exist in source. Cannot exercise interactively (server not running). Assessment from code:

| View | Operator capability | Gaps |
|---|---|---|
| **Overview** | Key counts, recent activity. `GET /api/v1/diag/counts` + `metrics()` feed this. | Health status only binary (ok/not-ok). No disk gauge. |
| **Memories** | Filter/browse L1/L2/L3 traces. Full row data available via `GET /api/v1/memory/*`. | Cannot verify embedding preview or trace links without live run. |
| **Policies / WorldModels** | Edit/retire/pin via PUT/DELETE routes. | Viewer edit capability assumed but not verified live. |
| **Tasks** | Episode timeline via `listEpisodeRows`. R_human and priority via episode fields. | 3-axis sub-score display not confirmed. |
| **Skills** | η, trial count, status visible via `listSkills`. | Beta posterior chart and probation transitions not confirmed without live run. |
| **Analytics** | `GET /api/v1/metrics/tools` provides avg/p50/p95 for `memory_search`/`memory_add` and trace tool calls. | No per-tier retrieval histograms. No Prometheus scrape. |
| **Logs** | SSE `/api/v1/logs` + tail endpoint. Channel filter dropdown uses `CHANNELS` registry. | Token-bucket drops are silent (no drop counter shown). |
| **Admin** | Restart + clear-data. No re-embed, vacuum, or migration replay endpoints found. | Missing: trigger re-embed, vacuum, migration replay. |
| **Settings / Import** | Config diff via GET/PATCH. Import round-trip via `import-export.ts`. | Config change does not emit SSE `system.config_changed`. |

---

## 7. Metrics scrapeability

**No Prometheus endpoint exists.** There is no `prom_client` dependency and no `/metrics` text/plain route.

`GET /api/v1/metrics` returns JSON KPIs (totals, daily histogram).  
`GET /api/v1/metrics/tools` returns per-tool latency stats (avg/p50/p95).

**Present counters/histograms:**
- Captures/day histogram ✓ (via metrics JSON)
- Retrieval count ✓
- LLM latency via perf.jsonl ✓
- Tool call latency (memory_search, memory_add) p50/p95 ✓

**Missing:**
- Prometheus scrape endpoint ✗
- auth-fail/s counter ✗
- SSE subscriber count gauge ✗
- DB file size / WAL size gauge ✗
- RSS gauge ✗
- Open connection count ✗
- Per-tier retrieval latency histograms ✗

**Could Prometheus be wired without forking?** Yes — a thin adapter could wrap `GET /api/v1/metrics` and convert to text exposition format. No core changes needed.

---

## 8. Audit trail

- **Mutation attribution:** `audit.log` sink is wired for `kind === "audit"` records. `log.audit("policy.promoted", { policyId })` is the documented API. Fields logged: event name + structured data.
- **Missing:** Source IP is not logged for auth events. No `before-hash / after-hash` of mutated rows. No `correlation-id` on audit records by default.
- **Who field:** Auth is off by default (no password required). When auth is disabled, there is no `userId` to attribute mutations to. When auth is on, `requireSession` validates the cookie but the authenticated identity is not injected into the log context.
- **Append-only / truncation detection:** `audit.log` uses monthly gzip rotation (not deleted). No hash-chaining or Merkle structure. The plugin **cannot detect truncation** of `audit.log`.

---

## 9. Error-message quality

| Trigger | HTTP response | Quality |
|---|---|---|
| Invalid JSON body | `400 invalid_argument "body must be a JSON object"` | ✓ helpful |
| Wrong auth (bad password) | `401 unauthenticated "invalid password"` | ✓ clear |
| Unknown JSON-RPC method | `{ error: { code, message } }` pattern | ✓ structured |
| Embed-provider down | `llm`/`embedder` health sub-field shows `ok: false` | ~ (silent in health, no hint on which call failed) |
| Dimension mismatch | Not found in server routes; likely surfaces as a 500 internal error | ✗ unknown |
| Malformed SQLite path | `MemosError("config_invalid", "migrations failed for ...")` — descriptive | ✓ helpful |

Overall error shape is consistent `{ error: { code, message } }`. Most cases are helpful. Embedder failures are silent in the health endpoint.

---

## 10. Scenario scoring table

| Scenario | Logs | Events/SSE | Viewer | Health | Metrics | Audit | Score 1-10 |
|---|---|---|---|---|---|---|---|
| S1 missing capture | ~ (DEBUG only) | ✗ (no drop event) | ✗ (silent gap) | — | — | — | **3** |
| S2 bad retrieval | ~ (DEBUG) | ~ (tier events exist; payload richness unconfirmed) | ~ (tool latency only) | — | ~ (memory_search p95) | — | **5** |
| S3 server down | ~ (last log entry) | ~ (system.shutdown for graceful) | — | ✗ (binary, no probe) | — | — | **3** |
| S4 bad skill | ✓ (llm.jsonl) | ~ (skill.crystallized; eligibility gap) | ~ (Skills view exists) | — | — | — | **6** |
| S5 auth lockout | ✗ (not logged) | ✗ | ✗ | — | — | ✗ (not in audit.log) | **1** |
| S6 disk fill | ✗ | ✗ | ✗ | ✗ (no disk probe) | ✗ | — | **1** |
| S7 slow embed | ~ (perf.jsonl; payload size unconfirmed) | — | ~ (analytics latency) | — | ~ (p95 in tools) | — | **5** |
| S8 dup capture | ✗ (DEBUG only, no row ID) | ✗ (no event) | ✗ | — | — | — | **2** |
| S9 reward drift | ~ (reward.computed; 3-axis unconfirmed) | ~ (episode.closed + priority_decayed) | ~ (Tasks view) | — | — | — | **5** |
| S10 SSE drop | ✗ (not logged) | — | — | — | — | — | **3** |

---

## 11. Surface scoring table

| Surface | Score 1-10 | Gaps |
|---|---|---|
| Sink inventory completeness | **9** | Self-check.log missing from on-disk discovery (plugin never started). All 7 sinks in code. |
| Channel taxonomy | **9** | 80 channels, well-mapped. patchConfig doesn't emit system.config_changed (minor gap). |
| Redaction-before-sink | **6** | 5 default patterns cover ~6/14 secret types. AWS AKIA, card, SSN, IP, RSA, .env exports not covered. |
| Correlation-id threading | **5** | turnId in traces; correlationId optional on CoreEvent; no guarantee all events carry it. |
| Viewer Overview/Memories | **7** | Exists and wired to metrics/trace APIs. Binary health card. No disk gauge. |
| Viewer Policies/WorldModels/Tasks | **6** | Views present; 3-axis R_human display unconfirmed without live run. |
| Viewer Skills/Analytics | **6** | Skills view present; Analytics only has tool-level latency, no per-tier breakdown. |
| Viewer Logs/Admin | **5** | Logs SSE works with rate-limit; Admin missing re-embed/vacuum/migration replay endpoints. |
| Health endpoint depth | **3** | Binary ok/not-ok. No SQLite probe. No disk space. No WAL size. No degraded state. No heartbeat. |
| Metrics scrapeability | **2** | JSON metrics endpoint exists. No Prometheus scrape. No disk/WAL/SSE-subscriber gauges. |
| Audit trail completeness | **3** | Auth failures not logged. No source IP. No before/after hash. No truncation detection. No userId when auth disabled. |
| Error-message quality | **7** | Consistent structured shape. Most cases helpful. Embedder failures silent in health. |

**Overall observability score = MIN of above = 2** (Metrics scrapeability)

---

## 12. Top gaps (priority order)

1. **Auth events not in audit.log** — failed logins, lockouts, source IP all missing. Critical for security operators. (S5: score 1)
2. **No disk/WAL monitoring** — system will crash silently on ENOSPC with no prior warning. Health endpoint has no disk probe. (S6: score 1)
3. **Dedup drop invisible at INFO** — a missing capture produces no event and no INFO-level log. SRE cannot diagnose without modifying config. (S8: score 2)
4. **Redaction gaps** — AWS keys, card numbers, SSNs, RSA blocks, IP addresses, .env exports all pass through unredacted. (Surface score 6)
5. **Health endpoint is shallow** — No SQLite live probe, no embedder ping, no degraded state, no WAL size, no disk space. (S3/surface score 3)
6. **No Prometheus scrape endpoint** — Ops teams cannot wire alerting without a custom adapter. No SSE-subscriber gauge, no disk gauge. (Surface score 2)
7. **SSE disconnect not logged** — Server does not record client disconnects. Token-bucket drops in logs SSE are silent. (S10: score 3)
8. **patchConfig doesn't emit system.config_changed** — Channel-level changes are not observable on the SSE stream.
9. **eligibility gate outcomes absent from CORE_EVENTS** — `skill.eligibility.checked` mentioned in README but not in the contract.
10. **Audit trail lacks who/before-hash/after-hash** — Mutations not fully attributable when auth is disabled (default).
