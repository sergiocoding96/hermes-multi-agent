# Hermes v2 Data Integrity Blind Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## Your Job

**Verify data consistency across local DB ↔ hub, and faithful preservation of content through the pipeline.** Score integrity 1-10.

Markers: `INTEG-AUDIT-<timestamp>`.

## Probes

1. **Local vs hub sync:** Write a memory locally, query the hub. Is it indexed correctly? Metadata, embeddings, timestamps match?

2. **Skill file consistency:** Generate a skill on client A. Verify `~/Coding/badass-skills/auto/<skill>.md` exists and can be read. Can client B fetch it from the hub?

3. **Task summary fidelity:** Capture a task with specific numbers, URLs, and error messages. Does the summarizer preserve them accurately?

4. **Dedup merge correctness:** Write `fact_v1` and `fact_v2` (same meaning, different wording). Dedup merges them into one row. Does the merged row retain all unique details from both?

5. **Embedding stability:** Reindex the same memory with a different embedding provider. Do results change significantly? Expected variance?

6. **Soft-delete correctness:** Mark a memory as inactive. Is it removed from local search AND hub search?

7. **Clock skew:** Timestamps across client-hub: is clock skew handled? What happens if client clock is behind?

8. **Content fidelity round-trip:** Write content with: numbers (3.14159), URLs (https://example.com?q=test&b=2), code blocks (bash, Python), unicode (中文, emoji), markdown formatting. Does it survive capture → search → retrieval?

9. **Null/empty handling:** Write null values, empty strings, very long strings (10MB). Are they handled correctly?

10. **Orphan records:** Delete a task boundary record from SQLite while keeping its memories. Can the agent still search those orphaned memories?

## Report

For each area: test, expected, actual, evidence (diffs, query results), and 1-10 score.

Summary table with overall integrity score.
