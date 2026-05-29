#!/bin/bash
# VPN container entrypoint.
# Runs inside a container with --net=host so the tun interface appears on the
# host network stack — all Docker containers automatically route through it.
#
# Env vars:
#   SLACK_BOT_TOKEN     xoxb-... with chat:write scope
#   SLACK_VPN_CHANNEL   Slack channel ID (default: C0B7FUXGHU0)
#   VPN_CONFIG          Path to .ovpn inside the container (default: /vpn/avanthika.ovpn)
#   VPN_KEEPALIVE_URL   URL to ping when connected (optional)
#   VPN_CHECK_INTERVAL  Seconds between checks (default: 60)
#   HOSTNAME_LABEL      Label shown in Slack messages

SLACK_TOKEN="${SLACK_BOT_TOKEN:-}"
SLACK_CHANNEL="${SLACK_VPN_CHANNEL:-C0B7FUXGHU0}"
VPN_CONFIG="${VPN_CONFIG:-/vpn/avanthika.ovpn}"
VPN_KEEPALIVE_URL="${VPN_KEEPALIVE_URL:-}"
CHECK_INTERVAL="${VPN_CHECK_INTERVAL:-60}"
HOSTNAME_LABEL="${HOSTNAME_LABEL:-$(hostname)}"
SAML_URL_FILE="/tmp/vpn_saml_url"

# ── Helpers ───────────────────────────────────────────────────────────────────

slack_notify() {
    [ -z "$SLACK_TOKEN" ] && return 0
    # Build JSON safely: escape backslashes, quotes, then newlines → \n
    local escaped
    escaped=$(printf '%s' "$1" \
        | sed 's/\\/\\\\/g' \
        | sed 's/"/\\"/g' \
        | sed ':a;N;$!ba;s/\n/\\n/g')
    curl -sf -X POST https://slack.com/api/chat.postMessage \
        -H "Authorization: Bearer $SLACK_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"channel\":\"$SLACK_CHANNEL\",\"text\":\"$escaped\"}" > /dev/null 2>&1
}

within_business_hours() {
    local h; h=$(date -u +%H)
    [ "$h" -ge 1 ] && [ "$h" -lt 10 ]
}

get_vpn_state() {
    local s; s=$(openvpn3 sessions-list 2>/dev/null)
    if echo "$s" | grep -q "Client connected"; then echo "connected"
    elif echo "$s" | grep -q "Web authentication required"; then echo "auth_required"
    else echo "disconnected"; fi
}

trigger_reconnect_and_capture_url() {
    # Kill any stale sessions first — a lingering auth_required session
    # causes subsequent session-start calls to fail with "New tunnel did not respond"
    openvpn3 session-manage --config-path /net/openvpn/v3/configuration/$(
        openvpn3 configs-list 2>/dev/null | awk '/cu-vpn/{print $1}' | head -1
    ) --disconnect 2>/dev/null || true
    openvpn3 session-manage -c cu-vpn --disconnect 2>/dev/null || true
    sleep 2

    rm -f "$SAML_URL_FILE"
    local intercept_dir; intercept_dir=$(mktemp -d)

    # Wrapper captures the SAML URL that openvpn3 passes to the browser.
    # openvpn3 tries to open a browser with the URL; in headless environments
    # it also prints the URL directly to stdout as a fallback.
    cat > "$intercept_dir/firefox-esr" << 'WRAPPER'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in http*) echo "$arg" > /tmp/vpn_saml_url; break;; esac
done
WRAPPER
    chmod +x "$intercept_dir/firefox-esr"
    for name in firefox xdg-open sensible-browser x-www-browser; do
        ln -sf "$intercept_dir/firefox-esr" "$intercept_dir/$name"
    done

    # All echo output → stderr so only the URL reaches stdout (captured by caller)
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC'): Starting VPN session (config: $VPN_CONFIG) ..." >&2
    local session_out
    session_out=$(PATH="$intercept_dir:$PATH" openvpn3 session-start --config cu-vpn 2>/dev/null) || \
    session_out=$(PATH="$intercept_dir:$PATH" openvpn3 session-start --config "$VPN_CONFIG" 2>/dev/null) || true

    # Strategy 1: URL in the browser-intercept file (openvpn3 called our wrapper)
    if [ -f "$SAML_URL_FILE" ]; then
        rm -rf "$intercept_dir"
        cat "$SAML_URL_FILE"
        return
    fi

    # Strategy 2: URL printed directly in session-start output
    local url_from_stdout
    url_from_stdout=$(echo "$session_out" | grep -oE 'https://[^[:space:]]+' | head -1)
    if [ -n "$url_from_stdout" ]; then
        rm -rf "$intercept_dir"
        echo "$url_from_stdout"
        return
    fi

    # Strategy 3: Poll up to 60s for the session to reach web auth state,
    # then get URL via session-auth
    echo "Polling up to 60s for web auth state ..." >&2
    for _i in $(seq 1 12); do
        sleep 5
        [ -f "$SAML_URL_FILE" ] && break
        local sess_status
        sess_status=$(openvpn3 sessions-list 2>/dev/null)
        if echo "$sess_status" | grep -q "Web authentication required"; then
            # Try to extract URL from session-auth output
            local auth_url
            auth_url=$(openvpn3 session-auth 2>/dev/null | grep -oE 'https://[^[:space:]]+' | head -1)
            if [ -n "$auth_url" ]; then
                echo "$auth_url" > "$SAML_URL_FILE"
                break
            fi
        fi
    done
    rm -rf "$intercept_dir"
    if [ -f "$SAML_URL_FILE" ]; then
        cat "$SAML_URL_FILE"
    fi
}

# ── Startup ───────────────────────────────────────────────────────────────────

# Start dbus (required by openvpn3)
mkdir -p /run/dbus
dbus-daemon --system --fork 2>/dev/null || true
sleep 5   # give D-Bus and openvpn3 services time to fully initialize

# Import VPN config (idempotent)
openvpn3 config-import --config "$VPN_CONFIG" --name cu-vpn --persistent 2>/dev/null || true

LAST_STATUS=""
DISCONNECTED_SINCE=0
echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC'): VPN monitor started (host: $HOSTNAME_LABEL)"

# ── Main loop ─────────────────────────────────────────────────────────────────
while true; do
    TS=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    CURRENT_STATUS=$(get_vpn_state)

    case "$CURRENT_STATUS" in
      connected)
        if [ "$LAST_STATUS" != "connected" ]; then
            echo "$TS: VPN connected"
            slack_notify ":large_green_circle: *VPN connected* — \`$HOSTNAME_LABEL\` at $TS"
        else
            echo "$TS: VPN connected — keepalive ok"
        fi
        [ -n "$VPN_KEEPALIVE_URL" ] && curl -sf "$VPN_KEEPALIVE_URL" > /dev/null 2>&1
        DISCONNECTED_SINCE=0
        ;;

      auth_required)
        if [ "$LAST_STATUS" != "auth_required" ]; then
            echo "$TS: VPN awaiting SAML auth"
            slack_notify ":warning: *VPN needs SAML auth* — \`$HOSTNAME_LABEL\` at $TS
A session is waiting. Auth link was already sent — check above in this channel."
        fi
        ;;

      disconnected)
        if within_business_hours; then
            echo "$TS: VPN disconnected — within business hours, reconnecting ..."
            AUTH_URL=$(trigger_reconnect_and_capture_url)
            TS2=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
            NEW_STATUS=$(get_vpn_state)

            if [ -n "$AUTH_URL" ]; then
                echo "$TS2: SAML URL captured — posting to Slack and waiting 10 min for auth"
                slack_notify ":warning: *VPN needs SAML auth* — \`$HOSTNAME_LABEL\` at $TS2
Click to authenticate:
$AUTH_URL"
                CURRENT_STATUS="auth_required"
                LAST_STATUS="auth_required"
                # Poll every 30s for up to 10 min — catch the moment user completes auth
                for i in $(seq 1 20); do
                    sleep 30
                    POLL_STATE=$(get_vpn_state)
                    if [ "$POLL_STATE" = "connected" ]; then
                        TS3=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
                        echo "$TS3: VPN connected after SAML auth"
                        slack_notify ":large_green_circle: *VPN connected* — \`$HOSTNAME_LABEL\` at $TS3"
                        CURRENT_STATUS="connected"
                        LAST_STATUS="connected"
                        break
                    elif [ "$POLL_STATE" = "disconnected" ]; then
                        # Session dropped before auth completed — exit poll loop and retry
                        CURRENT_STATUS="disconnected"
                        LAST_STATUS="auth_required"
                        break
                    fi
                    # Still auth_required — keep waiting
                done

            elif [ "$NEW_STATUS" = "connected" ]; then
                echo "$TS2: VPN reconnected (no SAML needed)"
                slack_notify ":large_green_circle: *VPN reconnected* — \`$HOSTNAME_LABEL\` at $TS2"
                CURRENT_STATUS="connected"

            else
                if [ "$LAST_STATUS" != "disconnected" ]; then
                    DISCONNECTED_SINCE=$(date +%s)
                    slack_notify ":red_circle: *VPN disconnected* — \`$HOSTNAME_LABEL\` at $TS2
Auto-reconnect attempted but no auth URL captured. Check the instance."
                else
                    NOW=$(date +%s)
                    SECS_DOWN=$(( NOW - DISCONNECTED_SINCE ))
                    if [ $((SECS_DOWN % 600)) -lt "$CHECK_INTERVAL" ] && [ "$SECS_DOWN" -gt 60 ]; then
                        MINS=$(( SECS_DOWN / 60 ))
                        slack_notify ":red_circle: *VPN still down* (${MINS}m) — \`$HOSTNAME_LABEL\` at $TS"
                    fi
                fi
            fi
        else
            echo "$TS: VPN disconnected — outside business hours (09:00–18:00 SGT)"
            if [ "$LAST_STATUS" != "disconnected" ]; then
                slack_notify ":red_circle: *VPN disconnected* — \`$HOSTNAME_LABEL\` at $TS
Outside business hours — auto-reconnect resumes at 09:00 SGT."
            fi
        fi
        ;;
    esac

    LAST_STATUS="$CURRENT_STATUS"
    sleep "$CHECK_INTERVAL"
done
