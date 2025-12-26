# NAS Media Server: Complete Build Guide

A comprehensive guide to building a self-hosted media server from scratch on Ubuntu 24.04 with ZFS storage, the *arr stack, qBittorrent (compiled from source with Qt 6.10.1), Jellyfin, LiveTV, and ProtonVPN integration.

## Table of Contents

1. [Overview](#overview)
2. [Hardware & Prerequisites](#hardware--prerequisites)
3. [Quick Rebuild](#quick-rebuild)
4. [Storage Setup (ZFS)](#storage-setup-zfs)
5. [ZFS Memory Tuning](#zfs-memory-tuning)
6. [Temperature Monitoring & Fan Control](#temperature-monitoring--fan-control)
7. [File Sharing (SMB/NFS/TFTP)](#file-sharing-smbnfstftp)
8. [Building OpenSSL 4.0 from Source](#building-openssl-40-from-source)
9. [Building Qt 6.10.1 from Source](#building-qt-6101-from-source)
10. [Building qBittorrent from Source](#building-qbittorrent-from-source)
11. [Installing the *arr Stack](#installing-the-arr-stack)
12. [Installing Jellyfin](#installing-jellyfin)
13. [Installing FlareSolverr](#installing-flaresolverr)
14. [ProtonVPN Setup with Split Tunneling](#protonvpn-setup-with-split-tunneling)
15. [Service Configuration](#service-configuration)
16. [qBittorrent Optimization](#qbittorrent-optimization-thousands-of-torrents)
17. [Queue Management](#queue-management)
18. [Automation Scripts](#automation-scripts)
19. [Security Considerations](#security-considerations)
20. [Troubleshooting](#troubleshooting)

---


## Overview

This guide documents building a complete media server that:

- **Downloads** via qBittorrent with VPN protection (ProtonVPN)
- **Manages** media with the *arr stack (Radarr, Sonarr, Lidarr, Prowlarr) + LazyLibrarian for books
- **Stores** everything on a ZFS RAIDZ2 pool for redundancy
- **Streams** via Jellyfin to any device
- **Protects** downloads with VPN namespace isolation (kill switch by design)

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              MEDIA SERVER                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                    VPN NAMESPACE (10.200.200.2)                     │   │
│   │                    All traffic → ProtonVPN WireGuard                │   │
│   │                    DNS → 10.2.0.1 (Proton DNS)                      │   │
│   │  ┌──────────────┐  ┌──────────────┐  ┌─────────────┐                │   │
│   │  │   Prowlarr   │  │ FlareSolverr │  │ qBittorrent │                │   │
│   │  │    :9696     │──│    :8191     │  │    :8080    │                │   │
│   │  │  (indexers)  │  │  (CF bypass) │  │ (downloads) │                │   │
│   │  └──────────────┘  └──────────────┘  └─────────────┘                │   │
│   └───────────────────────────┬─────────────────────────────────────────┘   │
│                               │ local network bypass                        │
│                               ▼ (10.200.40.0/24, 192.168.0.0/16)            │
│   HOST NETWORK                                                              │
│   ┌──────────┬──────────┬──────────┬───────────────┐                        │
│   │  Radarr  │  Sonarr  │  Lidarr  │ LazyLibrarian │                        │
│   │  :7878   │  :8989   │  :8686   │     :5299     │                        │
│   │ (Movies) │   (TV)   │ (Music)  │    (Books)    │                        │
│   └────┬─────┴────┬─────┴────┬─────┴───────┬───────┘                        │
│        │          │          │             │                                │
│        └──────────┴──────────┴─────────────┘                                │
│                        │                                                    │
│   STORAGE              ▼                                                    │
│                   /tank/media (ZFS RAIDZ2 - single dataset)                 │
│                   ├── downloads/    ←── qBittorrent saves here              │
│                   │   └── incomplete/                                       │
│                   │        │                                                │
│                   │        │ hardlinks (no duplication)                     │
│                   │        ▼                                                │
│                   ├── movies/       ←── organized library                   │
│                   ├── tv/                                                   │
│                   ├── music/                                                │
│                   ├── books/                                                │
│                   └── audiobooks/                                           │
│                               │                                             │
│   STREAMING                   ▼                                             │
│                         ┌──────────┐                                        │
│                         │ Jellyfin │                                        │
│                         │  :8096   │                                        │
│                         └──────────┘                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```


## Hardware & Prerequisites

### Hardware Used

This build uses the **ASUSTOR Flashstor 6 (FS6706T)**, a compact 6-bay all-flash NAS with some key upgrades.

#### Base Unit: ASUSTOR Flashstor 6 FS6706T

| Component | Specification |
|-----------|---------------|
| CPU | Intel Celeron N5105 @ 2.00GHz (4 cores, burst to 2.9GHz) |
| Architecture | Jasper Lake, 10nm |
| Base RAM | 4GB DDR4 (soldered) |
| Drive Bays | 6x M.2 NVMe slots (PCIe 3.0 x1 each) |
| Network | 2x 2.5 Gigabit Ethernet |
| USB | 3x USB 3.2 Gen1 |
| HDMI | 1x HDMI 2.0 (4K output) |
| Form Factor | Compact desktop |

#### Upgrades

| Upgrade | Part | Notes |
|---------|------|-------|
| **RAM** | PNY Performance 32GB (2x16GB) DDR4 3200MHz | Model: MD32GK2D4320016-TB, CL22. Compatible with 2933/2666/2400/2133MHz |
| **Boot Drive** | TEAM 512GB C212 USB 3.2 Gen2 Flash Drive | Model: TC2123512GB01. Running Ubuntu off USB |
| **NVMe Drives** | 5x Xiede XF-2TB2280 + 1x Timetec 2TB | Budget NVMe drives, ~$80-100 each |

## Quick Rebuild

To rebuild this environment from scratch on a fresh Ubuntu 24.04 installation. The username is anon and the network ip is 192.168.10.239/24.

### Rebuild Checklist

| Step | Command/Action | Automated? |
|------|----------------|------------|
| 1. Clone repository | `git clone ... ~/nas-media-server` | Manual |
| 2. Add WireGuard configs | Download from ProtonVPN | Manual |
| 3. Run rebuild script | `sudo ./rebuild.sh` | ✅ Auto |
| 4. Jellyfin setup wizard | http://localhost:8096 | Manual |
| 5. AdGuard setup wizard | http://localhost:3000 | Manual |
| 6. Run post-install | `./scripts/post-install.sh` | ✅ Auto |
| 7. Change passwords | Each app's settings | Manual |
| 8. Add private indexers | Prowlarr UI | Manual (optional) |

### Step-by-Step Instructions

### 1. Clone the Repository

```bash
git clone https://github.com/YOUR_USER/nas-media-server.git ~/nas-media-server
cd ~/nas-media-server
```

### 2. Get WireGuard Configs

Download WireGuard configs from [ProtonVPN](https://account.protonvpn.com/downloads#wireguard-configuration):
- Select **Linux** > **WireGuard**
- Choose **P2P-enabled servers** (required for port forwarding)
- Download 3-4 configs from different regions for failover

```bash
# Save configs to:
cp ~/Downloads/*.conf ~/nas-media-server/config/wireguard/servers/
```

### 3. Run Rebuild Script

```bash
sudo ./rebuild.sh
```

This installs all dependencies, builds qBittorrent from source, and configures all services.

### 4. Complete Setup Wizards

Before running post-install, complete these setup wizards:

```bash
# Open in browser:
# 1. Jellyfin: http://localhost:8096 (create admin user)
# 2. AdGuard Home: http://localhost:3000 (set password)
```

### 5. Run Post-Install Configuration

```bash
# Run as regular user (not root!)
./scripts/post-install.sh
```

This automatically configures:
- ✅ ZFS datasets (`/tank/media/*`)
- ✅ Download clients in all *arr apps → `10.200.200.2:8080`
- ✅ Root folders for movies, TV, music, etc.
- ✅ Prowlarr indexers (20+ public trackers)
- ✅ Prowlarr sync to all *arr apps
- ✅ Jellyfin media libraries
- ✅ LazyLibrarian qBittorrent connection

**Optional Environment Variables:**

Scripts support environment variables to customize defaults:

```bash
# qBittorrent credentials (for configure-arr-stack.sh, qbit-queue-manager.*)
export QB_USER="admin"
export QB_PASS="your_new_password"

# Prowlarr API key (for prowlarr-search.py, download-mobile-versions.py)
# Get from: Prowlarr → Settings → General → API Key
export PROWLARR_API_KEY="your_api_key"

# Network overrides (rarely needed)
export VPN_HOST="10.200.200.2"      # VPN namespace IP
export WAN_IF="eth0"                 # Override network interface detection
```

### 6. Manual Steps Required

These steps cannot be automated and must be done manually:

#### 6.1 Complete Setup Wizards (BEFORE post-install.sh)

**Jellyfin** - http://localhost:8096
1. Select language
2. Create admin username and password
3. Skip adding libraries (post-install.sh will do this)
4. Configure remote access settings
5. Finish wizard

**AdGuard Home** - http://localhost:3000
1. Click "Get Started"
2. Set admin interface port (default: 3000)
3. Set DNS server port (default: 53)
4. Create admin username and password
5. Configure upstream DNS (recommend: `9.9.9.9` and `1.1.1.1`)

#### 6.2 Change Default Passwords (AFTER post-install.sh)

| Service | Default Credentials | How to Change |
|---------|---------------------|---------------|
| qBittorrent | admin / adminadmin | Settings → Web UI → Authentication |
| Sonarr | none (first user) | Settings → General → Security |
| Radarr | none (first user) | Settings → General → Security |
| Lidarr | none (first user) | Settings → General → Security |
| Prowlarr | none (first user) | Settings → General → Security |
| LazyLibrarian | none | Config → Interface → HTTP Password |

#### 6.3 Add Private Indexers (Optional)

If you have accounts on private trackers:

1. Open Prowlarr: http://10.200.200.2:9696
2. Go to Indexers → Add Indexer
3. Search for your tracker
4. Enter your credentials/API key
5. Test and Save
6. Indexers sync automatically to all *arr apps

#### 6.4 Configure Quality Profiles (Optional)

Default profiles work for most users. To customize:

**Sonarr/Radarr:**
1. Settings → Profiles
2. Edit or create quality profile
3. Drag qualities to set preference order
4. Set cutoff (stops upgrading after this quality)

**Recommended Profiles:**
- **HD-1080p**: Good balance of quality and size
- **Ultra-HD**: 4K content (requires more storage)
- **Any**: Accept anything available

#### 6.5 Import Existing Media (Optional)

If you have existing media files:

**Sonarr (TV):**
1. Series → Import Existing Series
2. Browse to `/tank/media/tv`
3. Select series folders to import
4. Map to correct shows

**Radarr (Movies):**
1. Movies → Import Existing Movies
2. Browse to `/tank/media/movies`
3. Select movie folders to import
4. Map to correct movies

**Lidarr (Music):**
1. Artist → Import Existing
2. Browse to `/tank/media/music`
3. Select artist folders to import

### Environment-Specific Customization

If rebuilding on different hardware, check these files for hardcoded values:

| File | What to Check |
|------|---------------|
| `scripts/vpn-namespace-setup.sh` | Network interface auto-detected (override with `WAN_IF=eth0`) |
| `config/qbittorrent/qBittorrent.conf` | Download paths (`/tank/media/*`) |
| `config/lazylibrarian/config.ini` | Media paths, API keys |
| `configs/99-torrent-optimizations.conf` | Kernel tuning (adjust for RAM size) |

### Verify VPN Isolation

```bash
# Check namespace exists
sudo ip netns list
# Expected: vpn

# Verify VPN IP is different from host IP
sudo ip netns exec vpn curl -s https://api.ipify.org  # VPN IP
curl -s https://api.ipify.org                          # Host IP (should differ)

# Check services are accessible
curl -s http://10.200.200.2:8080/api/v2/app/version   # qBittorrent
curl -s http://10.200.200.2:9696/api/v1/health        # Prowlarr
```

---

### Network Isolation Strategy

The VPN namespace provides complete traffic isolation:

| Component | Network | DNS | ISP Visibility |
|-----------|---------|-----|----------------|
| qBittorrent | VPN Namespace | Proton (10.2.0.1) | Hidden - P2P traffic encrypted |
| Prowlarr | VPN Namespace | Proton (10.2.0.1) | Hidden - Indexer searches encrypted |
| FlareSolverr | VPN Namespace | Proton (10.2.0.1) | Hidden - Cloudflare bypass encrypted |
| Sonarr/Radarr/Lidarr | Host | System DNS | Visible but only metadata APIs (TVDB, TMDB) |
| Jellyfin | Host | System DNS | Visible - Media streaming |

Local networks (`10.200.40.0/24`, `192.168.0.0/16`, `172.16.0.0/12`) bypass the VPN for LAN access.

---

#### Why USB Boot?

The FS6706T has a small internal eMMC for the stock ADM OS. To run Linux:

1. **Back up the eMMC** following [Jeff Geerling's guide](https://www.jeffgeerling.com/blog/2023/how-i-installed-truenas-on-my-new-asustor-nas)
2. **Disable eMMC in BIOS** (Advanced → Storage Configuration → eMMC → Disabled)
3. **Set USB as first boot device**
4. **Install Ubuntu to USB drive** with ZFS root on the NVMe pool

This preserves the option to restore ADM later while giving full Linux control.

### Performance Benchmarks

Real-world benchmarks from this exact system:

#### ZFS Pool Performance (RAIDZ2, 6x NVMe)

| Test | Result | Notes |
|------|--------|-------|
| **Sequential Write** | 1.8 GB/s | `dd if=/dev/zero bs=1M count=4096` |
| **Sequential Read** | 4.0 GB/s | `dd if=testfile of=/dev/null bs=1M` |
| **IOPS (random)** | ~50,000+ | Limited by PCIe 3.0 x1 per slot |
| **Usable Capacity** | 7.3 TB | 6x 2TB in RAIDZ2 (can lose 2 drives) |

#### Network Performance

| Interface | Speed | Notes |
|-----------|-------|-------|
| bond0 | 2.5 Gbps | Primary network (bonded NICs) |
| veth-vpn | 1 Gbps | VPN namespace bridge |
| proton0 | ~200 Mbps | WireGuard tunnel (in VPN namespace) |

#### System Resources

| Metric | Value |
|--------|-------|
| Total RAM | 32 GB |
| Typical Usage | 17 GB (with all services) |
| CPU Load | 0.8 average (idle with services) |
| Power Draw | ~25-35W typical |

### Hardware Recommendations

**For similar builds:**

| Budget | Recommendation |
|--------|----------------|
| **CPU** | N5105/N6005 is plenty for transcoding-free streaming |
| **RAM** | 32GB recommended for ZFS ARC cache + services |
| **NVMe** | Mix brands/batches to reduce simultaneous failure risk |
| **Boot** | High-endurance USB 3.2 drive or small SATA SSD via adapter |
| **UPS** | Strongly recommended for ZFS - unclean shutdown can cause issues |

**Performance notes:**
- The N5105's Quick Sync handles 4K HEVC transcoding if needed
- Each M.2 slot is PCIe 3.0 x1 (~1GB/s max per drive)
- RAIDZ2 overhead + x1 lanes = real-world ~1.8GB/s write
- 2.5GbE is the bottleneck for network transfers (~300MB/s max)

### Base System

- **OS**: Ubuntu 24.04 LTS (installed to USB, ZFS root on NVMe pool)
- **Kernel**: 6.14.0+
- **Boot**: UEFI, USB 3.2 flash drive

### Required Packages

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Build essentials
sudo apt install -y build-essential cmake ninja-build git curl wget

# Qt6 build dependencies
sudo apt install -y \
    libgl1-mesa-dev \
    libvulkan-dev \
    libxcb-*-dev \
    libx11-xcb-dev \
    libxkbcommon-dev \
    libxkbcommon-x11-dev \
    libxrender-dev \
    libxi-dev \
    libfontconfig1-dev \
    libfreetype6-dev \
    libharfbuzz-dev \
    libicu-dev \
    libsqlite3-dev \
    libssl-dev \
    libpng-dev \
    libjpeg-dev \
    libzstd-dev \
    libb2-dev \
    libdouble-conversion-dev \
    libpcre2-dev \
    libglib2.0-dev \
    libdbus-1-dev \
    libudev-dev \
    libcups2-dev \
    libdrm-dev \
    libegl1-mesa-dev \
    libgbm-dev \
    libinput-dev \
    libmtdev-dev \
    libwayland-dev \
    libwayland-egl-backend-dev

# qBittorrent dependencies
sudo apt install -y \
    libtorrent-rasterbar-dev \
    libboost-all-dev \
    qtbase5-dev \
    qttools5-dev

# Python (for FlareSolverr)
sudo apt install -y python3 python3-pip python3-venv

# ZFS tools
sudo apt install -y zfsutils-linux
```

---

## Storage Setup (ZFS)

### Create RAIDZ2 Pool

```bash
# List available disks
lsblk

# Create RAIDZ2 pool with 6 drives (can lose 2 drives)
sudo zpool create -f tank raidz2 \
    /dev/nvme0n1 \
    /dev/nvme1n1 \
    /dev/nvme2n1 \
    /dev/nvme3n1 \
    /dev/nvme4n1 \
    /dev/nvme5n1

# Set mount point
sudo zfs set mountpoint=/tank tank

# Enable compression
sudo zfs set compression=lz4 tank

# Create datasets
sudo zfs create tank/torrents
sudo zfs create tank/media

# Verify
zpool status tank
zfs list
```

### Create Directory Structure

```bash
# Create media directories (single dataset for hardlinking)
sudo zfs create tank/media

sudo mkdir -p /tank/media/{movies,tv,music,books,audiobooks}
sudo mkdir -p /tank/media/downloads/{radarr,sonarr,lidarr,readarr,incomplete}

# Set ownership (replace 'anon' with your username)
sudo chown -R anon:anon /tank/media
```

**Important**: Downloads and library MUST be on the same filesystem for hardlinks to work. This setup uses `/tank/media/downloads/` for torrents and `/tank/media/{movies,tv,...}` for the organized library - all under one ZFS dataset.

---

## ZFS Memory Tuning

ZFS's ARC (Adaptive Replacement Cache) can consume most of your RAM by default. On a 32GB system, it may try to use 30GB+, leaving insufficient memory for applications.

### Limit ARC Size

```bash
# Check current ARC usage
cat /proc/spl/kstat/zfs/arcstats | grep -E "^size|^c_max" | awk '{print $1": "$3/1024/1024/1024" GB"}'

# Set permanent limit (8GB recommended for this system)
echo "options zfs zfs_arc_max=8589934592" | sudo tee /etc/modprobe.d/zfs.conf

# Apply immediately (full effect after reboot)
echo 8589934592 | sudo tee /sys/module/zfs/parameters/zfs_arc_max
```

### Recommended ARC Sizes

| Total RAM | ARC Max | Leaves for Apps |
|-----------|---------|-----------------|
| 32 GB | 8 GB | 24 GB |
| 16 GB | 4 GB | 12 GB |
| 8 GB | 2 GB | 6 GB |

**Why limit ARC?** Large file transfers (especially over SMB) combined with uncapped ARC cause memory pressure and swap thrashing, potentially freezing the system.

---

## Temperature Monitoring & Fan Control

The ASUSTOR Flashstor 6 uses an IT8625 chip for fan control. By default, fans may run too slow for heavy workloads (transcoding, downloading). This setup configures aggressive cooling.

### Install ASUSTOR Platform Driver

```bash
# Clone the driver
cd ~
git clone https://github.com/mafredri/asustor-platform-driver.git
cd asustor-platform-driver

# Build
make

# Install to kernel modules
sudo cp *.ko /lib/modules/$(uname -r)/kernel/drivers/hwmon/
sudo depmod -a

# Configure automatic loading at boot
echo -e "asustor\nasustor_it87" | sudo tee /etc/modules-load.d/asustor.conf

# Load now
sudo modprobe asustor
sudo modprobe asustor_it87
```

### Check Sensors

```bash
# View all temperatures and fan speeds
sensors

# Key readings:
# - coretemp (CPU): Target < 55°C for heavy workloads
# - it8625 (fan1): Main case fan
# - nvme: NVMe drive temps (should be < 50°C)
```

### Configure Maximum Fan Speed

For systems running heavy transcoding/download workloads, set fans to maximum:

```bash
# Find the PWM control (usually hwmon10 for it8625)
ls /sys/class/hwmon/*/name | while read f; do echo "$f: $(cat $f 2>/dev/null)"; done

# Set fan to 100% (255 PWM)
sudo sh -c 'echo 255 > /sys/class/hwmon/hwmon10/pwm1'

# Verify
sensors | grep fan1
```

### Persistent Fan Settings (Systemd)

Create a service to set fans to maximum at boot:

```bash
sudo tee /etc/systemd/system/asustor-fanmax.service << 'EOF'
[Unit]
Description=Set ASUSTOR fans to maximum
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for pwm in /sys/class/hwmon/*/pwm1; do [ -f "$pwm" ] && echo 255 > "$pwm"; done'

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable asustor-fanmax.service
```

### Temperature Targets

| Component | Target | Critical |
|-----------|--------|----------|
| CPU (coretemp) | < 55°C | 105°C |
| NVMe drives | < 50°C | 70°C |
| Network adapter | < 60°C | 120°C |

### Fan Speed Reference

| PWM Value | Speed | Use Case |
|-----------|-------|----------|
| 50 | ~20% (~1400 RPM) | Idle, quiet |
| 128 | ~50% (~2500 RPM) | Light load |
| 180 | ~70% (~3500 RPM) | Moderate load |
| 255 | 100% (~4300 RPM) | Heavy transcoding/downloads |

### Monitor Script

Quick script to monitor temps:

```bash
#!/bin/bash
# Save as ~/scripts/monitor-temps.sh
while true; do
    clear
    echo "=== Temperature Monitor ==="
    sensors | grep -E "Package|Core|fan1|Composite"
    sleep 5
done
```

---

## File Sharing (SMB/NFS/TFTP)

Cross-platform file sharing for ISOs, firmware, and general files.

### ZFS Dataset

```bash
# Create share dataset
sudo zfs create -o compression=lz4 tank/share
sudo zfs create tank/share/iso

# Create directory structure
sudo mkdir -p /tank/share/iso/{linux,windows,tools,firmware}
sudo chown -R anon:anon /tank/share
```

### Install Services

```bash
sudo apt install -y samba nfs-kernel-server tftpd-hpa
```

### SMB Configuration (Windows/Mac/Linux)

Add to `/etc/samba/smb.conf`:

```ini
[iso]
   comment = ISO Images and Tools
   path = /tank/share/iso
   browseable = yes
   read only = no
   guest ok = yes
   create mask = 0664
   directory mask = 0775
   force user = anon
   force group = anon
```

Restart: `sudo systemctl restart smbd nmbd`

### NFS Configuration (Linux/Mac - Faster)

Add to `/etc/exports`:

```
/tank/share/iso 192.168.10.0/24(rw,sync,no_subtree_check,no_root_squash,insecure)
```

Apply and restart:
```bash
sudo exportfs -ra
sudo systemctl restart nfs-server
```

### TFTP Configuration (Routers/Firmware)

Edit `/etc/default/tftpd-hpa`:

```
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="/tank/share/iso"
TFTP_ADDRESS=":69"
TFTP_OPTIONS="--secure --create"
```

Restart: `sudo systemctl restart tftpd-hpa`

### Access Methods

| Platform | Method | Example |
|----------|--------|---------|
| **Windows** | SMB | `\\192.168.10.239\iso` |
| **macOS** | SMB/NFS | Finder → ⌘K → `smb://192.168.10.239/iso` |
| **Linux** | NFS (fastest) | `sudo mount -t nfs 192.168.10.239:/tank/share/iso /mnt` |
| **Linux** | SMB | `sudo mount -t cifs //192.168.10.239/iso /mnt` |
| **rsync** | SSH (resumable) | `rsync -avhP file.iso anon@192.168.10.239:/tank/share/iso/` |
| **TFTP** | Firmware/routers | `tftp 192.168.10.239` then `get firmware/file.bin` |
| **HTTP** | Browser/wget/curl | `http://192.168.10.239/iso/` |

### Performance Comparison

| Method | Speed | Resume | Checksum | Best For |
|--------|-------|--------|----------|----------|
| **rsync** | Fast | Yes | Yes | Large files, unreliable networks |
| **NFS** | Fastest | No | No | Linux/Mac clients on LAN |
| **SMB** | Slow | No | No | Windows compatibility only |
| **HTTP** | Good | Yes* | No | One-way downloads |

**Recommendation**: Use rsync for large transfers (24GB+), NFS for LAN access, SMB only when Windows requires it.

### HTTP Downloads (nginx)

The ISO share is also available via HTTP with directory browsing:

```bash
# Symlink created at /var/www/nas-portal/iso -> /tank/share/iso
sudo ln -sf /tank/share/iso /var/www/nas-portal/iso
```

nginx config (`/etc/nginx/sites-available/nas-portal`):

```nginx
location /iso {
    alias /tank/share/iso;
    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;

    sendfile on;
    tcp_nopush on;
    client_max_body_size 0;
    add_header Accept-Ranges bytes;
}
```

Access via:
- **Browser**: `http://192.168.10.239/iso/`
- **wget**: `wget http://192.168.10.239/iso/linux/ubuntu.iso`
- **curl**: `curl -O http://192.168.10.239/iso/tools/gparted.iso`

---

## Building OpenSSL 4.0 from Source

qBittorrent with Qt 6.10.1 requires a newer OpenSSL than what ships with Ubuntu.

```bash
cd ~

# Clone OpenSSL
git clone https://github.com/openssl/openssl.git
cd openssl

# Check out a stable version
git checkout openssl-3.4.0  # or latest stable

# Configure
./Configure --prefix=/usr/local/ssl --openssldir=/usr/local/ssl shared

# Build (use all cores)
make -j$(nproc)

# Install
sudo make install

# Update library cache
echo "/usr/local/ssl/lib64" | sudo tee /etc/ld.so.conf.d/openssl.conf
sudo ldconfig

# Verify
/usr/local/ssl/bin/openssl version
```

---

## Building Qt 6.10.1 from Source

Qt 6.10.1 is required for the latest qBittorrent features.

### Download Qt Source

```bash
cd ~/Downloads

# Clone Qt (this takes a while)
git clone https://code.qt.io/qt/qt5.git qt6
cd qt6
git checkout v6.10.1

# Initialize submodules (only what we need)
perl init-repository --module-subset=qtbase,qttools,qtsvg,qtwayland
```

### Configure and Build

```bash
mkdir -p ~/Downloads/qt6-build
cd ~/Downloads/qt6-build

# Configure Qt
../qt6/configure \
    -prefix /usr/local/lib/qt6.10.1 \
    -release \
    -opensource \
    -confirm-license \
    -nomake examples \
    -nomake tests \
    -openssl-linked \
    -I /usr/local/ssl/include \
    -L /usr/local/ssl/lib64

# Build (this takes 1-2 hours)
cmake --build . --parallel $(nproc)

# Install
sudo cmake --install .

# Verify installation
ls /usr/local/lib/qt6.10.1/
```

---

## Building qBittorrent from Source

### Clone and Configure

```bash
cd ~

# Clone qBittorrent
git clone https://github.com/qbittorrent/qBittorrent.git
cd qBittorrent

# IMPORTANT: Use stable release, NOT alpha/master
# Alpha builds (5.2.0+) have authentication bugs with *arr apps
# See: https://github.com/qbittorrent/qBittorrent/issues/23270
git checkout release-5.1.4

# Create build directory
mkdir -p build-nox
cd build-nox

# Configure (headless version)
cmake -B . -S .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DGUI=OFF \
    -DCMAKE_PREFIX_PATH=/usr/local/lib/qt6.10.1/lib/cmake/
```

### Build

```bash
# Build
cmake --build . --parallel $(nproc)

# Verify
./qbittorrent-nox --version
# Should output: qBittorrent v5.1.4
```

### Install

```bash
# Copy binary
sudo cp qbittorrent-nox /usr/local/bin/

# Create config directory
mkdir -p ~/.config/qBittorrent
```

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

The Intel N5105 supports hardware-accelerated video transcoding via Quick Sync. This allows efficient HDR→SDR conversion and bitrate reduction when clients can't direct play.

#### Install VA-API Tools

```bash
sudo apt install -y vainfo intel-media-va-driver

# Verify Intel GPU capabilities
vainfo
```

#### N5105 Hardware Capabilities

| Codec | Decode | Encode | Notes |
|-------|--------|--------|-------|
| H.264 | Yes | CQP only | VBR not supported - Jellyfin incompatible |
| HEVC 8-bit | Yes | CQP only | VBR not supported - Jellyfin incompatible |
| HEVC 10-bit | Yes | CQP only | VBR not supported - Jellyfin incompatible |
| VP9 (all profiles) | Yes | No | |
| AV1 | No | No | |
| MPEG2 | Yes | No | |

**Note**: Hardware encoding is disabled because the N5105 only supports CQP (constant quality) mode, not VBR (variable bitrate) which Jellyfin requires for mobile streaming. Hardware decoding still works.

#### Configure Jellyfin User Permissions

```bash
# Add jellyfin to render and video groups
sudo usermod -aG render jellyfin
sudo usermod -aG video jellyfin

# Verify
groups jellyfin
# Should show: jellyfin video render
```

#### Optimized Encoding Configuration

The encoding config at `/etc/jellyfin/encoding.xml` should have these key settings:

```xml
<!-- Hardware acceleration type -->
<HardwareAccelerationType>qsv</HardwareAccelerationType>

<!-- GPU device paths -->
<VaapiDevice>/dev/dri/renderD128</VaapiDevice>
<QsvDevice>/dev/dri/renderD128</QsvDevice>

<!-- HDR to SDR tone mapping (hardware accelerated) -->
<EnableTonemapping>true</EnableTonemapping>
<EnableVppTonemapping>true</EnableVppTonemapping>

<!-- IMPORTANT: Low power mode disabled - causes rate control errors -->
<!-- See "Low Power Mode Issues" section below -->
<EnableIntelLowPowerH264HwEncoder>false</EnableIntelLowPowerH264HwEncoder>
<EnableIntelLowPowerHevcHwEncoder>false</EnableIntelLowPowerHevcHwEncoder>

<!-- Enable HEVC output (better compression) -->
<EnableHardwareEncoding>true</EnableHardwareEncoding>
<AllowHevcEncoding>true</AllowHevcEncoding>
<AllowAv1Encoding>false</AllowAv1Encoding>

<!-- All supported decode codecs -->
<HardwareDecodingCodecs>
  <string>h264</string>
  <string>hevc</string>
  <string>mpeg2video</string>
  <string>vc1</string>
  <string>vp8</string>
  <string>vp9</string>
</HardwareDecodingCodecs>
```

Full optimized config is at `configs/jellyfin-encoding.xml`.

#### Transcoding Capacity (N5105)

| Scenario | Simultaneous Streams |
|----------|---------------------|
| 4K HEVC → 1080p H.264 | 1-2 |
| 4K HEVC → 4K HEVC (bitrate only) | 2-3 |
| 1080p any → 1080p H.264 | 4-6 |
| HDR → SDR tone mapping | 1-2 |

#### When Transcoding Occurs

| Scenario | Result |
|----------|--------|
| Client supports codec + bandwidth | Direct Play (no CPU usage) |
| Client can't decode HEVC/HDR | Transcode to H.264 SDR |
| Low bandwidth (remote streaming) | Transcode to lower bitrate |
| PGS/ASS subtitles | Burn-in transcode required |
| SRT subtitles | Direct Play (text overlay) |

#### Best Practices

1. **Prefer Direct Play** - Configure clients for maximum quality
2. **Use SRT subtitles** - Avoids transcoding for subtitle burn-in
3. **Use native apps** - Web browsers always transcode; use Jellyfin apps
4. **Set client quality to Maximum** - Prevents unnecessary bitrate reduction

#### Intel N5105 Hardware Encoding Limitation

**IMPORTANT**: The Intel N5105 (Jasper Lake) does NOT support VBR (Variable Bit Rate) encoding via hardware. Both QSV and VAAPI drivers only support CQP (Constant Quantization Parameter) mode, but Jellyfin requires VBR for bandwidth-adaptive mobile streaming.

**Result**: Hardware encoding must be **disabled** on N5105. Software encoding (libx264) is used instead.

```xml
<!-- Hardware DECODING still works (fast) -->
<HardwareAccelerationType>vaapi</HardwareAccelerationType>

<!-- Hardware ENCODING disabled (N5105 doesn't support VBR) -->
<EnableHardwareEncoding>false</EnableHardwareEncoding>
```

**What still works with hardware acceleration:**
- Video decoding (HEVC, H.264, VP9, etc.) - GPU accelerated
- HDR to SDR tonemapping - GPU accelerated
- Only encoding falls back to CPU

**Performance impact:**
- 1 simultaneous transcode at ~50-80% CPU usage
- SD content (480p) transcodes fine
- 4K content will be slow but functional
- Direct play (no transcoding) is unaffected

---

#### Intel QSV Low Power Mode Issues (Reference)

**Problem**: Intel's "Low Power" encoder mode uses a specialized hardware path with limited rate control options. Jellyfin's default bitrate settings are incompatible, causing FFmpeg to fail with:

```
[h264_qsv] Selected ratecontrol mode is unsupported
[h264_qsv] Some encoding parameters are not supported under Low power mode
Error while opening encoder - maybe incorrect parameters such as bit_rate, rate, width or height
FFmpeg exited with code 218
```

**Symptoms**:
- Mobile playback fails (spins then returns to library)
- Works on local network (direct play) but fails remote (transcode required)
- All content affected, not just specific files

**Solution**: Disable low power mode in `/etc/jellyfin/encoding.xml`:

```xml
<EnableIntelLowPowerH264HwEncoder>false</EnableIntelLowPowerH264HwEncoder>
<EnableIntelLowPowerHevcHwEncoder>false</EnableIntelLowPowerHevcHwEncoder>
```

Then restart Jellyfin:
```bash
sudo systemctl restart jellyfin
```

**Trade-off**: Disabling low power mode uses the full QSV encoder which:
- Supports all rate control modes (VBR, CBR, etc.)
- Uses slightly more power (~1-2W difference)
- Has identical video quality
- Is recommended for NAS/server use

**When Low Power Mode Works**: Only with specific encoding parameters (CQP mode, fixed quality). Jellyfin uses VBR/target bitrate which is unsupported.

#### Verify Hardware Transcoding

During playback, check if hardware is being used:

```bash
# Watch for QSV processes
watch -n 1 'ps aux | grep -i ffmpeg'

# Check GPU utilization
sudo intel_gpu_top  # requires intel-gpu-tools package
```

In Jellyfin Dashboard → Playback, active transcodes show "(HW)" for hardware acceleration.

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

## ProtonVPN Setup with Split Tunneling

This setup uses a **network namespace** to completely isolate VPN traffic. Only qBittorrent, Prowlarr, and FlareSolverr run inside the VPN namespace - all other traffic (including SSH, web browsing, and *arr apps) stays on the normal network.

### Why Network Namespaces?

The ProtonVPN GUI's split tunneling doesn't work reliably on headless servers. Network namespaces provide:

- **Complete isolation**: VPN traffic is physically separated at the kernel level
- **No DNS leaks**: Namespace uses Proton's DNS (10.2.0.1) exclusively
- **Local network access**: Routes for LAN traffic bypass the VPN
- **Kill switch by design**: If VPN drops, namespace has no internet access

### Step 1: Download WireGuard Configs from Proton

1. Go to: https://account.protonvpn.com/downloads#wireguard-configuration
2. Select **Linux** as platform
3. Configure these settings (IMPORTANT):
   - **NetShield**: Level 2 (blocks malware + ads + trackers)
   - **Moderate NAT**: OFF (required for port forwarding to work)
   - **NAT-PMP (Port Forwarding)**: ON (required for torrent seeding)
   - **VPN Accelerator**: ON (improves speeds)
4. Choose **P2P-enabled servers** only (marked with P2P icon):

   **Recommended P2P Countries** (fast, privacy-friendly):
   | Country | Why | Server Examples |
   |---------|-----|-----------------|
   | Switzerland | Strong privacy laws, no data retention | CH-* servers |
   | Iceland | Very strong privacy protections | IS-* servers |
   | Netherlands | Good peering, P2P friendly | NL-* servers |
   | Sweden | Good speeds, privacy laws | SE-* servers |
   | Romania | No data retention laws | RO-* servers |

   **Avoid**: US, UK, Australia, New Zealand, Canada (Five Eyes surveillance)

5. Download 4-6 configs for redundancy (servers can go offline)
6. Save to: `config/wireguard/servers/`

```bash
# Example structure (recommended: mix of countries)
config/wireguard/
├── proton-template.conf  # Template showing config format
└── servers/              # Your downloaded configs go here
    ├── CH-NL-1.conf      # Switzerland via Netherlands (primary)
    ├── IS-DE-1.conf      # Iceland via Germany (backup)
    ├── SE-NL-1.conf      # Sweden via Netherlands (backup)
    └── CH-BE-2.conf      # Switzerland via Belgium (backup)
```

**Security Note**:
- WireGuard configs contain your private key - **never commit them to git!**
- The `.gitignore` already excludes `config/wireguard/servers/*.conf`
- See `config/wireguard/proton-template.conf` for the expected format

### Step 2: Set Up the VPN Namespace

```bash
# Create the namespace and networking
sudo ./scripts/vpn-namespace-setup.sh setup

# This creates:
# - Network namespace "vpn"
# - veth pair for host↔namespace communication
# - NAT rules for namespace internet access
# - Proton DNS configuration (10.2.0.1)
```

### Step 3: Install and Enable Services

```bash
# Copy service files
sudo cp configs/vpn-namespace.service /etc/systemd/system/
sudo cp configs/qbittorrent-vpn.service /etc/systemd/system/
sudo cp configs/prowlarr-vpn.service /etc/systemd/system/
sudo cp configs/flaresolverr-vpn.service /etc/systemd/system/

# Disable old services
sudo systemctl disable qbittorrent-nox prowlarr flaresolverr

# Enable new VPN namespace services
sudo systemctl daemon-reload
sudo systemctl enable vpn-namespace qbittorrent-vpn prowlarr-vpn flaresolverr-vpn
sudo systemctl start vpn-namespace qbittorrent-vpn prowlarr-vpn flaresolverr-vpn
```

### Step 4: Update Prowlarr Application URLs

Since Prowlarr now runs in the VPN namespace (10.200.200.2), update the *arr apps:

1. Open Prowlarr UI: http://10.200.200.2:9696
2. Go to **Settings → Apps**
3. For each app, update:
   - **Prowlarr Server**: `http://10.200.200.2:9696`
   - **App Server**: `http://10.200.200.1:<port>` (so Prowlarr can reach apps on host)
4. Click **Test** then **Save**

### Managing the VPN

```bash
# Check status
sudo ./scripts/qbt-vpn-start.sh status

# List available servers
sudo ./scripts/qbt-vpn-start.sh servers

# Switch to a specific server
sudo systemctl stop qbittorrent-vpn
sudo ./scripts/qbt-vpn-start.sh start CH-BE-2
# Or restart the service (auto-selects working server)
sudo systemctl restart qbittorrent-vpn

# Rotate to next server
sudo systemctl reload qbittorrent-vpn

# View logs
journalctl -u qbittorrent-vpn -u prowlarr-vpn -u flaresolverr-vpn -f
```

### Verify Split Tunnel is Working

```bash
# Check IPs are different
echo "Host IP: $(curl -s https://api.ipify.org)"
echo "VPN IP:  $(sudo ip netns exec vpn curl -s https://api.ipify.org)"

# Check DNS is using Proton
sudo ip netns exec vpn nslookup google.com
# Should show: Server: 10.2.0.1
```

---

## Service Configuration

**IMPORTANT**: All services run as system-level services (`/etc/systemd/system/`), not user services. This ensures they start at boot without requiring a user login.

### Install All Services

```bash
# Copy all service files
sudo cp configs/*.service /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable VPN namespace services (replaces old qbittorrent-nox, prowlarr, flaresolverr)
sudo systemctl enable --now \
    vpn-namespace \
    qbittorrent-vpn \
    prowlarr-vpn \
    flaresolverr-vpn \
    radarr \
    sonarr \
    lidarr \
    lazylibrarian \
    unpackerr
```

### Service Files Reference

All service files are in the `configs/` directory:

#### VPN Namespace Services (Protected Traffic)

These services run inside the VPN namespace for complete traffic isolation:

| Service | File | Description |
|---------|------|-------------|
| vpn-namespace | `vpn-namespace.service` | Creates/manages the VPN network namespace |
| qbittorrent-vpn | `qbittorrent-vpn.service` | qBittorrent in VPN namespace |
| prowlarr-vpn | `prowlarr-vpn.service` | Prowlarr in VPN namespace |
| flaresolverr-vpn | `flaresolverr-vpn.service` | FlareSolverr in VPN namespace |

#### Host Network Services

These run on the normal network (only talk to local services + legitimate APIs):

| Service | File | Description |
|---------|------|-------------|
| radarr | `radarr.service` | Movie manager |
| sonarr | `sonarr.service` | TV series manager |
| lidarr | `lidarr.service` | Music manager |
| lazylibrarian | `lazylibrarian.service` | Book/audiobook manager |
| unpackerr | `unpackerr.service` | Archive extractor |
| qbit-queue-manager | `qbit-queue-manager.timer` | Auto-prioritize healthy downloads |

#### System Services

| Service | Description |
|---------|-------------|
| smbd/nmbd | SMB file sharing |
| nfs-server | NFS file sharing |
| tftpd-hpa | TFTP for firmware/ISOs |

### Configuration Files Reference

| File | Target Location | Description |
|------|-----------------|-------------|
| `qBittorrent.conf` | `~/.config/qBittorrent/` | Optimized qBittorrent settings |
| `categories.json` | `~/.config/qBittorrent/` | Download categories for *arr apps |
| `unpackerr.conf` | `~/.config/unpackerr/` | Archive extraction config |
| `99-torrent-optimizations.conf` | `/etc/sysctl.d/` | Kernel network tuning |
| `jellyfin-encoding.xml` | `/etc/jellyfin/encoding.xml` | Hardware transcoding (Intel QSV) |

### Scripts Reference

#### VPN Namespace Scripts

| Script | Description |
|--------|-------------|
| `vpn-namespace-setup.sh` | Create/manage VPN network namespace with veth, NAT, and Proton DNS |
| `qbt-vpn-start.sh` | Start qBittorrent + WireGuard in namespace with server failover |
| `flaresolverr-start.sh` | Wrapper to start FlareSolverr with non-snap Chromium |

#### *arr Stack Scripts

| Script | Description |
|--------|-------------|
| `configure-arr-stack.sh` | Configure all *arr apps with Prowlarr + qBittorrent |
| `add-indexers.sh` | Add recommended public indexers to Prowlarr |
| `install-arr-stack.sh` | Download and install *arr applications |
| `install-flaresolverr.sh` | Install FlareSolverr for Cloudflare bypass |
| `restart-arr-services.sh` | Manual/cron script to restart all *arr services |
| `setup-arr-restart-cron.sh` | Setup daily restart cron for *arr services (04:00) |

#### qBittorrent Scripts

| Script | Description |
|--------|-------------|
| `restart-qbittorrent.sh` | Manual/cron script to restart qBittorrent |
| `setup-qbt-restart-cron.sh` | Setup auto-restart cron for qBittorrent (every 4h) |
| `qbit-queue-manager.py` | Prioritize healthy downloads over struggling ones |
| `apply-torrent-optimizations.sh` | Apply kernel + qBittorrent optimizations |

#### Build Scripts

| Script | Description |
|--------|-------------|
| `build-qbittorrent.sh` | Build qBittorrent from source |
| `build-qt6.sh` | Build Qt 6.10.1 from source |
| `build-openssl.sh` | Build OpenSSL from source |
| `install-dependencies.sh` | Install build dependencies |

#### Media Processing Scripts

| Script | Description |
|--------|-------------|
| `strip-audio-tracks.py` | Remove non-English audio tracks from MKV files (lossless) |
| `create-mobile-versions.py` | Transcode media for mobile devices |
| `download-mobile-versions.py` | Download mobile-optimized versions |
| `organize-mobile-downloads.py` | Organize mobile downloads into folders |

#### IPTV Scripts

| Script | Description |
|--------|-------------|
| `refresh-livetv.sh` | Full refresh: update EPG, M3U, and trigger Jellyfin guide refresh |
| `update-iptv.sh` | Update IPTV playlists and download service-specific EPGs |
| `update-epg.sh` | Update combined EPG from epghub sources |
| `filter-iptv-channels.py` | Filter unwanted IPTV channels |
| `match-epg-channels.py` | Match EPG data to channels |

#### Utility Scripts

| Script | Description |
|--------|-------------|
| `setup-services.sh` | Install all systemd services |
| `prowlarr-search.py` | Search Prowlarr indexers from command line |
| `calibre-metadata.sh` | Manage Calibre ebook metadata |

### Example Service File

All services follow this pattern (`radarr.service` example):

```ini
[Unit]
Description=Radarr Movie Manager
After=network.target

[Service]
Type=simple
User=anon
Group=anon
ExecStart=/opt/Radarr/Radarr -nobrowser -data=/home/anon/.config/Radarr
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Key points:
- `User=anon` and `Group=anon` - runs as your user, not root
- `After=network.target` - waits for network
- `Restart=on-failure` - auto-restart on crash
- `WantedBy=multi-user.target` - starts at boot

### Service Management Commands

```bash
# Check status of VPN namespace services
sudo systemctl status vpn-namespace qbittorrent-vpn prowlarr-vpn flaresolverr-vpn

# Check status of host services
sudo systemctl status radarr sonarr lidarr lazylibrarian

# Restart a single service
sudo systemctl restart radarr

# Stop all VPN services
sudo systemctl stop qbittorrent-vpn prowlarr-vpn flaresolverr-vpn

# View VPN service logs (live)
journalctl -u qbittorrent-vpn -u prowlarr-vpn -f

# View host service logs (last 100 lines)
journalctl -u radarr -n 100
```

---

## qBittorrent Optimization (Thousands of Torrents)

The default qBittorrent config is not optimized for seeding thousands of torrents. Apply these optimizations for the N5105 hardware.

### Kernel Network Tuning

Install kernel optimizations:

```bash
sudo cp configs/99-torrent-optimizations.conf /etc/sysctl.d/
sudo sysctl -p /etc/sysctl.d/99-torrent-optimizations.conf
```

Key settings in `99-torrent-optimizations.conf`:

| Setting | Value | Purpose |
|---------|-------|---------|
| `net.core.rmem_max` | 16 MB | Larger receive buffers |
| `net.core.wmem_max` | 16 MB | Larger send buffers |
| `net.core.somaxconn` | 8192 | More pending connections |
| `net.ipv4.tcp_max_syn_backlog` | 8192 | Handle connection bursts |
| `fs.inotify.max_user_watches` | 524288 | Watch many files |

### qBittorrent Config

Copy the optimized config:

```bash
mkdir -p ~/.config/qBittorrent
cp configs/qBittorrent.conf ~/.config/qBittorrent/
sudo systemctl restart qbittorrent-vpn
```

Key optimizations in `qBittorrent.conf`:

| Setting | Value | Purpose |
|---------|-------|---------|
| **Memory** | | |
| `MemoryWorkingSetLimit` | 8192 MB | Use available RAM |
| **Queue Management (Download Priority)** | | |
| `MaxActiveDownloads` | 5 | Focus on fewer downloads |
| `MaxActiveUploads` | 15 | Limit seeding during downloads |
| `MaxActiveTorrents` | 20 | Combined active limit |
| `UploadLimit` | 20 MB/s | Cap uploads for download priority |
| **Seeding Limits (Auto-cleanup)** | | |
| `MaxInactiveSeedingTime` | 24 hours | Remove if no upload activity |
| `MaxSeedingTime` | 7 days | Remove after seeding 7 days |
| `MaxRatio` | 1.5 | Remove after 1.5x upload ratio |
| `ActionOnLimits` | Remove torrent | Keeps files, removes from client |
| **Connections** | | |
| `MaxConnections` | 500 | Reduced for Celeron CPU |
| `MaxConnectionsPerTorrent` | 50 | Per-torrent limit |
| **Speed Scheduling** | | |
| `dl_limit` | 100 MB/s | Weekend download (800 Mbps) |
| `up_limit` | 12.5 MB/s | Weekend upload (100 Mbps) |
| `alt_dl_limit` | 37.5 MB/s | Weekday download (300 Mbps) |
| `alt_up_limit` | 6.25 MB/s | Weekday upload (50 Mbps) |
| `scheduler_enabled` | true | Enable scheduled limits |
| `scheduler_days` | 1 (Weekdays) | Alt speeds on Mon-Fri |
| **Disk I/O** | | |
| `DiskCacheSize` | 2048 MB | Reduce disk thrashing |
| `AsyncIOThreadsCount` | 8 | Parallel I/O |
| `FilePoolSize` | 100 | Limit open files |
| `CoalesceReadWriteEnabled` | true | Batch I/O ops |
| `PreallocationMode` | 0 (sparse) | Faster for ZFS |
| **Slow Torrent Detection** | | |
| `SlowTorrentThreshold` | 50 KB/s | Below this = "slow" |
| `DontCountSlowTorrents` | true | Slow torrents don't count against limits |

### Quick Apply Script

Run the optimization script:

```bash
./configs/apply-torrent-optimizations.sh
```

This will:
1. Stop qBittorrent
2. Apply kernel network optimizations
3. Install the system service
4. Start qBittorrent with optimized settings

### Validate Settings

```bash
# Note: qBittorrent runs in VPN namespace at 10.200.200.2
curl -s http://10.200.200.2:8080/api/v2/app/preferences | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('MaxActiveTorrents:', d['max_active_torrents'])
print('MaxConnections:', d['max_connec'])
print('DiskCache:', d['disk_cache'], 'MB')
"
```

---

## Queue Management

Automatically prioritize healthy torrents over struggling ones to ensure downloads complete.

### Queue Manager Script

The `qbit-queue-manager.py` script scores each torrent based on health metrics and reorders the queue:

**Scoring System:**

| Factor | Points | Description |
|--------|--------|-------------|
| Full availability (≥1.0) | +100 | Peers have complete files |
| Partial availability | +0-80 | Proportional to availability |
| No availability | -50 | Dead torrent, no peers |
| Seeders | +3 per seed (max 50) | More seeders = faster |
| Download speed >500 KB/s | +40 | Fast download |
| Download speed >100 KB/s | +25 | Moderate speed |
| Progress >90% | +30 | Almost done, finish it |
| Progress >50% | +15 | Halfway there |
| Stalled state | -30 | No activity |
| Stuck on metadata | -40 | Can't even start |
| Paused/stopped | -100 | Lowest priority |

### Install Queue Manager

```bash
# The script is at:
/home/anon/nas-media-server/scripts/qbit-queue-manager.py

# Run manually:
python3 /home/anon/nas-media-server/scripts/qbit-queue-manager.py

# Systemd timer runs every 30 minutes
sudo systemctl status qbit-queue-manager.timer
```

### Service Files

```bash
# Service (one-shot)
/etc/systemd/system/qbit-queue-manager.service

# Timer (every 30 min)
/etc/systemd/system/qbit-queue-manager.timer
```

### Sample Output

```
Score  Prog%  Seeds  Avail  KB/s     State        Name
----------------------------------------------------------------------------------------------------
179    81.0   8      8.85   9896     downloading  Requiem for a Dream 2000 2160p BluRay...
167    19.1   9      10.92  8750     downloading  Oppenheimer 2023 2160p EUR UHD...
-50    0.0    0      0.00   0        queuedDL     Dead.Torrent.With.No.Seeds...
-90    0.0    0      0.00   0        metaDL       Stuck.On.Metadata...
```

Healthy torrents (positive scores) move to the top; struggling ones (negative) sink to the bottom but remain queued for when peers become available.

---

## Automation Scripts

### *arr Stack Configuration

Run `scripts/configure-arr-stack.sh` to automatically:

- Add FlareSolverr to Prowlarr
- Sync all *arr apps with Prowlarr
- Configure qBittorrent as download client (credentials: admin/adminadmin)
- Set up root folders

**Note**: The script automatically reads API keys from each app's config file (`~/.config/<App>/config.xml`). No need to hardcode API keys - just ensure the apps are running before executing the script.

You can also set API keys via environment variables:
```bash
export PROWLARR_API="your-key"
export RADARR_API="your-key"
# etc.
./scripts/configure-arr-stack.sh
```

### Add Indexers Script

Run `scripts/add-indexers.sh` to automatically add recommended public indexers:

```bash
./scripts/add-indexers.sh
```

This adds 20+ public indexers including:
- **General**: The Pirate Bay, BitSearch, LimeTorrents, TorrentDownloads, MagnetDL, YTS
- **TV/Movies**: EZTV, Torrent9
- **Books**: InternetArchive
- **Anime**: Nyaa, TokyoTosho, Bangumi Moe, dmhy, Anidex
- **Linux**: LinuxTracker
- **Russian**: RuTor, RuTracker.RU, NoNaMe Club
- **French**: OxTorrent, ZkTorrent

CloudFlare-protected sites (1337x, KickassTorrents, etc.) require FlareSolverr and may need to be added manually through the Prowlarr UI.

### Unpackerr (Archive Extraction)

Unpackerr automatically extracts downloaded archives for *arr apps.

1. Copy and edit the config:
```bash
cp configs/unpackerr.conf ~/.config/unpackerr/
# Edit to add your API keys
nano ~/.config/unpackerr/unpackerr.conf
```

2. Enable the service:
```bash
sudo systemctl enable --now unpackerr
```

### qBittorrent Categories

Copy `configs/categories.json` to set up download categories for each *arr app:

```bash
cp configs/categories.json ~/.config/qBittorrent/
sudo systemctl restart qbittorrent-vpn
```

This creates separate download folders for each app:
- `/tank/media/downloads/radarr` - Movies
- `/tank/media/downloads/sonarr` - TV Shows
- `/tank/media/downloads/lidarr` - Music
- `/tank/media/downloads/readarr` - Books

### qBittorrent Auto-Restart (Cron)

qBittorrent can accumulate CPU/memory usage over time with many torrents. Set up automatic restarts every 4 hours to prevent issues:

```bash
sudo ./scripts/setup-qbt-restart-cron.sh
```

This script:
1. Installs restart script to `~/.local/bin/restart-qbittorrent.sh`
2. Creates passwordless sudo rule for `systemctl restart qbittorrent-vpn.service`
3. Adds cron job running at 0:00, 4:00, 8:00, 12:00, 16:00, 20:00

**Logs:** `~/.local/log/qbt-restart.log`

### *arr Services Daily Restart (Cron)

Restart all *arr services daily at 04:00 to prevent memory buildup:

```bash
sudo ./scripts/setup-arr-restart-cron.sh
```

This script:
1. Installs restart script to `~/.local/bin/restart-arr-services.sh`
2. Creates passwordless sudo rules for all services
3. Adds cron job running daily at 04:00

**Services restarted:** Radarr, Sonarr, Lidarr, Readarr, Prowlarr, FlareSolverr, Unpackerr

**Logs:** `~/.local/log/arr-restart.log`

### Cron Schedule Summary

| Time | Task |
|------|------|
| Every 4 hours | Restart qBittorrent |
| Daily 04:00 | Restart all *arr services |

---

## Security Considerations

### Default Credentials (CHANGE THESE!)

| Service | Default Login |
|---------|---------------|
| qBittorrent | admin / admin |
| Radarr | (set during first run) |
| Sonarr | (set during first run) |
| Lidarr | (set during first run) |
| Prowlarr | (set during first run) |
| Readarr | (set during first run) |
| Jellyfin | (set during wizard) |

**Note**: The *arr apps now require setting up authentication during first run. qBittorrent password has been set to `admin`.

### qBittorrent Security Settings

qBittorrent runs in the VPN namespace, so all traffic is automatically routed through WireGuard. No interface binding is required.

Edit `~/.config/qBittorrent/qBittorrent.conf`:

```ini
[BitTorrent]
Session\Encryption=1               # Require encryption
Session\Anonymous=true             # Anonymous mode

[Preferences]
WebUI\LocalHostAuth=false         # For local access
WebUI\AuthSubnetWhitelist=192.168.0.0/16, 10.200.200.0/24
WebUI\AuthSubnetWhitelistEnabled=true
```

**Note**: The `10.200.200.0/24` subnet is for the VPN namespace bridge, allowing *arr apps on the host to communicate with qBittorrent.

### Firewall (UFW)

```bash
# Allow local access only
sudo ufw allow from 192.168.0.0/16 to any port 8080  # qBittorrent
sudo ufw allow from 192.168.0.0/16 to any port 7878  # Radarr
sudo ufw allow from 192.168.0.0/16 to any port 8989  # Sonarr
sudo ufw allow from 192.168.0.0/16 to any port 8686  # Lidarr
sudo ufw allow from 192.168.0.0/16 to any port 8787  # Readarr
sudo ufw allow from 192.168.0.0/16 to any port 9696  # Prowlarr
sudo ufw allow from 192.168.0.0/16 to any port 8096  # Jellyfin

sudo ufw enable
```

---

## Troubleshooting

### qBittorrent Shows "Firewalled"

1. Check ProtonVPN port forwarding is enabled
2. Verify the port matches: `journalctl -b -g "external_port:"`
3. Update qBittorrent port in settings
4. Restart qBittorrent

### Downloads Not Starting

1. Check VPN namespace is up: `sudo ip netns list`
2. Check WireGuard is connected: `sudo ip netns exec vpn wg show`
3. Verify VPN has internet: `sudo ip netns exec vpn curl -s https://api.ipify.org`
4. Check qBittorrent logs: `journalctl -u qbittorrent-vpn -f`
5. Try rotating to another server: `sudo systemctl reload qbittorrent-vpn`

### VPN Namespace Troubleshooting

The VPN namespace isolates torrent traffic from the host network. All services that need VPN protection run inside this namespace at `10.200.200.2`.

#### Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│  HOST NETWORK (default namespace)                            │
│  IP: 10.200.200.1 (veth-host)                                │
│                                                              │
│  Services: Sonarr, Radarr, Lidarr, Jellyfin, LazyLibrarian   │
│  Can reach VPN namespace via 10.200.200.2                    │
└─────────────────────────┬────────────────────────────────────┘
                          │ veth pair
┌─────────────────────────▼────────────────────────────────────┐
│  VPN NAMESPACE (/run/netns/vpn)                              │
│  IP: 10.200.200.2 (veth-vpn)                                 │
│  Default route → WireGuard tunnel (proton0)                  │
│                                                              │
│  Services: qBittorrent (:8080), Prowlarr (:9696),            │
│            FlareSolverr (:8191)                              │
│  DNS: 10.2.0.1 (Proton DNS - no leaks)                       │
└──────────────────────────────────────────────────────────────┘
```

#### Quick Diagnostic Commands

```bash
# 1. Check if namespace exists
sudo ip netns list
# Expected: vpn

# 2. Check veth pair connectivity
ip addr show veth-host
# Expected: 10.200.200.1/24

sudo ip netns exec vpn ip addr show veth-vpn
# Expected: 10.200.200.2/24

# 3. Ping between namespaces
ping -c 2 10.200.200.2
# Expected: replies from 10.200.200.2

sudo ip netns exec vpn ping -c 2 10.200.200.1
# Expected: replies from 10.200.200.1

# 4. Check WireGuard tunnel status
sudo ip netns exec vpn wg show
# Expected: Shows peer, endpoint, latest handshake, transfer stats

# 5. Verify VPN IP (should NOT be your home IP)
sudo ip netns exec vpn curl -s https://api.ipify.org
# Expected: ProtonVPN exit IP (not your ISP IP)

# 6. Check DNS resolution in namespace
sudo ip netns exec vpn nslookup google.com
# Expected: Response from 10.2.0.1 (Proton DNS)

# 7. Check all services in namespace are running
systemctl status vpn-namespace qbittorrent-vpn prowlarr-vpn flaresolverr-vpn

# 8. Check service accessibility from host
curl -s http://10.200.200.2:8080/api/v2/app/version    # qBittorrent
curl -s http://10.200.200.2:9696/api/v1/health         # Prowlarr
curl -s http://10.200.200.2:8191/health                # FlareSolverr
```

#### Common Issues and Fixes

**Issue: Namespace doesn't exist**
```bash
sudo ip netns list
# Empty or no "vpn"

# Fix: Restart namespace service
sudo systemctl restart vpn-namespace
sudo systemctl status vpn-namespace
```

**Issue: WireGuard not connected (no handshake)**
```bash
sudo ip netns exec vpn wg show
# Shows "latest handshake: (none)" or old timestamp

# Fix: Rotate to different VPN server
sudo systemctl reload qbittorrent-vpn
# This triggers server rotation in qbt-vpn-start.sh

# Or manually select a server:
ls ~/nas-media-server/config/wireguard/servers/
sudo cp ~/nas-media-server/config/wireguard/servers/CH-NL-2.conf /etc/wireguard/vpn/active.conf
sudo ip netns exec vpn wg-quick down proton0 2>/dev/null; sudo ip netns exec vpn wg-quick up proton0
```

**Issue: Can't reach 10.200.200.2 from host**
```bash
ping 10.200.200.2
# Network unreachable or no reply

# Check veth interfaces exist
ip link show veth-host
sudo ip netns exec vpn ip link show veth-vpn

# Fix: Recreate namespace
sudo systemctl restart vpn-namespace
```

**Issue: Services not binding to namespace IP**
```bash
# Check what's listening in namespace
sudo ip netns exec vpn ss -tlnp

# Expected output should show:
# *:8080  (qBittorrent)
# *:9696  (Prowlarr)
# *:8191  (FlareSolverr)

# If service missing, check its status
journalctl -u qbittorrent-vpn -n 50
journalctl -u prowlarr-vpn -n 50
```

**Issue: VPN has no internet (tunnel down)**
```bash
sudo ip netns exec vpn curl -s --max-time 5 https://api.ipify.org
# Timeout or error

# Check WireGuard interface
sudo ip netns exec vpn ip addr show proton0
# Should have an IP like 10.2.0.x

# Check routing
sudo ip netns exec vpn ip route
# Should show: default via proton0, local network via veth-vpn

# Fix: Bring WireGuard back up
sudo ip netns exec vpn wg-quick up proton0
```

**Issue: DNS leaking (queries going to ISP)**
```bash
# Check DNS config in namespace
sudo ip netns exec vpn cat /etc/resolv.conf
# Should show: nameserver 10.2.0.1 (Proton DNS)

# If wrong, the namespace setup script should fix it
sudo systemctl restart vpn-namespace
```

#### Full Namespace Reset

If all else fails, do a complete reset:

```bash
# Stop all VPN namespace services
sudo systemctl stop flaresolverr-vpn prowlarr-vpn qbittorrent-vpn vpn-namespace

# Kill any orphaned processes in namespace
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
curl -s http://10.200.200.2:8080/api/v2/app/version && echo " (qBittorrent)"
```

#### Checking Which Namespace a Process is In

```bash
# Find process PID
pgrep -f qbittorrent-nox
# Example: 12345

# Check its network namespace
sudo ls -la /proc/12345/ns/net
# Should show -> /run/netns/vpn

# Or check its external IP
sudo nsenter --net=/proc/12345/ns/net curl -s https://api.ipify.org
# Should return VPN IP, not your home IP
```

#### Port Forwarding (NAT-PMP)

For better torrent connectivity, request a forwarded port:

```bash
# Request port from ProtonVPN
sudo ip netns exec vpn natpmpc -g 10.2.0.1

# Get assigned port
sudo ip netns exec vpn natpmpc -a 0 0 udp 60 -g 10.2.0.1
sudo ip netns exec vpn natpmpc -a 0 0 tcp 60 -g 10.2.0.1
# Note the "public port" in output

# Update qBittorrent to use this port
# Settings → Connection → Listening Port
```

### *arr Apps Can't Connect to qBittorrent

**Common Error:** "All download clients are unavailable due to failures" or "Unable to communicate with qBittorrent"

**Root Cause:** The *arr apps are configured to connect to `localhost:8080`, but qBittorrent runs in the VPN namespace and is only accessible at `10.200.200.2:8080`.

**Fix via API (recommended):**
```bash
# Fix Sonarr
SONARR_API=$(grep -oP '(?<=<ApiKey>)[^<]+' ~/.config/Sonarr/config.xml)
curl -s "http://localhost:8989/api/v3/downloadclient" -H "X-Api-Key: $SONARR_API" | \
  python3 -c "import sys,json; clients=json.load(sys.stdin); [print(f\"ID {c['id']}: {c['name']} -> host={[f['value'] for f in c['fields'] if f['name']=='host'][0]}\") for c in clients]"

# Fix Radarr
RADARR_API=$(grep -oP '(?<=<ApiKey>)[^<]+' ~/.config/Radarr/config.xml)
# Same pattern...

# Fix Lidarr
LIDARR_API=$(grep -oP '(?<=<ApiKey>)[^<]+' ~/.config/Lidarr/config.xml)
# Same pattern...
```

**Fix via UI:**
1. Open the *arr app (Sonarr/Radarr/Lidarr)
2. Go to Settings → Download Clients
3. Click on qBittorrent
4. Change **Host** from `localhost` to `10.200.200.2`
5. Ensure **Remove Completed** is enabled (prevents torrent buildup)
6. Click Test, then Save

**Required Settings for all *arr apps:**

| Setting | Value | Why |
|---------|-------|-----|
| Host | `10.200.200.2` | VPN namespace IP (not localhost) |
| Port | `8080` | qBittorrent WebUI port |
| Remove Completed Downloads | `true` | Prevents disk/queue bloat |
| Remove Failed Downloads | `true` | Cleans up failed items |

**Verification:**
```bash
# Test qBittorrent is accessible
curl -s http://10.200.200.2:8080/api/v2/app/version
# Should return: v5.1.4

# Check from VPN namespace
sudo ip netns exec vpn curl -s http://127.0.0.1:8080/api/v2/app/version
```

### *arr Apps Can't Connect to Prowlarr

1. Verify Prowlarr is running: `systemctl status prowlarr-vpn`
2. Check Prowlarr URL is `http://10.200.200.2:9696` in *arr app settings
3. Verify namespace routing: `curl http://10.200.200.2:9696`
4. Check Prowlarr app settings point to correct URLs:
   - Prowlarr Server: `http://10.200.200.2:9696`
   - Sonarr Server: `http://10.200.200.1:8989`
   - Radarr Server: `http://10.200.200.1:7878`

### DNS Leaks (Torrent Site Queries Visible to ISP)

If indexer searches are leaking to your ISP:

1. Verify Prowlarr is running in VPN namespace (NOT host):
   ```bash
   # Should show prowlarr-vpn.service, NOT prowlarr.service
   systemctl status prowlarr-vpn

   # Prowlarr's external IP should match VPN, not host
   sudo nsenter --net=/proc/$(pgrep -f Prowlarr)/ns/net curl -s ifconfig.me
   ```

2. If Prowlarr is on host network, switch to VPN service:
   ```bash
   sudo systemctl stop prowlarr
   sudo systemctl disable prowlarr
   sudo systemctl enable prowlarr-vpn
   sudo systemctl start prowlarr-vpn
   ```

3. Update Prowlarr application URLs in Prowlarr Settings → Apps:
   - Prowlarr Server: `http://10.200.200.2:9696`
   - App Servers: `http://10.200.200.1:<port>`

### Indexer Unavailable Errors (Prowlarr)

Common causes:
- **Site is down**: Some indexers (e.g., EBookBay) go offline permanently. Disable them in Prowlarr.
- **Cloudflare protection**: Ensure FlareSolverr is running and configured in Prowlarr.
- **DNS issues**: Check if the indexer domain resolves: `host <domain>`

To reset a failed indexer status:
```bash
# Via Prowlarr API (replace API_KEY and INDEXER_ID)
curl -X DELETE "http://localhost:9696/api/v1/indexerstatus/INDEXER_ID" \
  -H "X-Api-Key: YOUR_API_KEY"
```

**Recommended book indexers** (since EBookBay is dead):
- InternetArchive (legal, free books)
- The Pirate Bay (general tracker with books)
- BitSearch (meta-search)
- TorrentDownloads (general tracker)
- Torrent9 (general tracker)
- LimeTorrents (general tracker)
- Nyaa (anime/manga/light novels)

**Currently configured indexers** (26 total, 24 enabled):
- General: EZTV, MagnetDL, YTS, LinuxTracker, ShowRSS, RuTor
- Books: BitSearch, InternetArchive, The Pirate Bay, TorrentDownloads, Torrent9, LimeTorrents, Nyaa
- Anime/Asian: Nyaa, Bangumi Moe, BigFANGroup, dmhy, TokyoTosho, U3C3, Anidex
- Russian: NoNaMe Club, NorTorrent, RuTracker.RU, UzTracker
- French: OxTorrent, ZkTorrent

### Qt/OpenSSL Library Issues

```bash
# Verify library path
export LD_LIBRARY_PATH=/usr/local/lib/qt6.10.1/lib:$LD_LIBRARY_PATH
ldd /usr/local/bin/qbittorrent-nox
```

---

## Quick Reference

### Service URLs

**VPN Namespace Services** (access via namespace IP):

| Service | URL | Port | Notes |
|---------|-----|------|-------|
| qBittorrent | http://10.200.200.2:8080 | 8080 | VPN protected |
| Prowlarr | http://10.200.200.2:9696 | 9696 | VPN protected |
| FlareSolverr | http://10.200.200.2:8191 | 8191 | VPN protected |

**Host Network Services** (access via localhost or LAN IP):

| Service | URL | Port |
|---------|-----|------|
| Radarr | http://localhost:7878 | 7878 |
| Sonarr | http://localhost:8989 | 8989 |
| Lidarr | http://localhost:8686 | 8686 |
| LazyLibrarian | http://localhost:5299 | 5299 |
| Jellyfin | http://localhost:8096 | 8096 |

### Service Commands

```bash
# Check all VPN namespace services
for svc in vpn-namespace qbittorrent-vpn prowlarr-vpn flaresolverr-vpn; do
    echo "$svc: $(systemctl is-active $svc)"
done

# Check all host services
for svc in radarr sonarr lidarr lazylibrarian unpackerr jellyfin; do
    echo "$svc: $(systemctl is-active $svc)"
done

# Restart VPN namespace services
sudo systemctl restart vpn-namespace qbittorrent-vpn prowlarr-vpn flaresolverr-vpn

# Restart host services
sudo systemctl restart radarr sonarr lidarr lazylibrarian unpackerr

# View VPN namespace logs (live)
journalctl -u qbittorrent-vpn -u prowlarr-vpn -u flaresolverr-vpn -f

# View host service logs
journalctl -u radarr -u sonarr -u lidarr -u lazylibrarian -f

# Verify VPN isolation (IPs should be different)
echo "Host IP: $(curl -s https://api.ipify.org)"
echo "VPN IP:  $(sudo ip netns exec vpn curl -s https://api.ipify.org)"
```

### Storage Paths

```
/tank/media/                    # Single ZFS dataset (enables hardlinks)
├── downloads/                  # qBittorrent downloads here
│   ├── incomplete/             # Incomplete downloads
│   ├── radarr/                 # Category folders (optional)
│   ├── sonarr/
│   ├── lidarr/
│   └── lazylibrarian/
├── movies/                     # Organized library (hardlinked from downloads)
├── tv/
├── music/
├── books/
└── audiobooks/
```

**Why single dataset?** Hardlinks only work within the same filesystem. With downloads and library under `/tank/media/`, Sonarr/Radarr can hardlink instead of copy, saving disk space.

---

## Configuration Backup & Rebuild

All configuration files are stored in `config/` with sensitive data anonymized:

```
config/
├── systemd/              # All custom systemd services and timers
│   ├── vpn-namespace.service      # VPN network namespace
│   ├── qbittorrent-vpn.service    # qBittorrent in VPN namespace
│   ├── prowlarr-vpn.service       # Prowlarr in VPN namespace
│   ├── flaresolverr-vpn.service   # FlareSolverr in VPN namespace
│   ├── livetv-update.service      # IPTV/EPG update service
│   ├── livetv-update.timer        # Twice-daily update timer
│   ├── sonarr.service
│   ├── radarr.service
│   ├── lidarr.service
│   ├── lazylibrarian.service
│   ├── unpackerr.service
│   └── ...
├── nginx/                # nginx site configurations
│   ├── nas-portal        # Main portal (port 80)
│   └── livetv            # Live TV files (port 8888)
├── jellyfin/             # Jellyfin configuration
│   ├── livetv.xml        # Live TV tuners and EPG providers
│   └── jellyfin.service.conf
├── arr-stack/            # *arr app configs (API keys anonymized)
│   ├── sonarr-config.xml
│   ├── radarr-config.xml
│   ├── lidarr-config.xml
│   └── prowlarr-config.xml
├── qbittorrent/          # qBittorrent config (password anonymized)
│   └── qBittorrent.conf
├── adguard/              # AdGuard Home config (password anonymized)
│   └── AdGuardHome.yaml
├── samba/                # File sharing configs
│   ├── smb.conf
│   └── exports           # NFS exports
├── wireguard/            # VPN WireGuard configs
│   ├── servers/          # ProtonVPN WireGuard configs (download from Proton)
│   │   ├── SE-NL-1.conf
│   │   ├── CH-BE-2.conf
│   │   ├── IS-DE-1.conf
│   │   └── ...           # Multiple for failover
│   └── active.conf       # Currently active server (auto-managed)
├── unpackerr/            # Archive extraction config
│   └── unpackerr.conf
└── lazylibrarian/        # Book manager config
    └── config.ini
```

### Quick Rebuild

```bash
# 1. Clone this repo
git clone <repo-url> ~/nas-media-server
cd ~/nas-media-server

# 2. Run the rebuild script
sudo ./rebuild.sh

# 3. Replace placeholder values in configs:
#    - YOUR_API_KEY_HERE
#    - YOUR_PASSWORD_HERE
#    - YOUR_PRIVATE_KEY_HERE (WireGuard)
```

### Backup Current System

To update the config backup from a running system:

```bash
cd ~/nas-media-server

# Copy systemd services (VPN namespace + host services)
sudo cp /etc/systemd/system/{vpn-namespace,qbittorrent-vpn,prowlarr-vpn,flaresolverr-vpn,sonarr,radarr,lidarr,lazylibrarian,unpackerr,livetv-update}.{service,timer} config/systemd/ 2>/dev/null

# Copy nginx configs
sudo cp /etc/nginx/sites-available/{nas-portal,livetv} config/nginx/

# Copy Jellyfin config
sudo cp /etc/jellyfin/livetv.xml config/jellyfin/

# Anonymize and commit
git add -A && git commit -m "Update configs"
```

---

## Live TV Setup

Jellyfin Live TV with 5 streaming services (~2,500 channels):

| Service | Channels | M3U Source | EPG Source |
|---------|----------|------------|------------|
| Pluto TV | 417 | Local (nginx) | https://i.mjh.nz/PlutoTV/us.xml |
| Samsung TV Plus | 542 | Local (nginx) | https://i.mjh.nz/SamsungTVPlus/us.xml |
| Plex | 684 | Local (nginx) | https://i.mjh.nz/Plex/us.xml |
| Roku | 692 | Local (nginx) | https://i.mjh.nz/Roku/all.xml |
| Stirr | 147 | Local (nginx) | https://i.mjh.nz/Stirr/all.xml |

### How It Works

1. **EPG data** comes directly from i.mjh.nz (auto-updating)
2. **M3U playlists** are generated locally from EPG (channel IDs must match)
3. **Stream URLs** use jmp2.uk proxy service
4. Files served via nginx at `http://<IP>:8888/livetv/`

### EPG Providers in Jellyfin

Jellyfin is configured with XMLTV EPG providers for each streaming service:

| Service | Tuner ID | EPG URL |
|---------|----------|---------|
| Pluto TV | 806d5ea8... | http://192.168.10.239:8888/livetv/epg/pluto-us.xml |
| Samsung TV Plus | d5f28095... | http://192.168.10.239:8888/livetv/epg/samsungtvplus.xml |
| Plex | cbe57787... | http://192.168.10.239:8888/livetv/epg/plex.xml |
| Roku | b179faed... | http://192.168.10.239:8888/livetv/epg/roku.xml |
| Stirr | deec9ac9... | http://192.168.10.239:8888/livetv/epg/stirr.xml |

Config: `/etc/jellyfin/livetv.xml` (backed up to `config/jellyfin/livetv.xml`)

### Automated Updates

- `livetv-update.timer` runs at 4:00 AM and 4:00 PM (twice daily)
- Downloads fresh EPG data from i.mjh.nz
- Regenerates M3U files from EPG
- Ensures channel IDs match for guide data

### Manual Refresh

```bash
# Full refresh (recommended) - updates EPG, M3U, and triggers Jellyfin refresh
/home/anon/nas-media-server/scripts/refresh-livetv.sh

# Or run individual steps:
/home/anon/nas-media-server/scripts/update-iptv.sh   # Update M3U + service EPGs
/home/anon/nas-media-server/scripts/update-epg.sh    # Update combined EPG sources
```

**To view the TV Guide:**
1. Open Jellyfin → click "Live TV" in sidebar
2. Click "Guide" tab at the top
3. Browse the programme grid

**If guide data still doesn't appear:**
1. Go to Jellyfin Dashboard → Live TV
2. Click "TV Guide Data Providers"
3. Click refresh icon for each provider
4. Wait 2-3 minutes for data to load
5. Refresh browser/restart client app

---

## License

This documentation is provided as-is for educational purposes.

## Contributing

Feel free to submit issues and pull requests for improvements.
