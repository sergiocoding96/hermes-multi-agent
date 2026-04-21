# Hermes v2 Observability Blind Audit

Paste this into a fresh Claude Code Desktop session at `/home/openclaw/Coding/Hermes`.

---

## Your Job

**Verify operators can diagnose the system — logs, dashboard, metrics, health, audit trail.** Score observability 1-10.

Markers: `OBS-AUDIT-<timestamp>`.

## Probes

1. **Agent logs:** Check logs for `~/.hermes/profiles/*/logs/` or wherever configured. Are captures, searches, errors logged? Are log levels configurable?

2. **Hub logs:** Does the hub log requests? Auth failures? Rate limits?

3. **Dashboard usability:** Open the Memory Viewer dashboard at the hub. Can you diagnose "why didn't my memory land"? Can you search and view memories? Delete them? Export?

4. **Health endpoints:** Call hub `/api/v1/hub/info` or documented health endpoint. Does it verify SQLite is accessible? Hub is responsive?

5. **Metrics:** Does the plugin expose Prometheus or other metrics? Capture rates, search latencies, error counts?

6. **Audit trail:** Can you find a record of WHO wrote WHAT memory WHEN? Is this queryable?

7. **Error messages:** Intentionally trigger errors (write invalid JSON, corrupt DB, kill hub). Are error messages helpful or cryptic? Do they guide remediation?

8. **Debug logs:** Is there a verbose/debug mode? Can you enable it to trace a failing capture?

9. **Performance monitoring:** Can you see which queries are slow? Bottlenecks?

10. **Integration tracing:** When Paperclip delegates to Hermes and Hermes captures, can you trace the flow through logs?

## Report

For each area: test, findings (useful info available? helpful errors?), and 1-10 score.

Summary: overall observability score and recommendations for operators.
