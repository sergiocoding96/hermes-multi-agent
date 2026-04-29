#!/usr/bin/env python3
"""Tiny in-process HTTP server that pretends to be the MemOS v1 API.

Used by the bash unit tests. Listens on a free localhost port, accepts the
endpoints the v1 CEO scripts hit (/product/search, /product/add), records
each request's path / headers / body to a JSONL log, and replies with a
canned response that matches the v1 server's actual shape closely enough
for the adapter logic to be exercised.

Usage:
    python3 _fake_memos.py --log /tmp/req.log --port-file /tmp/port [--mode search|add|down]

Writes the chosen port to --port-file once it's listening, then runs until
SIGTERM. The bash test reads the port, exports MEMOS_ENDPOINT, runs the
script under test, then inspects the log.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


CANNED_SEARCH = {
    "data": {
        "text_mem": [
            {
                "cube_id": "ceo-cube",
                "memories": [
                    {
                        "id": "mem-1",
                        "memory": "CEO recorded that hydrazine is the LEO sat propellant of choice.",
                        "metadata": {
                            "cube_id": "ceo-cube",
                            "user_id": "ceo",
                            "tags": ["agent:ceo", "summary:propellant"],
                            "created_at": "2026-04-28T12:00:00Z",
                            "relativity": 0.91,
                            "visibility": "private",
                        },
                    }
                ],
            },
            {
                "cube_id": "research-cube",
                "memories": [
                    {
                        "id": "mem-2",
                        "memory": "Research agent confirmed hydrazine via Northrop Grumman datasheet.",
                        "metadata": {
                            "cube_id": "research-cube",
                            "user_id": "research-agent",
                            "tags": ["source:northrop"],
                            "created_at": "2026-04-27T09:00:00Z",
                            "relativity": 0.84,
                            "visibility": "private",
                        },
                    }
                ],
            },
        ]
    }
}


CANNED_ADD = {"status": "ok", "id": "mem-new-1"}


def make_handler(log_path: str, mode: str):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args, **_kwargs):  # silence stderr
            return

        def do_POST(self):  # noqa: N802
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length).decode("utf-8") if length else ""
            try:
                body = json.loads(raw) if raw else {}
            except json.JSONDecodeError:
                body = {"_raw": raw}

            entry = {
                "path": self.path,
                "headers": {k: v for k, v in self.headers.items()},
                "body": body,
            }
            with open(log_path, "a") as f:
                f.write(json.dumps(entry) + "\n")

            if mode == "down":
                # Force a connection-reset-style failure by closing without
                # writing a status line.
                try:
                    self.wfile.close()
                except Exception:
                    pass
                return

            if self.path.endswith("/product/search"):
                payload = CANNED_SEARCH
            elif self.path.endswith("/product/add"):
                payload = CANNED_ADD
            else:
                payload = {"error": "unknown path", "path": self.path}

            body_bytes = json.dumps(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body_bytes)))
            self.end_headers()
            self.wfile.write(body_bytes)

    return Handler


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True)
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--mode", default="ok", choices=["ok", "down"])
    args = parser.parse_args()

    # Truncate the log up front.
    open(args.log, "w").close()

    handler = make_handler(args.log, args.mode)
    httpd = HTTPServer(("127.0.0.1", 0), handler)
    port = httpd.server_address[1]
    with open(args.port_file, "w") as f:
        f.write(str(port))

    # serve_forever() blocks the main thread; calling httpd.shutdown() from a
    # signal handler running on that same thread deadlocks. Just exit on signal.
    def _exit(_sig, _frame):
        os._exit(0)
    signal.signal(signal.SIGTERM, _exit)
    signal.signal(signal.SIGINT, _exit)

    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
