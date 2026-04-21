# Hermes v2 Data Integrity Blind Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

Local memory plugin `@memtensor/memos-local-hermes-plugin`. Local SQLite at `~/.hermes/memos-state-<profile>/memos-local/memos.db` (WAL-mode, tables include capture rows, embeddings, task summaries, skills). Hub HTTP on `http://localhost:18992`. Skills on disk at `~/Coding/badass-skills/auto/`. Plugin source `~/.hermes/memos-plugin-<profile>/`.

Your job: **Find every way data can be inconsistent, lost, corrupted, or misrepresented across the layers (local DB, hub index, filesystem, embeddings, timestamps).** Score integrity 1-10 with evidence.

Use marker `INTEG-AUDIT-<timestamp>`. Create your own test data.

### Recon

- Inspect the SQLite schema: tables, FK relationships, indexes, triggers.
- Find the code path that writes to both local DB and hub. Is it transactional across layers? What happens if one fails?
- Find the skill-file writer. Does it `fsync` before returning? Does it atomically rename (tmp → final)?
- Find the timestamp source. `Date.now()` on each client? Server-side NTP? Hub-assigned?

### Integrity probes

**Local DB ↔ hub consistency:**
- Write a memory on client A with visibility=group. Inspect the local row in `memos.db`. Query the hub for the same row. Are all fields identical (content, embedding, metadata, timestamp)?
- Repeat: write 100 in rapid succession. Any that landed locally but NOT on the hub? Any hub-only (impossible but verify)? Any field mismatch?
- What if the hub is down mid-write? Write locally with hub dead, revive hub. Does a queued sync catch up? Is the sync ordered?

**Skill file ↔ index consistency:**
- Generate a skill on client A. Verify: (a) file at `~/Coding/badass-skills/auto/<skill>.md`, (b) SQLite row referencing it, (c) hub's skill listing if applicable. All three agree on name, content, version?
- Manually edit the on-disk skill file (change one word). Re-run search. Does the plugin detect drift? Does it re-embed?
- Delete the on-disk file (keeping the DB row). What does the plugin do on next search?

**Task summary ↔ underlying chunks:**
- Create a conversation with 10 specific factual claims (numbers, dates, URLs). Let the plugin summarize the task. Check each claim against the summary — any hallucinated? Any dropped?
- Which underlying chunk rows are referenced by the summary row (FK)? Are all claim-bearing chunks linked?

**Dedup merge correctness:**
- Write two near-duplicate memories that differ in one important detail (e.g. `"Alice is 25"` vs `"Alice is 30"`). Dedup likely merges them. Does the merged row preserve BOTH ages or lose one?
- If the merge is a hard overwrite, document it. If it's a "keep newer," document it. If it creates a diff / history, document it.

**Embedding drift:**
- Write 100 memories today. Note their embeddings.
- Simulate an embedder version upgrade (edit the plugin's embedder config to a different model, or force re-embed). Re-embed the 100.
- Compare old vs new embeddings. Are results stable under the switch, or does relevance shuffle drastically?

**Soft-delete propagation:**
- Mark a memory as inactive / deleted via the plugin API. Verify it's excluded from: local search, hub search, task-summary references, skill-evolution input.
- Any dangling FK? Any orphan row?

**Clock skew handling:**
- If client and hub clocks diverge (e.g. client clock 1h ahead), does a memory's timestamp come from client or hub? Does it affect ordering / recency-decay?
- Write a memory with a future timestamp (hack the client clock forward). Does the plugin accept it? Does search return it?

**Content-fidelity round-trip:**
Write content containing:
- Numbers with many decimals (`3.141592653589793`)
- Large ints (`9007199254740993` — beyond JS safe int)
- Unicode: emoji 🔥, Chinese 中文, RTL Arabic العربية
- URLs with query strings and fragments
- Code blocks with triple backticks
- JSON blobs with escaped quotes
- Markdown tables with pipes
- Null bytes (`\x00`), control characters
- Extremely long lines (10k chars no newline)
- Newlines: `\n`, `\r\n`, `\r`, no trailing newline

For each, verify exact byte-for-byte survival through capture → search retrieval. Log anything that changes.

**Orphan & referential integrity:**
- Delete a row in the main table that has FK references in the embeddings table. Does SQLite enforce cascade? If not, does the plugin detect and repair?
- Corrupt the embeddings blob column for one row. Does search crash or skip gracefully?

**Concurrent edits:**
- Two clients (same group) both UPDATE the same memory. What wins — last-writer? Merge? Reject? Does the plugin have optimistic concurrency (version field)?

**Backup / restore:**
- `sqlite3 memos.db '.dump' > backup.sql`. Wipe the DB. Restore from backup. Any rows lost? Any schema mismatch?
- Is there a documented export/import path? Test it end-to-end.

### Reporting

For each probe:

- Test description
- Expected behavior (based on source / docs)
- Actual behavior (DB state, field values, diff)
- Integrity class: consistency / fidelity / durability / ordering / isolation
- Score 1-10

Summary table:

| Area | Score 1-10 | Key finding |
|------|-----------|-------------|
| Local-hub consistency | | |
| Skill file-index consistency | | |
| Summary-chunk fidelity | | |
| Dedup merge correctness | | |
| Embedding drift | | |
| Soft-delete propagation | | |
| Clock skew handling | | |
| Content fidelity | | |
| Orphan / FK integrity | | |
| Concurrent edit semantics | | |
| Backup / restore | | |

**Overall integrity score = MIN of above.**

### Out of bounds

Do not read `/tmp/`, `CLAUDE.md`, other audit reports, plan files, or existing test scripts.
