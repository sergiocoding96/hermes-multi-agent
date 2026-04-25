# Resilience Audit — memos-local-plugin v2.0.0-beta.1 + v1.0.3 hub

> ⚠️ **NON-BLIND SELF-AUDIT.** Same caveat as the functionality report — produced inside the patching session, not a fresh blind run. Treat scores as smoke-pass evidence.
>
> Date: 2026-04-25  Marker: `RES-AUDIT-1777127200`

## What's actually deployed (the system under test)

The original audit prompt assumes a single v2 plugin install acting as both worker and hub. Our deployment is split:

- **v1.0.3 plugin** runs as the team-sharing hub at `127.0.0.1:18992` under `systemctl --user memos-hub.service`.
- **v2.0.0-beta.1 plugin** runs per-Hermes-session as the worker bridge subprocess (Sprint 3 wiring).

Resilience scores below grade *the deployed system*, not v2 in isolation.

## Probes ran + evidence

**Hub HTTP availability under load.**
- 20 parallel `GET /api/v1/hub/health` requests → all 20 returned HTTP 200. No FD exhaustion at modest concurrency.
- **Score: 7/10** for the burst level tested; not stress-tested (1000-conn flood not run).

**Hub restart cycle.**
- `systemctl --user restart memos-hub.service` → process replaced cleanly, port reclaimed, `/health` returned 200 within 3s.
- Bootstrap re-applies all v1.0.3 patches idempotently (`apply-plugin-patches.sh` reports "Already patched"). No drift.
- **Score: 8/10.**

**SQLite integrity (live DB).**
- `PRAGMA quick_check(1)` on hub DB → `ok`. WAL journal mode confirmed.
- v2 worker DB: WAL=on, busyTimeoutMs=5000 per startup logs.
- `getDbStats()` (Sprint 2 patch) reports integrityOk=true on `/api/v1/hub/health` — visible to monitors.
- **Score: 8/10** for the live DB; corruption-injection tests not run.

**v2 bridge bring-up.**
- 13 migrations applied at first boot, skipped on subsequent (`applied=0, skipped=13`). Idempotent migrator.
- Embedder init clean: `local Xenova/all-MiniLM-L6-v2 dim=384 cacheEnabled=true`.
- LLM init clean: `openai_compatible fallbackToHost=true timeoutMs=45000 maxRetries=3`.
- **Score: 7/10** for clean startup; mid-migration kill not tested.

**LLM-provider outage (Hermes fallback).**
- Earlier failover smoke (`fallback-model` task): `MINIMAX_API_KEY=invalid hermes chat -p default` → DeepSeek answered in 35s. Hermes-side `fallback_providers` working.
- v2's internal `fallbackToHost=true` not isolated; not tested independently.
- **Score: 7/10.**

**Loopback bind enforcement.**
- `ss -tlnp | grep 18992` → `127.0.0.1:18992` only. Verified earlier via curls to `192.168.1.122`, `100.80.252.97` (Tailscale), `172.17.0.1` (Docker bridge): all refused.
- Patch is idempotent in `bootstrap-hub.sh` with a fail-closed verification.
- **Score: 9/10.**

**Hub-sync graceful degradation.**
- `hub-sync.py` exits 2 on first hub error and lets cron re-attempt at the next 5-min tick. Watermark + per-id ledger persists in profile-local SQLite — no data loss on hub outage.
- Idempotent: re-running shows `pushed=0 skipped=0` when up-to-date.
- **Score: 8/10.**

**Cron + systemd hygiene.**
- `Linger=yes` for the user → unit survives logout.
- `Restart=on-failure RestartSec=10 TimeoutStartSec=120` in unit. PIDFile path tracked for systemd's reaping.
- Daily token refresh cron tested by re-running the wrapper (smoke pass at 12:40 UTC).
- **Score: 8/10.**

**Things NOT tested.**
- SQLite corruption injection (truncate, random bytes, integrity_check on damaged file)
- Mid-migration kill -9 / restart
- ENOSPC + log rotation under disk pressure
- 1000-conn / slow-loris HTTP flood
- Concurrent 100-write fanout
- SSE backpressure (no SSE clients in our setup)
- Power-cut approximation (kill -9 + drop_caches)
- Embedder dim mismatch
- Malformed JSON-RPC payloads

These are the ones that matter most for a real resilience grade. Not run in this session.

## Scorecard

| Failure mode | Score | Recovery | Evidence |
|---|---:|---|---|
| LLM-provider outage (Hermes fallback) | 7/10 | auto via DeepSeek | failover smoke pass |
| Embedder outage / dim mismatch | UNTESTED | – | – |
| SQLite corruption injection | UNTESTED | – | quick_check ok on live DB |
| Partial migration | UNTESTED | – | 13/13 applied at boot |
| Config malformed / perms | UNTESTED | – | – |
| Process crash (HTTP) | 8/10 | systemd Restart=on-failure | restart cycle clean |
| Mid-capture crash | UNTESTED | – | no persistent reward queue in v1.0.3 |
| Mid-crystallize crash | UNTESTED | – | skill pipeline never fired in test |
| Concurrent writes | UNTESTED in volume | – | 20 parallel health probes ok |
| SSE back-pressure | UNTESTED | – | – |
| Log rotation under pressure | UNTESTED | – | rotate config in unit but not stress-tested |
| Malformed JSON-RPC | UNTESTED | – | – |
| Hub degradation | 8/10 | hub-sync.py fail-soft | exit 2 + retry on next tick |
| Host-LLM-bridge fallback | UNTESTED | – | – |
| Rapid restart | UNTESTED in volume | – | single restart clean |
| Viewer connection flood | UNTESTED | – | – |
| Power-cut durability | UNTESTED | – | WAL + synchronous default |
| Loopback bind enforcement | 9/10 | n/a | 127.0.0.1 only, verified |

**Overall resilience score (MIN of measured rows): 7/10.**
**UNTESTED rows: 12 of 18.**

## Worst realistic failure case

**Mid-flight capture across the v2 bridge ↔ Hermes session boundary.**

The Hermes adapter spawns the v2 bridge as a session-scoped subprocess. If Hermes dies between `turn.end` and `episode.finalize`, any traces queued in the in-memory ingest pipeline that hadn't reached `traces` table will be lost. There's no persistent outbox (per `core/capture/` source — the `decision_repairs` table exists but is for repair decisions, not durable capture queue).

Mitigation: the user-visible content (chat responses) is generated before capture writes, so user experience isn't directly impacted. But trace-derived L2/L3/skill evolution loses those turns silently.

Severity: **moderate**. Acceptable for a chat agent; not acceptable for a logging/analytics system.

## Honest take

The system is **operationally stable for our deployment**: hub stays up across restarts, loopback bind is locked down, integrity check on the live DB passes, sync bridge fail-soft. **Not stress-tested**: corruption, ENOSPC, kill -9 chains, concurrent writes at scale, SSE backpressure. A real blind audit run with these chaos probes would likely find issues we haven't surfaced.

Score 7/10 reflects "we tested the obvious failure modes, didn't run the scary ones."
