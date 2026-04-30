# systemd units

Operator-installable systemd unit files for the Hermes deployment. These are **templates** — copy to `~/.config/systemd/user/` (user units) and adjust paths/`ExecStart` to match your install layout before enabling.

## Units

| Unit | Status | Purpose |
|---|---|---|
| `memos-server.service` | active (RES/9) | v1 MemOS server (Qdrant + Neo4j + SQLite) auto-restart |
| `memos-hub.service` | **legacy / v2** | Was for the v2 hub (`@memtensor/memos-local-plugin`). v2 was deprecated 2026-04-27. Disable + remove on existing deployments; do not install on new ones. |

## Why `memos-server.service` exists (RES/9)

Cross-audit ledger item RES/9 (Resilience report): the v1 MemOS server has no auto-restart guard. A `kill -9`, OOM, or unhandled exception leaves the service down until an operator manually restarts it. For a memory backend that all agents depend on, that's unacceptable.

This unit adds:

- `Restart=on-failure` + `RestartSec=10` — auto-restart on crash, 10s delay between attempts
- `StartLimitIntervalSec=300` + `StartLimitBurst=5` — five failures within five minutes stops the auto-restart loop and surfaces the failure to the operator (prevents an unrecoverable bug from becoming infinite restart spam)

## Install (operator-side)

```bash
# 1. Copy template into the user systemd dir, then edit paths/ExecStart for your install
cp /home/openclaw/Coding/Hermes/deploy/systemd/memos-server.service \
   ~/.config/systemd/user/memos-server.service
${EDITOR:-nano} ~/.config/systemd/user/memos-server.service

# 2. Reload + enable + start
systemctl --user daemon-reload
systemctl --user enable --now memos-server.service
systemctl --user status memos-server.service

# 3. Verify auto-restart works
PID_BEFORE=$(systemctl --user show -p MainPID --value memos-server.service)
echo "Before: $PID_BEFORE"
kill -9 "$PID_BEFORE"
sleep 12
PID_AFTER=$(systemctl --user show -p MainPID --value memos-server.service)
echo "After:  $PID_AFTER"
systemctl --user status memos-server.service   # expect Active: active (running)
```

If `PID_AFTER` is different and the service is `active (running)`, RES/9 is closed.

## What to adjust in the template

The default `ExecStart=/usr/bin/python3.12 -m memos.api.server_api` assumes the documented v1 entry point. If your install uses a different entry, edit the line. If `EnvironmentFile=` is at a different path on your box, edit that too.

## Removing the legacy v2 hub unit

If `memos-hub.service` is still installed from the Sprint 2 era, remove it:

```bash
systemctl --user disable --now memos-hub.service 2>/dev/null
rm -f ~/.config/systemd/user/memos-hub.service
systemctl --user daemon-reload
```

The v2 plugin path is no longer the production target. See `memos-setup/learnings/2026-04-27-v2-deprecated-revert-to-v1.md`.
