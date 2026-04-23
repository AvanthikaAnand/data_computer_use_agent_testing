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
XVFB_PID=$!

# Wait for Xvfb to be ready
sleep 1
until xdpyinfo -display ${DISPLAY} >/dev/null 2>&1; do sleep 0.2; done
echo "[entrypoint] Xvfb ready"

# Start XFCE4 desktop (lightweight, fast)
echo "[entrypoint] Starting XFCE4"
startxfce4 &
sleep 2

# x11vnc — VNC server over the virtual display
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

# noVNC — web browser VNC client
echo "[entrypoint] Starting noVNC on port ${NOVNC_PORT}"
websockify \
    --web /opt/novnc \
    --wrap-mode=ignore \
    ${NOVNC_PORT} \
    localhost:${VNC_PORT} &

echo "[entrypoint] Desktop ready at http://localhost:${NOVNC_PORT}"

# Set a sensible wallpaper and XFCE appearance
xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitorscreen/workspace0/color-style -s 0 2>/dev/null || true
xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitorscreen/workspace0/rgba1 -s "0.172549 0.243137 0.313725 1.000000" 2>/dev/null || true

# Launch the Gradio UI
echo "[entrypoint] Starting agent UI on port 7860"
cd /home/agent/app
exec python -m ui.app
