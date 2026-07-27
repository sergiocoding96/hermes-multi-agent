#!/usr/bin/env node
// PERF-AUDIT harness — drives the memos-local bridge daemon over TCP JSON-RPC.
// Standalone. No dependency on repo benchmark scripts.
import net from "node:net";
import fs from "node:fs";
import { performance } from "node:perf_hooks";
import crypto from "node:crypto";

const PORT = Number(process.env.PORT || 19001);
const HOST = "127.0.0.1";
const MARKER = process.env.MARKER || "PERF-AUDIT-" + Date.now();

// --- JSON-RPC client: one persistent connection, newline-delimited. -------
class RpcClient {
  constructor(host, port) {
    this.host = host; this.port = port;
    this.sock = null; this.buf = ""; this.nextId = 1;
    this.pending = new Map();
  }
  connect() {
    return new Promise((res, rej) => {
      const s = net.createConnection({ host: this.host, port: this.port });
      s.setNoDelay(true);
      s.once("connect", () => { this.sock = s; res(); });
      s.once("error", rej);
      s.on("data", (d) => {
        this.buf += d.toString("utf8");
        let idx;
        while ((idx = this.buf.indexOf("\n")) >= 0) {
          const line = this.buf.slice(0, idx); this.buf = this.buf.slice(idx + 1);
          if (!line.trim()) continue;
          let msg; try { msg = JSON.parse(line); } catch { continue; }
          const p = this.pending.get(msg.id);
          if (p) { this.pending.delete(msg.id); p.resolve(msg); }
        }
      });
      s.on("close", () => { for (const p of this.pending.values()) p.reject(new Error("closed")); });
    });
  }
  call(method, params) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve: (m) => m.error ? reject(new Error(m.error)) : resolve(m.result), reject });
      this.sock.write(JSON.stringify({ id, method, params }) + "\n");
    });
  }
  close() { try { this.sock?.end(); } catch {} }
}

// --- Stats ---------------------------------------------------------------
function pct(arr, p) {
  if (!arr.length) return NaN;
  const s = [...arr].sort((a,b)=>a-b);
  const i = Math.min(s.length - 1, Math.floor(s.length * p / 100));
  return s[i];
}
function summ(name, samples, extra={}) {
  const s = samples.filter(Number.isFinite);
  return {
    name, n: s.length,
    p50: +pct(s,50).toFixed(1), p95: +pct(s,95).toFixed(1), p99: +pct(s,99).toFixed(1),
    min: +Math.min(...s).toFixed(1), max: +Math.max(...s).toFixed(1),
    mean: +(s.reduce((a,b)=>a+b,0)/s.length).toFixed(1),
    ...extra,
  };
}

// --- Synthetic corpus ----------------------------------------------------
const TOPICS = [
  "quantum computing qubit decoherence error correction surface code",
  "distributed systems raft consensus leader election log replication",
  "transformer attention multihead positional encoding flash attention",
  "rust ownership borrow checker lifetime annotation async tokio",
  "sqlite WAL journal mode checkpoint fsync durability guarantee",
  "kubernetes pod scheduler taint toleration affinity node selector",
  "tcp congestion control cubic bbr retransmission timeout rtt",
  "postgres MVCC vacuum bloat index-only scan query planner",
  "linear algebra eigendecomposition singular value decomposition PCA",
  "neural retrieval dense embedding bi-encoder cross-encoder reranking",
];
const rng = (seed) => {
  let s = seed; return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 2**32; };
};
function makeTurn(i) {
  const r = rng(i + 1);
  const t = TOPICS[i % TOPICS.length];
  const variants = [
    `Discussion about ${t}. Case ${i}: analyzing trade-offs in depth with examples and failure modes. ${MARKER}-${i}`,
    `Implementation note on ${t}. Iteration ${i} produced metric=${(r()*100).toFixed(3)} across 5 runs. ${MARKER}-${i}`,
    `Debug log for ${t}. Request ${i} failed at line ${(r()*1000)|0} with code 0x${((r()*0xffff)|0).toString(16)}. ${MARKER}-${i}`,
  ];
  const user = variants[i % 3];
  const assistant = `Response ${i}: root cause analysis on ${t}. Key insight: consider the interaction between layers. Recommendation ${(r()*100).toFixed(1)}% confidence. Context reference ${MARKER}.`;
  return [
    { role: "user", content: user },
    { role: "assistant", content: assistant },
  ];
}

// --- Test scenarios ------------------------------------------------------
async function runSequentialCaptures(client, n, labelPrefix="") {
  const times = [];
  for (let i = 0; i < n; i++) {
    const msgs = makeTurn(i);
    const t0 = performance.now();
    await client.call("ingest", { messages: msgs, sessionId: `perf-seq-${labelPrefix}` });
    times.push(performance.now() - t0);
  }
  return times;
}
async function runConcurrentCaptures(client, concurrency, perWorker=5) {
  const all = [];
  const workers = [];
  const t0 = performance.now();
  for (let w = 0; w < concurrency; w++) {
    workers.push((async () => {
      for (let i = 0; i < perWorker; i++) {
        const t = performance.now();
        await client.call("ingest", { messages: makeTurn(w*10000 + i), sessionId: `perf-c${concurrency}-w${w}` });
        all.push(performance.now() - t);
      }
    })());
  }
  await Promise.all(workers);
  const total = performance.now() - t0;
  return { times: all, totalMs: total, throughputOps: (concurrency*perWorker) / (total/1000) };
}
async function runSearches(client, queries) {
  const times = [];
  const hitCounts = [];
  for (const q of queries) {
    const t0 = performance.now();
    const r = await client.call("search", { query: q, maxResults: 10 });
    times.push(performance.now() - t0);
    hitCounts.push((r?.hits ?? r?.local?.hits ?? []).length);
  }
  return { times, hitCounts };
}

const KEYWORD_QS = TOPICS.flatMap(t => t.split(" ").slice(0,2)).slice(0, 50).map(w => `${w}`);
const SEMANTIC_QS = [
  "how do distributed consensus algorithms elect a leader",
  "what makes a database durable under crash conditions",
  "explain the attention mechanism in deep learning architectures",
  "why does my async code deadlock when holding locks across awaits",
  "container orchestration scheduling constraints for co-location",
  "why do TCP flows slow down when packet loss happens",
  "how does a query planner decide when to use an index",
  "principal component analysis intuition for dimensionality reduction",
  "dense vs sparse retrieval comparison for question answering",
  "quantum error correction using topological codes",
].flatMap(q => [q, q+" in practice", q+" tradeoffs", q+" at scale", q+" with examples"]).slice(0, 50);

// --- Main ---------------------------------------------------------------
const out = { startedAt: new Date().toISOString(), marker: MARKER, steps: [] };
function log(step, obj) { out.steps.push({ step, ...obj }); console.log(`[${step}]`, JSON.stringify(obj)); }

async function main() {
  const mode = process.argv[2] || "all";
  const c = new RpcClient(HOST, PORT);
  await c.connect();

  // Warm + cold probe
  const tPing0 = performance.now(); await c.call("ping", {}); log("ping", { ms: +(performance.now()-tPing0).toFixed(1) });

  if (mode === "cold-capture" || mode === "all") {
    // First capture = cold (embedder may warm up here)
    const t0 = performance.now();
    await c.call("ingest", { messages: makeTurn(-1), sessionId: "perf-cold" });
    log("capture_cold", { ms: +(performance.now()-t0).toFixed(1) });

    // Sequential warm captures
    const times = await runSequentialCaptures(c, 100, "warm");
    log("capture_warm_sequential_n100", summ("cap_seq", times));
  }

  if (mode === "concurrent" || mode === "all") {
    for (const N of [1,5,10,25,50]) {
      const r = await runConcurrentCaptures(c, N, 3);
      log(`concurrent_N${N}`, { ...summ(`c${N}`, r.times), totalMs: +r.totalMs.toFixed(1), throughputOps: +r.throughputOps.toFixed(2) });
    }
  }

  if (mode === "search" || mode === "all") {
    // Count DB rows first
    const recent = await c.call("recent", { limit: 1 });
    log("recent_probe", { sampleCount: recent.total });

    const ksr = await runSearches(c, KEYWORD_QS);
    log("search_keyword", { ...summ("kw", ksr.times), avgHits: +(ksr.hitCounts.reduce((a,b)=>a+b,0)/ksr.hitCounts.length).toFixed(2) });

    const ssr = await runSearches(c, SEMANTIC_QS);
    log("search_semantic", { ...summ("sem", ssr.times), avgHits: +(ssr.hitCounts.reduce((a,b)=>a+b,0)/ssr.hitCounts.length).toFixed(2) });
  }

  if (mode === "scale-search") {
    // Just run searches at current DB size
    const ksr = await runSearches(c, KEYWORD_QS);
    const ssr = await runSearches(c, SEMANTIC_QS);
    log("scale_search_result", {
      keyword: summ("kw", ksr.times),
      semantic: summ("sem", ssr.times),
    });
  }

  if (mode === "preload") {
    // Bulk-load N captures for scaling tests
    const N = Number(process.argv[3] || 500);
    const CONC = 4;
    console.error(`[preload] loading ${N} captures at concurrency ${CONC}...`);
    const tStart = performance.now();
    let done = 0;
    const workers = Array.from({length: CONC}, (_, w) => (async () => {
      while (true) {
        const i = done++;
        if (i >= N) return;
        await c.call("ingest", { messages: makeTurn(100000 + i), sessionId: `preload-w${w}` });
        if (i % 50 === 0) console.error(`[preload] ${i}/${N}`);
      }
    })());
    await Promise.all(workers);
    log("preload", { n: N, totalMs: +(performance.now()-tStart).toFixed(1) });
  }

  c.close();
  fs.writeFileSync(`/home/openclaw/Coding/Hermes/perf-audit-results-${Date.now()}.json`, JSON.stringify(out, null, 2));
  console.log("\n=== DONE ===");
}
main().catch(e => { console.error("FATAL", e); process.exit(1); });
