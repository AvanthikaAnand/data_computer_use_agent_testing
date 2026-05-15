#!/bin/bash
# Keeps the openvpn (v2) tunnel alive.
#
# Every CHECK_INTERVAL seconds:
#   - Checks if the tun0 interface is up
#   - If connected: hits KEEPALIVE_URL, writes "connected" to VPN_STATUS_FILE
#   - If disconnected: attempts restart, writes "disconnected"
#
# Connect manually from VNC terminal:
#   sudo openvpn --config /vpn/your.ovpn --daemon --log /tmp/openvpn.log

KEEPALIVE_URL="${VPN_KEEPALIVE_URL:-}"
CHECK_INTERVAL="${VPN_CHECK_INTERVAL:-300}"
VPN_STATUS_FILE="${VPN_STATUS_FILE:-/tmp/vpn_status}"
VPN_CONFIG="${VPN_CONFIG_PATH:-}"
VPN_LOG="/tmp/openvpn.log"
VPN_PID="/tmp/openvpn.pid"

if [ -z "$KEEPALIVE_URL" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): VPN_KEEPALIVE_URL not set — keepalive disabled"
    exit 0
fi

echo "$(date '+%Y-%m-%d %H:%M:%S'): VPN keepalive started (interval=${CHECK_INTERVAL}s)"

_is_up() { ip link show tun0 2>/dev/null | grep -q "tun0"; }

_start_vpn() {
    [ -z "$VPN_CONFIG" ] || [ ! -f "$VPN_CONFIG" ] && return 1
    echo "$(date '+%Y-%m-%d %H:%M:%S'): Starting VPN..."
    [ -f "$VPN_PID" ] && sudo kill "$(cat "$VPN_PID")" 2>/dev/null; sleep 1
    sudo openvpn --config "$VPN_CONFIG" --daemon \
        --log "$VPN_LOG" --writepid "$VPN_PID" --script-security 2
    sleep 5
}

while true; do
    if _is_up; then
        echo "connected" > "$VPN_STATUS_FILE"
        curl -sf "$KEEPALIVE_URL" > /dev/null 2>&1 || true
        echo "$(date '+%Y-%m-%d %H:%M:%S'): VPN connected — keepalive sent"
    else
        echo "disconnected" > "$VPN_STATUS_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S'): VPN not active — attempting restart"
        _start_vpn || echo "$(date '+%Y-%m-%d %H:%M:%S'): Restart failed — reconnect manually"
    fi
    sleep "$CHECK_INTERVAL"
done
