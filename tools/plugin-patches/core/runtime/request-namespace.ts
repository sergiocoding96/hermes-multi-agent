/**
 * Per-request namespace override via AsyncLocalStorage.
 *
 * Added by the Hermes integration (2026-05-17) to support a "view as
 * <profile>" toggle in the bundled viewer. The HTTP dispatch layer parses
 * `?as_profile=<name>` or `X-As-Profile: <name>` from each request and runs
 * the handler inside `runWithRequestNamespace(ns, …)`. Visibility checks in
 * `core/pipeline/memory-core.ts` (`visibleToCurrent`, etc.) prefer the
 * ALS-scoped namespace over the daemon's startup-bound `activeNamespace`,
 * so list/get endpoints automatically show the requested profile's rows.
 *
 * Search endpoints already accept `query.namespace` explicitly — they
 * are wired separately in `server/routes/memory.ts`.
 *
 * See: memos-setup/learnings/2026-05-17-v2-only-bge-shares.md
 *      (section "Per-agent toggle in the bundled viewer")
 */

import { AsyncLocalStorage } from "node:async_hooks";
import type { RuntimeNamespace } from "./namespace.js";

const als = new AsyncLocalStorage<RuntimeNamespace>();

export function runWithRequestNamespace<T>(
  ns: RuntimeNamespace,
  fn: () => T | Promise<T>,
): T | Promise<T> {
  return als.run(ns, fn);
}

export function getRequestNamespace(): RuntimeNamespace | undefined {
  return als.getStore();
}
