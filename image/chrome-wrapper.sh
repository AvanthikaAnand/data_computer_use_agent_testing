#!/bin/bash
# Chrome wrapper — ensures Docker-safe flags are always passed.
# Installed at /usr/local/bin/google-chrome, overrides the real binary.
exec /usr/bin/google-chrome \
    --no-sandbox \
    --disable-setuid-sandbox \
    --disable-dev-shm-usage \
    --disable-gpu \
    --disable-software-rasterizer \
    --no-first-run \
    --no-default-browser-check \
    --disable-sync \
    --password-store=basic \
    --disable-background-networking \
    --disable-client-side-phishing-detection \
    --disable-hang-monitor \
    --metrics-recording-only \
    --safebrowsing-disable-auto-update \
    "$@"
