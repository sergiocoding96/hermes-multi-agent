#!/usr/bin/env python3.12
"""
One-shot scrubber for hermes-agent state.db files written before the
secret-redactor patches landed (deploy/patches/hermes-agent/0002-0004).

Walks every messages row, applies the same redactor, writes back via
UPDATE, then rebuilds the FTS indexes (messages_fts + messages_fts_trigram)
so searches can no longer hit the raw values either.

Usage
-----
Run once per profile after applying the patches:

    python3.12 deploy/scripts/scrub-hermes-state-secrets.py \\
        ~/.hermes/profiles/research-agent/state.db \\
        ~/.hermes/profiles/email-marketing/state.db \\
        ~/.hermes/profiles/ceo/state.db

Add ``--dry-run`` to print what *would* change without writing.

Safety
------
- The script takes a backup at ``<db>.pre-redaction-<timestamp>`` before
  writing. Drop the backup once you're satisfied.
- Idempotent: running twice does not double-redact (already-redacted
  text is a no-op for the redactor).
- The DB must NOT be open by a running hermes-agent process while this
  runs. Stop the agent first.

Why
---
The redactor patches ship the leak fix forward (writes go in redacted,
reads pass through the redactor on the way out). Existing rows from
before the patches still contain raw secrets in the SQLite data and the
FTS index. This scrubber retroactively cleans them.

See hermes-multi-agent issue #24 for context.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any

# ─── Mirror of hermes_state_redactor (same patterns; vendored to keep this
#     scrubber self-contained — no dependency on the patched runtime). ───

_PATTERNS: list[tuple[str, str, re.Pattern[str]]] = [
    # (class, lowercase-substring-hint, regex)
    ("pem", "-----begin",
     re.compile(r"-----BEGIN [A-Z ]+-----[\s\S]+?-----END [A-Z ]+-----")),
    ("jwt", "eyj",
     re.compile(r"\beyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\b")),
    ("bearer", "bearer",
     re.compile(r"\bBearer\s+[A-Za-z0-9._\-+/=]{8,}", re.IGNORECASE)),
    ("sk-key", "sk-",
     re.compile(r"\bsk-[A-Za-z0-9_\-]{16,}")),
    ("aws-key", "akia",
     re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("aws-key", "aws_secret",
     re.compile(r"aws_secret_access_key\s*=\s*[A-Za-z0-9/+=]{40}", re.IGNORECASE)),
    ("ssn", "-",
     re.compile(r"\b\d{3}-\d{2}-\d{4}\b")),
    ("email", "@",
     re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")),
    ("phone", "",
     re.compile(r"\+?\d{1,3}[\s\-.]?\(?\d{2,4}\)?[\s\-.]?\d{3,4}[\s\-.]?\d{3,4}")),
]
_CARD_RE = re.compile(r"\b\d{13,19}\b")


def _luhn_valid(num: str) -> bool:
    digits = [int(c) for c in num if c.isdigit()]
    if len(digits) < 13:
        return False
    parity = len(digits) % 2
    total = 0
    for i, d in enumerate(digits):
        if i % 2 == parity:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


def redact(text: str) -> str:
    if not isinstance(text, str) or not text:
        return text
    out = text
    # Card numbers FIRST (Luhn-validated) — so the permissive phone regex
    # doesn't eat 16-digit PANs and label them [REDACTED:phone].
    if any(c.isdigit() for c in out):
        def _card_sub(m: re.Match[str]) -> str:
            return "[REDACTED:card]" if _luhn_valid(m.group(0)) else m.group(0)
        out = _CARD_RE.sub(_card_sub, out)
    lower = out.lower()
    for cls, hint, pattern in _PATTERNS:
        if hint and hint not in lower:
            continue
        out = pattern.sub(f"[REDACTED:{cls}]", out)
    return out


def redact_dict(obj: Any) -> Any:
    if isinstance(obj, str):
        return redact(obj)
    if isinstance(obj, dict):
        return {k: redact_dict(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact_dict(v) for v in obj]
    return obj


# ─── Scrubber ───

def backup(db_path: Path) -> Path:
    """Copy db_path to db_path.pre-redaction-<unix-ts>; return backup path."""
    stamp = int(time.time())
    bak = db_path.with_suffix(db_path.suffix + f".pre-redaction-{stamp}")
    shutil.copy2(db_path, bak)
    return bak


def scrub_one(db_path: Path, dry_run: bool) -> dict[str, int]:
    """
    Scrub one state.db. Returns counts: {rows_total, rows_changed, fts_rebuilt}.
    """
    counts = {"rows_total": 0, "rows_changed": 0, "fts_rebuilt": 0}
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    try:
        cur = conn.execute(
            "SELECT id, content, tool_calls FROM messages "
            "WHERE content IS NOT NULL OR tool_calls IS NOT NULL"
        )
        rows = cur.fetchall()
        counts["rows_total"] = len(rows)

        for row in rows:
            new_content = redact(row["content"]) if row["content"] is not None else None
            new_tool_calls = row["tool_calls"]
            if new_tool_calls:
                try:
                    parsed = json.loads(new_tool_calls)
                    redacted = redact_dict(parsed)
                    new_tool_calls = json.dumps(redacted)
                except (json.JSONDecodeError, TypeError):
                    # Treat as opaque string; redact as text
                    new_tool_calls = redact(new_tool_calls)

            if new_content == row["content"] and new_tool_calls == row["tool_calls"]:
                continue

            counts["rows_changed"] += 1
            if dry_run:
                continue
            conn.execute(
                "UPDATE messages SET content = ?, tool_calls = ? WHERE id = ?",
                (new_content, new_tool_calls, row["id"]),
            )

        if not dry_run and counts["rows_changed"] > 0:
            # Rebuild FTS indexes so searches don't hit the raw values either.
            for fts in ("messages_fts", "messages_fts_trigram"):
                try:
                    conn.execute(f"INSERT INTO {fts}({fts}) VALUES('rebuild')")
                    counts["fts_rebuilt"] += 1
                except sqlite3.OperationalError:
                    # Index may not exist on older schemas; non-fatal.
                    pass
            conn.commit()

    finally:
        conn.close()

    return counts


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Retroactively redact secrets from hermes-agent state.db files.",
    )
    parser.add_argument("dbs", nargs="+", type=Path, help="Path(s) to state.db")
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print what would change without writing or rebuilding FTS",
    )
    parser.add_argument(
        "--no-backup", action="store_true",
        help="Skip the safety backup. Don't.",
    )
    args = parser.parse_args()

    rc = 0
    for db_path in args.dbs:
        if not db_path.exists():
            print(f"[skip] {db_path} — does not exist", file=sys.stderr)
            rc = 1
            continue

        print(f"[scrub] {db_path}")
        if not args.dry_run and not args.no_backup:
            bak = backup(db_path)
            print(f"  backup: {bak}")

        try:
            counts = scrub_one(db_path, args.dry_run)
        except Exception as e:  # pragma: no cover — diagnostic path
            print(f"  ERROR: {e}", file=sys.stderr)
            rc = 1
            continue

        action = "would change" if args.dry_run else "changed"
        print(
            f"  rows: {counts['rows_total']} scanned, "
            f"{counts['rows_changed']} {action}; "
            f"fts indexes rebuilt: {counts['fts_rebuilt']}"
        )

    return rc


if __name__ == "__main__":
    sys.exit(main())
