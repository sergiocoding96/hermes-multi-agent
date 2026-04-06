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

def load_existing_keys() -> dict[str, str]:
    """Load existing agent keys from agents-auth.json. Returns {user_id: key}."""
    if not os.path.exists(AUTH_CONFIG_PATH):
        return {}
    with open(AUTH_CONFIG_PATH) as f:
        data = json.load(f)
    return {entry["user_id"]: entry["key"] for entry in data.get("agents", [])}


def generate_key() -> str:
    """Generate a new agent key: ak_ + 32 random hex chars."""
    return "ak_" + secrets.token_hex(16)


def write_auth_config(agents: list[dict]) -> None:
    """Write agents-auth.json. Preserves key order: ceo first."""
    existing = load_existing_keys()

    entries = []
    for agent in agents:
        uid = agent["user_id"]
        # Preserve existing key; generate only if missing
        key = existing.get(uid) or generate_key()
        entries.append({
            "key": key,
            "user_id": uid,
            "description": agent["description"],
        })

    config = {"version": 1, "agents": entries}
    with open(AUTH_CONFIG_PATH, "w") as f:
        json.dump(config, f, indent=2)
    print(f"  Written: {AUTH_CONFIG_PATH}")


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

print("\n=== Generating agent API keys ===")
write_auth_config(AGENTS)

# Print keys for initial setup
with open(AUTH_CONFIG_PATH) as f:
    config = json.load(f)
for entry in config["agents"]:
    print(f"  {entry['user_id']:30s}  {entry['key']}")

print("\n=== Verification ===")
for user in um.list_users():
    cubes = um.get_user_cubes(user.user_id)
    cube_names = [c.cube_id for c in cubes]
    print(f"  {user.user_id} ({user.role.value}): {cube_names}")

print(f"""
Done. Next steps:
  1. Add to MemOS .env:
       MEMOS_AGENT_AUTH_CONFIG={AUTH_CONFIG_PATH}
       MEMOS_AUTH_REQUIRED=false   # set true to enforce auth on all requests

  2. In agent config (Hermes SOUL.md / Paperclip):
       Include header: Authorization: Bearer <key>
       when calling MemOS /product/add and /product/search

  3. Restart MemOS server to load the new middleware config.
""")
