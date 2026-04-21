# Hermes v2 Zero-Knowledge Security Audit

Paste this entire prompt into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`. Do not read CLAUDE.md, /tmp/, existing test scripts, or plan files.

---

## System Under Test

- **Plugin:** `@memtensor/memos-local-hermes-plugin` installed in `~/.hermes/profiles/research-agent/` and `~/.hermes/profiles/email-marketing/`
- **Hub:** HTTP server at `http://localhost:18992` (if down, restart: `~/.hermes/bin/hub-launcher.js`)
- **Local DB:** SQLite in each agent's `~/.hermes/memos-state-<profile>/` directory
- **Source:** Plugin code and documentation (explore `node_modules/@memtensor/memos-local-hermes-plugin/`)
- **Auth:** Hub uses bearer token authentication (token location documented in hub startup logs or config)

## Your Job

**Find every security vulnerability, data isolation issue, and infrastructure exposure you can.** Score production-readiness 1-10 with evidence.

Discover: auth flows, token types, rate limits, local file permissions, capture safety (secrets in conversations?), skill-generation injection vectors, pairing flows, telemetry, dashboard auth, and any credentials accidentally baked into code or logs.

Do not reuse existing test data. Create your own test users and markers (e.g., `SEC-AUDIT-<timestamp>`).

## Probes

1. **Hub authentication:** What token types does the hub accept? Where are tokens stored locally? Can an unauthenticated client read memories?
2. **Local file permissions:** Check `~/.hermes/memos-state-*/` directory and DB file permissions. Can another user on this machine read agent memories?
3. **Secrets in capture:** Write a message containing an API key (real or fake). Does the plugin auto-capture it? If so, where is it stored? Who can access it?
4. **Skill injection:** Try to craft a conversation that makes the LLM generate a malicious SKILL.md file (e.g., bash commands in the metadata). Does the plugin validate the generated file?
5. **Hub pairing:** Can an unauthenticated client pair with the hub? What's required?
6. **Rate limiting:** Hammer the hub with 100 concurrent requests. Does it rate-limit? What's the ceiling?
7. **Telemetry:** The plugin may include opt-out telemetry. If enabled, what data leaves the machine? Can you intercept it?
8. **Viewer dashboard:** Check `http://localhost:18992/` (or documented viewer URL). What auth is required? Can you XSS stored memory content?
9. **Embedding model:** Plugin uses local Xenova embeddings. Are there any side-channel risks (e.g., timing attacks on similarity)?
10. **Config files:** Search for hardcoded secrets, API keys, or bearer tokens in `~/.hermes/config.yaml`, plugin code, or hub logs.

## Report

For each area, record:
- What you tested
- Expected vs. actual behavior
- Evidence (curl output, file permissions, code paths)
- Security score 1-10

End with a summary table and overall production-readiness score.
