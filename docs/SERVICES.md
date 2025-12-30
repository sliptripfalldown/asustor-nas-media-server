# Services Guide

Service configuration, optimization, and automation.

## Table of Contents

- [Installing the *arr Stack](#installing-the-arr-stack)
- [Installing Jellyfin](#installing-jellyfin)
- [Installing FlareSolverr](#installing-flaresolverr)
- [Service Configuration](#service-configuration)
- [qBittorrent Optimization](#qbittorrent-optimization)
- [Queue Management](#queue-management)
- [Ratio Protection](#ratio-protection)
- [Automation Scripts](#automation-scripts)

---

## Installing the *arr Stack

### Download Applications

```bash
# Create install directory
sudo mkdir -p /opt

# Radarr (Movies)
wget -O /tmp/radarr.tar.gz \
    "https://github.com/Radarr/Radarr/releases/latest/download/Radarr.master.linux-core-x64.tar.gz"
sudo tar -xzf /tmp/radarr.tar.gz -C /opt/
sudo chown -R anon:anon /opt/Radarr

# Sonarr (TV)
wget -O /tmp/sonarr.tar.gz \
    "https://github.com/Sonarr/Sonarr/releases/latest/download/Sonarr.main.linux-x64.tar.gz"
sudo tar -xzf /tmp/sonarr.tar.gz -C /opt/
sudo chown -R anon:anon /opt/Sonarr

# Lidarr (Music)
wget -O /tmp/lidarr.tar.gz \
    "https://github.com/Lidarr/Lidarr/releases/latest/download/Lidarr.master.linux-core-x64.tar.gz"
sudo tar -xzf /tmp/lidarr.tar.gz -C /opt/
sudo chown -R anon:anon /opt/Lidarr

# Readarr (Books)
wget -O /tmp/readarr.tar.gz \
    "https://github.com/Readarr/Readarr/releases/latest/download/Readarr.develop.linux-core-x64.tar.gz"
sudo tar -xzf /tmp/readarr.tar.gz -C /opt/
sudo chown -R anon:anon /opt/Readarr

# Prowlarr (Indexer Manager)
wget -O /tmp/prowlarr.tar.gz \
    "https://github.com/Prowlarr/Prowlarr/releases/latest/download/Prowlarr.master.linux-core-x64.tar.gz"
sudo tar -xzf /tmp/prowlarr.tar.gz -C /opt/
sudo chown -R anon:anon /opt/Prowlarr
```

---

## Installing Jellyfin

```bash
# Add Jellyfin repository
curl -fsSL https://repo.jellyfin.org/ubuntu/jellyfin_team.gpg.key | \
    sudo gpg --dearmor -o /usr/share/keyrings/jellyfin.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/jellyfin.gpg] \
    https://repo.jellyfin.org/ubuntu $(lsb_release -cs) main" | \
    sudo tee /etc/apt/sources.list.d/jellyfin.list

# Install
sudo apt update
sudo apt install -y jellyfin

# Enable and start
sudo systemctl enable jellyfin
sudo systemctl start jellyfin

# Access at http://localhost:8096
```

### Hardware Transcoding (Intel Quick Sync)

```bash
# Install VA-API tools
sudo apt install -y vainfo intel-media-va-driver

# Add jellyfin to required groups
sudo usermod -aG render jellyfin
sudo usermod -aG video jellyfin

# Verify GPU access
vainfo
```

**Note**: The N5105 only supports CQP encoding (not VBR), so hardware encoding is disabled. Hardware decoding and HDR tone mapping still work.

---

## Installing FlareSolverr

FlareSolverr bypasses Cloudflare protection for indexers.

```bash
cd /opt

# Clone FlareSolverr
sudo git clone https://github.com/FlareSolverr/FlareSolverr.git
sudo chown -R anon:anon FlareSolverr
cd FlareSolverr

# Create virtual environment
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Install browser
playwright install chromium
```

---

## Service Configuration

All services run as system-level services (`/etc/systemd/system/`), not user services.

### Install All Services

```bash
# Copy all service files
sudo cp config/systemd/*.service /etc/systemd/system/
sudo cp config/systemd/*.timer /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable VPN namespace services
sudo systemctl enable --now \
    vpn-namespace \
    qbittorrent-vpn \
    prowlarr-vpn \
    flaresolverr-vpn \
    vpn-watchdog

# Enable host network services
sudo systemctl enable --now \
    radarr \
    sonarr \
    lidarr \
    lazylibrarian \
    unpackerr
```

### Service Reference

#### VPN Namespace Services (Protected Traffic)

| Service | File | Description |
|---------|------|-------------|
| vpn-namespace | `vpn-namespace.service` | Creates VPN network namespace |
| qbittorrent-vpn | `qbittorrent-vpn.service` | qBittorrent + WireGuard in namespace |
| prowlarr-vpn | `prowlarr-vpn.service` | Prowlarr in namespace |
| flaresolverr-vpn | `flaresolverr-vpn.service` | FlareSolverr in namespace |
| vpn-watchdog | `vpn-watchdog.service` | Monitors VPN, auto-reconnects |

#### Host Network Services

| Service | File | Description |
|---------|------|-------------|
| radarr | `radarr.service` | Movie manager |
| sonarr | `sonarr.service` | TV series manager |
| lidarr | `lidarr.service` | Music manager |
| lazylibrarian | `lazylibrarian.service` | Book manager |
| unpackerr | `unpackerr.service` | Archive extractor |

#### Timer Services

| Timer | Frequency | Description |
|-------|-----------|-------------|
| qbit-queue-manager | Every 30 min | Prioritize healthy downloads |
| qbt-ratio-guard | Every 15 min | Protect against ratio abuse |
| tracker-aggregator | Hourly | Add public trackers to stalled torrents |

### Service URLs

**VPN Namespace** (access via `10.200.200.2`):

| Service | URL | Port |
|---------|-----|------|
| qBittorrent | http://10.200.200.2:8080 | 8080 |
| Prowlarr | http://10.200.200.2:9696 | 9696 |
| FlareSolverr | http://10.200.200.2:8191 | 8191 |

**Host Network** (access via `localhost`):

| Service | URL | Port |
|---------|-----|------|
| Radarr | http://localhost:7878 | 7878 |
| Sonarr | http://localhost:8989 | 8989 |
| Lidarr | http://localhost:8686 | 8686 |
| LazyLibrarian | http://localhost:5299 | 5299 |
| Jellyfin | http://localhost:8096 | 8096 |

---

## qBittorrent Optimization

Optimized settings for seeding thousands of torrents on the N5105.

### Kernel Network Tuning

```bash
sudo cp config/sysctl/99-torrent-optimizations.conf /etc/sysctl.d/
sudo sysctl -p /etc/sysctl.d/99-torrent-optimizations.conf
```

Key settings:

| Setting | Value | Purpose |
|---------|-------|---------|
| `net.core.rmem_max` | 16 MB | Larger receive buffers |
| `net.core.wmem_max` | 16 MB | Larger send buffers |
| `net.core.somaxconn` | 8192 | More pending connections |
| `fs.inotify.max_user_watches` | 524288 | Watch many files |

### qBittorrent Settings

Copy optimized config:

```bash
mkdir -p ~/.config/qBittorrent
cp config/qbittorrent/qBittorrent.conf ~/.config/qBittorrent/
sudo systemctl restart qbittorrent-vpn
```

Key optimizations:

| Setting | Value | Purpose |
|---------|-------|---------|
| **Memory** | | |
| `MemoryWorkingSetLimit` | 8192 MB | Use available RAM |
| **Queue Management** | | |
| `MaxActiveDownloads` | 5 | Focus on fewer downloads |
| `MaxActiveUploads` | 15 | Limit seeding during downloads |
| `MaxActiveTorrents` | 20 | Combined active limit |
| **Seeding Limits** | | |
| `MaxInactiveSeedingTime` | 24 hours | Remove if no upload activity |
| `MaxSeedingTime` | 7 days | Remove after 1 week |
| `MaxRatio` | 1.5 | Remove at 1.5x ratio |
| **Connections** | | |
| `MaxConnections` | 500 | Reduced for Celeron CPU |
| `MaxConnectionsPerTorrent` | 50 | Per-torrent limit |
| **Disk I/O** | | |
| `DiskCacheSize` | 2048 MB | Reduce disk thrashing |
| `AsyncIOThreadsCount` | 8 | Parallel I/O |
| `PreallocationMode` | 0 (sparse) | Faster for ZFS |

---

## Queue Management

Automatically prioritize healthy torrents over struggling ones.

### How It Works

The `qbit-queue-manager.py` script scores each torrent:

| Factor | Points | Description |
|--------|--------|-------------|
| Full availability (≥1.0) | +100 | Peers have complete files |
| Partial availability | +0-80 | Proportional to availability |
| No availability | -50 | Dead torrent |
| Seeders | +3 per seed (max 50) | More seeders = faster |
| Download speed >500 KB/s | +40 | Fast download |
| Download speed >100 KB/s | +25 | Moderate speed |
| Progress >90% | +30 | Almost done |
| Stalled state | -30 | No activity |
| Stuck on metadata | -40 | Can't start |

### Enable Queue Manager

```bash
# Runs every 30 minutes via timer
sudo systemctl enable --now qbit-queue-manager.timer

# Run manually
python3 ~/nas-media-server/scripts/qbit-queue-manager.py
```

### Sample Output

```
Score  Prog%  Seeds  Avail  KB/s     State        Name
-------------------------------------------------------------------
179    81.0   8      8.85   9896     downloading  Requiem for a Dream...
167    19.1   9      10.92  8750     downloading  Oppenheimer 2023...
-50    0.0    0      0.00   0        queuedDL     Dead.Torrent...
```

---

## Ratio Protection

Prevents torrents from uploading excessively in dead swarms.

### The Problem

In dead swarms, incomplete torrents keep sharing pieces indefinitely:
- Infinite upload on incomplete torrents
- Wasted bandwidth with no progress
- Torrents that will never complete

### Solution: qbt-ratio-guard.py

Runs every 15 minutes:
1. **Stops seeding** on incomplete torrents with ratio > 5x
2. **Logs warnings** for torrents approaching 3x ratio
3. **Flags dead swarms** (ratio > 10x AND availability < 50%)

### Thresholds

| Setting | Default | Description |
|---------|---------|-------------|
| `MAX_RATIO_INCOMPLETE` | 5.0 | Stop seeding incomplete above this |
| `MAX_RATIO_DEAD_SWARM` | 10.0 | Flag for manual removal |
| `MIN_AVAILABILITY_DEAD` | 0.5 | Combined with high ratio = dead |
| `NOTIFY_RATIO` | 3.0 | Log warning |

### Enable Ratio Guard

```bash
sudo systemctl enable --now qbt-ratio-guard.timer

# Run manually
./scripts/qbt-ratio-guard.py

# View logs
tail -f /var/log/qbt-ratio-guard.log
```

---

## Automation Scripts

### *arr Stack Configuration

```bash
# Configure all *arr apps with Prowlarr + qBittorrent
./scripts/configure-arr-stack.sh
```

This automatically:
- Adds FlareSolverr to Prowlarr
- Syncs all *arr apps with Prowlarr
- Configures qBittorrent as download client
- Sets up root folders

### Add Indexers

```bash
# Add 20+ public indexers to Prowlarr
./scripts/add-indexers.sh
```

Adds indexers including:
- **General**: The Pirate Bay, BitSearch, LimeTorrents, YTS
- **TV/Movies**: EZTV, Torrent9
- **Books**: InternetArchive
- **Anime**: Nyaa, TokyoTosho, Bangumi Moe

### Tracker Aggregation

```bash
# Add public trackers to stalled torrents
./scripts/add-trackers.sh
```

Fetches trackers from:
- ngosang/trackerslist
- XIU2/TrackersListCollection

### qBittorrent Auto-Restart

```bash
# Set up restart every 4 hours
sudo ./scripts/setup-qbt-restart-cron.sh
```

### Cron Schedule Summary

| Time | Task |
|------|------|
| Every 15 min | Ratio Guard |
| Every 30 min | Queue Manager |
| Every hour | Tracker Aggregator |
| Every 4 hours | Restart qBittorrent |
| Daily 04:00 | Restart all *arr services |

---

## Scripts Reference

### VPN Namespace Scripts

| Script | Description |
|--------|-------------|
| `vpn-namespace-setup.sh` | Create/manage VPN namespace |
| `qbt-vpn-start.sh` | Start qBittorrent + WireGuard with failover |
| `vpn-watchdog.sh` | Monitor VPN, auto-reconnect |
| `flaresolverr-start.sh` | Start FlareSolverr with Chromium |

### *arr Stack Scripts

| Script | Description |
|--------|-------------|
| `configure-arr-stack.sh` | Configure all apps |
| `add-indexers.sh` | Add public indexers |
| `install-arr-stack.sh` | Install *arr apps |

### qBittorrent Scripts

| Script | Description |
|--------|-------------|
| `qbit-queue-manager.py` | Prioritize healthy downloads |
| `qbt-ratio-guard.py` | Protect against ratio abuse |
| `add-trackers.sh` | Add public trackers |
| `restart-qbittorrent.sh` | Manual restart script |

---

## Related Documentation

| Doc | Description |
|-----|-------------|
| [VPN Guide](VPN.md) | VPN namespace setup |
| [Storage Guide](STORAGE.md) | ZFS and file sharing |
| [Troubleshooting](TROUBLESHOOTING.md) | Common issues |
