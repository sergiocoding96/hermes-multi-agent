# MemOS v1 Provisioning & Setup-Workflow Audit
**Marker:** V1-PROV-1777216000  
**Date:** 2026-04-26  
**Auditor:** Claude Sonnet 4.6 (blind, zero-knowledge)  
**Script under test:** `deploy/scripts/setup-memos-agents.py.archived` (identical to root-level `setup-memos-agents.py.archived`)

---

## Executive Summary

The provisioning script covers the happy path adequately — `secrets`-based key generation, bcrypt cost 12, and preserve-on-re-run semantics are all correct. However, a careless operator will hit multiple silent footguns: the generated `agents-auth.json` is world-readable by default (0664), the script is hardcoded to a single machine's filesystem paths, there is no key rotation flag, profile `.env` files are never created, and the verification output leaks all historical test users. A new operator cannot stand up a working cluster in 30 minutes using the script and its inline documentation alone — the multi-machine hardcoding alone blocks deployment on any other host.

**Overall provisioning score = MIN = 1/10**

---

## Recon Findings

### Script Inventory

Both `deploy/scripts/setup-memos-agents.py.archived` and the root-level `setup-memos-agents.py.archived` are **byte-for-byte identical** (`diff` returned 0 output). There is no non-archived current script — only `.archived` versions exist. The script is 193 lines; no `argparse`/`sys.argv` parsing at all.

### Script Structure

| Section | Lines | Notes |
|---------|-------|-------|
| Module-level `os.chdir` + `sys.path.insert` | 23–24 | Both hardcoded to `/home/openclaw/...` |
| `AGENTS` / `CUBES` / `CEO_SHARES` constants | 36–63 | Hardcoded; not configurable via args |
| `load_existing_config()` | 68–73 | Reads existing JSON or returns `{}` |
| `generate_key()` | 76–78 | `"ak_" + secrets.token_hex(16)` |
| `hash_key()` | 81–83 | `bcrypt.hashpw(... bcrypt.gensalt())` |
| `write_auth_config()` | 86–132 | Migration + preserve/generate + write |
| Provisioning body | 137–192 | Users → Cubes → CEO shares → Keys → Print |

### `UserManager` API (MemOS source)

`UserManager` at `/home/openclaw/Coding/MemOS/src/memos/mem_user/user_manager.py`:

| Method | Signature | Notes |
|--------|-----------|-------|
| `__init__` | `(db_path=None, user_id="root")` | Creates tables; calls `_init_root_user(user_id)` every init |
| `create_user` | `(user_name, role, user_id=None) → str` | Returns existing user_id if name exists (no exception) |
| `get_user` | `(user_id) → User \| None` | |
| `get_user_by_name` | `(user_name) → User \| None` | |
| `validate_user` | `(user_id) → bool` | is_active check |
| `list_users` | `() → list[User]` | All active users (no filter) |
| `create_cube` | `(cube_name, owner_id, cube_path=None, cube_id=None) → str` | Raises on duplicate cube_id |
| `get_cube` | `(cube_id) → Cube \| None` | |
| `validate_user_cube_access` | `(user_id, cube_id) → bool` | Resolves cube by id/name/owner |
| `get_user_cubes` | `(user_id) → list[Cube]` | Active cubes only |
| `add_user_to_cube` | `(user_id, cube_id) → bool` | Idempotent; returns True |
| `remove_user_from_cube` | `(user_id, cube_id) → bool` | Cannot remove owner |
| `delete_user` | `(user_id) → bool` | Soft-delete; ROOT blocked |
| `delete_cube` | `(cube_id) → bool` | Soft-delete |

**Critical `_init_root_user` behavior:** on every `UserManager()` instantiation, if users already exist, it calls `create_user(user_name="root", user_id="root", role=ROOT)`. This inserts a spurious `root` user on first real run and is a no-op thereafter, but it pollutes the verification output on every re-run.

### Idempotency Guards

- `create_user`: internally returns existing user_id without exception if name exists. **The script cannot distinguish "just created" from "already existed"** — it always prints `Created:`.
- `create_cube`: raises `IntegrityError` on duplicate `cube_id`. Caught by `except Exception` → prints `Exists:`. But the `ERROR`-level log still appears in `stderr`.
- `add_user_to_cube`: already idempotent (`if user not in cube.users`).
- `write_auth_config`: preserves existing hash if `key_hash` present. ✓

---

## Probe Matrix Results

### 1. Key-Generation Entropy + BCrypt Cost

**Entropy source:** `secrets.token_hex(16)` — 16 bytes (128 bits) from `os.urandom` internally. Strong CSPRNG.

**Key format:** `ak_` (fixed 3-char prefix) + 32 lowercase hex chars = **35 chars total**, **128 bits entropy** in the random component.

**BCrypt cost factor:** `bcrypt.gensalt()` default = **12** (confirmed: `$2b$12$...` in generated hashes). Above the minimum of 10. ✓

**Keys differ per run:** Confirmed — two independent runs produced wholly different keys (128-bit random cannot collide in practice).

**One caveat:** hex alphabet (16 chars, 4 bits/char) vs `token_urlsafe` base64 (64 chars, 6 bits/char) produces keys of lower textual complexity, but the underlying entropy is identical. Not a meaningful weakness.

**Finding:** key_prefix stored in agents-auth.json degrades to `"ak_????"` on every subsequent run (see §4 File Perms). The prefix loses its value as a key identifier after the first re-run.

**Score: 8/10** — Strong entropy, adequate bcrypt cost; key_prefix corruption is a minor annoyance.

---

### 2. Raw-Key Handling

**Where raw key appears:** `stdout` only — printed once in the `=== Generating agent API keys ===` section.

**Stored on disk:** only `key_hash` in `agents-auth.json`. Raw key is not stored. ✓

**Recovery possible from hash:** No — bcrypt is one-way. Neither hash inversion nor any support tool recovers the raw key.

**Recovery story documented:** "To regenerate keys, delete agents-auth.json and re-run." This implies re-keying all agents simultaneously — no selective recovery.

**Footgun — stdout redirect:**

```bash
python3.12 setup-memos-agents.py.archived > setup.log  # raw keys land in setup.log
```

No warning in the script about this. An operator who redirects output to capture it for logging will persist raw keys on disk at the umask-derived permission of `setup.log`.

**Score: 7/10** — Print-once semantics correct; missing stdout-redirect warning.

---

### 3. Script Idempotency

**Test performed:** ran script twice against live DB; also confirmed hardcoded AGENTS list means partial agent overlap (`--agents A B`) is impossible.

**Second-run behavior:**

| Resource | Second-run result |
|----------|------------------|
| User rows | Script prints `Created: <name>` (misleading) — `create_user` silently returns existing user; no exception, no idempotent message |
| Cube rows | `ERROR` in log: `UNIQUE constraint failed: cubes.cube_id`; script prints `Exists:` |
| CEO cube shares | `add_user_to_cube` is idempotent; prints `Shared: ... True` both runs |
| Agent keys | Existing hashes preserved ✓; no raw keys printed on second run ✓ |

**Misleading output bug:** `create_user` handles duplicates by returning the existing user_id (no exception). Since the script only catches `Exception` to print `Exists:`, it always prints `Created:` — even for pre-existing users. An operator re-running the script cannot tell whether users were created or already present.

**Noisy error logs:** cube creation produces `ERROR`-level SQLAlchemy stack traces on every re-run (UNIQUE constraint). This is expected behavior being treated as an error, creating alert fatigue.

**No `--agents` arg, no `--rotate` flag:** the AGENTS list is hardcoded. Partial provisioning (e.g. adding one agent without touching others) requires editing the script source. There is no `--rotate` flag; the admin API at `/admin/keys/rotate` must be used instead (not documented in the script's next-steps).

**key_prefix corruption:** on every re-run, existing agents get `"key_prefix": "ak_????"` overwritten in the JSON because `raw_key = None` in the `elif old_entry.get("key_hash"):` branch, and the expression `(raw_key or "ak_????")[:12]` evaluates to `"ak_????"`. The prefix that was stored correctly on initial run is permanently lost.

**Reproducer:**
```bash
python3.12 deploy/scripts/setup-memos-agents.py.archived  # first run
python3.12 deploy/scripts/setup-memos-agents.py.archived  # second run — observe misleading "Created:"
cat deploy/scripts/agents-auth.json | python3 -c "import sys,json; [print(a['key_prefix']) for a in json.load(sys.stdin)['agents']]"
# Output: ak_???? ak_???? ak_????  ← all prefixes corrupted
```

**Score: 4/10** — Key preservation is correct, but misleading output, ERROR log noise, key_prefix corruption, and no partial-update capability.

---

### 4. File Permissions Post-Run

**`agents-auth.json` permissions observed:**
```
-rw-rw-r-- 1 openclaw openclaw 723 Apr 26 15:02 deploy/scripts/agents-auth.json
```

**Mode: 0664 (world-readable via group + others read bits)**

No `os.chmod(AUTH_CONFIG_PATH, 0o600)` call exists in the script. The file is created with `open(AUTH_CONFIG_PATH, "w")` under the process umask. On most Linux systems with umask 002, this produces 0664. The bcrypt hashes within are public to any user on the machine.

While bcrypt hashes cannot be reversed quickly, exposing them on-disk grants anyone with shell access the ability to mount offline dictionary attacks at bcrypt-limited throughput. On a multi-tenant machine this is a real risk.

**Profile `.env` files:** the script does **not** create `~/.hermes/profiles/<agent>/.env` at any permissions. No `.env` files are created; the operator receives printed instructions only.

**Admin router comparison:** the admin router (`admin_router.py`) uses `open(tmp, "w") + os.replace(tmp, path)` — atomic write — but also does not set permissions. Both the script and admin router omit explicit `chmod`.

**Reproducer:**
```bash
python3.12 deploy/scripts/setup-memos-agents.py.archived
ls -la deploy/scripts/agents-auth.json
# → -rw-rw-r--   ← bcrypt hashes world-readable
```

**Remediation:** add `os.chmod(AUTH_CONFIG_PATH, 0o600)` immediately after `with open(...) as f: json.dump(...)`.

**Score: 2/10** — BCrypt hashes exposed world-readable; no profile env files created.

---

### 5. ACL Setup Correctness (Including CEO Multi-Cube)

**DB state after first run (confirmed via SQLite):**

| Check | Result |
|-------|--------|
| `users` row for `ceo` | ✓ present, `role=ROOT`, `is_active=1` |
| `users` row for `research-agent` | ✓ present, `role=USER`, `is_active=1` |
| `users` row for `email-marketing-agent` | ✓ present, `role=USER`, `is_active=1` |
| `cubes` row for `ceo-cube` (owner: ceo) | ✓ present, `is_active=1` |
| `cubes` row for `research-cube` | ✓ present, `is_active=1` |
| `cubes` row for `email-mkt-cube` | ✓ present, `is_active=1` |
| `user_cube_association` ceo→ceo-cube | ✓ |
| `user_cube_association` ceo→research-cube | ✓ (CEO share) |
| `user_cube_association` ceo→email-mkt-cube | ✓ (CEO share) |
| `user_cube_association` research-agent→research-cube | ✓ |
| `user_cube_association` email-marketing-agent→email-mkt-cube | ✓ |

**CEO multi-cube access:** `um.add_user_to_cube("ceo", cube_id)` matches the `UserManager` API signature exactly. ✓

**`remove_user_from_cube`:** confirmed in source — correctly prevents removing the cube owner (`if cube.owner_id == user_id: return False`). Revocation for non-owner works.

**Verification output noise:** `list_users()` returns ALL active users across all historical test sessions (19 users total during this run), including deactivated test users that were later soft-deleted. The verification section is unusable as a cluster-health signal.

**Spurious root user:** `UserManager()` constructor calls `_init_root_user("root")` on every instantiation; when users exist, this calls `create_user(user_name="root", user_id="root", role=ROOT)`. A `root` user appears in `list_users()` output with no cube, unrelated to the provisioned agents.

**Score: 7/10** — Core ACL structure correct; verification noise and spurious root user undermine operator confidence.

---

### 6. Key Rotation Workflow

**Script-level rotation:** none. No `--rotate` flag, no `--force-regen` option. The script's own documentation says:
> "To regenerate keys, delete agents-auth.json and re-run."

This rotates ALL agents simultaneously — no per-agent rotation.

**Admin API rotation (parallel workflow):** the server exposes `POST /admin/keys/rotate` (in `admin_router.py`). This:
- Issues a new key for a single `user_id`
- Atomically writes via `os.replace` (temp file + rename)
- Removes any legacy `"key"` plaintext field
- Records `rotated_at` timestamp
- Returns the new key once in the response

**Auto-reload:** `AgentAuthMiddleware._check_reload()` fires on every `/product/*` request, comparing `os.path.getmtime`. When the file changes, the verify-cache is flushed and the new hashes are loaded. Hard cutover — old key stops working immediately after the next request that triggers a reload.

**Migration window:** none by design. After rotation, the old key produces 401 on the next request.

**Gap:** the script does not document the admin API rotation path. An operator who cannot delete `agents-auth.json` (e.g. multi-operator environment) has no documented per-agent rotation procedure.

**Score: 6/10** — Admin API rotation is well-implemented; script lacks a rotation flag and its only documented rotation path is destructive (delete all).

---

### 7. Profile Env Construction

**Does the script write `~/.hermes/profiles/<agent>/.env`?** No. It prints:

```
Done. Next steps:
  1. Ensure MemOS .env has:
       MEMOS_AGENT_AUTH_CONFIG=<path>
       MEMOS_AUTH_REQUIRED=true
  2. In agent config (Hermes SOUL.md / Paperclip):
       Include header: Authorization: Bearer <key>
       when calling MemOS /product/add and /product/search
  3. Restart MemOS server to load the new middleware config.
```

**Problems with these instructions:**

1. Step 3 says "Restart MemOS server" but the auto-reload makes restart unnecessary — misleading for operators who did the right thing and set up the config path first.
2. The `MEMOS_AGENT_AUTH_CONFIG` path in step 1 points to `deploy/scripts/agents-auth.json` — but the **running MemOS server is configured** with `MEMOS_AGENT_AUTH_CONFIG=/home/openclaw/Coding/Hermes/agents-auth.json` (the root-level file). Two auth config paths now exist with different content. An operator following step 1 literally would set a new path and the server would never reload it.
3. Missing vars: Hermes agent profiles need more than just the Bearer header — no mention of `MEMOS_BASE_URL`, `MEMOS_USER_ID`, `MEMOS_CUBE_ID`, or cube-addressing conventions.
4. No mention of file permissions for the profile `.env` — if written manually, it may be created at 0644.

**Path divergence confirmed:**
```
Running server: MEMOS_AGENT_AUTH_CONFIG=/home/openclaw/Coding/Hermes/agents-auth.json
Script writes to:                        /home/openclaw/Coding/Hermes/deploy/scripts/agents-auth.json
```

**Score: 2/10** — No env files created; printed instructions contain incorrect path and missing variables.

---

### 8. Error Recovery (Ctrl-C, Partial State)

**No atomic transaction wrapper** exists around the sequence: create users → create cubes → CEO shares → write keys.

**Interrupt at three stages:**

| Stage | State after Ctrl-C |
|-------|-------------------|
| Before BCrypt (during cube creation) | Some users created, cubes partially created, no keys written — inconsistent |
| After users/cubes committed, before key file write | Users+cubes present in DB, no auth config file — agents unregistered |
| After key file write, during next re-run | Idempotent — re-run recovers user/cube state; keys preserved |

**File write atomicity:** `write_auth_config` uses `open(AUTH_CONFIG_PATH, "w")` directly — a mid-write Ctrl-C can produce a truncated JSON file. Compare to admin_router.py which uses `tmp + os.replace` (atomic).

**Orphan user handling:** if a prior run created a user but the script crashed before creating its cube, re-running the script will print `Exists: <user>` (correct) but will also fail on cube creation if the cube_id already exists (orphan cube from prior run). The except clause silently prints `Exists: cube` without distinguishing a true orphan from a healthy pre-existing resource.

**Reproducer for truncated JSON:**
```python
import signal, os
# Send SIGINT mid-write to produce truncated agents-auth.json
os.kill(os.getpid(), signal.SIGINT)
```

**Score: 3/10** — No atomic writes, no transactional group, silently inconsistent state on interrupt.

---

### 9. Multi-Machine Portability

**Hardcoded host-specific paths (lines 23–24):**
```python
sys.path.insert(0, "/home/openclaw/.local/lib/python3.12/site-packages")
os.chdir("/home/openclaw/Coding/MemOS")
```

**Impact:** running on any machine where `/home/openclaw/` doesn't exist raises `ModuleNotFoundError` (for `bcrypt`/`memos`) before any provisioning occurs. The script is **completely non-functional** on any other host.

**`agents-auth.json` portability:** the docstring claims:
> "On a new machine: 1. git clone the Hermes repo (agents-auth.json travels with it)"

But `agents-auth.json` is NOT in `.gitignore` — only `agents-auth.json.bak.*` is ignored. The root-level `agents-auth.json` is an untracked file, so it does not travel with `git clone`. This instruction is false.

**Git tracking risk:** if an operator runs `git add -A` (not explicitly discouraged), `agents-auth.json` would be committed — bcrypt hashes in git history. While bcrypt hashes are far slower to crack than plaintext, having them publicly available enables targeted offline attacks.

**Admin router comparison:** the admin router (`admin_router.py`) uses `os.getenv("MEMOS_AGENT_AUTH_CONFIG")` for the path — portable. The provisioning script should do the same.

**Score: 1/10** — Hardcoded paths make the script completely non-portable. The documented "multi-machine" story is incorrect.

---

### 10. OpenClaw Parity

The script makes no mention of OpenClaw's profile model. There is no separate OpenClaw provisioning script visible in the repository. The script only provisions MemOS-side (users, cubes, ACL, keys). The OpenClaw-side configuration (connecting agent profiles to the MemOS endpoint with the correct keys) is entirely undocumented.

**Missing from operator instructions:**
- How to create an OpenClaw agent profile pointing to this MemOS instance
- Which env vars the OpenClaw adapter reads for the Bearer token
- Whether OpenClaw and MemOS user_ids must match (they do — the key's user_id is asserted against the cube_id in `validate_user_cube_access`)

**Score: 3/10** — No OpenClaw parity documented; operator must discover the connection manually.

---

### 11. End-to-End Smoke Test

**MemOS server health:** `GET /health` returns `{"status": "healthy", "version": "1.0.1"}` ✓

**Auth enforcement confirmed:**
```bash
curl http://localhost:8001/product/search -X POST -H "Content-Type: application/json" \
  -d '{"query": "V1-PROV-test", "user_id": "research-agent", "cube_id": "research-cube", "top_k": 1}'
# → {"detail": "Authorization header required. Use: Authorization: Bearer <agent-key>"}
```

**MEMOS_AUTH_REQUIRED=true** is active. ✓

**Provisioned agents in DB:** `ceo`, `research-agent`, `email-marketing-agent` — all present with correct cube associations (confirmed via SQLite). ✓

**Key path mismatch blocks smoke test:** the script wrote keys to `deploy/scripts/agents-auth.json`. The running server reads from `agents-auth.json` (repo root, v1 plaintext format with a different test user). The newly provisioned v2 keys are unknown to the running server.

A full round-trip (`memos_store` → `memos_search`) with the script-generated keys cannot be completed without either:
1. Restarting the server with `MEMOS_AGENT_AUTH_CONFIG` pointing to `deploy/scripts/agents-auth.json`, or
2. Using the admin API to add the new keys to the existing auth config

Neither step is described in the script's next-steps.

**Score: 5/10** — Auth enforcement, DB state, and auto-reload all work correctly; path divergence blocks out-of-box smoke test.

---

## Summary Table

| Area | Score 1–10 | Key Findings |
|------|-----------|--------------|
| Key-generation entropy + BCrypt cost | 8 | 128-bit `secrets.token_hex`, cost=12 ✓; key_prefix corrupted on re-run |
| Raw-key handling (print-once + no recovery) | 7 | Print-once correct; no stdout-redirect warning |
| Script idempotency | 4 | Keys preserved ✓; misleading "Created:" for existing users; ERROR noise on cubes; key_prefix corruption; no `--rotate` |
| File perms post-run | 2 | agents-auth.json 0664 (world-readable); no profile .env created |
| ACL setup correctness (incl. CEO multi-cube) | 7 | All rows correct ✓; verification polluted by historical users; spurious `root` user |
| Key rotation workflow | 6 | Admin API rotation solid ✓; script has no rotation flag; delete-all-and-rerun only documented path |
| Profile env construction | 2 | No .env files created; printed instructions have wrong path; missing required vars |
| Error recovery (Ctrl-C, partial state) | 3 | No atomic file write; no transaction wrapper; truncated JSON possible |
| Multi-machine portability | 1 | Two hardcoded `/home/openclaw/` paths; script fails immediately on any other host |
| OpenClaw parity | 3 | No OpenClaw-side provisioning documented or implemented |
| End-to-end smoke test | 5 | Auth enforcement works ✓; path mismatch blocks newly-provisioned key round-trip |
| **Overall (MIN)** | **1** | |

---

## Findings Catalogue

### F-01 — Hardcoded Host Paths (Critical)
**Class:** multi-machine / portability  
**Severity:** Critical  
**Reproducer:** `python3.12 setup-memos-agents.py.archived` on any machine other than `openclaw`  
**Evidence:** Lines 23–24 of script; `ModuleNotFoundError` on any other host  
**Remediation:** Replace hardcoded paths with `VIRTUAL_ENV`, `MEMOS_SOURCE_DIR` env vars; use `subprocess` to discover MemOS install.

---

### F-02 — agents-auth.json World-Readable (Critical)
**Class:** unsafe-perms  
**Severity:** Critical  
**Reproducer:**
```bash
python3.12 deploy/scripts/setup-memos-agents.py.archived
ls -la deploy/scripts/agents-auth.json  # → 0664
```
**Evidence:** `-rw-rw-r--` observed; bcrypt hashes available to all local users  
**Remediation:** Add `os.chmod(AUTH_CONFIG_PATH, 0o600)` after the JSON write.

---

### F-03 — agents-auth.json Not .gitignored (High)
**Class:** state-leak  
**Severity:** High  
**Reproducer:** `git check-ignore -v agents-auth.json` → returns "not ignored"  
**Evidence:** `.gitignore` only excludes `agents-auth.json.bak.*`; docstring incorrectly states the file "travels with" `git clone`  
**Remediation:** Add `agents-auth.json` and `**/agents-auth.json` to `.gitignore`; update docstring.

---

### F-04 — key_prefix Corrupted on Re-Run (Medium)
**Class:** state-leak / undocumented-step  
**Severity:** Medium  
**Reproducer:**
```bash
python3.12 setup-memos-agents.py.archived  # key_prefix = "ak_ca050aef..."
python3.12 setup-memos-agents.py.archived  # key_prefix = "ak_????"  ← bug
```
**Evidence:** `agents-auth.json` after second run shows `"key_prefix": "ak_????"` for all entries  
**Root cause:** `(raw_key or "ak_????")[:12]` when `raw_key = None` (existing-hash branch)  
**Remediation:** Preserve existing `key_prefix` from `old_entry` when hash is unchanged: `"key_prefix": old_entry.get("key_prefix", "ak_????")`.

---

### F-05 — Misleading "Created:" Output for Existing Users (Medium)
**Class:** non-idempotent  
**Severity:** Medium  
**Reproducer:** Run script twice; second run prints `Created: ceo (ROOT) -> ceo` despite user existing  
**Evidence:** `create_user` returns existing user_id without exception; script only prints `Exists:` on exception  
**Remediation:** Check return value against existing users before printing "Created:" vs "Exists:".

---

### F-06 — ERROR Log Noise on Re-Run Cube Creation (Low)
**Class:** non-idempotent  
**Severity:** Low  
**Reproducer:** Run script twice; observe `ERROR user_manager.py:285 create_cube: UNIQUE constraint failed`  
**Evidence:** SQLAlchemy stack trace in stderr on every re-run  
**Remediation:** Check cube existence before calling `create_cube`, or use `INSERT OR IGNORE`.

---

### F-07 — No Atomic File Write for agents-auth.json (High)
**Class:** poor-recovery  
**Severity:** High  
**Reproducer:** Send SIGINT during the `json.dump()` call in `write_auth_config`  
**Evidence:** Script uses `open(AUTH_CONFIG_PATH, "w")` directly; compare to admin router which uses `tmp + os.replace`  
**Remediation:** Write to `AUTH_CONFIG_PATH + ".tmp"` then `os.replace` to the final path.

---

### F-08 — No Key Rotation in Script (Medium)
**Class:** no-rotation  
**Severity:** Medium  
**Reproducer:** There is no `--rotate` flag; rotation requires `rm agents-auth.json && python3.12 setup-memos-agents.py.archived`  
**Evidence:** `grep -n "rotate" setup-memos-agents.py.archived` → no output  
**Remediation:** Add `--rotate <user_id>` flag or document admin API `/admin/keys/rotate` as the rotation path.

---

### F-09 — Auth Config Path Divergence (High)
**Class:** undocumented-step  
**Severity:** High  
**Reproducer:** Run script; observe "Next steps" output with `MEMOS_AGENT_AUTH_CONFIG=deploy/scripts/agents-auth.json`; note server is configured with root-level path  
**Evidence:** MemOS `.env`: `MEMOS_AGENT_AUTH_CONFIG=/home/openclaw/Coding/Hermes/agents-auth.json`; script writes to `deploy/scripts/agents-auth.json`  
**Remediation:** Script should read `MEMOS_AGENT_AUTH_CONFIG` from environment and write there, or explicitly warn the operator about the path it is using.

---

### F-10 — No Profile .env Creation (Medium)
**Class:** undocumented-step  
**Severity:** Medium  
**Evidence:** No `~/.hermes/profiles/` writes anywhere in the script  
**Remediation:** Script should optionally write per-agent profile `.env` files with correct Bearer keys, or provide a separate script that does so.

---

### F-11 — Stdout-Redirect Leaks Raw Keys to Disk (Medium)
**Class:** state-leak  
**Severity:** Medium  
**Reproducer:** `python3.12 setup-memos-agents.py.archived > setup.log` → raw keys in `setup.log`  
**Evidence:** No warning exists in script output or docstring  
**Remediation:** Add a warning in the "Next steps" section; alternatively write keys to a separate `agents-auth.keys` file with 0600 perms.

---

### F-12 — Spurious "root" User Pollutes Verification Output (Low)
**Class:** non-idempotent  
**Severity:** Low  
**Evidence:** `list_users()` shows `root (ROOT): []` on every run from `UserManager._init_root_user`  
**Remediation:** Filter `root` user from verification output, or scope `list_users` to the provisioned AGENTS set.

---

## Overall Judgement

**Can a new operator stand up a working v1 cluster in <30 minutes using this script and visible documentation alone?**

No. The script fails immediately on any machine other than the original development host due to hardcoded paths (F-01). Even on the original host, the script creates `deploy/scripts/agents-auth.json` while the running MemOS server reads from a different path (F-09), so the provisioned keys never reach the server without manual intervention. The world-readable file permissions (F-02) mean that if an operator does complete provisioning, the bcrypt hashes are immediately exposed to all local users. Profile env files are never created (F-10), so agents cannot authenticate without additional undocumented steps. The script's "Next steps" instructions are partially incorrect (wrong path, missing vars, misleading restart note). Taken together, a new operator following this script will produce a half-provisioned system with insecure files and non-functional agent profiles — without any error message indicating that something went wrong. The admin API rotation endpoint (`/admin/keys/rotate`) is a well-implemented contrast, but it is not documented anywhere in the script.
