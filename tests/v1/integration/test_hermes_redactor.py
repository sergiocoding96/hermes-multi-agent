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
scrub_markdown = scrubber.scrub_markdown
scrub_session_json = scrubber.scrub_session_json
discover_profile_targets = scrubber.discover_profile_targets
scrub_dispatch = scrubber.scrub_dispatch


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


class TestMarkdownScrubber(unittest.TestCase):
    """Scrub historical USER.md / MEMORY.md files (PR-C retroactive cleanup)."""

    DELIMITER = "\n§\n"

    def _make_md(self, tmp: Path, name: str = "USER.md") -> Path:
        path = tmp / name
        entries = [
            "Favorite color is teal-green",
            "SendGrid test key: sk-test-DEMO-T2-FIX-VERIFY — used for email integration",
            "the bearer of the message is benign prose",
            "Card on file: 4111111111111111",
        ]
        path.write_text(self.DELIMITER.join(entries), encoding="utf-8")
        return path

    def test_scrub_redacts_entries_and_preserves_structure(self):
        with tempfile.TemporaryDirectory() as t:
            md = self._make_md(Path(t))

            counts = scrub_markdown(md, dry_run=False)
            self.assertEqual(counts["rows_total"], 4)
            # 2 entries change: the sk- key and the card number.
            # Benign prose and the favorite color stay put.
            self.assertEqual(counts["rows_changed"], 2)
            self.assertEqual(counts["fts_rebuilt"], 0)

            text = md.read_text(encoding="utf-8")
            self.assertNotIn("sk-test-DEMO-T2-FIX-VERIFY", text)
            self.assertNotIn("4111111111111111", text)
            self.assertIn("[REDACTED:sk-key]", text)
            self.assertIn("[REDACTED:card]", text)
            # Benign content untouched
            self.assertIn("the bearer of the message is benign prose", text)
            self.assertIn("Favorite color is teal-green", text)
            # Delimiter structure preserved (4 entries → 3 separators)
            self.assertEqual(text.count(self.DELIMITER), 3)

    def test_scrub_idempotent(self):
        with tempfile.TemporaryDirectory() as t:
            md = self._make_md(Path(t))
            first = scrub_markdown(md, dry_run=False)
            second = scrub_markdown(md, dry_run=False)
            self.assertGreater(first["rows_changed"], 0)
            self.assertEqual(second["rows_changed"], 0)

    def test_dry_run_does_not_write(self):
        with tempfile.TemporaryDirectory() as t:
            md = self._make_md(Path(t))
            before = md.read_text(encoding="utf-8")
            counts = scrub_markdown(md, dry_run=True)
            after = md.read_text(encoding="utf-8")
            self.assertEqual(before, after)
            self.assertGreater(counts["rows_changed"], 0)

    def test_empty_file_no_op(self):
        with tempfile.TemporaryDirectory() as t:
            md = Path(t) / "USER.md"
            md.write_text("", encoding="utf-8")
            counts = scrub_markdown(md, dry_run=False)
            self.assertEqual(counts, {"rows_total": 0, "rows_changed": 0, "fts_rebuilt": 0})


class TestSessionJsonScrubber(unittest.TestCase):
    """Scrub historical sessions/*.json dumps (PR-D retroactive cleanup)."""

    def _make_session_json(self, tmp: Path) -> Path:
        path = tmp / "session_20260101_120000_abcdef.json"
        entry = {
            "session_id": "20260101_120000_abcdef",
            "model": "claude-opus-4-7",
            "system_prompt": "You are an agent. Bearer abc123def456ghi789 is the test header.",
            "tools": [{"name": "noop", "description": "AKIAIOSFODNN7EXAMPLE owner"}],
            "message_count": 3,
            "messages": [
                {"role": "user", "content": "Use sk-test-DEMO123ABCDEF in the SendGrid call"},
                {"role": "assistant", "content": "OK, will use it once."},
                {
                    "role": "tool",
                    "content": "result",
                    "tool_calls": [{"args": {"key": "Bearer xyz789abcdef1234"}}],
                },
            ],
        }
        path.write_text(json.dumps(entry, indent=2), encoding="utf-8")
        return path

    def test_scrub_redacts_messages_and_metadata(self):
        with tempfile.TemporaryDirectory() as t:
            j = self._make_session_json(Path(t))
            counts = scrub_session_json(j, dry_run=False)
            self.assertEqual(counts["rows_total"], 3)
            # 2 messages have secrets (user + tool); assistant is clean.
            self.assertEqual(counts["rows_changed"], 2)

            after = json.loads(j.read_text(encoding="utf-8"))
            self.assertIn("[REDACTED:bearer]", after["system_prompt"])
            self.assertIn("[REDACTED:aws-key]", after["tools"][0]["description"])
            self.assertNotIn("sk-test-DEMO123ABCDEF", json.dumps(after))
            self.assertNotIn("xyz789abcdef1234", json.dumps(after))
            # Untouched message stays untouched
            self.assertEqual(after["messages"][1]["content"], "OK, will use it once.")
            # Non-string structure preserved
            self.assertEqual(after["message_count"], 3)

    def test_scrub_idempotent(self):
        with tempfile.TemporaryDirectory() as t:
            j = self._make_session_json(Path(t))
            first = scrub_session_json(j, dry_run=False)
            second = scrub_session_json(j, dry_run=False)
            self.assertGreater(first["rows_changed"], 0)
            self.assertEqual(second["rows_changed"], 0)

    def test_metadata_only_change_still_counts(self):
        """If only system_prompt has a secret (no message changes), report 1."""
        with tempfile.TemporaryDirectory() as t:
            path = Path(t) / "session_x.json"
            path.write_text(json.dumps({
                "session_id": "x",
                "system_prompt": "header: Bearer abc123def456ghi789",
                "messages": [{"role": "user", "content": "hi"}],
            }), encoding="utf-8")
            counts = scrub_session_json(path, dry_run=False)
            self.assertEqual(counts["rows_changed"], 1)
            self.assertNotIn("abc123def456", path.read_text(encoding="utf-8"))

    def test_malformed_json_no_op(self):
        with tempfile.TemporaryDirectory() as t:
            path = Path(t) / "session_corrupt.json"
            path.write_text("{not valid json", encoding="utf-8")
            counts = scrub_session_json(path, dry_run=False)
            self.assertEqual(counts, {"rows_total": 0, "rows_changed": 0, "fts_rebuilt": 0})


class TestProfileDiscovery(unittest.TestCase):
    """Auto-discover scrub targets under a profile root."""

    def test_discover_finds_all_three_kinds(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t) / "research-agent"
            (root / "memories").mkdir(parents=True)
            (root / "sessions").mkdir(parents=True)
            (root / "state.db").write_text("(stub)")
            (root / "memories" / "USER.md").write_text("foo")
            (root / "memories" / "MEMORY.md").write_text("bar")
            (root / "sessions" / "session_a.json").write_text("{}")
            (root / "sessions" / "session_b.json").write_text("{}")
            # Decoy files that should NOT be picked up:
            (root / "sessions" / "request_dump_x.json").write_text("{}")
            (root / "memories" / "scratch.txt").write_text("nope")

            targets = discover_profile_targets(root)
            names = [p.name for p in targets]
            self.assertEqual(names[0], "state.db")
            self.assertIn("USER.md", names)
            self.assertIn("MEMORY.md", names)
            self.assertIn("session_a.json", names)
            self.assertIn("session_b.json", names)
            self.assertNotIn("request_dump_x.json", names)
            self.assertNotIn("scratch.txt", names)

    def test_discover_silently_skips_missing_pieces(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t) / "fresh-profile"
            (root / "memories").mkdir(parents=True)
            (root / "memories" / "MEMORY.md").write_text("only this")
            # No state.db, no sessions/ — should not error.
            targets = discover_profile_targets(root)
            self.assertEqual([p.name for p in targets], ["MEMORY.md"])


class TestScrubDispatch(unittest.TestCase):
    """scrub_dispatch routes by extension."""

    def test_unknown_extension_raises(self):
        with self.assertRaises(ValueError):
            scrub_dispatch(Path("/tmp/whatever.xyz"), dry_run=True)


# ─── Live integration smoke test (operator-side, NOT auto-run) ───
#
# After the patches at deploy/patches/hermes-agent/0002-0006 are applied to a
# hermes-agent install, run this manually against the running tower. Steps 1–4
# verify state.db (PR-A/PR-B), steps 5–7 verify memories/USER.md (PR-C) and
# sessions/*.json (PR-D), step 8 is the cross-channel scrubber sweep.
#
#   1. Submit a fresh chat with a known secret:
#        hermes -p research-agent chat -q \
#          "Remember: SendGrid key is sk-test-DEMO-T2-FIX-VERIFY"
#
#   2. state.db landed redacted (PR-A):
#        sqlite3 ~/.hermes/profiles/research-agent/state.db \
#          "SELECT content FROM messages WHERE timestamp > strftime('%s','now','-5 minutes')"
#      Expect [REDACTED:sk-key]; NOT the raw value.
#
#   3. memories/USER.md landed redacted (PR-C write path):
#        grep -E "DEMO-T2-FIX-VERIFY|REDACTED" \
#          ~/.hermes/profiles/research-agent/memories/USER.md
#      Expect: [REDACTED:sk-key]. The raw value must NOT appear.
#
#   4. sessions/*.json landed redacted (PR-D write path):
#        grep -lE "DEMO-T2-FIX-VERIFY|REDACTED" \
#          ~/.hermes/profiles/research-agent/sessions/session_*.json
#      Expect only redacted matches in the latest dumps.
#
#   5. Cross-turn leak fixed end-to-end (PR-B + PR-C read paths). New session:
#        hermes -p research-agent chat -q \
#          "What did I tell you earlier about SendGrid?"
#      Agent's reply should reference [REDACTED:sk-key], not the raw value.
#
#   6. FTS index check:
#        sqlite3 ~/.hermes/profiles/research-agent/state.db \
#          "SELECT * FROM messages_fts_trigram WHERE messages_fts_trigram MATCH 'DEMO-T2-FIX-VERIFY'"
#      Expect: zero rows.
#
#   7. (Pre-existing data) Scrub historical files via profile auto-discovery:
#        python3.12 deploy/scripts/scrub-hermes-state-secrets.py \
#          --profile ~/.hermes/profiles/research-agent \
#          --profile ~/.hermes/profiles/email-marketing
#      Walks state.db + memories/*.md + sessions/*.json. Run twice — second
#      run must report rows_changed=0 everywhere (idempotent).
#
# ─────────────────────────────────────────────────────────────────────


if __name__ == "__main__":
    unittest.main(verbosity=2)
