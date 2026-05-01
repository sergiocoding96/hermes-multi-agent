# MemOS v1 Provisioning & Setup-Workflow Audit — 2026-04-30

Marker: `V1-PROV-1777660695`

## Scope & method

System under test: `deploy/scripts/setup-memos-agents.py` (current `main` HEAD; 259 lines) — the
sole on-disk auth-provisioning entry point. Audit branch HEAD only carries the
`.archived` sibling, so the script source was read from `git show main:deploy/scripts/setup-memos-agents.py`.

Probes:

- Recon: read script + UserManager APIs (`/home/openclaw/Coding/MemOS/src/memos/mem_user/user_manager.py`).
- Generation: ran `secrets.token_hex(16)` + `bcrypt.gensalt()` directly to confirm the algorithm.
- Idempotency: ran the full provisioning logic twice in a sandbox `MEMOS_BASE_PATH`.
- Rotation: provisioned, deleted an agent entry from JSON, re-ran, diffed hashes.
- Revocation: called `UserManager.remove_user_from_cube` directly and re-checked `validate_user_cube_access`.
- Smoke: BCrypt round-trip + CEO multi-cube ACL via `UserManager`. (Live MemOS HTTP round-trip
  was attempted but **could not be sandboxed** — see F-01.)

The intended throwaway-bootstrap was `MEMOS_HOME=/tmp/memos-v1-audit-<uuid>` per the audit
prompt. **It does not work** — see F-01. All non-sandbox findings were verified by reading
state without modifying live infra.

---

## Findings

### F-01 · CRITICAL — operator-set env vars are silently overridden by `load_dotenv(override=True)` in the import chain

- **Class:** state-leak / undocumented-step
- **Reproducer:**
  ```bash
  cd /tmp/sandbox
  export MEMOS_AGENT_AUTH_CONFIG=/tmp/sandbox/agents-auth.json
  export MEMOS_BASE_PATH=/tmp/sandbox
  python3.12 -c '
  import os
  print("PRE:", os.environ["MEMOS_AGENT_AUTH_CONFIG"])
  import sys; sys.path.insert(0, "/home/openclaw/.local/lib/python3.12/site-packages")
  from memos.mem_user.user_manager import UserManager
  print("POST:", os.environ["MEMOS_AGENT_AUTH_CONFIG"])'
  ```
- **Evidence:**
  ```
  PRE: /tmp/sandbox/agents-auth.json
  POST: /tmp/memos-v1-prov-sandbox-1777660695/agents-auth.json   # from /home/openclaw/Coding/MemOS/.env
  ```
  Tracing: `setup-memos-agents.py` imports `memos.mem_user.user_manager`; that import chain hits
  `memos/api/config.py:75 load_dotenv(override=True)`. Operator-set env vars are clobbered by
  whatever the MemOS repo's `.env` declares.

  This was first observed when my sandbox provisioning run wrote to the **live** auth file
  `/home/openclaw/Coding/Hermes/agents-auth.json` despite explicit `export
  MEMOS_AGENT_AUTH_CONFIG=/tmp/...`. The script's own docstring (lines 10–13) advertises the
  env-var path as the documented override hook — it is not honored.
- **Severity:** **CRITICAL.** The script's "throwaway sandbox" guarantee is broken. An operator
  attempting an isolated dry-run will silently mutate production. This is also why the audit
  prompt's `MEMOS_HOME=/tmp/...` recipe does not isolate the run.
- **Remediation:** in `setup-memos-agents.py`, set `os.environ.setdefault(...)` for the canonical
  vars **before** the `from memos.* import …` line, and either (a) call `load_dotenv()` without
  `override=True` in `memos/api/config.py`, or (b) gate the override behind an explicit
  `MEMOS_FORCE_DOTENV=1` env var.

### F-02 · HIGH — `agents-auth.json` is NOT gitignored despite the docstring claim

- **Class:** state-leak
- **Reproducer:** `git -C /home/openclaw/Coding/Hermes check-ignore -v agents-auth.json` → empty.
  `grep agents-auth /home/openclaw/Coding/Hermes/.gitignore` → only `agents-auth.json.bak.*`.
- **Evidence:** Script docstring (`main` HEAD line 13): *"agents-auth.json is gitignored. It is
  per-deployment state, never committed."* — false. A `git add .` would commit it. This is a
  high-impact footgun because the file contains every production agent's BCrypt hash (now 26
  agents) and key prefix.
- **Severity:** HIGH.
- **Remediation:** add `agents-auth.json` (no glob) to `.gitignore`. Optionally add a pre-commit
  hook that rejects committing any file matching the `version:2 / agents:[…]` schema.

### F-03 · HIGH — `agents-auth.json.archived` is committed and world-readable on the audit branch

- **Class:** unsafe-perms
- **Reproducer:**
  ```
  ls -la /home/openclaw/Coding/Hermes/agents-auth.json.archived
  -rw-rw-r-- 1 openclaw openclaw 1113 Apr 30 18:41 .../agents-auth.json.archived
  git -C /home/openclaw/Coding/Hermes ls-files | grep agents-auth
  agents-auth.json.archived
  deploy/config/agents-auth.example.json
  ```
- **Evidence:** 4-agent v2 BCrypt hash file containing canonical names (`ceo`, `research-agent`,
  `email-marketing-agent`, plus a 4th `audit-custom-meta-user`). Perms `0664` (group + world
  read). Tracked in git on the audit-reports branch (and any branch that hasn't picked up the
  later `git rm` from `main`).

  Cost-12 BCrypt is ~240 ms per guess locally, so brute force is not trivial — but a published
  hash for a stable production user_id is still a credential exposure.
- **Severity:** HIGH.
- **Remediation:** `git rm` the `.archived` from any live branch, add it to `.gitignore`, and
  rotate every key whose hash was ever committed (see F-08).

### F-04 · HIGH — no CLI: AGENTS / CUBES / CEO_SHARES are source-level constants, no `--rotate`, no `--add`, no `--remove`

- **Class:** undocumented-step / no-rotation
- **Reproducer:** `python3.12 setup-memos-agents.py --rotate ceo` → unrecognized; the script has
  no `argparse`. `grep argparse setup-memos-agents.py` → empty.
- **Evidence:** Lines 59–86 of the main script: `AGENTS`, `CUBES`, `CEO_SHARES` are top-level
  literals. The audit prompt's `--agents A B` / `--rotate` / malformed-arg tests are vacuous —
  those flags don't exist. The actual workflow is "edit the script source, re-run".
- **Severity:** HIGH (footgun against the documented workflow).
- **Remediation:** introduce `argparse` with `--add USER:ROLE`, `--rotate USER`, `--remove USER`,
  `--list`, `--purge-not-canonical`. Or update the docstring to say the agent set is a
  source-level constant and link the line to edit.

### F-05 · HIGH — script writes ZERO profile envs; operator wiring is undocumented and inconsistent

- **Class:** undocumented-step
- **Reproducer:** Inspect the script — no code touches `~/.hermes/profiles/<agent>/.env`. Final
  output is just `print("=== Done. Next steps: …")` instructions.
- **Evidence:**
  ```
  ls -la ~/.hermes/profiles/
    drwx------  email-marketing/
    drwx------  research-agent/
    (no ceo/)
  ```
  - `email-marketing/.env` and `research-agent/.env` exist at `0600` ✓ — but they were created by
    a manual rotation commit (`2fdc4be Rotate research-agent + email-marketing-agent keys
    (captured + .envs updated)`), not by this script.
  - `ceo` profile does **not exist** under `~/.hermes/profiles/`. The CEO key is wired into
    Paperclip via a separate, undocumented path (per `CLAUDE.md`, `~/.paperclip/instances/...`).
- **Severity:** HIGH — every fresh provisioning requires a manual side-quest, and the CEO leg
  has no playbook at all.
- **Remediation:** when the script generates a key, write `~/.hermes/profiles/<agent>/.env` from
  a template at perms `0600`, including `MEMOS_API_KEY`, `MEMOS_USER_ID`, `MEMOS_CUBE_ID`,
  `MEMOS_API_URL`. Add a CEO-specific code path that writes into the Paperclip instance dir
  (or fail loudly if it can't find one).

### F-06 · MEDIUM — raw keys go to stdout only; redirecting the script leaks them to disk at default umask

- **Class:** state-leak
- **Reproducer:**
  ```bash
  python3.12 setup-memos-agents.py > /tmp/setup.log 2>&1
  cat /tmp/setup.log     # contains raw `ak_…` keys
  stat -c %a /tmp/setup.log    # 644
  ```
- **Evidence:** Confirmed by reading the script (lines 232–235): unconditional
  `print(f"  {uid:30s}  {key}")`. No `os.isatty(1)` check. Operators who tee output to a logfile
  (a normal habit when running provisioning) get plaintext keys at default umask.
- **Severity:** MEDIUM.
- **Remediation:** detect `not os.isatty(1)` and either (a) refuse to print raw keys without
  `--print-keys-non-tty`, or (b) write keys to a per-agent `.env` at `0600` (see F-05) and
  print only the prefixes.

### F-07 · MEDIUM — script chdir's to a hardcoded absolute path and inserts a hardcoded `site-packages` path

- **Class:** undocumented-step / non-portable
- **Reproducer:**
  ```
  $ grep -n "chdir\|sys.path.insert" deploy/scripts/setup-memos-agents.py
    41: sys.path.insert(0, "/home/openclaw/.local/lib/python3.12/site-packages")
    42: os.chdir("/home/openclaw/Coding/MemOS")
  ```
- **Evidence:** Both paths assume the openclaw user on this exact machine. On any other host
  (the explicit goal of the script — "On a new machine") the script ImportErrors or chdir-fails.
  No `MEMOS_REPO_PATH` env var, no fallback search.
- **Severity:** MEDIUM — bring-up on a fresh host requires editing the script before first run.
- **Remediation:** read `MEMOS_REPO_PATH` (default-discover via `importlib.util.find_spec("memos")`).
  Drop the `sys.path.insert`; rely on the standard import system + a virtualenv.

### F-08 · MEDIUM — rotation is hard cutover; no migration window; only documented in the
docstring

- **Class:** no-rotation
- **Reproducer:** Edit `agents-auth.json` to remove an agent's entry, re-run script. New `key_hash`
  written, old hash gone. Old raw key returns `bcrypt.checkpw(...)==False` against the new hash.
- **Evidence:** Probe `/tmp/probe-rotation.py` confirmed: rotated `ceo`, old key fails to verify
  against new hash. There is no `previous_key_hash` field, no time-bounded grace window, and the
  rotation procedure ("delete entry from agents-auth.json and re-run") only appears in the
  module docstring (lines 28–30) — not in any operator-facing README.
- **Severity:** MEDIUM — operators cannot rotate without simultaneously updating every
  consumer's `~/.hermes/profiles/<agent>/.env` (which the script doesn't write — see F-05),
  causing an outage window during the rotation.
- **Remediation:** support `previous_key_hash` with a TTL; emit a `rotated_at` timestamp; ship
  a `--rotate <user>` flag; document in `deploy/README.md`.

### F-09 · MEDIUM — re-runs print "Created" for users that already existed, and stdout is polluted with SQLAlchemy ERRORs for cubes

- **Class:** poor-recovery (cosmetic, but masks real errors)
- **Reproducer:** Run script twice in a clean sandbox.
- **Evidence (run 2):**
  ```
  === Creating users ===
    Created: ceo (ROOT) -> ceo                    # WRONG — already existed
    Created: research-agent (USER) -> research-agent
  === Creating cubes ===
  trace-id ... user_manager - ERROR - user_manager.py:285 - create_cube - Error creating cube:
    (sqlite3.IntegrityError) UNIQUE constraint failed: cubes.cube_id
  [SQL: INSERT INTO cubes ...]
    Exists:  ceo-cube
  ```
  - `UserManager.create_user` returns the existing user_id silently (no exception). The
    script's `except: print("Exists")` branch never fires for users — it always prints
    "Created" even when a user already existed.
  - `UserManager.create_cube` raises `IntegrityError`, which `user_manager.py:285` logs at
    `ERROR` level *before* re-raising. The script's `except: print("Exists:")` swallows the
    raise but cannot suppress the ERROR log.
- **Severity:** MEDIUM — operator cannot tell which agents/cubes are new vs. existing; real
  errors will hide in the noise.
- **Remediation:** call `um.get_user_by_name(...)` / `um.get_cube(...)` first, branch on
  presence, never log SQL stack traces in the create path.

### F-10 · MEDIUM — `agents-auth.json` accumulates 23 stale audit/test entries that the script
never removes

- **Class:** state-leak
- **Reproducer:**
  ```
  python3 -c "import json; d=json.load(open('agents-auth.json')); \
    print(len(d['agents']), 'agents,', \
          len([a for a in d['agents'] if a['user_id'].startswith('audit') or 'perf-xc' in a['user_id'] or 'v1obs' in a['user_id']]), 'are test fixtures')"
  → 26 agents, 23 are test fixtures
  ```
- **Evidence:** Pass-through logic at lines 174–184 keeps any pre-existing agent that is *not*
  in the canonical `AGENTS` list. There is no purge flag. Over multiple audit runs the file
  grew from 4 → 26 entries.
- **Severity:** MEDIUM — slow drift; auth-file bloat; operator can't tell at a glance which
  hashes are live vs. abandoned.
- **Remediation:** `--purge-not-canonical` flag; or warn at the end of every run if `len(non
  canonical) > N`.

### F-11 · LOW — BCrypt cost (12) is hardcoded

- **Class:** weak-entropy (mitigated)
- **Evidence:** `bcrypt.gensalt()` default = 12 (verified against current hashes:
  `$2b$12$...`). 12 is ≥10 and acceptable today, but no env/flag to bump it as hardware speeds
  up.
- **Severity:** LOW.
- **Remediation:** read `MEMOS_BCRYPT_COST` (default 12).

### F-12 · LOW — `agents-auth.example.json` says "First 10 chars" but `KEY_PREFIX_LEN = 12`

- **Class:** undocumented-step (doc / code mismatch)
- **Evidence:** `deploy/config/agents-auth.example.json:6` — `"key_prefix": "First 10 chars of
  the raw key, for log identification only"`. Code: `KEY_PREFIX_LEN = 12` (line 57). Live file
  values match the code (12 chars).
- **Severity:** LOW.
- **Remediation:** fix the doc string.

### F-13 · LOW — old `agents-auth.json.bak.*` files are kept indefinitely at `0600`

- **Class:** state-leak (mitigated)
- **Evidence:** `agents-auth.json.bak.1776639752` from Apr 19 still on disk. Perms `0600` so
  not externally exposed, but stale hashes accumulate forever.
- **Severity:** INFO/LOW.
- **Remediation:** clean up `.bak.*` older than 30 days, or stop creating them (atomic
  `os.replace` already gives us safe writes).

### F-14 · INFO — OpenClaw / Paperclip CEO wiring is entirely out of scope of this script

- **Class:** undocumented-step
- **Evidence:** No `setup-openclaw*` or `setup-paperclip*` script under `/home/openclaw/Coding/
  Hermes`. CEO profile dir under `~/.hermes/profiles/` is missing. Per `CLAUDE.md` the CEO key
  must be put into Paperclip's SOUL.md at
  `~/.paperclip/instances/default/companies/.../agents/...`. The provisioning script has no
  hook for that step.
- **Severity:** INFO — but a fresh-machine bring-up cannot succeed end-to-end using this script
  alone. Parity gap with the worker-agent path.
- **Remediation:** add an `--openclaw-instance <path>` flag that writes the CEO key into the
  appropriate Paperclip env, or document the manual steps in `deploy/README.md`.

---

## Summary table

| Area                                                   | Score 1-10 | Key findings   |
|--------------------------------------------------------|-----------:|----------------|
| Key-generation entropy + BCrypt cost                   | 8          | F-11           |
| Raw-key handling (print-once + no recovery)            | 5          | F-06           |
| Script idempotency                                     | 5          | F-09, F-10     |
| File perms post-run                                    | 3          | F-02, F-03, F-13 |
| ACL setup correctness (incl. CEO multi-cube)           | 8          | (none — works) |
| Key rotation workflow                                  | 4          | F-04, F-08     |
| Profile env construction                               | 2          | F-05           |
| Error recovery (Ctrl-C, partial state)                 | 7          | (atomic writes ✓) |
| Multi-machine portability                              | 2          | F-02, F-07     |
| OpenClaw / Paperclip parity                            | 1          | F-14           |
| End-to-end smoke test                                  | 4          | F-01 (sandbox is silently broken) |

**Overall provisioning score (MIN) = 1/10.**

If we set OpenClaw parity aside as out-of-scope for a *MemOS* provisioning audit, MIN = 2/10
(profile env + multi-machine portability).

---

## Operator-readiness verdict

**A new operator cannot stand up a working v1 cluster from scratch in <30 minutes using this
script + visible documentation alone, without footguns.** Specifically:

1. The script chdir's to `/home/openclaw/Coding/MemOS` (F-07) — it ImportErrors on any other
   path or user.
2. Operator-set `MEMOS_AGENT_AUTH_CONFIG` is silently overridden by `load_dotenv(override=True)`
   in MemOS's import chain (F-01). The "throwaway sandbox" pattern documented in the audit
   prompt — and presumably also expected by careful operators — does not work.
3. The docstring claims `agents-auth.json` is gitignored; it is not (F-02). A first-time
   operator following best-practice "git add ." will commit BCrypt hashes for every agent.
4. The script writes no profile env files (F-05); the worker `.env`s and the entire CEO/Paperclip
   wiring are manual, undocumented steps.
5. Rotation has no flag, no documented playbook, and no migration window (F-04, F-08).

The cryptographic primitives (`secrets.token_hex(16)` + BCrypt cost-12) and the SQLite ACL
plumbing (`UserManager.create_user/cube/add_user_to_cube/remove_user_from_cube`) are correct
and safe; the failure mode here is **operator-experience and supply-chain hygiene around those
primitives**, not the primitives themselves.

---

## Recommended fix order

1. **F-01** — stop the silent env override (or at minimum, set the env vars in the script
   before importing memos). Without this fix, every other test-vs-prod isolation guarantee is
   theatre.
2. **F-02 + F-03** — gitignore `agents-auth.json`, `git rm` the `.archived`, rotate any keys
   whose hashes were ever committed. (Highest real-world risk.)
3. **F-05** — write per-agent `.env` files at `0600`, including the CEO/Paperclip leg.
4. **F-04 + F-08** — proper CLI with `--add / --rotate / --remove`, plus a documented rotation
   playbook with optional grace window.
5. **F-07** — drop the hardcoded paths so the script runs on a fresh host.

The remaining findings (F-06, F-09, F-10, F-11, F-12, F-13, F-14) are quality-of-life and
hardening; address after the top five.
