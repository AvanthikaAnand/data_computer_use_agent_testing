# Computer Use Agent — Ubuntu 24.04 + XFCE4 + Chrome
# Pinned to linux/amd64: Chrome only ships amd64 packages.
# On Apple Silicon, Docker Desktop uses Rosetta 2 for emulation automatically.

FROM --platform=linux/amd64 ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Singapore \
    DISPLAY=:1 \
    DISPLAY_NUM=1 \
    WIDTH=1366 \
    HEIGHT=768 \
    DEPTH=24 \
    VNC_PORT=5901 \
    NOVNC_PORT=6080 \
    HOME=/home/agent \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    # Chrome flags for stable rendering inside Docker
    CHROME_FLAGS="--no-sandbox --disable-dev-shm-usage --disable-gpu --disable-software-rasterizer --no-first-run --no-default-browser-check"

# ── System packages ───────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core desktop
    xfce4 \
    xfce4-terminal \
    xfce4-taskmanager \
    thunar \
    thunar-archive-plugin \
    # Display server
    xvfb \
    x11vnc \
    # Fast web-based VNC
    websockify \
    # Screenshot + input control
    scrot \
    xdotool \
    x11-utils \
    # Fonts & icons
    fonts-liberation \
    fonts-noto-color-emoji \
    adwaita-icon-theme \
    # Utilities
    curl \
    wget \
    git \
    unzip \
    ca-certificates \
    gnupg \
    python3 \
    python3-pip \
    python3-venv \
    libgl1 \
    libglib2.0-0 \
    dbus-x11 \
    at-spi2-core \
    tzdata \
    apt-transport-https \
    && rm -rf /var/lib/apt/lists/* \
    # Set timezone
    && ln -sf /usr/share/zoneinfo/Asia/Singapore /etc/localtime \
    && echo "Asia/Singapore" > /etc/timezone

# ── Google Chrome ─────────────────────────────────────────────────────────────
RUN curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg && \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] \
        https://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && apt-get install -y --no-install-recommends google-chrome-stable \
    && rm -rf /var/lib/apt/lists/*

# ── Firefox (real .deb from Mozilla — Ubuntu 24.04 ships only a snap stub) ───
RUN curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
        | gpg --dearmor -o /etc/apt/keyrings/packages.mozilla.org.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.gpg] \
        https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list && \
    # Prefer Mozilla repo over Ubuntu's snap transitional stub
    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1001\n' \
        > /etc/apt/preferences.d/mozilla && \
    apt-get update && \
    apt-get install -y --no-install-recommends firefox && \
    rm -rf /var/lib/apt/lists/*

# ── Firefox wrapper (no-sandbox for Docker renderer stability) ────────────────
COPY image/firefox-wrapper.sh /usr/local/bin/firefox
RUN chmod +x /usr/local/bin/firefox

# ── Chrome wrapper (ensures Docker-safe flags for all launch paths) ───────────
COPY image/chrome-wrapper.sh /usr/local/bin/google-chrome
RUN chmod +x /usr/local/bin/google-chrome

# ── OpenVPN3 ─────────────────────────────────────────────────────────────────
RUN curl -fsSL https://packages.openvpn.net/packages-repo.gpg \
        | gpg --dearmor -o /etc/apt/keyrings/openvpn.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/openvpn.gpg] \
        https://packages.openvpn.net/openvpn3/debian noble main" \
        > /etc/apt/sources.list.d/openvpn3.list && \
    apt-get update && apt-get install -y --no-install-recommends openvpn3 \
    && rm -rf /var/lib/apt/lists/*

# ── noVNC (web client) ────────────────────────────────────────────────────────
RUN mkdir -p /opt/novnc && \
    curl -fsSL https://github.com/novnc/noVNC/archive/refs/tags/v1.5.0.tar.gz \
        | tar -xz -C /opt/novnc --strip-components=1 && \
    ln -s /opt/novnc/vnc.html /opt/novnc/index.html

# ── Non-root user ─────────────────────────────────────────────────────────────
RUN useradd -m -s /bin/bash agent && \
    echo "agent ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    # X11 + ICE socket dirs must exist with sticky bit before Xvfb runs as non-root
    mkdir -p /tmp/.X11-unix /tmp/.ICE-unix && \
    chmod 1777 /tmp/.X11-unix /tmp/.ICE-unix

WORKDIR /home/agent/app

# ── Python dependencies ───────────────────────────────────────────────────────
COPY requirements.txt .
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

ENV PATH="/opt/venv/bin:$PATH"

# ── App source ────────────────────────────────────────────────────────────────
COPY . .

# ── Desktop environment config ────────────────────────────────────────────────
COPY image/entrypoint.sh /entrypoint.sh
# Override the system default panel config (2-panel) with our single-bottom-panel
# config so xfce4-panel NEVER falls back to the Ubuntu default.
COPY image/xfce4-panel.xml /etc/xdg/xfce4/panel/default.xml
RUN chmod +x /entrypoint.sh && \
    # Fix ownership of entire home dir — build steps running as root can create
    # root-owned subdirs (e.g. .cache from pip, font cache) which break Firefox
    # profile creation and other per-user apps.
    chown -R agent:agent /home/agent

USER agent

EXPOSE 6080 5901 7860 8000

ENTRYPOINT ["/entrypoint.sh"]
