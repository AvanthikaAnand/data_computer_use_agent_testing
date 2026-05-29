# Host VPN Monitor

Runs on the **EC2 instance** (not inside Docker containers). When the instance
VPN connects, all 5 cu-agent containers automatically route through it.

## What it does

| Event | Action |
|---|---|
| VPN connected | 🟢 Slack alert |
| VPN disconnected, 09:00–18:00 SGT | Auto-triggers `openvpn3 session-start`, captures the SAML auth URL, posts it to Slack |
| VPN disconnected, outside hours | 🔴 Slack alert only |
| SAML auth URL captured | Posts clickable link directly to Slack channel |

## Install on the EC2 instance

```bash
# 1. Copy files
sudo cp vpn-monitor.sh /usr/local/bin/vpn-monitor.sh
sudo chmod +x /usr/local/bin/vpn-monitor.sh
sudo cp vpn-monitor.service /etc/systemd/system/

# 2. Create config
sudo cp vpn-monitor.env.example /etc/vpn-monitor.env
sudo nano /etc/vpn-monitor.env   # set VPN_CONFIG path

# 3. Put your .ovpn file on the instance
sudo mkdir -p /opt/vpn
sudo cp /path/to/avanthika.ovpn /opt/vpn/

# 4. Enable and start
sudo systemctl daemon-reload
sudo systemctl enable --now vpn-monitor

# 5. Check logs
journalctl -u vpn-monitor -f
```

## Container-level checks

The containers' `vpn-keepalive` service is a **connectivity-only** check — it
pings `VPN_KEEPALIVE_URL` and writes `reachable` / `unreachable` to
`/tmp/vpn_status`. The agent reads this before starting tasks (coming soon).
