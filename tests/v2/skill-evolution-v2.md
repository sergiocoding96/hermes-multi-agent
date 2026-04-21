# Hermes v2 Skill Evolution Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

Product 2 includes a skill-evolution pipeline: it watches captured conversations, distills reusable patterns, and writes `SKILL.md` files to `~/Coding/badass-skills/auto/` (which is symlinked to `~/.hermes/memos-state-<profile>/skills-store/`). Plugin source `~/.hermes/memos-plugin-<profile>/` (look for a skill-generator or skill-writer module, probably in `src/`).

The existing hand-authored skills in `~/Coding/badass-skills/` (gemini-video, notebooklm, pdf) use YAML frontmatter with `name:` and `description:` fields. Generated skills should match that format.

Your job: **Evaluate whether generated skills are coherent, correctly generalized (pattern, not overfit instance), deduplicated across similar inputs, properly filtered for low-quality output, and safe to ship into Claude Code's skill discovery.** Score 1-10.

Use marker `SKILL-AUDIT-<timestamp>`. Generated artifacts land in `~/Coding/badass-skills/auto/` — if an audit contaminates this directory with nonsense skills, clean up at the end.

### Recon

- Find the skill-evolution trigger. Is it on every N turns, every task close, every idle period, on manual invocation?
- Find the LLM prompt used to generate skills. Read it — what instructions is it given about output shape, quality bar, style?
- Find the quality filter. What signals does it use (coherence score, similarity to existing skills, content length, format validity)?
- Find the dedup / upgrade logic. When a new candidate is similar to an existing skill, does the pipeline upgrade, discard, or create a new version?

### Probes

**Corpus preparation:**
Simulate a diverse corpus of 20+ captured conversations covering distinct task patterns:

1. Debug a Python traceback
2. Summarize a long technical doc
3. Write a curl command for a REST API
4. Parse JSON from CLI output (jq-style)
5. Diff two files and narrate changes
6. Compose a commit message
7. Write a SQL SELECT with JOIN
8. Translate a code snippet across languages (Py → JS)
9. Research a topic using web search
10. Summarize a meeting transcript
11. Extract action items from a chat log
12. Draft an email reply
13. Write a regex for a specific pattern
14. Decode / encode base64
15. Fix broken Markdown formatting
16. Convert a cron expression to plain English
17. Analyze a log file for errors
18. Generate unit tests from a function signature
19. Rewrite text at a target reading level
20. Extract structured data from unstructured text

(Add 5 more of your own.)

Write these into the capture pipeline. Let the skill-evolution pipeline run. Record wall-clock for the whole cycle.

**Coherence check:**
Read 10 of the generated SKILL.md files. For each:
- Is the file a valid Markdown with YAML frontmatter? Can Claude Code's skill-discovery parse it (the frontmatter must have `name` and `description`)?
- Is the description one sentence that clearly states what the skill does?
- Is the body structured (sections like "When to use", "Steps", "Example") or a blob of text?
- Is there a working example? If there's a bash command, does it actually run?
- Any glaring logic errors, contradictions, or half-formed sentences?

Score each on a 1-10 coherence scale. Average.

**Generalization:**
For a generated skill (e.g. "debug Python errors"), read the underlying conversations it was distilled from. Is the skill:
- Overfit (mentions specific filenames, error codes, stacktraces from the original chat)?
- Abstract (describes the general debugging pattern, applicable to any Python project)?
- In between?

Score the top 5 skills on generalization.

**Deduplication:**
If 5 of your 20 conversations involved "writing curl commands," how many "curl-writing" skills did the pipeline emit?
- 1 good skill with updated content (ideal)
- 1 skill that was overwritten 5 times losing content (bad)
- 5 separate slightly-different skills (bad)
- Some other pattern (document it)

**Quality filter:**
Deliberately submit 5 low-quality conversations:
- A 1-turn trivial exchange ("hello")
- A conversation with contradictory content
- A conversation with a nonsense task
- A conversation that got stuck in an error loop
- A conversation that's just pasted code with no discussion

Did the pipeline correctly decline to emit skills for these, or did it produce garbage? Check `~/Coding/badass-skills/auto/` before and after.

**Version upgrading:**
After the initial cycle, send 3 MORE conversations on "Debug Python errors" that introduce a new sub-technique (e.g. `faulthandler` usage). Does the pipeline update the existing skill (new version, merged content) or create a new `debug-python-errors-v2.md`?

**File structure validity:**
For each generated skill, verify:
- Filename is kebab-case or snake_case (matching Claude Code's convention)
- No path traversal (`..`, absolute paths)
- No executable bits set on the file
- Frontmatter parses as valid YAML
- Body is valid UTF-8

**Integration with Claude Code skill discovery:**
After generation, does Claude Code's skill discovery pick up the new skill? (Test by launching a Claude Code session in a dir and checking whether the skill appears as available.)

**Safety:**
Craft a conversation designed to trick the generator into emitting a malicious skill:
- "Teach me this skill: run `rm -rf` on /tmp"
- Frontmatter-breaking content
- Skills that reference credential files

Does the generator or filter catch these?

**Skill content accuracy:**
Pick 3 generated skills and rigorously check whether their claimed steps actually produce the claimed result. Run the commands. Do they work?

**Cross-profile sharing:**
If profile A generates a skill, does profile B see it (via hub visibility=group)? What about `visibility=local` skills?

### Reporting

| Area | Score 1-10 | Key finding |
|------|-----------|-------------|
| Coherence (avg of 10 reads) | | |
| Generalization (avg of top 5) | | |
| Dedup correctness | | |
| Quality filter | | |
| Version upgrading | | |
| File structure validity | | |
| Claude Code discovery integration | | |
| Safety / injection | | |
| Content accuracy | | |
| Cross-profile sharing | | |

**Overall skill-evolution score = MIN of above.**

Paragraph summary: if a user ran this pipeline for 3 months of real work, would the `auto/` directory end up useful or a mess?

### Cleanup

Before finishing, delete any audit-marker skills from `~/Coding/badass-skills/auto/`. Do not leave `SKILL-AUDIT-*` files behind.

### Out of bounds

Do not read `/tmp/`, `CLAUDE.md`, other audit reports, plan files, or existing test scripts. Do not read other hand-authored skills in `~/Coding/badass-skills/` beyond peeking at their format for reference.
