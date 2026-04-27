#!/usr/bin/env python3
"""
hub-sync.py — push new memtensor traces from a Hermes worker to the v1.0.3 hub.

The v2 plugin (@memtensor/memos-local-plugin@2.0.0-beta.1) does not yet
ship its sharing.role=client implementation — `core/hub/` contains only
a README. This script is the practical bridge until upstream lands it.

What it does
------------
1. Reads the worker's v2 SQLite at ~/.hermes/memos-plugin/data/memos.db.
2. Selects traces whose ts > the last-synced watermark.
3. For each new trace, POSTs a memory to the v1.0.3 hub via
   /api/v1/hub/memories/share, using the worker's bearer token.
4. Persists the new watermark + the set of synced trace ids in a
   small SQLite db at ~/.hermes/profiles/<profile>/hub-sync-state.db.

Idempotent. Safe to run on cron every few minutes. Logs to stdout.

Environment
-----------
Read from ~/.hermes/profiles/<profile>/.hub-token:
  HERMES_WORKER_HUB_URL    — hub URL (default http://127.0.0.1:18992)
  HERMES_WORKER_HUB_TOKEN  — Bearer token (required)
  HERMES_WORKER_HUB_USER   — username for logging (cosmetic)

Optional env knobs:
  HUB_SYNC_BATCH=50        — max traces per run
  HUB_SYNC_MIN_TS=0        — floor watermark in ms (use to backfill)
  HUB_SYNC_DRY_RUN=1       — print but don't POST
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

V2_DB_PATH = Path(os.environ.get("MEMTENSOR_DB", str(Path.home() / ".hermes/memos-plugin/data/memos.db")))


def _load_worker_env(profile: str) -> dict[str, str]:
    env_file = Path.home() / ".hermes/profiles" / profile / ".hub-token"
    if not env_file.exists():
        sys.exit(f"missing worker env: {env_file} — run scripts/ceo/provision-worker-token.sh {profile}")
    out: dict[str, str] = {}
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):]
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k] = v.strip().strip('"').strip("'")
    return out


def _state_db(profile: str) -> sqlite3.Connection:
    state_path = Path.home() / ".hermes/profiles" / profile / "hub-sync-state.db"
    db = sqlite3.connect(state_path)
    db.execute("""
        CREATE TABLE IF NOT EXISTS synced (
          trace_id    TEXT PRIMARY KEY,
          hub_memory_id TEXT NOT NULL,
          synced_at   INTEGER NOT NULL
        )
    """)
    db.execute("""
        CREATE TABLE IF NOT EXISTS watermark (
          k  TEXT PRIMARY KEY,
          v  INTEGER NOT NULL
        )
    """)
    db.commit()
    return db


def _watermark_get(state: sqlite3.Connection) -> int:
    row = state.execute("SELECT v FROM watermark WHERE k='last_ts'").fetchone()
    return int(row[0]) if row else 0


def _watermark_set(state: sqlite3.Connection, ts: int) -> None:
    state.execute(
        "INSERT INTO watermark(k,v) VALUES('last_ts',?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",
        (ts,),
    )
    state.commit()


def _fetch_new_traces(v2_db: sqlite3.Connection, since_ts: int, limit: int) -> list[sqlite3.Row]:
    v2_db.row_factory = sqlite3.Row
    # Skip "(adapter-initiated)" stub traces (memtensor inserts these on
    # session boot; both user_text and agent_text are empty). We require
    # at least one of user_text / agent_text to carry content so we don't
    # pollute the hub with no-content placeholders.
    return v2_db.execute(
        """
        SELECT id, episode_id, session_id, ts, user_text, agent_text, summary,
               value, alpha, r_human, priority, schema_version
        FROM traces
        WHERE ts > ?
          AND (length(trim(user_text)) > 0 OR length(trim(agent_text)) > 0)
        ORDER BY ts ASC
        LIMIT ?
        """,
        (since_ts, limit),
    ).fetchall()


def _post_memory(hub_url: str, token: str, trace: sqlite3.Row, worker: str) -> str:
    summary = (trace["summary"] or trace["user_text"][:300] or "(no summary)").strip()
    content_parts = []
    if trace["user_text"]:
        content_parts.append(f"User: {trace['user_text'].strip()}")
    if trace["agent_text"]:
        content_parts.append(f"Agent: {trace['agent_text'].strip()}")
    content = "\n\n".join(content_parts) or summary

    payload = {
        "memory": {
            "sourceChunkId": f"hermes:{worker}:trace:{trace['id']}",
            "sourceAgent": worker,
            "role": "assistant",
            "content": content,
            "summary": summary,
            "kind": "paragraph",
        }
    }
    req = urllib.request.Request(
        f"{hub_url.rstrip('/')}/api/v1/hub/memories/share",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = json.loads(resp.read().decode())
    if not body.get("ok"):
        raise RuntimeError(f"hub rejected memory: {body}")
    return body["memoryId"]


def main(profile: str) -> int:
    if not V2_DB_PATH.exists():
        print(f"[hub-sync] {profile}: v2 db not present at {V2_DB_PATH} — nothing to sync")
        return 0

    env = _load_worker_env(profile)
    hub_url = env.get("HERMES_WORKER_HUB_URL", "http://127.0.0.1:18992")
    token = env.get("HERMES_WORKER_HUB_TOKEN", "")
    worker = env.get("HERMES_WORKER_HUB_USER", profile)
    if not token:
        print(f"[hub-sync] {profile}: no token — skipping")
        return 1

    batch = int(os.environ.get("HUB_SYNC_BATCH", "50"))
    min_ts = int(os.environ.get("HUB_SYNC_MIN_TS", "0"))
    dry_run = os.environ.get("HUB_SYNC_DRY_RUN") == "1"

    state = _state_db(profile)
    wm = max(_watermark_get(state), min_ts)
    v2 = sqlite3.connect(f"file:{V2_DB_PATH}?mode=ro", uri=True)
    rows = _fetch_new_traces(v2, wm, batch)
    if not rows:
        print(f"[hub-sync] {profile}: 0 new traces since ts={wm}")
        return 0

    pushed = 0
    skipped = 0
    last_ts = wm
    for row in rows:
        last_ts = max(last_ts, int(row["ts"]))
        if state.execute("SELECT 1 FROM synced WHERE trace_id=?", (row["id"],)).fetchone():
            skipped += 1
            continue
        if dry_run:
            print(f"[hub-sync] DRY {profile}: trace_id={row['id']} ts={row['ts']} summary={(row['summary'] or '')[:60]}")
            continue
        try:
            mid = _post_memory(hub_url, token, row, worker)
            state.execute(
                "INSERT INTO synced(trace_id, hub_memory_id, synced_at) VALUES(?,?,?)",
                (row["id"], mid, int(time.time() * 1000)),
            )
            state.commit()
            pushed += 1
        except urllib.error.HTTPError as e:
            print(f"[hub-sync] {profile}: HTTP {e.code} on trace {row['id']}: {e.read().decode()[:200]}", file=sys.stderr)
            return 2
        except Exception as e:
            print(f"[hub-sync] {profile}: error on trace {row['id']}: {e}", file=sys.stderr)
            return 2

    if not dry_run:
        _watermark_set(state, last_ts)
    print(f"[hub-sync] {profile}: pushed={pushed} skipped={skipped} watermark={last_ts}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: hub-sync.py <profile-name>  (e.g. research-agent)")
    sys.exit(main(sys.argv[1]))
