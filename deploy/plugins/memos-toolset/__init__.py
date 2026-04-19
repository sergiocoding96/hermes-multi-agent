"""MemOS Toolset Plugin — persistent vector memory for Hermes agents."""

import logging
import os

from . import handlers, schemas

logger = logging.getLogger(__name__)


def _memos_available():
    """Check if MemOS env vars are configured."""
    return bool(
        os.environ.get("MEMOS_API_KEY")
        and os.environ.get("MEMOS_USER_ID")
        and os.environ.get("MEMOS_CUBE_ID")
    )


def register(ctx):
    """Register memos_store and memos_search tools."""
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
    logger.info("[memos-toolset] Registered memos_store and memos_search")
