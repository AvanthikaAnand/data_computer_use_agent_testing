#!/bin/bash
# deploy.sh — Build and (re)deploy the cu-vpn monitor container on EC2.
#
# Design goals:
#   • Only touches the cu-vpn container — never the CU agent containers.
#   • Idempotent: safe to run multiple times.
#   • If a VPN session is in progress, the new container picks it up on start
#     (openvpn3 sessions persist in the host D-Bus, not inside the container).
#
# Usage:
#   ./deploy.sh                         # build locally on EC2, then run
#   SKIP_BUILD=1 ./deploy.sh            # restart from existing image
#
# Environment variables (all optional — defaults shown):
#   EC2_HOST        44.243.79.67
#   EC2_USER        ec2-user
#   EC2_KEY         ~/Downloads/sit-computer-use-ec2.pem
#   VPN_OVPN_PATH   /home/ec2-user/vpn/avanthika.ovpn   (inside EC2)
#   SLACK_CHANNEL   C0B7FUXGHU0

set -euo pipefail

EC2_HOST="${EC2_HOST:-44.243.79.67}"
EC2_USER="${EC2_USER:-ec2-user}"
EC2_KEY="${EC2_KEY:-$HOME/Downloads/sit-computer-use-ec2.pem}"
REMOTE_DIR="/home/ec2-user/host-vpn-monitor"
VPN_DIR="/home/ec2-user/vpn"
SLACK_CHANNEL="${SLACK_CHANNEL:-C0B7FUXGHU0}"
IMAGE="cu-vpn:latest"
CONTAINER="cu-vpn"

SSH="ssh -i $EC2_KEY -o StrictHostKeyChecking=no $EC2_USER@$EC2_HOST"
SCP="scp -i $EC2_KEY -o StrictHostKeyChecking=no"

echo "==> Syncing host-vpn-monitor source to EC2 ..."
$SSH "mkdir -p $REMOTE_DIR"
$SCP "$(dirname "$0")/Dockerfile" \
     "$(dirname "$0")/vpn-entrypoint.sh" \
     "$EC2_USER@$EC2_HOST:$REMOTE_DIR/"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
    echo "==> Building Docker image on EC2 ..."
    $SSH "cd $REMOTE_DIR && docker build -t $IMAGE . 2>&1"
fi

echo "==> (Re)deploying $CONTAINER ..."

# Grab the Slack token from the running container env (if it already exists),
# or fall back to the .env file on the host.
SLACK_TOKEN=$($SSH "
    docker inspect $CONTAINER --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep '^SLACK_BOT_TOKEN=' | cut -d= -f2-
" 2>/dev/null || true)

if [ -z "$SLACK_TOKEN" ]; then
    SLACK_TOKEN=$($SSH "grep SLACK_BOT_TOKEN /home/ec2-user/.env 2>/dev/null | cut -d= -f2- | tr -d '\"'" 2>/dev/null || true)
fi

# Stop old container if running — this is the only disruption: a few seconds
# while the new one starts and re-imports the VPN config.
$SSH "
    docker stop $CONTAINER 2>/dev/null || true
    docker rm   $CONTAINER 2>/dev/null || true
    docker run -d \
        --name $CONTAINER \
        --net=host \
        --privileged \
        --restart=unless-stopped \
        -v $VPN_DIR:/vpn:ro \
        -e SLACK_BOT_TOKEN='$SLACK_TOKEN' \
        -e SLACK_VPN_CHANNEL='$SLACK_CHANNEL' \
        -e HOSTNAME_LABEL='cu-agent-ec2' \
        -e VPN_CHECK_INTERVAL=60 \
        $IMAGE
    echo '==> Container started. Logs (first 30 lines):'
    sleep 8
    docker logs $CONTAINER 2>&1 | head -30
"

echo "==> Done. Only the $CONTAINER container was touched."
echo "    CU agent containers are untouched."
