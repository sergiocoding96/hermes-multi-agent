#!/usr/bin/env python3
"""
MCP server for the Claude Code CEO session — v1 MemOS server edition.

Exposes four tools (interface unchanged from the v2 hub edition, plus
memos_store added so the CEO can persist memories without dropping to
the bash scripts):
  memos_search       — FTS + vector search across configured agent cubes
  memos_store        — Write a memory into MEMOS_WRITABLE_CUBE_IDS
  memos_list_skills  — List skills from the badass-skills repo clone
  memos_recent       — Recent memories across configured cubes

Credentials and config are read from environment variables (never passed
to the LLM):
  MEMOS_ENDPOINT             default: http://localhost:8001
  MEMOS_API_KEY              required: CEO BCrypt-hashed agent key
  MEMOS_USER_ID              default: "ceo"
  MEMOS_READABLE_CUBE_IDS    comma-separated; cubes the CEO can read across
  MEMOS_WRITABLE_CUBE_IDS    comma-separated; default "ceo-cube"
  BADASS_SKILLS_DIR          local clone of the source-of-truth skills repo
                             default: /home/openclaw/Coding/badass-skills
                             (https://github.com/sergiocoding96/badass-skills)

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
from pathlib import Path
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
BADASS_SKILLS_DIR = Path(
    os.environ.get("BADASS_SKILLS_DIR", "/home/openclaw/Coding/badass-skills")
)

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
def memos_store(
    content: str,
    summary: str = "",
    chunk_id: str = "",
    agent: str = "ceo",
    mode: str = "fine",
) -> dict[str, Any]:
    """
    Store a memory in the CEO's writable cubes.

    Posts to the v1 server's /product/add against MEMOS_WRITABLE_CUBE_IDS
    (default "ceo-cube"). v1 has no first-class summary or external dedup-key
    field, so summary and chunk_id are surfaced as custom_tags
    (`summary:<text>`, `chunk_id:<id>`); search consumers can still filter
    by tag.

    Args:
        content:  The memory body. Required.
        summary:  Short summary (defaults to first 120 chars of content).
        chunk_id: Stable id for client-side dedup (defaults to a uuid4).
        agent:    Source agent label, stored as a tag (default "ceo").
        mode:     MemReader extraction mode — "fine" (default) or "fast".
    """
    if not content.strip():
        return {"status": "error", "error": "content is required"}
    if mode not in ("fine", "fast"):
        return {"status": "error", "error": "mode must be 'fine' or 'fast'"}

    if not summary:
        summary = content[:120]
    if not chunk_id:
        import uuid
        chunk_id = f"ceo-{uuid.uuid4()}"

    body = {
        "user_id": USER_ID,
        "writable_cube_ids": list(WRITABLE_CUBES),
        "messages": [{"role": "assistant", "content": content}],
        "async_mode": "sync",
        "mode": mode,
        "custom_tags": [
            f"agent:{agent}",
            f"chunk_id:{chunk_id}",
            f"summary:{summary}",
        ],
    }
    raw = _server_request("POST", "/product/add", body)
    return {
        "status": "stored",
        "chunk_id": chunk_id,
        "cubes": list(WRITABLE_CUBES),
        "mode": mode,
        "raw": raw,
    }


def _parse_skill_frontmatter(path: Path) -> dict[str, str]:
    """Read just the leading YAML frontmatter of a SKILL.md file.

    Only ``name:`` and ``description:`` are extracted, so we avoid pulling
    pyyaml as a dep. Frontmatter delimited by ``---`` lines per CommonMark.
    """
    out: dict[str, str] = {}
    try:
        with path.open("r", encoding="utf-8") as f:
            first = f.readline().strip()
            if first != "---":
                return out
            buf: list[str] = []
            for line in f:
                if line.strip() == "---":
                    break
                buf.append(line)
    except OSError:
        return out

    for line in buf:
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip().lower()
        value = value.strip()
        if value.startswith(("'", '"')) and value.endswith(("'", '"')) and len(value) >= 2:
            value = value[1:-1]
        if key in {"name", "description"}:
            out[key] = value
    return out


@mcp.tool()
def memos_list_skills(query: str = "", max_results: int = 40) -> dict[str, Any]:
    """
    List skills available to the agents from the badass-skills repo.

    The source of truth is https://github.com/sergiocoding96/badass-skills,
    cloned locally at BADASS_SKILLS_DIR (default
    /home/openclaw/Coding/badass-skills). This tool walks that clone and
    reads the YAML frontmatter (``name``, ``description``) from each
    ``<skill>/SKILL.md`` file. v1 MemOS itself has no skills endpoint —
    skills live in source control, not the memory store.

    To refresh the list, pull the repo:
        git -C "$BADASS_SKILLS_DIR" pull --ff-only origin main

    Args:
        query:       Optional substring filter (case-insensitive) over name + description.
        max_results: Maximum skills to return (1-200, default 40).
    """
    max_results = min(max(1, int(max_results)), 200)

    if not BADASS_SKILLS_DIR.exists():
        return {
            "query": query or "(all)",
            "totalSkills": 0,
            "skills": [],
            "warning": (
                f"BADASS_SKILLS_DIR not found: {BADASS_SKILLS_DIR}. "
                "Clone https://github.com/sergiocoding96/badass-skills to that "
                "path or set BADASS_SKILLS_DIR to the existing clone."
            ),
        }

    skills: list[dict[str, Any]] = []
    needle = query.lower().strip()
    for skill_md in sorted(BADASS_SKILLS_DIR.rglob("SKILL.md")):
        if any(part.startswith(".") for part in skill_md.relative_to(BADASS_SKILLS_DIR).parts):
            continue
        meta = _parse_skill_frontmatter(skill_md)
        name = meta.get("name") or skill_md.parent.name
        desc = meta.get("description") or ""
        if needle and needle not in name.lower() and needle not in desc.lower():
            continue
        skills.append({
            "name": name,
            "description": desc[:300],
            "path": str(skill_md.relative_to(BADASS_SKILLS_DIR).parent),
            "source": "badass-skills",
        })
        if len(skills) >= max_results:
            break

    return {
        "query": query or "(all)",
        "totalSkills": len(skills),
        "skills": skills,
        "repo": "https://github.com/sergiocoding96/badass-skills",
        "localClone": str(BADASS_SKILLS_DIR),
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
