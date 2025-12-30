# Building from Source

Guide to building OpenSSL, Qt 6.10.1, and qBittorrent from source.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Building OpenSSL](#building-openssl)
- [Building Qt 6.10.1](#building-qt-6101)
- [Building qBittorrent](#building-qbittorrent)

---

## Prerequisites

### Base System

- **OS**: Ubuntu 24.04 LTS
- **Kernel**: 6.14.0+

### Install Build Dependencies

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
```

---

## Building OpenSSL

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

## Building Qt 6.10.1

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

## Building qBittorrent

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

### Version Notes

| Version | Status | Notes |
|---------|--------|-------|
| 5.1.x | **Recommended** | Stable, works with *arr apps |
| 5.2.x (alpha) | Avoid | Authentication bugs break *arr integration |
| master | Avoid | Unstable, experimental features |

---

## Automated Build Scripts

The repository includes build scripts that automate these steps:

| Script | Description |
|--------|-------------|
| `scripts/build-openssl.sh` | Build OpenSSL from source |
| `scripts/build-qt6.sh` | Build Qt 6.10.1 from source |
| `scripts/build-qbittorrent.sh` | Build qBittorrent from source |
| `scripts/install-dependencies.sh` | Install all build dependencies |

### Quick Build

```bash
# Install dependencies
./scripts/install-dependencies.sh

# Build everything
./scripts/build-openssl.sh
./scripts/build-qt6.sh
./scripts/build-qbittorrent.sh
```

---

## Library Path Configuration

After building, ensure the library paths are set:

```bash
# Add to ~/.bashrc or /etc/profile.d/
export LD_LIBRARY_PATH=/usr/local/lib/qt6.10.1/lib:/usr/local/ssl/lib64:$LD_LIBRARY_PATH
```

Verify libraries are found:

```bash
ldd /usr/local/bin/qbittorrent-nox
# Should show Qt and OpenSSL libraries resolving correctly
```

---

## Related Documentation

| Doc | Description |
|-----|-------------|
| [Services Guide](SERVICES.md) | Service configuration |
| [Hardware Guide](HARDWARE.md) | Hardware specs |
| [Troubleshooting](TROUBLESHOOTING.md) | Common issues |
