#!/usr/bin/env python3
"""
memory-graph-watcher — keep tools/memory-graph.json fresh.

Watches `~/.hermes/memos-plugin/data/memos.db-wal` (SQLite's write-ahead log)
for modifications. When the WAL has been quiet for a debounce window, runs
`memos-explorer.py graph-export` to refresh the projection + cluster labels
the 3D Memory Map viewer reads from.

Design:
  - Poll mtime + size of the WAL file every POLL_INTERVAL seconds. WAL grows
    on every write; size shrinks back to ~0 after checkpoint. Either signal
    counts as activity.
  - When activity stops (no change for DEBOUNCE seconds), schedule a regen
    iff one is not already running and the WAL has actually changed since
    the last successful regen.
  - One regen takes ~40-60s (BGE-large CPU embedding + UMAP fit + ~30
    DeepSeek calls for labels). The watcher runs it as a subprocess so the
    poll loop stays responsive.
  - Min interval between regens enforced (MIN_INTERVAL) so a burst of
    activity doesn't trigger back-to-back exports.

Runs as a systemd-user service. Logs to ~/.hermes/memos-plugin/logs/
graph-watcher.log via journald.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path

# ── Config ────────────────────────────────────────────────────────────────
HOME = Path.home()
WAL = HOME / ".hermes/memos-plugin/data/memos.db-wal"
DB = HOME / ".hermes/memos-plugin/data/memos.db"
REPO = Path("/home/openclaw/Coding/Hermes")
EXPLORER = REPO / "tools/memos-explorer.py"
OUT = REPO / "tools/memory-graph.json"
PYTHON = HOME / ".hermes/tools-venv/bin/python"

POLL_INTERVAL = 5      # seconds between mtime checks
DEBOUNCE = 5 * 60      # quiet seconds before a regen fires
MIN_INTERVAL = 15 * 60 # don't regen more often than this even on bursts
STARTUP_SETTLE = 30    # don't trigger immediately on startup; wait for daemon to settle

# ── State ─────────────────────────────────────────────────────────────────
last_wal_signature: tuple[float, int] | None = None
last_regen_at: float = 0.0
last_known_signature_at_regen: tuple[float, int] | None = None


def log(msg: str) -> None:
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] {msg}", flush=True)


def wal_signature() -> tuple[float, int] | None:
    """Return (mtime, size) of the WAL file. None if WAL doesn't exist."""
    try:
        st = WAL.stat()
        return (st.st_mtime, st.st_size)
    except FileNotFoundError:
        return None


def run_regen() -> None:
    """Invoke memos-explorer graph-export. Blocks ~60s. Logs result."""
    global last_regen_at, last_known_signature_at_regen
    log("triggering graph-export …")
    start = time.time()
    try:
        proc = subprocess.run(
            [str(PYTHON), str(EXPLORER), "graph-export", "--out", str(OUT)],
            capture_output=True, text=True, timeout=600, cwd=str(REPO),
        )
        elapsed = time.time() - start
        if proc.returncode != 0:
            log(f"graph-export FAILED in {elapsed:.1f}s (exit {proc.returncode})")
            tail = (proc.stderr or "").strip().splitlines()[-6:]
            for line in tail:
                log(f"  | {line}")
            return
        # Find the "labelled N/M" line from stderr to surface usefulness
        labelled = ""
        for line in (proc.stderr or "").splitlines():
            if "labelled" in line and "/" in line:
                labelled = line.strip()
        log(f"graph-export OK in {elapsed:.1f}s.  {labelled}")
        last_regen_at = time.time()
        last_known_signature_at_regen = wal_signature()
    except subprocess.TimeoutExpired:
        log("graph-export TIMEOUT after 600s")


def main() -> None:
    global last_wal_signature

    log("memory-graph-watcher starting")
    log(f"  watching: {WAL}")
    log(f"  output:   {OUT}")
    log(f"  debounce: {DEBOUNCE}s   min-interval: {MIN_INTERVAL}s")

    if not EXPLORER.exists():
        log(f"FATAL: explorer not found at {EXPLORER}")
        sys.exit(2)
    if not PYTHON.exists():
        log(f"FATAL: tools-venv python not found at {PYTHON}")
        sys.exit(2)

    # Don't fire immediately on startup. If the daemon was off and just came
    # back, the WAL might appear new even though nothing actually changed.
    time.sleep(STARTUP_SETTLE)
    last_wal_signature = wal_signature()
    last_change_at = time.time()

    log("entering watch loop")
    while True:
        time.sleep(POLL_INTERVAL)
        sig = wal_signature()
        if sig is None:
            # WAL missing — daemon down or checkpointed away. Skip.
            continue
        if sig != last_wal_signature:
            last_wal_signature = sig
            last_change_at = time.time()
            continue

        # No change since last poll. Has it been quiet long enough?
        quiet_for = time.time() - last_change_at
        if quiet_for < DEBOUNCE:
            continue

        # Skip if we've recently regen'd and nothing has changed since.
        if last_known_signature_at_regen == sig:
            continue

        # Honour minimum interval between regens.
        if time.time() - last_regen_at < MIN_INTERVAL:
            continue

        run_regen()
        last_change_at = time.time()  # reset so we don't immediately retry


def shutdown(signum: int, _frame: object) -> None:
    log(f"received signal {signum}, exiting")
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    try:
        main()
    except Exception as e:
        log(f"FATAL: {type(e).__name__}: {e}")
        raise
