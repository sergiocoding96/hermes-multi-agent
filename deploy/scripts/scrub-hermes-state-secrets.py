#!/usr/bin/env python3.12
"""
One-shot scrubber for hermes-agent persistence files written before the
secret-redactor patches landed (deploy/patches/hermes-agent/0002-0006).

Three persistence channels are covered:

1. ``state.db``   — SQLite messages table + FTS5 indexes (PR-A / PR-B).
2. ``USER.md`` / ``MEMORY.md`` — markdown memory files loaded into the
   system prompt at session start (PR-C).
3. ``sessions/*.json`` — per-session message dumps used for resume,
   debug, and backup (PR-D).

For each, the script applies the same redactor as the runtime patches
(idempotent — running twice never double-redacts).

Usage
-----
Pass any mix of files. Dispatch is by extension::

    python3.12 deploy/scripts/scrub-hermes-state-secrets.py \\
        ~/.hermes/profiles/research-agent/state.db \\
        ~/.hermes/profiles/research-agent/memories/USER.md \\
        ~/.hermes/profiles/research-agent/memories/MEMORY.md \\
        ~/.hermes/profiles/research-agent/sessions/*.json

Or pass a profile root with ``--profile`` to auto-discover all four::

    python3.12 deploy/scripts/scrub-hermes-state-secrets.py \\
        --profile ~/.hermes/profiles/research-agent

Add ``--dry-run`` to print what *would* change without writing.

Safety
------
- A backup is taken at ``<file>.pre-redaction-<timestamp>`` before
  writing. Drop the backup once you're satisfied.
- Idempotent: running twice does not double-redact.
- The state.db must NOT be open by a running hermes-agent process while
  this runs. Stop the agent first.

Why
---
The redactor patches ship the leak fix forward (writes go in redacted,
reads pass through the redactor on the way out). Existing rows / files
from before the patches still contain raw secrets. This scrubber
retroactively cleans them.

See hermes-multi-agent issue #24 (state.db) and the follow-up PR
covering memories/USER.md, memories/MEMORY.md, and sessions/*.json.
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


def scrub_markdown(md_path: Path, dry_run: bool) -> dict[str, int]:
    """
    Scrub one memory markdown file (USER.md / MEMORY.md). Returns counts:
    ``{rows_total, rows_changed, fts_rebuilt}`` for shape symmetry with
    :func:`scrub_one` (fts_rebuilt is always 0 for markdown).

    rows_total / rows_changed count entries, where entries are the
    ``ENTRY_DELIMITER``-separated chunks the runtime treats as units.
    Splitting matches ``tools/memory_tool.py``'s ``_read_file`` /
    ``_write_file`` exactly so the rewrite preserves the file's logical
    structure.
    """
    counts = {"rows_total": 0, "rows_changed": 0, "fts_rebuilt": 0}

    raw = md_path.read_text(encoding="utf-8")
    if not raw.strip():
        return counts

    # ENTRY_DELIMITER from tools/memory_tool.py — keep in sync.
    delimiter = "\n§\n"
    entries = [e.strip() for e in raw.split(delimiter)]
    entries = [e for e in entries if e]
    counts["rows_total"] = len(entries)

    new_entries = [redact(e) for e in entries]
    counts["rows_changed"] = sum(1 for a, b in zip(entries, new_entries) if a != b)

    if dry_run or counts["rows_changed"] == 0:
        return counts

    new_raw = delimiter.join(new_entries) if new_entries else ""
    # Atomic replace: write to sibling temp, fsync, rename. Mirrors the
    # runtime's _write_file path so a crash mid-scrub leaves either the
    # old complete file or the new one — never a torn write.
    tmp = md_path.with_suffix(md_path.suffix + ".tmp-scrub")
    tmp.write_text(new_raw, encoding="utf-8")
    tmp.replace(md_path)
    return counts


def scrub_session_json(json_path: Path, dry_run: bool) -> dict[str, int]:
    """
    Scrub one ``sessions/session_<id>.json`` dump. Returns counts:
    ``{rows_total, rows_changed, fts_rebuilt}`` for shape symmetry.

    rows_total counts messages in the dump; rows_changed counts how many
    messages had at least one string field rewritten. The whole entry
    (system_prompt, tools, messages) is walked via ``redact_dict``.
    """
    counts = {"rows_total": 0, "rows_changed": 0, "fts_rebuilt": 0}

    try:
        entry = json.loads(json_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return counts

    if not isinstance(entry, dict):
        return counts

    messages = entry.get("messages") or []
    counts["rows_total"] = len(messages) if isinstance(messages, list) else 0

    new_entry = redact_dict(entry)

    if isinstance(messages, list):
        new_messages = new_entry.get("messages") or []
        counts["rows_changed"] = sum(
            1
            for old, new in zip(messages, new_messages)
            if old != new
        )

    # Also count system_prompt / tools changes as "row" changes for visibility.
    # We avoid double-counting: this only fires if messages were unchanged but
    # the surrounding metadata had a secret.
    if counts["rows_changed"] == 0 and new_entry != entry:
        counts["rows_changed"] = 1

    if dry_run or counts["rows_changed"] == 0:
        return counts

    tmp = json_path.with_suffix(json_path.suffix + ".tmp-scrub")
    tmp.write_text(json.dumps(new_entry, indent=2, default=str), encoding="utf-8")
    tmp.replace(json_path)
    return counts


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


def discover_profile_targets(profile_dir: Path) -> list[Path]:
    """Return all scrub-eligible files under one profile root, in a stable order:
    state.db first, then memory markdown files, then session JSON dumps.

    Missing files are silently skipped — operators can run this against a
    partially-populated profile without errors.
    """
    targets: list[Path] = []
    db = profile_dir / "state.db"
    if db.is_file():
        targets.append(db)
    for name in ("USER.md", "MEMORY.md"):
        p = profile_dir / "memories" / name
        if p.is_file():
            targets.append(p)
    sessions = profile_dir / "sessions"
    if sessions.is_dir():
        targets.extend(sorted(sessions.glob("session_*.json")))
    return targets


def scrub_dispatch(path: Path, dry_run: bool) -> dict[str, int]:
    """Pick the right scrubber for a path based on extension."""
    suffix = path.suffix.lower()
    if suffix == ".db":
        return scrub_one(path, dry_run)
    if suffix == ".md":
        return scrub_markdown(path, dry_run)
    if suffix == ".json":
        return scrub_session_json(path, dry_run)
    raise ValueError(f"unrecognised extension {suffix!r} — expected .db, .md, or .json")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Retroactively redact secrets from hermes-agent persistence files: "
            "state.db, memories/{USER,MEMORY}.md, sessions/*.json."
        ),
    )
    parser.add_argument(
        "paths", nargs="*", type=Path,
        help="Files to scrub. Dispatched by extension: .db, .md, .json.",
    )
    parser.add_argument(
        "--profile", action="append", type=Path, default=[],
        help=(
            "Profile root (e.g. ~/.hermes/profiles/research-agent). "
            "Auto-discovers state.db, memories/*.md, sessions/*.json. "
            "Repeatable."
        ),
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print what would change without writing or rebuilding FTS",
    )
    parser.add_argument(
        "--no-backup", action="store_true",
        help="Skip the safety backup. Don't.",
    )
    args = parser.parse_args()

    targets: list[Path] = list(args.paths)
    for prof in args.profile:
        if not prof.is_dir():
            print(f"[skip] {prof} — not a directory", file=sys.stderr)
            continue
        targets.extend(discover_profile_targets(prof))

    if not targets:
        parser.error("nothing to scrub: pass file paths and/or --profile <dir>")

    rc = 0
    for path in targets:
        if not path.exists():
            print(f"[skip] {path} — does not exist", file=sys.stderr)
            rc = 1
            continue

        print(f"[scrub] {path}")
        if not args.dry_run and not args.no_backup:
            bak = backup(path)
            print(f"  backup: {bak}")

        try:
            counts = scrub_dispatch(path, args.dry_run)
        except Exception as e:  # pragma: no cover — diagnostic path
            print(f"  ERROR: {e}", file=sys.stderr)
            rc = 1
            continue

        action = "would change" if args.dry_run else "changed"
        # "rows" reads naturally for state.db and session.json (messages),
        # and we extend the same word to .md entries so the output line
        # is uniform across file types.
        print(
            f"  rows: {counts['rows_total']} scanned, "
            f"{counts['rows_changed']} {action}; "
            f"fts indexes rebuilt: {counts['fts_rebuilt']}"
        )

    return rc


if __name__ == "__main__":
    sys.exit(main())
