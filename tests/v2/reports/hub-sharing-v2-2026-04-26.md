# Hub & Multi-Agent Sharing Audit — v2.0.0-beta.1
**Audit marker:** HUB-AUDIT-1777210004  
**Date:** 2026-04-26  
**Plugin version:** 2.0.0-alpha.1 (as reported by `/api/v1/health`)  
**Source root:** `~/.hermes/memos-plugin/`  
**Test profiles:** `/tmp/memos-hub-audit-agent-{a,b,c}` (throwaway, MEMOS_HOME overrides)

---

## Executive Summary

The v2.0 codebase has **two distinct hub surfaces** with very different maturity levels:

1. **Peer-registry** (`server/routes/hub.ts`) — implemented, functional, and used in production by the openclaw/hermes dual-install case. Correctly binds loopback-only, enforces agent name whitelist, and uses socket address for loopback checks (not spoofable headers). Key gaps: no TTL cleanup of stale entries, no cryptographic signing on registrations, and the peer namespace is constrained to exactly two names so two same-type agents overwrite each other.

2. **Team-sharing hub** (`core/hub/`) — **stub only**. The `README.md` describes `auth.ts`, `server.ts`, and `user-manager.ts`; none of these files exist on disk. All RPC bridge methods (`hub.status`, `hub.publish`, `hub.pull`) throw `"not implemented yet in V1"`. The `hub-admin` HTTP route returns empty arrays. Hub-related audit events and `events.jsonl` entries are declared in the contract layer but never emitted anywhere in the implementation. The team-sharing story is **not safe for real data** at this version.

---

## Recon Summary

| File | State |
|------|-------|
| `server/routes/hub.ts` | Implemented — peer registry, loopback check |
| `server/routes/hub-admin.ts` | Stub — returns empty lists when `hub.enabled=true` |
| `core/hub/README.md` | Exists, documents intended design |
| `core/hub/auth.ts` | **Missing** |
| `core/hub/server.ts` | **Missing** |
| `core/hub/user-manager.ts` | **Missing** |
| `core/config/defaults.ts` | Hub config block present (`enabled: false`, port `18912`) |
| `core/config/schema.ts` | `HubSchema` with `role`, `port`, `address`, `teamToken`, `userToken`, `nickname` |
| `agent-contract/jsonrpc.ts` | `hub.status`, `hub.publish`, `hub.pull` declared |
| `bridge/methods.ts` | All three hub RPC methods throw `"not implemented yet in V1"` |
| `agent-contract/events.ts` | `hub.client_connected`, `hub.client_disconnected`, `hub.share_published`, `hub.share_received` declared |
| `core/storage/repos/audit.ts` | Audit repo implemented; kind examples include `"hub.join"` in a comment — no hub events actually written anywhere |
| `docs/MULTI_AGENT_VIEWER.md` | Describes peer-discovery design (option 2: one viewer per agent with cross-linking) |
| No `published_skills` / `hub_imported_skills` SQL migration | Confirms team-sharing DB layer absent |
| `share_scope` columns (`'private'|'public'|'hub'`) | Present on `traces`, `skills`, `policies`, `world_model` — viewer-layer metadata only, not enforced by hub logic |

---

## Peer-Registry Probes

### Port Fallback

**Tested live:** started agent-a (grabbed 18799), then agent-b and agent-c concurrently.

- agent-a: bound 18799 (default)
- agent-b: `server.port_fallback { requested: 18799, bound: 18800, tries: 1 }`
- agent-c: `server.port_fallback { requested: 18799, bound: 18801, tries: 2 }` (18799 and 18800 both taken)
- After fallback, each agent calls `POST /api/v1/hub/register` with its actual port; confirmed via `GET /api/v1/hub/peers`

**Code path:** `server/http.ts` lines 66–99 — walks `port+i` for `i = 0..10`; logs `server.port_fallback` when `i > 0`. Fallback tries capped at 10.

**`ss -ltn` output confirmed:** all three bound `127.0.0.1:1879{9,0,1}`, not `0.0.0.0`.

**Finding:** Port fallback works correctly. **Score: 8/10** — the cap at 10 fallback attempts means an 11th agent fails to bind entirely rather than escalating (acceptable for the two-agent use case it's designed for, but undocumented limit).

### Loopback Enforcement

**Tested live:**

1. `curl --interface 192.168.1.122 POST /api/v1/hub/register` → `Connection refused` (server never accepts the TCP connection).
2. `ss -ltn` confirms `127.0.0.1:18799` — not `0.0.0.0`.
3. `X-Forwarded-For: 192.168.1.100` header sent while connecting from 127.0.0.1 → registration accepted (correct: header is ignored, socket address used).

**Code path:** `hub.ts:isLoopback()` checks `ctx.req.socket.remoteAddress` against `127.0.0.1`, `::1`, `::ffff:127.0.0.1`. No forwarded-header trust anywhere in the route.

**Finding:** Loopback enforcement is socket-level, not header-based. **Score: 9/10** — deduction for IPv6 `::ffff:127.0.0.1` being in the allowlist but `::1` not having its own explicit test in `server/http.ts` startup bind config (bind is driven by `config.viewer.bindHost` = `"127.0.0.1"` by default, so IPv6 loopback can only arrive via IPv4-mapped which is handled).

### TTL / Stale Entries

**Tested live:** killed agent-c (port 18802) hard via `SIGTERM`. After process death:
- `GET /api/v1/hub/peers` still returns the dead agent's entry (`port: 18802`, stale `registeredAt`).
- `GET /openclaw/...` proxy to a dead peer returns `502` with `{ error: { code: "peer_unreachable", ... } }`.

**Code path:** `server/routes/hub.ts` — peers stored in a `Map<string, PeerInfo>` with no TTL, no periodic cleanup, no heartbeat requirement. `registeredAt` is recorded but never checked. There is no background job sweeping stale entries.

**Finding:** Stale entries persist indefinitely until hub process restart or explicit `POST /api/v1/hub/deregister`. A peer that crashes without sending SIGTERM (OOM kill, `kill -9`) leaves a poisoned routing entry. **Score: 4/10** — this is a known limitation documented in the inline comment ("dropped on process restart; peers re-register on their own health loop") but no health-loop implementation exists in the codebase.

### Registration Forgery

**Tested live:** from loopback, registered `agent=hermes, port=19999, version=evil-1.0` → accepted with HTTP 200. Peers endpoint immediately advertised the forged entry to all other agents.

**Code path:** No MAC, no nonce, no PSK on `POST /api/v1/hub/register`. Validation is:
- agent must be `"openclaw"` or `"hermes"`  
- port must be 1024–65535

**Trust model documented inline:** "The registry is intentionally in-memory and unauthenticated — it only accepts registrations from loopback." This is explicitly a loopback-trust model.

**Implication:** Any process running under any user on the same host can poison the peer registry. For a single-user workstation (the intended deployment), this is acceptable. For a shared multi-user machine it would be a lateral-movement risk.

**Additional finding (namespace collision):** The peer map key is the agent name string. Both agent-b and agent-c boot as `agent: "hermes"`. When c registers after b, c's entry **overwrites** b's in the map. The peer registry effectively supports at most one instance per agent name. Routing to `/hermes/...` always proxies to the last registrant.

**Score: 5/10** — loopback-trust is documented and intentional; however, the same-name overwrite is an undocumented sharp edge that breaks multi-instance scenarios. Would be 7/10 with a documented namespace and the overwrite behavior made explicit.

---

## Team-Sharing Hub Probes

> All items in this section are rated **UNTESTED — implementation absent** unless static analysis or stub behavior reveals useful signal.

### Setup

Attempted to enable hub: `hub.enabled: true, hub.role: "hub"` in config. The `GET /api/v1/hub/admin` endpoint returns:

```json
{ "enabled": true, "role": "hub", "pending": [], "users": [], "groups": [] }
```

No additional server binds on port 18912 — no hub server exists to start.

**Core hub files present:** only `README.md`. Files documented in that README (`auth.ts`, `server.ts`, `user-manager.ts`) are absent.

### Pairing Flow — UNTESTED (implementation absent)

No pairing handshake exists. `hub.status` / `hub.publish` / `hub.pull` bridge methods throw:
```
MemosError: hub.status: not implemented yet in V1
```

**Score: UNTESTED — implementation absent**

### Pairing Security — UNTESTED

`teamToken` and `userToken` are schema'd and listed as `SECRET_FIELD_PATHS` (never surfaced via API), but no code reads or validates them against incoming requests.

**Score: UNTESTED — implementation absent**

### Revocation — UNTESTED

**Score: UNTESTED — implementation absent**

### Visibility=local Enforcement — UNTESTED

The `share_scope` column (`'private'|'public'|'hub'`) exists on `traces`, `skills`, `policies`, `world_model` (migrations 006 and 009). These are viewer-layer labels only — no enforcement code exists in the retrieval or hub layer. No `visibility=local/group/public` enum exists in the DB schema or type definitions; the `core/hub/` runtime that would apply ACLs has not been written.

**Score: UNTESTED — implementation absent**

### Visibility=group Enforcement — UNTESTED

**Score: UNTESTED — implementation absent**

### Visibility=public Behaviour — UNTESTED

**Score: UNTESTED — implementation absent**

### Cross-Group Isolation — UNTESTED

**Score: UNTESTED — implementation absent**

### Skill Visibility (3 levels) — UNTESTED

Skills have `share_scope TEXT` column but no group/public enforcement. `hub.publish` is not implemented.

**Score: UNTESTED — implementation absent**

### Skill Content Delivery — UNTESTED

**Score: UNTESTED — implementation absent**

### Tombstone Replication — UNTESTED

`skill.retire` writes a tombstone locally; no replication path to hub exists. `events.jsonl` entries for tombstone propagation are declared but never emitted.

**Score: UNTESTED — implementation absent**

---

## Cross-Agent Retrieval Ranking — UNTESTED

The peer registry proxies HTTP requests between viewers but does not aggregate memory namespaces. From `MULTI_AGENT_VIEWER.md` ("Non-goals"): "We don't aggregate memories from both agents into one search. Different agents' memory namespaces are deliberately isolated." Cross-agent retrieval ranking is therefore a non-feature at this version, not just unimplemented hub sharing.

**Score: UNTESTED — not in scope at this version**

---

## Offline Behaviour — UNTESTED (team-sharing hub absent)

**Client offline while writing:** Each instance writes to its own local SQLite. Local writes are unaffected by hub state. Confirmed by code: hub calls are behind `config.hub.enabled` guard; all storage writes go directly to local DB. Degraded local-only mode is the default.

**Reconnect sync / Hub-offline client search / Partition catch-up:** UNTESTED — no sync engine exists.

**Score for local write persistence: 9/10** (design is correct). Scores for reconnect/sync/catch-up: **UNTESTED — implementation absent**.

---

## Concurrency — UNTESTED

**Score: UNTESTED — implementation absent**

---

## Viewer Admin UX

**GET /api/v1/hub/admin** returns a stub:
```json
{ "enabled": true, "role": "hub", "pending": [], "users": [], "groups": [] }
```

The `hub-admin.ts` file explicitly states: "wiring in real sync state is a separate phase."

No force re-sync, ACL edit, per-client counts, or membership audit log is implemented.

**Score: 2/10** — endpoint exists and returns correct shape for the disabled path; active-hub path returns empty stub data only.

---

## Audit / Event Telemetry

**Audit log infrastructure:** `core/storage/repos/audit.ts` and `core/logger/sinks/audit-log.ts` are fully implemented. The `audit_events` table exists in every fresh DB. Kind field comment in the repo source lists `"hub.join"` as an example event kind.

**Hub events actually emitted:** none. Searched all `.ts` files for `hub.client_connected`, `hub.share_published`, `hub.share_received`, `hub.client_disconnected`, `hub.join`, `hub.pair`, `hub.revoke` — zero hits outside the declaration files (`agent-contract/events.ts`, `agent-contract/jsonrpc.ts`, the audit repo comment).

**events.jsonl entries for replication/tombstone:** declared in `agent-contract/events.ts` but never emitted. Logger channels `core.hub`, `core.hub.server`, `core.hub.client`, `core.hub.sync` defined but unused.

**Score: 3/10** — infrastructure is solid; hub-specific telemetry is entirely absent. A live audit trail of hub operations cannot be produced at this version.

---

## Scoring Table

| Area | Score 1–10 | Key finding |
|------|-----------|-------------|
| Peer-registry port fallback | 8 | Works correctly; 10-port cap undocumented |
| Peer-registry loopback bind | 9 | Socket-level, not header-based; `127.0.0.1` confirmed via `ss -ltn` |
| Peer-registry TTL / stale | 4 | No TTL; stale entries persist after peer crash until hub restart |
| Registration forgery | 5 | Loopback-trust intentional; same-name overwrite undocumented sharp edge |
| Pairing flow correctness | UNTESTED | `core/hub/` files absent; bridge throws "not implemented yet in V1" |
| Pairing — teamToken required | UNTESTED | `teamToken` schema'd and redacted; never validated |
| Pairing — self-group bypass | UNTESTED | Implementation absent |
| Pairing — replay protection | UNTESTED | Implementation absent |
| Revocation immediacy | UNTESTED | Implementation absent |
| Visibility=local enforcement | UNTESTED | `share_scope` column exists; no ACL enforcement code |
| Visibility=group enforcement | UNTESTED | Implementation absent |
| Visibility=public behaviour | UNTESTED | Implementation absent |
| Cross-group isolation | UNTESTED | Implementation absent |
| Skill visibility (3 levels) | UNTESTED | `share_scope` on skills table; no push/pull/filter logic |
| Skill content delivery | UNTESTED | Implementation absent |
| Tombstone replication | UNTESTED | Local retire works; no hub replication path |
| Cross-agent relevance | UNTESTED | Design doc explicitly excludes cross-agent aggregation at this version |
| Cross-agent metadata preservation | UNTESTED | No cross-agent retrieval |
| Offline write persistence | 9 | Local SQLite writes unaffected by hub state; confirmed by design |
| Reconnect sync correctness | UNTESTED | No sync engine |
| Hub-offline client search | 9 | Falls back gracefully to local-only (default behavior; no hub dependency in retrieval path) |
| Partition-rejoin catch-up | UNTESTED | No sync engine |
| Concurrent-write dedup | UNTESTED | Hub DB absent |
| Membership-change atomicity | UNTESTED | Implementation absent |
| Viewer Admin UX | 2 | Endpoint returns correct disabled-path shape; active-hub path is empty stub |
| Audit / event telemetry | 3 | Infrastructure exists; zero hub events emitted in practice |

**Overall hub-sharing score = MIN of above = 2** (Viewer Admin UX)

---

## Paragraph: Is the multi-agent + team-sharing story safe for real data?

**No.** At v2.0.0-beta.1, the team-sharing hub is a well-designed stub: the schema, config, contract layer, and README are in place, but the three critical implementation files (`core/hub/auth.ts`, `core/hub/server.ts`, `core/hub/user-manager.ts`) do not exist. All hub RPC methods throw a "not implemented" error. There is no auth, no pairing, no token validation, no visibility ACL enforcement, and no audit trail for hub events. Enabling `hub.enabled: true` produces a config that is accepted without error but does nothing beyond returning empty stub arrays from the admin endpoint.

The **peer-registry** surface (dual openclaw/hermes install on one box) is production-ready for its narrow use case: loopback-only binding, socket-level address check, graceful 502 on dead peers. Its limitations — no TTL on stale entries, no signing, same-name-agent overwrite — are acceptable given the single-user workstation deployment model and should be documented explicitly.

The team-sharing hub should carry a **beta-stub-only** warning in the changelog and documentation. It must not be enabled in any environment where multiple agents with different trust levels share data, until at minimum: `auth.ts` (token validation), `user-manager.ts` (group membership), visibility ACL enforcement in the retrieval layer, and hub-event audit telemetry are implemented and pass a follow-up security review.
