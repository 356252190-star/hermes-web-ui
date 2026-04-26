#!/usr/bin/env bash
#
# crash-diagnose.sh — Standalone crash diagnosis for hermes-web-ui
#
# Run manually or called by watchdog Phase 2.
# Outputs structured JSON for agent consumption.
#
# Usage:
#   ./crash-diagnose.sh [--port 8648] [--json]
#

set -euo pipefail

PORT="${PORT:-8648}"
JSON_MODE=false
LOG_DIR="$HOME/.hermes-web-ui/logs"

while [[ $# -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; shift 2 ;;
        --json) JSON_MODE=true; shift ;;
        *) shift ;;
    esac
done

# --- Collect info ---
HEALTH_URL="http://127.0.0.1:${PORT}/health"
HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "$HEALTH_URL" 2>/dev/null || echo "000")
PROCESS_ALIVE=$(pgrep -f "hermes-web-ui.*dist/server" >/dev/null 2>&1 && echo "true" || echo "false")
PORT_OCCUPIED=$(lsof -i :"$PORT" >/dev/null 2>&1 && echo "true" || echo "false")
DISK_USAGE=$(df -h / 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%')
MEM_AVAIL=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
CRASH_SIGNAL_EXISTS=$([[ -f "$LOG_DIR/CRASH_SIGNAL" ]] && echo "true" || echo "false")

# Check hermes agent availability (for Phase 3)
HERMES_AGENT_AVAILABLE=false
HERMES_CLI_FOUND=false
command -v hermes >/dev/null 2>&1 && HERMES_CLI_FOUND=true
for agent_port in 8015 18789 8642 8643; do
    if curl -s --connect-timeout 2 "http://127.0.0.1:$agent_port/health" >/dev/null 2>&1; then
        HERMES_AGENT_AVAILABLE=true
        break
    fi
done

# Find latest crash log
LATEST_CRASH_LOG=""
CRASH_LOG_CONTENT=""
if ls "$LOG_DIR"/crash-*.log 1>/dev/null 2>&1; then
    LATEST_CRASH_LOG=$(ls -t "$LOG_DIR"/crash-*.log 2>/dev/null | head -1)
    CRASH_LOG_CONTENT=$(tail -50 "$LATEST_CRASH_LOG" 2>/dev/null || echo "")
fi

# Classify error
ERROR_CLASS="NONE"
if [[ -n "$CRASH_LOG_CONTENT" ]]; then
    if echo "$CRASH_LOG_CONTENT" | grep -qi "EADDRINUSE"; then ERROR_CLASS="PORT_CONFLICT"
    elif echo "$CRASH_LOG_CONTENT" | grep -qi "out of memory\|OOM\|heap"; then ERROR_CLASS="OOM"
    elif echo "$CRASH_LOG_CONTENT" | grep -qi "MODULE_NOT_FOUND"; then ERROR_CLASS="MISSING_MODULE"
    elif echo "$CRASH_LOG_CONTENT" | grep -qi "EACCES\|permission"; then ERROR_CLASS="PERMISSION"
    elif echo "$CRASH_LOG_CONTENT" | grep -qi "ENOSPC\|no space"; then ERROR_CLASS="DISK_FULL"
    elif echo "$CRASH_LOG_CONTENT" | grep -qi "SyntaxError\|TypeError\|ReferenceError"; then ERROR_CLASS="CODE_ERROR"
    elif echo "$CRASH_LOG_CONTENT" | grep -qi "ECONNREFUSED\|fetch failed"; then ERROR_CLASS="UPSTREAM_DOWN"
    fi
fi

# --- Output ---
if $JSON_MODE; then
    cat <<EOF
{
  "timestamp": "$(date -Iseconds)",
  "port": $PORT,
  "health_code": "$HEALTH_CODE",
  "process_alive": $PROCESS_ALIVE,
  "port_occupied": $PORT_OCCUPIED,
  "disk_usage_pct": ${DISK_USAGE:-0},
  "mem_avail_mb": ${MEM_AVAIL:-0},
  "crash_signal_exists": $CRASH_SIGNAL_EXISTS,
  "hermes_agent_available": $HERMES_AGENT_AVAILABLE,
  "hermes_cli_found": $HERMES_CLI_FOUND,
  "error_class": "$ERROR_CLASS",
  "latest_crash_log": "$LATEST_CRASH_LOG",
  "recommended_action": "$(case $ERROR_CLASS in
    PORT_CONFLICT) echo "kill_stale_process" ;;
    OOM) echo "clean_memory_and_restart" ;;
    MISSING_MODULE) echo "reinstall_deps" ;;
    PERMISSION) echo "fix_permissions" ;;
    DISK_FULL) echo "clean_disk_space" ;;
    CODE_ERROR) echo "rebuild_and_restart" ;;
    UPSTREAM_DOWN) echo "restart_upstream" ;;
    NONE) echo "check_health_only" ;;
    *) echo "manual_intervention_needed" ;;
  esac)"
}
EOF
else
    echo "=== Crash Diagnosis ==="
    echo "Time:          $(date)"
    echo "Port:          $PORT"
    echo "Health:        HTTP $HEALTH_CODE"
    echo "Process alive: $PROCESS_ALIVE"
    echo "Port occupied: $PORT_OCCUPIED"
    echo "Disk usage:    ${DISK_USAGE:-?}%"
    echo "Memory free:   ${MEM_AVAIL:-?} MB"
    echo "Crash signal:  $CRASH_SIGNAL_EXISTS"
    echo "Error class:   $ERROR_CLASS"
    echo "Hermes CLI:    $HERMES_CLI_FOUND"
    echo "Agent avail:   $HERMES_AGENT_AVAILABLE"
    echo ""
    if [[ -n "$LATEST_CRASH_LOG" ]]; then
        echo "Latest crash log: $LATEST_CRASH_LOG"
        echo ""
        echo "--- Last 20 lines ---"
        tail -20 "$LATEST_CRASH_LOG"
    else
        echo "No crash logs found"
    fi
fi