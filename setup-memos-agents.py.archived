"""MemOS provisioning for Hermes Multi-Agent System.

Creates users, cubes, CEO shares, and per-agent API keys.
Safe to re-run: existing keys are preserved, new ones generated only if missing.

Usage:
    python3.12 setup-memos-agents.py

On a new machine:
    1. git clone the Hermes repo (agents-auth.json travels with it)
    2. Run this script — it reads existing keys from agents-auth.json and
       creates any missing users/cubes
    3. Set MEMOS_AGENT_AUTH_CONFIG=/path/to/agents-auth.json in MemOS .env
"""
import json
import os
import secrets
import sys

import bcrypt

# Use the installed memos package
sys.path.insert(0, "/home/openclaw/.local/lib/python3.12/site-packages")
os.chdir("/home/openclaw/Coding/MemOS")

from dotenv import load_dotenv
load_dotenv()

from memos.mem_user.user_manager import UserManager, UserRole

um = UserManager()

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
AUTH_CONFIG_PATH = os.path.join(SCRIPT_DIR, "agents-auth.json")

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
    """Load existing agents-auth.json. Returns full config dict."""
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

    Returns {user_id: raw_key} so keys can be printed once.
    Handles migration from v1 (plaintext) to v2 (hashed) format.
    """
    existing = load_existing_config()
    existing_agents = {e["user_id"]: e for e in existing.get("agents", [])}
    is_legacy = existing.get("version", 1) < 2 or any("key" in a for a in existing.get("agents", []))

    raw_keys: dict[str, str] = {}
    entries = []

    for agent in agents:
        uid = agent["user_id"]
        old_entry = existing_agents.get(uid, {})

        if is_legacy and old_entry.get("key"):
            # Migrating from plaintext: hash the existing key, preserve it for the user
            raw_key = old_entry["key"]
            key_hash = hash_key(raw_key)
            print(f"  Migrating {uid}: plaintext → bcrypt hash")
        elif old_entry.get("key_hash"):
            # Already hashed — generate a fresh key (user must have the old raw key)
            # Only regenerate if explicitly requested; otherwise keep existing hash
            raw_key = None
            key_hash = old_entry["key_hash"]
        else:
            # New agent — generate fresh key + hash
            raw_key = generate_key()
            key_hash = hash_key(raw_key)

        if raw_key:
            raw_keys[uid] = raw_key

        entries.append({
            "key_hash": key_hash,
            "key_prefix": (raw_key or "ak_????")[:12],
            "user_id": uid,
            "description": agent["description"],
        })

    config = {"version": 2, "agents": entries}
    with open(AUTH_CONFIG_PATH, "w") as f:
        json.dump(config, f, indent=2)
    print(f"  Written: {AUTH_CONFIG_PATH}")
    return raw_keys


# ── Provisioning ─────────────────────────────────────────────────────────────

print("=== Creating users ===")
for agent in AGENTS:
    try:
        uid = um.create_user(agent["user_name"], agent["role"], user_id=agent["user_id"])
        print(f"  Created: {agent['user_name']} ({agent['role'].value}) -> {uid}")
    except Exception as e:
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
    print("  To regenerate keys, delete agents-auth.json and re-run.")

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
     Keys are now bcrypt-hashed at rest. The server auto-reloads
     the config file when it changes (no restart needed for key rotation).
""")
