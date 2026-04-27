"""Auto-capture hook for memos-toolset.

After every agent turn (via the ``post_llm_call`` lifecycle hook) we capture
the user message + assistant response to the agent's MemOS cube. The agent
never sees the call: identity is read from the same env vars that
``handlers.memos_store`` uses, and the LLM cannot override them.

Filter rules
------------
- Skip turns shorter than ``_MIN_CHARS`` chars combined.
- Skip turns the skill marked ``no-capture`` via a sentinel in the assistant
  response (``[no-capture]`` anywhere, case-insensitive).
- Skip exact-content duplicates of the last 3 captured turns from the same
  session (cheap in-memory dedup; server-side dedup catches near-duplicates).

Failure isolation
-----------------
Capture errors NEVER raise. The hook system in ``hermes_cli.plugins`` already
swallows exceptions, but we belt-and-brace: any error inside the hook is
logged at WARN with ``(session_id, turn_id, error)`` and the failing payload
is queued for retry.

Identity
--------
Reads ``MEMOS_API_URL`` / ``MEMOS_API_KEY`` / ``MEMOS_USER_ID`` /
``MEMOS_CUBE_ID`` from the environment at hook time — same as
``handlers._get_config()``. The LLM cannot inject a different cube_id because
the hook ignores its arguments and reads identity directly from env.
"""

from __future__ import annotations

import logging
import os
import threading
from collections import OrderedDict, deque
from typing import Any, Deque, Dict, Optional

from . import handlers
from .capture_queue import CaptureQueue

logger = logging.getLogger(__name__)

# Filter thresholds — module-level constants so tests can monkeypatch.
_MIN_CHARS = 50
_DEDUP_WINDOW = 3
_NO_CAPTURE_SENTINEL = "[no-capture]"

# Retain at most this many sessions in the in-memory dedup ring before
# evicting the oldest. Bound the memory footprint for long-lived processes.
_MAX_TRACKED_SESSIONS = 256


class AutoCapture:
    """Hook implementation. One instance per process; bound at register time."""

    def __init__(self, queue: Optional[CaptureQueue] = None) -> None:
        self._queue = queue or CaptureQueue()
        self._lock = threading.Lock()
        # session_id -> deque of last N captured content strings (for dedup)
        self._recent: "OrderedDict[str, Deque[str]]" = OrderedDict()

    # ------------------------------------------------------------------
    # Hook entry point — registered with ctx.register_hook("post_llm_call", ...)
    # ------------------------------------------------------------------

    def post_llm_call(self, **kwargs: Any) -> None:
        """Called by Hermes after every completed agent turn."""
        if os.environ.get("MEMOS_AUTOCAPTURE_DISABLED", "").lower() in ("1", "true", "yes"):
            return

        session_id = str(kwargs.get("session_id") or "")
        user_msg = str(kwargs.get("user_message") or "").strip()
        assistant_msg = str(kwargs.get("assistant_response") or "").strip()
        turn_id = self._derive_turn_id(kwargs)

        try:
            self._handle_turn(session_id, turn_id, user_msg, assistant_msg)
        except Exception as exc:  # pragma: no cover — defensive belt-and-brace
            logger.warning(
                "[memos-toolset] auto_capture failure session=%s turn=%s err=%s",
                session_id, turn_id, exc,
            )

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    def _handle_turn(
        self,
        session_id: str,
        turn_id: str,
        user_msg: str,
        assistant_msg: str,
    ) -> None:
        content = self._format_content(user_msg, assistant_msg)
        skip_reason = self._filter_reason(session_id, content, assistant_msg)
        if skip_reason:
            logger.info(
                "[memos-toolset] auto_capture skip session=%s turn=%s reason=%s",
                session_id, turn_id, skip_reason,
            )
            return

        # Try identity load. If env is missing, the agent isn't memos-enabled
        # at all — silently no-op.
        try:
            cfg = handlers._get_config()
        except KeyError:
            return

        payload = self._build_payload(cfg, content, session_id, turn_id)
        result = handlers._post(
            "product/add",
            payload,
            cfg["api_url"],
            cfg["api_key"],
            handlers._STORE_TIMEOUT,
        )

        if "error" in result:
            err = f"{result.get('error', 'unknown')}: {str(result.get('detail', ''))[:200]}"
            self._queue.enqueue(cfg["user_id"], cfg["cube_id"], payload, error=err)
            logger.warning(
                "[memos-toolset] auto_capture queued session=%s turn=%s err=%s",
                session_id, turn_id, err,
            )
            return

        # Success — record for dedup, drain any backlog for this user+cube.
        self._record_recent(session_id, content)
        logger.info(
            "[memos-toolset] auto_capture stored session=%s turn=%s cube=%s chars=%d",
            session_id, turn_id, cfg["cube_id"], len(content),
        )
        self._drain_queue(cfg)

    def _filter_reason(
        self,
        session_id: str,
        content: str,
        assistant_msg: str,
    ) -> Optional[str]:
        if not content:
            return "empty"
        if len(content) < _MIN_CHARS:
            return f"too_short<{_MIN_CHARS}"
        if _NO_CAPTURE_SENTINEL in assistant_msg.lower():
            return "no_capture_sentinel"
        if self._is_duplicate(session_id, content):
            return "duplicate"
        return None

    def _format_content(self, user_msg: str, assistant_msg: str) -> str:
        if user_msg and assistant_msg:
            return f"User: {user_msg}\n\nAssistant: {assistant_msg}"
        return user_msg or assistant_msg

    def _build_payload(
        self,
        cfg: Dict[str, str],
        content: str,
        session_id: str,
        turn_id: str,
    ) -> Dict[str, Any]:
        # Identity from env, NOT from any agent-supplied args. The LLM has
        # no way to influence user_id / cube_id here.
        tags = ["auto-capture"]
        return {
            "user_id": cfg["user_id"],
            "writable_cube_ids": [cfg["cube_id"]],
            "messages": [{"role": "user", "content": content}],
            "async_mode": "sync",
            "mode": "fine",
            "custom_tags": tags,
            "metadata": {
                "session_id": session_id,
                "turn_id": turn_id,
                "source": "auto_capture",
            },
        }

    # -- dedup ring -----------------------------------------------------

    def _is_duplicate(self, session_id: str, content: str) -> bool:
        with self._lock:
            ring = self._recent.get(session_id)
            if not ring:
                return False
            return content in ring

    def _record_recent(self, session_id: str, content: str) -> None:
        with self._lock:
            ring = self._recent.get(session_id)
            if ring is None:
                ring = deque(maxlen=_DEDUP_WINDOW)
                self._recent[session_id] = ring
            else:
                # Touch the LRU order.
                self._recent.move_to_end(session_id)
            ring.append(content)
            # Bound dedup state for long-lived processes.
            while len(self._recent) > _MAX_TRACKED_SESSIONS:
                self._recent.popitem(last=False)

    # -- queue drain ---------------------------------------------------

    def _drain_queue(self, cfg: Dict[str, str]) -> None:
        """Best-effort drain of the local retry queue for this user+cube."""
        drained = 0
        for row_id, payload, attempts in self._queue.iter_pending(
            cfg["user_id"], cfg["cube_id"], limit=50
        ):
            result = handlers._post(
                "product/add",
                payload,
                cfg["api_url"],
                cfg["api_key"],
                handlers._STORE_TIMEOUT,
            )
            if "error" in result:
                err = f"{result.get('error', 'unknown')}: {str(result.get('detail', ''))[:200]}"
                self._queue.mark_failed(row_id, err)
                # Stop on first failure — the server is probably still down.
                break
            self._queue.delete(row_id)
            drained += 1
        if drained:
            logger.info(
                "[memos-toolset] auto_capture drained %d queued captures cube=%s",
                drained, cfg["cube_id"],
            )

    # -- helpers --------------------------------------------------------

    @staticmethod
    def _derive_turn_id(kwargs: Dict[str, Any]) -> str:
        """Best-effort turn id — Hermes doesn't pass one, derive from history."""
        history = kwargs.get("conversation_history") or []
        if isinstance(history, list):
            return str(len(history))
        return "0"
