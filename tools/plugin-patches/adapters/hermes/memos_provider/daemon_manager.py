"""Daemon manager for the MemOS bridge subprocess.

Responsibilities:
- Ensure exactly one bridge process runs per user home.
- Probe Node.js availability so ``MemTensorProvider.is_available`` can
  answer cheaply at plugin-startup time.
- Graceful shutdown helpers invoked from ``MemTensorProvider.shutdown``.

This file intentionally has **no runtime dependency** on the client; the
provider instantiates its own client. Keeping these concerns split means
the dependency graph for the Hermes plugin stays acyclic:

    memos_provider/__init__.py ─┬─▶ bridge_client.py
                                └─▶ daemon_manager.py
"""

from __future__ import annotations

import contextlib
import fcntl
import logging
import os
import shutil
import subprocess
import threading
import time

from pathlib import Path


logger = logging.getLogger(__name__)

_lock = threading.Lock()
_bridge_ok: bool | None = None


def _boot_lock_path() -> Path:
    return _bridge_script().parent / ".bridge-boot.lock"


@contextlib.contextmanager
def bridge_boot_lock(timeout: float = 180.0):
    """Cross-process exclusive lock so only ONE bridge cold-boot (BGE-large
    model load) runs at a time across all gateways.

    Each gateway spawns its own ``bridge.cts`` that cold-loads the local
    BGE-large embedder (~2 CPU cores). When several boot at once they starve
    the CPU past the ``session.open`` timeout → respawn → leak/CPU spiral
    (the recurring ``sergio`` failure). Serializing the boots makes each one
    finish before the next starts.

    Best-effort: if the lock can't be acquired within ``timeout`` we proceed
    anyway rather than block capture forever. Yields True iff the lock was held.
    (This is the cheap mitigation; the proper fix is the shared single daemon —
    see the 2026-05-27 roadmap. That change removes this lock.)
    """
    fd = None
    acquired = False
    try:
        fd = os.open(str(_boot_lock_path()), os.O_CREAT | os.O_RDWR, 0o644)
        deadline = time.time() + max(1.0, timeout)
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except OSError:
                if time.time() >= deadline:
                    logger.warning(
                        "MemOS: bridge boot lock not acquired in %.0fs — booting unserialized",
                        timeout,
                    )
                    break
                time.sleep(0.5)
        yield acquired
    finally:
        if fd is not None:
            with contextlib.suppress(Exception):
                if acquired:
                    fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)


def _bridge_script() -> Path:
    return Path(__file__).resolve().parent.parent.parent.parent / "bridge.cts"


def _node_available() -> bool:
    node = shutil.which("node")
    if not node:
        return False
    try:
        out = subprocess.check_output([node, "--version"], timeout=2.0)
        return bool(out.strip())
    except Exception:
        return False


def ensure_bridge_running(*, probe_only: bool = False) -> bool:
    """Return True when the bridge is (or can be) operational.

    ``probe_only=True`` performs a lightweight availability check without
    launching a long-lived subprocess. This is what
    ``MemTensorProvider.is_available`` calls during Hermes startup.
    """
    global _bridge_ok
    with _lock:
        if _bridge_ok is not None and probe_only:
            return _bridge_ok
        script = _bridge_script()
        if not script.exists():
            logger.warning("MemOS: bridge script missing at %s", script)
            _bridge_ok = False
            return False
        if not _node_available():
            logger.warning("MemOS: Node.js not found on PATH")
            _bridge_ok = False
            return False
        _bridge_ok = True
        return True


def shutdown_bridge() -> None:
    """Best-effort cleanup; each client owns its own subprocess."""
    global _bridge_ok
    with _lock:
        _bridge_ok = None
