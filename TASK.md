# Worktree A — Storage write path & delete consistency

> **Repo:** all edits in this worktree happen in the **MemOS repo** at `/home/openclaw/Coding/MemOS`, NOT the Hermes repo. The audit identified file paths like `src/memos/multi_mem_cube/...` and `src/memos/graph_dbs/neo4j.py` — those live only in MemOS. The Hermes worktree at `~/Coding/Hermes-wt/fix-storage` exists as a project-management artifact pointing at this brief; do your code work in a fresh MemOS worktree.
>
> **Setup before any code:**
> ```bash
> cd /home/openclaw/Coding/MemOS
> git fetch origin
> git worktree add ~/Coding/MemOS-wt/fix-storage -b fix/v1-storage-resilience origin/main
> cd ~/Coding/MemOS-wt/fix-storage
> ```
> Push to and PR against the **MemOS repo's `main`**, not Hermes.

You are fixing **two bugs in the v1 MemOS server's storage layer**. Both came out of the 2026-04-26 blind audit (Resilience and Data Integrity reports).

## Bug 4 (start here — small, 2 hours)

`Neo4jCommunityGraphDB.delete_node_by_prams()` at roughly `src/memos/graph_dbs/neo4j.py:1047` runs `DETACH DELETE` on Neo4j but never calls `self.vec_db.delete()`. The sibling function `delete_node_by_mem_cube_id()` at roughly line 1335 already does the right thing — mirror it.

**Reproducer (must fail before fix, pass after):**

```python
# Store, delete, then assert Qdrant point is gone
mid = memos.store({"content": "Bug-4 test memory"})
memos.delete(memory_ids=[mid])
# Direct Qdrant probe:
qdrant.client.retrieve(collection_name=cube_collection, ids=[mid]) == []  # currently False, must become True
```

**Fix:** in `delete_node_by_prams`, after the `DETACH DELETE` query, add `self.vec_db.delete(memory_ids)` when `memory_ids` is non-empty. Match the parameter handling that `delete_node_by_mem_cube_id` uses for empty/None inputs.

**Tests:** add a unit test (or regression test) that proves the round-trip; if no test exists for the existing `delete_node_by_mem_cube_id` either, write the missing pair.

---

## Bug 2 (the heavy one — 2–3 days)

When **Qdrant or Neo4j is briefly unreachable during a write**, the API returns HTTP 200 to the caller while the structured memory extraction is silently dropped by the async scheduler. Quote from the resilience audit:

> If DeepSeek fails or times out, the scheduler task is marked `"failed"` via `status_tracker.task_failed()`. The caller-visible response was already 200. The extraction result (structured memories, tags, graph edges) is silently lost. No fallback to fast/raw mode. No retry. No dead-letter queue.

Same pattern observed for Qdrant outage and Neo4j outage. `vec_dbs/qdrant.py` and `graph_dbs/neo4j.py` have **no retry, no timeout, no circuit breaker.**

**Required behaviour after the fix:**

1. **Synchronous write path** — if Qdrant or Neo4j is unreachable when the request arrives, return **HTTP 503** with a body that names which dependency is down. Do NOT return 200 with a silently-lost extraction.
2. **Async write path** — replace the fire-and-forget scheduler task with an **at-least-once durable retry queue**. SQLite-backed is fine (the database is already a hard dependency). Failed extractions retry with exponential backoff (initial 1s, max 60s, give up after ~10 attempts and write to a dead-letter table).
3. **`/health/deps` endpoint** — new route that probes Qdrant + Neo4j + LLM provider and returns per-dependency status. The existing `/health` already lies (returns OK when Qdrant 401s) — fix that too: `/health` should fail when any required dep is unreachable.
4. **Logging** — every retry attempt logs at INFO with `(memory_id, attempt_n, last_error)`. Final dead-letter entries log at WARN. No silent drops.

**Files in scope:**

- `src/memos/multi_mem_cube/single_cube.py` — write path
- `src/memos/vec_dbs/qdrant.py` — add retry/timeout, surface unreachability
- `src/memos/graph_dbs/neo4j.py` — same as Qdrant
- `src/memos/mem_scheduler/**` — durable queue + dead-letter
- `src/memos/api/server_api.py` — `/health` accuracy + new `/health/deps` route
- New file likely: `src/memos/storage/retry_queue.py` (or wherever fits) for the durable queue

**Out of scope:** process supervisor (Resilience report Item 7), config-malformed handling, FD exhaustion. Defer to post-MVP. Don't expand scope.

**Tests:**

- Unit: simulate Qdrant `ConnectionError` on write → API returns 503.
- Integration: stop the Qdrant container, submit write, restart container within 30s → verify the memory eventually lands. Verify `/health/deps` reports the outage during the window.
- Integration: same for Neo4j.
- Integration: dead-letter — make Qdrant fail for 600s; verify the entry lands in the dead-letter table after ~10 retries; verify it does NOT silently disappear.

---

## Working rules

- **Branch:** `fix/v1-storage-resilience` (already created by the worktree setup script).
- **Do not** touch `api/middleware/agent_auth.py`, `api/middleware/rate_limit.py`, MemReader prompts, or the Hermes plugin — those belong to other worktrees.
- **Do not** read `tests/v1/reports/**` or `tests/v2/reports/**` or `memos-setup/learnings/**` or any `CLAUDE.md`. The audit findings you need are summarized in this file. (Avoiding contamination of your fix decisions.)
- Keep commits small and atomic. Commit Bug 4 separately from Bug 2.
- Use the existing testing framework; don't introduce a new one.

## Deliver

1. Push to `fix/v1-storage-resilience`.
2. Open a PR against `main` titled `fix(storage): silent data-loss recovery + delete cleanup`.
3. PR body must include: (a) a 5-line summary of the change, (b) the exact reproducer commands proving Bug 4 fixed and Bug 2 fixed, (c) a list of files added or removed, (d) the test commands and a sample of green output.
4. Do NOT merge yourself. Hand off for review.

## When you are done

Reply with: branch name, PR number, the 4 reproducer outputs (one per test scenario above), and any deferred follow-ups you noticed but explicitly did not address.
