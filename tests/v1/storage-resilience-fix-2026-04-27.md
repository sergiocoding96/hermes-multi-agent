# Storage resilience fix — 2026-04-27

This document is the Hermes-side handoff for the fix that lives in the
**MemOS** repo on branch `fix/v1-storage-resilience`
(<https://github.com/sergiocoding96/MemOS/tree/fix/v1-storage-resilience>).
The actual code changes do not live in the Hermes repo.

## Summary (5 lines)

1. Bug 4: `Neo4jCommunityGraphDB.delete_node_by_prams` now cascades to
   `vec_db.delete()`, eliminating Qdrant orphans.
2. Bug 2: New typed `DependencyUnavailable` exceptions + API handler →
   the sync write path returns **HTTP 503** (with the failing dep name)
   instead of HTTP 200 with a silently-lost extraction.
3. Bug 2: `qdrant.py` gets bounded timeout + bounded exponential retry;
   `neo4j.py` gets `connection_timeout` + `max_transaction_retry_time`.
4. Bug 2: New SQLite-backed `RetryQueue` (1→60s exp backoff, max 10
   attempts, dead-letter table) wired into the scheduler dispatcher to
   replace fire-and-forget on dependency-class failures.
5. Bug 2: `/health` now actually probes Qdrant + Neo4j (returns 503 on
   any required dep down); new `/health/deps` gives per-dep latency.

## Reproducer commands

### Bug 4 — orphan Qdrant points after delete

```bash
# Pre-fix: this assertion FAILS (orphan vector remains)
# Post-fix: this assertion PASSES (vector removed alongside Neo4j node)

mid=$(curl -sS -X POST http://localhost:8001/product/add \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "{\"user_id\":\"u\",\"writable_cube_ids\":[\"c\"],\"messages\":[{\"role\":\"user\",\"content\":\"Bug-4 test\"}],\"async_mode\":\"sync\",\"mode\":\"fast\"}" \
  | jq -r '.data[0].memory_id')

curl -sS -X DELETE http://localhost:8001/product/delete_memory \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "{\"writable_cube_ids\":[\"c\"],\"memory_ids\":[\"$mid\"]}"

# Probe Qdrant directly (replace COLLECTION with the cube's collection name)
curl -sS http://localhost:6333/collections/COLLECTION/points/$mid | jq .
# Pre-fix: returns the point
# Post-fix: returns "Not found"
```

### Bug 2 — sync write returns 503 on dep down (was: silent 200)

```bash
docker stop qdrant
HTTP=$(curl -s -o /tmp/b -w '%{http_code}' \
  -X POST http://localhost:8001/product/add \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"user_id":"u","writable_cube_ids":["c"],"messages":[{"role":"user","content":"503 test"}],"async_mode":"sync","mode":"fast"}')
echo "HTTP=$HTTP body=$(cat /tmp/b)"
# Pre-fix:  HTTP=200  body=<silently-lost extraction>
# Post-fix: HTTP=503  body={"code":503,"dependency":"qdrant",...}
docker start qdrant
```

### Bug 2 — `/health` actually probes (was: lying 200)

```bash
docker stop qdrant
curl -sS -w "\nHTTP=%{http_code}\n" http://localhost:8001/health
# Pre-fix:  HTTP=200 body={"status":"healthy",...}    (LIE)
# Post-fix: HTTP=503 body={"status":"degraded","failing_dependencies":["qdrant"],...}
docker start qdrant
```

### Bug 2 — durable retry → dead letter

```bash
# 1. Submit one async write
curl -sS -X POST http://localhost:8001/product/add \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"user_id":"u","writable_cube_ids":["c"],"messages":[{"role":"user","content":"dl test"}],"async_mode":"async","mode":"fast"}'

# 2. Stop Qdrant for the full retry window (10 attempts × backoff ≈ 363s)
docker stop qdrant
sleep 600

# 3. Inspect dead letter
sqlite3 ~/.hermes/state/retry_queue.sqlite \
  "SELECT id, label, attempts, substr(last_error,1,80) FROM dead_letter ORDER BY dead_at DESC LIMIT 3"
# Pre-fix:  table does not exist; the extraction was silently dropped
# Post-fix: dead_letter row with attempts=10 and the qdrant connection error

docker start qdrant
```

## Files added (in MemOS repo)

```
src/memos/storage/__init__.py
src/memos/storage/exceptions.py             — DependencyUnavailable hierarchy
src/memos/storage/retry_queue.py            — SQLite durable queue + worker
src/memos/storage/dependency_health.py      — per-dep probes for /health
tests/storage/__init__.py
tests/storage/test_api_503_surface.py
tests/storage/test_dependency_health.py
tests/storage/test_dispatcher_retry_enqueue.py
tests/storage/test_exceptions_classifier.py
tests/storage/test_retry_queue.py
tests/storage/integration_README.md
tests/storage/integration_qdrant_outage.sh
tests/storage/integration_neo4j_outage.sh
tests/storage/integration_dead_letter.sh
tests/storage/integration_health_deps.sh
tests/vec_dbs/test_qdrant_retry.py
tests/graph_dbs/test_neo4j_community_delete_cascade.py   (Bug 4 regression)
```

## Files modified (in MemOS repo)

```
src/memos/api/exceptions.py                 — 503 handler + neo4j classifier
src/memos/api/server_api.py                 — real /health + /health/deps
src/memos/graph_dbs/neo4j.py                — driver timeouts
src/memos/graph_dbs/neo4j_community.py      — Bug 4 vec_db cascade
src/memos/mem_scheduler/task_schedule_modules/dispatcher.py
                                            — enqueue on dep-class failure
src/memos/vec_dbs/qdrant.py                 — timeout + retry + 503 plumbing
```

## Test commands + sample green output

### Unit tests

```bash
cd ~/Coding/MemOS
PYTHONPATH=src pytest \
  tests/storage \
  tests/vec_dbs/test_qdrant_retry.py \
  tests/graph_dbs/test_neo4j_community_delete_cascade.py -v
```

Sample output (57 tests, all green):

```
tests/storage/test_api_503_surface.py::TestApi503::test_qdrant_unavailable_returns_503_with_dep_name PASSED
tests/storage/test_api_503_surface.py::TestApi503::test_neo4j_unavailable_returns_503 PASSED
tests/storage/test_api_503_surface.py::TestApi503::test_raw_neo4j_service_unavailable_classified_to_503 PASSED
tests/storage/test_dependency_health.py::TestDependencyHealth::test_required_failure_marks_overall_red PASSED
tests/storage/test_dispatcher_retry_enqueue.py::TestEnqueueOnFailure::test_dep_failure_enqueues PASSED
tests/storage/test_dispatcher_retry_enqueue.py::TestEnqueueOnFailure::test_programming_error_does_not_enqueue PASSED
tests/storage/test_retry_queue.py::TestRetrySemantics::test_max_attempts_moves_to_dead_letter PASSED
tests/storage/test_retry_queue.py::TestPersistence::test_pending_survives_process_restart PASSED
tests/storage/test_retry_queue.py::TestPersistence::test_dead_letter_survives_process_restart PASSED
tests/storage/test_retry_queue.py::TestRequeueDeadLetter::test_requeue_brings_row_back PASSED
tests/vec_dbs/test_qdrant_retry.py::TestWithRetry::test_raises_qdrant_unavailable_after_max_attempts PASSED
tests/graph_dbs/test_neo4j_community_delete_cascade.py::TestDeleteNodeByPramsVecDbCascade::test_delete_by_memory_ids_cascades_to_vec_db PASSED
... (57 total)
======================= 57 passed, 2 warnings in 12.71s =======================
```

I also confirmed Bug 4 tests fail without the fix:

```
tests/graph_dbs/test_neo4j_community_delete_cascade.py::TestDeleteNodeByPramsVecDbCascade
FAILED test_delete_by_memory_ids_cascades_to_vec_db
FAILED test_delete_by_filter_cascades_resolved_ids
FAILED test_no_vec_db_call_when_nothing_matched
FAILED test_vec_db_failure_does_not_break_neo4j_delete
=================== 4 failed, 1 passed ===================
```

### Integration tests

Operator-run; require live Qdrant + Neo4j containers and a valid agent
key. See `tests/storage/integration_README.md` in the MemOS repo. Each
script prints a final `PASS` / `FAIL` line.

```bash
export MEMOS_AGENT_KEY=...
bash tests/storage/integration_qdrant_outage.sh   # ~30s
bash tests/storage/integration_neo4j_outage.sh    # ~60s
bash tests/storage/integration_health_deps.sh     # ~30s
bash tests/storage/integration_dead_letter.sh     # ~10 minutes
```

## Deferred / out of scope

Per `TASK.md`:

- Process supervisor (Resilience report Item 7) — defer to post-MVP.
- Config-malformed handling — defer.
- FD exhaustion — defer.
- Replacing the scheduler entirely — kept the retry queue as a hook on
  the existing failure path so the change is reviewable. The scheduler
  retry-side handler (rehydrating mem_cube + re-running the original
  handler) is left for the operator to wire via
  `dispatcher.start_retry_worker(handler)`. The infrastructure (durable
  queue, enqueue on dep-class failure, dead-letter, /health/deps) is in
  place; the only missing piece is the mem_cube resolver, which depends
  on which scheduler instance owns the mem_cube registry — best decided
  in the Sprint 2 V2 wiring.

## Branch / PR map

- **MemOS branch (code):** `fix/v1-storage-resilience`
  → <https://github.com/sergiocoding96/MemOS/tree/fix/v1-storage-resilience>
- **MemOS commits:**
  - `aaf22a6` — Bug 4: `delete_node_by_prams` → vec_db cascade
  - `0aa839d` — Bug 2: 503 + retry queue + /health
- **Hermes branch (this docs PR):** `fix/v1-storage-resilience`
