#!/bin/bash
set -e

echo "=== Setting up all media services as system services ==="

# Stop user services
echo "Stopping user services..."
systemctl --user stop qbittorrent sonarr readarr lidarr prowlarr radarr 2>/dev/null || true
systemctl --user disable qbittorrent sonarr readarr lidarr prowlarr radarr 2>/dev/null || true

# Install qbittorrent-nox
echo "Installing qbittorrent-nox..."
sudo cp /home/anon/qBittorrent/build-nox/qbittorrent-nox /usr/local/bin/
sudo chmod +x /usr/local/bin/qbittorrent-nox

# Copy VPN namespace services
echo "Installing VPN namespace services..."
sudo cp /home/anon/nas-media-server/configs/vpn-namespace.service /etc/systemd/system/
sudo cp /home/anon/nas-media-server/configs/qbittorrent-vpn.service /etc/systemd/system/
sudo cp /home/anon/nas-media-server/configs/prowlarr-vpn.service /etc/systemd/system/
sudo cp /home/anon/nas-media-server/configs/flaresolverr-vpn.service /etc/systemd/system/

# Copy VPN namespace scripts
echo "Installing VPN namespace scripts..."
sudo cp /home/anon/nas-media-server/scripts/vpn-namespace-setup.sh /usr/local/bin/
sudo cp /home/anon/nas-media-server/scripts/qbt-vpn-start.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/vpn-namespace-setup.sh /usr/local/bin/qbt-vpn-start.sh

# Create Radarr system service
echo "Creating Radarr system service..."
sudo tee /etc/systemd/system/radarr.service > /dev/null << 'EOF'
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
EOF

# Create Sonarr system service
echo "Creating Sonarr system service..."
sudo tee /etc/systemd/system/sonarr.service > /dev/null << 'EOF'
[Unit]
Description=Sonarr TV Series Manager
After=network.target

[Service]
Type=simple
User=anon
Group=anon
ExecStart=/opt/Sonarr/Sonarr -nobrowser -data=/home/anon/.config/Sonarr
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Create Readarr system service
echo "Creating Readarr system service..."
sudo tee /etc/systemd/system/readarr.service > /dev/null << 'EOF'
[Unit]
Description=Readarr Ebook/Audiobook Manager
After=network.target

[Service]
Type=simple
User=anon
Group=anon
ExecStart=/opt/Readarr/Readarr -nobrowser -data=/home/anon/.config/Readarr
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Create Lidarr system service
echo "Creating Lidarr system service..."
sudo tee /etc/systemd/system/lidarr.service > /dev/null << 'EOF'
[Unit]
Description=Lidarr Music Manager
After=network.target

[Service]
Type=simple
User=anon
Group=anon
ExecStart=/opt/Lidarr/Lidarr -nobrowser -data=/home/anon/.config/Lidarr
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Create Prowlarr system service
echo "Creating Prowlarr system service..."
sudo tee /etc/systemd/system/prowlarr.service > /dev/null << 'EOF'
[Unit]
Description=Prowlarr Indexer Manager
After=network.target

[Service]
Type=simple
User=anon
Group=anon
ExecStart=/opt/Prowlarr/Prowlarr -nobrowser -data=/home/anon/.config/Prowlarr
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Reload and enable all system services
echo "Enabling and starting system services..."
sudo systemctl daemon-reload
sudo systemctl enable vpn-namespace qbittorrent-vpn prowlarr-vpn flaresolverr-vpn radarr sonarr readarr lidarr
sudo systemctl start vpn-namespace
sleep 2
sudo systemctl start qbittorrent-vpn prowlarr-vpn flaresolverr-vpn radarr sonarr readarr lidarr

# Show status
echo ""
echo "=== Service Status ==="
sudo systemctl status vpn-namespace qbittorrent-vpn prowlarr-vpn flaresolverr-vpn radarr sonarr readarr lidarr --no-pager | grep -E '●|Active:'

echo ""
echo "=== Access URLs (192.168.10.239) ==="
echo "┌─────────────────┬──────────────────────────────────┬───────┐"
echo "│ Service         │ URL                              │ Port  │"
echo "├─────────────────┼──────────────────────────────────┼───────┤"
echo "│ qBittorrent     │ http://192.168.10.239:8080       │ 8080  │"
echo "│ Prowlarr        │ http://192.168.10.239:9696       │ 9696  │"
echo "│ FlareSolverr    │ http://192.168.10.239:8191       │ 8191  │"
echo "│ Radarr (Movies) │ http://192.168.10.239:7878       │ 7878  │"
echo "│ Sonarr (TV)     │ http://192.168.10.239:8989       │ 8989  │"
echo "│ Readarr (Books) │ http://192.168.10.239:8787       │ 8787  │"
echo "│ Lidarr (Music)  │ http://192.168.10.239:8686       │ 8686  │"
echo "│ Jellyfin        │ http://192.168.10.239:8096       │ 8096  │"
echo "└─────────────────┴──────────────────────────────────┴───────┘"
echo ""
echo "qBittorrent credentials: admin / adminadmin"
echo ""
echo "NOTE: qBittorrent, Prowlarr, and FlareSolverr run in VPN namespace."
echo "      Manage with: sudo systemctl {start|stop|restart|status} qbittorrent-vpn"
echo ""
echo "Done!"
