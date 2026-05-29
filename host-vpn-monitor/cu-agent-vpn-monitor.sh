#!/bin/bash
# macOS host-level VPN monitor for cu-agent.
#
# Checks VPN reachability every CHECK_INTERVAL seconds.
# During business hours (09:00–18:00 SGT / 01:00–10:00 UTC):
#   - When VPN drops: opens OpenVPN Connect (SAML prompt appears on screen)
#     and posts a Slack alert
#   - Nudges every 10 min while still disconnected
# Outside hours: single Slack alert on disconnect, no auto-open.

SLACK_TOKEN="${SLACK_BOT_TOKEN:-}"   # set via environment or .env file
SLACK_CHANNEL="C0B7FUXGHU0"
VPN_KEEPALIVE_URL="http://yp.internal.you.co/"
CHECK_INTERVAL=60
HOSTNAME_LABEL="$(scutil --get ComputerName 2>/dev/null || hostname)"

# ── Helpers ───────────────────────────────────────────────────────────────────

slack_notify() {
    curl -sf -X POST https://slack.com/api/chat.postMessage \
        -H "Authorization: Bearer $SLACK_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"channel\":\"$SLACK_CHANNEL\",\"text\":\"$1\"}" \
        > /dev/null 2>&1
}

within_business_hours() {
    local h; h=$(date -u +%H)
    [ "$h" -ge 1 ] && [ "$h" -lt 10 ]
}

vpn_reachable() {
    curl -sf --max-time 8 "$VPN_KEEPALIVE_URL" > /dev/null 2>&1
}

# ── Main loop ─────────────────────────────────────────────────────────────────
LAST_STATUS=""
DISCONNECTED_SINCE=0
echo "$(date '+%Y-%m-%d %H:%M:%S'): VPN monitor started on $HOSTNAME_LABEL"

while true; do
    TS=$(date '+%Y-%m-%d %H:%M:%S')

    if vpn_reachable; then
        CURRENT_STATUS="connected"
        DISCONNECTED_SINCE=0

        if [ "$LAST_STATUS" != "connected" ]; then
            echo "$TS: VPN reachable"
            slack_notify ":large_green_circle: *VPN connected* — \`$HOSTNAME_LABEL\` at $TS"
        else
            echo "$TS: VPN reachable — keepalive ok"
        fi

    else
        CURRENT_STATUS="disconnected"

        if within_business_hours; then
            # Open OpenVPN Connect once per disconnect event, then nudge every 10 min
            if [ "$LAST_STATUS" != "disconnected" ]; then
                DISCONNECTED_SINCE=$(date +%s)
                echo "$TS: VPN unreachable — opening OpenVPN Connect ..."
                open -a "OpenVPN Connect" 2>/dev/null || true
                slack_notify ":warning: *VPN disconnected* — \`$HOSTNAME_LABEL\` at $TS
OpenVPN Connect has been opened automatically. Complete the SAML login to reconnect."
            else
                # Nudge every 10 minutes while still down
                NOW=$(date +%s)
                SECS_DOWN=$(( NOW - DISCONNECTED_SINCE ))
                if [ $((SECS_DOWN % 600)) -lt "$CHECK_INTERVAL" ] && [ "$SECS_DOWN" -gt 60 ]; then
                    MINS_DOWN=$(( SECS_DOWN / 60 ))
                    echo "$TS: VPN still unreachable (${MINS_DOWN}m) — nudging"
                    slack_notify ":red_circle: *VPN still down* (${MINS_DOWN}m) — \`$HOSTNAME_LABEL\` at $TS
Please complete SAML login in OpenVPN Connect."
                fi
            fi
        else
            if [ "$LAST_STATUS" != "disconnected" ]; then
                echo "$TS: VPN unreachable — outside business hours"
                slack_notify ":red_circle: *VPN disconnected* — \`$HOSTNAME_LABEL\` at $TS
Outside business hours — will auto-open OpenVPN Connect from 09:00 SGT."
            fi
        fi
    fi

    LAST_STATUS="$CURRENT_STATUS"
    sleep "$CHECK_INTERVAL"
done
