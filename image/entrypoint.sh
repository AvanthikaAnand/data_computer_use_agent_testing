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

# Pre-create Firefox profile to avoid "Profile Missing" on first launch.
mkdir -p "$HOME/.mozilla/firefox/default-release"
mkdir -p "$HOME/.cache/mozilla/firefox"

# ── XFCE4 components — started manually (NOT via startxfce4 / xfce4-session)
# Using startxfce4 launches xfce4-session, whose failsafe client list includes
# its own xfce4-panel entry — producing a second panel on top of ours.
# Starting each component directly with --sm-client-disable keeps us in full
# control: exactly the processes we start, nothing more.
echo "[entrypoint] Starting D-Bus session bus"
eval "$(dbus-launch --sh-syntax)"
export DBUS_SESSION_BUS_ADDRESS

echo "[entrypoint] Starting XFCE4 components"
xfsettingsd --sm-client-disable 2>/dev/null &
sleep 1
xfwm4 --sm-client-disable 2>/dev/null &
sleep 1
xfdesktop --sm-client-disable 2>/dev/null &
sleep 1

# Trigger xfconfd to load our panel XML now (before xfce4-panel asks for it),
# so the panel never races against a cold xfconfd start.
xfconf-query -c xfce4-panel -p /panels -v 2>/dev/null || true
sleep 1

# Panel — reads our pre-written xfconfd XML (1 panel, bottom, Firefox/Term/Files)
xfce4-panel --sm-client-disable 2>/dev/null &
sleep 3

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
