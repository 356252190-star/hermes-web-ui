#!/usr/bin/env bash
# =============================================================================
# hermes-web-ui watchdog — Cross-platform (Linux + macOS)
# Health-checks every 30s, auto-restarts on failure (max 3 retries)
# =============================================================================

set -euo pipefail

# --- Configuration ---
APP_NAME="hermes-web-ui"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:8648/health}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
MAX_RETRIES="${MAX_RETRIES:-3}"
DATA_DIR="${HERMES_WEB_UI_DATA:-$HOME/.hermes-web-ui}"
CRASH_DIR="$DATA_DIR/crash-logs"
CRASH_SIGNAL="$DATA_DIR/CRASH_SIGNAL"
LOG_FILE="$DATA_DIR/watchdog.log"

# --- Platform Detection ---
OS="$(uname -s)"
case "$OS" in
    Linux*)  PLATFORM="linux";;
    Darwin*) PLATFORM="macos";;
    *)       PLATFORM="unknown";;
esac

# --- Helpers ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

ensure_dirs() { mkdir -p "$CRASH_DIR"; }

get_server_pid() {
    pgrep -f "hermes-web-ui.*server" 2>/dev/null || \
    pgrep -f "node.*hermes-web-ui" 2>/dev/null || echo ""
}

health_check() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$HEALTH_URL" 2>/dev/null || echo "000")
    [[ "$code" == "200" ]]
}

collect_system_state() {
    echo "=== SYSTEM STATE ==="
    echo "Platform: $PLATFORM"
    echo ""
    echo "--- Memory ---"
    if [[ "$PLATFORM" == "linux" ]]; then
        free -h 2>/dev/null || head -5 /proc/meminfo
    else
        vm_stat 2>/dev/null || echo "vm_stat not available"
    fi
    echo ""
    echo "--- Disk ---"
    df -h / 2>/dev/null || echo "df not available"
    echo ""
    echo "--- Load ---"
    uptime
    echo ""
    echo "--- Processes ---"
    if [[ "$PLATFORM" == "linux" ]]; then
        ps aux | grep -E "(hermes|node)" | grep -v grep || true
    else
        ps -eo pid,user,%cpu,%mem,command | grep -E "(hermes|node)" | grep -v grep || true
    fi
}

save_crash_log() {
    local crash_file="$CRASH_DIR/crash-$(date '+%Y%m%d-%H%M%S').log"
    {
        echo "=== CRASH REPORT ==="
        echo "Timestamp: $(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
        echo "Exit Code: $1"
        echo "Watchdog Retries: $consecutive_failures"
        echo ""
        collect_system_state
        echo ""
        echo "--- Server Log (last 100 lines) ---"
        tail -100 "$DATA_DIR/server.log" 2>/dev/null || echo "server.log not found"
    } > "$crash_file"
    log "Crash log saved: $crash_file"
}

write_crash_signal() {
    cat > "$CRASH_SIGNAL" <<EOF
CRASH_TIMESTAMP=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
CRASH_REASON=$1
WATCHDOG_PID=$$
APP_NAME=$APP_NAME
HEALTH_URL=$HEALTH_URL
CONSECUTIVE_FAILURES=$consecutive_failures
LAST_CRASH_LOG=$(ls -t "$CRASH_DIR"/*.log 2>/dev/null | head -1)
EOF
    log "CRASH_SIGNAL written: $1"
}

clear_crash_signal() { rm -f "$CRASH_SIGNAL"; }

start_server() {
    log "Starting $APP_NAME..."
    if [[ "$PLATFORM" == "linux" ]] && command -v systemctl &>/dev/null && systemctl is-enabled "$APP_NAME" &>/dev/null; then
        systemctl start "$APP_NAME"
    else
        local dir
        dir=$(npm root -g 2>/dev/null)/hermes-web-ui
        if [[ -d "$dir" ]]; then
            cd "$dir"
            node dist/server/index.js >> "$DATA_DIR/server.log" 2>&1 &
            log "Started via node (PID: $!)"
        else
            log "ERROR: Cannot find hermes-web-ui"
            return 1
        fi
    fi
}

stop_server() {
    log "Stopping $APP_NAME..."
    if [[ "$PLATFORM" == "linux" ]] && command -v systemctl &>/dev/null && systemctl is-active "$APP_NAME" &>/dev/null; then
        systemctl stop "$APP_NAME"
    else
        local pid
        pid=$(get_server_pid)
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
            sleep 2
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        fi
    fi
}

# --- Main ---
ensure_dirs
log "Watchdog starting (PID: $$)"
log "Platform: $PLATFORM | Health: $HEALTH_URL | Interval: ${CHECK_INTERVAL}s | Max retries: $MAX_RETRIES"

consecutive_failures=0
exit_code="unknown"
server_pid=""

while true; do
    if health_check; then
        if [[ $consecutive_failures -gt 0 ]]; then
            log "Health check recovered after $consecutive_failures failure(s)"
        fi
        consecutive_failures=0
        clear_crash_signal
    else
        consecutive_failures=$((consecutive_failures + 1))
        log "Health check failed ($consecutive_failures/$MAX_RETRIES)"

        if [[ $consecutive_failures -ge $MAX_RETRIES ]]; then
            log "Max retries reached — collecting crash data"
            exit_code="unknown"
            server_pid=$(get_server_pid)
            [[ -z "$server_pid" ]] && exit_code="process_not_found"
            save_crash_log "$exit_code"

            if [[ $consecutive_failures -eq $MAX_RETRIES ]]; then
                log "Attempting restart..."
                stop_server
                sleep 2
                if start_server; then
                    sleep 10
                    if health_check; then
                        log "Restart successful"
                        consecutive_failures=0
                        clear_crash_signal
                        continue
                    fi
                fi
            fi
            write_crash_signal "AUTO_RECOVERY_FAILED"
            log "Auto-recovery failed. Waiting for agent intervention."
            consecutive_failures=$((MAX_RETRIES + 1))
        fi
    fi
    sleep "$CHECK_INTERVAL"
done
