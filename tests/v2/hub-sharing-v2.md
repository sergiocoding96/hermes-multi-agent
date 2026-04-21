# Hermes v2 Hub Sharing Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

Product 2 includes a hub HTTP server on `http://localhost:18992` that serves shared memories and skills across multiple client profiles. Each profile has its own local SQLite and connects to the hub. Memories have visibility levels (`local`, `group`, `public`) which control whether other clients can see them.

Profiles on this machine: `arinze`, `email-marketing`, `mohammed`, `research-agent`. Groups are configured in plugin config; the `ceo-team` group exists and contains at least research-agent and email-marketing per the migration plan.

Plugin source `~/.hermes/memos-plugin-<profile>/`. Hub auth material `~/.hermes/memos-state-<profile>/hub-auth.json`.

Your job: **Verify (a) visibility ACL is enforced end-to-end, (b) pairing flow and allowlist work correctly, (c) cross-agent search is relevance-ranked, (d) offline clients operate gracefully, (e) hub ↔ client sync is eventually consistent.** Score 1-10.

Use marker `HUB-AUDIT-<timestamp>`. Create test profiles / groups / memories rather than mutating production data.

### Recon

- Enumerate hub HTTP routes. For each, which require auth, which require group membership, which require admin?
- Find the group membership table / config. Who's in `ceo-team`?
- Find the pairing flow. What's the handshake — signed nonce, token exchange, manual approval?
- Find the visibility enforcement. Is it client-side (client doesn't send `local`-visibility memories to hub) or server-side (hub filters on read)? If client-side only, that's a significant trust bug.

### ACL probes

**Visibility=local:**
- Client A writes memory with `visibility=local`. Verify: memory is in A's local SQLite; NOT in the hub's DB at all.
- Client B (same group) queries the hub — memory absent. ✓
- If it's on the hub but filtered, that's a leak. Verify with direct SQL if possible.

**Visibility=group:**
- Client A writes with `visibility=group`. Memory lands on hub.
- Client B (same group, `ceo-team`) queries — sees it with correct score. ✓
- Client C (different group, set this up) queries — absent. ✓
- Unauthenticated client — absent. ✓

**Visibility=public:**
- Client A writes with `visibility=public`. Hub stores it.
- Client C (different group) queries — present.
- Unauthenticated — depends on design; document what it is.

**Cross-group contamination:**
- Set up a second group (e.g. `dev-team`). Place Client D in it. Verify D cannot see `ceo-team`'s group-visibility memories.

### Pairing flow

**New client onboarding:**
- Instantiate a new test client (could be a minimal script that speaks the hub protocol, or a spare profile).
- Before pairing, attempt a search. Denied? With what error code / message?
- Execute the pairing handshake. What does it require (human approval in the viewer? a secret handshake? nothing)?
- After pairing, search again — works?

**Pairing security:**
- Can you pair without knowing the `authSecret`? If yes, it's a major auth bug.
- Can you self-pair into an arbitrary group by declaring it in the request? Or does the hub only assign groups server-side?

**Revocation:**
- Remove a client from a group. Immediately attempt a query — denied, or only denied on next session?
- Is there an active-sessions concept that needs to be invalidated?

### Cross-agent search

**Relevance ranking:**
- Client A writes 10 memories on topic X with varying specificity. Client B queries topic X. Are results ranked by relevance alone, or does "same-client bonus" bump B's own memories?
- If there's a bonus, document it. If not, verify B gets A's memories in the top-k.

**Metadata preservation:**
- When B sees A's memory via hub, is the author (A) visible? Timestamps? All fields?

**Skill visibility:**
- Client A generates a skill with `visibility=group`. Verify it appears in B's skill discovery.
- Client A generates a `visibility=local` skill. Verify it does NOT leak to B.
- Client A generates a `visibility=public` skill. Does it show up to C (different group)?

**Skill download:**
- Does B actually download the skill content, or just an index entry? How is the content retrieved?

### Offline behavior

**Client offline while writing:**
- Block egress from Client A to hub (firewall rule or stopping the hub). A continues to write memories locally.
- Verify they land in A's local SQLite.
- Verify A can still search locally — local-only memories + previously-synced ones.

**Hub restore:**
- Restore hub connectivity. Does A automatically re-sync pending memories?
- Are ordering / timestamps preserved?
- Any duplicates?

**Hub offline but client was online earlier:**
- Stop hub. Client B queries. Can B still search its own local memories + cached group memories, or does the whole search stack break?

**Partition rejoin:**
- Client A offline for a long period, accumulates 100 memories. Reconnect. Does the sync catch up cleanly? Does it block A during catch-up, or run in background?

### Concurrency

**Same-memory race:**
- Two clients (A, B) both write the exact same content with `visibility=group` at nearly the same time. Does the hub dedup? One copy or two? Which author is recorded?

**Group-membership changes mid-write:**
- Client A is writing a stream of memories. Mid-stream, remove A from the group. Do the already-queued writes land? Future writes refused?

### Viewer dashboard (port 18901)

- Can an operator see all groups and members?
- Can an operator see per-client memory counts?
- Can an operator force-rebalance / re-sync a client?
- Can an operator edit ACL from the UI?

### Reporting

| Area | Score 1-10 | Key finding |
|------|-----------|-------------|
| Visibility=local enforcement | | |
| Visibility=group enforcement | | |
| Visibility=public behavior | | |
| Cross-group isolation | | |
| Pairing flow | | |
| Pairing security | | |
| Revocation | | |
| Cross-agent relevance | | |
| Cross-agent metadata | | |
| Skill visibility | | |
| Skill download | | |
| Offline write persistence | | |
| Reconnect sync | | |
| Hub-offline search | | |
| Partition-rejoin catch-up | | |
| Concurrent-write dedup | | |
| Membership-change atomicity | | |
| Viewer ACL UX | | |

**Overall hub-sharing score = MIN of above.**

Paragraph summary: is the multi-client model safe to run with real data across multiple agents (possibly with different trust levels)?

### Out of bounds

Do not read `/tmp/`, `CLAUDE.md`, other audit reports, plan files, or existing test scripts.
