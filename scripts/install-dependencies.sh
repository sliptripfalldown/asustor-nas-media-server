#!/bin/bash
# Install all dependencies for the NAS media server
set -e

echo "=========================================="
echo "  NAS Media Server - Dependency Install"
echo "=========================================="

# Check if running as root for apt
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run with sudo"
   exit 1
fi

echo ""
echo "[1/5] Updating system..."
apt update && apt upgrade -y

echo ""
echo "[2/5] Installing build essentials..."
apt install -y \
    build-essential \
    cmake \
    ninja-build \
    git \
    curl \
    wget \
    pkg-config \
    perl \
    python3 \
    python3-pip \
    python3-venv

echo ""
echo "[3/5] Installing Qt6 build dependencies..."
apt install -y \
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
    libwayland-egl-backend-dev \
    libxshmfence-dev \
    libxxf86vm-dev \
    libatspi2.0-dev

echo ""
echo "[4/5] Installing qBittorrent dependencies..."
apt install -y \
    libtorrent-rasterbar-dev \
    libboost-all-dev \
    libboost-system-dev \
    libboost-filesystem-dev

echo ""
echo "[5/5] Installing ZFS utilities..."
apt install -y zfsutils-linux

echo ""
echo "=========================================="
echo "  Dependencies installed successfully!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Run: ./build-openssl.sh"
echo "  2. Run: ./build-qt6.sh"
echo "  3. Run: ./build-qbittorrent.sh"
