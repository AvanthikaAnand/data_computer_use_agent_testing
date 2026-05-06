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

# Write panel config BEFORE starting desktop so xfconfd reads it on launch.
# Also wipe any stale xfconf state persisted in the home volume.
echo "[entrypoint] Applying desktop panel config"
PANEL_CFG_DIR="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
LAUNCHER_DIR="$HOME/.config/xfce4/panel"
mkdir -p "$PANEL_CFG_DIR" "$LAUNCHER_DIR"
cp /home/agent/app/image/xfce4-panel.xml "$PANEL_CFG_DIR/xfce4-panel.xml"
cp -r /home/agent/app/image/panel/. "$LAUNCHER_DIR/"

echo "[entrypoint] Starting XFCE4"
startxfce4 &
sleep 3

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

xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitorscreen/workspace0/color-style -s 0 2>/dev/null || true
xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitorscreen/workspace0/rgba1 -s "0.172549 0.243137 0.313725 1.000000" 2>/dev/null || true

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
