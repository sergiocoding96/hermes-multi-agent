# Tower — Discord channels & permissions (Hermes multi-bot)

Use this on your **Tower agent server** so **`#hr`** and **`#research`** are **clean rooms**: only **you and people you choose**, and **only that channel’s bot** can act there (no Mohamed / Arinze / wrong specialist hijacking replies).

**Current Tower choice (your call):** keep a **`#general`** (or main) channel where **all agents** are present and Hermes **replies in threads**. **Do not change that for now.** This doc focuses on adding and locking down **`#hr`** and **`#research`**.

---

## 1. Channel layout

| Channel | Purpose | Bots (among Hermes agents) | Humans |
|---------|---------|----------------------------|--------|
| **`#general`** (or your main channel) | Everyone + all agents; **thread-style replies** | **All** bots you invited | You + whoever should use the “main” room |
| **`#hr`** | HR-only work | **hr-agent-hermes** only | You + whoever you add (e.g. CEO, ops) |
| **`#research`** | Research-only work | **research-agent-hermes** only | You + whoever you add |

**Principle for `#hr` / `#research`:** use **View Channel → Deny** for every **other** agent bot role so only the right bot **sees** the room.

---

## 2. Roles (optional but helps)

You can use **Discord roles** for humans (e.g. `Tower-HR`, `Tower-Research`, `Tower-Ops`) and assign people. Bot roles are usually the **default role** each bot gets when invited.

---

## 3. Step-by-step — create `#hr` and `#research`

Do this **after** all bots are already in the server.

### 3.1 Create the two channels

1. Server → **Channels** → add a category if you want (e.g. **Specialists**).
2. Create **`#hr`** and **`#research`** (names can vary; adjust below).

### 3.2 `#hr` — **only HR bot** (among agents)

1. Right‑click **`#hr`** → **Edit Channel** → **Permissions**.
2. **@everyone** (or your base member role): set **View Channel** how you want (often **Deny** for @everyone, then **Allow** only for chosen roles—see §3.4).
3. Add **overrides** for **each bot role that is *not* HR**:
   - **Hermes-Mohamed-Agent** (Mohamed) → **View Channel** → **Deny**
   - **Hermes-Arinze** → **View Channel** → **Deny**
   - **Hermes-Krati-Agent** (or Krati bot role) → **View Channel** → **Deny**
   - **research-agent-hermes** → **View Channel** → **Deny**
4. **HR bot** (`hr-agent-hermes`):
   - **View Channel** → **Allow**
   - **Send Messages** → **Allow**
   - **Read Message History** → **Allow**
   - For Hermes **auto-thread** (and to avoid **50001 Missing Access**): **Create Public Threads**, **Create Private Threads** (Hermes may try a fallback path), **Send Messages in Threads** → **Allow**.
   - If **`#hr`** sits under a **category**: open the **category** → **Permissions** → add the same **HR** override there (or ensure the category does **not** **Deny** thread-related actions for the bot). **Category Deny** can block the channel even when the channel list looks correct.
   - In **`#hr`** overrides, scroll the HR row and confirm nothing is **red / Deny** for thread actions (only **grey / neutral** or **green / Allow**).

**Result:** Mohamed, Arinze, and Research **cannot read** `#hr`, so they **cannot** reply there.

### 3.3 `#research` — **only Research bot** (among agents)

1. Same pattern on **`#research`**.
2. **Deny View** for: **Mohamed**, **Arinze**, **Krati**, **HR** bot roles.
3. **Allow** View + Send + Read history (+ thread perms if needed) for **research-agent-hermes** only.

### 3.4 Humans: you + people you want

1. On **`#hr`**: add **Allow** → **View Channel** + **Send Messages** + **Read Message History** for:
   - your role, and  
   - a role you assign to **Sergiusz (CEO)**, **Arinze**, etc., **only if** they should use HR in this room.
2. On **`#research`**: same for whoever should use Research.

**Private-by-default pattern:** set **@everyone** → **View Channel** **Deny**, then **Allow** for `Tower-Ops` / `Tower-HR` / named roles so random server members cannot see `#hr` or `#research`.

### 3.5 `#hr` — HR is the **home** bot: reply **without** needing `@mention`

**Tower intent:** **`#hr`** is the HR bot’s **home** channel (`/sethome` or `DISCORD_HOME_CHANNEL` here). You and allowed people should **chat normally**—**no need to @ the HR bot** every time. HR is the **only agent that can see `#hr`**, so it behaves like the **manager** of agent traffic in that room.

**How it fits together**

1. **Discord:** Only **HR** has **View** on **`#hr`**; other bots **Deny** (§3.2) so nobody else steals replies.
2. **Hermes:** **Home** tells Hermes this channel is HR’s primary place for conversation and cron-style delivery.
3. **`config.yaml` → `discord:` → `require_mention` + `free_response_channels` (Hermes):** With **`require_mention: true`** (default-style), the bot answers in server channels **when @mentioned**. **`free_response_channels`** is a comma-separated list of channel IDs where the bot **also** answers **without** an @ (see Hermes user guide — *Discord*). Tower uses **`require_mention: true`** on **`hr-agent` / `research-agent` / `sergio`** so **`#general`** is **mention-only**, while listing **only** each bot’s **home** channel id in **`free_response_channels`** so **`#hr` / `#research` / CEO home** stay **ambient** (no `@`). Restart the matching **`hermes-gateway-*.service`** after edits.
4. **If HR still ignores plain messages:** check **`DISCORD_ALLOWED_USERS`** (or pairing), **Message Content Intent** on the HR app, and any other Hermes flags—those should align with home-channel chat:

```bash
grep -Rni 'mention\|require\|trigger\|respond\|reply\|prefix\|discord' ~/.hermes/profiles/hr-agent/ 2>/dev/null | head -80
```

Then `systemctl --user restart hermes-gateway-hr-agent.service`.

**Research (optional):** If **`#research`** is Research’s **home** and only Research sees that channel, you can use the same “talk without @” expectation.

**Test:** In **`#hr`**, send **`hello`** **without** `@` → HR **should** reply for an allowlisted user.

**Threads vs parent channel:** On Tower, **`hr-agent`** `config.yaml` has included **`auto_thread: true`** and **`free_response_channels: ''`**. With **`auto_thread` on** and **no free-response channels**, Hermes tends to **open a thread** (especially after an `@`) and keep the session **there**, so **`hi`** in the **parent `#hr`** can look ignored.

**What to change (pick one policy):**

1. **Replies stay in `#hr` (no auto-thread there):** set **`free_response_channels`** to the **numeric Discord ID** of **`#hr`** (and **`#research`** on the research profile if you want the same). Use the same **string format** as your other profiles (compare `grep -n free_response ~/.hermes/profiles/mohammed/config.yaml` on `sergio` if unsure).  
2. **No auto-threads for this bot anywhere:** set **`auto_thread: false`** in **`hr-agent`** `config.yaml` (fine if this profile only uses channels where inline chat is OK).

After editing: `systemctl --user restart hermes-gateway-hr-agent.service`.

**Journal:** `[Discord] Auto-thread creation failed … 403 … 50001 Missing Access` means Discord **denied thread creation** for the HR bot in that channel (role missing **Create Public Threads** / **Send Messages in Threads**, or the channel type forbids threads). Fix **overrides** for **`hr-agent-hermes`** on **`#hr`** (§3.2), **or** set **`auto_thread: false`** so Hermes stops calling that API.

**Other log noise:** `Telegram bot token already in use` on **`hr-agent`** means that profile’s Telegram token is still held by another gateway (often **`mohammed`**); disable Telegram on the HR profile or use a dedicated token if HR needs Telegram. **`Main process exited, status=1`** right after the startup banner needs a wider `journalctl` window around the restart to capture the first Python error after the banner.

---

## 4. `#general` — mention-only replies (Tower)

- All bots may stay **in** **`#general`** for visibility and @mentions.
- **Hermes:** **`require_mention: true`** on specialist and CEO profiles, with **`free_response_channels`** set **only** to each profile’s **home** channel id (`#hr`, `#research`, CEO home), so a bare **`hi`** in **`#general`** does **not** wake HR / Research / CEO — only an **@** to that bot does (same idea as **`mohammed`**). **`#hr` / `#research` / CEO home** keep **plain** chat without `@` because those channel ids are in **`free_response_channels`**.
- **Mohamed** already uses **`require_mention: true`** with **`auto_thread: true`** in **`#general`** (thread on @) unless you change that profile.

---

## 5. Bot intents (Developer Portal)

For **HR** and **Research** applications, ensure **Message Content Intent** (and any other intents you already use on working bots) is enabled. Restart gateways on `sergio` after changes:

```bash
systemctl --user restart hermes-gateway-hr-agent.service
systemctl --user restart hermes-gateway-research-agent.service
```

---

## 6. Hermes — `/sethome` for HR and Research

1. Open **`#hr`** → run **`/sethome`** in that channel for the **HR** bot (so cron / cross-platform delivery for HR uses this room).
2. Open **`#research`** → **`/sethome`** for **Research**.

If you prefer file-based config, set **`DISCORD_HOME_CHANNEL=<numeric channel id>`** in:

- `~/.hermes/profiles/hr-agent/.env`
- `~/.hermes/profiles/research-agent/.env`

…then restart those two units. **Mohamed / Arinze** can keep **home** on **`#general`** until you decide otherwise.

**Consistency check:** **`DISCORD_HOME_CHANNEL`** for **`hr-agent`** must be the **same numeric id** as **`#hr`** (and must match **`discord.free_response_channels`** for that profile when you use mention-in-`#general` + ambient-in-home). If HR’s **`.env`** home id accidentally points at **`#research`** (or any other channel), plain messages in **`#hr`** can look “dead” while **`#research`** still behaves normally.

**Wrong id symptom:** Hermes logs **`404 … 10003 Unknown Channel`** on startup or send — the id is not a real channel the HR bot can see (deleted channel, typo, or **stale id**). On `sergio`, compare **`~/.hermes/profiles/hr-agent/channel_directory.json`** (Discord entries, **`name`: `hr`**) to **`DISCORD_HOME_CHANNEL`** and **`free_response_channels`**; fix both to the **same** `#hr` id, then **`systemctl --user restart hermes-gateway-hr-agent.service`**.

---

## 7. Hermes — allowlists (`sergio`)

Who may **talk** to HR / Research on Discord must match **`DISCORD_ALLOWED_USERS`** (or pairing) on **`hr-agent`** and **`research-agent`** profiles—add every human who should use **`#hr`** or **`#research`**.

```bash
systemctl --user restart hermes-gateway-hr-agent.service
systemctl --user restart hermes-gateway-research-agent.service
```

---

## 8. Verification

| # | Check |
|---|--------|
| 1 | In **`#hr`**, only **HR** bot answers; other agent bots have **no View** on `#hr`. |
| 1b | **`#hr`:** allowlisted users can message **without** `@hr…` and HR replies — Tower config uses **`require_mention: true`** + **`free_response_channels`** = **`#hr`** id + **`DISCORD_HOME_CHANNEL`** = same **`#hr`** id (see §6 consistency). |
| 2 | **`#research`** (`1503722569277374534`): only **Research** bot among agents + humans; **Deny View** for other bots (**same pattern as `#hr`**). Hermes **`research-agent`** tuned on `sergio`. Optional: plain **`hello`** without `@` to double-check. |
| 3 | In **`#general`**, bare **`hi`** should **not** wake HR / Research / CEO; use **`@`** to the bot you want (see §4). |
| 4 | Invited humans can open **`#hr` / `#research`**; others cannot (if you used private-by-default). |
| 5 | `systemctl --user is-active hermes-gateway-hr-agent.service hermes-gateway-research-agent.service` → **active**. |

---

## 9. Optional: dedicated `#mohamed` / `#arinze` later

If you later split personal traffic out of **general**, add private channels and **Deny View** for other bots per room. Not required while **general** remains the shared hub.

---

## 10. Related docs

| Doc | Role |
|-----|------|
| `docs/tower-architecture.md` | Teammate on-ramp — Discord architecture in context of full Tower stack |
| `docs/tower-agent-access-architecture.md` | Who may use which bot + MemOS + **Discord layout summary** + **implementation status** (done / partial / to-do) |
| `docs/tower-architecture-solidification-roadmap.md` | Phased solidification |
| `docs/hermes-tower-inventory.md` | Ops runbook |

---

## 11. Revision history

| Date | Change |
|------|--------|
| 2026-05-12 | Initial + iterations: permission overrides, /sethome, verification. |
| 2026-05-12 | **Layout:** keep `#general` (all agents, threads as-is); **`#hr`** + **`#research`** with Deny View for other bots; humans via roles + allowlists. |
| 2026-05-12 | §3.5: `#hr` as HR **home** — reply **without** mandatory @mention (reverts earlier mention-only draft). |
| 2026-05-12 | §3.5: note **`auto_thread` / `free_response_channels`** in `hr-agent` `config.yaml` (Tower). |
| 2026-05-12 | §3.2: HR thread perms — **private threads** + **category** overrides (50001). |
| 2026-05-12 | §3.5: journal **50001** auto-thread / Telegram token / exit `1` notes. |
| 2026-05-12 | §8 row 1b: verification vs **actual** `#hr` ambient chat (pointer to architecture §7). |
| 2026-05-12 | §8 row **1b** marked **verified** (`#hr` no-@). |
| 2026-05-12 | §8 row **2**: operator confirms **`#research`** layout = **`#hr`** pattern + id. |
| 2026-05-12 | §3.5 item 3: Hermes semantics — **`require_mention: true`** works **with** **`free_response_channels`** for home-only ambient; §4 **`#general`** mention-only policy for specialists + CEO. |
| 2026-05-12 | §6: **`DISCORD_HOME_CHANNEL`** vs **`#hr`** / **`free_response_channels`** consistency (mis-pointed home → no reply in **`#hr`**). §8 row **1b** wording. |
| 2026-05-12 | §6: **`10003 Unknown Channel`** troubleshooting — align ids with **`hr-agent/channel_directory.json`**. |
