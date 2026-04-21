#!/usr/bin/env bash
# patch-hermes-adapter-jwt.sh
#
# Closes the final delegation gap in `hermes-paperclip-adapter`:
#
#   Paperclip's heartbeat service already mints a short-lived, HS256-signed
#   per-run JWT (via `createLocalAgentJwt(agentId, companyId, adapterType,
#   runId)`) and passes it to the adapter as `ctx.authToken`. The hermes
#   adapter — unlike `adapter-claude-local` — never reads that field, so
#   the token never reaches the subprocess env. Agents have no way to
#   PATCH their issue to `done`.
#
# This patch rewrites `hermes-paperclip-adapter/dist/server/execute.js` so
# that `ctx.authToken` (when provided) is exported into the subprocess env
# as `PAPERCLIP_AGENT_JWT`. The prompt template (rewritten by
# `apply-prompt-override.sh`) instructs the agent to emit exactly one
# `PATCH /api/issues/:id` call using that bearer.
#
# JWT claim shape (produced upstream by `@paperclipai/server/dist/agent-auth-jwt.js`):
#
#     { sub: agentId, company_id, adapter_type, run_id, iat, exp,
#       iss: "paperclip", aud: "paperclip-api" }      // HS256
#
# The signing secret is `PAPERCLIP_AGENT_JWT_SECRET` (falling back to
# `BETTER_AUTH_SECRET`) in the Paperclip process env. Token TTL is set via
# `PAPERCLIP_AGENT_JWT_TTL_SECONDS` (default 48h; set to 600 for 10-minute
# per-run scope per TASK.md).
#
# Idempotent — detects a sentinel comment and no-ops if already patched.
# Same safety invariants as `patch-hermes-adapter.sh`:
#   - timestamped `.orig-YYYYMMDD-HHMMSS` backup before every write
#   - exact-string match replacement; abort if anchor not found
#   - `node --check` after each write; revert on parse failure
#   - auto-discovers every bundled copy of the adapter under the npm global root
#
# Usage:
#   ./patch-hermes-adapter-jwt.sh
# Override target path (disables auto-discovery):
#   HERMES_ADAPTER_EXECUTE=/path/to/execute.js ./patch-hermes-adapter-jwt.sh

set -euo pipefail

SENTINEL_TAG="patched-by-fix-paperclip-scoped-jwt-v1"
SENTINEL="// $SENTINEL_TAG — propagates ctx.authToken to env.PAPERCLIP_AGENT_JWT"

log() { printf '[patch-hermes-adapter-jwt] %s\n' "$*" >&2; }
die() { printf '[patch-hermes-adapter-jwt] ERROR: %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null || die "python3 is required"
command -v node    >/dev/null || die "node is required"

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

[ "${#TARGETS[@]}" -gt 0 ] || die "no hermes-paperclip-adapter execute.js found; set HERMES_ADAPTER_EXECUTE"

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

# Anchor: the block that injects PAPERCLIP_RUN_ID into the subprocess env,
# immediately after buildPaperclipEnv() is spread. We append a sibling
# injection for PAPERCLIP_AGENT_JWT. The match must be exact; if it isn't,
# the adapter shape has changed and the patch aborts cleanly.
OLD = (
    "    if (ctx.runId)\n"
    "        env.PAPERCLIP_RUN_ID = ctx.runId;\n"
)
NEW = (
    "    if (ctx.runId)\n"
    "        env.PAPERCLIP_RUN_ID = ctx.runId;\n"
    "    // Propagate the per-run scoped JWT that Paperclip's heartbeat service\n"
    "    // mints (via createLocalAgentJwt in @paperclipai/server). The agent\n"
    "    // uses it to PATCH its assigned issue to status=done on completion;\n"
    "    // without this the issue is reconciled to `blocked`.\n"
    "    if (typeof ctx.authToken === \"string\" && ctx.authToken.length > 0)\n"
    "        env.PAPERCLIP_AGENT_JWT = ctx.authToken;\n"
)

if OLD not in src:
    sys.stderr.write(
        "Expected anchor not found in execute.js — adapter version may have\n"
        "changed. Patch aborted.\nExpected anchor:\n" + OLD
    )
    sys.exit(2)

if src.count(OLD) != 1:
    sys.stderr.write(
        f"Anchor appears {src.count(OLD)} times; expected exactly 1. Aborted.\n"
    )
    sys.exit(2)

target.write_text(src.replace(OLD, NEW, 1))
PY

  { printf '\n%s\n' "$SENTINEL"; } >> "$TARGET"

  node --check "$TARGET" \
    || die "node --check failed after patch ($TARGET) — restore backup: cp $backup $TARGET"

  log "patched ok: $TARGET"
  log "to revert:  cp \"$backup\" \"$TARGET\""
  patched=$((patched + 1))
done

log "summary: patched=$patched, skipped=$skipped, total=${#TARGETS[@]}"
log "sentinel: $SENTINEL_TAG"
log "NOTE: restart paperclipai so Node reloads the patched module."
log "NOTE: for the ≤10 min per-run scope TASK.md requires, set"
log "      PAPERCLIP_AGENT_JWT_TTL_SECONDS=600 in ~/.paperclip/instances/default/.env"
log "      before restart. Default upstream TTL is 48h."
