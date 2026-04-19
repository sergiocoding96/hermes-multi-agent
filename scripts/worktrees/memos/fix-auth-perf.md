# TASK: fix/auth-perf — reduce BCrypt auth overhead

## Goal
Bring per-request auth overhead from ~1.1s down to <50ms p50 without weakening spoof protection.

## Context
From [blind-audit-report.md § 11 Bug 5](https://github.com/sergiocoding96/hermes-multi-agent/blob/main/tests/blind-audit-report.md):
> BCrypt with rounds=12 × N agents sequentially = 1.1-1.3s per request. With 6 agents, every API call burns ~1.2s before the handler runs. Incompatible with real-time use.

BCrypt rounds=12 is ~200ms per hash by design (that's the security). The fix is **caching**, not weakening the hash.

## Files
- `src/memos/api/middleware/agent_auth.py` — the middleware class

## Acceptance
- [ ] First request with a valid key: bcrypt verify runs once, result cached by key.
- [ ] Subsequent requests with the same key: **<50ms** middleware time (use `time.perf_counter()` around the auth block).
- [ ] Cache is per-key **and** per-match: `(raw_key_sha256, matched_agent_id)` → verified=True. Don't cache failed attempts (would trivialize brute force).
- [ ] Cache invalidates on `agents-auth.json` mtime change (the existing auto-reload must still work — invalidate cache when keys reload).
- [ ] Spoof check still works: if request claims `user_id=X` but cached agent is `Y`, return 403.
- [ ] Failed auth attempts still rate-limited (existing behavior).

## Approach (suggested)
Simplest correct fix: LRU cache keyed on `hashlib.sha256(raw_key).hexdigest()` → `matched_agent_id`. Bucket size 64 is plenty (we have ~6 agents).

```python
from functools import lru_cache  # or roll your own with a dict + OrderedDict for mtime invalidation
```

Store the verified `agent_id` in the cache, NOT the bcrypt hash itself. On hit: skip bcrypt, use cached agent_id, run spoof check and rate-limit as normal.

On `agents-auth.json` reload: clear the cache.

## Test plan (isolated to this worktree)
From `~/Coding/MemOS-wt/fix-auth-perf`:

```bash
# 1. Baseline BEFORE your changes (run once, then checkout your changes):
uv run python -c "
import httpx, time
url = 'http://localhost:8001/product/search'
key = '<pick an existing ak_ from agents-auth.json>'
for i in range(5):
    t=time.perf_counter()
    r = httpx.post(url, headers={'Authorization': f'Bearer {key}'},
                   json={'query':'test','user_id':'ceo','top_k':1}, timeout=10)
    print(f'req{i}: {(time.perf_counter()-t)*1000:.0f}ms status={r.status_code}')
"
# Expected before fix: all ~1100ms. Expected after fix: req0 ~1100ms, req1-4 <50ms.

# 2. Verify spoof still blocked:
curl -sS -X POST http://localhost:8001/product/search \
  -H "Authorization: Bearer <ceo-key>" \
  -d '{"query":"x","user_id":"research-agent","top_k":1}' | grep -i spoof
# Expected: 403 with spoof message.

# 3. Verify reload invalidates cache:
touch agents-auth.json   # bump mtime
# Next request should re-verify (will be ~1100ms again on the first call).
```

## Out of scope
- Don't change bcrypt rounds. That's the security contract.
- Don't touch the admin router (`admin_router.py`). This task is middleware only.

## Commit / PR
Branch: `fix/auth-perf`
PR title suggestion: `fix(auth): cache verified keys to bring p50 auth from 1.1s to <50ms`
Body: include the before/after timings from the test script.
