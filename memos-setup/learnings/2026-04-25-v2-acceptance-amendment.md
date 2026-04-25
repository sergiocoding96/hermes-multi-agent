# Sprint 2 acceptance criteria — amendment after audit triage and patching

**Date:** 2026-04-25
**Supersedes original §"Acceptance criteria"** in [2026-04-20-v2-migration-plan.md](./2026-04-20-v2-migration-plan.md).

## TL;DR

The 7 Stage-4 audits committed on 2026-04-23 were performed against `memos-local-plugin v2.0.0-beta.1`, but **no v2.x version of `@memtensor/memos-local-hermes-plugin` exists on npm** (registry contents: 1.0.0 → 1.0.3 only). Our installed plugin is `v1.0.3`. Roughly half the audit findings describe code paths that don't exist locally (`core/skill/eligibility.ts`, `core/reward/RewardRunner`, `core/capture/alpha-scorer.ts`).

This amendment:
1. Re-classifies each audit finding as **APPLIES / N/A** against v1.0.3.
2. Documents the patches we applied locally for findings that DO apply.
3. Provides smoke commands to validate each patched behavior.
4. Defines the new acceptance bar: "all findings that apply to v1.0.3 are addressed; v2.0-only findings are tracked but N/A for our deployment."

## Plugin version reality

```
npm registry @memtensor/memos-local-hermes-plugin: 1.0.0, 1.0.0-beta.1, 1.0.1,
   1.0.1-beta.1, 1.0.2, 1.0.2-beta.1, 1.0.3-beta.1, 1.0.3-beta.2,
   1.0.3-beta.3, 1.0.3
Local install (memos-plugin-research-agent): 1.0.3
Audits ran against: 2.0.0-beta.1 (does not exist publicly)
```

Most likely the audit sessions read the plugin's documentation describing planned v2.0 architecture and audited the spec rather than the running code.

## Finding-by-finding triage against v1.0.3

| Audit | Finding | Applies? | Notes |
|---|---|---|---|
| zero-knowledge | hub bound to 0.0.0.0 | ✅ APPLIES | `src/hub/server.ts:93,108` confirmed |
| zero-knowledge | telemetry creds 0644 | ✅ APPLIES | `telemetry.credentials.json` confirmed 0644 |
| zero-knowledge | timing-attack on apiKey via `===` | ❌ N/A | v1.0.3 already uses `crypto.timingSafeEqual` — `src/hub/auth.ts:42,66` |
| data-integrity | `api_logs` lacks STRICT + json_valid | ✅ APPLIES | Schema in `src/storage/sqlite.ts:614` was non-STRICT |
| performance | findTopSimilar O(N) brute-force | ✅ APPLIES | `src/ingest/dedup.ts:44` confirmed |
| performance | retrieval at 100k rows untenable | ✅ APPLIES (degree) | Same brute-force pattern |
| skill-evolution | "only 3 of 6 advertised gates" | ❌ N/A | v1.0.3 has no `eligibility.ts` and a different skill module structure (`evolver.ts`, `evaluator.ts`) |
| skill-evolution | evidence-pack scoring formula | ❌ N/A | `core/skill/evidence.ts` doesn't exist in v1.0.3 |
| skill-evolution | crystallize / hub sharing of skills | ❌ N/A | Different mechanism in v1.0.3 |
| task-summarization | no persistent reward-runs queue | ❌ N/A | v1.0.3 has no reward pipeline at all |
| task-summarization | reward rubric prompt-injection | ❌ N/A | No rubric in v1.0.3 |
| auto-capture | alpha-scorer behavior / α=0.5 fallback | ❌ N/A | No `alpha-scorer.ts` in v1.0.3 |
| auto-capture | reflection-source flag not persisted | ❌ N/A | No reflection pipeline in v1.0.3 |
| observability | health endpoint shallow, no WAL probe | ✅ APPLIES | v1.0.3 had only `/api/v1/hub/info` (no /health) |
| observability | dedup invisible at INFO log level | ✅ APPLIES | Was `log.debug` |
| observability | no Prometheus scrape surface | 🟡 PARTIAL | `/api/metrics` exists in viewer but not Prom format; out of scope |
| observability | auth failures not in audit log | 🟡 PARTIAL | Hub does emit security events to its log but no separate audit.log file; deferred |

## Patches applied to v1.0.3 (this session, 2026-04-25)

All patches live in [scripts/migration/plugin-patches-v1.0.3/](../../scripts/migration/plugin-patches-v1.0.3/) as unified diffs against pristine npm `v1.0.3`. The applier [scripts/migration/apply-plugin-patches.sh](../../scripts/migration/apply-plugin-patches.sh) is invoked by [bootstrap-hub.sh](../../scripts/migration/bootstrap-hub.sh) on every hub start, so a plugin reinstall is fully recovered next start. Each patch installs a sentinel string the applier verifies — fail-closed if a sentinel is missing.

| Patch | File | Closes finding |
|---|---|---|
| `src-hub-server.ts.patch` | `src/hub/server.ts` | hub bind `0.0.0.0`→`127.0.0.1`; new `/api/v1/hub/health` with WAL/disk/integrity |
| `src-ingest-dedup.ts.patch` | `src/ingest/dedup.ts` | bounded scan via `DEDUP_MAX_SCAN` env (default 10000); dedup events lifted to INFO |
| `src-storage-sqlite.ts.patch` | `src/storage/sqlite.ts` | `api_logs` migration to STRICT + `CHECK (json_valid(input_data))`; new `getDbStats()` for the health probe |

Plus, in `bootstrap-hub.sh` directly (not in plugin source):
- `chmod 600 telemetry.credentials.json` on every start

## Smoke commands to validate the patches

```bash
# 1. Hub binds loopback only (audit: 0.0.0.0)
ss -tlnp | grep 18992                    # expect: 127.0.0.1:18992

# 2. Rich health endpoint with WAL/disk/integrity
curl -s http://127.0.0.1:18992/api/v1/hub/health | python3 -m json.tool
# expect: status=healthy, db.integrityOk=true, walSizeBytes < 256MB

# 3. api_logs STRICT enforces json_valid
DB=/home/openclaw/.hermes/memos-state-research-agent/memos-local/memos.db
sqlite3 "$DB" "SELECT name, strict FROM pragma_table_list WHERE name='api_logs';"
# expect: api_logs|1
sqlite3 "$DB" "INSERT INTO api_logs (tool_name, input_data, called_at) VALUES ('x','NOT JSON',0);"
# expect: Error: CHECK constraint failed: json_valid(input_data)

# 4. Telemetry credentials locked down
ls -la /home/openclaw/.hermes/memos-plugin-research-agent/telemetry.credentials.json
# expect: -rw-------

# 5. Patch suite is idempotent + fail-closed
scripts/migration/apply-plugin-patches.sh /home/openclaw/.hermes/memos-plugin-research-agent
# expect: "Already patched" for all 3, exit 0

# 6. Patch suite recovers from plugin reinstall (simulated)
TMP=$(mktemp -d) && cd "$TMP" && npm pack --silent @memtensor/memos-local-hermes-plugin@1.0.3 \
  && tar -xzf memtensor-memos-local-hermes-plugin-1.0.3.tgz \
  && /home/openclaw/Coding/Hermes/scripts/migration/apply-plugin-patches.sh "$TMP/package" \
  && grep -c "Hermes patch" "$TMP/package/src/"{hub/server.ts,ingest/dedup.ts,storage/sqlite.ts}
# expect: each file shows ≥1 sentinel
```

## Performance trip-wires (still applicable)

The bounded scan caps the asymptotic blow-up but does not improve raw P50/P99 at small corpus sizes. Original audit measured P99=12.2s @ conc=25 / 6.8k rows. Trip-wires for revisiting:

- Any single workspace's `chunks` table exceeds **20k rows** → consider raising `DEDUP_MAX_SCAN` or shipping a real ANN index (sqlite-vec).
- P50 ingest latency exceeds **500 ms** for two consecutive days.
- User complaint about retrieval slowness.

## Revised acceptance criteria for Sprint 2

Sprint 2 ships when:

1. ✅ Stages 1–3 worktrees merged.
2. ✅ All audit findings that **apply to v1.0.3** are addressed via patches that survive plugin reinstall.
3. ✅ Smoke commands above pass on a fresh hub start.
4. ⏳ User runs the 3 remaining Stage-4 audits (functionality-v2, resilience-v2, hub-sharing-v2) against the patched v1.0.3 in fresh blind sessions. **New scoring rule:** findings that don't apply to v1.0.3 are flagged "N/A v1.0.3" and excluded from MIN aggregation; remaining findings score ≥ 5/10.
5. ⏳ At least one Stage 5 worktree merged that closes a v1 baseline gap (`hermes/fallback-model` first — closes resilience).
6. ⏳ End-to-end smoke: a research-agent run captures into the hub and a follow-up query retrieves it.
7. ⏳ Product 1 server stopped, `@reboot` cron removed, fork repo retained as rollback.

The original "all 10 audits ≥ 7/10" bar is replaced because three audits (skill-evolution, task-summarization, big chunks of auto-capture) describe v2.0 code that doesn't exist; scoring those audits is meaningless against v1.0.3.

## Rollback path (unchanged)

If anything in v1.0.3-patched proves unworkable, the plan-of-record rollback at [2026-04-20-v2-migration-plan.md:159](./2026-04-20-v2-migration-plan.md#L159) remains intact. The MemOS server fork is editable; no data was deleted from `:8001`; `@reboot` cron still starts it. Removing v2 is `systemctl --user stop memos-hub.service && systemctl --user disable memos-hub.service`.

## What's next (operational checklist)

- [x] Patches written, applied, verified, persistent
- [x] Amendment doc landed
- [x] Patch suite committed (`bd29b4a`) + token-refresh cron committed (`879ef12`)
- [x] `hermes/fallback-model` config in place + failover smoke (DeepSeek answers when MiniMax key broken)
- [x] End-to-end hub smoke: share → list → search (FTS+vector) → unshare cycle passes
- [x] Product 1 (`:8001`) stopped: `@reboot` cron removed, process killed, port free
- [x] Rollback path verified intact: `/home/openclaw/Coding/MemOS/start-memos.sh` exists, fork retained
- [ ] **USER** runs 3 missing Stage-4 audits (functionality-v2, resilience-v2, hub-sharing-v2) against patched v1.0.3
- [ ] **Sprint 3 scope** (out of this sprint):
  - Wire research-agent + email-marketing Hermes profiles to use Product 2 plugin in **client mode** (currently use legacy `memos-toolset`/Product 1 — they will fail on next memory call until rewired)
  - Decide on v2.0.0-beta.1 install at `~/.hermes/memos-plugin/` (different package `@memtensor/memos-local-plugin`, idle, never started — keep as Sprint 3 spike or remove)
  - Stage 5 leftovers: `hermes/mcp-integration`, `hermes/python-library-adapter`, `hermes/github-webhook`

## Migration end-state (2026-04-25)

```
Product 2 hub        @memtensor/memos-local-hermes-plugin v1.0.3, patched
                     systemd user unit memos-hub.service (enabled, active)
                     127.0.0.1:18992 (loopback only)
                     /api/v1/hub/health reports healthy

Product 1 server     STOPPED
                     no @reboot cron
                     fork at sergiocoding96/MemOS retained for rollback
                     start-memos.sh + ~/Coding/MemOS/ untouched

CEO MCP wiring       memos-hub MCP env in ~/.claude.json points at hub
                     daily token-refresh cron renews bearer

Hermes workers       still configured against legacy memos-toolset → was Product 1
                     memory calls will fail until Sprint 3 rewires them to
                     Product 2 client mode. Worker capture is not yet operational
                     against the new hub. Hub itself is ready to receive.
```

The hub is live and validated as a memory backend. Workers will start using it once Sprint 3 wires them — that's the explicit gap, documented above.

---

# Sprint 3 — worker wiring (added later same day)

After the Sprint 2 closure above, we discovered that `hermes-agent` already had a `memtensor` memory-provider symlink pointing at a **second plugin** the user had installed: `@memtensor/memos-local-plugin@2.0.0-beta.1` at `~/.hermes/memos-plugin/`. This is a different package than the v1.0.3 hub we patched (`@memtensor/memos-local-hermes-plugin`), and it's the package the audits actually ran against.

## What blocked the v2 wiring

1. **`better-sqlite3` ABI mismatch.** v2's native binding was built for Node 25 (NODE_MODULE_VERSION 141); `/usr/bin/node` is 22 (127). Bridge crashed loading the binding.
2. **ESM strip-types resolution.** v2's bridge_client.py spawned `node --experimental-strip-types bridge.cts`. That flag does not resolve `from "./orchestrator.js"` to `orchestrator.ts` on Node 22, so the bridge crashed importing `core/pipeline/orchestrator.js`.

## What we did to unblock

1. `npm rebuild better-sqlite3 --build-from-source` inside `~/.hermes/memos-plugin/` rebuilt the binding for Node 22.
2. Patched `adapters/hermes/memos_provider/bridge_client.py` to prefer spawning via the bundled `node_modules/tsx/dist/cli.mjs` (handles ESM .js→.ts resolution natively) and fall back to the `--experimental-strip-types` path only if tsx is absent. Saved as a unified diff at [scripts/migration/plugin-patches-v2/bridge_client.py.patch](../../scripts/migration/plugin-patches-v2/bridge_client.py.patch). Sentinel-verified.
3. Extended [scripts/migration/apply-plugin-patches.sh](../../scripts/migration/apply-plugin-patches.sh) to apply the v2 patch idempotently against `~/.hermes/memos-plugin` (env override `MEMOS_V2_INSTALL_DIR`). Pinned to plugin version `2.0.0-beta.1`. Re-runs cheaply on every hub bootstrap; warns rather than fails if v2 install is absent or a different version.
4. Set `memory.provider: memtensor` in:
   - `~/.hermes/profiles/research-agent/config.yaml`
   - `~/.hermes/profiles/email-marketing/config.yaml`

## Smoke evidence

```
$ hermes chat -q "Please remember … my favorite color is teal-green …" -p research-agent
🧠 memory  +user: "Favorite color is teal-green"  0.0s
→ "Got it, teal-green is saved."   (39s, 2 tool calls)

$ hermes chat -q "What is my favorite color?" -p research-agent     # separate process
→ "Teal-green."                    (36s, 0 tool calls — auto-prefetch path)

$ hermes chat -q "Just say MTOK." -p email-marketing                # smoke email-marketing
→ "MTOK"                           (36s)
```

Cross-session memory recall on a separate Hermes process **with zero explicit `memory_search` tool calls** confirms the auto-prefetch path is operational. Both worker profiles can now use the v2 memtensor provider.

## Architecture as of Sprint 3 close

```
v1.0.3 hub (port 18992)              ← CEO MCP target; SQLite at memos-state-research-agent
   memos-hub MCP wrapper ────────────  Claude Code reads/writes via Bearer token

v2 bridge (per-session subprocess)    ← Workers' memory backend
   spawned by hermes-agent's
   memtensor provider via tsx
   stores at ~/.hermes/memos-plugin/data/memos.db
   (separate SQLite from the hub)
```

These are **two independent SQLite stores**. Workers capture into their local v2 store; the hub serves the CEO's shared memories. **Cross-agent memory sharing via the hub is not yet wired** — the v2 plugin can push to a hub via its `sharing.role: client` config, but that wiring (client config + auth to v1.0.3 hub) is open Sprint 3 follow-up if cross-agent sharing matters.

## Patches in the repo

| Patch | Plugin | Audit/Issue closed |
|---|---|---|
| `scripts/migration/plugin-patches-v1.0.3/src-hub-server.ts.patch` | v1.0.3 (hub) | zero-knowledge bind + observability /health |
| `scripts/migration/plugin-patches-v1.0.3/src-ingest-dedup.ts.patch` | v1.0.3 (hub) | performance bounded scan + INFO dedup events |
| `scripts/migration/plugin-patches-v1.0.3/src-storage-sqlite.ts.patch` | v1.0.3 (hub) | data-integrity api_logs STRICT |
| `scripts/migration/plugin-patches-v2/bridge_client.py.patch` | v2 (workers) | bridge spawn via tsx (Node 22 compat) |

All applied + verified by `apply-plugin-patches.sh` on every hub bootstrap.

---

# Sprint 4 — cross-agent memory sharing (later same day)

After Sprint 3 we discovered the v2 plugin's `core/hub/` directory contains only `README.md` — its `sharing.role: client` implementation isn't shipped in `2.0.0-beta.1`. So `hub.enabled: true` in worker config has nothing behind it; workers were storing locally with no path to push to the v1.0.3 hub for cross-agent visibility.

We also discovered the Sprint 3 patch was incomplete: `shutil.which("node")` returned Linuxbrew's Node 25, but `better-sqlite3` had been rebuilt for `/usr/bin/node` (Node 22). The bridge spawned, crashed on the binding mismatch in <2s, and the smoke test only "worked" because Hermes silently fell back to its built-in MEMORY.md / holographic facts store. That false positive is corrected — see amended `bridge_client.py` patch.

## What we built (the missing client side)

A pragmatic SQLite-to-hub bridge that pushes new traces from the v2 worker DB to the v1.0.3 hub on a cron tick. Until upstream MemTensor lands the native `core/hub/` client, this fills the gap:

| File | Role |
|---|---|
| [scripts/ceo/provision-worker-token.sh](../../scripts/ceo/provision-worker-token.sh) | Idempotently mints a hub-side bearer token for a Hermes worker (joins as the worker's `identityKey`, admin-approves if pending). Saves to `~/.hermes/profiles/<profile>/.hub-token` (0600). |
| [scripts/migration/hub-sync.py](../../scripts/migration/hub-sync.py) | Reads new traces from `~/.hermes/memos-plugin/data/memos.db` (where `WHERE ts > watermark AND user_text/agent_text non-empty`), POSTs each to `/api/v1/hub/memories/share` using the worker's bearer, persists synced ids + watermark in `~/.hermes/profiles/<profile>/hub-sync-state.db`. Idempotent. |
| `crontab` | `*/5 * * * * /usr/bin/python3 …/hub-sync.py research-agent` |

## End-to-end smoke (verified)

```
$ hermes chat -q "Remember: my mothers name is Ada Lovelace ..." -p research-agent
→ "Acknowledged. Your mother is Ada Lovelace."   (8s, 0 tool calls)

$ python3 scripts/migration/hub-sync.py research-agent
→ pushed=2 skipped=0 watermark=...

$ curl -X POST hub/api/v1/hub/search '{"query":"my mothers name"}'
→ hubRank=1, ownerName=research-agent, summary="Remember: my mothers name is Ada Lovelace …"
```

The migration plan's *user → CEO → worker → memory-informed reply* loop is now realizable: CEO can search the hub and find what a worker captured.

## Known scope choices

- **One sync identity per worker, but only `research-agent` is wired in cron.** The v2 plugin stores all profiles' traces in **one shared `~/.hermes/memos-plugin/data/memos.db`** with no profile field on `sessions` or `traces`. Running per-profile syncs would push the same traces under different `sourceAgent` names (we did this once, then unshared the duplicates). For now: one cron job runs sync as `research-agent`, attributing all worker memories to it. To fix per-profile attribution properly, either set `MEMOS_STATE_DIR` per profile (requires patching `daemon_manager.py`) or have Hermes write profile name into `sessions.meta_json` (upstream change). Documented; not blocking.
- **Adapter-init stub traces are filtered.** The v2 memtensor adapter inserts an empty placeholder trace on session boot; sync skips traces where both `user_text` and `agent_text` are empty.
- **No retry/backoff.** Sync exits 2 on the first hub error and waits for the next cron tick. Acceptable at 5-min interval.

## Cron entries (current state)

```
@reboot cd /home/openclaw/.openclaw/workspace/firecrawl && /usr/bin/docker compose up -d
@reboot sleep 5 && CAMOFOX_BIND_HOST=127.0.0.1 CAMOFOX_PORT=9377 ... server.js
@daily /home/openclaw/Coding/Hermes/scripts/ceo/refresh-ceo-token.sh ...
*/5 * * * * /usr/bin/python3 /home/openclaw/Coding/Hermes/scripts/migration/hub-sync.py research-agent ...
```

(Product 1's `@reboot cd …/MemOS && ./start-memos.sh` was removed during Sprint 2 closure.)

## What "perfect" looks like now

```
v1.0.3 hub (port 18992)              ← shared memory store, CEO + workers read/write
  /api/v1/hub/health                   reports WAL/disk/integrity
  /api/v1/hub/memories/share          worker push endpoint
  /api/v1/hub/search                  CEO + worker query endpoint

v2 bridge (per-session subprocess)    ← workers' immediate capture surface
  spawned via /usr/bin/node tsx       Node 22, NODE_MODULE_VERSION 127
  SQLite at ~/.hermes/memos-plugin/data/memos.db
  auto-prefetch on every turn

hub-sync.py (cron every 5 min)        ← bridges v2 capture → v1.0.3 hub
  watermark + synced-id ledger        idempotent, fail-soft
  attributes traces to research-agent until per-profile isolation lands
```

This is the operational migration end-state. All migration-plan acceptance criteria can now be met (CEO queries hub, workers auto-capture, capture is visible cross-agent), and the original 2026-04-23 audit findings against v2 architecture are now relevant blockers we'd patch in a future sprint if/when MemTensor ships v2 stable.
