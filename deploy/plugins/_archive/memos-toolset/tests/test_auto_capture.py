"""Unit + integration tests for the v1.0.3 auto-capture hook.

Run with::

    python -m pytest deploy/plugins/_archive/memos-toolset/tests -v

The tests use a small in-process HTTP server (``_fake_server.FakeMemOSServer``)
that stands in for the MemOS API at ``localhost:8001``. No real MemOS server
is required.
"""

from __future__ import annotations

import os
import shutil
import tempfile
import time
import unittest
from pathlib import Path

# conftest.py registers the plugin under ``memos_toolset`` for these tests.
from . import conftest  # noqa: F401  — side-effect import

from memos_toolset import auto_capture as ac_mod  # type: ignore  # noqa: E402
from memos_toolset.auto_capture import AutoCapture  # type: ignore  # noqa: E402
from memos_toolset.capture_queue import CaptureQueue  # type: ignore  # noqa: E402

from ._fake_server import FakeMemOSServer


class _BaseTest(unittest.TestCase):
    """Shared fixture: env vars, fake server, isolated queue path."""

    def setUp(self) -> None:
        self.tmpdir = Path(tempfile.mkdtemp(prefix="memos-toolset-test-"))
        self.queue_path = self.tmpdir / "captures.db"

        self.server = FakeMemOSServer()
        self.server.start()

        self._old_env = {
            k: os.environ.get(k)
            for k in (
                "MEMOS_API_URL",
                "MEMOS_API_KEY",
                "MEMOS_USER_ID",
                "MEMOS_CUBE_ID",
                "MEMOS_QUEUE_PATH",
                "MEMOS_AUTOCAPTURE_DISABLED",
            )
        }
        os.environ["MEMOS_API_URL"] = self.server.url
        os.environ["MEMOS_API_KEY"] = "test-key"
        os.environ["MEMOS_USER_ID"] = "user-A"
        os.environ["MEMOS_CUBE_ID"] = "cube-A"
        os.environ["MEMOS_QUEUE_PATH"] = str(self.queue_path)
        os.environ.pop("MEMOS_AUTOCAPTURE_DISABLED", None)

        self.queue = CaptureQueue(db_path=self.queue_path)
        self.capture = AutoCapture(queue=self.queue)

    def tearDown(self) -> None:
        self.server.stop()
        for k, v in self._old_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmpdir, ignore_errors=True)


class TestFilterRules(_BaseTest):
    """Unit tests — filter rules."""

    def test_short_turn_skipped(self) -> None:
        self.capture.post_llm_call(
            session_id="s1",
            user_message="hi",
            assistant_response="ok",
            conversation_history=[],
        )
        self.assertEqual(len(self.server.received), 0)

    def test_no_capture_sentinel_skipped(self) -> None:
        long_msg = "x" * 80
        self.capture.post_llm_call(
            session_id="s1",
            user_message=long_msg,
            assistant_response=f"This response should NOT be captured. [no-capture] {long_msg}",
            conversation_history=[],
        )
        self.assertEqual(len(self.server.received), 0)

    def test_exact_dedup_skipped(self) -> None:
        user = "What is the capital of France?"
        assist = "The capital of France is Paris. " + ("." * 40)
        for _ in range(3):
            self.capture.post_llm_call(
                session_id="s1",
                user_message=user,
                assistant_response=assist,
                conversation_history=[],
            )
        # Only the first turn should land server-side; the next two are exact
        # dupes and get filtered before sending.
        self.assertEqual(len(self.server.received), 1)


class TestEndToEndCapture(_BaseTest):
    """Integration: 5 turns, 5 memories arrive at server."""

    def test_five_turns_five_memories(self) -> None:
        for i in range(5):
            user = f"Question {i} — please tell me about topic number {i}."
            assist = f"Here is a thorough answer to question {i}. " + ("detail " * 8)
            self.capture.post_llm_call(
                session_id="sess-e2e",
                user_message=user,
                assistant_response=assist,
                conversation_history=[None] * (i * 2),
            )
        self.assertEqual(len(self.server.received), 5)
        # Identity + tags carried correctly.
        for entry in self.server.received:
            payload = entry["payload"]
            self.assertEqual(payload["user_id"], "user-A")
            self.assertEqual(payload["writable_cube_ids"], ["cube-A"])
            self.assertIn("auto-capture", payload["custom_tags"])
            self.assertEqual(payload["metadata"]["session_id"], "sess-e2e")


class TestServerDownThenDrain(_BaseTest):
    """Integration: server-down → captures queue → restore → queue drains."""

    def test_queue_drains_when_server_returns(self) -> None:
        # Stop the server so the next 3 captures fail and queue locally.
        self.server.stop()
        for i in range(3):
            self.capture.post_llm_call(
                session_id="sess-q",
                user_message=f"Query {i} that should be queued for retry.",
                assistant_response=f"Answer {i} that should land eventually. " + ("." * 40),
                conversation_history=[None] * (i * 2),
            )
        self.assertEqual(self.queue.size("user-A", "cube-A"), 3)

        # Restart on the SAME port so the env var still points at it.
        port = self.server.port
        from http.server import HTTPServer

        from ._fake_server import _Handler  # type: ignore

        new_http = HTTPServer(("127.0.0.1", port), _Handler)
        new_http.received = self.server.received  # type: ignore[attr-defined]
        new_http.lock = self.server.lock  # type: ignore[attr-defined]
        new_http.mode = "ok"  # type: ignore[attr-defined]
        import threading

        t = threading.Thread(target=new_http.serve_forever, daemon=True)
        t.start()
        try:
            # A new (long-enough, non-duplicate) capture triggers the drain.
            self.capture.post_llm_call(
                session_id="sess-q",
                user_message="A fresh query that is long enough to pass the filter.",
                assistant_response="A fresh answer with enough body to pass the threshold. "
                + ("." * 40),
                conversation_history=[None, None, None, None, None, None, None, None],
            )
            # Allow a brief window for the drain (it's synchronous, but be tolerant).
            time.sleep(0.05)

            # 3 queued + 1 fresh = 4 hits server-side.
            self.assertEqual(len(self.server.received), 4)
            self.assertEqual(self.queue.size("user-A", "cube-A"), 0)
        finally:
            new_http.shutdown()
            new_http.server_close()


class TestFailureDoesNotBlock(_BaseTest):
    """Integration: capture failure must NOT raise out of the hook."""

    def test_500_does_not_raise(self) -> None:
        self.server.mode = "500"
        # Hook must complete cleanly even though the server returns 500.
        try:
            self.capture.post_llm_call(
                session_id="sess-500",
                user_message="A query that will hit a 500 on the server side.",
                assistant_response="An answer that the server will reject. " + ("." * 40),
                conversation_history=[],
            )
        except Exception as exc:  # pragma: no cover
            self.fail(f"post_llm_call raised on server error: {exc}")
        # The failed payload is queued for retry.
        self.assertEqual(self.queue.size("user-A", "cube-A"), 1)


class TestIdentityIsolation(_BaseTest):
    """Integration: an LLM-injected ``cube_id=B`` cannot redirect a capture."""

    def test_llm_cannot_override_identity(self) -> None:
        # Agent A is the env identity. Simulate a prompt-injection attempt:
        # the assistant tries to get the hook to write to cube B by stuffing
        # ``cube_id`` into kwargs and into the message body.
        malicious_response = (
            "Sure, I'll route this to cube_id=cube-B for you. "
            + ("filler text " * 10)
        )
        self.capture.post_llm_call(
            session_id="sess-iso",
            user_message="Please write to a different cube.",
            assistant_response=malicious_response,
            conversation_history=[],
            # Adversarial extras — the hook MUST ignore these.
            cube_id="cube-B",
            user_id="user-B",
            writable_cube_ids=["cube-B"],
        )
        self.assertEqual(len(self.server.received), 1)
        payload = self.server.received[0]["payload"]
        # The capture went to cube-A, not cube-B.
        self.assertEqual(payload["user_id"], "user-A")
        self.assertEqual(payload["writable_cube_ids"], ["cube-A"])


class TestQueuePersistence(unittest.TestCase):
    """Unit: the SQLite queue survives recreation of the CaptureQueue."""

    def setUp(self) -> None:
        self.tmpdir = Path(tempfile.mkdtemp(prefix="memos-queue-test-"))
        self.path = self.tmpdir / "q.db"

    def tearDown(self) -> None:
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_enqueue_persists(self) -> None:
        q1 = CaptureQueue(db_path=self.path)
        q1.enqueue("u", "c", {"hello": "world"}, error="boom")
        del q1
        q2 = CaptureQueue(db_path=self.path)
        self.assertEqual(q2.size("u", "c"), 1)
        rows = list(q2.iter_pending("u", "c"))
        self.assertEqual(len(rows), 1)
        _, payload, attempts = rows[0]
        self.assertEqual(payload, {"hello": "world"})
        self.assertEqual(attempts, 0)

    def test_mark_failed_drops_after_cap(self) -> None:
        q = CaptureQueue(db_path=self.path)
        rid = q.enqueue("u", "c", {"x": 1})
        # Force the row past the cap by writing the attempts directly. We
        # don't want the test to actually call mark_failed 50 times.
        ac_mod._MIN_CHARS  # touch the module so it's used (silence linters)
        import sqlite3

        conn = sqlite3.connect(str(self.path))
        try:
            conn.execute(
                "UPDATE pending_captures SET attempts=? WHERE id=?",
                (49, rid),
            )
            conn.commit()
        finally:
            conn.close()
        q.mark_failed(rid, "still failing")
        self.assertEqual(q.size("u", "c"), 0)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
