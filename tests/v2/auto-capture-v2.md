# Hermes v2 Auto-Capture Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

The auto-capture pipeline is new in Product 2 — unlike Product 1 (which required explicit write calls), Product 2 captures every agent turn automatically and writes it to local SQLite at `~/.hermes/memos-state-<profile>/memos-local/memos.db`. Plugin source: `~/.hermes/memos-plugin-<profile>/` (look especially at the bridge daemon `bridge.cts` which intercepts turns).

Your job: **Verify the capture pipeline correctly handles every message type, chunks content sensibly, recovers from aborts, and doesn't drop, duplicate, or corrupt data under realistic usage.** Score capture correctness 1-10.

Use marker `CAP-AUDIT-<timestamp>`. Create a throwaway Hermes session or a test profile; do not contaminate production data.

### Recon

- Find the capture entry point: what function accepts a turn?
- What message types does it recognize — user, assistant, tool_call, tool_result, system?
- What's chunked vs stored whole? What's the chunk-size policy?
- Is there a pre-write filter (PII, dedup, size cap)?
- How does the daemon handle backpressure (e.g. DB locked, LLM summarizer backlog)?

### Capture scenarios

**Message-type coverage:**
- Run a session with each message type (user / assistant / tool_call / tool_result / system). Verify which land in SQLite, which are filtered.
- Are speaker labels preserved? (If the DB doesn't distinguish user from assistant, that's a bug.)

**Consecutive assistant messages:**
- Agent emits 3 assistant messages in sequence (without a user reply between). Are they 3 rows or 1 merged row?
- Agent emits tool_call → tool_result → continued reasoning → final answer. Are all captured as separate "chunks" or merged?

**Huge tool outputs:**
- Run a bash command that outputs 10,000 characters. Capture verbatim, truncated, or chunked?
- 100,000 characters? 1,000,000?
- If truncated, is there a marker (e.g. `[...truncated...]`)?

**Chunking boundaries:**
- Long turn (3000 words) with mixed paragraphs, code blocks (```), bulleted lists, headings. Where are the chunk splits? At paragraph boundaries? Mid-sentence? Mid-code-block?
- Does splitting a code block lose indentation / language tags?

**Very long single turn:**
- 5000-word turn. Do all chunks land? Are there any dropped in the middle (buffer limits)?
- 20,000-word turn. Same check.

**Multi-language content:**
- One turn mixing English, Spanish, Chinese, emoji. Embeddings produced? Stored as UTF-8 correctly (check `sqlite3` output byte-for-byte)?
- Pure non-ASCII (full Chinese turn). Any token-count issues?

**PII-like content:**
- Include: email (`someone@example.com`), credit-card-like (`4111 1111 1111 1111`), SSN-like (`123-45-6789`), JWT (`eyJ...`), private-key-header (`-----BEGIN RSA PRIVATE KEY-----`), phone number, IP address, home address.
- Does the plugin redact, tag, or pass through? Document explicitly.
- Can you configure PII behavior? Find the config key. Toggle it. Verify behavior changes.

**Abort mid-conversation (Ctrl-C):**
- Start a session, send 3 turns, abort on the 4th mid-response. Query SQLite — are turns 1-3 preserved? Is turn 4 partial or absent?
- Restart the agent. Can it resume with the captured history?

**Session crash:**
- Simulate plugin process crash (`kill -9`) after turn 5. Are turns 1-5 flushed to disk? Any data loss?
- Graceful shutdown (`kill -TERM`) — does it flush cleaner than `-9`?

**Concurrent sessions:**
- Start 3 agent sessions on different profiles simultaneously. Each writes 10 turns. Any cross-talk (turns from session A in session B's DB)? Any dropped?

**Attachments / files:**
- If Hermes supports file inputs (images, PDFs), do they get captured? As what — base64 blob, reference, summary?
- Does capturing a 10MB PDF crash the pipeline or store it sensibly?

**Metadata correctness:**
- For each captured row, verify: timestamp monotonic, conversation_id stable within a session, agent_id matches the profile, turn_sequence correct, role field present.

**Idempotency:**
- Retry the same turn (if the client retried after a transient error). Does the plugin dedupe the retry, or create 2 rows?

**Ordering guarantees:**
- Send turns rapidly. Does SQLite preserve the order (via auto-increment row ID or timestamp)? If two turns have the same timestamp, how is tiebreak done?

### Reporting

| Scenario | Result | Expected | Score 1-10 |
|----------|--------|----------|-----------|
| Message-type coverage | | | |
| Consecutive assistant merging | | | |
| Tool output size | | | |
| Chunk boundaries | | | |
| Very long turn | | | |
| Multi-language | | | |
| PII handling | | | |
| Abort recovery | | | |
| Crash recovery | | | |
| Concurrent sessions | | | |
| Attachments | | | |
| Metadata correctness | | | |
| Idempotency | | | |
| Ordering | | | |

**Overall capture score = MIN of above.** If PII is passed through unredacted with no config to stop it, that's a security concern and must propagate to the zero-knowledge audit — but score it here strictly on capture pipeline correctness.

### Out of bounds

Do not read `/tmp/`, `CLAUDE.md`, other audit reports, plan files, or existing test scripts.
