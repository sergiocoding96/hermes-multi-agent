# 2026-05-17 — v2-only memory, BGE-large embedder, refined share-scope policy

## TL;DR

After a session-long review of the memory stack, we made four architectural decisions:

1. **Drop Paperclip / CEO orchestration entirely.** No more orchestrator layer. Each Hermes agent runs independently on the single workstation (OS hostname `sergio`; Tailnet name `tower.taila4a33f.ts.net` — same machine).
2. **Commit to v2 (`@memtensor/memos-local-plugin`) as the sole memory backend.** Stop and disable v1 MemOS server. Stop the failing `memos-hub.service`. The v2 plugin's row-level namespace tuple gives us per-agent isolation without cubes.
3. **Switch the embedder to `Xenova/bge-large-en-v1.5`.** Benchmarked 3-way against MiniLM-L6-v2 (current) and `gemini-embedding-2` on 200 real traces × 8 LLM-judged queries. BGE-large won on every quality metric (P@5, MRR, nDCG@5) while staying local + free.
4. **Refine the share-scope policy:** `skills` and `world_model` are `local` (shared across agents); `traces`, `episodes`, and `policies` are `private`. The hub config knob (`hub.enabled`) was observed silently promoting new rows to `local` — flipping it to `false`.

## Why drop Paperclip / CEO

The CEO-orchestrator-of-workers pattern had two costs we weren't paying back:

- **Orchestration value** turned out to be marginal. Workers handle their own delegation through the plugin's `on_delegation` hook well enough that the CEO layer wasn't doing meaningful work.
- **Conceptual overhead.** Documentation, mental model, and a handful of code paths assumed a "Tower (CEO) vs sergio (workers)" split that never reflected the actual single-machine reality. The Tailnet DNS name `tower.taila4a33f.ts.net` is just a friendly alias for this same box; the OS hostname is `sergio`.

Dropping Paperclip simplifies the stack to one agent layer, one plugin daemon, one DB. Soft-improvement loop (feedback → skill patch) now happens directly.

## Why v2 over v1

We acknowledged the original v2 audit (2.4/10 in April) but re-evaluated based on:

- **v1 was unused all along.** Probed the running v1 server's `ceo-cube` — empty (`text_mem=[], total_nodes=0`). The `memos-toolset` v1 client had been disabled on 2026-05-12. Months of "v1 is the production target" were never reflected in actual writes.
- **v2 has the UX wins we want.** UI at `:18800` with Memories / Skills / Policies / World-model views, per-agent filtering, episode timeline, log viewer, evolution timeline. None of this exists in v1.
- **Auto-skill crystallisation is novel.** L2 candidate → trials → promoted skill is a real reinforcement-style learning pattern only v2 has.
- **Isolation works.** Per-profile row tagging confirmed on the live DB: `(hr-agent: 237, sergio: 96, mohammed: 63, research-agent: 7, email-marketing: 2)`. No `default` bucket, no contamination.

v1 stays installed at `/home/openclaw/Coding/MemOS/` and the `memos-server.service` is on disk (disabled). Rollback is `systemctl --user enable --now memos-server.service`.

## The embedder benchmark

**Methodology:** 200 real trace summaries pulled from the live DB (read-only), 8 realistic memory queries, top-5 retrieval per model, DeepSeek-V3 as graded-relevance judge (0/1/2 scale) over the union of retrievals.

**Aggregate metrics across 8 queries:**

| Model | Dim | P@5 | MRR | nDCG@5 | Where |
|---|---|---|---|---|---|
| MiniLM-L6-v2 | 384 | 0.450 | 0.688 | 0.628 | Local (Xenova) — current |
| **BGE-large-en-v1.5** | **1024** | **0.500** | **0.781** | **0.725** | **Local (Xenova) — picked** |
| gemini-embedding-2 | 3072 | 0.425 | 0.750 | 0.662 | Google AI Studio API |

Margins for BGE-large: +11% P@5 / +14% MRR / +15% nDCG@5 over MiniLM; +18% P@5 / +4% MRR / +10% nDCG@5 over Gemini-2.

**Why not Gemini-2:** quality lower than BGE on every quality metric. The similarity-score gap (top-1 0.753 vs BGE 0.689) is a vector-space artefact, not a quality signal. Gemini's only practical advantage — multimodal — isn't used by our pipeline today.

**Why not MiniMax embeddings:** their embeddings endpoint uses `texts` + `type` body shape, not OpenAI-compatible `input`. Couldn't drop into the plugin's `openai_compatible` provider without a code patch.

**Eval harness:** `/tmp/embed-eval/metrics3.py` — keep as a reusable benchmark for future model swaps.

## Why not the lighter BGE variants

Considered but didn't benchmark:
- `BGE-base-en-v1.5` (768d, ~550 MB working set) — ~1% MTEB worse than large, 3× less RAM
- `BGE-small-en-v1.5` (384d, ~200 MB) — ~3% worse, 7× less RAM

Sergio's machine has 15 GB total / ~9 GB free at idle. BGE-large's ~1.5 GB working set is well within budget, ~200ms CPU embedding latency is fine for async post-turn writes. Picked large for the quality.

## Share-scope policy

The plugin's `isVisibleTo` rule (`core/runtime/namespace.ts:136`) treats any non-`private` scope as "visible to all callers." Currently all `traces`/`policies`/`world_model`/`skills` rows have `share_scope='local'` — meaning every agent can read every other agent's everything. Only `episodes` are `private` (correctly).

We don't want full cross-agent transparency:

- **Traces** are literal user/agent conversation turns — leak personal context wholesale.
- **Episodes** are session summaries — leak what each user was working on.
- **Policies** are L2 candidates under trial — half-formed hypotheses, not validated knowledge.

We do want:

- **Skills** shared — they're the validated procedural output of the crystallisation pipeline, the deliberately-distilled layer.
- **World_model** shared — facts about the environment + (less ideal) operator. Caveat: world_model mixes universal facts ("MemOS server is at :8001") with operator-specific facts ("Sergio prefers concise answers"). If shared skills misfire because they reference operator-specific facts the receiving agent doesn't have, we'll add a `fact_kind: environment | operator` flag and split visibility per kind. Not doing that today.

### SQL to land the policy

```sql
UPDATE traces   SET share_scope='private', shared_at=NULL, share_target=NULL;
UPDATE episodes SET share_scope='private', shared_at=NULL, share_target=NULL;
UPDATE policies SET share_scope='private', shared_at=NULL, share_target=NULL;
-- world_model + skills stay 'local' (already correct)
```

### Auto-promote — root cause found and fixed (2026-05-17)

After running the SQL we repeatedly saw `share_scope` revert from `private` back to `local`. Hunted it through every code path in the v2 plugin: `core/capture/`, `core/memory/l2/`, `core/memory/l3/`, `core/skill/`, `core/storage/repos/*`, `core/runtime/namespace.ts`. Every write path *correctly* preserves share scope via `normalizeShareForStorage(row.share?.scope)`. No event subscriber re-shares on the bus. The Python adapter doesn't pass a share field. `hub.enabled: true` was a false lead.

Forensic SQLite triggers (`tools/forensic-audit.sql`) caught the culprit in the act: at 04:30:01 we saw two `traces` rows transition `private → local` via direct `UPDATE` statements (not via the daemon's HTTP `/share` endpoint, which would have logged differently).

The culprit was an **out-of-band cron job** added during Sprint 3:

```cron
# Original (added 2026-05-12, disabled 2026-05-17):
*/15 * * * * /home/openclaw/Coding/Hermes/.claude/worktrees/nice-mclaren-13f017/scripts/promote-memos-shares.py \
  >> /home/openclaw/.hermes/memos-plugin/logs/promote.log 2>&1
```

The script's docstring is self-incriminating: *"For each artifact type that supports sharing in 2.0 …, find rows that are still `private` across ALL profiles and promote them to `share_scope='local'` so all Hermes profiles on this host (including sergio's orchestrator) can read them."* — and *"To work around [HTTP API namespace enforcement], the promoter writes directly to the SQLite store."*

This was correct behavior **for the old architecture** where sergio's orchestrator (Paperclip/CEO) needed cross-profile read. With Paperclip/CEO retired today, the script is actively defeating the per-agent isolation we want.

**Fix applied:** crontab line commented out with a `# DISABLED 2026-05-17 …` prefix. The script file remains on disk (in a Claude worktree from a different branch) — kept as a forensic artifact for this decision doc. To remove fully: `rm -rf /home/openclaw/Coding/Hermes/.claude/worktrees/nice-mclaren-13f017/` (it's an orphan worktree, deletion is safe).

A `@weekly` `check-memos-plugin-update.sh` line from the same worktree was disabled at the same time for the same reason — orphan Sprint 3 artifact.

### Forensic audit (kept for future)

`tools/forensic-audit.sql` installs `AFTER INSERT/UPDATE` triggers on `traces`, `policies`, `episodes` that record every share_scope write to a `share_scope_audit` side table without modifying behavior. Useful next time we observe unexpected scope drift. Apply / inspect / remove:

```bash
sqlite3 ~/.hermes/memos-plugin/data/memos.db < tools/forensic-audit.sql
python3.12 tools/memos-explorer.py audit --since 1h
sqlite3 ~/.hermes/memos-plugin/data/memos.db < tools/forensic-audit.down.sql   # uninstall
```

## Model assignment by role

| Role | Model | Why |
|---|---|---|
| Memory LLM (extraction / summarisation / injection) | DeepSeek V3 (`deepseek-chat`) | Non-thinking model. MiniMax's `<think>` tags break the extraction parser. Constrained generation — bigger isn't better. |
| Skill crystallisation (`skillEvolver`) | MiniMax M2.7 (Anthropic-compatible endpoint) | Synthesis-heavy. Reasoning helps. Output post-processed into YAML — `<think>` blocks get stripped cleanly. Lower call frequency → cost matters less. |
| Embedder | `Xenova/bge-large-en-v1.5` | See benchmark above. Local, free, top of measured quality. |

## What got removed / disabled

- `memos-server.service` — `systemctl --user stop memos-server.service && systemctl --user disable memos-server.service`. v1 plugin server, cube was empty. Free Qdrant + Neo4j + Python RAM.
- `memos-hub.service` — `systemctl --user stop memos-hub.service && systemctl --user disable memos-hub.service`. Was thrashing in auto-restart loop attempting to spawn hub mode the plugin doesn't implement upstream.
- Paperclip / CEO setup — operationally retired. No code change in this repo today; the Paperclip side is left as-is on Tower for archaeological reference.
- v2 `gemini-embedding-2` config — briefly swapped in during the embedder eval, replaced by BGE-large before any data was written.

## Rollback path

If BGE-large embedding causes problems (latency, quality regression on real workload, OOM):

1. Edit `~/.hermes/memos-plugin/config.yaml` → set `embedding.model: Xenova/all-MiniLM-L6-v2`, `embedding.dimensions: 384`.
2. Wipe `~/.hermes/memos-plugin/data/memos.db` (dimensions changed — old vectors are unusable).
3. Restart Hermes agents — DB rebuilds with MiniLM.

If the share-scope tightening causes problems (skills can't find context, world_model lookups fail):

1. `UPDATE <table> SET share_scope='local'` to revert one table at a time.
2. Don't revert all four — re-introduce sharing per-table until the problem disappears.

If v2 itself becomes unworkable:

1. `systemctl --user enable --now memos-server.service` brings v1 back.
2. Re-enable `memos-toolset` by renaming `plugin.yaml.disabled-2026-05-12` → `plugin.yaml`.
3. Restart agents — they pick up v1 cube writes via the toolset.
4. v2 plugin DB remains on disk and can be exported to v1 via a sync script if needed.

## On the "Tower" name

Earlier sprint docs referred to a separate "Tower" machine. There isn't one. The single workstation has OS hostname `sergio` and Tailnet DNS name `tower.taila4a33f.ts.net`. Tailscale Serve proxies tailnet HTTPS 443 → local `:18800`. Operators SSH in from other devices and almost always type the Tailnet name in browser URLs, so "Tower" is the more visible name in day-to-day use. Keep the Tailnet alias; ignore the prior assumption that it was a different host.

```bash
# Verify any time:
hostname                                                # → sergio
tailscale status --self --json | jq -r .Self.DNSName    # → tower.taila4a33f.ts.net.
tailscale serve status                                  # → / proxy http://127.0.0.1:18800
```

## Cross-agent visibility — two complementary paths

### Path 1 — bundled-viewer overlay (recommended for browsing)

The v2 plugin's built-in viewer is bound to one namespace at daemon startup, and its HTTP API enforces that namespace on every list / search. Two patches solve this without running multiple daemons:

- **Server side:** A per-request namespace override threaded through Node's `AsyncLocalStorage`. The HTTP dispatch layer parses `?as_profile=<id>` (URL) or `X-As-Profile: <id>` (header) on every request and wraps the handler in `runWithRequestNamespace(ns, …)`. Visibility helpers (`visibleToCurrent`, `ownedByCurrent`) and the paginated turn-key SQL (`listTurnKeys`, `countTurns`) read the ALS namespace via `effectiveNamespace()` and apply it. See `core/runtime/request-namespace.ts` (new) and the diffs in `core/pipeline/memory-core.ts`, `core/storage/repos/traces.ts`, `server/http.ts`.
- **Client side:** A small overlay script (`web/dist/hermes-profile-switcher.js`) added via one `<script>` tag in `index.html`. It fetches `/api/v1/diag/namespace`, renders a floating "VIEW AS [profile ▾]" picker top-right, persists the choice in `localStorage`, and patches `window.fetch` to attach `X-As-Profile`. Works on every tab — Memories, Tasks, Experiences, Skills — without modifying the React bundle.

All patches live under `tools/plugin-patches/` in this repo and are applied/verified by `tools/postinstall-patches.sh`. Run after every `npm install/update` of the plugin.

### Path 2 — direct-SQLite CLI explorer

For batch operations, scripting, and the UMAP visualisation, `tools/memos-explorer.py` reads `~/.hermes/memos-plugin/data/memos.db` directly. Bypasses the daemon entirely.

```bash
python3.12 tools/memos-explorer.py profiles                        # per-profile row counts
python3.12 tools/memos-explorer.py traces hr-agent --limit 20      # one agent's traces, fully isolated
python3.12 tools/memos-explorer.py skills                          # shared skills with originating profile
python3.12 tools/memos-explorer.py policies sergio                 # one agent's policies
python3.12 tools/memos-explorer.py world                           # shared world_model entries
python3.12 tools/memos-explorer.py vec-stats                       # embedding dim/coverage stats
python3.12 tools/memos-explorer.py search "memory architecture"    # semantic search across all traces via BGE-large
python3.12 tools/memos-explorer.py audit --since 1h                # share_scope_audit log

# Interactive UMAP visualisation:
~/.hermes/tools-venv/bin/python tools/memos-explorer.py project \
   --out tools/vec-map.png --json tools/vec-map.json
# Then open: https://tower.taila4a33f.ts.net/umap-viewer.html
```

### Interactive UMAP viewers

Three viewers, increasing in richness:

| File | Backend | Data | URL |
|---|---|---|---|
| `tools/umap-viewer.html` | Plotly.js (2D scatter) | `vec-map.json` (traces only) | `/umap-viewer.html` |
| `tools/umap-3d-viewer.html` | deck.gl (3D scatter) | `vec-map-3d.json` (traces only) | `/umap-3d-viewer.html` |
| **`tools/memory-map.html`** | **deck.gl (3D)** | **`memory-graph.json` (full graph)** | **`/memory-map.html`** (also as sidebar tab in the bundled viewer) |

The full **Memory Map** viewer renders **all four artifact kinds** (traces ↘ policies ↘ world_model ↘ skills) at distinct Z levels showing the L1 → L2 → L3 abstraction hierarchy vertically, with **lineage edges** between them (policy ↗ source traces, skill ↗ source policies, etc.). Each profile gets a "View as" pill at the top; clicking a pill focuses on that agent's slice and dims the rest. Layer checkboxes let you peel away L1/L2/L3 to study just one. Clicking a node lights up its full lineage chain (source policies / source traces of a skill, etc.).

Implementation: a single joint UMAP fit over all artifacts (traces + policies + skills + world_model) — so cross-kind semantic neighbours sit vertically aligned. Z is assigned by kind. For artifact rows missing a stored embedding vector (most policies/skills/world_model on first run), the explorer embeds them on the fly via BGE-large.

Generate the data, then open:

```bash
# Full memory graph (recommended)
~/.hermes/tools-venv/bin/python tools/memos-explorer.py graph-export \
   --out tools/memory-graph.json
# Open via the sidebar tab in the bundled viewer (the v2 plugin's
# left rail now shows a "Memory Map" icon), or directly:
xdg-open https://tower.taila4a33f.ts.net/memory-map.html

# Legacy trace-only viewers
~/.hermes/tools-venv/bin/python tools/memos-explorer.py project \
   --out tools/vec-map.png --json tools/vec-map.json                    # 2D
~/.hermes/tools-venv/bin/python tools/memos-explorer.py project --3d \
   --out tools/vec-map-3d.png --json tools/vec-map-3d.json              # 3D, traces only
```

The "Memory Map" sidebar tab is injected by `web/dist/hermes-profile-switcher.js` (the same overlay that runs the view-as toggle) — it MutationObserver-watches the React app's sidebar and adds an `<a href="/memory-map.html">` next to the built-in icons.

## Shared-skill attribution patch (applied 2026-05-17)

When a Hermes agent retrieves a shared skill (one crystallised by a different profile), the LLM prompt should carry the originating profile so it can reason about who learned it. Audit found this attribution missing — the rendered prompt only carried the bare skill name. Four-file surgical patch applied in place in `~/.hermes/memos-plugin/`:

| File | Change |
|---|---|
| `core/retrieval/types.ts` | Added optional `ownerProfileId` + `ownerAgentKind` to `SkillCandidate` (line ~116) |
| `core/retrieval/tier1-skill.ts` | Wired `ownerProfileId` / `ownerAgentKind` from `sk` (SkillRow) into the candidate (line ~177) |
| `core/pipeline/retrieval-repos.ts` | Passed owner fields through `wrapRetrievalRepos.skills.getById()` — it had been stripping them when projecting the row to the retrieval-shape DTO |
| `core/retrieval/injector.ts` | `renderSkill()` appends ` (learned by ${ownerProfileId})` to the skill title; `renderNumberedSnippet` then includes it in `## Candidate skills` |

Verified end-to-end via the daemon HTTP API:

```bash
curl -s -b /tmp/memos-cookie.txt -X POST http://localhost:18800/api/v1/memory/search \
  -H "Content-Type: application/json" \
  -d '{"query":"is this RAM part with FPR suffix compatible","limit":3}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['injectedContext'])"
```

Output now contains `1. confirm_fpr_part_compatibility (learned by sergio)`. Before patch: bare name only.

**Tech-debt risk addressed by `tools/postinstall-patches.sh`:** the patched files live inside an installed npm package (`@memtensor/memos-local-plugin@2.0.0`) and would be wiped on `npm update`. The script copies our staged versions from `tools/plugin-patches/` back into the plugin install dir and verifies via marker strings. Run after every `npm install/update`:

```bash
bash tools/postinstall-patches.sh           # apply (idempotent)
bash tools/postinstall-patches.sh --check   # verify only, exits 0/1
```

Each modified file also carries a `Added 2026-05-17` comment so `grep -r` finds the integration points if the patches drift from upstream.

## Skill packager — default scope = local (applied 2026-05-17)

Fresh crystallisations were landing `share_scope='private'` because `packager.ts` built the `SkillRow` without a `share` field — `normalizeShareForStorage(undefined)` returns `'private'`. Patched `core/skill/packager.ts` to set `share: existing?.share ?? { scope: 'local', target: null, sharedAt: now }` so newly-minted skills join the shared layer at write time. Rebuilt skills preserve their previous share state (in case a user explicitly demoted one). Patch staged in `tools/plugin-patches/core/skill/packager.ts` and verified by `postinstall-patches.sh`.

## Named-speaker summaries — multi-human (applied 2026-05-17)

The capture-pipeline summarizer's system prompt explicitly said *"Do NOT prefix with 'The user said'"* — so summaries landed as generic *"User asks about embedding choice"*, *"User confirmed no file at path"*. That's bad for retrieval signal: every user prompt from every human collapses into a near-identical embedding region.

We patched `core/capture/summarizer.ts` to read a **`MEMOS_HUMANS`** list from the environment and, when set, inject a speaker-attribution rule into the system prompt. The messaging gateway already prepends each message with a handle marker like `[sergiopalacio96] hey can you…`, so the LLM has the raw signal to identify the speaker — we just hand it the mapping from handle → human name and tell it to use the name.

**Format** (in `~/.hermes/.env`):

```bash
MEMOS_HUMANS=Sergio:sergiopalacio96|sergiop,Krati,Mohammed:moh,Arinze
```

- Comma-separated entries.
- Optional `:handle1|handle2|...` after each name = messaging-platform identifiers the gateway prepends to user_text.
- A name without handles still works — the LLM falls back on context or just omits the speaker if it can't tell.
- Legacy `MEMOS_HUMAN_NAME=Sergio` is honored as a single-entry fallback.

**This list is NOT a closed roster.** Agents receive messages from outside parties — clients, leads, group chats, quoted email — and the prompt explicitly tells the LLM to use whatever name appears in the message (handle prefix, self-introduction, or quoted byline) regardless of whether that person is on the list. The list is an *alias map*: when an opaque handle like `sergiopalacio96` appears, resolve to the friendly name `Sergio`. When an unknown handle like `[anna@acme.io]` appears, use it verbatim (so the summary reads *"Anna asked about pricing"*, not *"User asked about pricing"*). If no name signal is in the message at all, omit the speaker reference entirely — never invent one.

**Resulting prompt fragment:**

> *"The humans in this team are: Sergio (messaging handle: sergiopalacio96); Krati; Mohammed; Arinze. The USER block is one message from one of those humans. It may be prefixed with a handle marker like `[sergiopalacio96]` — match against the handles above and use the corresponding human name in the summary (e.g. "Sergio asked about X", "Krati noted Y"). If you cannot confidently identify the speaker, omit the speaker reference entirely — never invent a speaker."*

Result: summaries now read *"Sergio prefers BGE-large over MiniLM"* and *"Krati asked about embedding benchmarks"* instead of generic *"User …"*. Identity reaches the embedding space → sharper retrieval ranking + cleaner attribution when skills crystallise from these traces.

The plugin's daemon doesn't natively read `.env` files — systemd units set `Environment=` directives explicitly, and the manual-spawn / Python-adapter paths inherit shell env. So we also added a tiny dotenv loader to `bridge.cts` that reads `~/.hermes/.env` and `~/.hermes/memos-plugin/.env` at startup (existing `process.env` values aren't overridden, so explicit systemd directives still win).

**Adding a new human:** append to the `MEMOS_HUMANS` line in `~/.hermes/.env` and restart the daemon (`pkill -9 -f memos-plugin/bridge.cts && ./postinstall-patches.sh` will respawn). If the new human has a known Discord/Telegram handle, list it after `:`.

**Open follow-up:** re-summarising the old "User asks…" traces with the new prompt is optional. It'd require triggering capture.reflect again on each historical episode. Skipped for now; new captures from this point on use named attribution.

## Cluster summarisation + auto-refresh watcher (applied 2026-05-17)

Two operational follow-ups landed end of day:

**1. Cluster topic labels.** `memos-explorer.py graph-export` now runs HDBSCAN on the joint UMAP coordinates, picks the top ~6 most-representative member snippets per cluster, and sends them to DeepSeek (`deepseek-chat`) with the prompt *"reply with a single 4-6 word noun phrase that captures the single topic they share."* Labels are stored in `memory-graph.json` on each cluster object (`clusters[clusterId].label`) and rendered by `memory-map.html` via a deck.gl `TextLayer` — gold background + bigger size for **cross-agent clusters** (the actually-useful "shared knowledge" view), washed-out blue for solo-agent clusters. A "Labels On/Off" toggle hides them when the canvas gets busy. Latest run: **36/36 cross-agent clusters labelled** with topics like *"Hermes system file searches"*, *"RAM upgrade advice and specifications"*, *"MemOS hub mode configuration issues"*, *"Agent memory isolation and scoping"*. ~36 DeepSeek calls, <10s, ~$0.001 per regen. Helper code: `label_clusters()` in `memos-explorer.py`; viewer code: `buildClusterLabels()` in `memory-map.html`.

**2. Auto-refresh watcher.** `memory-graph.json` is **not** regenerated on every memos write — that would queue a 40–60s BGE-large embedding + UMAP fit + 36 DeepSeek calls per turn. Instead a small Python daemon watches `~/.hermes/memos-plugin/data/memos.db-wal` (SQLite's write-ahead log, which mutates on every plugin write) and triggers a regen once activity has been quiet for 5 minutes, with a 15-minute floor between regens so bursts don't thrash.

| Component | Path |
|---|---|
| Daemon | `tools/memory-graph-watcher.py` |
| Systemd unit | `~/.config/systemd/user/memory-graph-watcher.service` |
| Logs | `journalctl --user -u memory-graph-watcher -f` |

```bash
# Manage the watcher
systemctl --user status memory-graph-watcher
systemctl --user restart memory-graph-watcher
journalctl --user -u memory-graph-watcher -n 30 --no-pager

# Force a one-off regen (skips watcher path)
~/.hermes/tools-venv/bin/python tools/memos-explorer.py graph-export \
   --out tools/memory-graph.json
```

Tuning lives at the top of `memory-graph-watcher.py`: `POLL_INTERVAL=5s`, `DEBOUNCE=5min`, `MIN_INTERVAL=15min`, `STARTUP_SETTLE=30s`. The startup-settle delay prevents a spurious regen if the daemon comes back after a reboot and the WAL file looks "new" even though no real write happened.

## Open follow-ups

- Once we're confident the disabled cron stays disabled across a few real conversation cycles, drop the orphan worktree (`rm -rf /home/openclaw/Coding/Hermes/.claude/worktrees/nice-mclaren-13f017/`).
- If world_model sharing causes leakage, add `fact_kind: environment | operator` and split.
- Re-summarise pre-2026-05-17 traces (currently "User asks…") with the named-speaker prompt so historical embeddings benefit from the speaker signal too.

## Cross-references

- Pinned in CLAUDE.md `🚨 Active sprint` header
- Deck: [`docs/architecture/2026-05-17-memory-system-decisions.pptx`](../../docs/architecture/2026-05-17-memory-system-decisions.pptx)
- Supersedes: [`2026-04-28-collapse-to-single-tier-memos.md`](2026-04-28-collapse-to-single-tier-memos.md), [`2026-04-27-v2-deprecated-revert-to-v1.md`](2026-04-27-v2-deprecated-revert-to-v1.md)
