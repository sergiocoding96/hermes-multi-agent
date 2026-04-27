"""Tiny in-process HTTP server for integration tests.

Listens on a free localhost port and accepts ``POST /product/add``. Records
each accepted payload so tests can assert on what arrived. Supports modes:

- ``"ok"`` (default): respond 200 to every request.
- ``"500"``: respond 500 with a JSON error body.

Stop the server (``stop()``) to simulate ``"down"`` (connection refused).
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Dict, List


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args: Any, **_kwargs: Any) -> None:  # silence stderr
        return

    def do_POST(self) -> None:  # noqa: N802 — required name
        # ``self.server`` is the HTTPServer; we stash state on it directly.
        srv = self.server
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(raw.decode("utf-8")) if raw else {}
        except json.JSONDecodeError:
            payload = {"_raw": raw.decode("utf-8", errors="replace")}

        if getattr(srv, "mode", "ok") == "500":
            body = json.dumps({"error": "synthetic 500"}).encode("utf-8")
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        lock = getattr(srv, "lock", None)
        if lock is not None:
            with lock:
                srv.received.append({"path": self.path, "payload": payload})

        body = json.dumps({"status": "ok", "id": len(srv.received)}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class FakeMemOSServer:
    """Threaded HTTP server with switchable mode."""

    def __init__(self) -> None:
        self.received: List[Dict[str, Any]] = []
        self.lock = threading.Lock()
        self._mode: str = "ok"
        self._http: HTTPServer | None = None
        self._thread: threading.Thread | None = None
        self.port: int = 0

    def start(self) -> None:
        http = HTTPServer(("127.0.0.1", 0), _Handler)
        # Attach test state directly to the HTTPServer instance so the
        # handler can reach it via ``self.server``.
        http.received = self.received  # type: ignore[attr-defined]
        http.lock = self.lock  # type: ignore[attr-defined]
        http.mode = self._mode  # type: ignore[attr-defined]
        self._http = http
        self.port = http.server_address[1]
        self._thread = threading.Thread(target=http.serve_forever, daemon=True)
        self._thread.start()

    @property
    def mode(self) -> str:
        return self._mode

    @mode.setter
    def mode(self, value: str) -> None:
        self._mode = value
        if self._http is not None:
            self._http.mode = value  # type: ignore[attr-defined]

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def stop(self) -> None:
        if self._http is not None:
            self._http.shutdown()
            self._http.server_close()
            self._http = None
