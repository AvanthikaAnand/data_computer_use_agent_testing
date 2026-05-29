#!/bin/bash
# Host-level VPN monitor for the cu-agent EC2 instance.
#
# Responsibilities:
#   - Monitor openvpn3 connection status on the HOST (not inside containers)
#   - During business hours (09:00–18:00 SGT), auto-reconnect when disconnected
#   - On reconnect: capture the SAML auth URL (by intercepting the firefox-esr
#     call that openvpn3 makes) and post it directly to Slack
#   - On auth-needed state change: post the auth URL to Slack
#   - On connect/disconnect: post status change to Slack
#
# Setup:
#   sudo cp vpn-monitor.sh /usr/local/bin/vpn-monitor.sh
#   sudo chmod +x /usr/local/bin/vpn-monitor.sh
#   sudo cp vpn-monitor.service /etc/systemd/system/
#   sudo systemctl daemon-reload && sudo systemctl enable --now vpn-monitor
#
# Config (set in /etc/vpn-monitor.env or environment):
#   VPN_CONFIG          Path to .ovpn config (required)
#   SLACK_BOT_TOKEN     xoxb-... with chat:write scope
#   SLACK_CHANNEL       Slack channel ID (e.g. C0B7FUXGHU0)
#   VPN_CHECK_INTERVAL  Seconds between checks (default: 60)
#   VPN_KEEPALIVE_URL   URL to ping when connected (optional, keeps session alive)

VPN_CONFIG="${VPN_CONFIG:-/opt/vpn/avanthika.ovpn}"
SLACK_TOKEN="${SLACK_BOT_TOKEN:-}"
SLACK_CHANNEL="${SLACK_VPN_CHANNEL:-}"
CHECK_INTERVAL="${VPN_CHECK_INTERVAL:-60}"
KEEPALIVE_URL="${VPN_KEEPALIVE_URL:-}"
SAML_URL_FILE="/tmp/vpn_saml_url"
HOSTNAME_LABEL="$(hostname)"

# ── Helpers ───────────────────────────────────────────────────────────────────

slack_notify() {
    local text="$1"
    [ -z "$SLACK_TOKEN" ] || [ -z "$SLACK_CHANNEL" ] && return 0
    curl -sf -X POST https://slack.com/api/chat.postMessage \
        -H "Authorization: Bearer $SLACK_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"channel\":\"$SLACK_CHANNEL\",\"text\":\"$text\"}" \
        > /dev/null 2>&1
}

# Returns: connected | auth_required | disconnected
get_vpn_state() {
    local s
    s=$(openvpn3 sessions-list 2>/dev/null)
    if echo "$s" | grep -q "Client connected"; then
        echo "connected"
    elif echo "$s" | grep -q "Web authentication required"; then
        echo "auth_required"
    else
        echo "disconnected"
    fi
}

# Returns 0 (true) if current time is 09:00–18:00 SGT (01:00–10:00 UTC)
within_business_hours() {
    local h
    h=$(date -u +%H)
    [ "$h" -ge 1 ] && [ "$h" -lt 10 ]
}

# Trigger a new VPN session and capture the SAML URL.
# openvpn3 calls firefox-esr (or xdg-open) with the auth URL.
# We shadow those commands in PATH to intercept the URL instead of opening a browser.
trigger_reconnect_and_capture_url() {
    rm -f "$SAML_URL_FILE"

    local intercept_dir
    intercept_dir=$(mktemp -d)
    local wrapper="$intercept_dir/firefox-esr"

    # Write a wrapper that captures the URL to SAML_URL_FILE
    cat > "$wrapper" << 'WRAPPER'
#!/bin/bash
# Capture the SAML auth URL that openvpn3 passes to the browser
for arg in "$@"; do
    case "$arg" in
        http*) echo "$arg" > /tmp/vpn_saml_url; break ;;
    esac
done
WRAPPER
    chmod +x "$wrapper"

    # Also intercept other possible browser launchers
    for name in firefox xdg-open sensible-browser x-www-browser; do
        ln -sf "$wrapper" "$intercept_dir/$name"
    done

    echo "$(date '+%Y-%m-%d %H:%M:%S'): Starting VPN session (config: $VPN_CONFIG) ..."
    PATH="$intercept_dir:$PATH" openvpn3 session-start --config "$VPN_CONFIG" > /dev/null 2>&1 || true

    # Give openvpn3 time to reach the auth step and call the browser
    sleep 6

    rm -rf "$intercept_dir"

    if [ -f "$SAML_URL_FILE" ]; then
        cat "$SAML_URL_FILE"
    fi
}

# ── Main loop ─────────────────────────────────────────────────────────────────
LAST_STATUS=""

echo "$(date '+%Y-%m-%d %H:%M:%S'): VPN monitor started on $HOSTNAME_LABEL"

while true; do
    CURRENT_STATUS=$(get_vpn_state)
    TS=$(date '+%Y-%m-%d %H:%M:%S')

    case "$CURRENT_STATUS" in

      connected)
        if [ "$LAST_STATUS" != "connected" ]; then
            echo "$TS: VPN connected"
            slack_notify ":large_green_circle: *VPN connected* — \`$HOSTNAME_LABEL\` at $TS"
        fi
        if [ -n "$KEEPALIVE_URL" ]; then
            curl -sf "$KEEPALIVE_URL" > /dev/null 2>&1
        fi
        ;;

      auth_required)
        if [ "$LAST_STATUS" != "auth_required" ]; then
            echo "$TS: VPN session awaiting SAML authentication"
            # Auth URL was already posted when we triggered reconnect.
            # If we transitioned here without triggering (e.g. manual session-start),
            # post a reminder with instructions.
            slack_notify ":warning: *VPN needs SAML auth* — \`$HOSTNAME_LABEL\` at $TS
A VPN session is waiting for authentication. Check Slack for the auth link, or re-run the reconnect."
        fi
        ;;

      disconnected)
        if within_business_hours; then
            echo "$TS: VPN disconnected — within business hours, attempting reconnect ..."

            AUTH_URL=$(trigger_reconnect_and_capture_url)
            TS2=$(date '+%Y-%m-%d %H:%M:%S')
            NEW_STATUS=$(get_vpn_state)

            if [ -n "$AUTH_URL" ]; then
                echo "$TS2: SAML auth URL captured: $AUTH_URL"
                slack_notify ":warning: *VPN needs SAML auth* — \`$HOSTNAME_LABEL\` at $TS2
Auto-reconnect triggered. Click to authenticate:
$AUTH_URL"
                CURRENT_STATUS="auth_required"

            elif [ "$NEW_STATUS" = "connected" ]; then
                echo "$TS2: VPN reconnected (no SAML needed)"
                slack_notify ":large_green_circle: *VPN reconnected* — \`$HOSTNAME_LABEL\` at $TS2"
                CURRENT_STATUS="connected"

            else
                echo "$TS2: Reconnect attempted but VPN still not connected (status: $NEW_STATUS)"
                if [ "$LAST_STATUS" != "disconnected" ]; then
                    slack_notify ":red_circle: *VPN disconnected* — \`$HOSTNAME_LABEL\` at $TS2
Auto-reconnect attempted but failed. Check instance manually."
                fi
            fi

        else
            echo "$TS: VPN disconnected — outside business hours (09:00–18:00 SGT), skipping reconnect"
            if [ "$LAST_STATUS" != "disconnected" ]; then
                slack_notify ":red_circle: *VPN disconnected* — \`$HOSTNAME_LABEL\` at $TS
Outside business hours — auto-reconnect disabled until 09:00 SGT."
            fi
        fi
        ;;
    esac

    LAST_STATUS="$CURRENT_STATUS"
    sleep "$CHECK_INTERVAL"
done
