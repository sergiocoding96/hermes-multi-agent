# MemOS v1 Provisioning & Setup-Workflow Audit

Paste this as your FIRST message into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`. No other context should be present.

---

## Prompt

The v1 stack is provisioned with `deploy/scripts/setup-memos-agents.py` (or its archived variant). The script:

1. Generates raw API keys for one or more agents.
2. BCrypt-hashes them and stores hashes in `agents-auth.json` (the only on-disk auth source MemOS reads).
3. Prints raw keys ONCE — they are never recoverable from the file.
4. Optionally creates per-agent users, cubes, and ACL rows via `UserManager` (`add_user_to_cube` for CEO multi-cube reads).
5. Writes profile envs (or expects the operator to write them) at `~/.hermes/profiles/<agent>/.env` with the right perms.

**Your job: prove the workflow is safe, idempotent, and produces a working cluster — and find every place a careless operator could silently misconfigure it.** Score 1-10, MIN across sub-areas.

Use marker `V1-PROV-<unix-ts>` on every memory / cube / query you create.

### Zero-knowledge constraint

Do NOT read any of:
- `/tmp/**` beyond files you created this run
- `CLAUDE.md` at any level
- `tests/v1/reports/**`, `tests/v2/reports/**`
- `tests/blind-*`, `tests/zero-knowledge-audit.md`, `tests/security-remediation-report.md`
- `memos-setup/learnings/**`
- any `TASK.md` or plan file
- any commit message that mentions "audit", "score", "fix", or "remediation"

Inputs allowed: this prompt, the live system, the script source at `deploy/scripts/setup-memos-agents.py` and the archived sibling under `setup-memos-agents.py.archived`, the MemOS source under `/home/openclaw/Coding/MemOS/src/memos/**`, and the Hermes plugin source. Discover everything else.

### Throwaway profile (provision before any probe)

```bash
curl -s http://localhost:8001/health | jq . || (
  cd /home/openclaw/Coding/MemOS
  set -a && source .env && set +a
  python3.12 -m memos.api.server_api > /tmp/memos-v1-prov.log 2>&1 &
  sleep 5
)

# This audit deliberately uses the provisioning workflow as the system under test,
# so we drive it directly rather than via a wrapper. Provision into a temp home:
export MEMOS_HOME=/tmp/memos-v1-audit-$(uuidgen)
mkdir -p "$MEMOS_HOME/data"
```

Teardown:
```bash
rm -rf "$MEMOS_HOME"
sqlite3 ~/.memos/data/memos.db <<SQL
DELETE FROM users WHERE user_id LIKE 'audit-v1-prov%';
DELETE FROM cubes WHERE cube_id LIKE 'V1-PROV-%';
SQL
```

### Recon (first 5 minutes)

1. Read `deploy/scripts/setup-memos-agents.py` (and the `.archived` sibling — diff them; one is current). Note: arg parser, key-generation algorithm, BCrypt cost factor, output-file format, ACL operations.
2. Find the `UserManager` API in MemOS source: `grep -rn "class UserManager" src/memos`. List every method and arg.
3. Find any expected post-conditions in the README / inline comments (e.g. "you should now run X").
4. Check whether the script is idempotent — read for "if already exists" guards.
5. Note where the script reads its templates / defaults from (env, hard-coded, config file?).

### Probe matrix

**Key-generation strength.**
- What entropy source does the script use? `secrets.token_urlsafe`? `os.urandom`? Or something weaker (`random`, time-based)?
- What's the key length / charset? Document.
- Run the script twice — confirm keys differ each run.
- Inspect the BCrypt cost factor in `agents-auth.json`. Is it ≥10? Is it configurable, and what's the default?

**Raw-key handling.**
- Run the script. Where does the raw key get written / printed? stdout? A file? An env file?
- Is there a way to recover the raw key from `agents-auth.json` (hash inversion, support tool)? It should NOT be possible.
- If the operator misses the printout, what's the recovery story? Re-run the script (which key-rotates everything)?

**Idempotency.**
- Run the script twice with the same `--agents` arg. Does the second run: skip / fail-clearly / silently overwrite / duplicate?
- Run with a partial overlap (`--agents A B` then `--agents B C`). Are A's existing creds preserved? Is C added cleanly?
- Run with a malformed `--agents` arg (missing colon, empty user_id). Fails-fast or partially applies?

**File perms post-run.**
- After a successful run: `ls -la $MEMOS_HOME/agents-auth.json`. Is it `0600`? `0644`?
- Profile env files at `~/.hermes/profiles/<agent>/.env` — does the script create them? At what perms?
- The script's own log output — does it leak raw keys to disk if redirected (`> setup.log`)?

**ACL setup (cube ownership + sharing).**
- Run the script. For each agent, verify: (a) user row in SQLite, (b) cube row in SQLite, (c) `user_cube_association` row linking them, (d) cube has correct `is_active=True`.
- For the CEO: are CompositeCubeView grants set up (one row per worker cube)?
- Run `UserManager.add_user_to_cube` directly to grant the CEO access to a new worker cube. Does the script invocation match this manual call?
- Try to revoke (`UserManager.remove_user_from_cube` or equivalent). Confirm the revocation works and search results immediately reflect it.

**Key rotation workflow.**
- Run the script with the same `--agents` and an additional `--rotate` (or whatever the rotation flag is, if any). Does it issue new keys + invalidate old? Or does it silently overwrite?
- After rotation: old key returns 401? New key returns 200?
- Is there a migration window where both keys work, or hard cutover?

**Profile env construction.**
- Does the script write `~/.hermes/profiles/<agent>/.env` automatically, or print instructions for the operator?
- If automatic: are perms `0600`? Is the file syntax correct (KEY=VALUE, no shell injection in values)?
- If manual: are the printed instructions complete (every var the plugin needs)?

**Error recovery.**
- Run the script with a partially-stuck DB (e.g. orphan user row from a previous run). Does the script clean up or wedge?
- Kill the script mid-run (`Ctrl-C`) at three different stages: before BCrypt, after BCrypt but before SQLite, after SQLite. State after each? Recoverable?

**Multi-machine consideration.**
- Is `agents-auth.json` portable across machines, or is it host-pinned?
- If portable, is there any concern about checking it into git (committed BCrypt hashes)? What's the operator guidance?

**OpenClaw symmetry.**
- The OpenClaw side has its own profile model. Does the same script handle both, or is there a separate one? Document the parity.

**End-to-end smoke test.**
- After running the script: stand up a sandbox Hermes session loading the new profile. Issue `memos_store` then `memos_search`. Confirm round-trip in <10 s.
- Confirm the CEO (CompositeCubeView) can read across the agents the script provisioned for it.

### Reporting

For every finding:

- Class: weak-entropy / unsafe-perms / non-idempotent / state-leak / undocumented-step / no-rotation / poor-recovery.
- Reproducer: exact `setup-memos-agents.py` invocation.
- Evidence: file perms, DB rows before/after, script stderr, smoke-test result.
- Severity: Critical / High / Medium / Low / Info.
- One-sentence remediation.

Final summary table:

| Area | Score 1-10 | Key findings |
|------|-----------|--------------|
| Key-generation entropy + BCrypt cost | | |
| Raw-key handling (print-once + no recovery) | | |
| Script idempotency | | |
| File perms post-run | | |
| ACL setup correctness (incl. CEO multi-cube) | | |
| Key rotation workflow | | |
| Profile env construction | | |
| Error recovery (Ctrl-C, partial state) | | |
| Multi-machine portability | | |
| OpenClaw parity | | |
| End-to-end smoke test | | |

**Overall provisioning score = MIN.** Close with a one-paragraph judgement: can a new operator stand up a working v1 cluster from scratch in <30 minutes using this script + visible documentation alone, without footguns?

### Out of bounds (re-asserted)

Do NOT read `/tmp/` beyond files you created this run, `CLAUDE.md`, prior audit reports, plan files, learning docs, or any commit message that telegraphs prior findings.

### Deliver

```bash
git fetch origin tests/v1.0-audit-reports-2026-04-26
git switch tests/v1.0-audit-reports-2026-04-26
git pull --rebase origin tests/v1.0-audit-reports-2026-04-26
# write tests/v1/reports/provisioning-v1-$(date +%Y-%m-%d).md
git add tests/v1/reports/provisioning-v1-*.md
git commit -m "report(tests/v1.0): provisioning audit"
git push origin tests/v1.0-audit-reports-2026-04-26
```

Do not open a PR. Do not modify any other file. Do not push to `main` or any other branch.
