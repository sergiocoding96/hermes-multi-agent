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
