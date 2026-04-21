# Hermes v2 Functionality Blind Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

There is a local memory plugin (`@memtensor/memos-local-hermes-plugin`) installed per Hermes agent profile on this machine. Each profile has:

- Plugin source: `~/.hermes/memos-plugin-<profile>/` (TypeScript: `index.ts`, `bridge.cts`, `hub-launcher.cts`)
- State dir: `~/.hermes/memos-state-<profile>/`
  - Local SQLite: `memos-local/memos.db` (WAL-mode)
  - Skills store: `skills-store/` (symlinked to `~/Coding/badass-skills/auto/`)
  - Auth: `hub-auth.json` (authSecret + bootstrapAdminToken)

One profile runs the HTTP hub on `http://localhost:18992`, a bridge daemon on `http://localhost:18990`, and a viewer on `http://localhost:18901`.

Profiles: `arinze`, `email-marketing`, `mohammed`, `research-agent`.

Your job: **Determine whether auto-capture, hybrid search, dedup, MMR diversity, recency decay, skill evolution, and task summarization work correctly.** You are testing functionality, not security. Assume you have valid credentials.

### Recon

Before probing, understand the system:

- Read `~/.hermes/memos-plugin-<profile>/README.md` and the `src/` tree. What claims does the plugin make?
- Discover the hub's HTTP routes (live endpoints + source). Which routes write? Which read?
- Inspect the SQLite schema: `sqlite3 ~/.hermes/memos-state-research-agent/memos-local/memos.db '.schema'`. What tables exist? What does each column represent?
- Find where the capture pipeline is wired — what triggers it? What's the code path from an agent turn to a row in SQLite?
- Find the skill-evolution pipeline — what's the LLM prompt, what's the filter, where's the output?
- Find the summarizer — what model, what prompt, what input shape?

### Functional probes

**Auto-capture (write path):**
- Start a Hermes agent session. Send 5 turns of conversation with unique marker `FUNC-AUDIT-<ts>`. Verify exactly 5 user + 5 assistant messages land in `memos.db`.
- Does the plugin capture system messages? Tool calls? Tool results? Find each in the DB schema and confirm.
- What's the "unit" of capture — whole turn, sentence, chunk? Verify with a long multi-paragraph turn.
- Is capture synchronous (blocks the agent) or async? Measure by sending a large turn and timing the agent response.

**Semantic chunking:**
- Write one turn containing 3 paragraphs separated by blank lines. Count resulting chunks.
- Write one turn with code blocks ```` ``` ````. Are code blocks kept intact or split?
- Write 5000 words in one turn. How many chunks? Are chunk boundaries sentence-aligned?

**Smart dedup:**
- Write the exact same sentence 5 times across 5 turns. How many rows in the DB? Is there a "dedup count" field?
- Write 5 paraphrases of the same fact ("The capital of France is Paris" / "Paris is France's capital" / etc.). How many survive?
- At what cosine-similarity threshold does dedup fire? Binary-search by writing pairs of decreasing similarity.

**Hybrid search (FTS5 + vector):**
- Write memories with a rare keyword (`zplfkwrn`) + memories paraphrasing the concept but not using the word. Query with the keyword — does only the exact match return, or does vector also bubble paraphrases?
- Query with a semantic paraphrase (no keyword overlap). Does FTS5 contribute nothing and vector everything, or is there RRF fusion?
- Sanity check: for a query where both should agree, do the top-3 results overlap?

**MMR diversity:**
- Write 5 near-duplicate memories + 5 distinct-but-relevant memories on the same topic. Request top-10 via MMR. Count near-dupes in the result. MMR should return ~2 near-dupes + the distinct ones.
- Toggle MMR off (if possible) and re-query. The result should be dominated by near-dupes.

**Recency decay:**
- Write "`RECENCY-AUDIT x=5`" at time T0.
- Wait a measurable interval (1 min, 10 min, 1 hour depending on the decay constant).
- Write "`RECENCY-AUDIT x=10`" at time T1.
- Search "`RECENCY-AUDIT`". Which is ranked higher? By how much? Is there a decay constant you can tune?

**Task summarization:**
- Seed a session with 3 explicit task transitions: "Task 1: research X", "Done. Task 2: write code for Y", "Done. Task 3: summarize Z".
- After the session, inspect the task-summary table in SQLite. How many summaries? Each one's Goal / Steps / Result?
- Do a version with implicit transitions (no "Task 1:" markers). Does the boundary detector fire?

**Skill evolution:**
- Set up a corpus by running ~20 simulated tasks, each covering a distinct skill. Let the plugin run its evolution cycle.
- Inspect `~/Coding/badass-skills/auto/*.md`. How many skills? Are they coherent? Valid YAML frontmatter?
- Run the same corpus twice. Do you get 2× skills or does the plugin upgrade in place?

**Cross-profile visibility via hub:**
- Use `research-agent`'s hub client to write a memory with visibility=group. Use `email-marketing`'s client to query the hub. Does the memory appear? With what relevance score?

**Embedding consistency:**
- Write the same text twice. Verify embeddings are bit-identical (or numerically identical within floating-point tolerance).
- Write the same text on two different profiles. Are embeddings consistent across profiles?

**Content fidelity edge cases:**
- Write: numbers (3.14159265), URLs (`https://example.com/path?q=1&b=2#frag`), Unicode (中文 emoji 🔥), code snippets (with triple-backticks), JSON blobs, markdown tables, HTML-escape-triggering text (`<script>`), very short content ("yes"), very long single word (10k chars). Each survives round-trip?

### Scoring

For each probe, record:

- What you tested
- Expected behavior (based on plugin docs / source)
- Actual behavior (DB rows, query results, timing)
- 1-10 score with one-line justification

Summary table:

| Area | Score 1-10 | Key finding |
|------|-----------|-------------|
| Auto-capture | | |
| Chunking | | |
| Dedup | | |
| Hybrid search | | |
| MMR | | |
| Recency decay | | |
| Summarization | | |
| Skill evolution | | |
| Cross-profile visibility | | |
| Embedding consistency | | |
| Content fidelity | | |

**Overall functionality score = MIN of all areas.**

### Out of bounds

Do not read `/tmp/`, `CLAUDE.md`, other audit reports, plan files in `memos-setup/learnings/`, or existing test scripts. Form conclusions from the plugin source + runtime behavior only.
