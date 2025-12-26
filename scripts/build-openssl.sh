#!/bin/bash
# Build OpenSSL from source
set -e

OPENSSL_VERSION="openssl-3.4.0"
INSTALL_PREFIX="/usr/local/ssl"

echo "=========================================="
echo "  Building OpenSSL ${OPENSSL_VERSION}"
echo "=========================================="

cd ~

# Clone if not exists
if [ ! -d "openssl" ]; then
    echo "Cloning OpenSSL repository..."
    git clone https://github.com/openssl/openssl.git
fi

cd openssl

# Checkout version
echo "Checking out ${OPENSSL_VERSION}..."
git fetch --all --tags
git checkout ${OPENSSL_VERSION}

# Clean previous build
make clean 2>/dev/null || true

# Configure
echo "Configuring..."
./Configure \
    --prefix=${INSTALL_PREFIX} \
    --openssldir=${INSTALL_PREFIX} \
    shared

# Build
echo "Building (this takes ~10 minutes)..."
make -j$(nproc)

# Install
echo "Installing (requires sudo)..."
sudo make install

# Update library cache
echo "${INSTALL_PREFIX}/lib64" | sudo tee /etc/ld.so.conf.d/openssl.conf
sudo ldconfig

# Verify
echo ""
echo "=========================================="
echo "  OpenSSL installed successfully!"
echo "=========================================="
${INSTALL_PREFIX}/bin/openssl version
