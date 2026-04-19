# Session: Paperclip Local Deployment & Recovery — 2026-04-08

## What Happened

Short focused session. Paperclip was not responding. Diagnosed and recovered it by restarting the process. Confirmed fully healthy.

---

## Problem

Paperclip was configured to run at `http://tower.taila4a33f.ts.net:3100` (also `localhost:3100`). The node process was alive (PID from April 4) but the service was not responding to HTTP requests. Logs showed a flood of errors:

```
ERROR: connect ECONNREFUSED 127.0.0.1:54329
```

Port 54329 is the embedded PostgreSQL that Paperclip bundles via `@embedded-postgres/linux-x64`. The DB process had died (no `postmaster.pid` in the data dir), leaving the Paperclip node process in a broken state — running but unable to serve requests.

---

## Root Cause

Paperclip uses an embedded PostgreSQL (not system postgres). It starts the DB subprocess when it launches. The DB had gone down (likely a system restart or OOM), and the node process did not exit — it kept running and logging connection errors every heartbeat tick.

The caddy/system postgres running on the machine is unrelated to Paperclip.

---

## Fix

Kill the orphaned node process and restart Paperclip. The embedded postgres comes back up automatically when Paperclip restarts.

```bash
# Kill the broken node process
kill $(ps aux | grep "paperclipai run" | grep -v grep | awk '{print $2}')

# Restart with the correct env
source /home/openclaw/.paperclip/instances/default/.env
export PAPERCLIP_AGENT_JWT_SECRET
nohup paperclipai run > /home/openclaw/.paperclip/instances/default/logs/server.log 2>&1 &
```

Health check after ~8 seconds:
```bash
curl http://localhost:3100/api/health
# {"status":"ok","version":"2026.325.0","deploymentMode":"authenticated","bootstrapStatus":"ready"}
```

---

## Key Facts

| Item | Value |
|------|-------|
| Paperclip binary | `/home/linuxbrew/.linuxbrew/bin/paperclipai` |
| Embedded postgres binary | `/home/linuxbrew/.linuxbrew/lib/node_modules/paperclipai/node_modules/@embedded-postgres/linux-x64/native/bin/postgres` |
| Embedded postgres port | `54329` |
| DB data dir | `~/.paperclip/instances/default/db/` |
| Logs | `~/.paperclip/instances/default/logs/server.log` |
| Env file | `~/.paperclip/instances/default/.env` (contains `PAPERCLIP_AGENT_JWT_SECRET`) |
| Config | `~/.paperclip/instances/default/config.json` |
| URL | `http://localhost:3100` (also `http://tower.taila4a33f.ts.net:3100` via Tailscale) |
| Version | `2026.325.0` |

---

## Diagnosis Checklist (for future incidents)

1. Is the node process running? → `ps aux | grep paperclipai`
2. Is postgres running? → `ss -tlnp | grep 54329`
3. Check logs: `tail -50 ~/.paperclip/instances/default/logs/server.log`
4. If ECONNREFUSED on 54329: kill node process, restart with env sourced
5. If node process missing entirely: just start fresh with the `nohup` command above

---

## Context for Next Sessions

Paperclip (CEO agent UI) is now live at `http://localhost:3100`. The hermes-paperclip-adapter is still NOT installed — that remains the critical missing link before CEO can spawn Hermes workers. See `2026-04-08-status-review-and-next-steps.md` for the full integration gap list.
