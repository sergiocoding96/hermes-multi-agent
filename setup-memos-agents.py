"""MemOS provisioning for Hermes Multi-Agent System.

Creates users, cubes, and CEO shares for the multi-agent architecture.
Uses UserManager directly (not deprecated MOS class).

Usage:
    python3.12 setup-memos-agents.py
"""
import sys
import os

# Use the installed memos package
sys.path.insert(0, "/home/openclaw/.local/lib/python3.12/site-packages")
os.chdir("/home/openclaw/Coding/MemOS")

from dotenv import load_dotenv
load_dotenv()

from memos.mem_user.user_manager import UserManager, UserRole

um = UserManager()

AGENTS = [
    {"user_id": "ceo", "user_name": "ceo", "role": UserRole.ROOT},
    {"user_id": "research-agent", "user_name": "research-agent", "role": UserRole.USER},
    {"user_id": "email-marketing-agent", "user_name": "email-marketing-agent", "role": UserRole.USER},
]

CUBES = [
    {"cube_name": "ceo-cube", "cube_id": "ceo-cube", "owner_id": "ceo"},
    {"cube_name": "research-cube", "cube_id": "research-cube", "owner_id": "research-agent"},
    {"cube_name": "email-mkt-cube", "cube_id": "email-mkt-cube", "owner_id": "email-marketing-agent"},
]

CEO_SHARES = ["research-cube", "email-mkt-cube"]

# Create users
print("=== Creating users ===")
for agent in AGENTS:
    try:
        uid = um.create_user(agent["user_name"], agent["role"], user_id=agent["user_id"])
        print(f"  Created: {agent['user_name']} ({agent['role'].value}) -> {uid}")
    except Exception as e:
        print(f"  Exists or error: {agent['user_name']} -> {e}")

# Create cubes
print("\n=== Creating cubes ===")
for cube in CUBES:
    try:
        cid = um.create_cube(cube["cube_name"], cube["owner_id"], cube_id=cube["cube_id"])
        print(f"  Created: {cube['cube_name']} (owner: {cube['owner_id']}) -> {cid}")
    except Exception as e:
        print(f"  Exists or error: {cube['cube_name']} -> {e}")

# Share cubes with CEO
print("\n=== Sharing cubes with CEO ===")
for cube_id in CEO_SHARES:
    try:
        ok = um.add_user_to_cube("ceo", cube_id)
        print(f"  Shared: {cube_id} -> CEO: {ok}")
    except Exception as e:
        print(f"  Error sharing {cube_id}: {e}")

# Verify
print("\n=== Verification ===")
for user in um.list_users():
    cubes = um.get_user_cubes(user.user_id)
    cube_names = [c.cube_id for c in cubes]
    print(f"  {user.user_id} ({user.role.value}): {cube_names}")

print("\nDone. MemOS is ready for multi-agent use.")
