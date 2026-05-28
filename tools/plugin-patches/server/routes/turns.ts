/**
 * Turn-lifecycle WRITE endpoints (P3.1 — shared single daemon).
 *
 * The capture write path (`turn.start` / `turn.end`) was previously available
 * only over the per-gateway stdio bridge. Exposing it over the daemon's HTTP API
 * lets gateways become thin HTTP clients of the ONE :18800 daemon (one BGE-large
 * load total) instead of each spawning a full bridge.cts. These call the SAME
 * core methods the stdio dispatch uses (`bridge/methods.ts`: core.onTurnStart /
 * core.onTurnEnd), and run inside the per-request namespace (X-As-Profile) wired
 * in server/http.ts, so a write lands in the caller's profile.
 *
 * AUTH: these are gated by the same session check as every other /api/* route.
 * They are NOT in the public allowlist — a loopback bypass would be unsafe
 * because Tailscale Serve proxies tailnet → 127.0.0.1, so loopback ≠ local-user.
 * The adapter HTTP cutover (spec step 3) adds a per-boot internal token for the
 * gateways; until then these are reachable with a viewer session cookie (used by
 * tests).
 */

import type { TurnInputDTO, TurnResultDTO } from "../../agent-contract/dto.js";
import type { ServerDeps } from "../types.js";
import { parseJson, writeError, type Routes } from "./registry.js";

export function registerTurnRoutes(routes: Routes, deps: ServerDeps): void {
  routes.set("POST /api/v1/turn/start", async (ctx) => {
    const body = parseJson<Partial<TurnInputDTO>>(ctx);
    if (!body.sessionId || !body.userText) {
      writeError(ctx, 400, "invalid_argument", "sessionId and userText are required");
      return;
    }
    return await deps.core.onTurnStart(body as unknown as TurnInputDTO);
  });

  routes.set("POST /api/v1/turn/end", async (ctx) => {
    const body = parseJson<Partial<TurnResultDTO>>(ctx);
    if (!body.sessionId || !body.episodeId) {
      writeError(ctx, 400, "invalid_argument", "sessionId and episodeId are required");
      return;
    }
    return await deps.core.onTurnEnd(body as unknown as TurnResultDTO);
  });
}
