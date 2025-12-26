#!/bin/bash
# Apply qBittorrent and kernel optimizations for thousands of torrents

set -e

echo "=== Applying Torrent Optimizations ==="

# 1. Stop qBittorrent and remove user service
echo "[1/5] Stopping qBittorrent..."
sudo systemctl stop qbittorrent-vpn 2>/dev/null || true
systemctl --user disable --now qbittorrent 2>/dev/null || true
rm -f /home/anon/.config/systemd/user/qbittorrent.service 2>/dev/null || true
pkill -f qbittorrent 2>/dev/null || true
sleep 2

# 2. Apply kernel network optimizations
echo "[2/5] Applying kernel network optimizations..."
sudo cp /home/anon/nas-media-server/configs/99-torrent-optimizations.conf /etc/sysctl.d/
sudo sysctl -p /etc/sysctl.d/99-torrent-optimizations.conf

# 3. Install VPN namespace services
echo "[3/5] Installing VPN namespace services..."
sudo cp /home/anon/nas-media-server/configs/vpn-namespace.service /etc/systemd/system/
sudo cp /home/anon/nas-media-server/configs/qbittorrent-vpn.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable vpn-namespace qbittorrent-vpn

# 4. Start VPN namespace
echo "[4/5] Starting VPN namespace..."
sudo systemctl start vpn-namespace
sleep 2

# 5. Start qBittorrent in VPN
echo "[5/5] Starting qBittorrent in VPN namespace..."
sudo systemctl start qbittorrent-vpn
sleep 5

# Verify
if systemctl is-active --quiet qbittorrent-vpn; then
    echo ""
    echo "=== Success ==="
    echo "Config: ~/.config/qBittorrent/qBittorrent.conf"
    echo "WebUI:  http://10.200.200.2:8080 (VPN namespace)"
    echo ""
    echo "Manage: sudo systemctl {start|stop|restart|status} qbittorrent-vpn"
    echo "VPN:    sudo systemctl {start|stop|status} vpn-namespace"
else
    echo "ERROR: qBittorrent VPN failed to start"
    sudo systemctl status qbittorrent-vpn
    exit 1
fi
