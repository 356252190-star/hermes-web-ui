#!/usr/bin/env bash
# ============================================================================
# hermes-web-ui Watchdog v2.0 — Cross-platform crash recovery
# ============================================================================
# Requirements: bash 3.2+, curl, standard POSIX utils
# Compatibility: Linux (systemd/sysvinit), macOS (launchd/manual)
# ============================================================================

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH_URL="${HEALTH_URL:-http://localhost:8648/api/health}"
START_CMD="${START_CMD:-}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
MAX_RETRIES="${MAX_RETRIES:-3}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-300}"
MAX_DAILY_FAILURES="${MAX_DAILY_FAILURES:-30}"
STATE_DIR="${STATE_DIR:-$HOME/.hermes-web-ui}"
STATE_FILE="$STATE_DIR/watchdog.state"
LOG_DIR="${STATE_DIR}/logs"
WATCHDOG_LOG="${LOG_DIR}/watchdog-$(date +%Y%m%d).log"
LOCKFILE="/tmp/hermes-web-ui-watchdog.pid"

# ── Source shared library ──────────────────────────────────────────────────
if [ -f "$SCRIPT_DIR/error-classify.sh" ]; then
    source "$SCRIPT_DIR/error-classify.sh"
else
    echo "FATAL: error-classify.sh not found in $SCRIPT_DIR" >&2
    exit 1
fi

# ── Auto-detect start command ──────────────────────────────────────────────
detect_start_cmd() {
    if [ -n "$START_CMD" ]; then
        return
    fi

    # Dev directory with package.json
    if [ -f "$HOME/hermes-web-ui-dev/package.json" ]; then
        local node_bin="$HOME/hermes-web-ui-dev/node_modules/.bin/tsx"
        if [ -f "$node_bin" ]; then
            START_CMD="node $HOME/hermes-web-ui-dev/node_modules/.bin/tsx $HOME/hermes-web-ui-dev/packages/server/src/index.ts"
            log_info "Detected dev installation at $HOME/hermes-web-ui-dev"
            return
        fi
    fi

    # Global npm installation
    if command -v hermes-web-ui >/dev/null 2>&1; then
        START_CMD="hermes-web-ui"
        log_info "Detected global npm installation"
        return
    fi

    # Global npx
    if command -v npx >/dev/null 2>&1; then
        START_CMD="npx hermes-web-ui"
        log_info "Detected npx installation"
        return
    fi

    log_error "No hermes-web-ui installation found. Set START_CMD environment variable."
    exit 1
}

# ── Logging ────────────────────────────────────────────────────────────────
setup_logging() {
    mkdir -p "$LOG_DIR"
}

log_info() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] INFO: $*" | tee -a "$WATCHDOG_LOG"
}

log_warn() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] WARN: $*" | tee -a "$WATCHDOG_LOG"
}

log_error() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] ERROR: $*" | tee -a "$WATCHDOG_LOG"
}

# ── State management (safe key=value parsing, no source) ───────────────────
save_state() {
    local key="$1"
    local value="$2"
    mkdir -p "$STATE_DIR"

    if [ -f "$STATE_FILE" ]; then
        if is_linux; then
            sed -i "s|^${key}=.*|${key}=${value}|" "$STATE_FILE"
        else
            # macOS sed requires empty string after -i
            local tmp="${STATE_FILE}.tmp"
            sed "s|^${key}=.*|${key}=${value}|" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
        fi
    fi

    # Key not found? Append it
    if ! grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
        echo "${key}=${value}" >> "$STATE_FILE"
    fi
}

init_state() {
    mkdir -p "$STATE_DIR"
    if [ ! -f "$STATE_FILE" ]; then
        cat > "$STATE_FILE" <<'EOF'
CONSECUTIVE_FAILURES=0
LAST_FAILURE_TIME=0
DAILY_FAILURES=0
DAILY_FAILURE_DATE=
MAINTENANCE_MODE=0
EOF
        log_info "Initialized state file at $STATE_FILE"
    fi
}

get_state() {
    read_state_value "$STATE_FILE" "$1" "$2"
}

# ── Process health check ──────────────────────────────────────────────────
is_webui_running() {
    curl -sf --connect-timeout 5 --max-time 10 "$HEALTH_URL" > /dev/null 2>&1
}

find_webui_pids() {
    if is_linux; then
        pgrep -f "hermes-web-ui|tsx.*server/src/index" 2>/dev/null || true
    else
        # macOS: use pgrep without -f (not supported on all versions)
        pgrep -fl "tsx|hermes-web-ui" 2>/dev/null | grep -v grep | awk '{print $1}' || true
    fi
}

kill_webui_gracefully() {
    local pids
    pids="$(find_webui_pids)"
    if [ -z "$pids" ]; then
        return
    fi

    log_info "Sending SIGTERM to PIDs: $pids"
    for pid in $pids; do
        kill -TERM "$pid" 2>/dev/null || true
    done

    # Wait up to 10s for graceful shutdown
    local waited=0
    while [ $waited -lt 10 ]; do
        local still_alive=false
        for pid in $pids; do
            if kill -0 "$pid" 2>/dev/null; then
                still_alive=true
                break
            fi
        done
        if [ "$still_alive" = false ]; then
            log_info "All processes terminated gracefully"
            return
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # Force kill remaining
    log_warn "Force killing remaining PIDs"
    for pid in $pids; do
        kill -9 "$pid" 2>/dev/null || true
    done
    sleep 1
}

wait_for_port_release() {
    local port
    port=$(echo "$HEALTH_URL" | grep -oE ':[0-9]+' | tr -d ':' || echo "8648")
    local waited=0
    while [ $waited -lt 10 ]; do
        if ! port_in_use "$port"; then
            return 0
        fi
        log_info "Port $port still in use, waiting... ($waited/10)"
        sleep 1
        waited=$((waited + 1))
    done
    log_warn "Port $port still in use after 10s"
    return 1
}

# ── RESTART_CMD validation (safe, no eval) ────────────────────────────────
validate_restart_cmd() {
    if [ -z "$START_CMD" ]; then
        log_error "START_CMD is empty, cannot restart"
        return 1
    fi
    # Only allow safe characters: alphanumeric, space, /, -, _, ., =, :, @
    if echo "$START_CMD" | grep -qE '^[a-zA-Z0-9/_.:@= -]+$'; then
        return 0
    else
        log_error "START_CMD contains unsafe characters: $START_CMD"
        return 1
    fi
}

# ── Core restart logic ─────────────────────────────────────────────────────
restart_webui() {
    local attempt="$1"

    if ! validate_restart_cmd; then
        log_error "Invalid start command, aborting restart"
        return 1
    fi

    log_info "Restart attempt $attempt/$MAX_RETRIES"

    # Kill existing processes
    kill_webui_gracefully

    # Wait for port release
    wait_for_port_release || true

    # Start new process in background using array (no eval)
    log_info "Starting: $START_CMD"
    # shellcheck disable=SC2086
    nohup $START_CMD >> "$LOG_DIR/webui-stdout.log" 2>&1 &
    local new_pid=$!
    log_info "Started with PID $new_pid"

    # Wait for health check to pass
    local waited=0
    while [ $waited -lt 30 ]; do
        if is_webui_running; then
            log_info "Health check passed after ${waited}s"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    log_error "Health check failed after 30s (PID $new_pid)"
    return 1
}

# ── Phase 1: Quick restart ────────────────────────────────────────────────
phase1_quick_restart() {
    log_info "=== Phase 1: Quick restart ==="
    local attempt=1
    while [ $attempt -le "$MAX_RETRIES" ]; do
        if restart_webui "$attempt"; then
            save_state "CONSECUTIVE_FAILURES" "0"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 5
    done
    log_warn "Phase 1: All $MAX_RETRIES attempts failed"
    return 1
}

# ── Phase 2: Automatic diagnosis and repair ───────────────────────────────
phase2_auto_repair() {
    log_info "=== Phase 2: Automatic diagnosis and repair ==="

    local error_log="$LOG_DIR/webui-stdout.log"
    local last_error=""
    if [ -f "$error_log" ]; then
        last_error=$(tail -100 "$error_log" 2>/dev/null || true)
    fi

    local error_type
    error_type=$(classify_error "$last_error")
    log_info "Error classification: $error_type"

    local repair_success=false

    case "$error_type" in
        OOM)
            log_info "Attempting OOM repair"
            # Free system memory (Linux only, skip gracefully on macOS)
            if is_linux && [ -f /proc/sys/vm/drop_caches ]; then
                if sudo -n true 2>/dev/null; then
                    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null 2>&1 || true
                else
                    log_warn "Cannot free system cache: sudo requires password"
                fi
            fi
            # Try restart with reduced memory
            export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=512}"
            if restart_webui "Phase2-oom"; then
                repair_success=true
            fi
            ;;

        PORT_CONFLICT)
            log_info "Attempting port conflict repair"
            local port
            port=$(echo "$HEALTH_URL" | grep -oE ':[0-9]+' | tr -d ':' || echo "8648")
            # Kill any process on the port (cross-platform)
            if command -v lsof >/dev/null 2>&1; then
                lsof -ti :"$port" 2>/dev/null | xargs kill -9 2>/dev/null || true
            elif command -v fuser >/dev/null 2>&1; then
                fuser -k "$port/tcp" 2>/dev/null || true
            fi
            sleep 2
            if restart_webui "Phase2-port"; then
                repair_success=true
            fi
            ;;

        NODE_MISSING)
            log_info "Attempting node recovery"
            # Check common node locations (cross-platform)
            local node_candidates=(
                "$HOME/.nvm/versions/node/*/bin/node"
                "/usr/local/bin/node"
                "/opt/homebrew/bin/node"
                "$HOME/.local/share/fnm/aliases/default/bin/node"
            )
            for pattern in "${node_candidates[@]}"; do
                # shellcheck disable=SC2086
                for node_path in $pattern; do
                    if [ -x "$node_path" ]; then
                        local node_dir
                        node_dir="$(dirname "$node_path")"
                        export PATH="$node_dir:$PATH"
                        log_info "Found node at $node_path, added to PATH"
                        if restart_webui "Phase2-node"; then
                            repair_success=true
                            break 2
                        fi
                    fi
                done
            done
            ;;

        MISSING_MODULE)
            log_info "Attempting module reinstall"
            if [ -f "$HOME/hermes-web-ui-dev/package.json" ]; then
                cd "$HOME/hermes-web-ui-dev"
                if command -v pnpm >/dev/null 2>&1; then
                    pnpm install --frozen-lockfile 2>&1 | tail -5 >> "$WATCHDOG_LOG"
                elif command -v npm >/dev/null 2>&1; then
                    npm install 2>&1 | tail -5 >> "$WATCHDOG_LOG"
                fi
                cd - >/dev/null
            fi
            if restart_webui "Phase2-module"; then
                repair_success=true
            fi
            ;;

        PERMISSION_ERROR)
            log_info "Attempting permission repair"
            if [ -d "$HOME/.hermes-web-ui" ]; then
                chmod -R u+rw "$HOME/.hermes-web-ui" 2>/dev/null || true
            fi
            mkdir -p "$HOME/.hermes-web-ui/state" "$HOME/.hermes-web-ui/upload" 2>/dev/null || true
            if restart_webui "Phase2-perm"; then
                repair_success=true
            fi
            ;;

        DB_ERROR)
            log_info "Attempting database repair"
            local db_files=("$HOME/.hermes-web-ui/state/"*.db)
            for db_file in "${db_files[@]}"; do
                if [ -f "$db_file" ] && command -v sqlite3 >/dev/null 2>&1; then
                    sqlite3 "$db_file" "PRAGMA integrity_check;" 2>/dev/null | grep -q "ok" || {
                        log_warn "Database corruption detected in $db_file"
                        # Backup corrupted DB
                        cp "$db_file" "${db_file}.corrupted.$(date +%s)" 2>/dev/null || true
                    }
                fi
            done
            if restart_webui "Phase2-db"; then
                repair_success=true
            fi
            ;;

        SSL_ERROR)
            log_info "SSL error detected — disabling SSL verification for npm"
            export NODE_TLS_REJECT_UNAUTHORIZED=0
            export npm_config_strict_ssl=false
            if restart_webui "Phase2-ssl"; then
                repair_success=true
            fi
            ;;

        *)
            log_info "Attempting generic restart for error type: $error_type"
            # Clear any stuck state
            rm -f /tmp/.hermes-web-ui-* 2>/dev/null || true
            if restart_webui "Phase2-generic"; then
                repair_success=true
            fi
            ;;
    esac

    if [ "$repair_success" = true ]; then
        log_info "Phase 2 repair successful ($error_type)"
        return 0
    fi

    log_warn "Phase 2 repair failed ($error_type)"
    return 1
}

# ── Phase 3: Agent-assisted repair ────────────────────────────────────────
detect_hermes_agent() {
    # Check local hermes command
    if command -v hermes >/dev/null 2>&1; then
        return 0
    fi
    # Check remote gateway via HTTP
    if curl -sf --connect-timeout 3 "http://localhost:18789/api/health" > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

try_start_hermes_agent() {
    # Try systemd (Linux)
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl start hermes-gateway 2>/dev/null; then
            sleep 5
            if curl -sf --connect-timeout 5 "http://localhost:18789/api/health" > /dev/null 2>&1; then
                return 0
            fi
        fi
    fi
    # Try launchd (macOS)
    if command -v launchctl >/dev/null 2>&1; then
        if launchctl start com.hermes.gateway 2>/dev/null; then
            sleep 5
            if curl -sf --connect-timeout 5 "http://localhost:18789/api/health" > /dev/null 2>&1; then
                return 0
            fi
        fi
    fi
    # Try direct startup
    if [ -f "$HOME/hermes-gateway/start.sh" ]; then
        nohup bash "$HOME/hermes-gateway/start.sh" >> "$LOG_DIR/hermes-agent-restart.log" 2>&1 &
        sleep 5
        if curl -sf --connect-timeout 5 "http://localhost:18789/api/health" > /dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

trigger_agent_repair() {
    log_info "=== Phase 3: Agent-assisted repair ==="

    # Detect or start hermes-agent
    if ! detect_hermes_agent; then
        log_warn "Hermes agent not available, attempting to start..."
        if ! try_start_hermes_agent; then
            log_error "Cannot start hermes agent"
            return 1
        fi
    fi

    # Collect crash context
    local error_log="$LOG_DIR/webui-stdout.log"
    local diagnose_output="$LOG_DIR/diagnose-output.txt"

    # Run diagnose script if available
    if [ -f "$SCRIPT_DIR/crash-diagnose.sh" ]; then
        bash "$SCRIPT_DIR/crash-diagnose.sh" > "$diagnose_output" 2>&1 || true
    fi

    # Build repair prompt
    local last_error=""
    if [ -f "$error_log" ]; then
        last_error=$(tail -200 "$error_log" 2>/dev/null || true)
    fi

    local error_type
    error_type=$(classify_error "$last_error")

    local prompt="CRASH RECOVERY REQUEST

Web-ui has crashed and automated restarts have failed.

Error type: $error_type
Phase 1: Quick restart failed ($MAX_RETRIES attempts)
Phase 2: Automated repair failed

Please diagnose and fix. Follow CRASH-RECOVERY-PROTOCOL.md.

Error log (last 200 lines):
$last_error

--- END CRASH RECOVERY ---"

    log_info "Calling hermes agent for repair..."

    # Try hermes CLI first
    if command -v hermes >/dev/null 2>&1; then
        if timeout 120 hermes chat --yolo -q "$prompt" > "$LOG_DIR/agent-repair-output.log" 2>&1; then
            log_info "Agent repair command sent via CLI"
        else
            log_warn "Agent CLI call failed or timed out"
        fi
    fi

    # Verify recovery
    sleep 10
    if is_webui_running; then
        log_info "Phase 3 successful — web-ui recovered after agent repair"
        return 0
    fi

    log_warn "Phase 3: Web-ui still down after agent repair"
    return 1
}

# ── Phase 4: Final diagnostic report ─────────────────────────────────────
phase4_final_report() {
    log_error "=== Phase 4: All recovery attempts exhausted ==="

    local report="$STATE_DIR/CRASH_REPORT-$(date +%Y%m%d_%H%M%S).md"
    local error_log="$LOG_DIR/webui-stdout.log"

    {
        echo "# Crash Report — $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "## Status: UNRECOVERED — manual intervention required"
        echo ""
        echo "## Recovery attempts"
        echo "- Phase 1: Quick restart — FAILED"
        echo "- Phase 2: Auto repair — FAILED"
        echo "- Phase 3: Agent repair — FAILED"
        echo ""
        echo "## Last error (tail -100)"
        echo '```'
        tail -100 "$error_log" 2>/dev/null || echo "(no error log found)"
        echo '```'
        echo ""
        echo "## Watchdog log (last 50 lines)"
        echo '```'
        tail -50 "$WATCHDOG_LOG" 2>/dev/null || echo "(no watchdog log)"
        echo '```'
    } > "$report"

    log_error "Crash report saved to: $report"
    log_error "Stopping watchdog — manual intervention required"
}

# ── Global circuit breaker ────────────────────────────────────────────────
check_circuit_breaker() {
    local today
    today="$(date +%Y-%m-%d)"
    local daily_date
    daily_date="$(get_state "DAILY_FAILURE_DATE" "")"

    # Reset daily counter on new day
    if [ "$daily_date" != "$today" ]; then
        save_state "DAILY_FAILURES" "0"
        save_state "DAILY_FAILURE_DATE" "$today"
    fi

    local daily_count
    daily_count="$(get_state "DAILY_FAILURES" "0")"

    if [ "$daily_count" -ge "$MAX_DAILY_FAILURES" ]; then
        log_error "CIRCUIT BREAKER: $daily_count failures today (max $MAX_DAILY_FAILURES). Stopping watchdog."
        return 1
    fi
    return 0
}

# ── Main loop ─────────────────────────────────────────────────────────────
main() {
    setup_logging
    detect_start_cmd
    init_state

    log_info "Watchdog v2.0 started"
    log_info "Health check: $HEALTH_URL"
    log_info "Check interval: ${CHECK_INTERVAL}s"
    log_info "Max retries per cycle: $MAX_RETRIES"
    log_info "Max daily failures: $MAX_DAILY_FAILURES"
    log_info "Platform: $(uname -s) $(uname -m)"

    # Write PID file
    echo $$ > "$LOCKFILE"

    while true; do
        # Check maintenance mode (skip monitoring during updates)
        if [ "$(get_state "MAINTENANCE_MODE" "0")" = "1" ]; then
            log_info "Maintenance mode active, skipping health check"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        if is_webui_running; then
            # All good — reset consecutive failures
            save_state "CONSECUTIVE_FAILURES" "0"
        else
            log_warn "Web-UI health check failed!"

            # Check circuit breaker
            if ! check_circuit_breaker; then
                phase4_final_report
                exit 1
            fi

            # Increment counters
            local failures
            failures="$(get_state "CONSECUTIVE_FAILURES" "0")"
            failures=$((failures + 1))
            save_state "CONSECUTIVE_FAILURES" "$failures"

            local daily
            daily="$(get_state "DAILY_FAILURES" "0")"
            daily=$((daily + 1))
            save_state "DAILY_FAILURES" "$daily"
            save_state "DAILY_FAILURE_DATE" "$(date +%Y-%m-%d)"

            log_info "Failure #$failures (daily: $daily/$MAX_DAILY_FAILURES)"

            # Phase 1: Quick restart (up to MAX_RETRIES)
            if [ "$failures" -le "$MAX_RETRIES" ]; then
                phase1_quick_restart
                sleep "$CHECK_INTERVAL"
                continue
            fi

            # Phase 2: Automatic diagnosis and repair
            if [ "$failures" -le $((MAX_RETRIES * 2)) ]; then
                phase2_auto_repair
                sleep "$CHECK_INTERVAL"
                continue
            fi

            # Phase 3: Agent-assisted repair
            if trigger_agent_repair; then
                save_state "CONSECUTIVE_FAILURES" "0"
                sleep "$CHECK_INTERVAL"
                continue
            fi

            # Phase 4: Final report
            phase4_final_report
            exit 1
        fi

        sleep "$CHECK_INTERVAL"
    done
}

# ── Maintenance mode commands ─────────────────────────────────────────────
case "${1:-run}" in
    run)
        main
        ;;
    status)
        echo "=== Watchdog Status ==="
        echo "Consecutive failures: $(get_state CONSECUTIVE_FAILURES 0)"
        echo "Daily failures: $(get_state DAILY_FAILURES 0)"
        echo "Maintenance mode: $(get_state MAINTENANCE_MODE 0)"
        echo "Web-UI running: $(is_webui_running && echo 'yes' || echo 'no')"
        ;;
    maintenance-on)
        init_state
        save_state "MAINTENANCE_MODE" "1"
        echo "Maintenance mode ON — watchdog will skip health checks"
        ;;
    maintenance-off)
        init_state
        save_state "MAINTENANCE_MODE" "0"
        echo "Maintenance mode OFF — watchdog will resume health checks"
        ;;
    *)
        echo "Usage: $0 {run|status|maintenance-on|maintenance-off}"
        exit 1
        ;;
esac
