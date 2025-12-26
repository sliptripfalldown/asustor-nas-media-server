#!/bin/bash
# Build qBittorrent from source
set -e

QBT_VERSION="release-5.1.4"
QT_PREFIX="/usr/local/lib/qt6.10.1"

echo "=========================================="
echo "  Building qBittorrent ${QBT_VERSION}"
echo "=========================================="

cd ~

# Clone if not exists
if [ ! -d "qBittorrent" ]; then
    echo "Cloning qBittorrent repository..."
    git clone https://github.com/qbittorrent/qBittorrent.git
fi

cd qBittorrent

# Checkout version
echo "Checking out ${QBT_VERSION}..."
git fetch --all --tags
git checkout ${QBT_VERSION}

# Create build directory for headless version
mkdir -p build-nox
cd build-nox

# Clean previous build
rm -rf * 2>/dev/null || true

# Configure (headless - no GUI)
echo "Configuring qBittorrent (headless)..."
cmake -B . -S .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DGUI=OFF \
    -DCMAKE_PREFIX_PATH=${QT_PREFIX}/lib/cmake/

# Build
echo "Building..."
cmake --build . --parallel $(nproc)

# Verify
echo ""
echo "Testing binary..."
./qbittorrent-nox --version

# Install
echo ""
echo "Installing (requires sudo)..."
sudo cp qbittorrent-nox /usr/local/bin/
sudo chmod +x /usr/local/bin/qbittorrent-nox

echo ""
echo "=========================================="
echo "  qBittorrent installed successfully!"
echo "=========================================="
/usr/local/bin/qbittorrent-nox --version

echo ""
echo "Create initial config with:"
echo "  mkdir -p ~/.config/qBittorrent"
echo "  /usr/local/bin/qbittorrent-nox"
echo ""
echo "Then access WebUI at: http://localhost:8080"
echo "Default credentials: admin / adminadmin"
