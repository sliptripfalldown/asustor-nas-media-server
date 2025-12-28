#!/bin/bash
# NAS Media Server - Master Installation Script
# Run with: sudo ./install.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       NAS Media Server - Complete Installation               ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  This will install:                                          ║"
echo "║  • OpenSSL 3.4.0 (from source)                               ║"
echo "║  • Qt 6.10.1 (from source)                                   ║"
echo "║  • qBittorrent 5.1.4 (from source)                           ║"
echo "║  • *arr Stack (Radarr, Sonarr, Lidarr, Readarr, Prowlarr)   ║"
echo "║  • Jellyfin Media Server                                     ║"
echo "║  • FlareSolverr (Cloudflare bypass)                          ║"
echo "║  • VPN Namespace (isolated torrent traffic)                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "WARNING: This process takes several hours due to Qt compilation."
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

# Check sudo
if [[ $EUID -ne 0 ]]; then
   echo "Please run with sudo: sudo ./install.sh"
   exit 1
fi

# Get the actual user (not root)
REAL_USER=${SUDO_USER:-$USER}

echo ""
echo "=========================================="
echo "  Step 1/9: Installing Dependencies"
echo "=========================================="
bash ${SCRIPT_DIR}/scripts/install-dependencies.sh

echo ""
echo "=========================================="
echo "  Step 2/9: Building OpenSSL"
echo "=========================================="
sudo -u ${REAL_USER} bash ${SCRIPT_DIR}/scripts/build-openssl.sh

echo ""
echo "=========================================="
echo "  Step 3/9: Building Qt 6.10.1"
echo "=========================================="
echo "This takes 1-2 hours..."
sudo -u ${REAL_USER} bash ${SCRIPT_DIR}/scripts/build-qt6.sh

echo ""
echo "=========================================="
echo "  Step 4/9: Building qBittorrent"
echo "=========================================="
sudo -u ${REAL_USER} bash ${SCRIPT_DIR}/scripts/build-qbittorrent.sh

echo ""
echo "=========================================="
echo "  Step 5/9: Configuring qBittorrent"
echo "=========================================="
# Install optimized qBittorrent config
mkdir -p /home/${REAL_USER}/.config/qBittorrent
cp ${SCRIPT_DIR}/config/qbittorrent/qBittorrent.conf /home/${REAL_USER}/.config/qBittorrent/
chown -R ${REAL_USER}:${REAL_USER} /home/${REAL_USER}/.config/qBittorrent

# Install VPN namespace services (NEVER use user services)
cp ${SCRIPT_DIR}/config/systemd/vpn-namespace.service /etc/systemd/system/
cp ${SCRIPT_DIR}/config/systemd/qbittorrent-vpn.service /etc/systemd/system/
cp ${SCRIPT_DIR}/config/systemd/prowlarr-vpn.service /etc/systemd/system/
cp ${SCRIPT_DIR}/config/systemd/flaresolverr-vpn.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable vpn-namespace qbittorrent-vpn

# Install kernel network optimizations
cp ${SCRIPT_DIR}/config/sysctl/99-torrent-optimizations.conf /etc/sysctl.d/
sysctl -p /etc/sysctl.d/99-torrent-optimizations.conf

echo ""
echo "=========================================="
echo "  Step 6/9: Installing *arr Stack"
echo "=========================================="
bash ${SCRIPT_DIR}/scripts/install-arr-stack.sh

echo ""
echo "=========================================="
echo "  Step 7/9: Installing Jellyfin"
echo "=========================================="
curl -fsSL https://repo.jellyfin.org/ubuntu/jellyfin_team.gpg.key | \
    gpg --dearmor -o /usr/share/keyrings/jellyfin.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/jellyfin.gpg] \
    https://repo.jellyfin.org/ubuntu $(lsb_release -cs) main" | \
    tee /etc/apt/sources.list.d/jellyfin.list
apt update
apt install -y jellyfin
systemctl enable jellyfin
systemctl start jellyfin

echo ""
echo "=========================================="
echo "  Step 8/9: Installing FlareSolverr"
echo "=========================================="
bash ${SCRIPT_DIR}/scripts/install-flaresolverr.sh

echo ""
echo "=========================================="
echo "  Step 9/9: Configuring VPN Namespace"
echo "=========================================="
cp ${SCRIPT_DIR}/scripts/vpn-namespace-setup.sh /usr/local/bin/
cp ${SCRIPT_DIR}/scripts/qbt-vpn-start.sh /usr/local/bin/
chmod +x /usr/local/bin/vpn-namespace-setup.sh /usr/local/bin/qbt-vpn-start.sh
systemctl daemon-reload
systemctl enable vpn-namespace prowlarr-vpn flaresolverr-vpn

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Installation Complete!                             ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                              ║"
echo "║  Service URLs:                                               ║"
echo "║                                                              ║"
echo "║  VPN Namespace (10.200.200.2):                               ║"
echo "║  • qBittorrent:  http://10.200.200.2:8080 (admin/adminadmin)║"
echo "║  • Prowlarr:     http://10.200.200.2:9696                    ║"
echo "║  • FlareSolverr: http://10.200.200.2:8191                    ║"
echo "║                                                              ║"
echo "║  Host Network:                                               ║"
echo "║  • Radarr:       http://localhost:7878                       ║"
echo "║  • Sonarr:       http://localhost:8989                       ║"
echo "║  • Lidarr:       http://localhost:8686                       ║"
echo "║  • LazyLibrarian:http://localhost:5299                       ║"
echo "║  • Jellyfin:     http://localhost:8096                       ║"
echo "║                                                              ║"
echo "║  Next Steps:                                                 ║"
echo "║  1. Setup ZFS pool (if not done)                             ║"
echo "║  2. Download WireGuard configs from ProtonVPN                ║"
echo "║     Save to: config/wireguard/servers/                       ║"
echo "║  3. Run: ./scripts/configure-arr-stack.sh                    ║"
echo "║  4. Start VPN: systemctl start vpn-namespace qbittorrent-vpn ║"
echo "║  5. Change all default passwords!                            ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
