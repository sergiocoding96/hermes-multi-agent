# TASK: fix/delete-api — consistent delete endpoint behavior

## Goal
`DELETE /product/delete_memory` should accept the documented parameters (`mem_cube_id`, `memory_id`) and return accurate status codes.

## Context
From [blind-audit-report.md § 12 + Bug 2](https://github.com/sergiocoding96/hermes-multi-agent/blob/main/tests/blind-audit-report.md):
> Delete endpoint has confusing parameter naming. `mem_cube_id` is ignored — user must send `writable_cube_ids` instead. `memory_id` (singular) doesn't work — user must send `memory_ids` (plural array). Wrong cube returns 403 instead of 404.

This blocks clean agent behavior: skills that want to delete one memory shouldn't have to wrap it in a list and rename the cube param.

## Files
- `src/memos/api/routers/server_router.py` — the delete route
- Possibly `src/memos/api/product_models.py` — the Pydantic request model

## Acceptance
- [ ] Accept **both** `mem_cube_id` (single string) and `writable_cube_ids` (list). If both given, prefer `writable_cube_ids`. If only `mem_cube_id`, wrap into a single-element list internally.
- [ ] Accept **both** `memory_id` (single string) and `memory_ids` (list). Single coerces to list of one.
- [ ] Distinct status codes:
  - `401` — no/bad auth (unchanged)
  - `403` — auth OK but user doesn't own/share the target cube (spoof or unauthorized)
  - `404` — cube exists but memory_id doesn't
  - `400` — malformed request (neither id form given)
  - `200` — success, with a body showing `{deleted: [ids], not_found: [ids]}` for partial deletes
- [ ] Partial success: deleting 3 ids where 2 exist and 1 doesn't returns 200 with `deleted` and `not_found` split clearly (don't 404 the whole request).
- [ ] Existing callers that use `writable_cube_ids` + `memory_ids` keep working unchanged.

## Approach
Add a small normalization layer at the top of the handler:

```python
cube_ids = payload.writable_cube_ids or ([payload.mem_cube_id] if payload.mem_cube_id else [])
mem_ids = payload.memory_ids or ([payload.memory_id] if payload.memory_id else [])
if not cube_ids or not mem_ids:
    raise HTTPException(400, "require (mem_cube_id or writable_cube_ids) and (memory_id or memory_ids)")
```

Then fix status codes downstream. The 403 → 404 fix is the trickier one — distinguish "cube not shared with user" (stay 403) from "cube owned by user but memory not found" (return 404).

## Test plan (isolated)
```bash
USER=audit-delete-user
CUBE=audit-delete-cube
KEY=<key>

# 1. Write a memory, get its id:
MID=$(curl -sS -X POST http://localhost:8001/product/add \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "{\"user_id\":\"$USER\",\"writable_cube_ids\":[\"$CUBE\"],\"messages\":[{\"role\":\"user\",\"content\":\"delete me\"}],\"async_mode\":\"sync\",\"mode\":\"fast\"}" \
  | jq -r '.data[0].id')

# 2. Delete with LEGACY form (should still work):
curl -sS -X DELETE http://localhost:8001/product/delete_memory \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "{\"user_id\":\"$USER\",\"writable_cube_ids\":[\"$CUBE\"],\"memory_ids\":[\"$MID\"]}"

# 3. Delete with NEW form (singular):
# re-create a memory first, then:
curl -sS -X DELETE http://localhost:8001/product/delete_memory \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "{\"user_id\":\"$USER\",\"mem_cube_id\":\"$CUBE\",\"memory_id\":\"$MID\"}"

# 4. Delete non-existent id → expect 404:
curl -i -X DELETE http://localhost:8001/product/delete_memory \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "{\"user_id\":\"$USER\",\"mem_cube_id\":\"$CUBE\",\"memory_id\":\"nonexistent-id\"}"

# 5. Partial delete (2 real + 1 fake) → expect 200 with split result:
curl -sS -X DELETE http://localhost:8001/product/delete_memory \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "{\"user_id\":\"$USER\",\"mem_cube_id\":\"$CUBE\",\"memory_ids\":[\"$MID1\",\"$MID2\",\"fake\"]}"
```

## Out of scope
- Don't touch the admin router's delete endpoints (different contract).
- Don't add bulk-delete-all-in-cube. Scope is per-memory delete.

## Commit / PR
Branch: `fix/delete-api`
PR title suggestion: `fix(delete): accept singular+plural params and return distinct status codes`
