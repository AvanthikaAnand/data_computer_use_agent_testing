#!/bin/bash
# Relay Docker environment variables to /etc/agent.env so that systemd
# service units can read them via EnvironmentFile=-/etc/agent.env.
# Then hand off PID 1 to systemd.

set -e

# Write all current env vars in systemd EnvironmentFile format so that
# service units can read them via EnvironmentFile=-/etc/agent.env.
printenv | while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    printf '%s="%s"\n' "$key" "${value//\"/\\\"}"
done > /etc/agent.env

# Fix ownership of the Firefox profile volume — Docker creates named volumes
# owned by root. The agent user needs write access before Firefox launches.
mkdir -p /home/agent/.mozilla/firefox/default-release /home/agent/Downloads
chown -R agent:agent /home/agent/.mozilla /home/agent/Downloads

# /run is a tmpfs (from docker-compose) owned by root. Pre-create the dir
# that dbus-session.service writes into so the agent user can write there.
mkdir -p /run/agent
chown agent:agent /run/agent

echo "[entrypoint] Setup complete — handing off to systemd"
exec /sbin/init
