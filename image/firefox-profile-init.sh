#!/bin/bash
# Seed the Firefox profile volume on first use.
# On subsequent starts (volume already has data) this is a no-op.
# mozilla.cfg handles all prefs — this only seeds bookmark-import and profiles.ini.

PROFILE="/home/agent/.mozilla/firefox/default-release"
FIREFOX_DIR="/home/agent/.mozilla/firefox"
TEMPLATE="/etc/agent/firefox-profile-template"

mkdir -p "$PROFILE" "$FIREFOX_DIR"

# Seed profiles.ini if missing (needed so Firefox picks up our profile)
if [ ! -f "$FIREFOX_DIR/profiles.ini" ]; then
    echo "[firefox-profile-init] Writing profiles.ini"
    cp "$TEMPLATE/profiles.ini" "$FIREFOX_DIR/profiles.ini"
fi

# Seed user.js if missing — triggers bookmark import on first Firefox start.
# On subsequent starts (volume populated) user.js stays as-is, preserving
# any user changes. mozilla.cfg handles all other prefs independently.
if [ ! -f "$PROFILE/user.js" ]; then
    echo "[firefox-profile-init] Fresh profile volume — seeding user.js and bookmarks"
    cp "$TEMPLATE/user.js" "$PROFILE/user.js"
    cp "$TEMPLATE/bookmarks.html" "$PROFILE/bookmarks.html"
else
    echo "[firefox-profile-init] Existing profile detected — skipping seed (session preserved)"
fi
