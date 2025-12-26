#!/bin/bash
# ZFS Pool and Dataset Setup for Media Server
# Run with: sudo ./setup-zfs.sh [create|status]

set -e

POOL_NAME="tank"
MEDIA_ROOT="/tank/media"

# Default dataset structure
DATASETS=(
    "media"
    "media/movies"
    "media/tv"
    "media/music"
    "media/downloads"
    "media/downloads/incomplete"
    "media/audiobooks"
    "media/ebooks"
    "media/comics"
    "media/livetv"
    "media/livetv/epg"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[ZFS]${NC} $1"; }
warn() { echo -e "${YELLOW}[ZFS]${NC} $1"; }
error() { echo -e "${RED}[ZFS]${NC} $1"; exit 1; }

show_status() {
    echo ""
    log "=== ZFS Pool Status ==="
    if zpool list $POOL_NAME &>/dev/null; then
        zpool status $POOL_NAME
        echo ""
        log "=== Datasets ==="
        zfs list -r $POOL_NAME
        echo ""
        log "=== Space Usage ==="
        zfs list -o name,used,avail,refer,mountpoint -r $POOL_NAME
    else
        warn "Pool '$POOL_NAME' does not exist"
    fi
}

create_datasets() {
    log "Creating ZFS datasets..."

    for ds in "${DATASETS[@]}"; do
        if zfs list "$POOL_NAME/$ds" &>/dev/null; then
            echo "  → $POOL_NAME/$ds already exists"
        else
            zfs create "$POOL_NAME/$ds"
            echo "  ✓ Created $POOL_NAME/$ds"
        fi
    done

    # Set permissions
    log "Setting permissions..."
    chown -R anon:anon $MEDIA_ROOT
    chmod -R 775 $MEDIA_ROOT

    log "Datasets created successfully"
}

create_pool() {
    echo ""
    log "=== ZFS Pool Creation ==="
    echo ""
    echo "Available drives:"
    lsblk -d -o NAME,SIZE,MODEL | grep -v "loop\|sr0\|NAME"
    echo ""

    read -p "Enter drives for RAIDZ2 (space-separated, e.g., sda sdb sdc sdd sde sdf): " drives

    if [[ -z "$drives" ]]; then
        error "No drives specified"
    fi

    # Convert to /dev/ paths
    dev_list=""
    for drive in $drives; do
        dev_list="$dev_list /dev/$drive"
    done

    echo ""
    warn "This will DESTROY ALL DATA on: $dev_list"
    read -p "Are you sure? (type 'yes' to confirm): " confirm

    if [[ "$confirm" != "yes" ]]; then
        error "Aborted"
    fi

    log "Creating RAIDZ2 pool..."
    zpool create -o ashift=12 \
        -O compression=lz4 \
        -O atime=off \
        -O xattr=sa \
        -O acltype=posixacl \
        $POOL_NAME raidz2 $dev_list

    log "Pool created successfully"
    create_datasets
}

case "${1:-status}" in
    create)
        if zpool list $POOL_NAME &>/dev/null; then
            warn "Pool '$POOL_NAME' already exists. Creating datasets only..."
            create_datasets
        else
            create_pool
        fi
        ;;
    datasets)
        create_datasets
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 {create|datasets|status}"
        echo ""
        echo "Commands:"
        echo "  create   - Create ZFS pool and datasets (interactive)"
        echo "  datasets - Create only datasets (pool must exist)"
        echo "  status   - Show current ZFS status"
        exit 1
        ;;
esac
