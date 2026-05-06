#!/bin/bash
# Firefox wrapper — Docker-safe flags applied to every launch path.
# Installed at /usr/local/bin/firefox, overrides the real binary.
exec /usr/bin/firefox \
    --no-sandbox \
    --disable-background-networking \
    "$@"
