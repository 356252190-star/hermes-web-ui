#!/usr/bin/env bash
# ============================================================================
# Install hermes-web-ui watchdog as a systemd service (Linux) or launchd agent (macOS)
# Usage: sudo bash install-watchdog.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM="$(uname -s)"

echo "=========================================="
echo "  Installing hermes-web-ui Watchdog"
echo "  Platform: $PLATFORM"
echo "=========================================="
echo ""

# Make scripts executable
chmod +x "$SCRIPT_DIR/watchdog.sh"
chmod +x "$SCRIPT_DIR/crash-diagnose.sh"
chmod +x "$SCRIPT_DIR/error-classify.sh"

# Verify required files exist
for f in watchdog.sh crash-diagnose.sh error-classify.sh; do
    if [ ! -f "$SCRIPT_DIR/$f" ]; then
        echo "ERROR: $f not found in $SCRIPT_DIR"
        exit 1
    fi
done

case "$PLATFORM" in
    Linux)
        if ! command -v systemctl >/dev/null 2>&1; then
            echo "ERROR: systemctl not found. Install systemd or run watchdog manually:"
            echo "  bash $SCRIPT_DIR/watchdog.sh"
            exit 1
        fi

        # Install systemd service
        SERVICE_FILE="/etc/systemd/system/hermes-web-ui-watchdog.service"
        cp "$SCRIPT_DIR/hermes-web-ui-watchdog.service" "$SERVICE_FILE"

        # Reload and enable
        systemctl daemon-reload
        systemctl enable hermes-web-ui-watchdog
        systemctl start hermes-web-ui-watchdog

        echo "Installed and started systemd service"
        echo "  Status:  systemctl status hermes-web-ui-watchdog"
        echo "  Logs:    journalctl -u hermes-web-ui-watchdog -f"
        echo "  Stop:    systemctl stop hermes-web-ui-watchdog"
        ;;

    Darwin)
        PLIST_PATH="$HOME/Library/LaunchAgents/com.hermes.web-ui-watchdog.plist"
        cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.hermes.web-ui-watchdog</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/watchdog.sh</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/.hermes-web-ui/logs/watchdog-launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.hermes-web-ui/logs/watchdog-launchd.log</string>
</dict>
</plist>
PLIST

        launchctl load "$PLIST_PATH"
        echo "Installed and loaded launchd agent"
        echo "  Status:  launchctl list | grep hermes"
        echo "  Logs:    tail -f ~/.hermes-web-ui/logs/watchdog-launchd.log"
        echo "  Stop:    launchctl unload $PLIST_PATH"
        ;;

    *)
        echo "Unsupported platform: $PLATFORM"
        echo "Run watchdog manually: bash $SCRIPT_DIR/watchdog.sh"
        exit 1
        ;;
esac

echo ""
echo "Done! Watchdog is now running."
echo ""
echo "Commands:"
echo "  Status:           bash $SCRIPT_DIR/watchdog.sh status"
echo "  Maintenance mode: bash $SCRIPT_DIR/watchdog.sh maintenance-on"
echo "  Resume:           bash $SCRIPT_DIR/watchdog.sh maintenance-off"
echo "  Diagnostics:      bash $SCRIPT_DIR/crash-diagnose.sh"
echo "  Tests:            bash $SCRIPT_DIR/test-watchdog.sh"
