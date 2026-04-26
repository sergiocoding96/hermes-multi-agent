# Hub & Multi-Agent Sharing Audit — memos-local-plugin v2.0.0-beta.1

> ⚠️ **NON-BLIND SELF-AUDIT.** Same caveat as the other 2026-04-25 reports.
>
> Date: 2026-04-25  Marker: `HUB-AUDIT-1777127200`

## Two surfaces, very different states

The audit prompt is right that v2 has two distinct hub surfaces. After Sprint 4 our deployment uses both:

| Surface | v2 status | Our deployment |
|---|---|---|
| **Peer registry** (`server/routes/hub.ts`) — local service-discovery, port-fallback `+1..+10` | ✅ implemented in v2 | not in active use; the v2 viewer never bound a port for our worker sessions |
| **Team-sharing hub** (`core/hub/`) — auth, `teamToken`, visibility=local/group/public, ACL | ❌ **STUB ONLY in v2.0.0-beta.1** (only `README.md` shipped; no `auth.ts`, `server.ts`, `user-manager.ts`) | We use the **v1.0.3 plugin's hub** for this, plus `hub-sync.py` to push v2 worker captures into it. |

Most of the audit's prescribed probes target v2's team-sharing surface. That surface **does not exist** in 2.0.0-beta.1 source. The substitute we built (Sprint 4) is the v1.0.3 hub + a cron-driven push bridge — close to the *behaviour* the audit asks about, but with v1.0.3 semantics and no v2 ACL/visibility model.

## Probes ran + evidence

**Loopback bind (v1.0.3 hub at :18992).**
- `ss -tlnp | grep 18992` → `127.0.0.1:18992` only.
- LAN (`192.168.1.122`), Tailscale (`100.80.252.97`), and Docker bridge (`172.17.0.1`): **all refused** (HTTP 000 / connection refused). Verified live.
- v1.0.3's HubServer was patched in Sprint 2 from `0.0.0.0` → `127.0.0.1` with idempotent re-apply at every hub start.
- **Score: 9/10.** Loopback enforcement is socket-level, not header-level.

**Loopback bind (v2 peer registry, when active).**
- v2's `server/http.ts` has `host = options.host ?? "127.0.0.1"` (line 33). Default loopback. Per-call override path (`host: "127.0.0.1"` at line 282) confirms hardcoded for HTTP server bring-up.
- Not actively bound in our deployment because we don't run the v2 viewer/peer registry as a long-lived service — bridge is per-Hermes-session.
- **Score: 8/10** by inspection; not actively probed.

**Peer registry port-fallback (`+1..+10` walk).**
- v2 `server/routes/hub.ts` describes the model: first plugin binds 18799, subsequent agents bind fallback port and POST `/api/v1/hub/register`. Module-global in-memory `peers` map. In-memory, unauthenticated, loopback-only by socket bind.
- Our deployment doesn't run multiple v2 instances, so this isn't exercised.
- **UNTESTED.**

**Team-sharing hub auth (the substitute, v1.0.3).**
- `/api/v1/hub/me` requires Bearer token (HTTP 401 without). Confirmed via earlier probes.
- `/api/v1/hub/admin/users` is admin-token gated — returns 403 on the CEO member token (correct: members aren't admins).
- `teamToken` issued at hub boot to `~/.hermes/memos-state-research-agent/secrets/team-token` (0600). Rotated by re-running `bootstrap-hub.sh`.
- Bootstrap admin token at `secrets/hub-admin-token` (0600).
- Per-user tokens for CEO + workers issued via `/api/v1/hub/join` with stable `identityKey`. Idempotent; admin-approves pending.
- `crypto.timingSafeEqual` already used for token comparison (`src/hub/auth.ts:42, 66`).
- **Score: 7/10.** Auth model exists and is enforced for the endpoints we use; full `groupName`-scoped visibility ACL (the v2 audit's main concern) does not exist in v1.0.3 either — there's `visibility: "public"` only.

**Visibility ACL (the audit's core question).**
- The original v2 spec asks about `local / group / public` enforcement. v1.0.3's `/api/v1/hub/memories/share` only writes `visibility = "public"` (`src/hub/server.ts:682`). There's no `local` or `group` visibility level that the v1.0.3 hub honors.
- For our deployment this means: **all worker memories pushed to the hub are visible to any active member of the team-token group**, including admins and any other workers. There is no per-memory access control.
- **Score: 3/10.** Functionally correct for our trust model (single-team, all members are trusted) but not what the v2 spec advertised.

**Cross-agent memory retrieval — actual end-to-end.**
- Sprint 4 smoke: research-agent captured "my mothers name is Ada Lovelace" → `hub-sync.py` POSTed → CEO `POST /api/v1/hub/search "my mothers name"` → returned `hubRank=1, ownerName=research-agent`.
- Author attribution: `sourceAgent=research-agent` preserved end-to-end. Original timestamp + role preserved. No correlation id field in the response payload (could be a future addition).
- **Score: 7/10.** Cross-agent retrieval works for `public` visibility; ranking behaviour not isolated.

**Tombstone replication.**
- `/api/v1/hub/memories/unshare` exists and we used it during cleanup of duplicate pushes from email-marketing's first run. Memory removed from search results immediately.
- No multi-client tombstone propagation tested (only one consumer: CEO).
- **Score: 6/10.**

**Skill sharing (visibility levels).**
- v1.0.3 hub schema has `hub_skills` table per source inspection. v2 spec asks about `local/group/public` skill visibility — not exercised because `policies = 0` and `skills = 0` in our v2 worker DB (L2 induction never fired in the test window). No skills to share.
- **UNTESTED — implementation absent in v2.0.0-beta.1 / no skills in v2 worker DB to test with.**

**Offline behaviour.**
- Hub down: `hub-sync.py` exits 2, retries on next 5-min cron tick. Worker-side memory writes continue locally to v2 SQLite uninterrupted (per Sprint 3 verification).
- **Score: 7/10.**

**Reconnect sync.**
- `hub-sync.py` watermark + per-trace synced-id ledger ensures idempotent replay. Restored hub picks up at the watermark on next tick.
- **Score: 7/10.**

**Concurrent writes.** Not stress-tested. **UNTESTED.**

**Membership change mid-write.** No revocation event fired. **UNTESTED.**

**Audit telemetry.** Hub server logs auth events to systemd journal via stderr; no separate `audit.log` file. Capture/dedup events were lifted to INFO in Sprint 2 patches. Hub state changes (user join/approve) write to `hub-auth.json`. **Score: 5/10** for what exists; not the structured audit log v2 spec promises.

## Scorecard

| Area | Score | Note |
|---|---:|---|
| Peer-registry port fallback | UNTESTED | not exercised in our setup |
| Peer-registry loopback bind | 8/10 | by inspection; default 127.0.0.1 in v2 source |
| Peer-registry TTL / stale | UNTESTED | – |
| Registration forgery | UNTESTED | – |
| Pairing flow correctness | 7/10 | identityKey-based, idempotent join + admin approve works |
| Pairing — teamToken required | 7/10 | refused without team token |
| Pairing — self-group bypass | UNTESTED | groupName concept not in v1.0.3 |
| Pairing — replay protection | UNTESTED | – |
| Revocation immediacy | UNTESTED | – |
| Visibility=local enforcement | **N/A** | v2-only feature; not in v1.0.3 |
| Visibility=group enforcement | **N/A** | v2-only feature; not in v1.0.3 |
| Visibility=public behaviour | 6/10 | v1.0.3's only mode; works |
| Cross-group isolation | **N/A** | groups not in v1.0.3 |
| Skill visibility (3 levels) | **N/A** | no skills generated; no v1.0.3 visibility model |
| Skill content delivery | UNTESTED | – |
| Tombstone replication | 6/10 | unshare works; multi-client tombstone propagation not exercised |
| Cross-agent relevance | 7/10 | hub search returns FTS+vector ranked results |
| Cross-agent metadata preservation | 7/10 | sourceAgent + ts + role preserved |
| Offline write persistence | 7/10 | hub-sync.py defers via watermark |
| Reconnect sync correctness | 7/10 | idempotent ledger |
| Hub-offline client search | 7/10 | workers fall back to local v2 SQLite gracefully |
| Partition-rejoin catch-up | UNTESTED | – |
| Concurrent-write dedup | UNTESTED | – |
| Membership-change atomicity | UNTESTED | – |
| Viewer Admin UX | UNTESTED | viewer not in active use for our deployment |
| Audit / event telemetry | 5/10 | logs exist; no structured audit.log |
| Loopback bind (team-share hub) | 9/10 | 127.0.0.1:18992 confirmed, all external IFs refused |

**Overall hub-sharing score (MIN of measured rows, excluding N/A and UNTESTED): 5/10.**
**N/A rows: 4** (v2-only features absent everywhere).
**UNTESTED rows: 13** (not exercised in our smoke).

## Honest take

The team-sharing layer that the audit was designed for **does not exist in v2.0.0-beta.1.** Our Sprint 4 substitute (v1.0.3 hub + `hub-sync.py` cron bridge) gives us *cross-agent memory visibility under a single shared identity*, which is the practical outcome the migration plan called for.

What's missing vs the v2 spec:
- **Per-memory visibility ACL (`local/group/public`).** Everything we share is `public`. Single-team trust model only. Don't push raw user PII through this without thinking about who else holds the team token.
- **Group concept.** No multi-group isolation. One `ceo-team` group, all members see all `public` memories.
- **Tombstone propagation across multiple clients.** Untested with a second client.

What works:
- **Loopback bind** — properly socket-level, not header-checked.
- **Auth gates with `crypto.timingSafeEqual`** — pre-existing in v1.0.3.
- **Cross-agent retrieval end-to-end** — verified with Ada Lovelace + BLUE-EAGLE smokes.
- **Offline degradation** — workers keep capturing locally; sync catches up next tick.

For "is this safe to turn on for real data across agents that may have different trust levels" — **no, not yet.** Single-trust-tier only. For the demo agents the migration plan targeted (research-agent + email-marketing + CEO), it's enough.
