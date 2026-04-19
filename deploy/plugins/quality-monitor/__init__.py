"""Quality Monitor Plugin — tracks research quality scores and logs agent activity.

Hooks:
- post_tool_call: captures quality_score from research-coordinator outputs
- session_end: logs session summary to quality log

Logs to: ~/.hermes/logs/quality.jsonl
"""

import json
import os
import re
from datetime import datetime
from pathlib import Path

LOG_DIR = Path.home() / ".hermes" / "logs"
QUALITY_LOG = LOG_DIR / "quality.jsonl"
ACTIVITY_LOG = LOG_DIR / "activity.jsonl"


def _ensure_log_dir():
    LOG_DIR.mkdir(parents=True, exist_ok=True)


def _append_log(path, entry):
    _ensure_log_dir()
    with open(path, "a") as f:
        f.write(json.dumps(entry) + "\n")


def _extract_quality_score(text):
    """Extract quality_score from research output text."""
    patterns = [
        r"quality_score[\"']?\s*[:=]\s*([\d.]+)",
        r"Quality Score[:\s]+([\d.]+)",
        r"score[\"']?\s*[:=]\s*([\d.]+)",
    ]
    for pattern in patterns:
        match = re.search(pattern, str(text), re.IGNORECASE)
        if match:
            try:
                score = float(match.group(1))
                if 0 <= score <= 10:
                    return score
            except ValueError:
                pass
    return None


def register(ctx):
    """Register hooks for quality monitoring."""

    tool_call_count = {"n": 0}

    def on_tool_call(tool_name, params, result):
        tool_call_count["n"] += 1

        # Log all tool calls to activity log
        _append_log(ACTIVITY_LOG, {
            "ts": datetime.now().isoformat(),
            "event": "tool_call",
            "tool": tool_name,
            "params_keys": list(params.keys()) if isinstance(params, dict) else [],
            "result_len": len(str(result)) if result else 0,
        })

        # Check for quality scores in research outputs
        result_str = str(result) if result else ""
        score = _extract_quality_score(result_str)
        if score is not None:
            _append_log(QUALITY_LOG, {
                "ts": datetime.now().isoformat(),
                "event": "quality_score",
                "tool": tool_name,
                "score": score,
                "threshold": 7.5,
                "passed": score >= 7.5,
            })
            if score < 5.0:
                print(f"[quality-monitor] LOW SCORE: {score}/10 — consider re-running with skill patches")
            elif score < 7.5:
                print(f"[quality-monitor] MODERATE SCORE: {score}/10 — acceptable but could improve")

    ctx.register_hook("post_tool_call", on_tool_call)
