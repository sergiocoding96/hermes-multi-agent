"""MemOS provisioning for Hermes Multi-Agent System.

Creates users, cubes, CEO shares, and per-agent API keys.
Safe to re-run: existing keys, prefixes, and timestamps are preserved.
Only newly-introduced agents get fresh keys generated.

Usage:
    python3.12 deploy/scripts/setup-memos-agents.py

The deployment auth-file path is read from $MEMOS_AGENT_AUTH_CONFIG. If unset,
the script falls back to <repo-root>/agents-auth.json.

agents-auth.json is gitignored. It is per-deployment state, never committed.

────────────────────────────────────────────────────────────────────────────
Schema (version 2)
────────────────────────────────────────────────────────────────────────────
Each agent record carries a `key_prefix` (first 12 chars of the raw key, e.g.
"ak_b34b75126"). The MemOS middleware (src/memos/api/middleware/agent_auth.py)
uses this prefix to bucket-lookup candidate hashes on each request, so an
incoming key BCrypt-verifies against ~1 hash instead of all N. Without a
prefix index, a single bad-key flood walks every hash and DoSes the server.

Migration: pre-schema-2 records (no `key_prefix` field) cause the middleware
to log a single startup WARN and gracefully degrade to the O(N) BCrypt loop.
Run this script to backfill prefixes (only possible for agents whose raw key
is recoverable — i.e. legacy plaintext entries or freshly generated ones).
For records that already have a hash but no prefix and no raw key, the
operator must rotate that key (delete the entry from agents-auth.json and
re-run this script, or wait for a future --rotate flag).
"""
import json
import os
import secrets
import stat
import sys

import bcrypt

# Use the installed memos package.
sys.path.insert(0, "/home/openclaw/.local/lib/python3.12/site-packages")
os.chdir("/home/openclaw/Coding/MemOS")

from dotenv import load_dotenv
load_dotenv()

from memos.mem_user.user_manager import UserManager, UserRole

um = UserManager()

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
AUTH_CONFIG_PATH = os.environ.get(
    "MEMOS_AGENT_AUTH_CONFIG",
    os.path.join(REPO_ROOT, "agents-auth.json"),
)
KEY_PREFIX_LEN = 12  # matches the prefix length already deployed in v2 records

AGENTS = [
    {
        "user_id": "ceo",
        "user_name": "ceo",
        "role": UserRole.ROOT,
        "description": "CEO Agent — Claude Opus 4.6 via Paperclip",
    },
    {
        "user_id": "research-agent",
        "user_name": "research-agent",
        "role": UserRole.USER,
        "description": "Research Agent — MiniMax M2.7",
    },
    {
        "user_id": "email-marketing-agent",
        "user_name": "email-marketing-agent",
        "role": UserRole.USER,
        "description": "Email Marketing Agent — MiniMax M2.7",
    },
]

CUBES = [
    {"cube_name": "ceo-cube",       "cube_id": "ceo-cube",       "owner_id": "ceo"},
    {"cube_name": "research-cube",  "cube_id": "research-cube",  "owner_id": "research-agent"},
    {"cube_name": "email-mkt-cube", "cube_id": "email-mkt-cube", "owner_id": "email-marketing-agent"},
]

CEO_SHARES = ["research-cube", "email-mkt-cube"]


# ── Key management ──────────────────────────────────────────────────────────

def load_existing_config() -> dict:
    """Load existing agents-auth.json. Returns full config dict or {}."""
    if not os.path.exists(AUTH_CONFIG_PATH):
        return {}
    with open(AUTH_CONFIG_PATH) as f:
        return json.load(f)


def generate_key() -> str:
    """Generate a new agent key: ak_ + 32 random hex chars."""
    return "ak_" + secrets.token_hex(16)


def hash_key(raw_key: str) -> str:
    """Hash an API key with bcrypt. Returns the hash as a string."""
    return bcrypt.hashpw(raw_key.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def write_auth_config(agents: list[dict]) -> dict[str, str]:
    """Write agents-auth.json with bcrypt-hashed keys.

    Idempotency contract:
      - Existing entries (any user_id already in file) are preserved unchanged
        unless they are in our AGENTS list AND are missing a hash.
      - Entries already present but absent from AGENTS (e.g. audit/test users)
        are passed through untouched. The script does not remove them.
      - On migration from v1 (plaintext "key"), we hash and add key_prefix.
      - On a v2 record missing key_prefix (pre-prefix-index format), we keep
        the hash but emit a WARN suggesting rotation. Middleware will degrade
        gracefully; see module docstring.

    Returns {user_id: raw_key} for any newly-minted keys so they can be printed
    once — they are never re-derivable from the file.
    """
    existing = load_existing_config()
    existing_agents = {e["user_id"]: e for e in existing.get("agents", [])}
    file_version = existing.get("version", 0)

    raw_keys: dict[str, str] = {}
    entries: list[dict] = []
    seen: set[str] = set()

    # Pass 1: process the canonical AGENTS list (may add/migrate/preserve).
    for agent in agents:
        uid = agent["user_id"]
        seen.add(uid)
        old_entry = existing_agents.get(uid, {})

        legacy_plaintext = "key" in old_entry and not old_entry.get("key_hash")

        if legacy_plaintext:
            raw_key = old_entry["key"]
            key_hash = hash_key(raw_key)
            key_prefix = raw_key[:KEY_PREFIX_LEN]
            print(f"  Migrating {uid}: plaintext → bcrypt hash + key_prefix")
        elif old_entry.get("key_hash"):
            raw_key = None
            key_hash = old_entry["key_hash"]
            key_prefix = old_entry.get("key_prefix")
            if not key_prefix:
                print(
                    f"  WARN  {uid}: hash present but no key_prefix. "
                    f"Middleware will degrade to O(N) for this record. "
                    f"Rotate the key (delete entry + re-run) to enable bucket lookup."
                )
        else:
            raw_key = generate_key()
            key_hash = hash_key(raw_key)
            key_prefix = raw_key[:KEY_PREFIX_LEN]

        if raw_key:
            raw_keys[uid] = raw_key

        entry = dict(old_entry)  # preserve created_at, rotated_at, etc.
        entry["user_id"] = uid
        entry["key_hash"] = key_hash
        if key_prefix:
            entry["key_prefix"] = key_prefix
        entry["description"] = agent["description"]
        # Strip the legacy plaintext field if present.
        entry.pop("key", None)
        entries.append(entry)

    # Pass 2: pass through any pre-existing agents not in our canonical list
    # (audit users, test fixtures, etc.). Don't touch them.
    for uid, old_entry in existing_agents.items():
        if uid in seen:
            continue
        if not old_entry.get("key_prefix") and old_entry.get("key_hash"):
            print(
                f"  WARN  {uid}: hash present but no key_prefix. "
                f"Middleware will degrade to O(N) for this record."
            )
        entries.append(old_entry)

    config = {"version": 2, "agents": entries}

    # Write atomically with restrictive perms before placing into final path.
    tmp_path = AUTH_CONFIG_PATH + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(config, f, indent=2)
    os.chmod(tmp_path, stat.S_IRUSR | stat.S_IWUSR)  # 0600
    os.replace(tmp_path, AUTH_CONFIG_PATH)
    # Re-assert perms post-replace (replace can preserve target's perms on some FS).
    os.chmod(AUTH_CONFIG_PATH, stat.S_IRUSR | stat.S_IWUSR)
    print(f"  Written: {AUTH_CONFIG_PATH} (perms 0600, schema v2)")
    if file_version and file_version < 2:
        print(f"  Upgraded schema: v{file_version} → v2")
    return raw_keys


# ── Provisioning ─────────────────────────────────────────────────────────────

print("=== Creating users ===")
for agent in AGENTS:
    try:
        uid = um.create_user(agent["user_name"], agent["role"], user_id=agent["user_id"])
        print(f"  Created: {agent['user_name']} ({agent['role'].value}) -> {uid}")
    except Exception:
        print(f"  Exists:  {agent['user_name']}")

print("\n=== Creating cubes ===")
for cube in CUBES:
    try:
        cid = um.create_cube(cube["cube_name"], cube["owner_id"], cube_id=cube["cube_id"])
        print(f"  Created: {cube['cube_name']} (owner: {cube['owner_id']}) -> {cid}")
    except Exception:
        print(f"  Exists:  {cube['cube_name']}")

print("\n=== Sharing cubes with CEO ===")
for cube_id in CEO_SHARES:
    try:
        ok = um.add_user_to_cube("ceo", cube_id)
        print(f"  Shared: {cube_id} -> CEO: {ok}")
    except Exception as e:
        print(f"  Error sharing {cube_id}: {e}")

print("\n=== Generating agent API keys (bcrypt hashed) ===")
raw_keys = write_auth_config(AGENTS)

if raw_keys:
    print("\n  ⚠  Raw keys shown below — save them now, they will NOT be stored on disk:")
    for uid, key in raw_keys.items():
        print(f"  {uid:30s}  {key}")
    print("  (keys are stored as bcrypt hashes in agents-auth.json)")
else:
    print("  All keys already hashed — no raw keys to display.")
    print("  To regenerate a key: delete that agent's entry from agents-auth.json and re-run.")

print("\n=== Verification ===")
for user in um.list_users():
    cubes = um.get_user_cubes(user.user_id)
    cube_names = [c.cube_id for c in cubes]
    print(f"  {user.user_id} ({user.role.value}): {cube_names}")

print(f"""
Done. Next steps:
  1. Ensure MemOS .env has:
       MEMOS_AGENT_AUTH_CONFIG={AUTH_CONFIG_PATH}
       MEMOS_AUTH_REQUIRED=true

  2. In agent config (Hermes SOUL.md / Paperclip):
       Include header: Authorization: Bearer <key>
       when calling MemOS /product/add and /product/search

  3. Restart MemOS server to load the new middleware config.
     Keys are bcrypt-hashed at rest. The server auto-reloads
     the config file when it changes (no restart needed for key rotation).
""")
