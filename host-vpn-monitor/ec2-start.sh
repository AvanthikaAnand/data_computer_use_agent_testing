#!/bin/bash
# ec2-start.sh — Start the full cu-agent stack on EC2.
#
# Runs LiteLLM + postgres via docker compose (no cgroup quirks needed),
# then starts each cu-agent container via docker run with --cgroupns host
# (required for systemd on Amazon Linux 2023 / cgroup v2 hosts).
# Only starts the VPN monitor (cu-vpn) and agents 1-N — never destroys
# containers that aren't in the target list.
#
# Usage:
#   ./ec2-start.sh [num_agents]     # default: 3
#
# Environment (read from /home/ec2-user/cu-agent/.env automatically):
#   All AWS keys, Slack token, etc.

set -euo pipefail

NUM_AGENTS="${1:-3}"
BASE_DIR="/home/ec2-user/cu-agent"
ENV_FILE="$BASE_DIR/.env"
AGENT_ENV="$BASE_DIR/agent.env"
VPN_ENV="/home/ec2-user/.env"
VPN_DIR="/home/ec2-user/vpn"
IMAGE="cu-agent:latest"
EC2_IP=$(curl -sf --max-time 3 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || hostname -I | awk '{print $1}')

echo "==> EC2 IP: $EC2_IP | Starting $NUM_AGENTS agents"

# ── Infrastructure: postgres + LiteLLM via compose ───────────────────────────
echo "==> Starting postgres + LiteLLM..."
cd "$BASE_DIR"
docker compose --env-file "$ENV_FILE" up -d postgres litellm
echo "==> Waiting for postgres to be healthy..."
until docker inspect litellm-postgres --format '{{.State.Health.Status}}' 2>/dev/null | grep -q healthy; do sleep 2; done
echo "==> postgres healthy, LiteLLM up"

# ── CU Agent containers (systemd needs --cgroupns host on AL2023) ─────────────
for i in $(seq 1 "$NUM_AGENTS"); do
    NOVNC_PORT=$((6080 + i))
    GRADIO_PORT=$((7860 + i))
    API_PORT=$((8800 + i))    # task API (port 8000 inside container)
    FILE_PORT=$((8900 + i))   # filebrowser (port 8080 inside container)
    VNC_PORT=$((5910 + i))
    NAME="cu-agent-$i"

    if docker inspect "$NAME" &>/dev/null; then
        STATUS=$(docker inspect "$NAME" --format '{{.State.Status}}')
        if [ "$STATUS" = "running" ]; then
            echo "==> $NAME already running — skipping"
            continue
        fi
        docker rm -f "$NAME" 2>/dev/null || true
    fi

    echo "==> Starting $NAME (noVNC :$NOVNC_PORT, API :$API_PORT)..."
    docker run -d \
        --name "$NAME" \
        --hostname "$NAME" \
        --privileged \
        --cgroupns host \
        --shm-size 2gb \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        --tmpfs /run --tmpfs /run/lock \
        -v "$BASE_DIR/config.yaml":/home/agent/app/config.yaml:ro \
        -v "$BASE_DIR/vpn":/vpn:ro \
        --env-file "$AGENT_ENV" \
        --env-file "$ENV_FILE" \
        -e AGENT_ID="$i" \
        -e WIDTH=1920 -e HEIGHT=1080 \
        -e AGENT_HOST="$EC2_IP" \
        --network cu-agent_default \
        -p "${NOVNC_PORT}:6080" \
        -p "${GRADIO_PORT}:7860" \
        -p "${API_PORT}:8000" \
        -p "${FILE_PORT}:8080" \
        -p "${VNC_PORT}:5901" \
        --restart unless-stopped \
        "$IMAGE"
done

# ── VPN monitor ───────────────────────────────────────────────────────────────
if ! docker inspect cu-vpn &>/dev/null || [ "$(docker inspect cu-vpn --format '{{.State.Status}}')" != "running" ]; then
    echo "==> Starting cu-vpn monitor..."
    docker stop cu-vpn 2>/dev/null || true
    docker rm   cu-vpn 2>/dev/null || true
    docker run -d \
        --name cu-vpn \
        --net=host \
        --privileged \
        --restart=unless-stopped \
        -v "$VPN_DIR":/vpn:ro \
        --env-file "$VPN_ENV" \
        -e HOSTNAME_LABEL=cu-agent-ec2 \
        -e VPN_CHECK_INTERVAL=60 \
        cu-vpn:latest
else
    echo "==> cu-vpn already running — skipping"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "==> Stack status:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" \
  | grep -E "NAMES|cu-agent|litellm|postgres|cu-vpn"

echo ""
echo "==> Access URLs:"
for i in $(seq 1 "$NUM_AGENTS"); do
    echo "    Agent $i  noVNC → http://$EC2_IP:$((6080 + i))"
    echo "    Agent $i  API   → http://$EC2_IP:$((8800 + i))/task  (POST)"
    echo "    Agent $i  UI    → http://$EC2_IP:$((7860 + i))"
done
echo "    LiteLLM  → http://$EC2_IP:4000"
echo "    Traefik  → http://$EC2_IP:80  (load-balanced API)"
