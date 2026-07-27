# 2026-05-26 — Memory capture outage: RCA + recovery

**Status:** RESOLVED. Acute issues fixed (runaway purged, leak/spiral stopped, DB clean + VACUUMed, daemon healthy) **and** the durable fixes applied 2026-05-26: idempotency guard, raised bridge timeouts, safe band-aid scripts, and the `:18800` daemon promoted to a systemd unit. Final DB: ~324 traces (was 95,174 of which ~28k were dup re-inserts), file 1.8 GB → 566 MB. The deeper architecture options (B serialize boots / C shared single daemon) remain as future work — see "Durable fixes" below.

Operator reported the memory viewer "looked reset / broken — lost the last 3 weeks." Investigation showed **no data loss**; the perception came from three stacked problems plus an expectation gap.

## What was actually true

- **No deletion.** The v2 DB held 93,584→95,174 traces (1.87 GB), daemon reading the correct file. Nothing wiped.
- **Expectation gap.** This v2 store was *born* `2026-05-12 21:06` (the v2-only overhaul). There is no pre-05-12 history in it — earlier memory lived in the retired v1 MemOS (`~/Coding/MemOS/`, stopped 05-16). So "3 weeks ago" was never in this store.
- **Capture had been dying agent-by-agent** and was fully stopped: last trace per profile ranged hr-agent 05-16, mohammed 05-18, research 05-17, sergio/cto 05-25 02:xx, arinze/default 05-25 14:44 — zero after the 05-26 03:01 daemon restart.
- **UI overview rendered "—"** for all counts, reinforcing the "empty" impression (display, not data).

## Root causes (two distinct)

### 1. Runaway capture re-insert loop (arinze, 05-25)
Session `20260525_140424_68e686e2` / episode `ep_pen5q6ndmf8q` produced **65,741 trace rows for only 6 logical turns** (two turns re-inserted 33,840× and 31,318×; 64,957 were empty `(empty turn)` duplicates; ~233 MB of duplicated `tool_calls_json`).

Chain: arinze ran a Spanish-business lead-gen task → `web_search` entered a tool-failure retry loop → the memory capture call `subagent.record` **timed out at 30s** repeatedly → each timeout **re-inserted the same turn with no idempotency on `turn_id`**.

**Token cost was trivial** (this was a DB re-insert bug, not a token burn): per arinze's `state.db`, the session was 30 API calls, 83,190 in / 13,010 out / 1,160,960 cache-read tokens, **est. $0.0115**. The damage was storage/IO and pipeline health, not money.

Underlying bug: **capture retry is not idempotent on `turn_id`** — a timed-out `subagent.record` re-inserts instead of upserting.

### 2. Bridge cold-boot CPU death-spiral (the capture-stoppage + process leak)
Each Hermes gateway's `memos_provider` spawns a **full `bridge.cts` memos instance that cold-loads the local BGE-large embedding model** (~2 CPU cores, tens of seconds). When several gateways boot at once (e.g. after a restart) the model loads **starve the CPU so no single boot completes** before the bridge RPC timeouts fire:
- initial `session.open` default **30s** (`_open_session`/`_reconnect_bridge`/`_ensure_bridge` defaults in `adapters/hermes/memos_provider/__init__.py`),
- a transport-close reconnect at **4s** (line ~849),
- `turn.start` **4s** (by-design fail-open recall — non-fatal).

Timed-out `session.open` → gateway respawns the bridge → more concurrent model loads → slower boots → more timeouts → **leaked/orphaned `bridge.cts` processes** (observed 29, a new pair every ~30–60s, some at 117–248% CPU). Patch #8's keepalive uses 90s, but (a) the initial/on-demand path still uses the 30s default and (b) under concurrent starvation even 90s is exceeded.

Confirmed: stopping the two leaking gateways (sergio, krati) dropped bridges 29→4 and halted spawning; restarting them **one at a time** booted cleanly with no spiral (load fell 7.93→0.57). A single gateway booting alone is fine; concurrent cold-boots are the trigger.

## Aggravating factors
- **Two band-aid scripts** run `pkill -f 'bridge\.cts'`: `scripts/tower-memos-bridge-guard.sh` and `scripts/tower-personal-channel-assistant.sh` (threshold 8). That pattern **kills the `:18800` viewer daemon too** and matches any shell whose command line contains `bridge.cts`. Neither is currently scheduled (cron/timer), but both are landmines. The guard's threshold of 8 is below normal multi-gateway steady state.
- The `:18800` daemon is a **manually-launched foreground process in an SSH session** (`session-883.scope`), not a systemd unit — it dies with the session and won't auto-restart.
- DeepSeek `$0`-balance on 05-24 (402/503 storms) had earlier stalled the extraction pipeline and seeded the dirty-episode backlog.

## What was done (2026-05-26)
1. **Consistent backup** of the DB before any mutation: `~/.hermes/memos-plugin/data/memos.db.bak-20260526-061139` (integrity `ok`, 94,668 traces).
2. **Purged the runaway pollution**: kept the 6 real turns of `ep_pen5q6ndmf8q`, deleted 67,247 duplicate/empty rows. Did it fast by dropping the FTS triggers, bulk-deleting, then dropping+recreating+repopulating the `traces_fts` FTS5 table from survivors and restoring triggers (row-by-row FTS delete was O(n) and hung). Result: **95,174 → 27,927 traces**, FTS in sync (27,927), integrity `ok`, WAL checkpointed to 0.
   - (Embedding "backlog" of 579 turned out to be all `status=succeeded` — not a real backlog.)
   - DB file still ~1.89 GB (freed pages not returned to OS). **VACUUM deferred** — needs the daemon down.
3. **Stopped the leak/spiral**: stopped sergio+krati, killed orphaned bridges by explicit PID (never by pattern — preserved the `:18800` daemon 2253405/2253430), then **restarted gateways staggered**. Bridges stable at 4, load normal, daemon healthy.

## Durable fixes
Applied 2026-05-26:
- **A. Raised the fatal timeouts** in `memos_provider/__init__.py`: `session.open`/`_reconnect_bridge`/`_ensure_bridge` defaults 30→120s and the transport-close reconnect 4→90s. (Patch source under `tools/plugin-patches/` was stale/diverged — synced from the installed file in the same change.) ✅
- **D. Idempotency guard** — `traces_idempotent_turn` `BEFORE INSERT` trigger does `RAISE(IGNORE)` when a row with the same `(episode_id, turn_id)` already exists, so a slow/timed-out `subagent.record`/`turn.end` can no longer re-inflate an episode. Chosen over a unique index because `RAISE(IGNORE)` skips silently (no exception that could break capture) and needs no TS change. Verified: a duplicate insert is dropped, the first is kept. ✅
- **E. Neutralized the `pkill -f 'bridge\.cts'` band-aids** — both scripts now `source scripts/lib-bridge-safe-cleanup.sh` (kills only node bridge procs, never the `:18800` daemon or a shell) and restart gateways staggered; guard threshold raised 8→16. ✅
- **Daemon as a systemd unit** — `hermes-memos-daemon.service` (see appendix), replacing the fragile manual SSH-session process. ✅

Remaining future work (not blocking; the above contains the leak):
- **B. Serialize bridge boots** (a cross-gateway boot lock) so only one BGE-large load runs at a time — the timeout raise + staggered restarts mitigate but don't eliminate concurrent-boot starvation.
- **C. Shared single daemon (architecture-true)** — make gateways thin clients of the one `:18800` daemon instead of each booting a full embedded instance + model. Also: boot-time episode reflection still blocks `session.open` (one episode took 154s); backgrounding it is the real cure for slow boots.

## Also corrected this session (unrelated, same sitting)
- Memory-viewer login through the tailnet was 401ing: nginx `location /api/` greedily routed the viewer's `/api/v1/auth/login` to the Hermes dashboard (:9119). Added a more-specific `location /api/v1/ → :18800`. Browser login verified.
- Viewer console errors fixed in `web/dist/hermes-profile-switcher.js`: mixed-content guard for the cross-daemon health probe, and an auth gate before `/api/v1/diag/namespace`.

## Config note
Extraction + skillEvolver LLMs were reverted **Gemini → DeepSeek on 2026-05-25** (DeepSeek refunded, balance $6.82, endpoint healthy). CLAUDE.md had still listed Gemini as current — reconciled in the same change as this doc.

## Appendix — capture wiring for the ~/Coding/Hermes Claude Code session

`.claude/settings.json` is gitignored, so its contents are recorded here for
reproducibility. The setup reuses the env-configurable CTO memory stack
(`~/Coding/Hermes-CTO/.venv` + `mcp/`) under a dedicated `claude-code` profile
on a separate warm-bridge daemon port (18811), so it never collides with the
`cto` profile (18810). The daemon auto-starts on first hook call (`warm_async`).

`~/Coding/Hermes/.claude/settings.json` (gitignored — recreate by hand):
```json
{
  "hooks": {
    "UserPromptSubmit": [{"hooks": [{"type": "command",
      "command": "CTO_MEM_PORT=18811 CTO_PROFILE_ID=claude-code /home/openclaw/Coding/Hermes-CTO/.venv/bin/python /home/openclaw/Coding/Hermes-CTO/.claude/hooks/hook_recall.py",
      "timeout": 50}]}],
    "Stop": [{"hooks": [{"type": "command",
      "command": "CTO_MEM_PORT=18811 CTO_PROFILE_ID=claude-code /home/openclaw/Coding/Hermes-CTO/.venv/bin/python /home/openclaw/Coding/Hermes-CTO/.claude/hooks/hook_capture.py",
      "timeout": 30}]}]
  }
}
```

`~/Coding/Hermes/.mcp.json` (committed) points the `hermes-memory` MCP server
at the same profile/port. The hooks take effect on the next Claude Code session
start (settings are read at startup).

## Appendix — :18800 daemon as a systemd unit

The viewer/daemon was a fragile manual `tsx bridge.cts --daemon --agent=hermes`
launched in an SSH session (died with the session). It is now
`hermes-memos-daemon.service` (`--user`, `Restart=always`, enabled at boot);
a copy lives at `memos-setup/systemd/hermes-memos-daemon.service`. Manage with:
```
systemctl --user status  hermes-memos-daemon.service
systemctl --user restart hermes-memos-daemon.service
journalctl --user -u hermes-memos-daemon.service -n 50 --no-pager
```
