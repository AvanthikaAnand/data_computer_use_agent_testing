#!/bin/bash
# Firefox wrapper — Docker-safe flags for all launch paths.
# --no-sandbox   : required in Docker (no user namespaces by default)
# --profile      : always use our pre-configured profile

DISPLAY=${DISPLAY:-:1}
export DISPLAY

/usr/bin/firefox-esr \
    --no-sandbox \
    --profile "$HOME/.mozilla/firefox/default-release" \
    "$@"
