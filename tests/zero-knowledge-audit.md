# MemOS Zero-Knowledge Security Audit

Paste this into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

There is a memory storage API running at `http://localhost:8001`. If it's not running, start it: `cd /home/openclaw/Coding/MemOS && set -a && source .env && set +a && python3.12 -m memos.api.server_api > /tmp/memos_audit.log 2>&1 &` — wait 15 seconds.

The source code is installed at `/home/openclaw/.local/lib/python3.12/site-packages/memos/`. The config is at `/home/openclaw/Coding/MemOS/.env`. There may be additional config files elsewhere on this machine.

Your job: **Find every security vulnerability, data integrity issue, and reliability problem you can.** Score the system's production-readiness on a 1-10 scale with evidence.

Start by discovering what the API does — read the OpenAPI spec, explore the source code, find all config files. Then design and run your own adversarial test suite. Create your own test users, cubes, and data — do not reuse anything that already exists.

Do not read any files in `/tmp/`, any `CLAUDE.md` files, any plan files, or any existing test scripts. Form your own conclusions from the code and observed behavior only.

Report every finding with evidence (HTTP status codes, response bodies, code paths). End with a summary table scoring each area you tested.
