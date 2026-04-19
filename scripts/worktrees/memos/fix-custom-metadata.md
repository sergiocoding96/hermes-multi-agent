# TASK: fix/custom-metadata — preserve custom_tags and info on write

## Goal
Round-trip `custom_tags` and `info` fields sent to `POST /product/add` so they appear in stored memories and are filterable on search.

## Context
From [blind-audit-report.md § 7d + Bug 3](https://github.com/sergiocoding96/hermes-multi-agent/blob/main/tests/blind-audit-report.md):
> Adding a memory with `custom_tags: ["finance","quarterly"]` and `info: {"source_type":"web"}` — only `["mode:fast"]` appears in the stored memory. Custom tags are overwritten by the mode tag; custom info fields are filtered out to "avoid conflict with system fields".

Right now there's no way to tag Hermes research outputs with e.g. `source=firecrawl` or `topic=real-estate` for later filtering — which is a blocker for the hard autoresearch loop (H5) because quality scoring needs to segment results by source type.

## Files
- `src/memos/api/handlers/add_handler.py` — the add handler
- Possibly `src/memos/api/product_models.py` — if the model strips fields

## Acceptance
- [ ] `POST /product/add` with `custom_tags=["foo","bar"]` stores a memory whose `tags` list contains both `foo` and `bar` **plus** the existing mode tag (e.g. `mode:fast`). Preserve the mode tag — don't remove it; just merge.
- [ ] `POST /product/add` with `info={"source_type":"web","topic":"real-estate"}` stores the info alongside the system fields. Collision handling: prefix user fields with `user:` if there's a conflict, or namespace under `info.custom`. Pick one and document it in the code.
- [ ] Search results expose the preserved fields so downstream consumers can filter.
- [ ] Existing behavior preserved: memories written without `custom_tags`/`info` still work exactly as before (mode tag still present, no spurious fields).
- [ ] Both fast mode and fine mode honor the custom metadata (fine mode extracted facts should inherit `info` from the parent request).

## Approach
Trace the path from the Pydantic model → the handler → the write. The audit note says `info` is "stripped to prevent confusion with system fields" — find that strip and replace it with a merge/namespace. For tags, find where the mode tag is written and change overwrite → append.

## Test plan (isolated)
Use a dedicated cube so this doesn't pollute real data. From the worktree:

```bash
USER=audit-custom-meta-user
CUBE=audit-custom-meta-cube
KEY=<existing agent key; or provision a test one>

# Provision (one-time):
# See tests/ for examples of provisioning a test user/cube, or use the admin router.

# 1. Write with custom metadata:
curl -sS -X POST http://localhost:8001/product/add \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"user_id\": \"$USER\",
    \"writable_cube_ids\": [\"$CUBE\"],
    \"messages\": [{\"role\":\"user\",\"content\":\"Q1 revenue was up 12 percent\"}],
    \"custom_tags\": [\"finance\",\"quarterly\"],
    \"info\": {\"source_type\":\"web\",\"topic\":\"earnings\"},
    \"async_mode\": \"sync\",
    \"mode\": \"fast\"
  }" | jq

# 2. Search and inspect metadata:
curl -sS -X POST http://localhost:8001/product/search \
  -H "Authorization: Bearer $KEY" \
  -d "{\"query\":\"revenue\",\"user_id\":\"$USER\",\"top_k\":5}" | jq '.data[0] | {tags,info,metadata}'

# Expected: tags include "finance","quarterly","mode:fast"; info.source_type == "web".
```

Also run the full blind audit test § 7d after your fix — the bug should be cleared.

## Out of scope
- Don't change the search endpoint's filtering yet. First make the data round-trip; filtering is a follow-up.
- Don't break existing writes: run the existing tests in the MemOS repo (`pytest` — if they exist, otherwise manual regression).

## Commit / PR
Branch: `fix/custom-metadata`
PR title suggestion: `fix(add): preserve user-supplied custom_tags and info on write`
