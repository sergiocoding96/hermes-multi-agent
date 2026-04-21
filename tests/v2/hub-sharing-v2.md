# Hermes v2 Hub Sharing Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## Your Job

**Verify group visibility model, cross-agent recall, pairing flow, and offline sync.** Score sharing correctness 1-10.

Markers: `HUB-AUDIT-<timestamp>`.

## Probes

1. **Visibility levels — local:** Client A writes a memory with `visibility=local`. Can client B (same group) see it via hub? (Should be NO)

2. **Visibility levels — group:** Client A writes with `visibility=group`. Client B in the same group searches the hub. Can B see it? (Should be YES)

3. **Visibility levels — public:** Client A writes with `visibility=public`. Client C (different group or unauthenticated) searches. Can C see it? (Should be YES)

4. **Pairing flow unauthenticated:** Unauthed client attempts to search the hub. Denied? Queued for pairing?

5. **Pairing authorization:** New client initiates pairing. Does it require admin approval on client A? How is approval signaled?

6. **Allowlist enforcement:** Remove client B from the group. Attempt search from client B. Denied? (Should be YES, denied)

7. **Re-add client:** Add client B back to the group. Can it search again?

8. **Cross-agent search relevance:** Client A writes task details. Client B searches with similar keywords. Are results ranked by relevance? Cross-agent results ranked below own-agent results, or equally?

9. **Skill sharing visibility:** Client A generates a skill with `visibility=group`. Client B's skill discovery — can it see A's skill? Download?

10. **Offline client behavior:** Take client A offline. Client A writes to local SQLite. Take hub offline. Can client A still search locally? (Should be YES)

11. **Hub comes back online:** Restart hub while clients are still offline. Reconnect clients. Does sync happen? Any dupes? Ordering preserved?

12. **Group member removal + data retention:** Remove client B from the group. Does existing data written by B become inaccessible to group? Or remain queryable by B?

13. **Concurrent group writes:** Clients A and B both write to the group simultaneously. Do writes collide? Ordering? Consistency?

## Report

For each area: test, expected ACL behavior, actual, evidence (curl output, query results), and 1-10 score.

Summary: overall hub sharing and ACL correctness score.
