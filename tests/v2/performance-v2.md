# Hermes v2 Performance Blind Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## Your Job

**Measure capture latency, search speed, scaling limits, memory footprint, and hub throughput.** Score performance 1-10 based on production expectations.

Use markers: `PERF-AUDIT-<timestamp>`.

## Probes

1. **Capture latency:** Write 100 single-sentence messages in rapid succession. Measure time per message from send to SQLite write. What's P50, P95, P99?

2. **Search latency (keyword):** Write 500 memories with varied keywords. Time 50 FTS5 keyword searches. Average latency?

3. **Search latency (vector):** Time 50 semantic searches on the same 500 memories. Vector search slower than keyword?

4. **Hybrid fusion overhead:** Compare (keyword-only) vs (vector-only) vs (hybrid with RRF). Does fusion improve relevance? At what cost?

5. **Scaling to 2k memories:** Write 2k memories. Does search latency degrade? By how much?

6. **Memory footprint:** Measure RSS of the agent process at: idle, after 500 memories, after 2k memories. Growth trajectory?

7. **Hub throughput:** Bombard the hub with GET requests. How many queries per second before saturation?

8. **Skill evolution time:** Let the plugin run skill evolution on 50 captured turns. How long does the LLM-driven pipeline take? Wall time vs. LLM token time?

9. **Concurrent agent load:** Start 3 Hermes agents simultaneously, each writing 100 messages. What's the aggregate throughput? Does one agent's activity starve the others?

10. **Large document ingestion:** Write a 20k-word document in one turn. Chunking time? Search latency after?

## Report

For each metric: test, methodology, raw numbers, expected-vs-actual, 1-10 score.

Summary with bottleneck identification and overall performance score.
