#!/usr/bin/env bash
# Shared helper: safely collapse leaked MemOS bridge processes.
#
# WHY THIS EXISTS: the old band-aids ran `pkill -f 'bridge\.cts'`, which (1) kills
# the :18800 viewer/daemon bridge too — taking down the memory UI and capture for
# every agent — and (2) matches ANY process whose command line merely contains the
# string "bridge.cts" (e.g. an interactive admin shell that's grepping for it),
# SIGTERMing it. Both bit us during the 2026-05-26 capture-outage recovery.
#
# This helper instead:
#   - only targets real bridge *node* processes (comm = node/tsx), never shells;
#   - never kills the process holding TCP :18800 (the daemon) or its parent wrapper;
#   - kills the rest by explicit PID.
#
# The proper fix for the leak itself is the adapter's serialized cold-boot +
# raised session.open timeout (see memos_provider/__init__.py and the
# 2026-05-26 decision doc); this helper is only a safety net.

safe_bridge_cleanup() {
  local keep_pid keep_ppid pid comm
  keep_pid="$(ss -ltnp 2>/dev/null | grep ':18800' | grep -oP 'pid=\K[0-9]+' | head -1)"
  keep_ppid="$(ps -o ppid= -p "${keep_pid:-0}" 2>/dev/null | tr -d ' ')"
  for pid in $(pgrep -f 'bridge\.cts --agent' 2>/dev/null); do
    # only real node bridge procs, never shells that merely mention the string
    comm="$(ps -o comm= -p "$pid" 2>/dev/null)"
    case "$comm" in *node*|*tsx*) ;; *) continue ;; esac
    [ "$pid" = "$keep_pid" ] && continue
    [ "$pid" = "$keep_ppid" ] && continue
    kill "$pid" 2>/dev/null || true
  done
}
