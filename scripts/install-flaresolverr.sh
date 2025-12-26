#!/bin/bash
# Install FlareSolverr for Cloudflare bypass
set -e

INSTALL_DIR="/opt/FlareSolverr"
USER="anon"

echo "=========================================="
echo "  Installing FlareSolverr"
echo "=========================================="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run with sudo"
   exit 1
fi

# Clone repository
echo "Cloning FlareSolverr..."
if [ -d "${INSTALL_DIR}" ]; then
    rm -rf ${INSTALL_DIR}
fi
git clone https://github.com/FlareSolverr/FlareSolverr.git ${INSTALL_DIR}
chown -R ${USER}:${USER} ${INSTALL_DIR}

# Setup as user
echo "Setting up Python environment..."
sudo -u ${USER} bash << EOF
cd ${INSTALL_DIR}
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
playwright install chromium
EOF

# Create systemd service
echo "Creating systemd service..."
cat > /etc/systemd/system/flaresolverr.service << EOF
[Unit]
Description=FlareSolverr - Cloudflare bypass for Prowlarr
After=network.target

[Service]
Type=simple
User=${USER}
Group=${USER}
WorkingDirectory=${INSTALL_DIR}
Environment="PATH=${INSTALL_DIR}/venv/bin"
ExecStart=${INSTALL_DIR}/venv/bin/python ${INSTALL_DIR}/src/flaresolverr.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Reload and enable
systemctl daemon-reload
systemctl enable flaresolverr
systemctl start flaresolverr

echo ""
echo "=========================================="
echo "  FlareSolverr installed successfully!"
echo "=========================================="
echo ""
echo "Running at: http://localhost:8191"
echo ""
echo "Add to Prowlarr:"
echo "  Settings → Indexers → Add Indexer Proxy"
echo "  Type: FlareSolverr"
echo "  Host: http://localhost:8191/"
