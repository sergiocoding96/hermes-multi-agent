# Hermes v2 Task Summarization Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

Product 2's task-summarization pipeline detects task boundaries within a captured conversation, invokes an LLM summarizer (DeepSeek V3 via `openai_compatible`, per plugin config), and stores a structured summary (Goal / Key Steps / Result / Key Details) in SQLite. Plugin source `~/.hermes/memos-plugin-<profile>/`. Local DB at `~/.hermes/memos-state-<profile>/memos-local/memos.db`.

Idle timeout is configurable; plugin default is 2 hours — an idle period exceeding this threshold closes the current task and triggers summarization.

Your job: **Verify (a) boundary detection — over-splits / under-splits / misses, (b) summary fidelity — no hallucination, all key details preserved, (c) idle-timeout correctness, (d) handling of tasks with errors or complications.** Score 1-10.

Use marker `TASK-AUDIT-<timestamp>`. Create your own test conversations.

### Recon

- Find the boundary detector. Is it rule-based (keywords like "done", "next", "now let's"), LLM-based (every N turns ask "has the task shifted?"), or timeout-driven?
- Find the summarizer prompt. Read it. What output shape does it demand? What fields are mandatory?
- Find where summaries land in the DB. What's the schema?
- What's the default idle timeout? Where is it configurable?

### Boundary detection probes

**Explicit boundaries:**
- Write one session with 3 explicit task transitions:
  - Turns 1-5: "Task 1: research the Raft consensus algorithm"
  - Turn 6: "Done with task 1. Task 2: write Python for leader election"
  - Turns 7-12: ... (do the task)
  - Turn 13: "Finished. Task 3: summarize Raft in 3 paragraphs"
  - Turns 14-16: (do it)
- Trigger a summarization cycle (via idle timeout or manual invocation — find the API).
- Count the summaries in the DB. Expected: 3. Actual: ?

**Implicit boundaries (context shift, no marker):**
- Write 5 turns about Python debugging, then 5 turns about recipe recommendations (cognitively unrelated), no explicit transition. How many summaries are generated?

**Over-split scenario:**
- Single task, with a long pause in the middle: "Help me understand TCP… [7 turns]" — wait 30 minutes — "[5 more turns on same topic]". Does the plugin treat this as 1 or 2 tasks? What does the config dictate?

**Under-split scenario:**
- Two completely different tasks rapid-fire, no transition words:
  - Turns 1-3: "What's the capital of France?" / "Paris." / "Great."
  - Turns 4-6: "How do I sort a list in Python?" / ... / "Thanks."
- Does the plugin detect 2 boundaries or merge them?

**Very short task:**
- A 2-turn "task" (single question-answer). Does it generate a summary? Should it?

**Very long task:**
- A 50-turn task on one topic. Is a single summary generated, or does the plugin split long tasks into parts?

### Summary quality probes

**Key details preservation:**
Within a task, mention explicit artifacts:
- A specific URL: `https://example.com/ref?v=42&lang=en#section-3`
- A file path: `/var/log/nginx/access.log.2026-04-21`
- A code snippet: ``` def foo(x): return x * 2 ```
- An error: `ImportError: No module named 'foo' at line 47 of bar.py`
- A number: `exactly 1,527,384 users`

Generate the summary. Check each artifact — preserved verbatim / paraphrased / lost?

**Faithfulness:**
- Make a clearly false claim in one turn ("Python 2 is faster than Python 3 for JSON parsing"). Verify in the summary: is the claim repeated uncritically, attributed to the user, or dropped?
- Make a claim that's correct but obscure ("Raft uses randomized election timeouts between 150-300ms"). Does the summary preserve the number?

**Structure adherence:**
Check each summary for the required fields (Goal, Key Steps, Result, Key Details).
- Missing fields?
- Blank fields?
- Steps numbered or narrative?
- Result matches what actually happened, or hallucinated success?

**Multi-language:**
- Task conducted in Spanish. Is the summary in Spanish (mirroring user language) or forced to English? Is it still faithful?

**Task with errors:**
- Task that encounters failures: commands that errored, approaches that didn't work. Is the summary honest about failures, or does it paper over them?
- Does the "Result" field capture "partial success" vs "success" vs "failure"?

### Idle timeout probes

**Short-timeout test (if configurable):**
Config the idle timeout to 60 seconds. Do a task. Go idle 70 seconds. Verify summary fires.

**Default-timeout (2h) smoke:**
If 2h is tractable, do one real-time test at the boundary: do a task, wait 1h 55m, add one turn, wait 10m more. Does the boundary fall before or after the continuation?
(If not tractable within the audit window, document the default and test with a temporarily lowered config.)

**Pending-summary on shutdown:**
If the plugin is killed (or the agent exits) with an uncompleted task, is a summary still generated on restart, or is the task orphaned without a summary?

### Concurrency probes

**Multiple sessions:**
Two profiles both have open tasks. Both hit idle timeout simultaneously. Do summaries get generated correctly for both, or do they interfere?

**Summarizer latency under load:**
Trigger 5 summaries concurrently. Do any fail / timeout / produce truncated output?

### Reporting

| Area | Score 1-10 | Key finding |
|------|-----------|-------------|
| Boundary detection — explicit | | |
| Boundary detection — implicit | | |
| Over-split | | |
| Under-split | | |
| Very short task | | |
| Very long task | | |
| Key-detail preservation | | |
| Faithfulness (no hallucination) | | |
| Structure adherence | | |
| Multi-language | | |
| Error-task handling | | |
| Idle timeout accuracy | | |
| Pending summaries on shutdown | | |
| Concurrent summarization | | |

**Overall task-summarization score = MIN of above.**

Paragraph summary: is the summarizer reliable enough that an agent could use the summaries as working memory the next day without re-reading the raw conversation?

### Out of bounds

Do not read `/tmp/`, `CLAUDE.md`, other audit reports, plan files, or existing test scripts.
