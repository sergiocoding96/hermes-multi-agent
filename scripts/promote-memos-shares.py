#!/usr/bin/env python3
"""promote-memos-shares.py — auto-promote memos-local-plugin artifacts to 'local'.

Runs on cron. For each artifact type that supports sharing in 2.0
(traces, policies, world-models, skills), find rows that are still
`private` across ALL profiles and promote them to `share_scope='local'`
so all Hermes profiles on this host (including sergio's orchestrator)
can read them.

Episodes do not have a /share endpoint in 2.0 — the constituent traces
carry the synthesis (summary field). Promoting traces gives the
orchestrator the "constant flow of synthesis" we want.

Implementation note: in 2.0.0 the HTTP API (`POST /api/v1/{resource}/{id}/share`)
enforces the bridge's *active namespace* on both reads and writes — so a
cross-cube promoter that talks HTTP can only ever touch one profile's rows.
Internal pipeline artifacts (skills, policies, world-models created by the
bridge's "default" namespace) are unreachable via HTTP at all. To work
around this, the promoter writes directly to the SQLite store. Schema
migrations in 2.0 are additive (column adds), so direct writes to the
stable `share_scope` / `share_target` / `shared_at` columns are upgrade-safe
across minor versions. A future column rename would break this script
loudly and we'd update it.

Usage:
  ./promote-memos-shares.py           # run once, exit
  ./promote-memos-shares.py --dry     # show what would change, don't write
  ./promote-memos-shares.py --scope local|public|hub|private  # override target scope

Cron entry (every 15 min):
  */15 * * * * /home/openclaw/Coding/Hermes/scripts/promote-memos-shares.py \\
    >> /home/openclaw/.hermes/memos-plugin/logs/promote.log 2>&1
"""

from __future__ import annotations

import argparse
import os
import sqlite3
import sys
import time

DB = os.path.expanduser("~/.hermes/memos-plugin/data/memos.db")

# Tables that have a share_scope column in 2.0 (migration 009).
RESOURCES = ("traces", "policies", "skills", "world_model")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry", action="store_true",
                        help="Show planned promotions; don't write.")
    parser.add_argument("--scope", default="local",
                        choices=("private", "local", "public", "hub"),
                        help="Target share_scope (default: local).")
    parser.add_argument("--db", default=DB,
                        help=f"SQLite path (default: {DB}).")
    args = parser.parse_args()

    if not os.path.exists(args.db):
        print(f"[promote] db not found: {args.db}", file=sys.stderr)
        return 2

    # Open read-write — direct SQL is the only path that works for
    # cross-namespace promotion (HTTP API enforces bridge's active
    # namespace on the share endpoint, see module docstring).
    con = sqlite3.connect(args.db, timeout=30)
    try:
        summary: dict[str, int] = {}
        now_ms = int(time.time() * 1000)

        for table in RESOURCES:
            try:
                rows = con.execute(
                    f"SELECT id FROM {table} "
                    f"WHERE share_scope IS NULL OR share_scope = 'private'"
                ).fetchall()
            except sqlite3.Error as e:
                # Table might not exist on older plugin versions; skip with note.
                print(f"[promote] {table} enum failed: {e}", file=sys.stderr)
                continue

            ids = [r[0] for r in rows]
            if args.dry:
                for row_id in ids:
                    print(f"[dry] {table} {row_id} → {args.scope}")
                summary[table] = len(ids)
                continue

            promoted = 0
            try:
                with con:  # transaction
                    for row_id in ids:
                        con.execute(
                            f"UPDATE {table} "
                            f"SET share_scope=?, shared_at=? "
                            f"WHERE id=? AND (share_scope IS NULL OR share_scope='private')",
                            (args.scope, now_ms, row_id),
                        )
                        promoted += 1
            except sqlite3.Error as e:
                print(f"[promote] {table} update failed: {e}", file=sys.stderr)
                return 1
            summary[table] = promoted
    finally:
        con.close()

    ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    counts = " ".join(f"{k}={v}" for k, v in summary.items())
    suffix = " (dry)" if args.dry else ""
    print(f"[{ts}] promoted{suffix}: {counts}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
