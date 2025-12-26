#!/bin/bash
# Post-Install Configuration Script
# Run after rebuild.sh completes to configure all services
# Usage: ./post-install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[POST-INSTALL]${NC} $1"; }
warn() { echo -e "${YELLOW}[POST-INSTALL]${NC} $1"; }
error() { echo -e "${RED}[POST-INSTALL]${NC} $1"; }
header() { echo -e "\n${CYAN}=== $1 ===${NC}\n"; }

# Check if running as regular user (not root)
if [[ $EUID -eq 0 ]]; then
    echo "Run as regular user, not root: ./post-install.sh"
    exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Post-Install Configuration                         ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  This script configures all services after installation:     ║"
echo "║  • ZFS datasets                                              ║"
echo "║  • *arr stack (download clients, root folders, sync)         ║"
echo "║  • Prowlarr indexers                                         ║"
echo "║  • Jellyfin media libraries                                  ║"
echo "║  • LazyLibrarian                                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ============================================
# Pre-flight checks
# ============================================
header "Pre-flight Checks"

# Check VPN namespace
if sudo ip netns list | grep -q vpn; then
    log "VPN namespace: OK"
else
    error "VPN namespace not found. Run: sudo systemctl start vpn-namespace"
    exit 1
fi

# Check services
services=("qbittorrent-vpn" "prowlarr-vpn" "sonarr" "radarr" "lidarr" "jellyfin")
for svc in "${services[@]}"; do
    if systemctl is-active --quiet "$svc"; then
        log "$svc: Running"
    else
        warn "$svc: Not running - starting..."
        sudo systemctl start "$svc" || true
        sleep 2
    fi
done

# Check VPN connectivity
vpn_ip=$(sudo ip netns exec vpn curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "FAILED")
host_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "FAILED")

if [[ "$vpn_ip" != "FAILED" && "$vpn_ip" != "$host_ip" ]]; then
    log "VPN isolation: OK (VPN: $vpn_ip, Host: $host_ip)"
else
    error "VPN not working properly. Check: sudo systemctl status qbittorrent-vpn"
    exit 1
fi

# Wait for services to be ready
log "Waiting for services to initialize..."
sleep 5

# ============================================
# Step 1: ZFS Datasets
# ============================================
header "Step 1: ZFS Datasets"

if zpool list tank &>/dev/null; then
    log "ZFS pool 'tank' exists"
    sudo bash "$SCRIPT_DIR/setup-zfs.sh" datasets
else
    warn "ZFS pool 'tank' not found"
    echo "Create it manually or run: sudo $SCRIPT_DIR/setup-zfs.sh create"
fi

# ============================================
# Step 2: Configure *arr Stack
# ============================================
header "Step 2: Configure *arr Stack"

log "Configuring download clients, root folders, and Prowlarr sync..."
bash "$SCRIPT_DIR/configure-arr-stack.sh"

# ============================================
# Step 3: Add Indexers
# ============================================
header "Step 3: Add Prowlarr Indexers"

log "Adding public indexers to Prowlarr..."
bash "$SCRIPT_DIR/add-indexers.sh"

# ============================================
# Step 4: Configure Jellyfin
# ============================================
header "Step 4: Configure Jellyfin"

# Check if Jellyfin setup wizard is complete
if curl -s "http://localhost:8096/System/Info/Public" | grep -q "ServerName"; then
    log "Jellyfin is configured, adding libraries..."
    bash "$SCRIPT_DIR/configure-jellyfin.sh" configure
else
    warn "Jellyfin setup wizard not complete"
    echo "  1. Open http://localhost:8096"
    echo "  2. Complete the setup wizard"
    echo "  3. Run: $SCRIPT_DIR/configure-jellyfin.sh configure"
fi

# ============================================
# Step 5: Configure LazyLibrarian
# ============================================
header "Step 5: Configure LazyLibrarian"

if curl -s "http://localhost:5299/api?cmd=getVersion" 2>/dev/null | grep -q "install_type"; then
    log "LazyLibrarian is running"

    # Get API key
    LL_API=$(grep -oP '(?<=api_key = )[^\s]+' /var/lib/lazylibrarian/config.ini 2>/dev/null || echo "")

    if [[ -n "$LL_API" ]]; then
        # Configure qBittorrent host
        curl -s "http://localhost:5299/api?cmd=writeCFG&section=QBITTORRENT&qbittorrent_host=http://10.200.200.2:8080&apikey=$LL_API" > /dev/null
        log "LazyLibrarian qBittorrent host configured"
    else
        warn "Could not find LazyLibrarian API key"
    fi
else
    warn "LazyLibrarian not responding"
fi

# ============================================
# Summary
# ============================================
header "Configuration Complete!"

echo "Service URLs:"
echo ""
echo "  VPN Namespace (10.200.200.2):"
echo "  ├── qBittorrent:  http://10.200.200.2:8080"
echo "  ├── Prowlarr:     http://10.200.200.2:9696"
echo "  └── FlareSolverr: http://10.200.200.2:8191"
echo ""
echo "  Host Network:"
echo "  ├── Sonarr:       http://localhost:8989"
echo "  ├── Radarr:       http://localhost:7878"
echo "  ├── Lidarr:       http://localhost:8686"
echo "  ├── LazyLibrarian:http://localhost:5299"
echo "  ├── Jellyfin:     http://localhost:8096"
echo "  └── AdGuard Home: http://localhost:3000"
echo ""
echo "Next steps:"
echo "  1. Change default passwords in each app"
echo "  2. Complete Jellyfin setup wizard if not done"
echo "  3. Add any private indexers to Prowlarr"
echo "  4. Import existing media libraries in *arr apps"
echo ""
log "Post-install configuration complete!"
