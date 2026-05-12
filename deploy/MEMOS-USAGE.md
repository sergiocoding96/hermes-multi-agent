# Memory system — usage guide (2.0)

> **Date this was written:** 2026-05-12 (Sprint 3)
> **Plugin version:** `@memtensor/memos-local-plugin@2.0.0`
> **Upstream:** github.com/MemTensor/MemOS — `apps/memos-local-plugin/`

Companion docs:
- Architecture decision: [`memos-setup/learnings/2026-05-11-remove-hub-and-paperclip-ceo.md`](../memos-setup/learnings/2026-05-11-remove-hub-and-paperclip-ceo.md)
- 2.0 migration decision: [`memos-setup/learnings/2026-05-12-migrate-to-memos-local-plugin-2.0.md`](../memos-setup/learnings/2026-05-12-migrate-to-memos-local-plugin-2.0.md)

---

## TL;DR

| Question | Answer |
|---|---|
| Where is the viewer? | https://tower.taila4a33f.ts.net/ (Tailscale, tailnet-only) — or http://127.0.0.1:18800 on the host |
| Where do agents write memory? | Nowhere explicitly. Capture is automatic. |
| Where does the data live? | `~/.hermes/memos-plugin/data/memos.db` (one SQLite, all profiles, namespace-tagged) |
| Which agents are on 2.0? | All 6 Hermes profiles: `arinze`, `email-marketing`, `hr-agent`, `mohammed`, `research-agent`, `sergio` |
| How does cross-agent sharing work? | A cron (every 15 min) promotes new traces / policies / skills / world-models to `share_scope='local'` so every profile sees them. Raw private rows stay private. |
| Who can see across cubes? | All profiles can see the shared (`local`-scoped) pool. `sergio` additionally has a `cross-cube-read` skill for debugging private rows. |
| How do I upgrade? | Run `bash install.sh --version X.Y.Z` against a new tarball. Data, config, skills, logs all preserved. |
| How do I know upgrades exist? | Weekly cron checks npm and emits a notice when a newer stable is available. |

---

## The mental model

Two layers of memory per agent:

**Diary (private, automatic):**
Every turn an agent takes is captured into an L1 trace by the memtensor provider. The trace includes user input, agent response, the agent's reflection on its own choice, an attention weight (alpha), and a value estimate. The agent doesn't write this — the system does. The diary is **invisible** to other agents.

**Bulletin board (shared pool):**
A cron job (`scripts/promote-memos-shares.py`) runs every 15 minutes and marks new traces, policies, skills, and world-models as `share_scope='local'`. That makes them visible to every other Hermes profile on the host. The bulletin board is the orchestration substrate — sergio and the other agents read it via the normal `memory_search` tool.

The four memory layers in the plugin:

| Layer | What it is | Created when | Shared? |
|---|---|---|---|
| **L1 trace** | One row per agent turn (user_text, agent_text, summary, reflection, alpha, value) | Every turn, automatic | Promoted to `local` after ≤15 min |
| **Episode** | A session of related traces, with a summary preview and `r_task` reward | When a task closes | NOT shareable (no /share endpoint in 2.0) — but its constituent traces are |
| **L2 policy** | An induced strategy across many traces | When the reward pipeline finds a pattern | Promoted to `local` |
| **Skill** | A crystallized, callable capability | When a policy has proven itself with enough reward + support | Promoted to `local` |
| **L3 world model** | Compressed environmental cognition | Rare, aggregation pass | Promoted to `local` |

---

## What changed in Sprint 3 (2026-05-12)

| Change | Reason |
|---|---|
| Global `memory.provider: holographic` → `memtensor` | Switch to 2.0 plugin |
| `memos-toolset` plugin disabled (renamed `plugin.yaml` → `plugin.yaml.disabled-2026-05-12`) | Auto-capture replaces explicit POSTs |
| "MemOS Write Obligations" block stripped from `research-agent` and `email-marketing` SOULs | Same — agents no longer need to call `memos_store` |
| Cron entry `*/15` added: `promote-memos-shares.py` | Trickle high-signal rows into the shared pool |
| Cron entry `@weekly` added: `check-memos-plugin-update.sh` | Notify when upstream ships a new stable |
| Tailscale Serve mapped `https://tower.taila4a33f.ts.net/` → `:18800` | Tailnet UI access |
| Sergio gets a `cross-cube-read` skill | Escape hatch to read other agents' private traces for debugging |
| Stale cron entries removed: `refresh-ceo-token.sh`, `hub-sync.py` | Referred to scripts already deleted |

The V1 stack (MemOS server at `localhost:8001`, Qdrant, Neo4j) is **still running** — left up for one week as a safety net. Shutdown procedure documented separately.

---

## Day-to-day usage

### As a worker agent (research-agent, email-marketing, etc.)

You don't do anything. Memory is automatic. Your SOUL no longer requires `memos_store` calls. Focus on doing the task; the capture pipeline handles the rest.

If you want to recall something from your past work:

```
memory_search(query="...")     # semantic search across your private + the shared pool
memory_timeline(episode_id=...)  # full turn-by-turn for one past task
skill_list()                     # what skills exist (yours + shared)
```

You **cannot** see another agent's private traces. Once promoted to `local` (within 15 min), you can.

### As sergio (the orchestrator)

Same tools as the worker agents, but `memory_search` will surface results from **every** profile that has promoted material. The bulletin board is yours by default.

If you need to look at another agent's *private* memory (raw diary), use the `cross-cube-read` skill:

```bash
# Who is in the store?
python3 ~/.hermes/profiles/sergio/skills/cross-cube-read/peek.py profiles

# Full-text search across all profiles (private + shared)
python3 ~/.hermes/profiles/sergio/skills/cross-cube-read/peek.py search "competitor pricing"

# Last N traces from a specific profile
python3 ~/.hermes/profiles/sergio/skills/cross-cube-read/peek.py timeline research-agent 20

# Full timeline of one episode
python3 ~/.hermes/profiles/sergio/skills/cross-cube-read/peek.py episode ep_7s382nyfjcbs
```

But prefer the indirect path: **ask the source agent via Hermes Kanban**. Dispatching a task back to research-agent ("give me your timeline for episode X") gives you an answer with full context. Direct DB reads bypass the agent's framing.

### Viewing in the browser

From any device on your tailnet, open:

```
https://tower.taila4a33f.ts.net/
```

The viewer shows traces, episodes, policies, skills, world models, and api logs. The active namespace defaults to whatever profile last touched the bridge — switch profiles in the top-right.

From this host directly: http://127.0.0.1:18800

---

## Operations

### File layout

```
~/.hermes/memos-plugin/           # plugin runtime home — installer never touches data/, config.yaml, skills/, logs/
├── config.yaml                   # chmod 600 — LLM provider, embedder, viewer port
├── data/memos.db                 # SQLite (L1 traces, episodes, policies, skills, world model, sessions)
├── skills/                       # crystallized skill packages
├── logs/                         # memos.log, error.log, audit.log, llm.jsonl, perf.jsonl, daemon-start.log, promote.log, update-check.log
└── daemon/                       # bridge pid/port files

~/.hermes/hermes-agent/plugins/memory/memtensor → symlink to ~/.hermes/memos-plugin/adapters/hermes/memos_provider
~/.hermes/plugins/memos-toolset/plugin.yaml.disabled-2026-05-12   # V1 toolset (deprecated)

scripts/promote-memos-shares.py         # cron: promote synthesis layer to 'local'
scripts/check-memos-plugin-update.sh    # cron: weekly npm version check
~/.hermes/profiles/sergio/skills/cross-cube-read/   # orchestrator escape hatch
```

### LLM + embedder

Plugin reflection / policy induction / skill crystallization use **DeepSeek V3** (`deepseek-chat`) via `openai_compatible` provider. Picked because MiniMax broke V1 MEMRADER with `<think>` tags — DeepSeek is the proven choice.

Embedder is **local sentence-transformers** (`Xenova/all-MiniLM-L6-v2`, 384-dim). No external API for embeddings.

Both configured in `~/.hermes/memos-plugin/config.yaml`. To rotate keys or switch providers, edit and **restart the bridge daemon**:

```bash
pkill -f "bridge.cts --agent=hermes"
# daemon respawns lazily on the next memory call from any agent
```

### Cron entries (live)

```
*/15 * * * * /home/openclaw/Coding/Hermes/scripts/promote-memos-shares.py >> ~/.hermes/memos-plugin/logs/promote.log 2>&1
@weekly /home/openclaw/Coding/Hermes/scripts/check-memos-plugin-update.sh >> ~/.hermes/memos-plugin/logs/update-check.log 2>&1
```

> **Worktree path note:** Until you merge this branch into main, the live
> crontab references the Claude Code worktree path
> (`/home/openclaw/Coding/Hermes/.claude/worktrees/nice-mclaren-13f017/scripts/...`).
> After merging + `git pull`, run **`bash scripts/post-merge-fixup.sh`** once to
> swap the cron paths to the canonical `/home/openclaw/Coding/Hermes/scripts/...`.
> Idempotent and non-destructive (backs up your crontab to /tmp first).

Tail logs:

```bash
tail -f ~/.hermes/memos-plugin/logs/promote.log     # promotion stats
tail -f ~/.hermes/memos-plugin/logs/update-check.log # version check (silent unless update available)
tail -f ~/.hermes/memos-plugin/logs/memos.log       # plugin runtime
```

### Health checks

```bash
# Bridge daemon up?
curl -sf http://127.0.0.1:18800/api/v1/ping | jq

# What's in the store?
curl -sf http://127.0.0.1:18800/api/v1/overview | jq

# Active bridge namespace + per-owner counts
curl -sf http://127.0.0.1:18800/api/v1/diag/namespace | jq
```

### Manual promotion (one-off)

```bash
# Promote everything now
~/Coding/Hermes/scripts/promote-memos-shares.py

# Dry run (show what would change, don't write)
~/Coding/Hermes/scripts/promote-memos-shares.py --dry

# Promote to a different scope
~/Coding/Hermes/scripts/promote-memos-shares.py --scope public  # or 'hub' (stub today)
```

---

## Upgrades

### Watching for new versions

Weekly cron emits a notice when npm has a newer stable. Tail `~/.hermes/memos-plugin/logs/update-check.log` periodically. Or run on demand:

```bash
~/Coding/Hermes/scripts/check-memos-plugin-update.sh
```

Output (when an update is available):
```
[2026-05-18T08:00:00+0000] memos-local-plugin update available: installed=2.0.0 latest=2.1.0
[2026-05-18T08:00:00+0000]   to upgrade: cd /tmp && npm pack @memtensor/memos-local-plugin@2.1.0 && tar -xzf memtensor-memos-local-plugin-2.1.0.tgz && bash package/install.sh --version 2.1.0
[2026-05-18T08:00:00+0000]   release notes: gh api repos/MemTensor/MemOS/releases/latest --jq .body | head -50
```

### Running the upgrade

```bash
# 1. Read release notes first
gh api repos/MemTensor/MemOS/releases/latest --jq .body | head -100

# 2. Stop the bridge daemon (in-flight ops drained on shutdown)
pkill -f "bridge.cts --agent=hermes"

# 3. Run the installer with the new version
cd /tmp
npm pack @memtensor/memos-local-plugin@<NEW_VERSION>
tar -xzf memtensor-memos-local-plugin-<NEW_VERSION>.tgz
bash package/install.sh --version <NEW_VERSION>

# 4. Verify
curl -sf http://127.0.0.1:18800/api/v1/overview | jq .version
~/Coding/Hermes/scripts/promote-memos-shares.py --dry  # smoke-test
```

The installer is idempotent. `data/memos.db`, `config.yaml`, `skills/`, `logs/` are explicitly preserved per upstream README.

### If an upgrade breaks something

1. Check `~/.hermes/memos-plugin/logs/memos.log` for errors after install
2. Try `~/Coding/Hermes/scripts/promote-memos-shares.py --dry` — confirms SQLite reads still work
3. If table/column was renamed, update `peek.py` and `promote-memos-shares.py` (both are small, schema-aware files in our repo)
4. Worst case: pin to last-known-good version via `bash install.sh --version 2.0.0` (the previous version)
5. Data is preserved across re-installs; rolling back is non-destructive

---

## Architecture details (for when you forget)

### Why per-profile isolation works with one shared DB

Every row carries `owner_agent_kind`, `owner_profile_id`, `share_scope`. Queries apply this WHERE clause:

```sql
WHERE (owner_agent_kind = @ns_agent AND owner_profile_id = @ns_profile)
   OR COALESCE(share_scope, 'private') IN ('local', 'public', 'hub')
```

The bridge daemon has an "active namespace" — typically whichever profile most recently made a memory call. Listing endpoints (`/api/v1/episodes` etc.) filter by this active namespace. That's why HTTP enumeration only sees one profile's content at a time — and why the promoter script reads SQLite directly to enumerate across all profiles.

### Why we promote traces and not episodes

Episodes have no `/share` endpoint in 2.0 (only traces, policies, skills, world-models do). Promoting the traces inside an episode effectively shares the episode contents. The episode's metadata stays scoped, but the content (which is in the traces) crosses.

### Why DeepSeek for the LLM

Earlier V1 MEMRADER extraction with MiniMax broke on `<think>` tags. DeepSeek doesn't emit those. Switching the plugin's reflection LLM to DeepSeek for apples-to-apples reliability. If a future stable handles MiniMax cleanly, swap back via `config.yaml`.

### Why `hub:` is off

The 2.0 hub runtime is a stub (see `server/routes/hub-admin.ts:10` — "the core/hub/ runtime is a stub, and wiring in real sync state is a separate phase"). When MemTensor ships hub sync, we'll evaluate.

---

## Open questions / future work

- **L2 policy + Skill crystallization in practice.** We have 1 trace and 0 policies / 0 skills today. The Reflect2Evolve loop should mint these as the workers accumulate traces with reward. We'll know if this works after 1-2 weeks of regular use.
- **Migration of V1 historical data.** The MemOS server cubes have ~2.7MB of legacy memories. No automated migration shipped today. Two options when the V1 shutdown happens: write a one-off script that POSTs each memory into the 2.0 store as a synthesized trace, or accept the V1 data as reference-only.
- **Hub mode for cross-host sharing.** Not configured today. Would let multiple machines pool memory. The `hub:` block in `config.yaml` exists but the runtime is a stub upstream.
- **Strictness of the promoter.** Currently permissive — every closed trace gets promoted. If the shared pool grows noisy, the promoter can gate on `summary IS NOT NULL` (system already declines to summarize short turns) or on `value >= 0.5`.
- **V1 server shutdown.** Docker stack (Qdrant + Neo4j + MemOS) still running. Will plan a deliberate shutdown in 1 week with a separate decision doc.
