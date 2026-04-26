"""Local SQLite retry queue for auto-capture.

Captures that fail (network blip, server down, transient error) are written
here so they can be drained on the next successful capture. The queue is
durable across plugin restarts.

Path: ``~/.hermes/plugins/memos-toolset/queue/captures.db`` by default,
overridable via the ``MEMOS_QUEUE_PATH`` env var (used by tests).
"""

from __future__ import annotations

import json
import logging
import os
import sqlite3
import threading
import time
from pathlib import Path
from typing import Iterator, List, Optional, Tuple

logger = logging.getLogger(__name__)

_DEFAULT_QUEUE_DIR = Path(os.path.expanduser("~/.hermes/plugins/memos-toolset/queue"))
_SCHEMA = """
CREATE TABLE IF NOT EXISTS pending_captures (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    cube_id TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    enqueued_at REAL NOT NULL,
    last_attempt_at REAL
);
CREATE INDEX IF NOT EXISTS idx_user_cube ON pending_captures(user_id, cube_id);
"""

# Re-attempt budget. Beyond this, we drop the row to avoid an unbounded queue
# when the server is permanently broken.
_MAX_ATTEMPTS = 50


def _resolve_queue_path() -> Path:
    override = os.environ.get("MEMOS_QUEUE_PATH")
    if override:
        return Path(override)
    return _DEFAULT_QUEUE_DIR / "captures.db"


class CaptureQueue:
    """Thread-safe SQLite-backed queue for pending captures."""

    def __init__(self, db_path: Optional[Path] = None) -> None:
        self._db_path = db_path or _resolve_queue_path()
        self._db_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._init_schema()

    def _connect(self) -> sqlite3.Connection:
        # Each call returns a fresh connection — sqlite3 connections are not
        # safely shareable across threads. Short-lived ops only.
        conn = sqlite3.connect(str(self._db_path), timeout=5.0, isolation_level=None)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        return conn

    def _init_schema(self) -> None:
        with self._lock:
            conn = self._connect()
            try:
                conn.executescript(_SCHEMA)
            finally:
                conn.close()

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def enqueue(
        self,
        user_id: str,
        cube_id: str,
        payload: dict,
        error: str = "",
    ) -> int:
        """Persist a payload for later retry. Returns the row id."""
        body = json.dumps(payload, ensure_ascii=False)
        now = time.time()
        with self._lock:
            conn = self._connect()
            try:
                cur = conn.execute(
                    """
                    INSERT INTO pending_captures
                        (user_id, cube_id, payload_json, attempts, last_error,
                         enqueued_at, last_attempt_at)
                    VALUES (?, ?, ?, 0, ?, ?, NULL)
                    """,
                    (user_id, cube_id, body, error[:500], now),
                )
                return int(cur.lastrowid or 0)
            finally:
                conn.close()

    def size(self, user_id: Optional[str] = None, cube_id: Optional[str] = None) -> int:
        """Count of pending rows, optionally scoped to a user/cube."""
        with self._lock:
            conn = self._connect()
            try:
                if user_id is None and cube_id is None:
                    row = conn.execute(
                        "SELECT COUNT(*) FROM pending_captures"
                    ).fetchone()
                elif user_id is not None and cube_id is not None:
                    row = conn.execute(
                        "SELECT COUNT(*) FROM pending_captures "
                        "WHERE user_id=? AND cube_id=?",
                        (user_id, cube_id),
                    ).fetchone()
                else:
                    raise ValueError("size() requires both user_id and cube_id, or neither")
                return int(row[0]) if row else 0
            finally:
                conn.close()

    def iter_pending(
        self,
        user_id: str,
        cube_id: str,
        limit: int = 50,
    ) -> Iterator[Tuple[int, dict, int]]:
        """Yield (row_id, payload, attempts) oldest-first for a user+cube."""
        with self._lock:
            conn = self._connect()
            try:
                rows = conn.execute(
                    """
                    SELECT id, payload_json, attempts
                    FROM pending_captures
                    WHERE user_id=? AND cube_id=?
                    ORDER BY id ASC
                    LIMIT ?
                    """,
                    (user_id, cube_id, limit),
                ).fetchall()
            finally:
                conn.close()
        for row_id, body, attempts in rows:
            try:
                yield int(row_id), json.loads(body), int(attempts)
            except (json.JSONDecodeError, ValueError) as exc:
                logger.warning(
                    "[memos-toolset] dropping malformed queue row %s: %s", row_id, exc
                )
                self.delete(int(row_id))

    def mark_failed(self, row_id: int, error: str) -> None:
        """Increment the attempt counter; drop if past the cap."""
        now = time.time()
        with self._lock:
            conn = self._connect()
            try:
                row = conn.execute(
                    "SELECT attempts FROM pending_captures WHERE id=?",
                    (row_id,),
                ).fetchone()
                if not row:
                    return
                attempts = int(row[0]) + 1
                if attempts >= _MAX_ATTEMPTS:
                    conn.execute("DELETE FROM pending_captures WHERE id=?", (row_id,))
                    logger.warning(
                        "[memos-toolset] dropped capture %s after %d attempts: %s",
                        row_id, attempts, error,
                    )
                    return
                conn.execute(
                    "UPDATE pending_captures "
                    "SET attempts=?, last_error=?, last_attempt_at=? "
                    "WHERE id=?",
                    (attempts, error[:500], now, row_id),
                )
            finally:
                conn.close()

    def delete(self, row_id: int) -> None:
        """Remove a successfully-drained row."""
        with self._lock:
            conn = self._connect()
            try:
                conn.execute("DELETE FROM pending_captures WHERE id=?", (row_id,))
            finally:
                conn.close()

    def list_user_cubes(self) -> List[Tuple[str, str]]:
        """Distinct (user_id, cube_id) pairs that have at least one pending row."""
        with self._lock:
            conn = self._connect()
            try:
                rows = conn.execute(
                    "SELECT DISTINCT user_id, cube_id FROM pending_captures"
                ).fetchall()
            finally:
                conn.close()
        return [(str(u), str(c)) for u, c in rows]
