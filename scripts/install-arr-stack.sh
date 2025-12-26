#!/bin/bash
# Install the *arr stack (Radarr, Sonarr, Lidarr, Readarr, Prowlarr)
set -e

INSTALL_DIR="/opt"
USER="anon"

echo "=========================================="
echo "  Installing *arr Stack"
echo "=========================================="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run with sudo"
   exit 1
fi

cd /tmp

# ============================================
# Radarr (Movies)
# ============================================
echo ""
echo "[1/5] Installing Radarr..."
RADARR_URL=$(curl -s https://api.github.com/repos/Radarr/Radarr/releases/latest | \
    grep "browser_download_url.*linux-core-x64.tar.gz" | cut -d '"' -f 4)
wget -q -O radarr.tar.gz "${RADARR_URL}"
tar -xzf radarr.tar.gz -C ${INSTALL_DIR}/
chown -R ${USER}:${USER} ${INSTALL_DIR}/Radarr
rm radarr.tar.gz
echo "  ✓ Radarr installed to ${INSTALL_DIR}/Radarr"

# ============================================
# Sonarr (TV Shows)
# ============================================
echo ""
echo "[2/5] Installing Sonarr..."
SONARR_URL=$(curl -s https://api.github.com/repos/Sonarr/Sonarr/releases/latest | \
    grep "browser_download_url.*linux-x64.tar.gz" | cut -d '"' -f 4 | head -1)
wget -q -O sonarr.tar.gz "${SONARR_URL}"
tar -xzf sonarr.tar.gz -C ${INSTALL_DIR}/
chown -R ${USER}:${USER} ${INSTALL_DIR}/Sonarr
rm sonarr.tar.gz
echo "  ✓ Sonarr installed to ${INSTALL_DIR}/Sonarr"

# ============================================
# Lidarr (Music)
# ============================================
echo ""
echo "[3/5] Installing Lidarr..."
LIDARR_URL=$(curl -s https://api.github.com/repos/Lidarr/Lidarr/releases/latest | \
    grep "browser_download_url.*linux-core-x64.tar.gz" | cut -d '"' -f 4)
wget -q -O lidarr.tar.gz "${LIDARR_URL}"
tar -xzf lidarr.tar.gz -C ${INSTALL_DIR}/
chown -R ${USER}:${USER} ${INSTALL_DIR}/Lidarr
rm lidarr.tar.gz
echo "  ✓ Lidarr installed to ${INSTALL_DIR}/Lidarr"

# ============================================
# Readarr (Books/Audiobooks)
# ============================================
echo ""
echo "[4/5] Installing Readarr..."
READARR_URL=$(curl -s https://api.github.com/repos/Readarr/Readarr/releases/latest | \
    grep "browser_download_url.*linux-core-x64.tar.gz" | cut -d '"' -f 4)
wget -q -O readarr.tar.gz "${READARR_URL}"
tar -xzf readarr.tar.gz -C ${INSTALL_DIR}/
chown -R ${USER}:${USER} ${INSTALL_DIR}/Readarr
rm readarr.tar.gz
echo "  ✓ Readarr installed to ${INSTALL_DIR}/Readarr"

# ============================================
# Prowlarr (Indexer Manager)
# ============================================
echo ""
echo "[5/5] Installing Prowlarr..."
PROWLARR_URL=$(curl -s https://api.github.com/repos/Prowlarr/Prowlarr/releases/latest | \
    grep "browser_download_url.*linux-core-x64.tar.gz" | cut -d '"' -f 4)
wget -q -O prowlarr.tar.gz "${PROWLARR_URL}"
tar -xzf prowlarr.tar.gz -C ${INSTALL_DIR}/
chown -R ${USER}:${USER} ${INSTALL_DIR}/Prowlarr
rm prowlarr.tar.gz
echo "  ✓ Prowlarr installed to ${INSTALL_DIR}/Prowlarr"

# ============================================
# Create systemd services
# ============================================
echo ""
echo "Creating systemd services..."

# Radarr service
cat > /etc/systemd/system/radarr.service << EOF
[Unit]
Description=Radarr Movie Manager
After=network.target

[Service]
Type=simple
User=${USER}
Group=${USER}
ExecStart=${INSTALL_DIR}/Radarr/Radarr -nobrowser -data=/home/${USER}/.config/Radarr
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Sonarr service
cat > /etc/systemd/system/sonarr.service << EOF
[Unit]
Description=Sonarr TV Series Manager
After=network.target

[Service]
Type=simple
User=${USER}
Group=${USER}
ExecStart=${INSTALL_DIR}/Sonarr/Sonarr -nobrowser -data=/home/${USER}/.config/Sonarr
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Lidarr service
cat > /etc/systemd/system/lidarr.service << EOF
[Unit]
Description=Lidarr Music Manager
After=network.target

[Service]
Type=simple
User=${USER}
Group=${USER}
ExecStart=${INSTALL_DIR}/Lidarr/Lidarr -nobrowser -data=/home/${USER}/.config/Lidarr
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Readarr service
cat > /etc/systemd/system/readarr.service << EOF
[Unit]
Description=Readarr Book Manager
After=network.target

[Service]
Type=simple
User=${USER}
Group=${USER}
ExecStart=${INSTALL_DIR}/Readarr/Readarr -nobrowser -data=/home/${USER}/.config/Readarr
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Prowlarr service
cat > /etc/systemd/system/prowlarr.service << EOF
[Unit]
Description=Prowlarr Indexer Manager
After=network.target

[Service]
Type=simple
User=${USER}
Group=${USER}
ExecStart=${INSTALL_DIR}/Prowlarr/Prowlarr -nobrowser -data=/home/${USER}/.config/Prowlarr
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Reload and enable
systemctl daemon-reload
systemctl enable radarr sonarr lidarr readarr prowlarr

echo ""
echo "=========================================="
echo "  *arr Stack installed successfully!"
echo "=========================================="
echo ""
echo "Start services with:"
echo "  sudo systemctl start radarr sonarr lidarr readarr prowlarr"
echo ""
echo "Access URLs:"
echo "  Prowlarr: http://localhost:9696"
echo "  Radarr:   http://localhost:7878"
echo "  Sonarr:   http://localhost:8989"
echo "  Lidarr:   http://localhost:8686"
echo "  Readarr:  http://localhost:8787"
