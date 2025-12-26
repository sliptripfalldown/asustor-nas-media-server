#!/bin/bash
# NAS Media Server - Full System Rebuild Script
# This script restores the complete NAS media server setup from scratch
# Run as: sudo ./rebuild.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"

echo "=========================================="
echo "NAS Media Server - Full Rebuild"
echo "=========================================="
echo ""
echo "This script will:"
echo "  1. Install all dependencies"
echo "  2. Set up ZFS pool (manual step)"
echo "  3. Install and configure all services"
echo "  4. Restore configurations"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

# ============================================
# PHASE 1: System Dependencies
# ============================================
echo ""
echo "[Phase 1] Installing system dependencies..."

apt update
apt install -y \
    curl wget git python3 python3-pip \
    nginx \
    samba samba-common-bin \
    nfs-kernel-server \
    zfsutils-linux \
    ffmpeg \
    unrar p7zip-full \
    wireguard wireguard-tools \
    sqlite3 \
    natpmpc \
    calibre \
    chromium-browser \
    iptables

# ============================================
# PHASE 2: ZFS Pool Setup (Manual)
# ============================================
echo ""
echo "[Phase 2] ZFS Pool Setup"
echo ""
echo "MANUAL STEP REQUIRED:"
echo "  If the ZFS pool 'tank' doesn't exist, create it:"
echo "    zpool create -o ashift=12 tank raidz /dev/sda /dev/sdb /dev/sdc /dev/sdd"
echo ""
echo "  Then create datasets:"
echo "    zfs create tank/media"
echo "    zfs create tank/media/movies"
echo "    zfs create tank/media/tv"
echo "    zfs create tank/media/music"
echo "    zfs create tank/media/downloads"
echo "    zfs create tank/media/audiobooks"
echo "    zfs create tank/media/ebooks"
echo "    zfs create tank/media/comics"
echo "    zfs create tank/media/livetv"
echo ""
read -p "Press Enter when ZFS is ready..."

# ============================================
# PHASE 3: Create directories
# ============================================
echo ""
echo "[Phase 3] Creating directories..."

mkdir -p /tank/media/{movies,tv,music,downloads,audiobooks,ebooks,comics,livetv/epg}
mkdir -p /home/anon/.config/{Sonarr,Radarr,Lidarr,Prowlarr,LazyLibrarian,qBittorrent,unpackerr}
chown -R anon:anon /tank/media
chown -R anon:anon /home/anon/.config

# ============================================
# PHASE 4: Install *arr Stack
# ============================================
echo ""
echo "[Phase 4] Installing *arr stack..."

# Sonarr
if ! command -v sonarr &> /dev/null; then
    apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 2009837CBFFD68F45BC180471F4F90DE2A9B4BF8
    echo "deb https://apt.sonarr.tv/ubuntu focal main" > /etc/apt/sources.list.d/sonarr.list
    apt update && apt install -y sonarr
fi

# Radarr
if ! command -v radarr &> /dev/null; then
    apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 4D1DAF7DC860E5FB96A61D6B8F7134A8E4B93C1B
    echo "deb https://apt.radarr.video/ubuntu focal main" > /etc/apt/sources.list.d/radarr.list
    apt update && apt install -y radarr
fi

# Lidarr
if ! command -v lidarr &> /dev/null; then
    apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 5F1BBF0F
    echo "deb https://apt.lidarr.audio/ubuntu focal main" > /etc/apt/sources.list.d/lidarr.list
    apt update && apt install -y lidarr
fi

# Prowlarr
if [ ! -d /opt/Prowlarr ]; then
    wget -O /tmp/prowlarr.tar.gz "https://prowlarr.servarr.com/v1/update/master/updatefile?os=linux&runtime=netcore&arch=x64"
    tar -xzf /tmp/prowlarr.tar.gz -C /opt
    chown -R anon:anon /opt/Prowlarr
fi

# LazyLibrarian
if [ ! -d /home/anon/LazyLibrarian ]; then
    git clone https://gitlab.com/LazyLibrarian/LazyLibrarian.git /home/anon/LazyLibrarian
    chown -R anon:anon /home/anon/LazyLibrarian
fi

# LazyLibrarian data directory
mkdir -p /var/lib/lazylibrarian/Logs
chown -R anon:anon /var/lib/lazylibrarian

# ============================================
# PHASE 5: Install qBittorrent (from source)
# ============================================
echo ""
echo "[Phase 5] Installing qBittorrent..."

if ! command -v qbittorrent-nox &> /dev/null; then
    echo "Building qBittorrent from source..."
    bash "$SCRIPT_DIR/scripts/build-qbittorrent.sh"
fi

# Install VueTorrent (alternative WebUI for qBittorrent)
if [ ! -d /home/anon/vuetorrent ]; then
    echo "Installing VueTorrent WebUI..."
    mkdir -p /home/anon/vuetorrent
    wget -qO /tmp/vuetorrent.zip https://github.com/WDaan/VueTorrent/releases/latest/download/vuetorrent.zip
    unzip -q /tmp/vuetorrent.zip -d /home/anon/vuetorrent/
    chown -R anon:anon /home/anon/vuetorrent
    rm /tmp/vuetorrent.zip
fi

# ============================================
# PHASE 6: Install FlareSolverr
# ============================================
echo ""
echo "[Phase 6] Installing FlareSolverr..."

bash "$SCRIPT_DIR/scripts/install-flaresolverr.sh"

# ============================================
# PHASE 7: Install AdGuard Home
# ============================================
echo ""
echo "[Phase 7] Installing AdGuard Home..."

if [ ! -d /opt/AdGuardHome ]; then
    curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
fi

# ============================================
# PHASE 8: Install Unpackerr
# ============================================
echo ""
echo "[Phase 8] Installing Unpackerr..."

if ! command -v unpackerr &> /dev/null; then
    wget -O /tmp/unpackerr.deb "https://github.com/Unpackerr/unpackerr/releases/latest/download/unpackerr_amd64.deb"
    dpkg -i /tmp/unpackerr.deb
fi

# ============================================
# PHASE 9: Install Jellyfin
# ============================================
echo ""
echo "[Phase 9] Installing Jellyfin..."

if ! command -v jellyfin &> /dev/null; then
    curl https://repo.jellyfin.org/install-debuntu.sh | bash
fi

# ============================================
# PHASE 10: Copy systemd services
# ============================================
echo ""
echo "[Phase 10] Installing systemd services..."

cp "$CONFIG_DIR/systemd/"*.service /etc/systemd/system/
cp "$CONFIG_DIR/systemd/"*.timer /etc/systemd/system/
systemctl daemon-reload

# ============================================
# PHASE 11: Copy nginx configs
# ============================================
echo ""
echo "[Phase 11] Configuring nginx..."

cp "$CONFIG_DIR/nginx/"* /etc/nginx/sites-available/
ln -sf /etc/nginx/sites-available/nas-portal /etc/nginx/sites-enabled/
ln -sf /etc/nginx/sites-available/livetv /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# ============================================
# PHASE 12: Copy Jellyfin config
# ============================================
echo ""
echo "[Phase 12] Configuring Jellyfin..."

mkdir -p /etc/systemd/system/jellyfin.service.d
cp "$CONFIG_DIR/jellyfin/jellyfin.service.conf" /etc/systemd/system/jellyfin.service.d/
cp "$CONFIG_DIR/jellyfin/livetv.xml" /etc/jellyfin/

# ============================================
# PHASE 13: Copy Samba config
# ============================================
echo ""
echo "[Phase 13] Configuring Samba..."

cp "$CONFIG_DIR/samba/smb.conf" /etc/samba/
if [ -f "$CONFIG_DIR/samba/exports" ]; then
    cp "$CONFIG_DIR/samba/exports" /etc/exports
    exportfs -ra
fi
systemctl restart smbd nmbd

# ============================================
# PHASE 14: Configure VPN Namespace
# ============================================
echo ""
echo "[Phase 14] VPN Namespace Setup"
echo ""
echo "MANUAL STEP REQUIRED:"
echo "  1. Get your Proton VPN WireGuard configs from:"
echo "     https://account.protonvpn.com/downloads#wireguard-configuration"
echo "  2. Download multiple P2P-enabled server configs for failover"
echo "  3. Save configs to: $SCRIPT_DIR/config/wireguard/servers/"
echo ""
echo "  The VPN namespace isolates torrent traffic from local network."
echo ""
read -p "Press Enter when VPN configs are downloaded..."

# ============================================
# PHASE 15: Enable services
# ============================================
echo ""
echo "[Phase 15] Enabling services..."

# VPN namespace services
systemctl enable --now vpn-namespace.service
systemctl enable --now qbittorrent-vpn.service
systemctl enable --now prowlarr-vpn.service
systemctl enable --now flaresolverr-vpn.service
systemctl enable --now sonarr.service
systemctl enable --now radarr.service
systemctl enable --now lidarr.service
systemctl enable --now lazylibrarian.service
systemctl enable --now unpackerr.service
systemctl enable --now AdGuardHome.service
systemctl enable --now jellyfin.service
systemctl enable --now livetv-update.timer
systemctl enable --now qbit-queue-manager.timer
systemctl enable --now mobile-encode.timer

# ============================================
# PHASE 16: Final Configuration (Manual)
# ============================================
echo ""
echo "=========================================="
echo "REBUILD COMPLETE!"
echo "=========================================="
echo ""
echo "Installation complete! Next steps:"
echo ""
echo "1. Complete Jellyfin setup wizard at http://localhost:8096"
echo "2. Complete AdGuard Home setup at http://localhost:3000"
echo ""
echo "3. Run post-install configuration (as regular user, not root):"
echo "   cd $SCRIPT_DIR && ./scripts/post-install.sh"
echo ""
echo "   This will automatically configure:"
echo "   - ZFS datasets"
echo "   - Download clients in all *arr apps (10.200.200.2:8080)"
echo "   - Root folders for media"
echo "   - Prowlarr indexers"
echo "   - Jellyfin media libraries"
echo "   - LazyLibrarian settings"
echo ""
echo "Service URLs after configuration:"
echo "  VPN Namespace: qBittorrent (10.200.200.2:8080), Prowlarr (:9696)"
echo "  Host Network:  Sonarr (:8989), Radarr (:7878), Lidarr (:8686)"
echo "                 Jellyfin (:8096), LazyLibrarian (:5299)"
echo ""
