#!/usr/bin/env bash
# =============================================================================
# hermes-web-ui watchdog installer — Linux (systemd) + macOS (launchd)
# Usage: bash scripts/install-watchdog.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

OS="$(uname -s)"
case "$OS" in
    Linux*)  PLATFORM="linux";;
    Darwin*) PLATFORM="macos";;
    *)       echo "Unsupported: $OS"; exit 1;;
esac

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

TARGET_USER="${SUDO_USER:-$(whoami)}"
TARGET_HOME=$(eval echo "~$TARGET_USER")
DATA_DIR="$TARGET_HOME/.hermes-web-ui"

info "Installing hermes-web-ui watchdog"
info "  Platform: $PLATFORM"
info "  User: $TARGET_USER"
info "  Data dir: $DATA_DIR"

[[ -f "$SCRIPT_DIR/watchdog.sh" ]] || error "watchdog.sh not found"

mkdir -p "$DATA_DIR/crash-logs"
chown -R "$TARGET_USER:$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")" "$DATA_DIR" 2>/dev/null || true
chmod +x "$SCRIPT_DIR/watchdog.sh"

# =============================================================================
# Linux: systemd
# =============================================================================
install_systemd() {
    local SERVICE_NAME="hermes-web-ui-watchdog"
    local SYSTEMD_DIR="/etc/systemd/system"
    [[ $EUID -eq 0 ]] || error "Run as root: sudo bash scripts/install-watchdog.sh"

    cat > "/tmp/$SERVICE_NAME.service" <<EOF
[Unit]
Description=hermes-web-ui watchdog
After=network.target
Wants=network.target

[Service]
Type=simple
User=$TARGET_USER
Group=$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")
ExecStart=/bin/bash $SCRIPT_DIR/watchdog.sh
Restart=always
RestartSec=10
Environment=HEALTH_URL=http://127.0.0.1:8648/health
Environment=CHECK_INTERVAL=30
Environment=MAX_RETRIES=3
Environment=HERMES_WEB_UI_DATA=$DATA_DIR
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hermes-web-ui-watchdog
NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=$DATA_DIR $TARGET_HOME/.npm-global $PROJECT_DIR

[Install]
WantedBy=multi-user.target
EOF

    cp "/tmp/$SERVICE_NAME.service" "$SYSTEMD_DIR/$SERVICE_NAME.service"
    rm -f "/tmp/$SERVICE_NAME.service"

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME" 2>/dev/null || systemctl start "$SERVICE_NAME"

    sleep 2
    systemctl is-active --quiet "$SERVICE_NAME" && info "✅ Watchdog installed and running" || warn "Check: journalctl -u $SERVICE_NAME -n 50"

    echo ""
    echo "========================================="
    echo "  hermes-web-ui watchdog (systemd)"
    echo "========================================="
    echo "  Status:    systemctl status $SERVICE_NAME"
    echo "  Logs:      journalctl -u $SERVICE_NAME -f"
    echo "  Stop:      systemctl stop $SERVICE_NAME"
    echo "  Disable:   systemctl disable $SERVICE_NAME"
}

# =============================================================================
# macOS: launchd
# =============================================================================
install_launchd() {
    local PLIST_NAME="com.hermes-web-ui.watchdog"
    local PLIST_DIR="$TARGET_HOME/Library/LaunchAgents"
    local PLIST_FILE="$PLIST_DIR/$PLIST_NAME.plist"

    mkdir -p "$PLIST_DIR"
    [[ -f "$PLIST_FILE" ]] && launchctl unload "$PLIST_FILE" 2>/dev/null || true

    cat > "$PLIST_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$PLIST_NAME</string>
    <key>ProgramArguments</key>
    <array><string>/bin/bash</string><string>$SCRIPT_DIR/watchdog.sh</string></array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HEALTH_URL</key><string>http://127.0.0.1:8648/health</string>
        <key>CHECK_INTERVAL</key><string>30</string>
        <key>MAX_RETRIES</key><string>3</string>
        <key>HERMES_WEB_UI_DATA</key><string>$DATA_DIR</string>
        <key>PATH</key><string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>$DATA_DIR/watchdog-stdout.log</string>
    <key>StandardErrorPath</key><string>$DATA_DIR/watchdog-stderr.log</string>
    <key>WorkingDirectory</key><string>$TARGET_HOME</string>
</dict>
</plist>
EOF

    launchctl load "$PLIST_FILE" 2>/dev/null || true
    launchctl start "$PLIST_NAME" 2>/dev/null || true

    sleep 2
    launchctl list | grep -q "$PLIST_NAME" && info "✅ Watchdog installed and running" || warn "Check: launchctl list | grep hermes"

    echo ""
    echo "========================================="
    echo "  hermes-web-ui watchdog (launchd)"
    echo "========================================="
    echo "  Status:    launchctl list | grep hermes"
    echo "  Logs:      cat $DATA_DIR/watchdog-stdout.log"
    echo "  Stop:      launchctl stop $PLIST_NAME"
    echo "  Unload:    launchctl unload $PLIST_FILE"
}

# =============================================================================
case "$PLATFORM" in
    linux) install_systemd ;;
    macos) install_launchd ;;
esac

echo "  Crash dir: $DATA_DIR/crash-logs/"
echo "  Signal:    $DATA_DIR/CRASH_SIGNAL"
echo "  Protocol:  $PROJECT_DIR/CRASH-RECOVERY-PROTOCOL.md"
echo ""
