# Hermes v2 Task Summarization Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## Your Job

**Verify task boundary detection and summary quality (Goal, Steps, Result, Details).** Score 1-10.

Markers: `TASK-AUDIT-<timestamp>`.

## Probes

1. **Exact boundary detection:** Create a conversation with 3 clearly distinct tasks with explicit transitions:
   - "Task 1: research X" (5 turns)
   - "Done with task 1. Now task 2: write code for Y" (5 turns)
   - "Finished. Task 3: summarize Z" (5 turns)
   Does the plugin detect exactly 3 tasks or fewer/more?

2. **Implicit boundary detection:** Create a conversation where tasks transition via context shift (not explicit markers). Does the plugin detect boundaries?

3. **Over-split scenario:** Within a single cohesive task, include natural pauses (user goes idle 10 minutes mid-task). Does the plugin over-split into separate tasks?

4. **Under-split scenario:** Two unrelated tasks in rapid succession with minimal transition. Does the plugin merge them or keep separate?

5. **Summary structure:** For each detected task, does the plugin generate a summary with: Goal (clear statement), Key Steps (ordered list), Result (outcome), Key Details (preserves URLs, file paths, code)?

6. **Detail preservation:** Within a task, mention specific technical details: code snippets, error messages, file paths, URLs. Are these preserved in the summary or lost?

7. **Fidelity:** Write a specific command like `curl -X GET "https://api.example.com/v2/resource?id=123&format=json"`. Does the summary reproduce it exactly?

8. **Idle timeout:** Plugin default is 2 hours. Create a task, let the agent idle for 2+ hours. Does the idle timeout trigger task summarization?

9. **Boundary near 2h:** Create a task, user goes idle for 1h 59m, then returns. Is the task still open or summarized?

10. **Multi-language tasks:** Task in English, task in Spanish. Are boundaries still detected? Summaries coherent?

11. **Task with errors:** A task that encounters errors (failed commands, exceptions). Are errors reflected in the summary?

## Report

For each scenario: test description, expected boundaries, actual, evidence (task count, summary content), and 1-10 score.

Summary: overall task detection and summarization quality score.
