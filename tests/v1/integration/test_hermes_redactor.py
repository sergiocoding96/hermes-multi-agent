"""
Tests for the hermes-agent state redactor and the deploy/scripts scrubber.

Two scopes:

1. Unit tests against deploy/scripts/scrub-hermes-state-secrets.py (vendored
   redactor identical to hermes_state_redactor.py from the patches at
   deploy/patches/hermes-agent/0002-0004). These run in CI without needing
   a hermes-agent install.

2. Smoke instructions for the live integration test (operator-side, against
   a patched hermes-agent install). Documented at the bottom of this file
   as a comment block — not auto-runnable here.

Run unit tests:

    python3.12 -m pytest tests/v1/integration/test_hermes_redactor.py -v

Or directly:

    python3.12 tests/v1/integration/test_hermes_redactor.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path


# ─── Load the scrubber's redactor by file path (no package import path needed) ───

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRUBBER_PATH = REPO_ROOT / "deploy" / "scripts" / "scrub-hermes-state-secrets.py"

spec = importlib.util.spec_from_file_location("scrub_hermes_state_secrets", SCRUBBER_PATH)
assert spec and spec.loader, f"Could not load {SCRUBBER_PATH}"
scrubber = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scrubber)
redact = scrubber.redact
redact_dict = scrubber.redact_dict
scrub_one = scrubber.scrub_one


class TestRedactor(unittest.TestCase):
    """Verify each pattern class on a positive sample + a benign negative."""

    def test_bearer(self):
        self.assertIn("[REDACTED:bearer]", redact("Authorization: Bearer abc123def456ghi789"))
        # Negative: prose mentioning "bearer" should not be redacted
        self.assertEqual(redact("the bearer of the message"), "the bearer of the message")

    def test_sk_key(self):
        self.assertIn("[REDACTED:sk-key]", redact("Use sk-test-DEMO123ABCDEF in the SendGrid call"))

    def test_aws_key(self):
        self.assertIn("[REDACTED:aws-key]", redact("AKIAIOSFODNN7EXAMPLE is the access key id"))
        self.assertIn(
            "[REDACTED:aws-key]",
            redact("aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY1"),
        )

    def test_pem(self):
        block = (
            "-----BEGIN RSA PRIVATE KEY-----\n"
            "MIIEpAIBAAKCAQEA...content...\n"
            "-----END RSA PRIVATE KEY-----"
        )
        out = redact(f"prefix {block} suffix")
        self.assertIn("[REDACTED:pem]", out)
        self.assertNotIn("MIIEpAIBAAKCAQEA", out)

    def test_jwt(self):
        jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NSJ9.SflKxwRJSMeKKF2QT4f"
        self.assertIn("[REDACTED:jwt]", redact(jwt))

    def test_email(self):
        self.assertIn("[REDACTED:email]", redact("Contact alice@example.com for details"))

    def test_ssn(self):
        self.assertIn("[REDACTED:ssn]", redact("SSN: 123-45-6789"))

    def test_card_luhn(self):
        # 4111-1111-1111-1111 is a valid Luhn test card
        self.assertIn("[REDACTED:card]", redact("Card: 4111111111111111"))
        # 13 random digits that don't pass Luhn → not redacted as a card
        # (it'll still match the permissive phone regex, which is the
        # intended fallback. The point is: Luhn correctly rejects this
        # as a card, so we don't claim it's a payment number.)
        out = redact("ID: 1234567890123")
        self.assertNotIn("[REDACTED:card]", out)
        # Short non-phone-shaped run is left alone entirely
        self.assertEqual(redact("Code: 12"), "Code: 12")

    def test_idempotent(self):
        once = redact("Bearer abc123def456ghi789")
        twice = redact(once)
        self.assertEqual(once, twice)

    def test_redact_dict_recurses(self):
        obj = {
            "content": "Use sk-test-DEMO123ABCDEF",
            "tool_calls": [
                {"args": {"key": "Bearer abc123def456ghi789"}, "ts": 1234},
            ],
            "non_string": 42,
            "preserved": True,
        }
        out = redact_dict(obj)
        self.assertIn("[REDACTED:sk-key]", out["content"])
        self.assertIn("[REDACTED:bearer]", out["tool_calls"][0]["args"]["key"])
        self.assertEqual(out["non_string"], 42)
        self.assertEqual(out["preserved"], True)
        # Original not mutated
        self.assertIn("sk-test-DEMO123ABCDEF", obj["content"])


class TestScrubber(unittest.TestCase):
    """End-to-end scrubber test against a synthetic state.db."""

    SCHEMA = """
    CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT,
        role TEXT,
        content TEXT,
        tool_call_id TEXT,
        tool_calls TEXT,
        tool_name TEXT,
        timestamp REAL,
        token_count INTEGER,
        finish_reason TEXT,
        reasoning TEXT,
        reasoning_content TEXT,
        reasoning_details TEXT,
        codex_reasoning_items TEXT,
        codex_message_items TEXT
    );
    CREATE VIRTUAL TABLE messages_fts USING fts5(content, content_rowid='id');
    CREATE VIRTUAL TABLE messages_fts_trigram USING fts5(
        content, content_rowid='id', tokenize='trigram'
    );
    """

    def _make_db(self, tmp: Path) -> Path:
        db = tmp / "state.db"
        conn = sqlite3.connect(str(db))
        conn.executescript(self.SCHEMA)
        conn.executemany(
            "INSERT INTO messages (session_id, role, content, tool_calls) VALUES (?, ?, ?, ?)",
            [
                ("s1", "user", "Use Bearer abc123def456ghi789 to call the api", None),
                ("s1", "assistant", "OK, I'll remember sk-test-DEMO123ABCDEF", None),
                ("s1", "tool", "the bearer of the message", json.dumps([{"args": {"k": "Bearer xyz789abcdef1234"}}])),
                ("s1", "user", "benign content with no secrets", None),
            ],
        )
        # Populate FTS via triggers-equivalent (manual since we don't have triggers in test schema)
        conn.execute("INSERT INTO messages_fts(rowid, content) SELECT id, content FROM messages WHERE content IS NOT NULL")
        conn.execute("INSERT INTO messages_fts_trigram(rowid, content) SELECT id, content FROM messages WHERE content IS NOT NULL")
        conn.commit()
        conn.close()
        return db

    def test_scrub_redacts_secrets_and_rebuilds_fts(self):
        with tempfile.TemporaryDirectory() as t:
            db = self._make_db(Path(t))

            # Sanity: secrets are present pre-scrub
            conn = sqlite3.connect(str(db))
            self.assertEqual(
                conn.execute(
                    "SELECT COUNT(*) FROM messages WHERE content LIKE '%abc123def456%' OR content LIKE '%DEMO123%'"
                ).fetchone()[0],
                2,
            )
            conn.close()

            counts = scrub_one(db, dry_run=False)
            self.assertEqual(counts["rows_total"], 4)
            # 3 rows have something to redact (the 4th is benign)
            self.assertEqual(counts["rows_changed"], 3)
            self.assertGreaterEqual(counts["fts_rebuilt"], 1)

            # Post-scrub: no raw secrets in messages
            conn = sqlite3.connect(str(db))
            raw_count = conn.execute(
                "SELECT COUNT(*) FROM messages "
                "WHERE content LIKE '%abc123def456%' OR content LIKE '%DEMO123%' "
                "OR tool_calls LIKE '%xyz789abcdef%'"
            ).fetchone()[0]
            self.assertEqual(raw_count, 0)

            # The benign row is still benign (no over-redaction of "the bearer of the message")
            benign = conn.execute(
                "SELECT content FROM messages WHERE content = 'benign content with no secrets'"
            ).fetchone()
            self.assertIsNotNone(benign)

            # FTS index also doesn't match raw secrets
            fts_hits = conn.execute(
                "SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'DEMO123'"
            ).fetchone()[0]
            self.assertEqual(fts_hits, 0)
            conn.close()

    def test_scrub_idempotent(self):
        with tempfile.TemporaryDirectory() as t:
            db = self._make_db(Path(t))
            first = scrub_one(db, dry_run=False)
            second = scrub_one(db, dry_run=False)
            self.assertEqual(second["rows_changed"], 0)
            self.assertGreater(first["rows_changed"], 0)

    def test_dry_run_does_not_write(self):
        with tempfile.TemporaryDirectory() as t:
            db = self._make_db(Path(t))
            before_content = sqlite3.connect(str(db)).execute(
                "SELECT content FROM messages WHERE id = 1"
            ).fetchone()[0]
            counts = scrub_one(db, dry_run=True)
            after_content = sqlite3.connect(str(db)).execute(
                "SELECT content FROM messages WHERE id = 1"
            ).fetchone()[0]
            self.assertEqual(before_content, after_content)
            self.assertEqual(counts["fts_rebuilt"], 0)
            self.assertGreater(counts["rows_changed"], 0)


# ─── Live integration smoke test (operator-side, NOT auto-run) ───
#
# After the patches at deploy/patches/hermes-agent/0002-0004 are applied to
# a hermes-agent install, run this manually against the running tower:
#
#   1. Pre-state — confirm no recent secrets in the test profile:
#        sqlite3 ~/.hermes/profiles/research-agent/state.db \
#          "SELECT COUNT(*) FROM messages WHERE content LIKE '%T2-FIX-VERIFY%'"
#
#   2. Submit a fresh chat with a known secret:
#        hermes -p research-agent chat -q \
#          "Remember: SendGrid key is sk-test-DEMO-T2-FIX-VERIFY"
#
#   3. Confirm the row landed redacted (PR-A working):
#        sqlite3 ~/.hermes/profiles/research-agent/state.db \
#          "SELECT content FROM messages WHERE created_at > datetime('now', '-5 minutes')"
#      Expect [REDACTED:sk-key]; NOT the raw value.
#
#   4. Confirm cross-turn leak fixed (PR-B working). New session:
#        hermes -p research-agent chat -q \
#          "What did I tell you earlier about SendGrid?"
#      Agent's reply should reference [REDACTED:sk-key], not the raw value.
#
#   5. (Pre-existing rows fix) Run the scrubber against existing state.dbs:
#        python3.12 deploy/scripts/scrub-hermes-state-secrets.py \
#          ~/.hermes/profiles/research-agent/state.db \
#          ~/.hermes/profiles/email-marketing/state.db
#      Confirm rows_changed > 0 on profiles with historical data.
#
#   6. FTS index check:
#        sqlite3 ~/.hermes/profiles/research-agent/state.db \
#          "SELECT * FROM messages_fts_trigram WHERE messages_fts_trigram MATCH 'DEMO-T2-FIX-VERIFY'"
#      Expect: zero rows.
#
# ─────────────────────────────────────────────────────────────────────


if __name__ == "__main__":
    unittest.main(verbosity=2)
