#!/usr/bin/env bash
# Shared error classification for crash recovery
# Source this file to use classify_error() and is_oom_error()

classify_error() {
    local error_msg="$1"

    # OOM / Memory errors
    if echo "$error_msg" | grep -qiE "(OOM|out of memory|JavaScript heap|FATAL ERROR.*heap|allocation failed|Cannot allocate memory|v8::internal.*abort)" 2>/dev/null; then
        echo "OOM"
        return
    fi

    # Port conflicts
    if echo "$error_msg" | grep -qiE "(EADDRINUSE|address already in use|port.*in use)" 2>/dev/null; then
        echo "PORT_CONFLICT"
        return
    fi

    # Socket / connection errors
    if echo "$error_msg" | grep -qiE "(EACCES|permission denied|ECONNREFUSED|ECONNRESET|ETIMEDOUT|socket hang up)" 2>/dev/null; then
        echo "SOCKET_ERROR"
        return
    fi

    # Node not found
    if echo "$error_msg" | grep -qiE "(node: command not found|NODE_NOT_FOUND)" 2>/dev/null; then
        echo "NODE_MISSING"
        return
    fi

    # Module not found
    if echo "$error_msg" | grep -qiE "(MODULE_NOT_FOUND|Cannot find module|ERR_MODULE_NOT_FOUND)" 2>/dev/null; then
        echo "MISSING_MODULE"
        return
    fi

    # SIGTERM / SIGKILL
    if echo "$error_msg" | grep -qiE "(SIGTERM|SIGKILL|signal.*term|graceful.*stop)" 2>/dev/null; then
        echo "SIGTERM"
        return
    fi

    # Config / parse errors
    if echo "$error_msg" | grep -qiE "(Unexpected token|SyntaxError|YAMLParseError|YAMLException|Config.*error|TypeError|ReferenceError)" 2>/dev/null; then
        echo "CONFIG_ERROR"
        return
    fi

    # Database errors
    if echo "$error_msg" | grep -qiE "(SQLITE.*error|database.*corrupt|database.*lock|disk I/O error)" 2>/dev/null; then
        echo "DB_ERROR"
        return
    fi

    # Permission errors (directory)
    if echo "$error_msg" | grep -qiE "(EPERM|mkdir.*EACCES)" 2>/dev/null; then
        echo "PERMISSION_ERROR"
        return
    fi

    # SSL / certificate errors
    if echo "$error_msg" | grep -qiE "(SSL|certificate|CERT_|UNABLE_TO_VERIFY)" 2>/dev/null; then
        echo "SSL_ERROR"
        return
    fi

    # EOF / premature close
    if echo "$error_msg" | grep -qiE "(PREMATURE_CLOSE|ERR_STREAM_PREMATURE_CLOSE|unexpected end)" 2>/dev/null; then
        echo "EOF_ERROR"
        return
    fi

    echo "UNKNOWN"
}

is_oom_error() {
    local error_msg="$1"
    echo "$error_msg" | grep -qiE "(OOM|out of memory|JavaScript heap|FATAL ERROR.*heap|allocation failed|Cannot allocate memory)" 2>/dev/null
    return $?
}

# Cross-platform port check (works on Linux and macOS)
port_in_use() {
    local port="$1"
    if command -v lsof >/dev/null 2>&1; then
        lsof -i :"$port" -sTCP:LISTEN -t >/dev/null 2>&1
    elif command -v ss >/dev/null 2>&1; then
        ss -tlnp 2>/dev/null | grep -q ":${port} "
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | grep -q ":${port} "
    else
        return 1
    fi
}

# Cross-platform safe sed (handles macOS vs Linux differences)
safe_sed_inplace() {
    local old="$1"
    local new="$2"
    local file="$3"
    if sed --version >/dev/null 2>&1; then
        sed -i "s|${old}|${new}|g" "$file"
    else
        sed -i '' "s|${old}|${new}|g" "$file"
    fi
}

# Read a value from key=value state file (safe replacement for source)
read_state_value() {
    local file="$1"
    local key="$2"
    local default="${3:-}"
    if [ -f "$file" ]; then
        local val
        val=$(grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d'=' -f2-)
        if [ -n "$val" ]; then
            echo "$val"
            return
        fi
    fi
    echo "$default"
}

# Detect if running on Linux (vs macOS/BSD)
is_linux() {
    [ "$(uname -s)" = "Linux" ]
}
