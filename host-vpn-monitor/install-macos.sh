#!/bin/bash
# Run this once to install the VPN monitor as a macOS LaunchAgent.
# Usage: bash install-macos.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing cu-agent VPN monitor..."

# 1. Script
sudo cp "$SCRIPT_DIR/cu-agent-vpn-monitor.sh" /usr/local/bin/cu-agent-vpn-monitor.sh
sudo chmod +x /usr/local/bin/cu-agent-vpn-monitor.sh

# 2. Log dir
sudo mkdir -p /usr/local/var/log

# 3. LaunchAgent (runs as current user, not root)
cp "$SCRIPT_DIR/com.cu-agent.vpn-monitor.plist" ~/Library/LaunchAgents/com.cu-agent.vpn-monitor.plist

# 4. Load it (starts immediately, survives reboots)
launchctl unload ~/Library/LaunchAgents/com.cu-agent.vpn-monitor.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.cu-agent.vpn-monitor.plist

echo ""
echo "Done! Monitor is running."
echo "Logs: tail -f /usr/local/var/log/cu-agent-vpn-monitor.log"
echo ""
echo "To stop:    launchctl unload ~/Library/LaunchAgents/com.cu-agent.vpn-monitor.plist"
echo "To restart: launchctl unload ~/Library/LaunchAgents/com.cu-agent.vpn-monitor.plist && launchctl load ~/Library/LaunchAgents/com.cu-agent.vpn-monitor.plist"
