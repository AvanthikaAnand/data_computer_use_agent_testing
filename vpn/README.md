# VPN Config

Place your `.ovpn` file here, then set in your `.env`:

```
VPN_CONFIG_PATH=/vpn/your-config.ovpn
```

To connect manually inside any agent container:
```bash
docker exec -it cu-agent-1 bash
openvpn3 config-import --config /vpn/your-config.ovpn --name MyVPN
openvpn3 session-start --config MyVPN
openvpn3 sessions-list       # check status
```
