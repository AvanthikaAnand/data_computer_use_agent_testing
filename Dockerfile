# Computer Use Agent — Ubuntu 24.04 + XFCE4 + Chrome
# Pinned to linux/amd64: Chrome only ships amd64 packages.
# On Apple Silicon, Docker Desktop uses Rosetta 2 for emulation automatically.

FROM --platform=linux/amd64 ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    DISPLAY=:1 \
    DISPLAY_NUM=1 \
    WIDTH=1366 \
    HEIGHT=768 \
    DEPTH=24 \
    VNC_PORT=5901 \
    NOVNC_PORT=6080 \
    HOME=/home/agent \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

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
    && rm -rf /var/lib/apt/lists/*

# ── Google Chrome ─────────────────────────────────────────────────────────────
RUN curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg && \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] \
        https://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list && \
    apt-get update && apt-get install -y --no-install-recommends google-chrome-stable \
    && rm -rf /var/lib/apt/lists/*

# ── Firefox ───────────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends firefox && \
    rm -rf /var/lib/apt/lists/*

# ── noVNC (web client) ────────────────────────────────────────────────────────
RUN mkdir -p /opt/novnc && \
    curl -fsSL https://github.com/novnc/noVNC/archive/refs/tags/v1.5.0.tar.gz \
        | tar -xz -C /opt/novnc --strip-components=1 && \
    ln -s /opt/novnc/vnc.html /opt/novnc/index.html

# ── Non-root user ─────────────────────────────────────────────────────────────
RUN useradd -m -s /bin/bash agent && \
    echo "agent ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers && \
    # X11 socket dir must exist with sticky bit before Xvfb runs as non-root
    mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

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
COPY image/xfce4-panel.xml /etc/xdg/xfce4/panel/default.xml
COPY image/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && chown -R agent:agent /home/agent/app

USER agent

EXPOSE 6080 5901 7860 8000

ENTRYPOINT ["/entrypoint.sh"]
