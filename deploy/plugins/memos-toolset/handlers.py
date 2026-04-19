"""MemOS API handlers — HTTP calls to store and search memories.

Identity (user_id, cube_id, api_key) is read from environment variables
at call time, never from the LLM. The agent cannot see or override these.
"""

import json
import logging
import os
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

logger = logging.getLogger(__name__)

_DEFAULT_API_URL = "http://localhost:8001"
_STORE_TIMEOUT = 30  # DeepSeek extraction can be slow
_SEARCH_TIMEOUT = 10


def _get_config():
    """Read identity from environment. Called per invocation, not at startup."""
    return {
        "api_url": os.environ.get("MEMOS_API_URL", _DEFAULT_API_URL),
        "api_key": os.environ["MEMOS_API_KEY"],
        "user_id": os.environ["MEMOS_USER_ID"],
        "cube_id": os.environ["MEMOS_CUBE_ID"],
    }


def _post(endpoint, payload, api_url, api_key, timeout):
    """Authenticated POST to MemOS API. Returns parsed JSON or error dict."""
    url = f"{api_url.rstrip('/')}/{endpoint.lstrip('/')}"
    body = json.dumps(payload).encode("utf-8")
    req = Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", f"Bearer {api_key}")

    try:
        with urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8", errors="replace")[:500]
        except Exception:
            pass
        return {"error": f"HTTP {e.code}", "detail": detail}
    except URLError as e:
        return {"error": "connection_failed", "detail": str(e.reason)}
    except TimeoutError:
        return {"error": "timeout", "detail": f"Request timed out after {timeout}s"}
    except Exception as e:
        return {"error": "unexpected", "detail": str(e)}


def memos_store(args, **kwargs):
    """Store content in the agent's MemOS cube."""
    content = args.get("content", "").strip()
    if not content:
        return json.dumps({"error": "No content provided"})

    mode = args.get("mode", "fine")
    if mode not in ("fine", "fast"):
        mode = "fine"

    tags = args.get("tags", [])
    if not isinstance(tags, list):
        tags = []

    try:
        cfg = _get_config()
    except KeyError as e:
        return json.dumps({"error": f"Missing environment variable: {e}"})

    payload = {
        "user_id": cfg["user_id"],
        "writable_cube_ids": [cfg["cube_id"]],
        "messages": [{"role": "user", "content": content}],
        "async_mode": "sync",
        "mode": mode,
    }
    if tags:
        payload["custom_tags"] = tags

    result = _post("product/add", payload, cfg["api_url"], cfg["api_key"], _STORE_TIMEOUT)

    if "error" in result:
        return json.dumps({"status": "error", **result})

    return json.dumps({
        "status": "stored",
        "cube": cfg["cube_id"],
        "mode": mode,
        "tags": tags,
        "preview": content[:100] + ("..." if len(content) > 100 else ""),
    })


def memos_search(args, **kwargs):
    """Search the agent's MemOS cube."""
    query = args.get("query", "").strip()
    if not query:
        return json.dumps({"error": "No query provided"})

    top_k = min(max(int(args.get("top_k", 10)), 1), 50)

    try:
        cfg = _get_config()
    except KeyError as e:
        return json.dumps({"error": f"Missing environment variable: {e}"})

    payload = {
        "query": query,
        "user_id": cfg["user_id"],
        "readable_cube_ids": [cfg["cube_id"]],
        "top_k": top_k,
        "relativity": 0.05,
        "dedup": "mmr",
    }

    result = _post("product/search", payload, cfg["api_url"], cfg["api_key"], _SEARCH_TIMEOUT)

    if "error" in result:
        return json.dumps({"status": "error", **result})

    # Format results for LLM consumption — extract memories from nested structure
    formatted = []
    text_mem = result.get("data", result).get("text_mem", [])
    for bucket in text_mem:
        for mem in bucket.get("memories", []):
            entry = {
                "rank": len(formatted) + 1,
                "content": mem.get("memory", ""),
            }
            meta = mem.get("metadata", {})
            if meta.get("relativity"):
                entry["relevance"] = round(float(meta["relativity"]), 3)
            if meta.get("tags"):
                entry["tags"] = meta["tags"]
            if meta.get("created_at"):
                entry["created_at"] = meta["created_at"]
            formatted.append(entry)

    return json.dumps({
        "status": "ok",
        "query": query,
        "count": len(formatted),
        "memories": formatted,
    })
