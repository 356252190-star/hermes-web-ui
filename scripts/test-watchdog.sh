#!/usr/bin/env bash
# ============================================================================
# Test suite for crash recovery scripts
# Usage: bash test-watchdog.sh
# ============================================================================

set -uo pipefail
# Note: not using -e because grep returning 1 (no match) would exit the script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
TOTAL=0

# Colors
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
NC="\033[0m"

assert_eq() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}PASS${NC} $test_name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} $test_name"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$actual" | grep -q "$expected" 2>/dev/null; then
        echo -e "  ${GREEN}PASS${NC} $test_name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} $test_name"
        echo "    expected to contain: $expected"
        echo "    actual: $actual"
        FAIL=$((FAIL + 1))
    fi
}

# ── Source shared library ──────────────────────────────────────────────────
source "$SCRIPT_DIR/error-classify.sh"

echo "=========================================="
echo "  Crash Recovery Test Suite"
echo "=========================================="
echo ""

# ── Test: Error Classification ─────────────────────────────────────────────
echo "--- Error Classification ---"

assert_eq "OOM heap"     "OOM"     "$(classify_error "FATAL ERROR: CALL_AND_RETRY_LAST Allocation failed - JavaScript heap out of memory")"

assert_eq "OOM allocation"     "OOM"     "$(classify_error "Cannot allocate memory")"

assert_eq "OOM v8 abort"     "OOM"     "$(classify_error "v8::internal::Abort")"

assert_eq "Port conflict"     "PORT_CONFLICT"     "$(classify_error "Error: listen EADDRINUSE: address already in use :::8648")"

assert_eq "Port in use"     "PORT_CONFLICT"     "$(classify_error "port 8648 is already in use")"

assert_eq "Node not found"     "NODE_MISSING"     "$(classify_error "node: command not found")"

assert_eq "Module not found"     "MISSING_MODULE"     "$(classify_error "Error: Cannot find module @hermes-web-ui/server")"

assert_eq "SIGTERM"     "SIGTERM"     "$(classify_error "Process terminated with SIGTERM")"

assert_eq "Config error"     "CONFIG_ERROR"     "$(classify_error "SyntaxError: Unexpected token")"

assert_eq "YAML error"     "CONFIG_ERROR"     "$(classify_error "YAMLParseError: bad indentation")"

assert_eq "Database error"     "DB_ERROR"     "$(classify_error "SQLITE_ERROR: database disk image is malformed")"

assert_eq "Permission error"     "PERMISSION_ERROR"     "$(classify_error "EPERM: operation not permitted, mkdir")"

assert_eq "SSL error"     "SSL_ERROR"     "$(classify_error "UNABLE_TO_VERIFY_LEAF_SIGNATURE")"

assert_eq "EOF error"     "EOF_ERROR"     "$(classify_error "ERR_STREAM_PREMATURE_CLOSE")"

assert_eq "SIGKILL"     "SIGTERM"     "$(classify_error "Process killed with SIGKILL")"

assert_eq "Memory (alt)"     "OOM"     "$(classify_error "out of memory")"

assert_eq "Unknown error"     "UNKNOWN"     "$(classify_error "something completely random xyz123")"

echo ""

# ── Test: OOM detection ────────────────────────────────────────────────────
echo "--- OOM Detection ---"

assert_eq "OOM heap text" "0"     "$(is_oom_error "JavaScript heap out of memory"; echo $?)"

assert_eq "OOM FATAL" "0"     "$(is_oom_error "FATAL ERROR: allocation failed"; echo $?)"

assert_eq "OOM Cannot allocate" "0"     "$(is_oom_error "Cannot allocate memory"; echo $?)"

assert_eq "Non-OOM error" "1"     "$(is_oom_error "EADDRINUSE port in use"; echo $?)"

echo ""

# ── Test: Port check ───────────────────────────────────────────────────────
echo "--- Port Check ---"

# Port 1 should not be in use
assert_eq "Port 1 not in use" "1"     "$(port_in_use 1; echo $?)"

# Check any listening port (port 18789 should be running on this machine)
test_port=""
for p in 18789 8648 3000 8080; do
    if port_in_use "$p" 2>/dev/null; then
        test_port="$p"
        break
    fi
done
if [ -n "$test_port" ]; then
    assert_eq "Port $test_port detected as in use" "0" "$(port_in_use $test_port; echo $?)"
else
    echo -e "  ${YELLOW}SKIP${NC} No known ports listening to test"
fi

echo ""

# ── Test: State file operations ────────────────────────────────────────────
echo "--- State File Operations ---"

TEST_STATE="/tmp/test-watchdog-state-$$"
cat > "$TEST_STATE" <<'EOF'
CONSECUTIVE_FAILURES=0
LAST_FAILURE_TIME=0
DAILY_FAILURES=0
DAILY_FAILURE_DATE=2026-04-26
MAINTENANCE_MODE=0
EOF

assert_eq "Read CONSECUTIVE_FAILURES" "0"     "$(read_state_value "$TEST_STATE" "CONSECUTIVE_FAILURES" "999")"

assert_eq "Read DAILY_FAILURE_DATE" "2026-04-26"     "$(read_state_value "$TEST_STATE" "DAILY_FAILURE_DATE" "never")"

assert_eq "Read missing key returns default" "fallback"     "$(read_state_value "$TEST_STATE" "NONEXISTENT_KEY" "fallback")"

assert_eq "Read missing key no default" ""     "$(read_state_value "$TEST_STATE" "NONEXISTENT_KEY")"

rm -f "$TEST_STATE"

echo ""

# ── Test: Cross-platform functions ─────────────────────────────────────────
echo "--- Cross-platform Functions ---"

assert_eq "is_linux runs" "0"     "$(is_linux; echo $?)"

assert_eq "port_in_use function exists" "0"     "$(declare -f port_in_use >/dev/null; echo $?)"

assert_eq "safe_sed_inplace function exists" "0"     "$(declare -f safe_sed_inplace >/dev/null; echo $?)"

assert_eq "read_state_value function exists" "0"     "$(declare -f read_state_value >/dev/null; echo $?)"

echo ""

# ── Test: Script syntax ────────────────────────────────────────────────────
echo "--- Script Syntax ---"

# Test watchdog.sh has no syntax errors
assert_eq "watchdog.sh syntax" "0"     "$(bash -n "$SCRIPT_DIR/watchdog.sh" 2>&1; echo $?)"

# Test crash-diagnose.sh has no syntax errors
assert_eq "crash-diagnose.sh syntax" "0"     "$(bash -n "$SCRIPT_DIR/crash-diagnose.sh" 2>&1; echo $?)"

# Test error-classify.sh has no syntax errors
assert_eq "error-classify.sh syntax" "0"     "$(bash -n "$SCRIPT_DIR/error-classify.sh" 2>&1; echo $?)"

echo ""

# ── Test: No eval usage ───────────────────────────────────────────────────
echo "--- Security Checks ---"
# Check for actual eval invocations (not comments mentioning "no eval")
eval_invocations=$(grep -v '^\s*#' "$SCRIPT_DIR/watchdog.sh" | grep 'eval' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "watchdog.sh no eval invocations" "0" "$eval_invocations" 

# Check no actual 'source "$STATE_FILE"' (only 'source error-classify.sh' is OK)
source_invocations=$(grep -v '^\s*#' "$SCRIPT_DIR/watchdog.sh" | grep 'source.*STATE_FILE' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "watchdog.sh no source STATE_FILE" "0" "$source_invocations" 

echo ""

# ── Test: All locale files have copyBubble key ─────────────────────────────
echo "--- i18n Completeness ---"

LOCALE_DIR="$HOME/hermes-web-ui-dev/packages/client/src/locales"
if [ -d "$LOCALE_DIR" ]; then
    for locale_file in "$LOCALE_DIR"/*.ts; do
        locale_name=$(basename "$locale_file" .ts)
        if grep -q "copyBubble" "$locale_file" 2>/dev/null; then
            assert_eq "$locale_name has copyBubble" "0" "0"
        else
            assert_eq "$locale_name has copyBubble" "0" "1"
        fi
    done
else
    echo -e "  ${YELLOW}SKIP${NC} Locale directory not found"
fi

echo ""

# ── Summary ────────────────────────────────────────────────────────────────
echo "=========================================="
echo "  Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "=========================================="

if [ $FAIL -gt 0 ]; then
    exit 1
fi
exit 0
