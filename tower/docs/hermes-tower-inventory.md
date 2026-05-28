# Hermes / Tower — Capability Inventory Guide

This document is the **runbook** for producing a factual inventory of Hermes skills, plugins, MCP servers, browser automation, notebook/presentation tooling, meeting-related tooling, and integrations. Run the commands on the machine where Hermes is installed (**hostname `sergio`**, environment nickname **Tower**). Paste outputs back into this repo or append sections below **Inventory results**.

**Primary operator:** Mohammed  

**Principle:** Inspect what already exists before designing meeting automation, SDR pipelines, or new agents.

---

## 1. Why this exists

Multi-agent goals include personal Discord agents per teammate, HR and sales agents, meeting automation (join → transcribe → summarize → presentations / NotebookLM-style outputs), cold outreach, Kanban orchestration, and shared memory plus delegation (Hermes, MemOS, Paperclip).  

Those designs must align with **actual** Hermes capabilities on disk and in config—not assumptions.

### 1.1 Tower architecture (start here)

**Teammate on-ramp** (stack, Discord surfaces, Hermes on `sergio`, MemOS, current vs target, quick start): **`docs/tower-architecture.md`**.

### 1.2 Agent access architecture (authoritative)

Who may use which Discord bot, CEO delegation (e.g. **Sergiusz** → HR), Mohammed → Research, MemOS alignment, **Hermes architecture (§8)**, **conversation placement** (§6.6), **Discord channel layout summary, and implementation status (done / partial / to-do):** **`docs/tower-agent-access-architecture.md`**. **Phased solidification plan** (CEO **`sergio`** live + MemOS / chat tuning; no new agents until stable): **`docs/tower-architecture-solidification-roadmap.md`**. **Discord channel setup detail (overrides, `/sethome`, threading keys, intents):** **`docs/tower-discord-channels-permissions.md`**. Quick **`MEMOS_*` / Telegram token** presence audit on **`sergio`:** run **`scripts/tower-audit-memos-telegram.sh`** (pipe into `ssh sergio bash -s` from repo root). **Conversation placement on `sergio`:** **`scripts/tower-apply-conversation-policy.sh`**. Update all when policy or layout changes.

---

## 2. Where to run vs where this file lives

| Location | Role |
|----------|------|
| **`sergio`** (`~/.hermes`, Hermes install, gateways in tmux) | Execute all discovery commands; source of truth |
| **`Hermes-Tower` repo** (this workspace) | Store this guide + pasted inventory results |

If Hermes source lives under `~/Coding` or elsewhere on `sergio`, extend `find` roots accordingly.

---

## 3. Snapshot — infrastructure (update when things change)

### 3.1 Disk / cleanup notes

- Recent cleanup: old Hermes venv removed, caches cleared; roughly **~25 GB** free (confirm with `df -h`).
- Heavy dirs often include `~/.hermes`, `~/.local`, `~/Coding`.

### 3.2 Docker services (typical roles)

Record versions with `docker ps` and image tags when documenting results.

| Container | Typical role |
|-----------|----------------|
| firecrawl-api | Crawl / extract |
| searxng | Meta-search |
| postgres | Relational data |
| rabbitmq | Messaging |
| playwright-service | Remote browser automation |
| redis | Cache / sessions |
| open-webui | Chat UI |
| neo4j | Graph store |
| qdrant | Vector store |

### 3.3 Hermes profiles (known)

Paths: `~/.hermes/profiles/`

Known profile names from ops notes include: `mohammed`, `arinze`, `krati`, `sergio`, `hr-agent`, `research-agent`, and a Discord-oriented profile label **Mohammed Discord Agent**. **Krati provision:** `scripts/tower-provision-krati-agent.sh` — **`docs/tower-krati-agent-setup.md`**.

### 3.4 Gateway / Discord ops notes

- Discord bot **Hermes-Mohamed-Agent**: setup via `hermes --profile mohammed gateway setup`; run via tmux (`hermes --profile mohammed gateway run`).
- Auth fix: use Discord **numeric user IDs**, not usernames.
- Duplicate **`gateway run`** processes can cause errors (e.g. Telegram token already in use). Check with `ps aux | grep "gateway run"` and stop stray PIDs before restart.
- Recurring warning (not fixed): auxiliary title generation **HTTP 404**.
- Persistence: **`hermes-gateway.service`** (user systemd) runs the default / Mohamed gateway on Tower; additional profiles use separate units (e.g. `hermes-gateway-arinze.service` with `--profile arinze`). tmux may still be used for ad-hoc runs.
- **Same Mohamed bot on a second Discord server:** one bot token = one gateway process. Invite the **existing** Mohamed application to the new server (OAuth2 URL Generator → scopes `bot` + needed permissions → authorize). Do **not** start a second `gateway run` for the same token. After join: set **home** for that server if Hermes prompts (`/sethome` in the target channel, or extend profile env if multi-guild home is supported). Users may need **pairing** again in the new guild (`hermes --profile mohammed pairing approve discord <code>`). Grant the bot role **channel permissions** (and **Send Messages in Threads** if you use thread replies) in the new server.

### 3.4.1 Cursor agent vs `sergio` (how automation actually works)

The AI **agent does not get a special “Remote SSH” channel** by default. It runs shell commands in **whatever environment Cursor gives that session** (often your **local** machine). Whether those commands hit **`sergio`** depends on the same things as any other SSH client: **`~/.ssh/config`**, keys, **BatchMode** (non-interactive), network, and **no** password/hardware prompts in that environment.

**Remote - SSH window:** your **own** integrated terminals there run **on the remote host** — good for **you** pasting ops commands. The **agent** in a **different** local window may still execute on **Windows** unless that chat is bound to the **remote** workspace and Cursor runs tools there (confirm with **`hostname`** in a test the agent runs).

**Reliable pattern for the agent from a local window:** configure passwordless SSH, then the agent can run one-shots such as  
`ssh -o BatchMode=yes -o ConnectTimeout=10 sergio 'systemctl --user is-active hermes-gateway-hr-agent.service'`.

**Verify (pick one):** (1) Agent-run **`hostname`** returns **`sergio`**, or (2) **`ssh -o BatchMode=yes sergio "hostname"`** returns **`sergio`** with no prompts.

**Limits:** the agent cannot use your passwords or unlock your **hardware** security key unless that session already has **ssh-agent** / keys loaded the same way your manual terminal does.

### 3.5 Meeting / browser notes from investigation

- Whisper: installed/working (CLI).
- Deepgram: API key exists (confirm env/profile wiring in inventory).
- NotebookLM: referenced as a Hermes skill area; confirm paths and triggers in skills inventory.
- **Camofox:** not available as `apt` package; Hermes-related Node usage observed around `@askjo/camofox-browser` / `camofox-browser/server.js` — document exact paths and parent process in results section.

---

## 4. Inventory commands (run on `sergio`)

### 4.1 Hermes CLI snapshot

```bash
command -v hermes && hermes --version 2>/dev/null
hermes --help 2>&1 | head -80
```

### 4.2 Skills

```bash
ls -la ~/.hermes/skills 2>/dev/null
find ~/.hermes/skills -maxdepth 4 -type f \( -name 'SKILL.md' -o -name '*.md' \) 2>/dev/null | sort
```

For each skill directory: note purpose (from `SKILL.md` first lines), dependencies, and whether it is tied to a profile or gateway.

### 4.3 Plugins / integrations directories

```bash
find ~/.hermes -maxdepth 5 -type d \( -iname '*plugin*' -o -iname '*extensions*' -o -iname '*integrations*' \) 2>/dev/null
grep -R --include='*.json' --include='*.yaml' --include='*.yml' -l 'plugin' ~/.hermes 2>/dev/null | head -200
```

If Hermes is cloned from git:

```bash
find ~/Coding ~/.local/src -maxdepth 6 -type d -iname '*hermes*' 2>/dev/null
```

### 4.4 MCP servers

Hermes or editor configs may declare MCP servers:

```bash
grep -R --include='*.json' -i 'mcp' ~/.hermes 2>/dev/null | head -120
grep -R --include='*.json' -i 'mcp' ~/.cursor ~/.config 2>/dev/null | head -120
```

For each server, record: command, args, env vars, and which profile or app consumes it.

### 4.5 Browser automation

```bash
ps aux | grep -E 'camofox|playwright|chromium|puppeteer' | grep -v grep
find ~/.hermes ~/Coding -type f \( -iname '*camofox*' -o -iname '*playwright*' \) 2>/dev/null | head -80
grep -R --include='package.json' -E 'playwright|puppeteer|camofox|browser' ~/.hermes ~/Coding 2>/dev/null | head -80
```

Relate findings to Docker **`playwright-service`** if used.

### 4.6 Notebook / presentation tooling

```bash
find ~/.hermes/skills -type f \( -iname '*notebook*' -o -iname '*slides*' -o -iname '*deck*' -o -iname '*ppt*' \) 2>/dev/null
grep -R --include='*.md' -i 'notebooklm\|slides\|presentation\|pptx\|reveal' ~/.hermes/skills 2>/dev/null | head -60
```

### 4.7 Meeting / audio / transcription

```bash
which whisper whisper.cpp 2>/dev/null
grep -R --include='*.md' --include='*.json' --include='*.yaml' --include='*.yml' \
  -i 'deepgram\|whisper\|fireflies\|fathom\|transcri\|meet\.google\|zoom\|teams' ~/.hermes 2>/dev/null | head -80
```

### 4.8 CRM / outbound / calendar strings

```bash
grep -R --include='*.md' --include='*.json' --include='*.yaml' --include='*.yml' \
  -iE 'hubspot|salesforce|apollo|clay|instantly|lemlist|linkedin|cal\.com|calendly|slack|discord|telegram' ~/.hermes 2>/dev/null | head -120
```

---

## 5. One-shot bundle (optional)

Save stdout to a file and copy into this repo:

```bash
INV="hermes-inventory-$(date +%Y%m%d).txt"
{
  echo "=== DATE ===" && date -u
  echo "=== HERMES ===" && command -v hermes && hermes --version 2>/dev/null
  echo "=== SKILLS LS ===" && ls -la ~/.hermes/skills 2>/dev/null
  echo "=== SKILL MD FILES ===" && find ~/.hermes/skills -type f -name 'SKILL.md' 2>/dev/null | sort
  echo "=== GATEWAY PROCS ===" && ps aux | grep -E 'gateway run|hermes' | grep -v grep
  echo "=== DOCKER ===" && docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null
} >> "$INV" 2>&1
echo "Wrote $INV"
```

Extend the block with any subsection from §4 you want fully automated.

---

## 6. Inventory results (paste below)

After running discovery, fill in structured rows. **Do not paste secret values**—only variable names and storage location (e.g. `.env`, OS keychain).

### 6.1 Skills

| Skill / path | Purpose | Used by (profile/gateway) | Notes |
|--------------|---------|---------------------------|--------|
| | | | |

### 6.2 Plugins / packaged integrations

| Name / path | Purpose | Config location | Notes |
|-------------|-----------|-----------------|--------|
| | | | |

### 6.3 MCP servers

| Server | Command / transport | Env / secrets (names only) | Consumer |
|--------|----------------------|----------------------------|----------|
| | | | |

### 6.4 Browser automation

| Component | Path / container | How Hermes invokes it | Notes |
|-----------|------------------|----------------------|--------|
| | | | |

### 6.5 Notebook / decks

| Tool / skill | Entrypoint | Output format | Notes |
|--------------|------------|---------------|--------|
| | | | |

### 6.6 Meeting stack

| Capability | Tool | Wired? (Y/N/partial) | Notes |
|------------|------|----------------------|--------|
| Capture | | | |
| Transcribe | | | |
| Summarize | | | |
| Artifacts | | | |

### 6.7 External integrations (declared in configs)

| System | Where referenced | Status |
|--------|------------------|--------|
| | | |

---

## 7. Priority backlog (from product notes)

**High**

- Meeting automation: join → transcribe → summarize → presentation / NotebookLM-style outputs.
- SDR agent: CRM, LinkedIn, lead gen, cold email, follow-ups, booking, reporting (15-phase pipeline alignment).

**Medium**

- Arinze Discord bot (**Hermes-Arinze-Agent**) on separate profile/bot to avoid gateway conflicts.
- HR agent Discord + CEO→HR delegation workflows.
- Cold outreach Kanban (Notion / Trello / internal).
- MemOS prospect memory.

**Low**

- Systemd units for gateways.
- Fix auxiliary title generation 404.
- Expand Tower operating manual beyond this inventory.

---

## 8. Revision history

| Date | Change |
|------|--------|
| 2026-05-10 | Initial inventory guide and Tower context |
| 2026-05-11 | Link to `tower-agent-access-architecture.md` (people ↔ agents ↔ memory) |
| 2026-05-11 | Link to `tower-architecture-solidification-roadmap.md` (phased plan, gates) |
| 2026-05-12 | §1.1: CEO **Sergiusz Profał** / **`sergio`** live wording; **`tower-discord-channels-permissions.md`** link; **`scripts/tower-audit-memos-telegram.sh`** audit pointer. |
