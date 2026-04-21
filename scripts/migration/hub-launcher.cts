/**
 * hub-launcher.cts — start @memtensor/memos-local-hermes-plugin in HUB mode.
 *
 * The plugin's bridge.cts daemon handles JSON-RPC for Hermes but does NOT
 * start the hub HTTP server (HubServer is only wired by the OpenHarness
 * entry in index.ts). This launcher imports HubServer directly so we can
 * run the hub as a standalone process.
 *
 * Config is read from MEMOS_BRIDGE_CONFIG (same env var the bridge uses):
 *   {
 *     "stateDir": "...",
 *     "config": {
 *       "sharing": {
 *         "enabled": true,
 *         "role": "hub",
 *         "hub": { "port": 18992, "teamName": "ceo-team", "teamToken": "..." }
 *       },
 *       "embedding": { "provider": "local" }
 *     }
 *   }
 *
 * This file is copied into the plugin install dir at bootstrap time so that
 * its relative imports into src/ resolve via the installed plugin's code.
 */

import { SqliteStore } from "./src/storage/sqlite";
import { Embedder } from "./src/embedding";
import { HubServer } from "./src/hub/server";
import { buildContext } from "./src/config";
import { ensureSqliteBinding } from "./src/storage/ensure-binding";
import type { Logger } from "./src/types";
import * as fs from "fs";
import * as path from "path";

const logger: Logger = {
  debug: (msg: string) => process.stderr.write(`[debug] ${msg}\n`),
  info:  (msg: string) => process.stderr.write(`[info] ${msg}\n`),
  warn:  (msg: string) => process.stderr.write(`[warn] ${msg}\n`),
  error: (msg: string) => process.stderr.write(`[error] ${msg}\n`),
};

function parseConfig() {
  const raw = process.env.MEMOS_BRIDGE_CONFIG;
  if (!raw) {
    logger.error("MEMOS_BRIDGE_CONFIG not set — refusing to start with defaults");
    process.exit(2);
  }
  try { return JSON.parse(raw); } catch (err) {
    logger.error(`MEMOS_BRIDGE_CONFIG parse failed: ${err}`);
    process.exit(2);
  }
}

async function main(): Promise<void> {
  const configOpts = parseConfig();
  const stateDir: string = configOpts.stateDir;
  if (!stateDir) { logger.error("stateDir is required"); process.exit(2); }

  fs.mkdirSync(stateDir, { recursive: true });

  ensureSqliteBinding(logger);

  const ctx = buildContext(stateDir, process.cwd(), configOpts.config, logger);
  if (!ctx.config.sharing?.enabled || ctx.config.sharing.role !== "hub") {
    logger.error("config.sharing.enabled must be true and config.sharing.role must be 'hub'");
    process.exit(2);
  }

  const dbPath = ctx.config.storage?.dbPath ?? path.join(stateDir, "memos-local", "memos.db");
  fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  const store = new SqliteStore(dbPath, logger);
  const embedder = new Embedder(ctx.config.embedding, logger);

  const hub = new HubServer({
    store,
    log: logger,
    config: ctx.config,
    dataDir: stateDir,
    embedder,
  });

  const url = await hub.start();
  logger.info(`hub-launcher: hub up at ${url}`);
  process.stdout.write(JSON.stringify({
    hubUrl: url,
    hubPort: ctx.config.sharing.hub?.port,
    teamName: ctx.config.sharing.hub?.teamName,
    pid: process.pid,
  }) + "\n");

  const shutdown = async (signal: string) => {
    logger.info(`hub-launcher: received ${signal}, shutting down`);
    try { await hub.stop(); } catch (e) { logger.warn(`hub stop error: ${e}`); }
    try { store.close(); } catch (e) { logger.warn(`store close error: ${e}`); }
    process.exit(0);
  };
  process.on("SIGINT",  () => void shutdown("SIGINT"));
  process.on("SIGTERM", () => void shutdown("SIGTERM"));

  setInterval(() => {}, 1 << 30);
}

main().catch((err) => {
  logger.error(`hub-launcher fatal: ${err?.stack ?? err}`);
  process.exit(1);
});
