#!/usr/bin/env bash
#
# run-blind-audits.sh — checklist + paste-ready prompts for the 3 remaining
# Stage-4 audits (functionality-v2, resilience-v2, hub-sharing-v2).
#
# These audits MUST run as fresh Claude Code Desktop sessions per the
# methodology in tests/v2/README.md:
#   - no CLAUDE.md context
#   - no prior conversation
#   - paste the audit prompt as the FIRST message
#   - one audit per session, never combined
#
# This script doesn't run the audits — it can't (the methodology forbids
# it). It prints the per-audit checklist and shows the prompt path so
# you can copy it into a fresh session.

set -e

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMPTS_DIR="$REPO/tests/v2"

cat <<'BANNER'

╔══════════════════════════════════════════════════════════════════════╗
║  BLIND AUDIT LAUNCHER — Stage 4 (3 remaining)                        ║
║                                                                       ║
║  Open a fresh Claude Code Desktop session for EACH audit.            ║
║  Disable CLAUDE.md auto-load (--no-context or remove temporarily).   ║
║  Paste the prompt below as the FIRST message.                         ║
║  Let it run uninterrupted. One audit per session.                     ║
║                                                                       ║
║  Reports land at: tests/v2/reports/<name>-<date>.md                   ║
║  on branch: tests/v2.0-audit-reports-2026-04-22                       ║
╚══════════════════════════════════════════════════════════════════════╝
BANNER

for audit in functionality-v2 resilience-v2 hub-sharing-v2; do
  prompt_file="$PROMPTS_DIR/${audit}.md"
  echo
  echo "─── ${audit} ───────────────────────────────────────────────"
  echo "  prompt file: $prompt_file"
  echo "  prompt size: $(wc -l <"$prompt_file") lines"
  echo "  copy with:   cat $prompt_file | xclip -selection clipboard  # X11"
  echo "       or:     cat $prompt_file | pbcopy                       # macOS"
  echo "       or:     less $prompt_file                                # to read"
  echo
done

cat <<'AFTER'
After all 3 audits run, aggregate via:
  ls -la tests/v2/reports/*-2026-04-*.md
  git pull --rebase origin tests/v2.0-audit-reports-2026-04-22

Check if any audit scored < 5/10 and revisit blockers if so.
Note: the 2026-04-25 *non-blind* self-audits already in the reports
directory should be ignored for aggregation; the migration plan's
acceptance bar requires blind scores.
AFTER
