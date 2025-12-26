#!/bin/bash
# Build Qt 6.10.1 from source
set -e

QT_VERSION="v6.10.1"
QT_INSTALL_PREFIX="/usr/local/lib/qt6.10.1"
OPENSSL_PREFIX="/usr/local/ssl"

echo "=========================================="
echo "  Building Qt ${QT_VERSION}"
echo "=========================================="

cd ~/Downloads

# Clone if not exists
if [ ! -d "qt6" ]; then
    echo "Cloning Qt repository (this takes a while)..."
    git clone https://code.qt.io/qt/qt5.git qt6
fi

cd qt6

# Checkout version
echo "Checking out ${QT_VERSION}..."
git fetch --all --tags
git checkout ${QT_VERSION}

# Initialize only required submodules
echo "Initializing submodules..."
perl init-repository --module-subset=qtbase,qttools,qtsvg,qtwayland

# Create build directory
mkdir -p ~/Downloads/qt6-build
cd ~/Downloads/qt6-build

# Clean previous build
rm -rf * 2>/dev/null || true

# Configure
echo "Configuring Qt..."
../qt6/configure \
    -prefix ${QT_INSTALL_PREFIX} \
    -release \
    -opensource \
    -confirm-license \
    -nomake examples \
    -nomake tests \
    -openssl-linked \
    -I ${OPENSSL_PREFIX}/include \
    -L ${OPENSSL_PREFIX}/lib64

# Build
echo "Building Qt (this takes 1-2 hours)..."
cmake --build . --parallel $(nproc)

# Install
echo "Installing Qt (requires sudo)..."
sudo cmake --install .

echo ""
echo "=========================================="
echo "  Qt ${QT_VERSION} installed successfully!"
echo "=========================================="
echo "Installed to: ${QT_INSTALL_PREFIX}"
ls ${QT_INSTALL_PREFIX}/
