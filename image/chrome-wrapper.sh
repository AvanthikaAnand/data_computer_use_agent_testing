#!/bin/bash
# Wrapper that ensures Chrome always runs with Docker-safe flags.
# Placed at /usr/local/bin/google-chrome, overrides the real binary.
exec /usr/bin/google-chrome \
    --no-sandbox \
    --disable-dev-shm-usage \
    --disable-gpu \
    --disable-software-rasterizer \
    --no-first-run \
    --no-default-browser-check \
    "$@"
