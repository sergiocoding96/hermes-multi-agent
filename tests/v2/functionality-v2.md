# Hermes v2 Functionality Blind Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## System Under Test

- **Plugin:** `@memtensor/memos-local-hermes-plugin` (each Hermes profile)
- **Hub:** `http://localhost:18992`
- **Config:** `~/.hermes/config.yaml`, `~/.hermes/profiles/<profile>/.env`
- **Skills:** Auto-generated at `~/Coding/badass-skills/auto/`
- **Embeddings:** Local Xenova all-MiniLM-L6-v2 (384 dim)

## Your Job

**Determine whether auto-capture, search, dedup, skill evolution, and task summarization actually work.** Assume you have valid credentials. Test every claimed feature.

Do not reuse existing test data. Use unique markers: `FUNC-AUDIT-<timestamp>`.

## Probes

1. **Auto-capture on every turn:** Start a Hermes session, send a multi-turn conversation (3-5 turns). Check that each turn is captured to local SQLite. Verify schema (messages, embeddings, metadata).

2. **Capture completeness:** Ensure captured: user messages, assistant messages, tool calls, tool results. Verify that system messages are NOT captured.

3. **Semantic chunking:** Write a 1000-word essay in a single turn. Does the plugin chunk it (multiple SQLite rows) or store as one? Are splits at paragraph/code boundaries or arbitrary?

4. **Smart dedup:** Write the same fact 5 times in different messages. How many copies are stored? At what similarity threshold does dedup activate?

5. **Hybrid search (FTS5 + vector):** Write memories with specific keywords. Search for: (a) exact keyword match, (b) semantic paraphrase (no keyword overlap), (c) both. Verify hybrid fusion improves results vs. keyword-only or vector-only.

6. **MMR diversity:** Write 5 near-duplicate memories + 5 distinct ones. Search and request top-10 results. Does MMR dedup work — i.e., do you get 1-2 of the near-dupes instead of all 5?

7. **Recency decay:** On day 1, write `"fact_v1: x=5"`. On day 2, write `"fact_v2: x=10"` (same topic, contradictory value). Search for the fact. Does the newer version rank higher?

8. **Cross-profile search (hub):** Write to profile A, search from profile B using the hub. Are results correctly merged? Relevance sane?

9. **Task summarization:** Create a session with 3 clearly distinct tasks (e.g., "1) debug Python error 2) summarize doc 3) write curl"). Does the plugin detect 3 task boundaries or over/under-split?

10. **Skill evolution:** Let the plugin capture 20+ turns of varied conversations. Check `~/Coding/badass-skills/auto/` for generated SKILL.md files. Are they coherent? Generalized (not overfit)? Deduplicated across similar tasks?

11. **Long-form content:** Write 5000 words in a single turn. Is extraction complete or does quality degrade at the end?

12. **Embedding model consistency:** Verify the embeddings are reproducible (same fact written twice = same embedding).

## Report

For each area: test description, expected, actual, evidence, and 1-10 score.

Summary table with overall functionality score.
