#!/usr/bin/env bash
# apply-prompt-override.sh
#
# One-shot: apply the hermes-employee.mustache prompt template to the
# adapterConfig.promptTemplate field on every existing hermes_local
# Paperclip employee in the target company.
#
# Idempotent: fetches each agent's current adapterConfig.promptTemplate,
# compares to the on-disk template, skips if already matching.
#
# Uses PATCH /api/agents/:id with a partial adapterConfig — Paperclip's
# route handler merges {...existingAdapterConfig, ...requestedAdapterConfig}
# when replaceAdapterConfig is omitted/false. So sending just the single
# key preserves every other adapterConfig field.
#
# NOTE: TASK.md originally called for a direct Postgres UPDATE via
# `jsonb_set`. The embedded Postgres bundle that ships with paperclipai
# does not include `psql`, and the REST PATCH route does the same
# mutation through validated, authorized code paths. This script uses
# the API accordingly.
#
# Usage:
#   PAPERCLIP_BOARD_TOKEN=<token> ./apply-prompt-override.sh

set -euo pipefail

PAPERCLIP_URL="${PAPERCLIP_URL:-http://localhost:3100}"
COMPANY_ID="${COMPANY_ID:-a5e49b0d-bd58-4239-b139-435046e9ab91}"
BOARD_TOKEN="${PAPERCLIP_BOARD_TOKEN:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_TEMPLATE_FILE="${PROMPT_TEMPLATE_FILE:-$SCRIPT_DIR/prompts/hermes-employee.mustache}"

log() { printf '[apply-prompt-override] %s\n' "$*" >&2; }
die() { printf '[apply-prompt-override] ERROR: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl is required"
command -v jq   >/dev/null || die "jq is required"

[ -n "$BOARD_TOKEN" ] || die "PAPERCLIP_BOARD_TOKEN is not set."
[ -f "$PROMPT_TEMPLATE_FILE" ] || die "Prompt template not found at $PROMPT_TEMPLATE_FILE"

AUTH=(-H "Authorization: Bearer $BOARD_TOKEN")

template_content=$(cat "$PROMPT_TEMPLATE_FILE")

log "Fetching hermes_local agents in company $COMPANY_ID..."
agents_json=$(curl -sf "${AUTH[@]}" "$PAPERCLIP_URL/api/companies/$COMPANY_ID/agents" \
  || die "GET /api/companies/$COMPANY_ID/agents failed.")

mapfile -t agent_ids < <(echo "$agents_json" | jq -r '.[] | select(.adapterType == "hermes_local") | .id')

if [ "${#agent_ids[@]}" -eq 0 ]; then
  log "No hermes_local agents found in company $COMPANY_ID. Nothing to do."
  exit 0
fi

log "Found ${#agent_ids[@]} hermes_local agent(s): ${agent_ids[*]}"

updated=0
skipped=0
failed=0

for agent_id in "${agent_ids[@]}"; do
  agent_name=$(echo "$agents_json" | jq -r --arg id "$agent_id" '.[] | select(.id == $id) | .name')
  current_template=$(echo "$agents_json" | jq -r --arg id "$agent_id" \
    '.[] | select(.id == $id) | .adapterConfig.promptTemplate // ""')

  if [ "$current_template" = "$template_content" ]; then
    log "[$agent_name] already matches on-disk template — skipping."
    skipped=$((skipped + 1))
    continue
  fi

  log "[$agent_name] applying prompt template override..."
  patch_payload=$(jq -n --rawfile tpl "$PROMPT_TEMPLATE_FILE" \
    '{adapterConfig: {promptTemplate: $tpl}}')

  resp=$(curl -s -w '\n%{http_code}' \
    -X PATCH "$PAPERCLIP_URL/api/agents/$agent_id" \
    "${AUTH[@]}" \
    -H 'Content-Type: application/json' \
    -d "$patch_payload")
  body=$(printf '%s' "$resp" | head -n -1)
  code=$(printf '%s' "$resp" | tail -n 1)

  if [ "$code" != "200" ] && [ "$code" != "201" ]; then
    log "[$agent_name] FAILED (HTTP $code): $body"
    failed=$((failed + 1))
    continue
  fi

  # Verify the write
  post_template=$(echo "$body" | jq -r '.adapterConfig.promptTemplate // ""')
  if [ "$post_template" = "$template_content" ]; then
    log "[$agent_name] override applied — verified."
    updated=$((updated + 1))
  else
    log "[$agent_name] WARN: PATCH returned 200 but promptTemplate mismatch after write."
    failed=$((failed + 1))
  fi
done

log "Summary: updated=$updated, skipped=$skipped, failed=$failed"
[ "$failed" -eq 0 ] || exit 1
