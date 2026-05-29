FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl ca-certificates gpg dbus \
    iproute2 net-tools \
    && rm -rf /var/lib/apt/lists/*

# Install openvpn3 — same approach as the cu-agent Dockerfile.
# Ubuntu 24.04 has no ARM64 openvpn3 packages; Debian Bookworm does.
# openvpn3-client needs libtinyxml2-9 but Ubuntu 24.04 ships libtinyxml2-10,
# so we add Debian Bookworm at priority 100 (below Ubuntu's 500) to pull
# only that missing lib, then remove the Debian source after install.
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://packages.openvpn.net/packages-repo.gpg \
      | gpg --dearmor -o /etc/apt/keyrings/openvpn.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/openvpn.gpg] https://packages.openvpn.net/openvpn3/debian bookworm main" \
      > /etc/apt/sources.list.d/openvpn3.list && \
    echo "deb [trusted=yes] http://deb.debian.org/debian bookworm main" \
      > /etc/apt/sources.list.d/debian-bookworm.list && \
    printf 'Package: *\nPin: origin deb.debian.org\nPin-Priority: 100\n' \
      > /etc/apt/preferences.d/debian-bookworm && \
    apt-get update && \
    apt-get install -y --no-install-recommends openvpn3 && \
    rm -rf /var/lib/apt/lists/* && \
    rm -f /etc/apt/sources.list.d/debian-bookworm.list \
          /etc/apt/preferences.d/debian-bookworm && \
    # Remove systemd D-Bus service activation files — systemd is not running in
    # this container, so D-Bus activation attempts for hostname1/locale1/etc.
    # cause ChildExited errors that eat into openvpn3-service-client's 5-second
    # registration timeout, causing "New tunnel did not respond" failures.
    rm -f /usr/share/dbus-1/system-services/org.freedesktop.hostname1.service \
          /usr/share/dbus-1/system-services/org.freedesktop.locale1.service \
          /usr/share/dbus-1/system-services/org.freedesktop.login1.service \
          /usr/share/dbus-1/system-services/org.freedesktop.network1.service \
          /usr/share/dbus-1/system-services/org.freedesktop.timedate1.service \
          /usr/share/dbus-1/system-services/org.freedesktop.systemd1.service

COPY vpn-entrypoint.sh /usr/local/bin/vpn-entrypoint.sh
RUN chmod +x /usr/local/bin/vpn-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/vpn-entrypoint.sh"]
