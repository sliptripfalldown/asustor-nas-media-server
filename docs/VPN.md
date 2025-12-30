# VPN Setup & Traffic Isolation

Complete guide to setting up ProtonVPN with network namespace isolation for secure torrenting.

## Table of Contents

- [Architecture](#architecture)
- [Why Network Namespaces?](#why-network-namespaces)
- [Setup Guide](#setup-guide)
- [VPN Watchdog](#vpn-watchdog)
- [Traffic Verification](#traffic-verification)
- [Troubleshooting](#troubleshooting)

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                     VPN NAMESPACE                            │
│  ┌─────────────┐    ┌──────────────┐                         │
│  │ qBittorrent │    │   proton0    │                         │
│  │  Prowlarr   │────│  (WireGuard) │──→ ProtonVPN (encrypted)│
│  │ FlareSolverr│    │  10.2.0.2    │                         │
│  └─────────────┘    └──────────────┘                         │
│        │                                                     │
│        │ Local API (10.200.200.0/24)                         │
│        ↓                                                     │
│  ┌──────────┐                                                │
│  │ veth-vpn │                                                │
│  └────┬─────┘                                                │
└───────┼──────────────────────────────────────────────────────┘
        │
┌───────┼──────────────────────────────────────────────────────┐
│  ┌────┴─────┐         HOST NETWORK                           │
│  │veth-host │    Sonarr, Radarr, Jellyfin                    │
│  │10.200.200.1    (direct internet, no VPN)                  │
│  └──────────┘                                                │
└──────────────────────────────────────────────────────────────┘
```

**Traffic Flow:**
- **Torrent/Indexer traffic**: VPN namespace → `proton0` (WireGuard) → ProtonVPN → Internet
- **\*arr apps & Jellyfin**: Host → `bond0` → Direct internet
- **Local API calls**: Host ↔ VPN namespace via `veth` pair (10.200.200.0/24)

---

## Why Network Namespaces?

The ProtonVPN GUI's split tunneling doesn't work reliably on headless servers. Network namespaces provide:

| Feature | Benefit |
|---------|---------|
| **Complete isolation** | VPN traffic is physically separated at the kernel level |
| **No DNS leaks** | Namespace uses Proton's DNS (10.2.0.1) exclusively |
| **Kill switch by design** | If VPN drops, namespace has no internet access |
| **Local network access** | Routes for LAN traffic bypass the VPN |
| **No traffic leaks** | qBittorrent bound to `proton0` interface only |

---

## Setup Guide

### Step 1: Download WireGuard Configs

1. Go to: https://account.protonvpn.com/downloads#wireguard-configuration
2. Select **Linux** as platform
3. Configure these settings (**IMPORTANT**):

   | Setting | Value | Why |
   |---------|-------|-----|
   | NetShield | Level 2 | Blocks malware + ads + trackers |
   | Moderate NAT | **OFF** | Required for port forwarding |
   | NAT-PMP | **ON** | Required for torrent seeding |
   | VPN Accelerator | ON | Improves speeds |

4. Choose **P2P-enabled servers** only (marked with P2P icon)

   **Recommended Countries** (privacy-friendly, no data retention):
   - Switzerland (CH-*)
   - Iceland (IS-*)
   - Netherlands (NL-*)
   - Sweden (SE-*)
   - Romania (RO-*)

   **Avoid**: US, UK, Australia, New Zealand, Canada (Five Eyes)

5. Download 4-6 configs for redundancy
6. Save to: `config/wireguard/servers/`

```bash
# Example structure
config/wireguard/
├── proton-template.conf  # Template (reference only)
└── servers/              # Your configs go here
    ├── CH-NL-1.conf
    ├── IS-DE-1.conf
    ├── SE-NL-1.conf
    └── CH-BE-2.conf
```

> **Security**: WireGuard configs contain your private key. Never commit them to git! The `.gitignore` already excludes `config/wireguard/servers/*.conf`

### Step 2: Set Up VPN Namespace

```bash
# Create the namespace and networking
sudo ./scripts/vpn-namespace-setup.sh setup

# This creates:
# - Network namespace "vpn"
# - veth pair for host↔namespace communication
# - NAT rules for namespace internet access
# - Proton DNS configuration (10.2.0.1)
```

### Step 3: Enable Services

```bash
# Copy service files
sudo cp config/systemd/vpn-namespace.service /etc/systemd/system/
sudo cp config/systemd/qbittorrent-vpn.service /etc/systemd/system/
sudo cp config/systemd/prowlarr-vpn.service /etc/systemd/system/
sudo cp config/systemd/flaresolverr-vpn.service /etc/systemd/system/
sudo cp config/systemd/vpn-watchdog.service /etc/systemd/system/

# Disable old services (if they exist)
sudo systemctl disable qbittorrent-nox prowlarr flaresolverr 2>/dev/null

# Enable VPN namespace services
sudo systemctl daemon-reload
sudo systemctl enable --now vpn-namespace qbittorrent-vpn prowlarr-vpn flaresolverr-vpn vpn-watchdog
```

### Step 4: Update Prowlarr URLs

Since Prowlarr now runs in the VPN namespace (10.200.200.2):

1. Open Prowlarr: http://10.200.200.2:9696
2. Go to **Settings → Apps**
3. Update each app:
   - **Prowlarr Server**: `http://10.200.200.2:9696`
   - **App Server**: `http://10.200.200.1:<port>`
4. Click **Test** then **Save**

---

## VPN Watchdog

The watchdog service monitors VPN health and automatically recovers from failures.

### What It Monitors

| Check | Threshold | Action on Failure |
|-------|-----------|-------------------|
| WireGuard interface | Must exist | Restart VPN |
| Handshake age | < 180 seconds | Restart VPN |
| Internet connectivity | curl test | Restart VPN |
| 3 consecutive failures | - | Rotate to next server |

### Commands

```bash
# Check watchdog status
systemctl status vpn-watchdog

# View logs
journalctl -u vpn-watchdog -f

# Manual server rotation
sudo ./scripts/qbt-vpn-start.sh rotate

# List available servers
sudo ./scripts/qbt-vpn-start.sh servers

# Switch to specific server
sudo ./scripts/qbt-vpn-start.sh restart CH-BE-2
```

### Recovery Flow

```
VPN Health Check (every 30s)
         │
         ▼
    ┌────────────┐
    │  Healthy?  │──Yes──→ Continue monitoring
    └────────────┘
         │ No
         ▼
    Failed checks += 1
         │
         ▼
    ┌────────────────┐
    │  >= 3 failures │──No──→ Wait 30s, retry
    └────────────────┘
         │ Yes
         ▼
    Attempt restart
         │
         ▼
    ┌────────────┐
    │  Success?  │──Yes──→ Reset counter, continue
    └────────────┘
         │ No
         ▼
    Rotate to next server
```

---

## Traffic Verification

### Quick Check

```bash
# IPs should be different
echo "Host IP: $(curl -s https://api.ipify.org)"
echo "VPN IP:  $(sudo ip netns exec vpn curl -s https://api.ipify.org)"
```

### Full Verification

```bash
# 1. Verify qBittorrent is bound to proton0
grep "Session\\Interface" ~/.config/qBittorrent/qBittorrent.conf
# Expected: Session\Interface=proton0

# 2. Verify services are in VPN namespace
for svc in Prowlarr flaresolverr qbittorrent; do
    pid=$(pgrep -f $svc | head -1)
    if [ -n "$pid" ]; then
        svc_ns=$(sudo stat -L /proc/$pid/ns/net | grep -oP 'Inode: \K\d+')
        vpn_ns=$(sudo stat -L /var/run/netns/vpn | grep -oP 'Inode: \K\d+')
        if [ "$svc_ns" = "$vpn_ns" ]; then
            echo "✓ $svc is in VPN namespace"
        else
            echo "✗ $svc is LEAKING!"
        fi
    fi
done

# 3. Check WireGuard status
sudo ip netns exec vpn wg show proton0

# 4. Verify no traffic on bond0 (should be empty)
sudo tcpdump -i bond0 -n 'port 6881 or port 6969' -c 5
```

### What Each Check Means

| Check | Pass | Fail |
|-------|------|------|
| Interface binding | `proton0` | Empty or `bond0` |
| Namespace inode | Matches VPN namespace | Different inode = leak |
| WireGuard handshake | < 3 minutes ago | Stale = reconnecting |
| tcpdump on bond0 | No packets | Torrent traffic leaking! |

---

## Troubleshooting

### VPN Not Connecting

```bash
# Check WireGuard status
sudo ip netns exec vpn wg show

# Check if handshake is happening
# If "latest handshake" is missing, config may be wrong

# Try manual connect
sudo ./scripts/qbt-vpn-start.sh restart

# Check logs
journalctl -u qbittorrent-vpn -n 50
```

### Services Not in Namespace

```bash
# Restart services
sudo systemctl restart prowlarr-vpn flaresolverr-vpn

# Verify
sudo ip netns exec vpn pgrep -a Prowlarr
```

### Port Forwarding Not Working

```bash
# Check NAT-PMP
sudo ip netns exec vpn natpmpc -g 10.2.0.1

# Verify port in qBittorrent
curl -s "http://10.200.200.2:8080/api/v2/app/preferences" | jq .listen_port

# Check if port refresh loop is running
pgrep -f qbt-port-refresh
```

### Namespace Doesn't Exist

```bash
# Recreate namespace
sudo systemctl restart vpn-namespace

# Verify
sudo ip netns list
```

### All Servers Failing

```bash
# Check if configs exist
ls config/wireguard/servers/

# Test config manually
sudo ip netns exec vpn wg-quick up /path/to/config.conf

# Download fresh configs from ProtonVPN
```

---

## Related Files

| File | Purpose |
|------|---------|
| `scripts/vpn-namespace-setup.sh` | Creates/manages VPN namespace |
| `scripts/qbt-vpn-start.sh` | Starts qBittorrent + WireGuard with failover |
| `scripts/vpn-watchdog.sh` | Monitors and auto-recovers VPN |
| `config/systemd/vpn-*.service` | Systemd service files |
| `config/wireguard/servers/*.conf` | WireGuard configs (not in git) |
