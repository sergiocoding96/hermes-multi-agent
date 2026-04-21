# Hermes v2 Skill Evolution Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## Your Job

**Verify the skill evolution pipeline produces coherent, generalized, non-duplicative SKILL.md files.** Score quality 1-10.

Markers: `SKILL-AUDIT-<timestamp>`.

## Probes

1. **Corpus generation:** Create 20+ simulated multi-turn conversations covering realistic tasks:
   - Debug a Python error
   - Summarize a technical document
   - Write a curl command for an API
   - Analyze JSON data
   - Parse CLI output
   - (Add 15+ more)

2. **Plugin execution:** Let the plugin's skill evolution pipeline process this corpus. Monitor `~/Coding/badass-skills/auto/` for generated SKILL.md files.

3. **Coherence:** Read 10 generated skills. Are they:
   - Syntactically valid SKILL.md format?
   - Grammatically correct?
   - Logically coherent (not contradictory)?
   - Would a human find them useful as reference material?

4. **Generalization:** Do the skills describe a pattern (e.g., "debug Python errors" as a general technique) or overfit to one conversation (e.g., "fix this exact error code 1234")?

5. **De-duplication:** If 5 conversations all involve "summarizing documents," do you get 5 skills or 1 skill with multiple versions?

6. **Version upgrading:** If a similar conversation occurs later, does the plugin upgrade an existing skill or create a new one? Evidence?

7. **Quality filtering:** The plugin claims to filter low-quality skills. Run your corpus and verify that bad generations (contradictory, incoherent, trivial) are filtered out.

8. **File structure:** Check `~/Coding/badass-skills/auto/<skill>.md` format. Does it match the expected YAML-frontmatter structure? Are skills discoverable by other systems (e.g., Claude Code skill discovery)?

9. **Metadata preservation:** Do generated skills include: name, description, example usage, tags?

10. **Corpus diversity impact:** Run the pipeline on a diverse corpus, then on a narrow corpus (only "debug Python"). Does the diversity affect skill count or quality?

## Report

For each area: test method, findings, evidence (sample skills, counts, logs), and 1-10 score.

Summary: overall skill evolution quality score and production readiness.
