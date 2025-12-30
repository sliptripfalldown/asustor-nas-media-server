# NAS Media Server

A self-hosted media server with VPN-protected downloads, the *arr stack, and Jellyfin streaming.

```
                    ┌──────────────────────────────────────────────────┐
                    │              MEDIA SERVER                        │
                    │                                                  │
   ProtonVPN ◄──────┤  VPN NAMESPACE (10.200.200.2)                    │
   (encrypted)      │  ┌───────────┐ ┌──────────┐ ┌────────────┐       │
                    │  │qBittorrent│ │ Prowlarr │ │FlareSolverr│       │
                    │  │   :8080   │ │  :9696   │ │   :8191    │       │
                    │  └───────────┘ └──────────┘ └────────────┘       │
                    │         ▲          ▲              ▲              │
                    │         └──────────┴──────────────┘              │
                    │                    │ local bridge                │
                    │  HOST NETWORK      │                             │
                    │  ┌──────┐ ┌──────┐ ┌──────┐ ┌─────────┐          │
                    │  │Radarr│ │Sonarr│ │Lidarr│ │Jellyfin │◄── Stream│
                    │  │:7878 │ │:8989 │ │:8686 │ │  :8096  │          │
                    │  └──────┘ └──────┘ └──────┘ └─────────┘          │
                    │         │          │          │                  │
                    │         └──────────┴──────────┘                  │
                    │                    │                             │
                    │  STORAGE    /tank/media (ZFS RAIDZ2)             │
                    │             ├── downloads/ ◄── torrents          │
                    │             ├── movies/    ◄── hardlinks         │
                    │             ├── tv/                              │
                    │             └── music/                           │
                    └──────────────────────────────────────────────────┘
```

## Features

| Feature | Description |
|---------|-------------|
| **VPN Isolation** | Torrent traffic isolated in network namespace - kill switch by design |
| **Auto-Recovery** | VPN watchdog monitors health, auto-reconnects and rotates servers |
| **Zero DNS Leaks** | Namespace uses Proton's DNS (10.2.0.1) exclusively |
| **Queue Management** | Auto-prioritizes healthy downloads over struggling ones |
| **Ratio Protection** | Prevents infinite upload in dead swarms |
| **ZFS RAIDZ2** | 6x NVMe drives, can lose 2 drives, ~7.3TB usable |
| **Hardware Control** | Automatic fan curves, LED triggers, temperature monitoring |

## Quick Start

### 1. Clone & Configure

```bash
git clone https://github.com/sliptripfalldown/nas-media-server.git ~/nas-media-server
cd ~/nas-media-server
```

### 2. Download WireGuard Configs

Get configs from [ProtonVPN](https://account.protonvpn.com/downloads#wireguard-configuration):
- Select **Linux** → **WireGuard**
- Enable **NAT-PMP (Port Forwarding)** - required for seeding
- Choose **P2P-enabled servers** (CH, NL, SE, IS recommended)
- Download 3-4 configs for failover

```bash
cp ~/Downloads/*.conf ~/nas-media-server/config/wireguard/servers/
```

### 3. Run Rebuild Script

```bash
sudo ./rebuild.sh
```

This installs dependencies, builds qBittorrent from source, and configures all services.

### 4. Complete Setup Wizards

| Service | URL | Action |
|---------|-----|--------|
| Jellyfin | http://localhost:8096 | Create admin user |
| AdGuard | http://localhost:3000 | Set password |

### 5. Run Post-Install

```bash
./scripts/post-install.sh
```

Automatically configures:
- Download clients (qBittorrent at `10.200.200.2:8080`)
- Root folders for movies, TV, music
- 20+ public indexers in Prowlarr
- Jellyfin media libraries

### 6. Change Default Passwords

| Service | Where |
|---------|-------|
| qBittorrent | Settings → Web UI → Authentication |
| Sonarr/Radarr/Lidarr | Settings → General → Security |
| Prowlarr | Settings → General → Security |

## Service URLs

**VPN Protected** (via `10.200.200.2`):

| Service | URL |
|---------|-----|
| qBittorrent | http://10.200.200.2:8080 |
| Prowlarr | http://10.200.200.2:9696 |

**Host Network** (via `localhost`):

| Service | URL |
|---------|-----|
| Radarr | http://localhost:7878 |
| Sonarr | http://localhost:8989 |
| Lidarr | http://localhost:8686 |
| Jellyfin | http://localhost:8096 |

## Verify VPN Isolation

```bash
# IPs should be different
echo "Host IP: $(curl -s https://api.ipify.org)"
echo "VPN IP:  $(sudo ip netns exec vpn curl -s https://api.ipify.org)"

# Check services are protected
for svc in qbittorrent Prowlarr flaresolverr; do
    pid=$(pgrep -f $svc | head -1)
    if [ -n "$pid" ]; then
        svc_ns=$(sudo stat -L /proc/$pid/ns/net | grep -oP 'Inode: \K\d+')
        vpn_ns=$(sudo stat -L /var/run/netns/vpn | grep -oP 'Inode: \K\d+')
        [ "$svc_ns" = "$vpn_ns" ] && echo "✓ $svc protected" || echo "✗ $svc LEAKING"
    fi
done
```

## Common Commands

```bash
# Check service status
systemctl status qbittorrent-vpn prowlarr-vpn vpn-watchdog

# Rotate VPN server
sudo ./scripts/qbt-vpn-start.sh rotate

# View VPN logs
journalctl -u qbittorrent-vpn -u vpn-watchdog -f

# Restart all services
sudo systemctl restart vpn-namespace qbittorrent-vpn prowlarr-vpn flaresolverr-vpn
```

## Hardware

Built on the **ASUSTOR Flashstor 6 (FS6706T)**:

| Component | Spec |
|-----------|------|
| CPU | Intel N5105 (4 cores, 2.9GHz burst) |
| RAM | 32GB DDR4 |
| Storage | 6x 2TB NVMe (RAIDZ2) |
| Network | 2x 2.5GbE (bonded) |
| Power | ~25-35W |

See [Hardware Guide](docs/HARDWARE.md) for benchmarks and optimization.

## Documentation

| Guide | Description |
|-------|-------------|
| [Hardware](docs/HARDWARE.md) | Specs, benchmarks, fan control, LED triggers |
| [Storage](docs/STORAGE.md) | ZFS setup, file sharing |
| [VPN](docs/VPN.md) | Namespace architecture, watchdog, traffic verification |
| [Services](docs/SERVICES.md) | *arr stack, Jellyfin, qBittorrent optimization |
| [Building](docs/BUILDING.md) | Compile OpenSSL, Qt, qBittorrent from source |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Common issues and fixes |

## Project Structure

```
nas-media-server/
├── config/
│   ├── systemd/           # Service files (vpn-namespace, qbittorrent-vpn, etc.)
│   ├── qbittorrent/       # Optimized qBittorrent config
│   ├── fancontrol/        # Automatic fan curve configuration
│   ├── wireguard/
│   │   └── servers/       # Your WireGuard configs (gitignored)
│   └── sysctl/            # Kernel network tuning
├── scripts/
│   ├── vpn-namespace-setup.sh    # Create VPN namespace
│   ├── qbt-vpn-start.sh          # Start qBittorrent + WireGuard
│   ├── vpn-watchdog.sh           # Monitor VPN, auto-recover
│   ├── hardware-control.sh       # Fan, LED, and sensor control
│   ├── setup-hardware-controls.sh # Install fancontrol + LED services
│   ├── configure-arr-stack.sh    # Configure *arr apps
│   ├── qbit-queue-manager.py     # Prioritize healthy downloads
│   └── qbt-ratio-guard.py        # Protect against ratio abuse
├── docs/                  # Detailed documentation
├── rebuild.sh             # Full system rebuild
└── install.sh             # Quick install
```

## Automated Tasks

| Task | Frequency | Description |
|------|-----------|-------------|
| VPN Watchdog | Every 30s | Monitor health, auto-reconnect |
| Fancontrol | Every 5s | Adjust fan speed based on CPU temp |
| Ratio Guard | Every 15 min | Stop excessive uploads |
| Queue Manager | Every 30 min | Prioritize healthy torrents |
| Tracker Aggregator | Hourly | Add public trackers to stalled torrents |
| qBittorrent Restart | Every 4 hours | Prevent memory buildup |

## License

MIT

---

**Note**: This project is for personal use. Ensure you comply with local laws regarding media downloading and sharing.
