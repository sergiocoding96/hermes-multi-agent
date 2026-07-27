#!/usr/bin/env bash
# Auto-prune dead skills (Phase 1.3, 2026-05-27).
#
# Skills crystallize and accumulate; many never re-match. Now that usage_count
# is recorded on retrieval (the 2026-05-27 fix), we can ARCHIVE skills that have
# had a fair chance and zero usage. Archiving (status='archived') hides them from
# retrieval (tier-1 includes only active+candidate) but keeps the row — fully
# reversible, never deleted.
#
# Conservative by design + DRY-RUN by default. Intended to run periodically
# (e.g. weekly) so skills accrue usage data before being judged.
#
#   bash tools/prune-stale-skills.sh                 # dry-run: list candidates
#   bash tools/prune-stale-skills.sh --apply         # archive them
#   GRACE_DAYS=30 bash tools/prune-stale-skills.sh    # tune the grace window
set -euo pipefail

DB="${MEMOS_DB:-$HOME/.hermes/memos-plugin/data/memos.db}"
GRACE_DAYS="${GRACE_DAYS:-21}"
MAX_GAIN="${MAX_GAIN:-0.05}"        # only prune low-value skills
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

[ -f "$DB" ] || { echo "DB not found: $DB" >&2; exit 1; }

# A skill is "dead" iff: surfaced-but-never-used (usage_count=0, never last_used),
# older than the grace window, and low gain. Active+candidate only (archived already out).
WHERE="status IN ('active','candidate')
  AND COALESCE(usage_count,0)=0
  AND last_used_at IS NULL
  AND (strftime('%s','now') - created_at/1000) > ${GRACE_DAYS}*86400
  AND COALESCE(gain,0) < ${MAX_GAIN}"

echo "Dead-skill prune (grace=${GRACE_DAYS}d, max_gain=${MAX_GAIN}) — $([ "$APPLY" = 1 ] && echo APPLY || echo DRY-RUN)"
echo "Candidates:"
sqlite3 -header -column "$DB" "
  SELECT substr(name,1,40) name, owner_profile_id prof, usage_count uses,
         ROUND(COALESCE(gain,0),3) gain,
         ROUND((strftime('%s','now')-created_at/1000)/86400.0,1) age_days
  FROM skills WHERE ${WHERE} ORDER BY age_days DESC LIMIT 50;"
N=$(sqlite3 "$DB" "SELECT COUNT(*) FROM skills WHERE ${WHERE};")
echo "→ ${N} skill(s) match."

if [ "$APPLY" = 1 ] && [ "$N" -gt 0 ]; then
  sqlite3 "$DB" "UPDATE skills SET status='archived', updated_at=strftime('%s','now')*1000 WHERE ${WHERE};"
  echo "✓ archived ${N} skill(s) (reversible: set status back to 'candidate')."
elif [ "$APPLY" = 1 ]; then
  echo "(nothing to archive)"
else
  echo "(dry-run — re-run with --apply to archive)"
fi
