# v1.0 Blind Audit — Runbook

Open **8 fresh** Claude Code sessions at `/home/openclaw/Coding/Hermes`. Paste exactly one of the blocks below as the FIRST message of each session. No CLAUDE.md, no prior context. Close session on completion.

All reports converge on the shared branch `tests/v1.0-audit-reports-2026-04-26`. Reports land at `tests/v1/reports/<audit-name>-YYYY-MM-DD.md`.

For full suite context (rubric, contamination ban, throwaway-profile bootstrap), see `tests/v1/README.md`.

---

## 1. Zero-knowledge (security)

```
cd /home/openclaw/Coding/Hermes && git fetch origin && git switch docs/write-v1.0-audit-suite && git pull --rebase
Read tests/v1/zero-knowledge-v1.md and execute it end-to-end. Follow the Deliver section exactly (push to tests/v1.0-audit-reports-2026-04-26).
```

## 2. Functionality (core)

```
cd /home/openclaw/Coding/Hermes && git fetch origin && git switch docs/write-v1.0-audit-suite && git pull --rebase
Read tests/v1/functionality-v1.md and execute it end-to-end. Follow the Deliver section exactly (push to tests/v1.0-audit-reports-2026-04-26).
```

## 3. Resilience

```
cd /home/openclaw/Coding/Hermes && git fetch origin && git switch docs/write-v1.0-audit-suite && git pull --rebase
Read tests/v1/resilience-v1.md and execute it end-to-end. Follow the Deliver section exactly (push to tests/v1.0-audit-reports-2026-04-26).
```

## 4. Performance

```
cd /home/openclaw/Coding/Hermes && git fetch origin && git switch docs/write-v1.0-audit-suite && git pull --rebase
Read tests/v1/performance-v1.md and execute it end-to-end. Follow the Deliver section exactly (push to tests/v1.0-audit-reports-2026-04-26).
```

## 5. Data integrity

```
cd /home/openclaw/Coding/Hermes && git fetch origin && git switch docs/write-v1.0-audit-suite && git pull --rebase
Read tests/v1/data-integrity-v1.md and execute it end-to-end. Follow the Deliver section exactly (push to tests/v1.0-audit-reports-2026-04-26).
```

## 6. Observability

```
cd /home/openclaw/Coding/Hermes && git fetch origin && git switch docs/write-v1.0-audit-suite && git pull --rebase
Read tests/v1/observability-v1.md and execute it end-to-end. Follow the Deliver section exactly (push to tests/v1.0-audit-reports-2026-04-26).
```

## 7. Plugin integration

```
cd /home/openclaw/Coding/Hermes && git fetch origin && git switch docs/write-v1.0-audit-suite && git pull --rebase
Read tests/v1/plugin-integration-v1.md and execute it end-to-end. Follow the Deliver section exactly (push to tests/v1.0-audit-reports-2026-04-26).
```

## 8. Provisioning

```
cd /home/openclaw/Coding/Hermes && git fetch origin && git switch docs/write-v1.0-audit-suite && git pull --rebase
Read tests/v1/provisioning-v1.md and execute it end-to-end. Follow the Deliver section exactly (push to tests/v1.0-audit-reports-2026-04-26).
```

---

## After all 8 complete

```bash
# Pull the latest reports
git fetch origin tests/v1.0-audit-reports-2026-04-26
git switch tests/v1.0-audit-reports-2026-04-26
git pull --rebase origin tests/v1.0-audit-reports-2026-04-26

# Review
ls -la tests/v1/reports/*-2026-04-*.md
```

Aggregate the 8 scores. Per `tests/v1/README.md`, **overall = MIN across all 8**.

| v1 MIN result | Decision (per the approved plan) |
|---|---|
| **≥ 7/10** | Revert to v1 cleanly. v2 stays as dormant spike. |
| **5–6/10** | Patch v1 weak spots first (likely cheaper than v2's 30+ issues), then revert. |
| **< 5/10** | Both stacks weak; reassess from scratch. |
