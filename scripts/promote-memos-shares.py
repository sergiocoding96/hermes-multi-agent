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

Hybrid approach (necessary because 2.0.0 HTTP list endpoints filter by
the bridge's *active namespace*, so cross-cube enumeration via HTTP
returns only one profile's rows):
  - Listing: read SQLite directly (additive migrations are upgrade-safe;
    renames break loudly and we update this script).
  - Sharing: POST /api/v1/{resource}/{id}/share — the public viewer
    contract, upgrade-safe across minor versions.

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
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from typing import Any

BRIDGE = "http://127.0.0.1:18800"
DB = os.path.expanduser("~/.hermes/memos-plugin/data/memos.db")

# Maps SQLite table → URL path segment for POST /api/v1/{segment}/{id}/share.
RESOURCES = {
    "traces": "traces",
    "policies": "policies",
    "skills": "skills",
    "world_model": "world-models",
}


def _post_share(resource_path: str, row_id: str, scope: str, bridge: str) -> None:
    body = json.dumps({
        "scope": scope,
        "target": None,
        "sharedAt": int(time.time() * 1000),
    }).encode()
    req = urllib.request.Request(
        f"{bridge}/api/v1/{resource_path}/{row_id}/share",
        data=body,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    urllib.request.urlopen(req, timeout=10).read()


def _list_private_ids(con: sqlite3.Connection, table: str) -> list[str]:
    """Return row IDs where share_scope is null or 'private'."""
    rows = con.execute(
        f"SELECT id FROM {table} "
        f"WHERE share_scope IS NULL OR share_scope = 'private'"
    ).fetchall()
    return [r[0] for r in rows]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry", action="store_true",
                        help="Show planned promotions; don't write.")
    parser.add_argument("--scope", default="local",
                        choices=("private", "local", "public", "hub"),
                        help="Target share_scope (default: local).")
    parser.add_argument("--bridge", default=BRIDGE,
                        help=f"Bridge URL (default: {BRIDGE}).")
    parser.add_argument("--db", default=DB,
                        help=f"SQLite path (default: {DB}).")
    args = parser.parse_args()

    if not os.path.exists(args.db):
        print(f"[promote] db not found: {args.db}", file=sys.stderr)
        return 2

    # Probe bridge health first so a cron failure logs a clean reason.
    try:
        urllib.request.urlopen(f"{args.bridge}/api/v1/ping", timeout=5).read()
    except (urllib.error.URLError, urllib.error.HTTPError) as e:
        print(f"[promote] bridge unreachable at {args.bridge}: {e}", file=sys.stderr)
        return 2

    # Read-only connection — we only enumerate; HTTP does the writes.
    con = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True, timeout=30)
    try:
        summary: dict[str, int] = {}
        for table, resource_path in RESOURCES.items():
            try:
                ids = _list_private_ids(con, table)
            except sqlite3.Error as e:
                # Table might not exist on older plugin versions; skip with a note.
                print(f"[promote] {table} list failed: {e}", file=sys.stderr)
                continue

            promoted = 0
            for row_id in ids:
                if args.dry:
                    print(f"[dry] {table} {row_id} → {args.scope}")
                    promoted += 1
                    continue
                try:
                    _post_share(resource_path, row_id, args.scope, args.bridge)
                    promoted += 1
                except urllib.error.HTTPError as e:
                    # 400/404 are non-fatal (row may have been deleted between
                    # list and promote, or scope already set).
                    if e.code in (400, 404):
                        continue
                    print(f"[promote] {table} {row_id}: HTTP {e.code}", file=sys.stderr)
                except urllib.error.URLError as e:
                    print(f"[promote] {table} {row_id}: {e}", file=sys.stderr)
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
