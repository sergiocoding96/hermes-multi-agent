#!/usr/bin/env bash
# patch-hermes-adapter.sh
#
# Fixes a bug in hermes-paperclip-adapter/dist/server/execute.js where the
# wake-context fields (taskId, taskTitle, taskBody, commentId, wakeReason,
# companyName, projectName) are read from `ctx.config` instead of
# `ctx.context`. Paperclip's heartbeat service puts these fields on
# `ctx.context` (contextSnapshot); `ctx.config` is only the resolved
# runtimeConfig (workspace + skills). As a result, every wake — including
# `issue_assigned` — was rendering the `{{#noTask}}` branch of the prompt
# template.
#
# This script rewrites the 8 affected reads in place, adds fallbacks to
# `ctx.context.paperclipWake.issue.{id,title,body}` for completeness, and
# makes a timestamped backup of the original file.
#
# Idempotent — detects a sentinel comment and no-ops if already patched.
#
# Scope note: TASK.md originally forbade touching
# `/home/linuxbrew/.linuxbrew/lib/node_modules/hermes-paperclip-adapter/**`.
# Scope was explicitly expanded when the prompt-template-only fix (Option 1)
# was found to be insufficient: the taskId-routing bug means the template's
# `{{#taskId}}` conditional never triggers and the agent never sees its
# assigned task. See
# memos-setup/learnings/2026-04-21-paperclip-hermes-adapter-auth-gap.md for
# the full analysis.
#
# Revert: restore the timestamped backup and remove the sentinel line.
#
# Usage:
#   ./patch-hermes-adapter.sh
# Override target path (disables auto-discovery):
#   HERMES_ADAPTER_EXECUTE=/path/to/execute.js ./patch-hermes-adapter.sh
#
# Auto-discovery note: paperclipai bundles its own copy of
# hermes-paperclip-adapter under its node_modules. That bundled copy is what
# `paperclipai run` actually imports — patching the top-level global copy
# alone is a no-op at runtime. This script discovers and patches EVERY
# execute.js for hermes-paperclip-adapter under the npm global prefix.

set -euo pipefail

SENTINEL_TAG="patched-by-fix-paperclip-agent-auth-v1"
SENTINEL="// $SENTINEL_TAG — wake-context reads migrated from ctx.config to ctx.context"

log() { printf '[patch-hermes-adapter] %s\n' "$*" >&2; }
die() { printf '[patch-hermes-adapter] ERROR: %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null || die "python3 is required"
command -v node    >/dev/null || die "node is required"

# Build the list of targets.
TARGETS=()
if [ -n "${HERMES_ADAPTER_EXECUTE:-}" ]; then
  TARGETS=("$HERMES_ADAPTER_EXECUTE")
else
  npm_root="$(npm root -g 2>/dev/null || true)"
  search_roots=()
  [ -n "$npm_root" ] && [ -d "$npm_root" ] && search_roots+=("$npm_root")
  [ -d /home/linuxbrew/.linuxbrew/lib/node_modules ] \
    && search_roots+=("/home/linuxbrew/.linuxbrew/lib/node_modules")
  if [ "${#search_roots[@]}" -eq 0 ]; then
    die "could not locate any global node_modules directory; set HERMES_ADAPTER_EXECUTE"
  fi
  while IFS= read -r path; do
    [ -n "$path" ] && TARGETS+=("$path")
  done < <(find "${search_roots[@]}" -path '*hermes-paperclip-adapter/dist/server/execute.js' -type f 2>/dev/null | sort -u)
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  die "no hermes-paperclip-adapter execute.js found under search roots; set HERMES_ADAPTER_EXECUTE"
fi

log "targets (${#TARGETS[@]}):"
for t in "${TARGETS[@]}"; do log "  - $t"; done

patched=0; skipped=0
for TARGET in "${TARGETS[@]}"; do
  [ -f "$TARGET" ] || { log "missing, skipping: $TARGET"; continue; }
  [ -w "$TARGET" ] || die "not writable: $TARGET (chmod +w or run as owner)"

  if grep -q "$SENTINEL_TAG" "$TARGET"; then
    log "already patched — skipping: $TARGET"
    skipped=$((skipped + 1))
    continue
  fi

  backup="$TARGET.orig-$(date +%Y%m%d-%H%M%S)"
  cp "$TARGET" "$backup"
  log "backup saved: $backup"

  python3 - "$TARGET" <<'PY'
import sys, pathlib

target = pathlib.Path(sys.argv[1])
src = target.read_text()

# (old_snippet, new_snippet). Each old_snippet must appear exactly as shown
# in the current hermes-paperclip-adapter dist; if any of them fail to find a
# match we abort so the file isn't left half-patched.
replacements = [
    (
        "cfgString(ctx.config?.taskId)",
        "(cfgString(ctx.context?.taskId) || cfgString(ctx.context?.issueId) || cfgString(ctx.context?.paperclipWake?.issue?.id))",
    ),
    (
        'cfgString(ctx.config?.taskTitle) || ""',
        '(cfgString(ctx.context?.taskTitle) || cfgString(ctx.context?.paperclipWake?.issue?.title) || "")',
    ),
    (
        'cfgString(ctx.config?.taskBody) || ""',
        '(cfgString(ctx.context?.taskBody) || cfgString(ctx.context?.paperclipWake?.issue?.body) || "")',
    ),
    (
        'cfgString(ctx.config?.commentId) || ""',
        '(cfgString(ctx.context?.commentId) || cfgString(ctx.context?.wakeCommentId) || "")',
    ),
    (
        'cfgString(ctx.config?.wakeReason) || ""',
        'cfgString(ctx.context?.wakeReason) || ""',
    ),
    (
        'cfgString(ctx.config?.companyName) || ""',
        'cfgString(ctx.context?.companyName) || ""',
    ),
    (
        'cfgString(ctx.config?.projectName) || ""',
        'cfgString(ctx.context?.projectName) || ""',
    ),
]

missing = []
for old, _new in replacements:
    if old not in src:
        missing.append(old)

if missing:
    sys.stderr.write(
        "Expected string(s) not found in execute.js — adapter version may have\n"
        "changed. Patch aborted. Missing:\n  " + "\n  ".join(missing) + "\n"
    )
    sys.exit(2)

for old, new in replacements:
    # Order-of-operations: the commentId / taskBody / taskTitle replacements
    # must run before the bare taskId replacement because the latter's pattern
    # is a substring of the others' left-hand sides via the same cfgString
    # wrapper. We replace all at once but the exact-string match keeps each
    # distinct.
    src = src.replace(old, new)

target.write_text(src)
PY

  # Sentinel on a new line at EOF. execute.js ends with a sourceMappingURL
  # comment — appending another comment is safe.
  { printf '\n%s\n' "$SENTINEL"; } >> "$TARGET"

  # Verify the patched file still parses as JS.
  node --check "$TARGET" \
    || die "node --check failed after patch ($TARGET) — restoring backup: cp $backup $TARGET"

  log "patched ok: $TARGET"
  log "to revert:  cp \"$backup\" \"$TARGET\""
  patched=$((patched + 1))
done

log "summary: patched=$patched, skipped=$skipped, total=${#TARGETS[@]}"
log "sentinel: $SENTINEL_TAG"
log "NOTE: restart paperclipai for the patch to take effect — Node caches modules in-memory."
