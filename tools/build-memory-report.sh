#!/usr/bin/env bash
# Regenerate the comprehensive memory report PDF from its HTML source.
#
# STANDING PROCESS (set 2026-05-27): every memory change updates this report.
#   1. Edit the source deck:
#        docs/architecture/2026-05-27-memory-comprehensive-report-deck.html
#   2. Run this script to rebuild the PDF.
#   3. Commit both.
#   4. Refresh the Drive copy (Google Doc) in folder "Memory System"
#      (1WSCcEJ-Zfe3mgvfeCLsBK0wEkUoiHojm). Note: service-account binary upload
#      is blocked (no quota on personal My Drive) — update the Doc via the Drive
#      MCP (text), or File→Download→PDF the Doc, until the folder is a Shared Drive.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/docs/architecture/2026-05-27-memory-comprehensive-report-deck.html"
OUT="$REPO/docs/architecture/Hermes-Memory-System-Comprehensive-Report-2026-05-27.pdf"

[ -f "$SRC" ] || { echo "missing source deck: $SRC" >&2; exit 1; }

google-chrome --headless --no-sandbox --disable-gpu \
  --print-to-pdf="$OUT" --no-pdf-header-footer "file://$SRC"

pages="$(pdfinfo "$OUT" 2>/dev/null | awk '/^Pages:/{print $2}')"
echo "built: $OUT (${pages:-?} pages, $(stat -c%s "$OUT") bytes)"
echo "next: commit, then refresh the Drive Doc (see header)."
