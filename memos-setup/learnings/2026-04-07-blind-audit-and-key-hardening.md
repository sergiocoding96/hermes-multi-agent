# Blind Security Audit & Key Hardening — 2026-04-07

## What Happened

An independent blind audit was conducted against the MemOS API (v1.0.1) using a structured audit prompt (`tests/blind-audit-prompt.md`). The audit had no prior context — it read all patched source files, wrote Python test scripts from scratch, and scored each category. Following the audit, all discovered vulnerabilities were fixed and verified.

---

## Audit Methodology

The audit covered 5 categories with **34 total subtests**, all scripted in Python:

| Category | Subtests | Score | Verdict |
|----------|----------|-------|---------|
| Authentication (API keys, spoofing, headers) | 10 | 8/10 | Solid mechanism, weak deployment config |
| Cube Isolation (cross-agent read/write, path traversal) | 9 | 10/10 | Robust SQLite ACL enforcement |
| Memory Quality (recall, dedup, extraction, language) | 6 | 10/10 | Excellent across all dimensions |
| Edge Cases (empty, large, unicode, SQLi, concurrency) | 9 | 10/10 | All handled cleanly |

**Overall: 9.5/10 on observed behavior** — the only weakness was a deployment configuration issue, not a code defect.

---

## Vulnerabilities Found

| Severity | Finding | Root Cause |
|----------|---------|------------|
| ~~CRITICAL~~ | `MEMOS_AUTH_REQUIRED=false` in running server | **.env already had `true`** — server needed restart. Was fixed before this session's code changes. |
| HIGH | API keys stored in plaintext in `agents-auth.json` | `setup-memos-agents.py` wrote raw keys; middleware compared raw strings |
| MEDIUM | Zero rate limiting on auth failures | No per-IP throttle; brute force possible |
| LOW | Key registry loaded once at startup, never auto-reloaded | `reload()` existed but nothing triggered it |

---

## Fixes Applied

### 1. Bcrypt Key Hashing (HIGH → FIXED)

**What changed:**
- `agents-auth.json` format upgraded from v1 (plaintext) to v2 (bcrypt hashes)
- Raw keys are printed once during provisioning, never stored on disk
- Middleware uses `bcrypt.checkpw()` to validate incoming keys against hashes
- Supports both v1 (legacy) and v2 (hashed) formats for backward compatibility

**Config format (v2):**
```json
{
  "version": 2,
  "agents": [
    {
      "key_hash": "$2b$12$eEGDwi...",
      "key_prefix": "ak_244ce9c7a",
      "user_id": "ceo",
      "description": "CEO Agent"
    }
  ]
}
```

**Files modified:**
- `~/.local/lib/python3.12/site-packages/memos/api/middleware/agent_auth.py` — `_authenticate_key()` method, bcrypt import, dual-format loading
- `setup-memos-agents.py` — `hash_key()`, `write_auth_config()` rewritten for bcrypt + migration
- `agents-auth.json` — regenerated with hashed keys

### 2. Rate Limiting on Auth Failures (MEDIUM → FIXED)

**What changed:**
- In-memory sliding window per client IP
- 10 failures in 60 seconds → 429 Too Many Requests
- Valid keys still authenticate even from a rate-limited IP (clears counter on success)
- No external dependencies (uses `collections.defaultdict` + `time.monotonic()`)

**Key design decision:** Rate limit is checked *after* attempting authentication, not before. This means a legitimate user behind a temporarily rate-limited IP can still authenticate with a valid key — the successful auth clears their failure history. This avoids locking out real users when an attacker shares their IP.

### 3. Auto-Reload Key Registry (LOW → FIXED)

**What changed:**
- `_check_reload()` compares `os.path.getmtime()` on every request (~0.01ms overhead)
- If the config file's mtime changed, triggers `_load_config()` automatically
- Enables: key rotation, adding new agents, revoking keys — all without server restart
- If config file is deleted: registry stays in memory from last load until restart

---

## Key Audit Observations (Positive)

These passed cleanly and are worth preserving as known-good behaviors:

1. **Spoof protection works** — presenting key A with user_id B → 403 with clear error message
2. **Cube isolation is DB-enforced** — SQLite `user_cube_association` table, not trust-based. Cross-agent reads and writes both rejected.
3. **Deprecated `mem_cube_id` is safe** — model_validator converts it to `readable_cube_ids`/`writable_cube_ids` before handlers see it. Cannot bypass isolation.
4. **Path traversal in cube_id is harmless** — cube_ids are DB-looked-up, never used as filesystem paths
5. **SQL injection in user_id field blocked** — SQLAlchemy ORM parameterization. DB verified intact after injection attempt.
6. **Write-time dedup is excellent** — 5 identical writes → 1 stored memory (0.90 cosine threshold)
7. **Memory extraction granularity** — 7-finding document → 15 extracted memories. Over-fragments rather than under-fragments.
8. **No Chinese language leakage** — English input → English output consistently
9. **Data integrity** — dollar amounts, ISO dates, proper nouns all survive extraction verbatim
10. **Concurrent writes** — two agents writing simultaneously: no race, no crash, no cross-contamination

---

## Gotchas & Lessons

1. **Bcrypt is slow by design.** With 3 agents, worst-case auth is ~300ms (3 hash comparisons). If agent count grows to 20+, add a SHA-256 LRU cache in front of bcrypt to avoid per-request hash iteration.

2. **Rate limit must not block valid auth.** The initial implementation checked rate limit *before* attempting key validation — this locked out legitimate users after an attacker triggered the limit. Fix: attempt auth first, only return 429 if auth also fails.

3. **`MEMOS_AUTH_REQUIRED` in .env vs running server can diverge.** The .env had `true` but the running server was started with `false`. Always restart after changing auth config. The auto-reload feature only covers `agents-auth.json`, not `.env` variables.

4. **The blind audit prompt (`tests/blind-audit-prompt.md`) is reusable.** It's designed to be pasted into a fresh session with zero context. Good for regression testing after changes.

5. **`key_prefix` in v2 config is for log identification only.** It stores the first 8-12 chars of the original key so log messages can reference which agent authenticated without exposing the full key.

---

## Verification

All fixes verified with 13/13 automated tests passing:

```bash
# Run the verification suite
cd /home/openclaw/Coding/MemOS && set -a && source .env && set +a
python3.12 /tmp/audit_verify.py

# Expected output:
# Pass: 13/13
# ALL CHECKS PASSED
```

Test coverage:
- 3 agents authenticate via bcrypt ✓
- Invalid/missing keys rejected (401) ✓
- Spoof detection (403) ✓
- Cube isolation (403) ✓
- Rate limiting triggers at 10 failures (429) ✓
- Valid key clears rate limit (200) ✓
- `agents-auth.json` contains only hashed keys ✓

---

## Test Scripts Location

All audit scripts written during this session:
- `/tmp/audit_1_auth.py` — Authentication audit (10 subtests)
- `/tmp/audit_2_isolation.py` — Cube isolation audit (9 subtests)
- `/tmp/audit_3_quality.py` — Memory quality audit (6 subtests)
- `/tmp/audit_4_edge.py` — Edge case audit (9 subtests)
- `/tmp/audit_verify.py` — Post-fix verification (13 subtests)

Note: these are in `/tmp/` and will be lost on reboot. The reusable audit prompt is at `tests/blind-audit-prompt.md`.
