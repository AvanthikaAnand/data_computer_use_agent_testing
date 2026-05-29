# Computer Use Agent — Ubuntu 24.04 + Firefox + systemd
# systemd runs as PID 1, giving openvpn3 its native D-Bus environment.
# Native multi-arch (arm64 + amd64): Chrome removed so Apple Silicon runs
# natively without Rosetta 2.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Singapore \
    DISPLAY=:1 \
    DISPLAY_NUM=1 \
    WIDTH=1920 \
    HEIGHT=1080 \
    DEPTH=24 \
    VNC_PORT=5901 \
    NOVNC_PORT=6080 \
    HOME=/home/agent \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    MOZ_DISABLE_RenderCompositorSWGL=1

# ── System packages ───────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    mutter \
    tint2 \
    xfce4-terminal \
    xfce4-taskmanager \
    thunar \
    thunar-archive-plugin \
    xvfb \
    x11vnc \
    websockify \
    scrot \
    xdotool \
    x11-utils \
    fonts-liberation \
    fonts-noto-color-emoji \
    adwaita-icon-theme \
    curl \
    wget \
    git \
    unzip \
    ca-certificates \
    gnupg \
    iproute2 \
    python3 \
    python3-pip \
    python3-venv \
    libgl1 \
    libglib2.0-0 \
    dbus \
    dbus-x11 \
    at-spi2-core \
    tzdata \
    apt-transport-https \
    sudo \
    # systemd as PID 1 — enables openvpn3 D-Bus service activation
    systemd \
    systemd-sysv \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/share/zoneinfo/Asia/Singapore /etc/localtime \
    && echo "Asia/Singapore" > /etc/timezone \
    # Mask systemd units incompatible with containers
    && systemctl mask \
        dev-hugepages.mount \
        sys-fs-fuse-connections.mount \
        sys-kernel-config.mount \
        display-manager.service \
        getty@.service \
        getty.target \
        console-getty.service \
        systemd-logind.service \
        systemd-remount-fs.service \
        systemd-udev-trigger.service \
        systemd-udevd.service \
        systemd-update-utmp.service \
        systemd-networkd.service \
        NetworkManager.service \
    && rm -f \
        /lib/systemd/system/multi-user.target.wants/systemd-resolved.service \
        /lib/systemd/system/sysinit.target.wants/systemd-resolved.service \
    || true

# ── OpenVPN ───────────────────────────────────────────────────────────────────
# openvpn3 is required for OpenVPN Cloud SAML auth — openvpn2 exits on AUTH_FAILED.
# Ubuntu Noble has no ARM64 openvpn3 packages, but Debian Bookworm does.
# Ubuntu 24.04 is Bookworm-era so the packages are ABI-compatible.
# openvpn3-client depends on libtinyxml2-9 but Ubuntu Noble ships libtinyxml2-10.
# Adding the Debian repo naively causes python3-systemd (Debian) to be selected,
# which requires python3<3.12 — conflict with Noble's 3.12.
# Fix: add Debian Bookworm at apt priority 100 (below Ubuntu's default 500) so
# Ubuntu packages always win, and only packages absent from Ubuntu (libtinyxml2-9)
# get pulled from Debian. Remove the Debian list after install to keep image clean.
# Also keep openvpn (v2) for fallback / non-SAML use.
RUN curl -fsSL https://packages.openvpn.net/packages-repo.gpg \
        | gpg --dearmor -o /etc/apt/keyrings/openvpn.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/openvpn.gpg] \
        https://packages.openvpn.net/openvpn3/debian bookworm main" \
        > /etc/apt/sources.list.d/openvpn3.list && \
    echo "deb [trusted=yes] http://deb.debian.org/debian bookworm main" \
        > /etc/apt/sources.list.d/debian-bookworm.list && \
    printf 'Package: *\nPin: origin deb.debian.org\nPin-Priority: 100\n' \
        > /etc/apt/preferences.d/debian-bookworm && \
    apt-get update && \
    apt-get install -y --no-install-recommends openvpn3 openvpn && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /etc/apt/sources.list.d/debian-bookworm.list \
          /etc/apt/preferences.d/debian-bookworm

# ── Firefox ESR ───────────────────────────────────────────────────────────────
RUN curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
        | gpg --dearmor -o /etc/apt/keyrings/packages.mozilla.org.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.gpg] \
        https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list && \
    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1001\n' \
        > /etc/apt/preferences.d/mozilla && \
    apt-get update && \
    apt-get install -y --no-install-recommends firefox-esr && \
    rm -rf /var/lib/apt/lists/*

# ── mozilla.cfg — Firefox prefs outside the profile ──────────────────────────
# These apply to every profile (including volume-mounted ones) on every launch.
# Fixes: cookie isolation, tracking protection, geolocation, fingerprinting,
# language header, disk cache, WebRTC, notification permission.
COPY image/autoconfig.js /usr/lib/firefox-esr/defaults/pref/autoconfig.js
COPY image/mozilla.cfg   /usr/lib/firefox-esr/mozilla.cfg

# ── Firefox wrapper ───────────────────────────────────────────────────────────
COPY image/firefox-wrapper.sh /usr/local/bin/firefox-esr
RUN chmod +x /usr/local/bin/firefox-esr && \
    ln -sf /usr/local/bin/firefox-esr /usr/local/bin/firefox

# ── uBlock Origin — force-installed via Firefox enterprise policy ─────────────
RUN mkdir -p /usr/lib/firefox-esr/distribution/extensions && \
    curl -fsSL --retry 3 \
        "https://addons.mozilla.org/firefox/downloads/file/4721638/ublock_origin-1.70.0.xpi" \
        -o "/usr/lib/firefox-esr/distribution/extensions/uBlock0@raymondhill.net.xpi"
COPY image/firefox-policies.json /usr/lib/firefox-esr/distribution/policies.json

# ── noVNC ─────────────────────────────────────────────────────────────────────
RUN mkdir -p /opt/novnc && \
    curl -fsSL --retry 5 --retry-delay 5 \
        -o /tmp/novnc.tar.gz \
        https://github.com/novnc/noVNC/archive/refs/tags/v1.5.0.tar.gz && \
    tar -xz -C /opt/novnc --strip-components=1 -f /tmp/novnc.tar.gz && \
    rm /tmp/novnc.tar.gz && \
    printf '<!DOCTYPE html>\n<html>\n<head><meta charset="utf-8"><title>Agent Desktop</title>\n<script>window.location="vnc.html?autoconnect=true&resize=scale&reconnect=true&reconnect_delay=2000";</script>\n</head><body>Loading...</body></html>\n' \
        > /opt/novnc/index.html

# ── FileBrowser — arch-aware ──────────────────────────────────────────────────
RUN FB_ARCH=$(dpkg --print-architecture) && \
    curl -fsSL "https://github.com/filebrowser/filebrowser/releases/latest/download/linux-${FB_ARCH}-filebrowser.tar.gz" \
        | tar -xz -C /usr/local/bin filebrowser && \
    chmod +x /usr/local/bin/filebrowser

# ── Non-root user ─────────────────────────────────────────────────────────────
RUN useradd -m -s /bin/bash agent && \
    echo "agent ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    mkdir -p /tmp/.X11-unix /tmp/.ICE-unix && \
    chmod 1777 /tmp/.X11-unix /tmp/.ICE-unix

# ── Firefox profile template ──────────────────────────────────────────────────
# Stored OUTSIDE the profile directory so it isn't shadowed by the Docker
# volume mount. firefox-profile-init.service copies these to the volume on
# first run only — subsequent starts skip this, preserving session cookies.
# Each heredoc needs its own RUN — the Dockerfile parser rejects heredocs
# inside backslash-continued multi-statement RUN blocks.
RUN mkdir -p /etc/agent/firefox-profile-template /home/agent/.mozilla/firefox

RUN cat > /etc/agent/firefox-profile-template/profiles.ini << 'EOF'
[General]
StartWithLastProfile=1
Version=2

[Profile0]
Name=default-release
IsRelative=1
Path=default-release
Default=1
EOF

# user.js — only needed to trigger bookmark import on a fresh profile.
# All other prefs live in mozilla.cfg (install-level, survives volume mount).
RUN cat > /etc/agent/firefox-profile-template/user.js << 'EOF'
user_pref("browser.places.importBookmarksHTML", true);
EOF

RUN cat > /etc/agent/firefox-profile-template/bookmarks.html << 'EOF'
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks Menu</H1>
<DL><p>
    <DT><H3 ADD_DATE="0" LAST_MODIFIED="0" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks Toolbar</H3>
    <DL><p>
        <DT><A HREF="https://yp.internal.you.co/" ADD_DATE="0">YouPortal</A>
        <DT><A HREF="https://portal.esimfx.com/auth/signin" ADD_DATE="0">eSIMfx Portal</A>
        <DT><A HREF="https://mail.google.com/mail/u/0/" ADD_DATE="0">Gmail</A>
        <DT><A HREF="https://login4.fisglobal.com/idp/PANorama" ADD_DATE="0">FIS panorama</A>
    </DL><p>
</DL><p>
EOF

RUN cp /etc/agent/firefox-profile-template/profiles.ini \
       /home/agent/.mozilla/firefox/profiles.ini

# ── Static tint2 + desktop launcher config ────────────────────────────────────
RUN mkdir -p /home/agent/.config/tint2/applications

RUN cat > /home/agent/.config/tint2/applications/filebrowser.desktop << 'EOF'
[Desktop Entry]
Name=File Browser
Comment=Upload and download files
Exec=/usr/bin/firefox-esr --no-sandbox --new-tab http://localhost:8080
Icon=folder
Type=Application
Categories=Utility;
EOF

RUN cat > /home/agent/.config/tint2/tint2rc << 'EOF'
#-------------------------------------
# Panel
panel_items = TL
panel_size = 100% 48
panel_margin = 0 0
panel_padding = 2 0 2
panel_background_id = 1
panel_position = bottom center horizontal
panel_layer = top
panel_monitor = all
panel_shrink = 0
autohide = 0
strut_policy = follow_size
panel_window_name = tint2
disable_transparency = 1
mouse_effects = 1

#-------------------------------------
# Taskbar
taskbar_mode = single_desktop
taskbar_hide_if_empty = 0
taskbar_padding = 0 0 2
taskbar_background_id = 0
taskbar_active_background_id = 0
taskbar_name = 1
taskbar_name_padding = 4 2
taskbar_name_background_id = 0
taskbar_name_active_background_id = 0
taskbar_name_font_color = #e3e3e3 100
taskbar_name_active_font_color = #ffffff 100
task_align = left

#-------------------------------------
# Launcher
launcher_padding = 4 8 4
launcher_background_id = 0
launcher_icon_size = 32
launcher_tooltip = 1
launcher_item_app = /usr/share/applications/firefox-esr.desktop
launcher_item_app = /usr/share/applications/xfce4-terminal.desktop
launcher_item_app = /home/agent/.config/tint2/applications/filebrowser.desktop

#-------------------------------------
# Background
# ID 1
rounded = 0
border_width = 0
background_color = #2c3e50 100
border_color = #000000 30
EOF

# ── Systemd service units ─────────────────────────────────────────────────────
COPY image/systemd/ /etc/systemd/system/
RUN systemctl enable \
    xvfb.service \
    dbus-session.service \
    mutter.service \
    tint2.service \
    x11vnc.service \
    websockify.service \
    firefox-profile-init.service \
    firefox-prewarm.service \
    filebrowser.service \
    agent-api.service \
    agent-ui.service \
    vpn-keepalive.service \
    && true

WORKDIR /home/agent/app

# ── Python dependencies ───────────────────────────────────────────────────────
COPY requirements.txt .
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

ENV PATH="/opt/venv/bin:$PATH"

# ── App source ────────────────────────────────────────────────────────────────
COPY . .

# ── Ownership ─────────────────────────────────────────────────────────────────
RUN chown -R agent:agent /home/agent && \
    chmod +x /home/agent/app/image/firefox-profile-init.sh \
    && chmod +x /home/agent/app/image/maintain_vpn_connection.sh

# ── Entrypoint: relay Docker env → /etc/agent.env, then hand to systemd ───────
COPY image/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 6080 5901 7860 8000 8080

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/entrypoint.sh"]
