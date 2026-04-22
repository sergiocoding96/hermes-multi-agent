# memos-local-plugin v2.0 Hub & Multi-Agent Sharing Audit

Paste this into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

v2.0 has **two distinct hub surfaces**, and they are easy to confuse:

1. **Peer registry** on every plugin instance — `GET|POST /api/v1/hub/register`, `GET /api/v1/hub/peers`. It is a loopback-only service-discovery list so multiple agents (hermes, openclaw) running on the same box can see each other's viewer ports. **Read `server/routes/hub.ts` for the exact behaviour.**
2. **Team-sharing hub (stub)** — `core/hub/` — an opt-in server role (`hub.enabled: true`, `hub.role: "hub"`, default port `18912`) that stores shared memories and skills with `visibility` levels (`local` / `group` / `public`) and authenticates clients via `teamToken` + per-user `userToken`. **Read `core/hub/README.md`.** At v2.0.0-beta.1 this is largely a stub — verify what is actually implemented vs documented.

Default viewer port per `core/config/defaults.ts`: `127.0.0.1:18799` (walks `+1..+10` on collision — actual bound port surfaces in `GET /api/v1/health`). Hub port: `18912`. Bridge port (if `bridge.mode: "tcp"`): `18911`. Source root: `~/.hermes/plugins/memos-local-plugin/`. Runtime: `~/.hermes/memos-plugin/`.

**Your job:** for each surface, verify (a) auth model is enforced end-to-end, (b) port-fallback multi-agent peer registry works correctly, (c) visibility ACL is enforced server-side (not just client-filter), (d) pairing / token flow cannot be bypassed, (e) offline / partition behaviour is graceful, (f) no loopback-escape (hub must never bind a public interface). Score 1-10.

Use marker `HUB-AUDIT-<timestamp>`. Stand up throwaway profiles — `agent-a`, `agent-b`, `agent-c` — via `MEMOS_HOME` overrides; do not mutate any existing install.

### Recon

- `server/routes/hub.ts` — peer-registry routes, loopback enforcement (`req.socket.remoteAddress === '127.0.0.1'` or similar), ttl for registrations.
- `core/hub/README.md` + `core/hub/*.ts` — team-sharing protocol: pairing, token issuance, publish, subscribe, tombstone replication, visibility filter.
- `core/config/defaults.ts` — `hub.*` config keys and their defaults.
- `agent-contract/jsonrpc.ts` — any hub-scoped RPC methods.
- `docs/MULTI_AGENT_VIEWER.md` — the port-fallback story.
- Schema: `publishedSkills` table (or equivalent) for the shared skill index.

### Peer-registry probes (local service discovery)

**Port fallback:**
- Launch agent-a (default 18799). Launch agent-b — must bind 18800. Launch agent-c → 18801. Verify by `ss -ltn | grep 1879`.
- Each instance calls `POST /api/v1/hub/register` with its actual port + agent id + pid. `GET /api/v1/hub/peers` on any instance returns all three?
- Kill agent-b hard. After TTL expiry (find it), does `peers` drop agent-b? Or does the stale row persist?

**Loopback enforcement:**
- Attempt to reach `POST /api/v1/hub/register` from `192.168.x.x` (use `curl --interface` or `nc` from another host in the LAN, or spoof via `X-Forwarded-For`). Must be **refused at socket-accept level** (`bindHost: "127.0.0.1"`), not just a 403 — a bound `0.0.0.0` with an app-level check is still a leak.
- Confirm via `ss -ltn`: bound address is 127.0.0.1 only.
- Check every hub-related route for header-spoofing trust (X-Forwarded-For, X-Real-IP).

**Registration forgery:**
- From loopback: register with a made-up agent id + port pointing to an evil server. `peers` now advertises the poisoned entry to legit agents. Is there any signing / auth on registration?
- If no signing, document the trust model (loopback-only may be enough).

### Team-sharing hub probes (if `hub.enabled=true`)

**Setup:**
- Enable hub on agent-a (`hub.role: "hub"`), run as hub. Configure agent-b + agent-c as clients. Confirm all three boot cleanly.
- Where is `hub-auth.json` / teamToken stored? File mode? Perms 600?

**Pairing flow:**
- Fresh client (agent-d) attempts `/api/v1/hub/…` without pairing. Expect auth denial with a specific `ERROR_CODES` entry from `agent-contract/errors.ts`.
- Execute the pairing handshake per `core/hub/README.md`. What does it require — human approval in viewer? Signed nonce? OOB teamToken?
- After pairing, repeat — succeeds?

**Pairing security:**
- Pair without knowing `teamToken` — possible? If yes, major auth bug.
- Self-assign to a group by declaring it in the request — refused by the hub (groups must be server-assigned)?
- Replay a valid pairing request — second attempt refused (nonce reuse)?

**Revocation:**
- Remove agent-b from the group on the hub. Immediate next query — denied? Or only denied on next session / token refresh?
- Active SSE / long-poll connection — forcibly torn down on revoke?

**Visibility ACL (the core question):**

Visibility=local — must never leave the client:
- Agent-b writes a memory with `visibility=local`. Inspect: in b's local SQLite, absent from hub's DB at all (direct SQL). Absent from c's queries.
- If the hub DB has it filtered at read-time only, that's a leak. Verify.

Visibility=group — within-group only:
- Agent-b writes `visibility=group`. Lands on hub DB.
- Agent-c (same group) queries hub — sees it, correct score.
- Agent-d (different group, set up a `dev-team` group with d only) queries — absent.
- Unauthenticated client — absent.

Visibility=public:
- Agent-b writes `visibility=public`. Hub stores it.
- Agent-d (different group) queries — present.
- Unauthenticated — design decision; document what it is (likely denied).

**Cross-group contamination:**
- Set up `ceo-team` (a, b, c) and `dev-team` (d). Verify d cannot see ceo-team's group-visibility memories under any query (direct SQL on hub, filtered search, skill discovery).

**Skill sharing:**
- Agent-a generates a skill with `visibility=group`. Appears in agent-b's skill-discovery?
- Same with `visibility=local` → must NOT leak to b.
- Same with `visibility=public` → d (different group) sees?
- Skill content delivery: is the SKILL.md blob served from hub, or only the index (and b fetches content out-of-band)?

**Tombstone replication:**
- Agent-a retires a shared skill. Tombstone propagates to b + c on next sync? After propagation, b + c cannot execute or discover it? `skill_evidence` retained for audit?

### Cross-agent retrieval ranking

- Agent-a writes 10 memories on topic X with varying specificity and `visibility=group`. Agent-b queries topic X.
- Ranking respects relevance only, or does "same-client bonus" bump b's own memories ahead of a's higher-relevance ones? Document the rule + verify.
- Metadata on b's view of a's memory: author-agent, original timestamp, visibility, correlation id — all preserved?

### Offline behaviour

**Client offline while writing:**
- Block egress from agent-b to hub (iptables loopback rule, or stop hub). Agent-b continues to write memories locally.
- Verify all land in b's local DB.
- b searches locally — own memories + cached group memories if any (confirm caching policy in `core/hub/README.md`).

**Reconnect sync:**
- Restore hub. Does b auto-sync queued writes? Ordering preserved? Duplicates dedup'd?
- Timestamps: client-assigned or hub-reassigned on sync? (Client-assigned + clock skew = ordering bug.)

**Hub offline, client alive:**
- Stop hub. b issues a search. Expected: local-only degraded mode with a clear warning. Catastrophic failure (500 on every search) is a bad result.

**Partition rejoin:**
- Agent-a offline for a long period, accumulates 100 memories. Reconnect. Catch-up: blocking (agent stalls) or background (agent usable during catch-up)? Progress observable in `events.jsonl` / viewer Admin?

### Concurrency

**Same-memory race:**
- Agents b + c both write identical content with `visibility=group` within 10ms. Hub dedups (one row) or stores two with different ids? Author attribution?

**Membership change mid-write:**
- Remove b from the group while b is flushing a 50-write queue. Already-queued writes — land or reject? Future writes refused with specific error?

### Viewer Admin UX

In the hub agent's viewer:
- Groups + members visible?
- Per-client memory / skill counts?
- Force re-sync / rebalance a client?
- Edit ACL (add/remove member, change visibility on a memory)?
- Audit log of membership changes?

### Telemetry

- `audit.log` entries on: pair, unpair, group-add, group-remove, token-refresh, ACL-change. Every one with actor + method + target.
- `events.jsonl` entries on replication push/pull, tombstone propagation, port-fallback fires.

### Reporting

| Area | Score 1-10 | Key finding |
|----|---|---|
| Peer-registry port fallback | | |
| Peer-registry loopback bind | | |
| Peer-registry TTL / stale | | |
| Registration forgery | | |
| Pairing flow correctness | | |
| Pairing — teamToken required | | |
| Pairing — self-group bypass | | |
| Pairing — replay protection | | |
| Revocation immediacy | | |
| Visibility=local enforcement | | |
| Visibility=group enforcement | | |
| Visibility=public behaviour | | |
| Cross-group isolation | | |
| Skill visibility (3 levels) | | |
| Skill content delivery | | |
| Tombstone replication | | |
| Cross-agent relevance | | |
| Cross-agent metadata preservation | | |
| Offline write persistence | | |
| Reconnect sync correctness | | |
| Hub-offline client search | | |
| Partition-rejoin catch-up | | |
| Concurrent-write dedup | | |
| Membership-change atomicity | | |
| Viewer Admin UX | | |
| Audit / event telemetry | | |

**Overall hub-sharing score = MIN of above.**

Paragraph: is the multi-agent + team-sharing story safe to turn on for real data across agents that may have different trust levels, or is it beta-stub-only?

### Out of bounds

Do not read `/tmp/`, `CLAUDE.md`, `tests/v2/reports/`, `memos-setup/learnings/`, prior audit reports, or plan/TASK.md files. If hub is a stub at beta-1 and most of the above can't run end-to-end, score each untested row as "UNTESTED — implementation absent" rather than guessing.


### Deliver — end-to-end (do this at the end of the audit)

Reports land on the shared branch `tests/v2.0-audit-reports-2026-04-22` (at https://github.com/sergiocoding96/hermes-multi-agent/tree/tests/v2.0-audit-reports-2026-04-22). Every audit session pushes to it directly — that's how the 10 concurrent runs converge.

1. From `/home/openclaw/Coding/Hermes`, ensure you are on the shared branch:
   ```bash
   git fetch origin tests/v2.0-audit-reports-2026-04-22
   git switch tests/v2.0-audit-reports-2026-04-22
   git pull --rebase origin tests/v2.0-audit-reports-2026-04-22
   ```
2. Write your report to `tests/v2/reports/hub-sharing-v2-$(date +%Y-%m-%d).md`. Create the directory if it does not exist. The filename MUST use the audit name (matching this file's basename) so aggregation scripts can find it.
3. Commit and push:
   ```bash
   git add tests/v2/reports/<your-report>.md
   git commit -m "report(tests/v2.0): hub-sharing audit"
   git push origin tests/v2.0-audit-reports-2026-04-22
   ```
   If the push fails because another audit pushed first, `git pull --rebase` and push again. Do NOT force-push.
4. Do NOT open a PR. Do NOT merge to main. The branch is a staging area for aggregation.
5. Do NOT read other audit reports on the branch (under `tests/v2/reports/`). Your conclusions must be independent.
6. After pushing, close the session. Do not run a second audit in the same session.
