# MemOS v1 Functionality Audit

Paste this as your FIRST message into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`. No other context should be present.

---

## Prompt

The legacy MemOS server at `http://localhost:8001` exposes a memory-management API used by Hermes (`memos-toolset` plugin) and OpenClaw (`memos-local-openclaw`). The system claims to:

1. Accept memory writes via `/memories` (and equivalents) in **fast** (raw store) and **fine** (LLM-extracted) modes, plus **async** background extraction.
2. Auto-capture turn content from agents through the plugin (v1.0.3+), so callers don't need explicit `memos_store` calls.
3. Apply **write-time deduplication** at cosine ≈ 0.90 against existing memories in the same cube.
4. Run **MemReader** (DeepSeek V3) for fine-mode extraction: structures raw text into typed memories with `custom_tags`, `info`, timestamps, and language enforcement (no Chinese in English output).
5. Serve search via `/search` with three modes: `no` (raw), `sim` (similarity), `mmr` (max-marginal-relevance).
6. Enforce **per-cube isolation** through `UserManager` ACL, while letting the CEO read across cubes via `CompositeCubeView`.
7. Honor a **relativity threshold** that filters search results below a min cosine.

**Your job: prove or disprove each of those claims with concrete evidence, and find any case where the documented behaviour does NOT match the live system.** Score correctness 1-10, MIN across sub-areas. Adopt a "trust nothing" stance — every claim must be demonstrated.

Use marker `V1-FN-<unix-ts>` on every memory / cube / query you create.

### Zero-knowledge constraint

Do NOT read any of:
- `/tmp/**` beyond files you created this run
- `CLAUDE.md` at any level
- `tests/v1/reports/**`, `tests/v2/reports/**`
- `tests/blind-*`, `tests/zero-knowledge-audit.md`, `tests/security-remediation-report.md`
- `memos-setup/learnings/**`
- any `TASK.md` or plan file
- any commit message that mentions "audit", "score", "fix", or "remediation"

Inputs allowed: this prompt, the live system, source under `/home/openclaw/Coding/MemOS/src/memos/**`, the Hermes plugin under `~/.hermes/plugins/memos-toolset/**`. Discover everything else.

### Throwaway profile (provision before any probe)

```bash
curl -s http://localhost:8001/health | jq . || (
  cd /home/openclaw/Coding/MemOS
  set -a && source .env && set +a
  python3.12 -m memos.api.server_api > /tmp/memos-v1-fn.log 2>&1 &
  sleep 5 && curl -s http://localhost:8001/health | jq .
)

export MEMOS_HOME=/tmp/memos-v1-audit-$(uuidgen)
mkdir -p "$MEMOS_HOME/data"
TS=$(date +%s)
python3.12 /home/openclaw/Coding/Hermes/deploy/scripts/setup-memos-agents.py \
  --output "$MEMOS_HOME/agents-auth.json" \
  --agents \
    "audit-v1-fn-a:V1-FN-A-$TS" \
    "audit-v1-fn-b:V1-FN-B-$TS"
```

Teardown:
```bash
rm -rf "$MEMOS_HOME"
sqlite3 ~/.memos/data/memos.db <<SQL
DELETE FROM users WHERE user_id LIKE 'audit-v1-fn%';
DELETE FROM cubes WHERE cube_id LIKE 'V1-FN-%';
SQL
```

### Recon (first 5 minutes — don't skip)

1. Read `src/memos/api/server_api.py` and list every route with method + path + payload schema. What's gated by auth?
2. Read `src/memos/multi_mem_cube/single_cube.py` and `composite_cube_view.py`. Find: write path, dedup logic, search dispatch, ACL check.
3. Read `src/memos/templates/mem_reader_prompts.py`. What does the fine-mode extraction actually emit? Schema?
4. `grep -rn "auto_capture\|auto-capture" src/memos ~/.hermes/plugins/memos-toolset 2>/dev/null` — find the v1.0.3 auto-capture path. Where does it hook?
5. Read the Hermes plugin (`~/.hermes/plugins/memos-toolset/`) — what does it expose? Tool names, args, identity model.

### Probe matrix

**Write paths (fast / fine / async).**
- Submit a memory in **fast** mode (no extraction). Confirm: row appears immediately; `info` empty; no LLM call (check llm.log or DeepSeek call counter).
- Submit the same content in **fine** mode. Confirm: LLM is called; structured fields (`custom_tags`, `info`, `timestamp`) are populated; output language matches request (English in → English out, no CJK leakage).
- Submit in **async** mode. Confirm: API returns immediately; check after 5–30s that fine-mode fields appear without blocking the caller.
- Submit content with embedded JSON, code blocks, URLs, emoji, mixed CJK/English. Verify each survives end-to-end (database row matches input byte-for-byte for the raw fields).

**Auto-capture (v1.0.3 path).**
- Use the Hermes `memos-toolset` plugin from a sandbox agent run. Issue a few turns. Verify capture happens **without** an explicit `memos_store` call. Where? When?
- Submit a turn that should NOT be captured (e.g. the agent asks "what's 2+2"). Does the plugin filter trivial content? What's the threshold?
- Force a capture failure (e.g. block port 8001 for one second). Does the plugin queue, drop, retry?

**Write-time dedup (~0.90 cosine).**
- Submit two memories with near-identical text. Second should be deduped. Confirm in DB that only one row exists. What's stored about the dedup decision (audit trail)?
- Submit two memories that are 0.85 / 0.92 / 0.95 cosine similar. Find the exact threshold by bisection. Document the value.
- Submit duplicates **across cubes** (different `cube_id`) — does dedup apply? It shouldn't, per per-cube isolation.

**MemReader fine-mode extraction.**
- Submit a memory with structured info ("Buy milk by Friday at 5pm, then call mom"). Fine-mode extracted fields: do they capture entity / time / action? Schema-validated?
- Submit a paragraph in Spanish, then in Chinese. Output language: respects the request locale? Or defaults to one language regardless?
- Submit a 5000-char block. Chunked? Retained as a single memory? Find the chunking threshold and rule (`grep -rn "chunk_size\|MAX_TOKENS"`).
- Submit content that the LLM would refuse / soft-error on. What does MemReader do? Re-prompt? Fall back to raw? Drop the memory?

**Search modes (no / sim / mmr).**
- Insert 20 memories with controlled topical overlap. Run search with each mode for the same query. Document: result-set differences, ordering, score values.
- `mmr`: verify diversity property — do top-k results differ from `sim` mode, and is the diversification visible?
- Set `relativity` (or equivalent threshold). Push it high — empty results expected; push it low — full corpus expected. Find the actual threshold semantics.

**Per-cube isolation under search.**
- As `audit-v1-fn-a`, search for content that exists only in `audit-v1-fn-b`'s cube. Expected: zero results, not 403 (silent isolation).
- As CEO with `CompositeCubeView`, run the same search. Expected: results from both cubes, each tagged with `cube_id`. Confirm the tag is reliable.

**Custom tags + info round-trip.**
- Submit a memory with `custom_tags: ["alpha", "beta"]` and structured `info: {project: "X"}`. Retrieve via `/memories/<id>` and via search. Confirm both round-trip without modification.
- Modify the memory (`PUT` or equivalent). Does the modification preserve other fields? Are tags merged or replaced?

**Delete + soft-delete behaviour.**
- Create a memory, delete it. Confirm: gone from search, gone from `/memories`, marked `is_active=False` in SQLite (or hard-deleted — note which).
- Re-create with the same content. Does dedup catch it against the soft-deleted row? It shouldn't.
- Bulk-delete by tag, by query, by cube — supported? Atomic on partial failure?

**Concurrent writes.**
- Fire 50 parallel writes to the same cube. Verify: all land, no `SQLITE_BUSY` leaked to caller, dedup ordering deterministic (or at least documented).

**Plugin contract (Hermes).**
- The plugin should expose `memos_store`, `memos_search`, possibly `memos_delete` to the agent. Verify the tool definitions don't leak the API key into the LLM context.
- The agent's `MEMOS_USER_ID` / `MEMOS_CUBE_ID` come from the profile env, not from the agent's prompt. Try to override at call time — the plugin should refuse or ignore.

### Reporting

For every finding:

- Class: spec-violation / silent-failure / data-loss / dedup-error / isolation-leak / extraction-error / contract-mismatch.
- Reproducer: exact `curl` / `sqlite3` / Hermes plugin call.
- Evidence: HTTP status + body, DB row, log excerpt, before/after timestamps.
- Severity: Critical / High / Medium / Low / Info.
- One-sentence remediation.

Final summary table:

| Area | Score 1-10 | Key findings |
|------|-----------|--------------|
| Fast write path | | |
| Fine write path (MemReader extraction) | | |
| Async write path | | |
| Auto-capture (v1.0.3 plugin) | | |
| Write-time dedup (cosine threshold) | | |
| Cross-cube dedup boundary | | |
| Search `no` mode | | |
| Search `sim` mode | | |
| Search `mmr` mode | | |
| Relativity / score threshold | | |
| Per-cube isolation under search | | |
| CompositeCubeView (CEO multi-cube) | | |
| Custom tags + info round-trip | | |
| Delete + soft-delete | | |
| Concurrent writes | | |
| Hermes plugin contract | | |

**Overall functionality score = MIN of all sub-areas.** Close with a one-paragraph recommendation: would the demo agents (research-agent, email-marketing-agent) work as designed against this system today?

### Out of bounds (re-asserted)

Do NOT read `/tmp/` beyond files you created this run, `CLAUDE.md`, prior audit reports under `tests/v1/reports/` or `tests/v2/reports/`, plan files, learning docs under `memos-setup/learnings/`, or any commit message that telegraphs prior findings.

### Deliver

```bash
git fetch origin tests/v1.0-audit-reports-2026-04-30
git switch tests/v1.0-audit-reports-2026-04-30
git pull --rebase origin tests/v1.0-audit-reports-2026-04-30
# write tests/v1/reports/functionality-v1-$(date +%Y-%m-%d).md
git add tests/v1/reports/functionality-v1-*.md
git commit -m "report(tests/v1.0): functionality audit"
git push origin tests/v1.0-audit-reports-2026-04-30
```

Do not open a PR. Do not modify any other file. Do not push to `main` or any other branch.
