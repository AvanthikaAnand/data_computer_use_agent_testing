#!/bin/bash
set -e

DISPLAY_NUM=${DISPLAY_NUM:-1}
DISPLAY=":${DISPLAY_NUM}"
export DISPLAY

WIDTH=${WIDTH:-1366}
HEIGHT=${HEIGHT:-768}
DEPTH=${DEPTH:-24}
VNC_PORT=${VNC_PORT:-5901}
NOVNC_PORT=${NOVNC_PORT:-6080}

echo "[entrypoint] Starting Xvfb on display ${DISPLAY} at ${WIDTH}x${HEIGHT}x${DEPTH}"
Xvfb ${DISPLAY} -screen 0 ${WIDTH}x${HEIGHT}x${DEPTH} -ac +extension GLX +render -noreset &

until [ -S /tmp/.X11-unix/X${DISPLAY_NUM} ]; do sleep 0.2; done
echo "[entrypoint] Xvfb ready"

# ── Desktop config ────────────────────────────────────────────────────────────
# Wipe ALL stale xfce4 state so xfconfd reads our clean 1-panel config.
echo "[entrypoint] Writing clean desktop config"
XFCE_CFG="$HOME/.config/xfce4"
PANEL_CFG_DIR="$XFCE_CFG/xfconf/xfce-perchannel-xml"
LAUNCHER_DIR="$XFCE_CFG/panel"

rm -rf "$XFCE_CFG"
mkdir -p "$PANEL_CFG_DIR" "$LAUNCHER_DIR"
cp /home/agent/app/image/xfce4-panel.xml "$PANEL_CFG_DIR/xfce4-panel.xml"
cp -r /home/agent/app/image/panel/. "$LAUNCHER_DIR/"

# ── Firefox profile ───────────────────────────────────────────────────────────
# Pre-create a named profile and write user.js to disable GPU/hardware
# acceleration — these features crash in Xvfb (no real GPU).
# MOZ_DISABLE_RenderCompositorSWGL=1 (set in Dockerfile ENV) handles the
# renderer process; user.js handles the compositor and WebGL layers.
FIREFOX_PROFILE="$HOME/.mozilla/firefox/default-release"
mkdir -p "$FIREFOX_PROFILE"
mkdir -p "$HOME/.cache/mozilla/firefox"

cat > "$FIREFOX_PROFILE/user.js" << 'USERJS'
// Disable hardware acceleration — prevents RenderCompositorSWGL crash in Xvfb
user_pref("layers.acceleration.disabled", true);
user_pref("gfx.webrender.enabled", false);
user_pref("gfx.webrender.all", false);
user_pref("webgl.disabled", true);
// Suppress first-run UI
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.firstrunSkipsHomepage", true);
user_pref("browser.startup.homepage", "about:blank");
// Disable session restore prompt
user_pref("browser.sessionstore.resume_from_crash", false);
USERJS

# Write profiles.ini so Firefox picks up our profile automatically
mkdir -p "$HOME/.mozilla/firefox"
cat > "$HOME/.mozilla/firefox/profiles.ini" << 'PROFILES'
[General]
StartWithLastProfile=1
Version=2

[Profile0]
Name=default-release
IsRelative=1
Path=default-release
Default=1
PROFILES

# ── XFCE4 components — started manually (NOT via startxfce4 / xfce4-session)
# Using startxfce4 launches xfce4-session, whose failsafe client list includes
# its own xfce4-panel entry — producing a second panel on top of ours.
# Starting each component directly with --sm-client-disable keeps us in full
# control: exactly the processes we start, nothing more.
echo "[entrypoint] Starting D-Bus session bus"
eval "$(dbus-launch --sh-syntax)"
export DBUS_SESSION_BUS_ADDRESS

echo "[entrypoint] Starting XFCE4 components"

# Warm up xfconfd with our XML before any panel process starts.
# This prevents xfce4-panel from racing against a cold xfconfd.
xfconf-query -c xfce4-panel -p /panels -v 2>/dev/null || true

xfsettingsd --sm-client-disable 2>/dev/null &
sleep 1
xfwm4 --sm-client-disable 2>/dev/null &
sleep 1

# xfdesktop manages the desktop icons/wallpaper.
# --sm-client-disable prevents it registering with any session manager.
xfdesktop --sm-client-disable 2>/dev/null &
sleep 1

# Panel — reads our pre-written xfconfd XML (1 panel, bottom, Firefox/Term/Files)
# Started LAST so all other components are settled and xfconfd is fully loaded.
xfce4-panel --sm-client-disable 2>/dev/null &
sleep 3

# Explicitly remove any stale second panel that xfdesktop or another component
# may have triggered during startup, then do nothing more — any restart from
# here would cause the duplicate we're fighting.
_panel_count=$(xfconf-query -c xfce4-panel -p /panels 2>/dev/null | grep -c '[0-9]')
if [ "${_panel_count:-0}" -gt 1 ]; then
    echo "[entrypoint] WARNING: xfconfd shows >1 panel — resetting to panel-1 only"
    xfconf-query -c xfce4-panel -p /panels -t int -s 1 --force-array 2>/dev/null || true
    pkill -x xfce4-panel 2>/dev/null || true
    sleep 1
    xfce4-panel --sm-client-disable 2>/dev/null &
    sleep 2
fi

# Dark desktop background
xfconf-query -c xfce4-desktop \
    -p /backdrop/screen0/monitorscreen/workspace0/color-style -s 0 2>/dev/null || true
xfconf-query -c xfce4-desktop \
    -p /backdrop/screen0/monitorscreen/workspace0/rgba1 \
    -s "0.172549 0.243137 0.313725 1.000000" 2>/dev/null || true

echo "[entrypoint] Starting x11vnc on port ${VNC_PORT}"
x11vnc \
    -display ${DISPLAY} \
    -nopw \
    -listen localhost \
    -xkb \
    -ncache 10 \
    -ncache_cr \
    -forever \
    -rfbport ${VNC_PORT} \
    -noxrecord \
    -noxdamage \
    -shared \
    -bg -o /tmp/x11vnc.log

echo "[entrypoint] Starting noVNC on port ${NOVNC_PORT}"
websockify \
    --web /opt/novnc \
    --wrap-mode=ignore \
    ${NOVNC_PORT} \
    localhost:${VNC_PORT} &

echo "[entrypoint] Desktop ready at http://localhost:${NOVNC_PORT}"

cd /home/agent/app

# VPN keepalive — only runs if VPN_KEEPALIVE_URL is set
if [ -n "${VPN_KEEPALIVE_URL:-}" ]; then
    echo "[entrypoint] Starting VPN keepalive (url=${VPN_KEEPALIVE_URL})"
    bash /home/agent/app/image/maintain_vpn_connection.sh &
fi

# FastAPI — REST + SSE API (port 8000)
echo "[entrypoint] Starting FastAPI on port 8000"
uvicorn api.main:app --host 0.0.0.0 --port 8000 --workers 1 &

# Gradio UI (port 7860)
echo "[entrypoint] Starting Gradio UI on port 7860"
exec python -m ui.app
