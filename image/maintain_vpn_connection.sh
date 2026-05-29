#!/bin/bash
# Container-side VPN reachability check.
# The VPN itself is managed at the HOST level (not inside containers).
# This script only checks whether VPN-protected resources are reachable
# and writes a status file that the agent can consult before starting tasks.
#
# Config via environment (passed through /etc/agent.env):
#   VPN_KEEPALIVE_URL   URL to ping to verify VPN connectivity (e.g. internal site)
#   VPN_CHECK_INTERVAL  Seconds between checks (default: 300)
#   VPN_STATUS_FILE     Status file path (default: /tmp/vpn_status)

KEEPALIVE_URL="${VPN_KEEPALIVE_URL:-}"
CHECK_INTERVAL="${VPN_CHECK_INTERVAL:-300}"
VPN_STATUS_FILE="${VPN_STATUS_FILE:-/tmp/vpn_status}"
AGENT_ID="${AGENT_ID:-?}"

while true; do
    if [ -z "$KEEPALIVE_URL" ]; then
        echo "unknown" > "$VPN_STATUS_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S'): VPN_KEEPALIVE_URL not set — skipping check"
    elif curl -sf --max-time 10 "$KEEPALIVE_URL" > /dev/null 2>&1; then
        echo "reachable" > "$VPN_STATUS_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S'): VPN reachable (agent $AGENT_ID)"
    else
        echo "unreachable" > "$VPN_STATUS_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S'): WARNING — VPN-protected resource unreachable (agent $AGENT_ID)"
    fi

    sleep "$CHECK_INTERVAL"
done
