#!/usr/bin/env bash
#
# Install hermes-web-ui watchdog as a systemd service
#
# Usage: bash scripts/install-watchdog.sh [--port 8648]
#

set -euo pipefail

PORT="${1:-8648}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WATCHDOG_SCRIPT="$PROJECT_DIR/scripts/watchdog.sh"
SERVICE_FILE="$PROJECT_DIR/scripts/hermes-web-ui-watchdog.service"
INSTALL_DIR="$HOME/.hermes-web-ui"

echo "🔧 Installing Hermes Web UI Watchdog..."

# 1. Copy watchdog script to install dir
mkdir -p "$INSTALL_DIR/logs"
cp "$WATCHDOG_SCRIPT" "$INSTALL_DIR/watchdog.sh"
chmod +x "$INSTALL_DIR/watchdog.sh"

# 2. Create systemd service
SERVICE_PATH="$HOME/.config/systemd/user/hermes-web-ui-watchdog.service"
mkdir -p "$(dirname "$SERVICE_PATH")"
cp "$SERVICE_FILE" "$SERVICE_PATH"

# 3. Update port in service
sed -i "s/Environment=PORT=8648/Environment=PORT=$PORT/" "$SERVICE_PATH"

# 4. Reload and enable
systemctl --user daemon-reload
systemctl --user enable hermes-web-ui-watchdog
systemctl --user start hermes-web-ui-watchdog

echo ""
echo "✅ Watchdog installed and started!"
echo ""
echo "Status:  systemctl --user status hermes-web-ui-watchdog"
echo "Logs:    journalctl --user -u hermes-web-ui-watchdog -f"
echo "Stop:    systemctl --user stop hermes-web-ui-watchdog"
echo "Remove:  systemctl --user disable --now hermes-web-ui-watchdog"
echo ""
echo "Crash logs: $INSTALL_DIR/logs/"
echo "Protocol:   docs/CRASH-RECOVERY-PROTOCOL.md"
