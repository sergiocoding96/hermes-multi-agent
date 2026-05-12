# 2026-05-12 — Migrate all profiles to `@memtensor/memos-local-plugin@2.0.0`

## Decision

Replace the **V1 memory stack** (MemOS server v1.0.1 at `localhost:8001` + the deprecated `memos-toolset` Hermes plugin) with the **2.0 local plugin** (`@memtensor/memos-local-plugin@2.0.0`, npm-stable since 2026-05-09) for all six Hermes profiles on this host:

`arinze`, `email-marketing`, `hr-agent`, `mohammed`, `research-agent`, `sergio`.

V1 stack (Qdrant + Neo4j + SQLite + bcrypt-authed REST API) **stays running** for one week as a safety net. Shutdown to be planned in a separate decision doc.

## Why 2.0 over V1

| Axis | V1 (MemOS server + memos-toolset) | 2.0 (memos-local-plugin) |
|---|---|---|
| Failure modes that scored 2.4/10 in the 2026-04 audit (MEMRADER quality, sharing.role, JWT scoping, hub-sync) | Patched-on top of upstream via the fork | Gone by construction — different package, different design |
| Capture model | Agent must explicitly call `memos_store` after every task (30 lines of SOUL obligations) | Auto-capture per turn via memtensor provider; agent does nothing |
| Memory model | Flat cubes of text memories with MEMRADER extraction | L1 traces / L2 policies / L3 world model / Skills (Reflect2Evolve) |
| Operational footprint | 3 Docker containers + bcrypt provisioning + your security-patched fork | One SQLite + one Node bridge daemon |
| Upstream status | `memos-toolset` marked DEPRECATED.md 2026-04-20 by upstream | Actively iterated (8 betas in 12 days before 2.0.0 stable) |
| Cross-agent sharing | CompositeCubeView API (works) | `share_scope` field per row + cron promoter (works today) + `hub:` block (stub upstream) |

The pilot test on 2026-05-12 confirmed: from a single 12-second math chat, 2.0 captured a fully-structured trace (user_text, agent_text, summary, reflection, agent_thinking, value, alpha, priority, 384-dim embeddings) without any agent action. V1 captured **nothing** from the same prompt because the agent didn't call `memos_store`. The richness + auto-capture won the test.

## Architecture decisions

### Per-profile isolation
Shared `~/.hermes/memos-plugin/data/memos.db` SQLite, but every row tagged `owner_agent_kind` + `owner_profile_id`. The plugin's namespace filter enforces visibility: each profile sees only its own private rows + anything marked `share_scope IN ('local','public','hub')`.

### Cross-cube reading (Option A: shared pool, permissive)
A cron script (`scripts/promote-memos-shares.py`) runs every 15 min and promotes new traces, policies, skills, and world-models to `share_scope='local'`. That makes them visible to every profile. Raw private fields stay invisible to other profiles — only the promoted rows cross. (Within a single-user system, this is fine.)

Hybrid implementation: SQLite read for enumeration (the HTTP list endpoints filter by the bridge's active namespace, so can't enumerate cross-cube), HTTP POST for the actual share write (the upgrade-safe contract).

### Sergio's orchestrator role
Sergio's profile gets the same `memory_search` view as any other profile — which post-promotion includes the shared pool from every cube. Plus a dedicated `cross-cube-read` skill at `~/.hermes/profiles/sergio/skills/cross-cube-read/` that exposes a Python helper (`peek.py`) for read-only SQL access bypassing namespace filters. Use case: debugging another agent's private trace. Not for routine retrieval.

### Episodes don't cross
2.0.0 has no `POST /api/v1/episodes/:id/share`. Only traces, policies, skills, world-models support sharing. Since traces carry the per-turn `summary` field, promoting traces gives the "constant flow of synthesis" without needing episode-level sharing.

### Upgrade tracking
- Weekly cron checks npm for newer stable versions of `@memtensor/memos-local-plugin` (`scripts/check-memos-plugin-update.sh`). Silent unless an update lands.
- Upgrades are deliberate: read release notes, kill bridge, run `bash install.sh --version X.Y.Z`. Installer preserves `data/`, `config.yaml`, `skills/`, `logs/`.

### LLM for the plugin
DeepSeek V3 (`deepseek-chat`) via `openai_compatible` provider. Picked because MiniMax broke V1 MEMRADER with `<think>` tags. Configured in `~/.hermes/memos-plugin/config.yaml` (chmod 600).

## Concrete changes

### Plugin install
- `@memtensor/memos-local-plugin@2.0.0` installed at `~/.hermes/memos-plugin/`
- Bridge daemon running on `127.0.0.1:18800`
- Local embeddings (`Xenova/all-MiniLM-L6-v2`, 384-dim), DeepSeek for reflection
- Python adapter symlinked into `~/.hermes/hermes-agent/plugins/memory/memtensor`

### Config
- Global `~/.hermes/config.yaml`: `memory.provider: holographic → memtensor`
- `research-agent` profile: explicit `memtensor` removed → inherits from global
- Other 5 profiles: already `provider: ''` (inheriting from global)

### Disabled
- `~/.hermes/plugins/memos-toolset/plugin.yaml` → renamed to `plugin.yaml.disabled-2026-05-12`. All 4 profiles using it (arinze, email-marketing, mohammed, research-agent) auto-affected via shared symlink.

### SOUL edits
- `~/.hermes/profiles/research-agent/SOUL.md`: stripped "MemOS Write Obligations" block, replaced with "Memory" section explaining auto-capture
- `~/.hermes/profiles/email-marketing/SOUL.md`: same treatment
- Both copied to `deploy/profiles/*/SOUL.md` for git tracking
- The other 4 profiles had no obligations block to strip

### New files (in this repo)
- `scripts/promote-memos-shares.py` — cron promoter
- `scripts/check-memos-plugin-update.sh` — weekly version check
- `deploy/profiles/sergio/skills/cross-cube-read/{SKILL.md, peek.py}` — sergio's escape hatch
- `deploy/MEMOS-USAGE.md` — usage guide

### Live system changes (not in repo, but documented)
- `~/.hermes/profiles/sergio/skills/cross-cube-read/` — mirror of the repo skill
- Crontab: added 2 entries (`*/15 promote`, `@weekly update-check`); removed 2 stale entries (`refresh-ceo-token.sh`, `hub-sync.py` — scripts deleted in commit `66cae50`)
- Tailscale Serve: `https://tower.taila4a33f.ts.net/` → `http://127.0.0.1:18800` (tailnet-only)

### Gateway restarts
All 6 profile gateways restarted to pick up `memory.provider: memtensor`. New PIDs verified.

## What's NOT done

1. **V1 server shutdown.** Docker stack still running (Qdrant + Neo4j + MemOS server v1.0.1). Deliberate shutdown deferred 1 week — gives a clean rollback window if 2.0 surfaces issues.
2. **V1 historical data migration.** ~2.7MB of memories in V1 cubes. No migration script written. Two options when V1 shuts down: write a script that synthesizes V1 memories into 2.0 traces with `share_scope='local'`, or accept the V1 history as reference-only.
3. **Hub cross-host sharing.** Stub upstream. Will reconsider when MemTensor ships the runtime.

## Rollback

If 2.0 needs to be reverted:

```bash
# 1. Restore global config
edit ~/.hermes/config.yaml → memory.provider: holographic

# 2. Re-enable memos-toolset (single shared yaml)
mv ~/.hermes/plugins/memos-toolset/plugin.yaml.disabled-2026-05-12 \
   ~/.hermes/plugins/memos-toolset/plugin.yaml

# 3. Restore SOULs (revert this commit)
git revert <this-commit>
cp deploy/profiles/research-agent/SOUL.md ~/.hermes/profiles/research-agent/SOUL.md
cp deploy/profiles/email-marketing/SOUL.md ~/.hermes/profiles/email-marketing/SOUL.md

# 4. Remove the promoter cron + stop the bridge daemon
crontab -e  # delete the two memos-2.0 lines
pkill -f "bridge.cts --agent=hermes"

# 5. Restart all gateways
for p in arinze email-marketing hr-agent mohammed research-agent sergio; do
  hermes -p $p gateway restart
done
```

The MemOS server is untouched and still serves V1 reads/writes immediately.

## Pilot evidence

From the 2026-05-12 real test (math chat through research-agent on 2.0):

```sql
sqlite> SELECT id, owner_profile_id, share_scope FROM traces;
tr_kpkp6x77yvhf|research-agent|local
```

```
$ ~/Coding/Hermes/scripts/promote-memos-shares.py --dry
[dry] traces tr_kpkp6x77yvhf → local
[2026-05-12T20:40:28+0000] promoted (dry): traces=1 policies=0 skills=0 world_model=0
```

```
$ ~/.hermes/profiles/sergio/skills/cross-cube-read/peek.py profiles
[{"agentKind": "hermes", "profileId": "research-agent", "traceCount": 1, "lastTraceMs": 1778616000091}]
```

```
$ curl -sf http://127.0.0.1:18800/api/v1/overview | jq
{
  "ok": true, "version": "2.0.0",
  "episodes": 1, "traces": 1,
  "llm": {"provider": "openai_compatible", "model": "deepseek-chat"},
  "embedder": {"provider": "local", "model": "Xenova/all-MiniLM-L6-v2"}
}
```

All three layers (capture, promotion, cross-cube read) verified end-to-end on a single chat. Real-world signal is what accumulates over the coming weeks.
