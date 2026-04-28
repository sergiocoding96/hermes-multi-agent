"""MemOS Toolset Plugin — persistent vector memory for Hermes agents.

v1.0.3 adds an auto-capture hook (``post_llm_call``) so agents do not need
to call ``memos_store`` explicitly after every relevant turn. Filter rules,
local retry queue, and identity isolation live in ``auto_capture`` and
``capture_queue``.
"""

import logging
import os

from . import auto_capture as _auto_capture_mod
from . import handlers, schemas

logger = logging.getLogger(__name__)

# Module-level singleton so tests can introspect / monkeypatch.
_capture_instance = None


def _memos_available():
    """Check if MemOS env vars are configured."""
    return bool(
        os.environ.get("MEMOS_API_KEY")
        and os.environ.get("MEMOS_USER_ID")
        and os.environ.get("MEMOS_CUBE_ID")
    )


def _autocapture_enabled():
    """Auto-capture is on by default; opt-out via env."""
    flag = os.environ.get("MEMOS_AUTOCAPTURE_DISABLED", "").lower()
    return flag not in ("1", "true", "yes")


def register(ctx):
    """Register tools and (when enabled) the auto-capture lifecycle hook."""
    global _capture_instance

    ctx.register_tool(
        name="memos_store",
        toolset="memos",
        schema=schemas.MEMOS_STORE,
        handler=handlers.memos_store,
        check_fn=_memos_available,
        emoji="🧠",
        description="Store a memory in the agent's MemOS cube",
    )
    ctx.register_tool(
        name="memos_search",
        toolset="memos",
        schema=schemas.MEMOS_SEARCH,
        handler=handlers.memos_search,
        check_fn=_memos_available,
        emoji="🔍",
        description="Search the agent's MemOS memory cube",
    )

    if _memos_available() and _autocapture_enabled():
        _capture_instance = _auto_capture_mod.AutoCapture()
        ctx.register_hook("post_llm_call", _capture_instance.post_llm_call)
        logger.info(
            "[memos-toolset] v1.0.3 — registered tools and auto-capture hook"
        )
    else:
        logger.info(
            "[memos-toolset] v1.0.3 — registered tools (auto-capture disabled)"
        )
