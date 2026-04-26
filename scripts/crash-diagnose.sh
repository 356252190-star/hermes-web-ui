#!/usr/bin/env bash
# ============================================================================
# hermes-web-ui Crash Diagnostics v2.0 — Cross-platform
# ============================================================================
# Usage:  ./crash-diagnose.sh [--json]
# Can be sourced by watchdog.sh or run independently.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_JSON=false

[ "${1:-}" = "--json" ] && OUTPUT_JSON=true

# Source shared library
if [ -f "$SCRIPT_DIR/error-classify.sh" ]; then
    source "$SCRIPT_DIR/error-classify.sh"
else
    echo "FATAL: error-classify.sh not found" >&2
    exit 1
fi

# ── Platform detection ─────────────────────────────────────────────────────
PLATFORM="$(uname -s)"
MACHINE="$(uname -m)"

# ── Configuration ──────────────────────────────────────────────────────────
WEBUI_PID=""
WEBUI_PORT=8648
INSTALL_DIR="$HOME/hermes-web-ui-dev"
STATE_DIR="$HOME/.hermes-web-ui"
LOG_DIR="$STATE_DIR/logs"

find_webui_pid() {
    WEBUI_PID=$(pgrep -f "hermes-web-ui|tsx.*server/src/index" 2>/dev/null | head -1 || echo "")
    if [ -z "$WEBUI_PID" ] && command -v lsof >/dev/null 2>&1; then
        WEBUI_PID=$(lsof -ti :"$WEBUI_PORT" 2>/dev/null | head -1 || echo "")
    fi
}

# ── Diagnostics ────────────────────────────────────────────────────────────
check_status() {
    echo "=== 1. Process Status ==="
    find_webui_pid
    if [ -n "$WEBUI_PID" ]; then
        echo "  PID: $WEBUI_PID (running)"
        if command -v ps >/dev/null 2>&1; then
            echo "  Uptime: $(ps -p "$WEBUI_PID" -o etime= 2>/dev/null | tr -d ' ' || echo 'unknown')"
            echo "  Memory: $(ps -p "$WEBUI_PID" -o rss= 2>/dev/null | awk '{printf "%.1f MB", $1/1024}' || echo 'unknown')"
        fi
    else
        echo "  Status: NOT RUNNING"
    fi
    echo ""
}

check_health() {
    echo "=== 2. Health Endpoint ==="
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://localhost:$WEBUI_PORT/api/health" 2>/dev/null || echo "000")
    echo "  HTTP: $http_code"
    if [ "$http_code" = "200" ]; then
        local body
        body=$(curl -s --connect-timeout 5 "http://localhost:$WEBUI_PORT/api/health" 2>/dev/null || echo "{}")
        local version
        version=$(echo "$body" | grep -oE '"version":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "unknown")
        echo "  Version: $version"
        echo "  Status: HEALTHY"
    else
        echo "  Status: UNHEALTHY"
    fi
    echo ""
}

check_port() {
    echo "=== 3. Port $WEBUI_PORT ==="
    if command -v lsof >/dev/null 2>&1; then
        local port_info
        port_info=$(lsof -i :"$WEBUI_PORT" -sTCP:LISTEN 2>/dev/null || true)
        if [ -n "$port_info" ]; then
            echo "  $port_info"
        else
            echo "  No process listening on port $WEBUI_PORT"
        fi
    elif command -v ss >/dev/null 2>&1; then
        ss -tlnp 2>/dev/null | grep ":${WEBUI_PORT} " || echo "  No process listening on port $WEBUI_PORT"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | grep ":${WEBUI_PORT} " || echo "  No process listening on port $WEBUI_PORT"
    else
        echo "  Cannot check port (no lsof/ss/netstat)"
    fi
    echo ""
}

check_recent_crashes() {
    echo "=== 4. Recent Crashes ==="
    local crash_dir="$STATE_DIR"
    local count=0
    for f in "$crash_dir"/CRASH_REPORT-*.md; do
        if [ -f "$f" ]; then
            count=$((count + 1))
            if [ $count -le 3 ]; then
                echo "  $(basename "$f") ($(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null || echo 'unknown'))"
            fi
        fi
    done
    if [ $count -eq 0 ]; then
        echo "  No crash reports found"
    elif [ $count -gt 3 ]; then
        echo "  ... and $((count - 3)) more"
    fi
    echo ""
}

check_system_resources() {
    echo "=== 5. System Resources ==="

    # Memory (cross-platform)
    if [ "$PLATFORM" = "Linux" ]; then
        echo "  Memory: $(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2 " used"}' || echo 'unknown')"
        echo "  Swap: $(free -h 2>/dev/null | awk '/^Swap:/ {print $3 "/" $2 " used"}' || echo 'unknown')"
    elif [ "$PLATFORM" = "Darwin" ]; then
        local total_mem
        total_mem=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.1f GB", $1/1024/1024/1024}' || echo 'unknown')
        echo "  Memory total: $total_mem"
        echo "  Memory pressure: $(memory_pressure 2>/dev/null | head -1 || echo 'run memory_pressure for details')"
    else
        echo "  Memory: unknown (platform: $PLATFORM)"
    fi

    # Disk
    echo "  Disk: $(df -h "$HOME" 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " used (" $5 ")"}' || echo 'unknown')"

    # OOM kills (Linux only)
    if [ "$PLATFORM" = "Linux" ] && command -v dmesg >/dev/null 2>&1; then
        local oom_count
        oom_count=$(dmesg 2>/dev/null | grep -c "Out of memory" || echo "0")
        echo "  OOM kills (kernel): $oom_count"
    fi
    echo ""
}

check_recent_errors() {
    echo "=== 6. Recent Errors ==="
    local error_log="$LOG_DIR/webui-stdout.log"
    if [ -f "$error_log" ]; then
        local errors
        errors=$(grep -iE "(error|fatal|crash|exception)" "$error_log" 2>/dev/null | tail -5 || true)
        if [ -n "$errors" ]; then
            echo "$errors" | while read -r line; do
                echo "  $line"
            done
        else
            echo "  No recent errors in log"
        fi
    else
        echo "  No error log found"
    fi
    echo ""
}

classify_last_error() {
    echo "=== 7. Error Classification ==="
    local error_log="$LOG_DIR/webui-stdout.log"
    local last_error=""
    if [ -f "$error_log" ]; then
        last_error=$(tail -100 "$error_log" 2>/dev/null || true)
    fi
    local error_type
    error_type=$(classify_error "$last_error")
    echo "  Type: $error_type"

    # Suggest fix
    case "$error_type" in
        OOM)             echo "  Suggestion: Increase --max-old-space-size or reduce load" ;;
        PORT_CONFLICT)   echo "  Suggestion: Kill process on port $WEBUI_PORT" ;;
        NODE_MISSING)    echo "  Suggestion: Install Node.js or fix PATH" ;;
        MISSING_MODULE)  echo "  Suggestion: Run pnpm install" ;;
        PERMISSION_ERROR) echo "  Suggestion: Fix permissions on $STATE_DIR" ;;
        DB_ERROR)        echo "  Suggestion: Check sqlite database integrity" ;;
        SSL_ERROR)       echo "  Suggestion: Set NODE_TLS_REJECT_UNAUTHORIZED=0" ;;
        SIGTERM)         echo "  Suggestion: Check who sent the signal" ;;
        CONFIG_ERROR)    echo "  Suggestion: Validate hermes-web-ui config" ;;
        *)               echo "  Suggestion: Manual investigation needed" ;;
    esac
    echo ""
}

check_hermes_agent() {
    echo "=== 8. Hermes Agent ==="
    if command -v hermes >/dev/null 2>&1; then
        echo "  hermes CLI: available"
    else
        echo "  hermes CLI: NOT FOUND"
    fi
    if curl -sf --connect-timeout 3 "http://localhost:18789/api/health" > /dev/null 2>&1; then
        echo "  Gateway: running (port 18789)"
    else
        echo "  Gateway: NOT RUNNING"
    fi
    echo ""
}

check_node_env() {
    echo "=== 9. Node.js Environment ==="
    if command -v node >/dev/null 2>&1; then
        echo "  Node: $(node --version 2>/dev/null || echo 'unknown')"
        echo "  npm: $(npm --version 2>/dev/null || echo 'unknown')"
        if command -v pnpm >/dev/null 2>&1; then
            echo "  pnpm: $(pnpm --version 2>/dev/null || echo 'unknown')"
        fi
    else
        echo "  Node.js: NOT FOUND"
    fi
    echo "  NODE_OPTIONS: ${NODE_OPTIONS:-<not set>}"
    echo "  UPLOAD_DIR: ${UPLOAD_DIR:-<not set>}"
    echo ""
}

# ── Output ─────────────────────────────────────────────────────────────────
if [ "$OUTPUT_JSON" = true ]; then
    # JSON output for programmatic consumption
    echo "{"
    find_webui_pid
    echo "  "pid": "$WEBUI_PID","
    echo "  "platform": "$PLATFORM","
    echo "  "machine": "$MACHINE","
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://localhost:$WEBUI_PORT/api/health" 2>/dev/null || echo "000")
    echo "  "health_http": "$http_code","
    local error_log="$LOG_DIR/webui-stdout.log"
    local last_error=""
    [ -f "$error_log" ] && last_error=$(tail -100 "$error_log" 2>/dev/null || true)
    local error_type
    error_type=$(classify_error "$last_error")
    echo "  "error_type": "$error_type","
    echo "  "hermes_cli": $(command -v hermes >/dev/null 2>&1 && echo 'true' || echo 'false'),"
    echo "  "gateway_running": $(curl -sf --connect-timeout 3 'http://localhost:18789/api/health' >/dev/null 2>&1 && echo 'true' || echo 'false')"
    echo "}"
else
    echo "=========================================="
    echo "  hermes-web-ui Crash Diagnostics v2.0"
    echo "  Platform: $PLATFORM ($MACHINE)"
    echo "  Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=========================================="
    echo ""
    check_status
    check_health
    check_port
    check_recent_crashes
    check_system_resources
    check_recent_errors
    classify_last_error
    check_hermes_agent
    check_node_env
fi
