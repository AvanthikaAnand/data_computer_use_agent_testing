#!/bin/bash
# Keeps the OpenVPN3 connection alive.
#
# Every CHECK_INTERVAL seconds:
#   - Checks whether the VPN session is still "Client connected"
#   - If connected: hits KEEPALIVE_URL to prevent idle timeout,
#     writes "connected" to VPN_STATUS_FILE (read by the agent API /health)
#   - If disconnected: writes "disconnected" and logs a warning
#     (cannot auto-reconnect due to 2FA — reconnect manually)
#
# To reconnect manually:
#   openvpn3 session-start --config <your-config>.ovpn

KEEPALIVE_URL="${VPN_KEEPALIVE_URL:-}"
CHECK_INTERVAL="${VPN_CHECK_INTERVAL:-300}"   # default: 5 minutes
VPN_STATUS_FILE="${VPN_STATUS_FILE:-/tmp/vpn_status}"

if [ -z "$KEEPALIVE_URL" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): VPN_KEEPALIVE_URL not set — VPN keepalive disabled"
    exit 0
fi

echo "$(date '+%Y-%m-%d %H:%M:%S'): VPN keepalive started (interval=${CHECK_INTERVAL}s, url=${KEEPALIVE_URL})"

while true; do
    VPN_STATUS=$(openvpn3 sessions-list 2>/dev/null)

    if echo "$VPN_STATUS" | grep -q "Client connected"; then
        echo "connected" > "$VPN_STATUS_FILE"
        curl -sf "$KEEPALIVE_URL" > /dev/null 2>&1
        echo "$(date '+%Y-%m-%d %H:%M:%S'): VPN connected — keepalive sent to ${KEEPALIVE_URL}"
    else
        echo "disconnected" > "$VPN_STATUS_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S'): WARNING — VPN session is not active. Reconnect manually:"
        echo "  openvpn3 session-start --config <your-config>.ovpn"
    fi

    sleep "$CHECK_INTERVAL"
done
