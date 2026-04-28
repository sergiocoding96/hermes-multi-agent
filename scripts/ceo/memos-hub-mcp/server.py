#!/usr/bin/env python3
"""
MCP server for the Claude Code CEO session — v1 MemOS server edition.

Exposes three tools (interface unchanged from the v2 hub edition):
  memos_search       — FTS + vector search across configured agent cubes
  memos_list_skills  — Skill listing (v1 has no skills endpoint; returns empty + note)
  memos_recent       — Recent memories across configured cubes

Credentials and config are read from environment variables (never passed
to the LLM):
  MEMOS_ENDPOINT             default: http://localhost:8001
  MEMOS_API_KEY              required: CEO BCrypt-hashed agent key
  MEMOS_USER_ID              default: "ceo"
  MEMOS_READABLE_CUBE_IDS    comma-separated; cubes the CEO can read across
  MEMOS_WRITABLE_CUBE_IDS    comma-separated; default "ceo-cube"

Start: python3 server.py
Register: claude mcp add memos-hub python3 /path/to/server.py
(Server name stays "memos-hub" so existing claude.json registrations
keep working without re-registration.)

History: this file used to wrap the v2 hub at port 18992. v2 was
deprecated 2026-04-27 (see memos-setup/learnings/2026-04-27-v2-deprecated-revert-to-v1.md).
The MCP interface is preserved; only the backend flips to v1.
"""

import json
import os
import sys
import urllib.request
import urllib.error
from typing import Any

from mcp.server.fastmcp import FastMCP

# ─── Config from env (never appear in tool args or results) ───
ENDPOINT = os.environ.get("MEMOS_ENDPOINT", "http://localhost:8001").rstrip("/")
API_KEY = os.environ.get("MEMOS_API_KEY", "")
USER_ID = os.environ.get("MEMOS_USER_ID", "ceo")
READABLE_CUBES = [
    c.strip() for c in os.environ.get("MEMOS_READABLE_CUBE_IDS", "").split(",") if c.strip()
]
WRITABLE_CUBES = [
    c.strip() for c in os.environ.get("MEMOS_WRITABLE_CUBE_IDS", "ceo-cube").split(",") if c.strip()
]

if not API_KEY:
    print(
        "Error: MEMOS_API_KEY is not set.\n"
        "Source ~/.hermes/profiles/ceo/.env (or your CEO profile env file) before starting,\n"
        "or set MEMOS_API_KEY in the MCP server's env configuration in ~/.claude.json.\n"
        "See deploy/profiles/ceo.env.example for the expected env-var layout.",
        file=sys.stderr,
    )
    sys.exit(1)

if not READABLE_CUBES:
    print(
        "Warning: MEMOS_READABLE_CUBE_IDS is empty.\n"
        "memos_search and memos_recent will fall back to the CEO's own cube only.\n"
        "Set MEMOS_READABLE_CUBE_IDS=research-cube,email-marketing-cube,ceo-cube (or your\n"
        "actual deployed cube list) to enable CompositeCubeView reads across worker cubes.",
        file=sys.stderr,
    )


def _server_request(method: str, path: str, body: dict | None = None) -> dict:
    url = f"{ENDPOINT}{path}"
    data = json.dumps(body).encode() if body is not None else None
    headers = {
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json",
    }
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body_bytes = e.read()
        raise RuntimeError(f"MemOS HTTP {e.code}: {body_bytes.decode()[:200]}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"MemOS unreachable at {ENDPOINT}: {e.reason}") from e


def _cubes_for_search() -> list[str]:
    """The cubes to read across when servicing a search/recent call."""
    return READABLE_CUBES if READABLE_CUBES else WRITABLE_CUBES


def _project_v1_to_hits(v1_resp: dict, max_hits: int) -> list[dict[str, Any]]:
    """
    Project the v1 server's response into the v2 hub's hit shape so any
    consumer that was coded against the v2 schema sees the same fields.

    v1 shape: {data: {text_mem: [{cube_id, memories: [{id, memory, metadata}]}]}}
    v2 shape: hits[] with rank, summary, excerpt, ownerName, sourceAgent,
              taskTitle, visibility, remoteHitId.
    """
    hits: list[dict[str, Any]] = []
    text_mem = ((v1_resp or {}).get("data") or {}).get("text_mem", []) or []
    rank = 0
    for bucket in text_mem:
        cube_id = bucket.get("cube_id") or ""
        for m in bucket.get("memories", []) or []:
            rank += 1
            if rank > max_hits:
                return hits
            text = m.get("memory") or ""
            meta = m.get("metadata") or {}
            hits.append(
                {
                    "rank": rank,
                    "summary": text[:300],
                    "excerpt": text[:240],
                    "ownerName": cube_id,
                    "sourceAgent": cube_id.replace("-cube", "") if cube_id else "",
                    "taskTitle": meta.get("task_title"),
                    "visibility": meta.get("visibility"),
                    "remoteHitId": m.get("id"),
                }
            )
    return hits


mcp = FastMCP(
    "memos-hub",
    instructions=(
        "Tools for querying MemOS — the shared memory store for the Hermes "
        "multi-agent system. Use memos_search to find memories from any cube "
        "the CEO has read access to. Use memos_recent to browse latest activity. "
        "Skill enumeration is not yet supported on the v1 server backend."
    ),
)


@mcp.tool()
def memos_search(query: str, max_results: int = 10) -> dict[str, Any]:
    """
    Search across all configured cubes for memories and conversation chunks.

    Returns hits as a flat list across all cubes. Each hit includes:
      - summary: first ~300 chars of the memory text
      - excerpt: first ~240 chars (legacy field, same content as summary)
      - ownerName: cube the memory came from
      - sourceAgent: agent name derived from cube_id (e.g. "research-agent")
      - taskTitle: associated task if present in metadata
      - visibility: visibility scope from metadata (or None)
      - remoteHitId: opaque memory ID for follow-up fetches

    Args:
        query: Full-text / semantic search query.
        max_results: Maximum number of hits to return (default 10, max 40).
    """
    max_results = min(max(1, max_results), 40)
    cubes = _cubes_for_search()
    body = {
        "query": query,
        "user_id": USER_ID,
        "readable_cube_ids": cubes,
        "top_k": max_results,
    }
    resp = _server_request("POST", "/product/search", body)
    hits = _project_v1_to_hits(resp, max_results)
    return {
        "query": query,
        "totalHits": len(hits),
        "hits": hits,
    }


@mcp.tool()
def memos_list_skills(query: str = "", max_results: int = 20) -> dict[str, Any]:
    """
    Skill enumeration is not yet supported on the v1 MemOS server backend.

    The v2 hub had a /api/v1/hub/skills endpoint; v1 does not. The tool is
    kept on the interface so existing prompts that reference it don't break;
    callers will see an empty list with an explanatory note. Use memos_search
    with skill-related queries to find skill content directly until v1 grows
    a dedicated skills endpoint.

    Args:
        query: Ignored on v1.
        max_results: Ignored on v1.
    """
    return {
        "query": query or "(all)",
        "totalSkills": 0,
        "skills": [],
        "note": (
            "v1 server has no skills enumeration endpoint. Use memos_search "
            "with relevant terms to find skill content. This tool is reserved "
            "for a future v1.x release."
        ),
    }


@mcp.tool()
def memos_recent(limit: int = 20) -> dict[str, Any]:
    """
    Browse recent activity across configured cubes.

    Implementation: calls /product/search with an empty query and the
    configured readable cubes; v1 orders results by recency by default.

    On the v1 backend there is no separate "tasks" entity (the v2 hub had
    /api/v1/hub/tasks); the tasks field in the response is always empty.

    Args:
        limit: How many recent memories to return (default 20, max 40).
    """
    limit = min(max(1, limit), 40)
    cubes = _cubes_for_search()
    body = {
        "query": "",
        "user_id": USER_ID,
        "readable_cube_ids": cubes,
        "top_k": limit,
    }
    resp = _server_request("POST", "/product/search", body)
    hits = _project_v1_to_hits(resp, limit)
    memories = [
        {
            "id": h["remoteHitId"],
            "summary": h["summary"][:200],
            "sourceAgent": h["sourceAgent"],
            "role": None,
            "visibility": h["visibility"],
            "createdAt": None,
        }
        for h in hits
    ]
    return {
        "memories": memories,
        "tasks": [],
    }


if __name__ == "__main__":
    mcp.run()
