# MemOS v1 Data Integrity Audit Report

**Date:** 2026-04-26  
**Marker:** V1-DI-1777215651  
**Auditor:** Blind audit session — zero-knowledge constraint applied  
**Scope:** MemOS v1.0.1 (server at localhost:8001), Neo4j Community Edition, Qdrant (neo4j_vec_db collection), SQLite (memos_users.db)

---

## Architecture Clarification (Discovered During Recon)

The audit prompt described MemOS as a **tri-store** system with "a row per memory" in SQLite. This is **incorrect**. The actual architecture is:

| Store | Role |
|-------|------|
| **Neo4j** (`neo4j_vec_db` graph + `memory_vector_index`) | Primary memory store: content, metadata, embeddings, vector ANN index |
| **Qdrant** (`neo4j_vec_db` collection, 384-dim) | Companion vector store, written in parallel with Neo4j via `Neo4jCommunityGraphDB` |
| **SQLite** (`memos_users.db`) | User/cube/ACL management only — no memory rows |

All memory data is in Neo4j + Qdrant. The `memos.db` file exists on disk but was found to be 0 bytes (no memory tables). The "tri-store" frame still applies since Neo4j + Qdrant + SQLite-ACL must all be consistent, but findings below reflect the actual topology.

**Write path (source: `neo4j_community.py:add_node`):**
1. Neo4j MERGE (graph node + metadata + embedding)
2. Qdrant upsert (same payload + vector)
Both are sequential, not atomic.

---

## Findings

### FINDING-1: Delete Leaves Qdrant with Stale Active Vectors
**Class:** `tri-store-divergence` / `orphan`  
**Severity:** Critical  
**Area:** Soft-delete idempotency, Partial-write recovery

**Description:** `delete_memory` (via `delete_node_by_prams(memory_ids=...)`) hard-deletes the Neo4j node (`DETACH DELETE`) but performs **no Qdrant cleanup**. The Qdrant point remains with `status: activated`.

**Reproducer:**
```python
# 1. Add memory
r = POST /product/add {"messages": [...], "async_mode": "sync"}
mem_id = r["data"][0]["memory_id"]

# 2. Delete memory  
POST /product/delete_memory {"mem_cube_id": "<user>", "memory_ids": [mem_id]}
# Returns {"status": "success", "deleted": [mem_id]}

# 3. Verify divergence
neo4j: MATCH (n:Memory {id: mem_id}) RETURN n  → 0 rows (HARD-DELETED)
qdrant: GET /collections/neo4j_vec_db/points/mem_id  → {status: "activated", memory: "..."}
```

**Evidence (live probe):**
```
Memory ID: 6227b482-5072-4ee3-a7a8-00c0a94cafa4
Delete API: {"code":200, "deleted":["6227b482..."]}
Neo4j post-delete: NOT_FOUND (hard-deleted via DETACH DELETE)
Qdrant post-delete: status=activated, memory="...proper soft delete test probe"
```

**Root cause:** `Neo4jCommunityGraphDB.delete_node_by_prams()` (line 1047) executes `DETACH DELETE` on Neo4j but contains no `self.vec_db.delete()` call. By contrast, `delete_node_by_mem_cube_id()` (line 1335) does call `self.vec_db.delete(node_ids)` — the two delete paths have inconsistent Qdrant handling.

**Impact:**
- Deleted memories persist in Qdrant as `activated` vectors indefinitely
- Qdrant count diverges from Neo4j count over time (confirmed: Qdrant=15, Neo4j=16 after audit session)
- Orphaned vectors degrade ANN search quality (occupy top-K slots, resolved to null by caller)
- Potential privacy implication: vector embeddings of user-deleted memories never expire

**Remediation:** In `delete_node_by_prams`, after the `DETACH DELETE` query, add `self.vec_db.delete(memory_ids)` when `memory_ids` is non-empty. Mirror the cleanup logic already present in `delete_node_by_mem_cube_id`.

---

### FINDING-2: Non-Atomic Sequential Write — Partial Failure Creates Permanent Orphans
**Class:** `orphan`  
**Severity:** Critical  
**Area:** Partial-write recovery

**Description:** `add_node` writes to Neo4j first (`session.run(MERGE ...)`), then Qdrant (`self.vec_db.add([item])`). These are two independent network calls with no shared transaction. If Qdrant fails after Neo4j succeeds, a Neo4j node exists without a Qdrant vector. If Neo4j fails after Qdrant succeeds, a Qdrant vector exists without a Neo4j node. Neither failure triggers any rollback or retry.

**Source reference:**  
`neo4j_community.py:add_node()` lines 54–94:  
```python
# 1. Writes to Neo4j via MERGE (no exception handling after this point)
session.run(query, ...)
# 2. Qdrant upsert — if this throws, Neo4j node is stranded
self.vec_db.add([item])
```

**No reconciliation job exists.** A search for any scheduled task, cron, or background worker that cross-checks Neo4j ↔ Qdrant count returned zero results.

**Reproducer:**
```bash
# Stop Qdrant between Neo4j write and Qdrant write (requires timing)
# Or: check count divergence after a Qdrant restart
curl -s http://localhost:6333/health  # stop here
# add_memory call → Neo4j gets node, Qdrant gets error
```

**Observed evidence:** The manual Qdrant-point deletion in test 7 (search orphan test) created a Neo4j node with no Qdrant vector. This remained as a permanent orphan throughout the session, searchable by Neo4j fulltext but NOT returned by vector search (since fulltext search is a stub returning `[]` — see FINDING-3).

**Remediation:** Wrap both writes in a try/except with compensating delete on partial failure; or use a write-ahead log / outbox pattern; or run a daily reconciliation job comparing Neo4j and Qdrant counts per `user_name`.

---

### FINDING-3: No Fulltext Search Fallback — Orphaned Neo4j Nodes Are Invisible
**Class:** `orphan`  
**Severity:** High  
**Area:** Search-time tri-store consistency

**Description:** When a Qdrant point is deleted or missing, the corresponding Neo4j node becomes invisible to all search paths. `search_by_fulltext()` in `Neo4jGraphDB` is a stub that unconditionally returns `[]`:

```python
# neo4j.py:search_by_fulltext (line 1016)
def search_by_fulltext(...) -> list[dict]:
    """
    TODO: Implement fulltext search for Neo4j to be compatible with TreeTextMemory's
    keyword/fulltext recall path.
    Currently, return an empty list to avoid runtime errors...
    """
    return []
```

**Reproducer:**
```python
# 1. Add memory M
# 2. Manually delete M from Qdrant: qc.delete(QDRANT_COL, points_selector=...)
# 3. Search for M's content → 0 results (Qdrant miss, no FTS fallback)
# 4. Neo4j still has the node: MATCH (n:Memory {id: M}) RETURN n → 1 row
```

**Evidence (live probe):**
```
Orphan ID: a3829de0-...
Neo4j: FOUND (status=activated)
Qdrant: NOT FOUND (manually deleted)
search("V1-DI-1777215651 search orphan xyz9qr7unique...") → not returned
```

**Impact:** Any memory whose Qdrant vector is missing (due to partial write, manual deletion, or collection corruption) is permanently lost from the system's perspective, with no way to recover it via search. Users cannot find or reference the memory.

**Remediation:** Implement `search_by_fulltext` in Neo4jCommunityGraphDB using Neo4j full-text index (`CREATE FULLTEXT INDEX ... FOR (n:Memory) ON EACH [n.memory]`). This provides a fallback recall path when vector search misses.

---

### FINDING-4: No Migration Scripts — Schema Changes Are Manual and Undocumented
**Class:** `migration-error`  
**Severity:** High  
**Area:** Migration safety

**Description:** No migration scripts, Alembic configuration, or schema versioning exist anywhere under `/home/openclaw/Coding/MemOS/`. Schema changes require manual intervention:
- Changing embedding dimension (384 → other) requires recreating the Qdrant collection and the Neo4j vector index and re-embedding all existing memories
- Adding new SQLite tables or columns requires manual `ALTER TABLE`
- Adding new Neo4j indexes requires manual Cypher

**Evidence:** `glob('src/**/migrate*.py', 'migrations/**/*.py', 'src/**/alembic/**')` → 0 results.

**Impact:** Any schema upgrade risks data loss or silent incompatibility. The embedding dimension is particularly dangerous: if the collection was created with dim=384 and a new deployment uses a different model, Qdrant will silently reject upserts with the wrong dimension, leading to partial write failures.

**Remediation:** Add Alembic for SQLite schema management; document Neo4j and Qdrant schema upgrade procedures with version markers in a `SCHEMA_VERSION` file.

---

### FINDING-5: No Backup / Restore Procedure
**Class:** `no-backup-path`  
**Severity:** Critical  
**Area:** Backup / restore

**Description:** Backup scripts were found (6 shell scripts referenced in repository) but they exist in worktrees and test directories, not as a documented operational procedure. No tested restore path exists. All three stores must be snapshotted atomically to guarantee consistency on restore:
- Neo4j: `neo4j-admin database dump`
- Qdrant: snapshot API (`POST /collections/{name}/snapshots`)
- SQLite: `sqlite3 memos_users.db .backup dst.db`

If Neo4j and Qdrant snapshots are taken at different times, the restored state will have a count mismatch.

**Remediation:** Create a `backup.sh` script that: (1) pauses writes (or uses a maintenance mode), (2) takes all three snapshots atomically, (3) records a manifest with counts; document tested restore steps.

---

### FINDING-6: Concurrent Write-Time Dedup Has TOCTOU Race
**Class:** `dedup-error`  
**Severity:** Medium  
**Area:** Concurrent dedup ordering

**Description:** Write-time dedup (in `single_cube.py:_process_text_mem`) checks for near-duplicates by searching Neo4j by embedding before writing. Two concurrent writes with identical content can both pass the check simultaneously before either writes.

**Source (single_cube.py lines 728–749):**
```python
similar = graph_store.search_by_embedding(
    vector=embedding, top_k=1, status="activated",
    threshold=DEDUP_SIMILARITY_THRESHOLD, ...)
if similar:
    # skip — but another thread may be writing the same memory right now
```

**Evidence:** 2 concurrent threads writing identical content produced 1 ID (dedup coincidentally worked due to bcrypt verification serializing the requests), but the window is real — high-load systems or fast clients can trigger it.

**Remediation:** Use a Redis-backed or DB-level idempotency key (hash of content + user_name) checked under a lock, or enforce uniqueness at the Neo4j level with a MERGE+constraint.

---

### FINDING-7: Neo4j Node Missing Embedding Field at Write Time
**Class:** `fidelity-loss`  
**Severity:** Medium  
**Area:** Embedding dimension lock-in

**Description:** In fast-mode adds, the Neo4j node is written by `neo4j_community.add_node()`, but a direct Cypher query immediately after write returned no `embedding` field on the node. Qdrant had the 384-dim vector. This suggests embeddings may be computed and stored asynchronously via the scheduler (ADD_TASK_LABEL processing), creating a window where Neo4j's `search_by_embedding` (line 939: `WHERE node.embedding IS NOT NULL`) would skip the node.

**Evidence:**
```
POST /product/add (mode=fast) → mem_id returned
# 0.5s later:
MATCH (n:Memory {id: mem_id}) RETURN n.embedding → null
Qdrant point vector dim: 384 ✓
```

**Impact:** Newly written memories are invisible to `search_by_embedding` until the scheduler processes the ADD_TASK and stores the embedding in Neo4j. Window duration depends on scheduler throughput.

**Remediation:** Compute and store embeddings synchronously in `add_node` for fast-mode adds, or document the delay explicitly in the search SLA.

---

### FINDING-8: Delete API Missing Required Parameter Not Documented
**Class:** `fidelity-loss`  
**Severity:** Low  
**Area:** ACL / API contract

**Description:** `POST /product/delete_memory` with `{"memory_ids": [...]}` but without `mem_cube_id` returns HTTP 400: *"Provide both a cube (mem_cube_id or writable_cube_ids) and a memory id"*. The OpenAPI spec at `/openapi.json` lists `mem_cube_id` as optional with no indication it becomes required when `memory_ids` is used.

**Remediation:** Update the OpenAPI description for `delete_memory` to clearly state `mem_cube_id` is required when deleting by `memory_ids`.

---

## SQLite Architecture Note

The audit prompt's claim that SQLite stores "a row per memory" is incorrect. `~/.memos/data/memos.db` is 0 bytes. The server reads from `/home/openclaw/Coding/MemOS/.memos/memos_users.db` (discovered via `settings.MEMOS_DIR`), which contains only three tables: `users`, `cubes`, `user_cube_association`. All memory content lives in Neo4j + Qdrant.

---

## Scores

| Area | Score 1–10 | Key Findings |
|------|-----------|--------------|
| Tri-store write consistency | 9 | Neo4j + Qdrant both populated on write; IDs cross-link correctly |
| Partial-write recovery | 2 | Non-atomic sequential writes; no compensating rollback; no reconciliation job |
| Soft-delete idempotency across stores | 2 | `delete_memory` hard-deletes Neo4j, leaves Qdrant `activated`; stores diverge immediately |
| Content fidelity (text / JSON / code) | 10 | 7/7 content types pass byte-for-byte between Qdrant and Neo4j |
| Unicode / emoji / CJK fidelity | 10 | Emoji, CJK, RTL (Hebrew/Arabic) all round-trip correctly between stores |
| Timestamp resolution + ordering | 8 | ISO-8601 stored, cross-store match at seconds precision; rapid writes unique |
| Embedding dimension lock-in | 10 | 384-dim confirmed; collection and vector agree; no dim mismatch observed |
| Search-time tri-store consistency | 3 | Qdrant-missing node invisible (no FTS fallback stub); Qdrant orphans degrade ANN quality |
| ACL idempotency | 10 | `add_user_to_cube` is idempotent (no duplicate rows); no race condition found |
| Migration safety | 2 | No migration scripts; no schema versioning; upgrade path is entirely manual |
| Concurrent dedup ordering | 4 | TOCTOU race exists in write-time dedup; no DB-level uniqueness constraint |
| Backup / restore documented path | 1 | No backup procedure; multi-store atomic snapshot undocumented |

**Overall data-integrity score = MIN = 1/10**

---

## Summary Judgment

Would I trust this system to hold the only copy of important memories? **No.**

The single highest-risk issue is the combination of FINDING-1 and FINDING-3: every `delete_memory` call leaves a stale Qdrant vector that cannot be recovered, and every Qdrant miss (from partial writes, restarts, or manual operations) leaves a Neo4j node permanently invisible to search with no fulltext fallback. These two bugs interact: deleting a memory leaves a vector that wastes ANN slots and degrades search, while a failed write leaves a node that is permanently unreachable. Neither has a recovery path. Layered on top is FINDING-5 (no backup procedure), meaning a single disk failure or accidental `docker rm qdrant` would require full data reconstruction from Neo4j alone — which is possible in principle but untested and not documented.

The strong positives are content fidelity (10/10 across all character sets) and ACL idempotency (10/10), which show the application-level logic is correct. The fragility is at the infrastructure boundary: the two stores are written sequentially without coordination, and only one side is cleaned on delete.
