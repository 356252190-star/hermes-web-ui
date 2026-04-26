#!/usr/bin/env bash
#
# hermes-web-ui watchdog — automatic crash recovery
#
# Monitors the web-ui process and auto-restarts on failure.
# Saves crash logs for agent-assisted diagnosis.
#
# Usage:
#   ./watchdog.sh [options]
#
# Options:
#   --port PORT        Web-UI port (default: 8648)
#   --interval SEC     Check interval in seconds (default: 30)
#   --max-retries N    Max consecutive restart attempts (default: 3)
#   --log-dir DIR      Log directory (default: ~/.hermes-web-ui/logs)
#   --restart-cmd CMD  Custom restart command
#

set -euo pipefail

# --- Defaults ---
PORT="${PORT:-8648}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
MAX_RETRIES="${MAX_RETRIES:-3}"
LOG_DIR="${LOG_DIR:-$HOME/.hermes-web-ui/logs}"
RESTART_CMD="${RESTART_CMD:-}"
HEALTH_URL="http://127.0.0.1:${PORT}/health"

# --- Parse CLI args ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --port) PORT="$2"; HEALTH_URL="http://127.0.0.1:${PORT}/health"; shift 2 ;;
        --interval) CHECK_INTERVAL="$2"; shift 2 ;;
        --max-retries) MAX_RETRIES="$2"; shift 2 ;;
        --log-dir) LOG_DIR="$2"; shift 2 ;;
        --restart-cmd) RESTART_CMD="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Setup ---
mkdir -p "$LOG_DIR"
CRASH_SIGNAL="$LOG_DIR/CRASH_SIGNAL"
CONSECUTIVE_FAILURES=0
LAST_CRASH_TIME=0
COOLDOWN_SECONDS=60

# --- Functions ---
timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
    echo "[$(timestamp)] [watchdog] $*"
}

check_process_alive() {
    # Check if any hermes-web-ui node process is running
    pgrep -f "hermes-web-ui.*dist/server" >/dev/null 2>&1
}

check_health() {
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$HEALTH_URL" 2>/dev/null || echo "000")
    [[ "$http_code" == "200" ]]
}

save_crash_log() {
    local reason="$1"
    local timestamp_str
    timestamp_str=$(date '+%Y-%m-%dT%H-%M-%S')
    local crash_log="$LOG_DIR/crash-${timestamp_str}.log"

    {
        echo "=== Crash Report ==="
        echo "Time: $(timestamp)"
        echo "Reason: $reason"
        echo ""
        echo "--- Process Status ---"
        ps aux | grep -E "hermes-web-ui|node.*8648" | grep -v grep || echo "(no process found)"
        echo ""
        echo "--- System Resources ---"
        free -h 2>/dev/null || echo "(free not available)"
        df -h / 2>/dev/null || echo "(df not available)"
        echo ""
        echo "--- Uptime ---"
        uptime
        echo ""
        echo "--- Recent Logs ---"
        # Capture last 50 lines from systemd journal if available
        journalctl -u hermes-web-ui --no-pager -n 50 2>/dev/null || echo "(no systemd logs)"
        echo ""
        echo "--- Port Status ---"
        lsof -i :"$PORT" 2>/dev/null || ss -tlnp | grep ":$PORT" || echo "(port not in use)"
    } > "$crash_log" 2>&1

    log "Crash log saved: $crash_log"
    echo "$crash_log"
}

restart_webui() {
    local attempt=$1
    log "Restart attempt $attempt/$MAX_RETRIES"

    if [[ -n "$RESTART_CMD" ]]; then
        log "Running custom restart command: $RESTART_CMD"
        eval "$RESTART_CMD" 2>&1 || true
    else
        # Try systemctl first
        if systemctl is-active hermes-web-ui-watchdog >/dev/null 2>&1; then
            systemctl restart hermes-web-ui-watchdog 2>&1 || true
        # Try npm global
        elif command -v hermes-web-ui >/dev/null 2>&1; then
            nohup hermes-web-ui --port "$PORT" > /dev/null 2>&1 &
        # Try local node
        elif [[ -f "dist/server/index.js" ]]; then
            nohup node dist/server/index.js > /dev/null 2>&1 &
        elif [[ -f "$HOME/.npm-global/lib/node_modules/hermes-web-ui/dist/server/index.js" ]]; then
            nohup node "$HOME/.npm-global/lib/node_modules/hermes-web-ui/dist/server/index.js" > /dev/null 2>&1 &
        else
            log "ERROR: No restart method available"
            return 1
        fi
    fi

    # Wait for startup
    local wait_count=0
    while [[ $wait_count -lt 15 ]]; do
        sleep 2
        wait_count=$((wait_count + 1))
        if check_health; then
            log "✅ Restart successful (healthy after ${wait_count}*2s)"
            return 0
        fi
    done

    log "❌ Restart failed — not healthy after 30s"
    return 1
}

clear_crash_signal() {
    rm -f "$CRASH_SIGNAL" 2>/dev/null
}

write_crash_signal() {
    local reason="$1"
    cat > "$CRASH_SIGNAL" <<EOF
CRASH_TIME=$(timestamp)
REASON=$reason
CONSECUTIVE_FAILURES=$CONSECUTIVE_FAILURES
STATUS=AGENT_REVIEW_NEEDED
EOF
    log "⚠️  CRASH_SIGNAL written — agent review needed"
}

# --- Main Loop ---
log "Watchdog started (port=$PORT, interval=${CHECK_INTERVAL}s, max_retries=$MAX_RETRIES)"

while true; do
    sleep "$CHECK_INTERVAL"

    # Check if process is alive
    if check_process_alive && check_health; then
        # Everything fine
        if [[ $CONSECUTIVE_FAILURES -gt 0 ]]; then
            log "✅ Service stable after $CONSECUTIVE_FAILURES recovery"
            CONSECUTIVE_FAILURES=0
            clear_crash_signal
        fi
        continue
    fi

    # Process is down or unhealthy
    log "⚠️  Service is down! (process_alive=$(check_process_alive), health=$(check_health 2>/dev/null && echo ok || echo fail))"

    # Save crash log
    save_crash_log "Process not responding (check=$(date +%s))" > /dev/null

    # Try to restart
    CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))

    if [[ $CONSECUTIVE_FAILURES -le $MAX_RETRIES ]]; then
        if restart_webui "$CONSECUTIVE_FAILURES"; then
            CONSECUTIVE_FAILURES=0
            clear_crash_signal
        fi
    else
        # Max retries exceeded — need agent intervention
        write_crash_signal "Max retries ($MAX_RETRIES) exceeded"
        log "🛑 Auto-recovery failed. Waiting for agent intervention."
        log "   Agent: read $CRASH_SIGNAL and follow docs/CRASH-RECOVERY-PROTOCOL.md"

        # Reset failure counter after cooldown
        sleep 300  # 5 minutes cooldown
        CONSECUTIVE_FAILURES=0
        clear_crash_signal
    fi
done
