# Hermes v2 Auto-Capture Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## Your Job

**Verify the capture pipeline handles every message type, correctly chunks content, filters PII, and recovers from aborts.** Score capture correctness 1-10.

Markers: `CAP-AUDIT-<timestamp>`.

## Probes

1. **Every message type:** In a multi-turn conversation, verify all captured: user messages, assistant response, tool calls, tool result outputs. System messages should NOT be captured.

2. **Consecutive assistant messages:** If Hermes emits multiple assistant messages before the user's next turn, are they merged into one memory or separate?

3. **Tool output size:** Run a bash command that outputs 10k characters. Is it captured in full, truncated, or chunked?

4. **Chunking boundaries:** Write a turn with multiple paragraphs + code blocks + lists. Are splits at natural boundaries (paragraphs, blocks) or arbitrary?

5. **Very long single turn:** Write 5000 words in one turn. Is extraction complete or degraded at the end of the message?

6. **Multi-language:** Write mixed English, Spanish, Chinese in one turn. Does embedding handle all? Any corruption?

7. **PII detection:** Include what looks like a credit card number, email, SSH key, in a message. Does the plugin flag it? Filter it? Document what it does?

8. **Abort handling (Ctrl-C):** Start a long-running task, interrupt it mid-turn. Are the captured-so-far memories preserved? Can you resume the conversation?

9. **Session crash:** Simulate a process crash mid-turn. When the agent restarts, are previously captured memories intact?

10. **File uploads:** If Hermes supports file operations, do file contents get captured? Attachments?

11. **Error messages:** Capture turns that include errors from tools. Are errors preserved accurately?

12. **Metadata preservation:** Verify captured metadata: timestamps, agent ID, turn sequence, conversation ID. Are they correct and queryable?

## Report

For each scenario: test, expected behavior, actual, evidence, 1-10 score.

Summary: overall capture reliability score.
