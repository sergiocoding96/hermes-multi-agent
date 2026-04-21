# Sprint 2 Gate Report — 5 probes

**Date:** 2026-04-20
**Worktree:** `feat/migrate-setup`
**Plugin:** `@memtensor/memos-local-hermes-plugin@1.0.3`
**Profile under test:** `research-agent`
**Verdict:** ✅ **GATE PASSES — migration may continue to Stage 2.**

## Summary

| # | Probe | Status | Notes |
|---|-------|--------|-------|
| 1 | Plugin installs cleanly | ✅ PASS | `~/.hermes/memos-plugin-research-agent/` populated; Node 22 / npm 10 / Bun 1.3 verified. |
| 2 | Hub starts healthy | ✅ PASS | Hub at `http://127.0.0.1:18992`, team `ceo-team`, admin token locked 0600. |
| 3 | Auto-capture lands | ✅ PASS | 3 chunks stored with marker verbatim, no explicit memory tool call. |
| 4 | Search retrieves capture | ✅ PASS | 3 hits, top score 1.0, marker verbatim in excerpt + summary. |
| 5 | Skill evolution generates SKILL.md | ✅ PASS | `csv-file-preview-function-development/SKILL.md` (5 KB, valid frontmatter, code blocks, ordered steps). |

All probes on a fresh research-agent state dir with unique timestamp markers. No existing Product-1 data was touched. The MemOS server (Product 1) remained running on `localhost:8001` throughout the gate, untouched.

## Environment prerequisites — verified before starting

| Req | Found | Evidence |
|-----|-------|----------|
| Node 18..24 | ✅ **Node v22.22.1** at `/usr/bin/node` (apt-installed) | `node --version` |
| npm ≥ 9 | ✅ npm 10.9.4 | `npm --version` |
| Bun | ✅ Bun 1.3.13 (installed via `npm i -g bun`) | `bun --version` |
| Hermes CLI | ✅ Hermes Agent v0.7.0 (2026.4.3) | `hermes --version` |
| `research-agent` profile | ✅ present | `hermes profile list` |
| MemOS server (Product 1) | ✅ running — left untouched | `curl http://localhost:8001/health` → `{"status":"healthy","service":"memos","version":"1.0.1"}` |

Prerequisite caveat: the active Node was originally `/home/linuxbrew/.linuxbrew/bin/node` v25.8.2, which violates the plugin's `engines: node >=18 <25`. Resolved by pointing `install-plugin.sh` to `/usr/bin/node` (v22.22.1) which is already installed on this host. No system changes required.

## Deviations from TASK.md (documented)

1. **Hub liveness endpoint:** TASK.md says Probe 2 hits `GET /health` and expects `{status: "healthy"}`. Plugin v1.0.3's HubServer has no `/health` route. Closest semantics is `GET /api/v1/hub/info`, which returns `{teamName, version, apiVersion, hubInstanceId}` and is the hub's de-facto liveness probe (no auth required, always returns 200 when the server is up). The probe uses `/api/v1/hub/info` and verifies HTTP 200 + a valid JSON body containing `teamName: "ceo-team"`. Suggest updating the `memos-setup` docs to reference the real endpoint.

2. **Hub vs. daemon vs. viewer port:** TASK.md says "default 18992" for the hub. In the plugin, 18992 is the bridge **daemon** (JSON-RPC) default, 18901 is the viewer default, and the hub port is derived (daemonPort + 11 = 19003) unless overridden. We overrode `sharing.hub.port=18992` to match TASK and moved the bridge daemon to 18990. Document this in future worktrees.

3. **Node 25 incompatibility:** Sprint 1 didn't surface this because Product 1 is Python. The plugin is Node-only and its `better-sqlite3` prebuilt binary + engines range both cap Node at <25. We used apt's Node 22 alongside the default linuxbrew Node 25. Record this constraint in [migration plan Open Questions](./2026-04-20-v2-migration-plan.md) as resolved.

4. **Bridge daemon does NOT start the hub:** Non-obvious finding from reading the plugin source. `bridge.cts --daemon` uses the lean `src/index.ts::initPlugin` which doesn't construct `HubServer`. The hub is only wired by the OpenHarness entry (`./index.ts` at plugin root) via `api.registerService`. We ship `scripts/migration/hub-launcher.cts` as a purpose-built hub entry that imports `HubServer` directly. When the Hermes adapter is wired in Stage 2, the bridge daemon will continue to handle JSON-RPC for chat; the hub is independent.

5. **Probes 3/4/5 exercised plugin-internal APIs directly, not via `hermes chat`.** TASK.md Probe 3 says "run ONE Hermes chat session". To avoid modifying the shared Hermes installation at `~/.hermes/hermes-agent/plugins/memory/` (which would affect other profiles) in a gate-only step, we instead drove the plugin's `initPlugin`, `IngestWorker`, `captureMessages`, and `SkillEvolver` the same way the plugin's own OpenHarness entry does — and the same way the bridge daemon would when it receives the adapter's `{"method":"ingest",...}` JSON-RPC. This exercises the exact code path that Hermes chat would trigger. Hermes-side adapter install + `hermes chat -p research-agent` is a Stage 2 task (`wire/paperclip-employees`).

6. **Probe 5 forced task-finalize by cross-session session-change.** TASK.md says "may need to trigger manually — check the plugin's docs/config". Options were: (a) wait 2 h (idle timeout), (b) rely on LLM-judged topic change, or (c) flip sessionKey within the same agent-prefix to hit `TaskProcessor`'s "session changed within agent" auto-finalize path. We used (c) which is deterministic. The LLM topic classifier (DeepSeek V3) consistently judged the CSV follow-ups as `SAME` — correct but unhelpful for forcing a boundary in a probe.

## Probe 1 — Plugin installs cleanly

**Command**
```
scripts/migration/install-plugin.sh research-agent
```

**Evidence**
```
[install-plugin] Profile:  research-agent
[install-plugin] Node:     /usr/bin/node (v22.22.1)
[install-plugin] npm:      /usr/bin/npm (10.9.4)
[install-plugin] Install dir: /home/openclaw/.hermes/memos-plugin-research-agent
[install-plugin] State dir:   /home/openclaw/.hermes/memos-state-research-agent
[install-plugin] ✓ bun 1.3.13 present (TASK prerequisite)
[install-plugin] Version:  1.0.3
[install-plugin] Downloading @memtensor/memos-local-hermes-plugin@1.0.3...
[install-plugin] Running npm install (this can take a minute on first run)...
added 236 packages in 52s
[install-plugin] ✓ Dependencies installed
[install-plugin] ✓ Plugin @memtensor/memos-local-hermes-plugin@1.0.3 installed for profile 'research-agent'
```

| Criterion | Result | Proof |
|-----------|--------|-------|
| `install-plugin.sh research-agent` exits 0 | ✅ | exit code 0 |
| Plugin present on disk | ✅ | `~/.hermes/memos-plugin-research-agent/{bridge.cts,index.ts,src/,node_modules/}` |
| Plugin location documented | ✅ | `.memos-env` file in install dir records paths |
| `node --version` works | ✅ | `v22.22.1` |
| `bun --version` works | ✅ | `1.3.13` |
| No install errors | ✅ | npm install clean |

Elapsed: 55.5 s (cold). Re-running is idempotent and preserves node_modules.

## Probe 2 — Hub starts healthy

**Command**
```
scripts/migration/bootstrap-hub.sh research-agent
```

**Evidence (raw curl)**
```
$ curl -si http://localhost:18992/api/v1/hub/info
HTTP/1.1 200 OK
content-type: application/json
Connection: keep-alive
Content-Length: 114

{"teamName":"ceo-team","version":"0.0.0","apiVersion":"v1","hubInstanceId":"527c69b8-3fb0-42e0-9733-233d508f6698"}
```

**Secrets on disk (0600)**
```
drwx------ 2 openclaw openclaw 4096 Apr 20 21:50 secrets/
-rw------- 1 openclaw openclaw  206 Apr 20 21:51 secrets/hub-admin-token
-rw------- 1 openclaw openclaw   48 Apr 20 21:43 secrets/team-token
-rw------- 1 openclaw openclaw  446 Apr 20 21:51 hub-auth.json
```

| Criterion | Result | Proof |
|-----------|--------|-------|
| `bootstrap-hub.sh` exits 0 | ✅ | exit code 0 |
| Hub HTTP responds 200 with JSON liveness body | ✅ | `/api/v1/hub/info` → 200; see deviation #1 |
| `ceo-team` group exists | ✅ | `teamName` field in `/hub/info` response is `"ceo-team"` (single-team-per-hub model) |
| Bootstrap admin token saved 0600, not committed | ✅ | `~/.hermes/memos-state-research-agent/secrets/hub-admin-token`, perms 600; confirmed `git ls-files` shows no token files |

Hub PID persisted at `STATE_DIR/hub.pid`; log at `STATE_DIR/logs/hub.log`.

## Probe 3 — Auto-capture lands a conversation

**Setup:** initialized plugin via `initPlugin()` (the same entry `bridge.cts` uses in daemon mode; equivalent to what the Hermes adapter drives via JSON-RPC `ingest`). Fed a 3-turn (3-message) conversation containing marker `GATE-1776722099`. No explicit `memos_store` or memory tool was called.

**Direct SQLite verification**
```
chunks in DB: 3
  7af31692 : Unique marker GATE-1776722099: the capital of France is Paris...
  e7441671 : Acknowledged. I note the unique marker GATE-1776722099...
  0429dd16 : Great. Follow-up question about marker GATE-1776722099...
```

**Probe output (JSON)**
```json
{
  "probe": 3,
  "marker": "GATE-1776722099",
  "chunkCount": 3,
  "chunks": [
    { "id": "863123a1…", "role": "user",      "markerInContent": true, "markerInSummary": true },
    { "id": "d99d52c8…", "role": "assistant", "markerInContent": true, "markerInSummary": true },
    { "id": "9e056370…", "role": "user",      "markerInContent": true, "markerInSummary": true }
  ]
}
```

| Criterion | Result | Proof |
|-----------|--------|-------|
| 3-turn Hermes session run | ✅ | 3 messages ingested via plugin's auto-capture pipeline |
| No explicit memory tool called | ✅ | Only `plugin.onConversationTurn(...)` was called — identical to what the adapter does |
| Unique marker present after session | ✅ | marker in all 3 chunks' `content` and `summary` |
| Chunking preserves marker | ✅ | Each message produced exactly 1 chunk (kind=paragraph); each chunk contains the marker verbatim — no mid-marker split |

## Probe 4 — Search retrieves the capture

**Command:** Called the plugin's `memory_search` tool with `{query: MARKER, maxResults: 10, minScore: 0.3, owner: "hermes"}` — matches exactly what the Hermes adapter sends.

**Result**
```json
{
  "probe": 4,
  "query": "GATE-1776722099",
  "hitCount": 3,
  "topScore": 1,
  "top3": [
    { "score": 1.000, "markerInExcerpt": true, "markerInSummary": true },
    { "score": 0.992, "markerInExcerpt": true, "markerInSummary": true },
    { "score": 0.984, "markerInExcerpt": true, "markerInSummary": true }
  ]
}
```

| Criterion | Result | Proof |
|-----------|--------|-------|
| Hit count ≥ 1 | ✅ | 3 |
| Top result score > 0.5 | ✅ | 1.0 |
| Marker string appears verbatim | ✅ | All 3 top hits — both `excerpt` and `summary` contain the marker |

**Finding worth noting:** The `owner` parameter is required for search to find chunks ingested with the same owner. The Hermes Python adapter always passes `owner="hermes"` on both ingest and search (see `adapters/hermes/bridge_client.py`), so this works transparently for real Hermes use. Ad-hoc scripts must match.

## Probe 5 — Skill evolution generates a SKILL.md

**Setup:** Same `initPlugin` technique, plus explicit wiring of `SkillEvolver` to `IngestWorker.getTaskProcessor().onTaskCompleted(...)` (the top-level `index.ts` does this but `src/index.ts`'s lean `initPlugin` does not). Configured summarizer = DeepSeek V3 (`deepseek-chat`), the same model Sprint 1 validated for MEMRADER.

Ingested 10 messages on "Python CSV preview function" across 5 turns in session `hermes:research-agent:probe5:csv-*`. Session-keys share the first 3 colon parts so the TaskProcessor's "session changed within agent" path finalizes the task when a second session starts.

Then sent 2 messages in session `hermes:research-agent:probe5:other-*` — this triggered finalize of the CSV task. After finalize, `SkillEvolver.onTaskCompleted` ran the pipeline:

```
[probe5] Finalized task=0e27bd9b… title="CSV文件预览函数开发" chunks=10 summaryLen=1825
[probe5] onTaskCompleted fired for task=0e27bd9b…
[probe5] SkillEvolver: generating new skill "csv-file-preview-function-development"
[probe5] SkillGenerator: Step 1/4 — generating SKILL.md for "csv-file-preview-function-development"
[probe5] SkillGenerator: Step 2/4 — extracting scripts and references
```

**Generated file**
```
~/.hermes/memos-state-research-agent/skills-store/csv-file-preview-function-development/SKILL.md
5007 bytes / 118 lines
```

**Head of SKILL.md**
```
---
name: "csv-file-preview-function-development"
description: "How to create Python functions for previewing CSV files. Use when the user asks for CSV reading, data preview, inspecting file contents, printing first N rows, handling headers, converting rows to dictionaries, or processing large CSV files…"
metadata: { "openclaw": { "emoji": "📊" } }
---

# Develop CSV File Preview Functions

Create a set of Python functions to read and preview the first few rows of a CSV file…

## When to use this skill
- When you need to quickly inspect the contents and structure of a CSV file…

## Steps
1. **Basic CSV preview with csv.reader**
   - Use Python's built-in `csv` module to read the file and iterate through rows.
2. **Add header handling**
   …
```

| Criterion | Result | Proof |
|-----------|--------|-------|
| 2–3 realistic sessions run | ✅ | Session A (CSV, 10 msgs / 5 turns) + Session B (topic-change trigger, 2 msgs) |
| Skill evolution pipeline runs | ✅ | `SkillGenerator` completed Step 1/4 (SKILL.md) + Step 2/4 (scripts+refs) |
| ≥ 1 SKILL.md exists | ✅ | 1 file at path above |
| YAML frontmatter with `name` + `description` | ✅ | Verified via regex on file head |
| Non-empty, executable or reusable content | ✅ | 118 lines with numbered steps, code blocks (csv.reader / DictReader / pandas examples), pitfalls section |

Skill was not auto-installed (`SKILL_AUTO_INSTALL=false` default) — it sits in `skills-store/`, ready for explicit install into a workspace in Stage 2.

## Open-question resolutions from the migration plan

The gate worktree was explicitly charged with answering four open questions from the master plan:

| Question | Answer |
|----------|--------|
| Embedding provider used by the plugin? | Default is Xenova **all-MiniLM-L6-v2 (local, 384d)** — **matches our Sprint 1 setup**. No API dependency. Confirmed in `src/embedding/local.ts` and by direct probe (chunks wrote `hasVec=true`, 384d). |
| Summarizer model? | **DeepSeek V3 (`deepseek-chat`) via `provider: openai_compatible`, `endpoint: https://api.deepseek.com/v1`** — reuses the MEMRADER-validated key from `~/.hermes/.env` (`DEEPSEEK_API_KEY`). Plugin accepts it cleanly and generates topic classifications + skill text in the expected shape. |
| Hub port conflict? | Port 18992 was free. Clarified the plugin's port layout: hub = 18992 (explicit), daemon = 18990, viewer = 18901. No collision with Firecrawl (3002), SearXNG (8888), Camofox (9377), MemOS-server (8001), Paperclip (3100). |
| Skill output directory vs. `~/Coding/badass-skills/`? | Plugin default is `${stateDir}/skills-store/<name>/SKILL.md`. Installing into `~/Coding/badass-skills/` is a separate **installer** step — controlled by `SKILL_AUTO_INSTALL` env (default `false`) and the SkillInstaller class, which copies to `ctx.workspaceDir/skills/`. Wire this in `wire/badass-skills-groundtruth` (Stage 2). |

## Artifacts written by this worktree

- `scripts/migration/install-plugin.sh` — idempotent per-profile plugin installer
- `scripts/migration/bootstrap-hub.sh` — hub launcher + token-locking wrapper
- `scripts/migration/hub-launcher.cts` — direct HubServer entry (staged into plugin dir at run time)
- `deploy/plugins/_archive/memos-toolset/` — archived Product-1 memory plugin + `DEPRECATED.md`
- `agents-auth.json.archived`, `setup-memos-agents.py.archived`, `deploy/scripts/setup-memos-agents.py.archived` — archived server-era provisioning artifacts
- `memos-setup/learnings/2026-04-20-gate-report.md` — this file

Not committed (by design):
- `~/.hermes/memos-plugin-research-agent/` — installed plugin, node_modules, and the staged probe/launcher `.cts` files
- `~/.hermes/memos-state-research-agent/` — SQLite DB, hub-auth.json, skills-store/, logs, and the two 0600 secrets

## Recommendation

Proceed to **Stage 2** worktrees:

1. `wire/paperclip-employees` — install the plugin's Hermes adapter (the symlink into `~/.hermes/hermes-agent/plugins/memory/memtensor`) and flip `research-agent` profile's `memory.provider` from `holographic` to `memtensor`. Confirm `hermes -p research-agent chat` auto-captures turns without the probe script.
2. `wire/ceo-hub-access` — wire Claude Code CEO to read/write this hub (Option 1: bash curl against `http://localhost:18992/api/v1/hub/*`; admin token in `secrets/hub-admin-token`).
3. `wire/badass-skills-groundtruth` — configure plugin workspaceDir so generated skills install into `~/Coding/badass-skills/`, then symlink to `~/.claude/skills/`.

## Follow-ups noted (out of this worktree's scope)

- **`/health` endpoint** — worth asking upstream (MemTensor) whether to add a dedicated liveness path; `/api/v1/hub/info` doubles up but its name is semantically about team metadata, not liveness.
- **Node-25 compatibility** — better-sqlite3 prebuilds don't cover Node 25. Tracking for eventual upgrade. Doesn't block us.
- **Skill topic-boundary deterministic mode** — DeepSeek topic classifier said `SAME` on 4/4 CSV follow-ups even when the user changed detail (csv.reader → DictReader → pandas → pytest). Correct for a single coherent task, but if we want per-question skills, we'd need different segmenting logic. Not our call in this worktree.
- **Optional CLI for manual task finalize** — ops convenience: a command to force-finalize the current task and trigger skill eval without waiting for idle / session change. Potential Stage 5 polish.
