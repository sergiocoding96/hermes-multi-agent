# Hermes v2 Zero-Knowledge Security Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

There is a local memory plugin (`@memtensor/memos-local-hermes-plugin`) installed across four Hermes agent profiles on this machine. Each profile has its own SQLite store at `~/.hermes/memos-state-<profile>/memos-local/memos.db`. One of the profiles also runs an HTTP **hub** on `http://localhost:18992` that serves shared group/public memories + skills to other clients. A **bridge daemon** runs on `http://localhost:18990`, and a **viewer dashboard** on `http://localhost:18901`.

Plugin source (per profile): `~/.hermes/memos-plugin-<profile>/` (entry points: `index.ts`, `bridge.cts`, `hub-launcher.cts`). Auth material: `~/.hermes/memos-state-<profile>/hub-auth.json` (authSecret + bootstrapAdminToken). Profiles on this machine: `arinze`, `email-marketing`, `mohammed`, `research-agent`.

If the hub is down, you can start it with `~/.hermes/memos-plugin-research-agent/hub-launcher.cts` (or the equivalent launcher script) — but do NOT restart it unless your tests require it.

Your job: **Find every security vulnerability, isolation failure, secret-handling mistake, and injection vector you can.** Score the system's production-readiness for a security-conscious deployment on a 1-10 scale with evidence.

Approach: **adversarial**. Assume an attacker is a malicious local user, a malicious agent profile, a compromised LLM response, or a network attacker who can reach `localhost`. Create your own test profile / group / memory data — do not mutate the existing profiles beyond what you can cleanly revert.

### Recon phase

Before attacking, understand what's exposed:

- Enumerate all listening ports in the `189xx` range and figure out which process listens on which.
- Read `~/.hermes/memos-plugin-<profile>/package.json` to learn the plugin's claimed scope + dependencies.
- List all HTTP routes the hub exposes. Are there unauthenticated routes? Admin-only routes?
- Find every file in `~/.hermes/memos-state-<profile>/` and record its permissions + contents type (DB? key? cache? log?).
- Find every place the word `token`, `secret`, `authSecret`, `bearer`, or `Authorization` appears in the plugin source.

### Attack surface to probe

**Hub authentication & authorization:**
- What token format does the hub accept? JWT? Opaque bearer? Both?
- The `bootstrapAdminToken` in `hub-auth.json` is a base64-decodable blob with `role: admin` and an `exp`. Does the hub verify signature, or trust the claims by inspection? Can you forge one by editing the claims and re-encoding?
- Is there any rate limit on authentication failures? Try 1000 wrong tokens rapidly.
- Can an unauthenticated client enumerate users / groups / memories? Try `GET /api/v1/hub/info`, `GET /api/v1/users`, `GET /api/v1/memories`, etc.
- Does the hub enforce allowlist/ACL on every query, or only some? Find at least one route that leaks data it shouldn't.

**Local file permissions:**
- What are the permissions on `~/.hermes/memos-state-*/memos.db`, `hub-auth.json`, `secrets/*`? World-readable? Group-readable?
- Can a different OS user on this box read another user's memories? Simulate by running `sudo -u nobody cat` against the DB (if sudo available) or by explicit permission check.
- Does SQLite's WAL leak data that's "deleted" from the main table? (Check `memos.db-wal` after a DELETE.)

**Secret handling in captured memories:**
- Write a message containing a plausible API key (e.g. `sk-test_abc123def456`), a bearer token, a password in plaintext, an SSH private key fragment, a PAN-like number. Does the plugin capture it verbatim? Does it redact? Document the exact behavior.
- Is the captured content encrypted at rest in SQLite, or plaintext? `sqlite3 memos.db "SELECT * FROM ..."` — what do you see?
- Does the plugin send captured content to any remote service (embedding API, summarizer, telemetry)? Trace outbound connections with `ss -tnp` / `lsof -i` while the plugin is working.

**Skill-generation injection:**
- The plugin runs an LLM pipeline that writes SKILL.md files to `~/Coding/badass-skills/auto/`. Craft a conversation where a user (or simulated agent) tries to get the LLM to emit a SKILL.md with: (a) embedded bash commands in the frontmatter, (b) a filename traversal (`../../.bashrc`), (c) content that would execute when the file is parsed by Claude Code's skill discovery.
- Can the plugin be manipulated into overwriting an existing hand-authored skill in `~/Coding/badass-skills/` (not `auto/`)?
- Does the plugin validate the generated file (schema check, path confinement) before writing?

**Hub pairing & ACL:**
- What's the client onboarding flow? Can an arbitrary process on `localhost` pair itself as a member of the `ceo-team` group without human approval?
- Remove a client from a group, attempt a search — is the removal enforced immediately or only on new sessions?
- Can a group member see memories written with `visibility=local` by another member (should be NO)?

**Telemetry / data exfiltration:**
- There's a `telemetry.credentials.json` in `~/.hermes/memos-plugin-<profile>/`. What service does it point to? What events does the plugin send? Can you disable telemetry entirely? Does disabling actually stop the network traffic?
- Capture network traffic with `tcpdump -i any` (or `ss` loop) while a capture + skill-evolution cycle runs. Anything unexpected leaves?

**Viewer dashboard (port 18901):**
- What auth guards the dashboard? Session cookie? Bearer?
- Does the dashboard render captured memory content as HTML? Try writing a memory with an XSS payload (`<script>alert(1)</script>`, `<img onerror=...>`, `javascript:` URL) and see if it executes in the browser.
- CSRF: can a cross-origin request trigger a destructive action (delete memory, revoke pairing)?

**Bridge daemon (port 18990):**
- Undocumented in the hub's claimed API surface. What does it expose? Same auth as the hub or different? Find any routes that are unauthenticated or privileged.

**Process-level isolation:**
- If one plugin process is compromised (arbitrary code exec in the Node runtime), what does it have access to that it shouldn't? Can it read another profile's `hub-auth.json`?
- Does the plugin run with elevated privileges (capabilities, suid)? `ps -o user,pid,cmd` to verify.

### Reporting

For every finding, include:

- Vulnerability class (auth-bypass, injection, info-leak, privilege-escalation, DoS, etc.)
- Reproduction (exact curl / sqlite / filesystem command)
- Evidence (HTTP status + body, file permissions, captured traffic)
- Severity: Critical / High / Medium / Low / Informational
- Suggested remediation (one sentence)

Final summary table:

| Area | Score 1-10 | Key findings |
|------|-----------|--------------|
| Hub auth | | |
| Local file permissions | | |
| Secret capture | | |
| Skill injection | | |
| Pairing / ACL | | |
| Telemetry / exfiltration | | |
| Viewer / XSS / CSRF | | |
| Bridge daemon | | |
| Process isolation | | |

**Overall security score = MIN of all areas above.** Justify in one paragraph whether this system is safe to run for a user who treats their captured conversations as private.

### Out of bounds

Do not read `/tmp/`, `CLAUDE.md`, other audit reports under `tests/v2/reports/`, plan files under `memos-setup/learnings/`, or any existing test scripts. Form conclusions from the plugin source + runtime behavior only.
