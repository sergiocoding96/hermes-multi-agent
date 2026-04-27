# Hermes + MemOS — How the Two Repos Fit Together

**A team explainer**
Date: 2026-04-27
Audience: anyone working in this codebase who's confused about why fixes split between two GitHub repos

---

## The one-paragraph version

You're working with **two GitHub repositories that talk to each other.** Hermes is the application; MemOS is the memory server it calls. They live in two separate repos, two separate clones on the deployment box, and have two separate PR review streams. The names overlap so the confusion is reasonable, but the boundary is clean: **Hermes calls; MemOS responds.** Anything that says `src/memos/...` is server code and lives in the MemOS repo. Anything that says `deploy/plugins/memos-toolset/` or `deploy/scripts/setup-memos-agents.py` is the **client side** and lives in the Hermes repo. They are not the same software.

---

## The shape of it

```
  GitHub
  ┌─────────────────────────────────────┐    ┌─────────────────────────────────┐
  │ sergiocoding96/hermes-multi-agent   │    │ sergiocoding96/MemOS            │
  │ (the application)                   │    │ (your fork of the server)       │
  │                                     │    │                                 │
  │ - memos-toolset (CLIENT plugin)     │    │ - src/memos/  (SERVER code)     │
  │ - setup-memos-agents.py             │    │ - HTTP API on port 8001         │
  │ - Audit suite + reports             │    │ - Qdrant + Neo4j + SQLite       │
  │ - Plan + runbook docs               │    │                                 │
  │ - PRs #14, #15, #16                 │    │ - PRs #6, #7, #8                │
  └──────────────────┬──────────────────┘    └────────────────┬────────────────┘
                     │                                        │
                     │ git clone                              │ git clone
                     ▼                                        ▼
                            On the deployment tower
  /home/openclaw/Coding/Hermes               /home/openclaw/Coding/MemOS
                     │                                        │
                     │  HTTP request:  Authorization: Bearer <key>
                     └────────────────────────────────────────►
                                  localhost:8001/product/...
```

**Two things to internalize:**

1. The two repos are **independent.** No shared git history, no submodules, no symlinks. Each has its own `main` branch, its own PR review stream, its own version. You can't merge one into the other.

2. They communicate **at runtime, over HTTP.** Hermes makes a Bearer-authenticated call to `localhost:8001`. MemOS replies. Neither one cares about the other's source code.

---

## What's in each repo

### Hermes repo — `sergiocoding96/hermes-multi-agent`

This is your **application**. It contains everything *about* using MemOS, but never MemOS itself.

| Path | What it is |
|---|---|
| `deploy/plugins/memos-toolset/` | The **client plugin** Hermes agents use to call MemOS over HTTP. New tools, filters, auto-capture — all here. |
| `deploy/scripts/setup-memos-agents.py` | Provisioning script that **writes** `agents-auth.json` (the BCrypt-hashed credentials file MemOS reads at startup). |
| `deploy/cron/`, `deploy/systemd/` | Operator-side glue: when to restart, how to install, what cronjobs to run. |
| `tests/v1/`, `tests/v2/` | Audit prompts and reports **about** MemOS. The audits describe MemOS behaviour; the actual MemOS code isn't here. |
| `memos-setup/learnings/` | Historical project notes, retros, decision logs. |
| `scripts/worktrees/` | Sprint coordination tooling: per-bug TASK briefs, worktree setup scripts, runbooks. |
| `docs/` | Architecture docs (including this one). |

### MemOS repo — `sergiocoding96/MemOS`

This is your **fork** of the upstream MemOS server. Originally from MemTensor; you maintain a fork so you can patch independently.

| Path | What it is |
|---|---|
| `src/memos/api/` | HTTP API server. Routes, middleware, auth, rate limiting. |
| `src/memos/api/middleware/agent_auth.py` | The component that **reads** `agents-auth.json` and validates Bearer tokens. |
| `src/memos/multi_mem_cube/` | Per-agent memory isolation, write/read/delete logic. |
| `src/memos/vec_dbs/qdrant.py` | Qdrant vector store integration. |
| `src/memos/graph_dbs/neo4j*.py` | Neo4j graph store integration. |
| `src/memos/storage/`, `src/memos/mem_scheduler/` | Async write pipeline, retry queue, dead-letter handling. |
| `src/memos/templates/mem_reader_prompts.py` | LLM prompts for memory extraction. |

---

## How they talk to each other

A round-trip when an agent stores a memory:

```
1. Agent says something memorable in a chat session.
2. Hermes plugin (deploy/plugins/memos-toolset/handlers.py) calls MemOS:
     POST http://localhost:8001/product/add
     Authorization: Bearer <raw key from ~/.hermes/profiles/<agent>/.env>
     { "user_id": "...", "messages": [...], "mode": "fast" }
3. MemOS server (src/memos/api/middleware/agent_auth.py) validates the Bearer
   token by hashing it and looking up the BCrypt hash in agents-auth.json.
4. MemOS scheduler runs the extraction pipeline. Stores rows in SQLite, vectors
   in Qdrant, graph nodes in Neo4j.
5. MemOS replies HTTP 200 with the memory ID.
6. Hermes plugin returns the result to the agent.
```

**Key plumbing:**

- **`agents-auth.json`** — the credentials handshake file. Hermes-side script writes it; MemOS-side middleware reads it. It lives at `$MEMOS_AGENT_AUTH_CONFIG` on disk (outside both repos). Never commit this file with real hashes — Hermes has it in `.gitignore`.
- **`~/.hermes/profiles/<agent>/.env`** — per-agent identity (agent's Bearer token, user_id, cube_id). Hermes plugin reads it at process start. The LLM never sees the contents.

---

## Why split this way

**1. MemOS is a fork of upstream.** You want your patches independent of upstream's release schedule. Standard fork pattern: contribute to upstream when ready, run your fork in production, pull upstream improvements down on your schedule.

**2. Application vs library separation.** Hermes is *your* code. MemOS is a *dependency*. Mixing them in one repo would mean every Hermes commit drags MemOS source along; every MemOS upstream pull would conflict with Hermes work. Two repos = two independent change streams.

**3. Different review signals.** A change to "how agents authenticate" needs different reviewers than a change to "the secret-redaction module inside the MemOS server." Two repos let those reviews stay focused.

---

## What this means for daily ops

### When MemOS gets a fix

- PR opens against `sergiocoding96/MemOS`
- Reviewed and merged → `MemOS:main`
- On the tower:
  ```bash
  cd /home/openclaw/Coding/MemOS
  git checkout main && git pull
  systemctl restart memos       # or whatever the deployment uses
  ```
- The Hermes repo doesn't change. Hermes processes don't restart.

### When Hermes gets a fix

- PR opens against `sergiocoding96/hermes-multi-agent`
- Reviewed and merged → `Hermes:main`
- On the tower:
  ```bash
  cd /home/openclaw/Coding/Hermes
  git checkout main && git pull
  hermes restart                 # or your equivalent
  ```
- The MemOS repo doesn't change. MemOS server doesn't restart (unless the change affected the plugin's calls, in which case you may want to verify with a smoke test).

### When a bug spans both repos

The classic example is **authentication**: the credentials file is *written* by Hermes-side code and *read* by MemOS-side code. A schema change to that file requires a coordinated rollout — both repos must merge before the system works again.

Pattern: open both PRs together, cross-link them in the PR bodies, merge in the order that keeps the running system healthy at every step. (Usually: writer-side first, then reader-side, since the reader can be tolerant of old-format files but the writer can't write a new format the reader doesn't understand yet.)

---

## Common confusions cleared up

| If you see... | What it actually is |
|---|---|
| `feat(plugin): v1.0.3 auto-capture in memos-toolset` (Hermes) | Hermes-side **client plugin** got a new feature. Server is unaffected. |
| `fix(auth): startup gate + key-prefix BCrypt` (MemOS) | Server-side middleware got fixed. Plugin is unaffected. |
| `chore(plugins): un-archive memos-toolset` (Hermes) | The client plugin was inactive (Sprint-2 archive); now reactivated for v1. |
| `fix(storage): silent data-loss recovery` (MemOS) | Server-side fix in `src/memos/...`. Hermes still calls the server the same way. |
| `setup-memos-agents.py` | A Hermes script that writes credentials. Not the MemOS server. |
| Audit report paths like `src/memos/api/server_api.py` | Those files live in **MemOS only**. The audit document lives in Hermes. |
| `memos-toolset` directory | The plugin in Hermes. **Not** the MemOS server. |
| `~/.hermes/plugins/memos-toolset/` | Runtime location of the plugin (after install). |
| `~/.memos/data/memos.db` | Server-side SQLite. MemOS owns this. |
| `localhost:8001` | The MemOS HTTP API. |
| `localhost:6333` | Qdrant vector store, used by MemOS. |
| `localhost:7687` | Neo4j graph store, used by MemOS. |

---

## When do I touch which repo?

| Task | Repo |
|---|---|
| Add a new tool the agent can call | Hermes |
| Change how agents authenticate (credential format) | Both — writer in Hermes, reader in MemOS |
| Add a new memory type or extraction prompt | MemOS |
| Fix the server's response codes | MemOS |
| Add a new audit | Hermes (prompt) → results in Hermes (report) |
| Generate a PDF report | Hermes |
| Update the deployment runbook | Hermes |
| Patch Qdrant or Neo4j integration | MemOS |
| Change the plugin's filter rules | Hermes |
| Change the server's rate limit | MemOS |
| Change which model does extraction | MemOS (config) + possibly Hermes (orchestration prompt) |

---

## Quick reference card

**Repos:**

- Hermes (this repo): https://github.com/sergiocoding96/hermes-multi-agent
- MemOS (your fork): https://github.com/sergiocoding96/MemOS

**Tower paths:**

- Hermes clone: `/home/openclaw/Coding/Hermes`
- MemOS clone: `/home/openclaw/Coding/MemOS`
- Plugin runtime: `~/.hermes/plugins/memos-toolset/`
- MemOS data dir: `~/.memos/data/`
- MemOS log dir: `~/.memos/logs/`
- Per-agent profile envs: `~/.hermes/profiles/<agent>/.env`

**Default ports (loopback only):**

- MemOS API: `localhost:8001`
- Qdrant: `localhost:6333`
- Neo4j Bolt: `localhost:7687`

**Standard ops commands:**

```bash
# Pull MemOS updates
cd /home/openclaw/Coding/MemOS && git checkout main && git pull && systemctl restart memos

# Pull Hermes updates
cd /home/openclaw/Coding/Hermes && git checkout main && git pull && hermes restart

# Check both are healthy
curl http://localhost:8001/health
curl http://localhost:8001/health/deps    # per-dep status (Qdrant, Neo4j, LLM)

# Check what version of MemOS is running
cd /home/openclaw/Coding/MemOS && git log -1 --format="%h %s"
```

---

## When in doubt

If you're not sure which repo to touch, ask: **"is this code that runs as the MemOS server, or code that talks to it?"**

- *Runs as the server* → MemOS repo
- *Talks to it* (plugin, script, prompt, doc, audit, runbook) → Hermes repo

That heuristic resolves about 95% of cases.
