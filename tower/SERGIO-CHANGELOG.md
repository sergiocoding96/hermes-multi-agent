# Tower changes on sergio (summary for `mohammed-work`)

Recorded **2026-05-16**. Secrets stay on server only (`~/.hermes/profiles/*/.env`, `Coding/Hermes/agents-auth.json`).

## Hermes profiles and gateways

| Profile | Gateway unit | Notes |
|---------|--------------|--------|
| `mohammed` | `hermes-gateway.service` | THE SPIRE `#general` hub, `no_thread_channels` |
| `arinze` | `hermes-gateway-arinze.service` | Aligned to hub + CEO pattern |
| `krati` | `hermes-gateway-krati.service` | **New** — personal agent, MemOS `krati` / `krati-cube` |
| `sergio` | `hermes-gateway-sergio.service` | CEO home + `#general` `@` |
| `hr-agent` | `hermes-gateway-hr-agent.service` | Strict placement, MemOS off |
| `research-agent` | `hermes-gateway-research-agent.service` | Strict placement, MemOS off |

## MemOS

- Local API: `http://localhost:8001` (`memos-server.service`)
- Requires Docker: `qdrant`, `neo4j-docker`
- Krati: user/cube + API key in `agents-auth.json` (not committed)

## Ops scripts

See `tower/scripts/tower-*.sh` — run on sergio as `openclaw`.
