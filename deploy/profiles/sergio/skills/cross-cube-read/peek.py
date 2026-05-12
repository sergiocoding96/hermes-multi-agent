#!/usr/bin/env python3
"""peek.py — sergio's cross-cube reader.

Read-only SQLite access to the memos-local-plugin store, bypassing the
plugin's per-profile namespace filter. ONLY for sergio's orchestrator
role. See SKILL.md for usage policy.

Read-only by `mode=ro` URI flag. Cannot mutate.

Outputs JSON on stdout.
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys

DB = os.path.expanduser("~/.hermes/memos-plugin/data/memos.db")


def _con() -> sqlite3.Connection:
    if not os.path.exists(DB):
        sys.stderr.write(f"db missing: {DB}\n")
        sys.exit(2)
    return sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=10)


def cmd_profiles() -> None:
    con = _con()
    rows = con.execute(
        "SELECT owner_agent_kind, owner_profile_id, "
        "       COUNT(*) AS trace_count, "
        "       MAX(ts) AS last_trace_ms "
        "FROM traces "
        "GROUP BY owner_agent_kind, owner_profile_id "
        "ORDER BY last_trace_ms DESC"
    ).fetchall()
    out = [
        {
            "agentKind": r[0],
            "profileId": r[1],
            "traceCount": r[2],
            "lastTraceMs": r[3],
        }
        for r in rows
    ]
    print(json.dumps(out, indent=2))


def cmd_search(query: str, limit: int = 20) -> None:
    con = _con()
    needle = f"%{query}%"
    rows = con.execute(
        "SELECT id, owner_profile_id, ts, "
        "       substr(user_text, 1, 200) AS user_snippet, "
        "       substr(summary, 1, 300) AS summary "
        "FROM traces "
        "WHERE user_text LIKE ? OR agent_text LIKE ? OR summary LIKE ? "
        "ORDER BY ts DESC LIMIT ?",
        (needle, needle, needle, limit),
    ).fetchall()
    out = [
        {
            "id": r[0],
            "profileId": r[1],
            "ts": r[2],
            "userSnippet": r[3],
            "summary": r[4],
        }
        for r in rows
    ]
    print(json.dumps(out, indent=2))


def cmd_timeline(profile_id: str, limit: int = 20) -> None:
    con = _con()
    rows = con.execute(
        "SELECT id, episode_id, ts, "
        "       substr(user_text, 1, 200) AS user_snippet, "
        "       substr(agent_text, 1, 300) AS agent_snippet, "
        "       substr(summary, 1, 200) AS summary "
        "FROM traces "
        "WHERE owner_profile_id = ? "
        "ORDER BY ts DESC LIMIT ?",
        (profile_id, limit),
    ).fetchall()
    out = [
        {
            "id": r[0],
            "episodeId": r[1],
            "ts": r[2],
            "userSnippet": r[3],
            "agentSnippet": r[4],
            "summary": r[5],
        }
        for r in rows
    ]
    print(json.dumps(out, indent=2))


def cmd_episode(episode_id: str) -> None:
    con = _con()
    ep = con.execute(
        "SELECT id, owner_profile_id, session_id, started_at, ended_at, status "
        "FROM episodes WHERE id = ?",
        (episode_id,),
    ).fetchone()
    if not ep:
        sys.stderr.write(f"episode not found: {episode_id}\n")
        sys.exit(1)
    traces = con.execute(
        "SELECT id, ts, "
        "       substr(user_text, 1, 200) AS user_text, "
        "       substr(agent_text, 1, 500) AS agent_text, "
        "       substr(summary, 1, 300) AS summary, "
        "       substr(reflection, 1, 400) AS reflection, "
        "       value, alpha, priority "
        "FROM traces WHERE episode_id = ? ORDER BY ts ASC",
        (episode_id,),
    ).fetchall()
    out = {
        "episode": {
            "id": ep[0],
            "profileId": ep[1],
            "sessionId": ep[2],
            "startedAt": ep[3],
            "endedAt": ep[4],
            "status": ep[5],
        },
        "traces": [
            {
                "id": t[0],
                "ts": t[1],
                "userText": t[2],
                "agentText": t[3],
                "summary": t[4],
                "reflection": t[5],
                "value": t[6],
                "alpha": t[7],
                "priority": t[8],
            }
            for t in traces
        ],
    }
    print(json.dumps(out, indent=2))


def usage() -> None:
    sys.stderr.write(
        "usage:\n"
        "  peek.py profiles\n"
        "  peek.py search <query> [limit]\n"
        "  peek.py timeline <profile_id> [limit]\n"
        "  peek.py episode <episode_id>\n"
    )
    sys.exit(2)


def main(argv: list[str]) -> None:
    if len(argv) < 2:
        usage()
    cmd, *rest = argv[1:]
    if cmd == "profiles":
        cmd_profiles()
    elif cmd == "search":
        if not rest:
            usage()
        limit = int(rest[1]) if len(rest) > 1 else 20
        cmd_search(rest[0], limit)
    elif cmd == "timeline":
        if not rest:
            usage()
        limit = int(rest[1]) if len(rest) > 1 else 20
        cmd_timeline(rest[0], limit)
    elif cmd == "episode":
        if not rest:
            usage()
        cmd_episode(rest[0])
    else:
        usage()


if __name__ == "__main__":
    main(sys.argv)
