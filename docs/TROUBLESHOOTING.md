# Troubleshooting Guide

Common issues and their solutions.

## Table of Contents

- [VPN Issues](#vpn-issues)
- [qBittorrent Issues](#qbittorrent-issues)
- [*arr App Issues](#arr-app-issues)
- [Indexer Issues](#indexer-issues)
- [Library Issues](#library-issues)
- [Security Settings](#security-settings)

---

## VPN Issues

### VPN Namespace Doesn't Exist

```bash
sudo ip netns list
# Empty or no "vpn"

# Fix: Restart namespace service
sudo systemctl restart vpn-namespace
sudo systemctl status vpn-namespace
```

### WireGuard Not Connected (No Handshake)

```bash
sudo ip netns exec vpn wg show
# Shows "latest handshake: (none)" or old timestamp

# Fix: Rotate to different server
sudo systemctl reload qbittorrent-vpn

# Or manually select a server:
ls ~/nas-media-server/config/wireguard/servers/
sudo cp ~/nas-media-server/config/wireguard/servers/CH-NL-2.conf /etc/wireguard/vpn/active.conf
sudo ip netns exec vpn wg-quick down proton0 2>/dev/null
sudo ip netns exec vpn wg-quick up proton0
```

### Can't Reach 10.200.200.2 from Host

```bash
ping 10.200.200.2
# Network unreachable or no reply

# Check veth interfaces exist
ip link show veth-host
sudo ip netns exec vpn ip link show veth-vpn

# Fix: Recreate namespace
sudo systemctl restart vpn-namespace
```

### VPN Has No Internet (Tunnel Down)

```bash
sudo ip netns exec vpn curl -s --max-time 5 https://api.ipify.org
# Timeout or error

# Check WireGuard interface
sudo ip netns exec vpn ip addr show proton0
# Should have an IP like 10.2.0.x

# Check routing
sudo ip netns exec vpn ip route

# Fix: Bring WireGuard back up
sudo ip netns exec vpn wg-quick up proton0
```

### "Nexthop has invalid gateway" Error

```bash
# Symptom: VPN restart fails, WireGuard handshake stale
sudo ip netns exec vpn ip route
# Shows: 10.200.200.0/24 via 10.200.200.1 dev veth-vpn (WRONG!)

# Fix: Repair the link-local route
sudo ip netns exec vpn ip route del 10.200.200.0/24 2>/dev/null
sudo ip netns exec vpn ip route add 10.200.200.0/24 dev veth-vpn scope link
sudo ip netns exec vpn ip route add default via 10.200.200.1

# Then restart VPN
sudo ~/nas-media-server/scripts/qbt-vpn-start.sh restart
```

### DNS Leaking (Queries Going to ISP)

```bash
# Check DNS config in namespace
sudo ip netns exec vpn cat /etc/resolv.conf
# Should show: nameserver 10.2.0.1 (Proton DNS)

# Fix: Restart namespace
sudo systemctl restart vpn-namespace
```

### Full Namespace Reset

If all else fails:

```bash
# Stop all VPN namespace services
sudo systemctl stop flaresolverr-vpn prowlarr-vpn qbittorrent-vpn vpn-namespace

# Kill orphaned processes
sudo ip netns pids vpn 2>/dev/null | xargs -r sudo kill

# Delete the namespace
sudo ip netns delete vpn 2>/dev/null

# Recreate everything
sudo systemctl start vpn-namespace
sleep 3
sudo systemctl start qbittorrent-vpn
sleep 5
sudo systemctl start prowlarr-vpn flaresolverr-vpn

# Verify
sudo ip netns exec vpn curl -s https://api.ipify.org && echo " (VPN IP)"
```

---

## qBittorrent Issues

### qBittorrent Shows "Firewalled"

1. Check ProtonVPN port forwarding is enabled
2. Verify the port matches: `journalctl -b -g "external_port:"`
3. Update qBittorrent port in settings
4. Restart qBittorrent

### Downloads Not Starting

```bash
# 1. Check VPN namespace
sudo ip netns list

# 2. Check WireGuard
sudo ip netns exec vpn wg show

# 3. Verify VPN has internet
sudo ip netns exec vpn curl -s https://api.ipify.org

# 4. Check logs
journalctl -u qbittorrent-vpn -f

# 5. Try rotating servers
sudo systemctl reload qbittorrent-vpn
```

### Port Forwarding Not Working

```bash
# Check NAT-PMP
sudo ip netns exec vpn natpmpc -g 10.2.0.1

# Request port
sudo ip netns exec vpn natpmpc -a 0 0 udp 60 -g 10.2.0.1
sudo ip netns exec vpn natpmpc -a 0 0 tcp 60 -g 10.2.0.1

# Update qBittorrent to use the assigned port
# Settings → Connection → Listening Port
```

### Qt/OpenSSL Library Issues

```bash
# Verify library path
export LD_LIBRARY_PATH=/usr/local/lib/qt6.10.1/lib:$LD_LIBRARY_PATH
ldd /usr/local/bin/qbittorrent-nox
```

---

## *arr App Issues

### Can't Connect to qBittorrent

**Error:** "All download clients are unavailable" or "Unable to communicate with qBittorrent"

**Cause:** *arr apps configured to `localhost:8080`, but qBittorrent is at `10.200.200.2:8080`

**Fix via UI:**
1. Open the *arr app
2. Settings → Download Clients
3. Click on qBittorrent
4. Change **Host** from `localhost` to `10.200.200.2`
5. Click Test, then Save

**Required Settings:**

| Setting | Value |
|---------|-------|
| Host | `10.200.200.2` |
| Port | `8080` |
| Remove Completed | `true` |
| Remove Failed | `true` |

**Verification:**
```bash
# Test qBittorrent is accessible
curl -s http://10.200.200.2:8080/api/v2/app/version
```

### Can't Connect to Prowlarr

```bash
# 1. Verify Prowlarr is running
systemctl status prowlarr-vpn

# 2. Check URL is correct
# Should be: http://10.200.200.2:9696

# 3. Check namespace routing
curl http://10.200.200.2:9696

# 4. Verify Prowlarr app settings:
#    - Prowlarr Server: http://10.200.200.2:9696
#    - Sonarr Server: http://10.200.200.1:8989
#    - Radarr Server: http://10.200.200.1:7878
```

### DNS Leaks (Searches Visible to ISP)

```bash
# Verify Prowlarr is in VPN namespace
systemctl status prowlarr-vpn  # Should show prowlarr-vpn, NOT prowlarr

# Check Prowlarr's external IP matches VPN
sudo nsenter --net=/proc/$(pgrep -f Prowlarr)/ns/net curl -s ifconfig.me

# If on host network, switch to VPN service:
sudo systemctl stop prowlarr
sudo systemctl disable prowlarr
sudo systemctl enable --now prowlarr-vpn
```

---

## Indexer Issues

### Indexer Unavailable Errors

Common causes:
- **Site is down**: Some indexers go offline permanently
- **Cloudflare protection**: Ensure FlareSolverr is running
- **DNS issues**: Check domain resolves: `host <domain>`

Reset failed indexer status:
```bash
curl -X DELETE "http://localhost:9696/api/v1/indexerstatus/INDEXER_ID" \
  -H "X-Api-Key: YOUR_API_KEY"
```

### Recommended Book Indexers

Since EBookBay is dead:
- InternetArchive (legal, free books)
- The Pirate Bay
- BitSearch
- TorrentDownloads
- Nyaa (manga/light novels)

---

## Library Issues

### Hardlinks Not Working

**Symptom:** Files are copied instead of hardlinked, doubling disk usage

**Cause:** Downloads and library are on different filesystems

**Fix:** Both must be under the same ZFS dataset:
```
/tank/media/
├── downloads/    # qBittorrent downloads here
├── movies/       # Library here (same filesystem)
├── tv/
└── music/
```

### Media Not Importing

```bash
# Check permissions
ls -la /tank/media/downloads/
ls -la /tank/media/movies/

# Fix ownership
sudo chown -R anon:anon /tank/media
```

---

## Security Settings

### Default Credentials (CHANGE THESE!)

| Service | Default Login |
|---------|---------------|
| qBittorrent | admin / admin |
| Radarr | (set during first run) |
| Sonarr | (set during first run) |
| Lidarr | (set during first run) |
| Prowlarr | (set during first run) |
| Jellyfin | (set during wizard) |

### qBittorrent Security Settings

Edit `~/.config/qBittorrent/qBittorrent.conf`:

```ini
[BitTorrent]
Session\Encryption=1               # Require encryption
Session\Anonymous=true             # Anonymous mode

[Preferences]
WebUI\LocalHostAuth=false
WebUI\AuthSubnetWhitelist=192.168.0.0/16, 10.200.200.0/24
WebUI\AuthSubnetWhitelistEnabled=true
```

### Firewall (UFW)

```bash
# Allow local access only
sudo ufw allow from 192.168.0.0/16 to any port 8080  # qBittorrent
sudo ufw allow from 192.168.0.0/16 to any port 7878  # Radarr
sudo ufw allow from 192.168.0.0/16 to any port 8989  # Sonarr
sudo ufw allow from 192.168.0.0/16 to any port 8686  # Lidarr
sudo ufw allow from 192.168.0.0/16 to any port 9696  # Prowlarr
sudo ufw allow from 192.168.0.0/16 to any port 8096  # Jellyfin

sudo ufw enable
```

---

## Quick Diagnostic Commands

```bash
# Check all VPN namespace services
for svc in vpn-namespace qbittorrent-vpn prowlarr-vpn flaresolverr-vpn; do
    echo "$svc: $(systemctl is-active $svc)"
done

# Check all host services
for svc in radarr sonarr lidarr lazylibrarian jellyfin; do
    echo "$svc: $(systemctl is-active $svc)"
done

# Verify VPN isolation (IPs should differ)
echo "Host IP: $(curl -s https://api.ipify.org)"
echo "VPN IP:  $(sudo ip netns exec vpn curl -s https://api.ipify.org)"

# Check which namespace a process is in
pgrep -f qbittorrent-nox
sudo ls -la /proc/$(pgrep -f qbittorrent-nox)/ns/net
```

---

## Related Documentation

| Doc | Description |
|-----|-------------|
| [VPN Guide](VPN.md) | VPN setup and architecture |
| [Services Guide](SERVICES.md) | Service configuration |
| [Storage Guide](STORAGE.md) | ZFS and file sharing |
