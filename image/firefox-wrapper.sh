#!/bin/bash
# Firefox wrapper — Docker-safe flags applied to every launch path.
# --no-sandbox   : required in Docker (no user namespaces by default)
# --profile      : always use our pre-configured profile with GPU accel disabled
exec /usr/bin/firefox \
    --no-sandbox \
    --profile "$HOME/.mozilla/firefox/default-release" \
    "$@"
