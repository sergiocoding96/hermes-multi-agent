# MemOS Functionality Blind Audit

Paste this into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

There is a memory storage API at `http://localhost:8001`. If down, start it: `cd /home/openclaw/Coding/MemOS && set -a && source .env && set +a && python3.12 -m memos.api.server_api > /tmp/memos_func_audit.log 2>&1 &` — wait 15 seconds.

Source: `/home/openclaw/.local/lib/python3.12/site-packages/memos/`. Config: `/home/openclaw/Coding/MemOS/.env`. Agent keys: `/home/openclaw/Coding/Hermes/agents-auth.json`.

Your job: **Determine whether this system correctly stores, extracts, deduplicates, searches, and returns memories.** You are testing functionality, not security. Assume you have valid credentials.

Start by reading the OpenAPI spec at `/openapi.json` and the source code to understand what the system is supposed to do. Then design and run your own test suite. Create your own test users, cubes, and data — do not reuse anything that already exists.

Test every claim the system makes about its own capabilities. Focus on:

- **Write path:** Does writing a memory actually persist it? What modes exist (fast vs fine)? What's the difference? Does sync mode block until completion? Does async mode return immediately?
- **Extraction quality:** When you write a paragraph of text, what memories get extracted? Are they atomic (one fact per memory)? Are timestamps resolved? Are pronouns resolved? Is third-person perspective maintained?
- **Search path:** Does exact search work? Does semantic/vague search work? How does relativity threshold affect results? How does top_k affect results? Does dedup (no/sim/mmr) change what comes back? What reranking strategy is used?
- **Deduplication:** Write the same fact multiple times. Write paraphrased versions. Write facts with different wording but same meaning. How many copies are stored? At what similarity threshold does dedup kick in?
- **Long content:** Write 500 words, 1000 words, 2000 words, 5000 words. At what length does extraction degrade? How does chunking work? Are facts at the end of long documents extracted as well as facts at the beginning?
- **Cross-cube search:** Write to cube A and cube B. Search across both. Are results correctly merged? Are they ranked by relevance or by cube?
- **Memory types:** What types exist (text_mem, preference, skill, tool)? Test each one. Do preferences get extracted differently than facts?
- **Feedback system:** What does the feedback endpoint do? Does positive/negative feedback change future search results?
- **Scheduler:** Is there a background scheduler? What does it do? Does it reorganize memories? Does it affect search quality over time?
- **Chat endpoint:** Does the chat endpoint use memories in its responses? Does it add conversation turns to memory?
- **Edge cases in content:** Numbers, dates, URLs, code snippets, JSON, markdown, HTML tags, very short content (2 words), very long single words.

For each area, report: what you tested, what you expected, what actually happened, and a 1-10 score with justification.

Do not read any files in `/tmp/`, `CLAUDE.md`, or existing test scripts. Form conclusions from code and behavior only.
