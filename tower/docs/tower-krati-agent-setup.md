# Tower — Krati personal agent (`krati`)

Hermes profile **`krati`** is **Krati’s personal Discord agent** on **`sergio`**, aligned with **`mohammed`** and **`arinze`** (THE SPIRE `#general` hub + DM). Policy: [`tower-agent-access-architecture.md`](tower-agent-access-architecture.md).

**Provision on `sergio`:** `scripts/tower-provision-krati-agent.sh`

---

## 1. What you get

| Item | Value |
|------|--------|
| Hermes profile | `krati` |
| Profile path | `~/.hermes/profiles/krati/` |
| systemd unit | `hermes-gateway-krati.service` |
| Discord bot (example name) | **Hermes-Krati-Agent** (create in Developer Portal) |
| Primary owner | **Krati only** (`DISCORD_ALLOWED_USERS`) |
| MemOS `user_id` | `krati` |
| MemOS `cube_id` | `krati-cube` |
| THE SPIRE `#general` id | `1503342972950024244` |
| Delegation (default) | None — add HR/Research ids to specialist profiles if policy changes |

---

## 2. On Discord (operator)

1. [Discord Developer Portal](https://discord.com/applications) → **New Application** → name e.g. **Hermes-Krati-Agent**.
2. **Bot** → **Reset Token** → copy token (store only on `sergio`, not in this repo).
3. **Privileged Gateway Intents** → enable **Message Content Intent** (and others your stack uses).
4. **OAuth2 → URL Generator** → scopes `bot` → permissions: View Channels, Send Messages, Read Message History, Send Messages in Threads (if threads used elsewhere).
5. Open generated URL → invite bot to **THE SPIRE** server.
6. In server **Roles**, grant the Krati bot role **View/Send** on **`#general`** (and channels Krati should use). For **`#hr`** / **`#research`**, **Deny View** for Krati bot (same clean-room as other non-specialist bots) — see [`tower-discord-channels-permissions.md`](tower-discord-channels-permissions.md).

---

## 3. On `sergio` (SSH as `openclaw`)

1. Run provision (idempotent):

   ```bash
   bash scripts/tower-provision-krati-agent.sh
   ```

2. Edit secrets (do not commit):

   ```bash
   nano ~/.hermes/profiles/krati/.env
   ```

   Set:

   - `DISCORD_BOT_TOKEN=<token from step 2>`
   - `DISCORD_ALLOWED_USERS=<Krati numeric Discord user id>`
   Or run (creates user, cube, API key, and writes `.env`):

   ```bash
   bash scripts/tower-provision-krati-memos.sh
   ```

   Sets: `MEMOS_USER_ID=krati`, `MEMOS_CUBE_ID=krati-cube`, unique `MEMOS_API_KEY`.

   Confirm already set by script:

   - `DISCORD_HOME_CHANNEL=1503342972950024244`
   - `DISCORD_IGNORE_NO_MENTION=false`

3. Start gateway:

   ```bash
   systemctl --user daemon-reload
   systemctl --user enable --now hermes-gateway-krati.service
   ```

4. If Krati must approve pairing (Hermes policy):

   ```bash
   hermes --profile krati pairing list
   hermes --profile krati pairing approve discord <code>
   ```

---

## 4. Verify

1. On `sergio`:

   ```bash
   systemctl --user is-active hermes-gateway-krati.service
   journalctl --user -u hermes-gateway-krati.service -n 30 --no-pager | grep -iE 'discord|error|401'
   ```

   Expect: unit **active**; no recurring **401** or intent errors.

2. **Krati on Discord:**

   1. **DM:** `@` bot once → short follow-up **without** `@`.
   2. **`#general`:** `@` bot once → short follow-up **without** `@` in the **main** channel (not a new thread per message).

---

## 5. Revision history

| Date | Change |
|------|--------|
| 2026-05-16 | Initial Krati profile + provision script + operator checklist. |
