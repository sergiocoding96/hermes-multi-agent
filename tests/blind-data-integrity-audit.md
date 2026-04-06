# MemOS Data Integrity Blind Audit

Paste this into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

There is a memory storage API at `http://localhost:8001` backed by Neo4j (graph), Qdrant (vectors), and SQLite (users). Source: `/home/openclaw/.local/lib/python3.12/site-packages/memos/`. Config: `/home/openclaw/Coding/MemOS/.env`. Agent keys: `/home/openclaw/Coding/Hermes/agents-auth.json`.

Your job: **Determine whether this system preserves data correctly across all storage layers.** You are looking for data corruption, inconsistency between databases, silent data loss, and phantom data.

Create your own test users/cubes.

**Cross-layer consistency:**
- Write a memory via the API. Then query Qdrant directly (port 6333) and Neo4j directly (port 7687, default password in .env). Is the same data present in both? Same embedding dimension? Same metadata? Same cube scoping?
- Delete a memory via the API. Is it removed from both Qdrant and Neo4j? Or does one retain orphaned data?
- Is there a scenario where Qdrant has a vector but Neo4j doesn't have the node (or vice versa)? Try killing the server mid-write.

**Data fidelity:**
- Write a memory containing: exact numbers (3.14159265), dates (2026-04-06T15:30:00Z), URLs (https://example.com/path?q=1&r=2), code (`def foo(): return 42`), special characters (`<script>alert('xss')</script>`), markdown tables, JSON objects.
- Search for each and verify the extracted memory preserves the critical data. What gets lost? What gets mangled? What gets interpreted vs stored literally?

**Embedding consistency:**
- Write the same sentence twice with fine mode. Are the embeddings identical? (Query Qdrant directly to compare vectors.)
- Write two semantically similar but textually different sentences. Are their embeddings close? How close?
- Write two completely unrelated sentences. Are their embeddings distant?

**Cube scoping in databases:**
- Write memory to cube A and cube B. Query Qdrant directly for cube A's vectors. Are any of cube B's vectors returned? Is cube scoping enforced at the Qdrant collection level or by metadata filter?
- Same test in Neo4j. Are cubes separate graphs, separate labels, or just filtered by property?

**Orphan detection:**
- After running all tests, count: total vectors in Qdrant, total nodes in Neo4j, total rows in SQLite user_cube_association. Are the numbers consistent? Are there orphaned records from test users that weren't cleaned up properly?
- How does the soft-delete mechanism (is_active=False) interact with data in Qdrant and Neo4j? Are "deleted" users' memories still searchable via direct DB access?

**Temporal consistency:**
- Write a memory. Immediately search for it (within 1 second). Is it found? Or is there eventual consistency delay?
- Write with async_mode="async". Search immediately. Search after 5 seconds. When does it appear?
- Does the scheduler modify existing memories over time? Write 10 memories, note their content, wait 5 minutes, read them again. Has anything changed?

Report every inconsistency you find between the API layer and the underlying databases. Score 1-10 on data integrity.

Do not read `/tmp/`, `CLAUDE.md`, or existing test scripts.
