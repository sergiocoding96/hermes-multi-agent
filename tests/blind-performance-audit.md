# MemOS Performance Blind Audit

Paste this into a fresh Claude Code session at `/home/openclaw/Coding/Hermes`.

---

## Prompt

There is a memory storage API at `http://localhost:8001`. Source: `/home/openclaw/.local/lib/python3.12/site-packages/memos/`. Config: `/home/openclaw/Coding/MemOS/.env`. Agent keys: `/home/openclaw/Coding/Hermes/agents-auth.json`.

Your job: **Benchmark this system's performance and identify bottlenecks.** Measure latency, throughput, and scaling behavior.

Create your own test users/cubes. Run each benchmark multiple times and report mean, p50, p95, p99.

**Write latency:**
- Measure write time for fine mode vs fast mode. What's the distribution? What causes the variance?
- Measure write time as the cube grows: 0 memories, 10, 50, 100, 500. Does it degrade? Why?
- Measure write time for different content sizes: 50 words, 200 words, 500 words, 2000 words, 5000 words.
- What's the bottleneck? Read the code to determine: is it the LLM call, the embedding, the graph DB write, or the vector DB write?

**Search latency:**
- Measure search time with relativity=0.0 vs 0.05 vs 0.20. Does threshold affect speed?
- Measure search time with top_k=5 vs 10 vs 50 vs 100.
- Measure search time with dedup=no vs sim vs mmr. Which is fastest? Which is most expensive?
- Measure search time as cube size grows: 10, 50, 100, 500 memories.
- What's the bottleneck? Embedding the query, vector search, reranking, or graph traversal?

**Throughput:**
- Maximum writes per minute in fine mode. Maximum in fast mode.
- Maximum searches per second.
- Does concurrent load affect individual request latency? At what concurrency does it saturate?

**Resource consumption:**
- Memory usage (RSS) at idle, after 100 writes, after 500 writes.
- CPU usage during writes vs searches.
- Disk usage growth per memory stored.
- Which component consumes the most resources: MemOS server, Neo4j, or Qdrant?

**Scaling limits:**
- At what cube size does search latency exceed 1 second?
- At what concurrent load does the server start returning errors?
- Is there a memory leak? Monitor RSS over 100 sequential writes.

Profile with `time`, `psutil`, or `py-spy` where needed. Trace the code to explain why bottlenecks exist, not just where. End with a summary table and recommendations.

Do not read `/tmp/`, `CLAUDE.md`, or existing test scripts.
