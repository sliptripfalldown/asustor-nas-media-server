#!/bin/bash
# Add public trackers from maintained lists to stalled/slow torrents
# Sources:
#   - https://github.com/ngosang/trackerslist
#   - https://github.com/XIU2/TrackersListCollection

set -euo pipefail

QBT_HOST="${QBT_HOST:-127.0.0.1}"
QBT_PORT="${QBT_PORT:-8080}"
VPN_NAMESPACE="${VPN_NAMESPACE:-vpn}"
TRACKER_CACHE="/tmp/combined_trackers.txt"
TRACKER_CACHE_AGE=86400  # Refresh trackers every 24 hours

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to run commands in VPN namespace
qbt_api() {
    local endpoint="$1"
    shift
    sudo ip netns exec "$VPN_NAMESPACE" curl -s "http://${QBT_HOST}:${QBT_PORT}/api/v2/${endpoint}" "$@"
}

# Fetch and combine tracker lists
fetch_trackers() {
    log_info "Fetching tracker lists..."

    local temp_trackers=$(mktemp)

    # ngosang trackers
    if curl -sf "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt" >> "$temp_trackers" 2>/dev/null; then
        log_info "  ✓ ngosang/trackerslist"
    else
        log_warn "  ✗ Failed to fetch ngosang trackers"
    fi

    # XIU2 trackers
    if curl -sf "https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/all.txt" >> "$temp_trackers" 2>/dev/null; then
        log_info "  ✓ XIU2/TrackersListCollection"
    else
        log_warn "  ✗ Failed to fetch XIU2 trackers"
    fi

    # Deduplicate and clean
    grep -v '^$' "$temp_trackers" 2>/dev/null | sort -u > "$TRACKER_CACHE"
    rm -f "$temp_trackers"

    local count=$(wc -l < "$TRACKER_CACHE")
    log_info "Combined $count unique trackers"
}

# Check if tracker cache needs refresh
check_tracker_cache() {
    if [[ ! -f "$TRACKER_CACHE" ]]; then
        fetch_trackers
        return
    fi

    local cache_age=$(( $(date +%s) - $(stat -c %Y "$TRACKER_CACHE") ))
    if [[ $cache_age -gt $TRACKER_CACHE_AGE ]]; then
        log_info "Tracker cache expired, refreshing..."
        fetch_trackers
    else
        local count=$(wc -l < "$TRACKER_CACHE")
        log_info "Using cached tracker list ($count trackers)"
    fi
}

# Find suffering torrents (stalled, slow, or stuck on metadata)
find_suffering_torrents() {
    qbt_api "torrents/info" | python3 -c "
import json, sys
data = json.load(sys.stdin)

suffering = []
for t in data:
    state = t.get('state', '')
    dlspeed = t.get('dlspeed', 0)
    progress = t.get('progress', 0)
    seeds = t.get('num_complete', 0)

    # Conditions for 'suffering' torrents:
    # 1. Stuck on metadata
    # 2. Stalled downloading with < 100% progress
    # 3. Downloading very slowly (< 10 KB/s) with no seeds
    is_suffering = (
        state == 'metaDL' or
        (state == 'stalledDL' and progress < 1.0) or
        (state in ['downloading', 'queuedDL'] and dlspeed < 10240 and seeds == 0 and progress < 1.0)
    )

    if is_suffering:
        suffering.append({
            'hash': t['hash'],
            'name': t['name'],
            'state': state,
            'progress': progress,
            'seeds': seeds,
            'dlspeed': dlspeed
        })

for t in suffering:
    print(t['hash'])
" 2>/dev/null
}

# Add trackers to a torrent
add_trackers_to_torrent() {
    local hash="$1"
    local trackers="$2"

    qbt_api "torrents/addTrackers" \
        -X POST \
        -d "hash=$hash" \
        --data-urlencode "urls=$trackers" > /dev/null
}

# Main function
main() {
    log_info "=== Tracker Aggregator for Suffering Torrents ==="

    # Ensure tracker cache is fresh
    check_tracker_cache

    if [[ ! -s "$TRACKER_CACHE" ]]; then
        log_error "No trackers available!"
        exit 1
    fi

    local trackers=$(cat "$TRACKER_CACHE")

    # Find suffering torrents
    log_info "Finding suffering torrents..."
    local hashes=$(find_suffering_torrents)

    if [[ -z "$hashes" ]]; then
        log_info "No suffering torrents found!"
        exit 0
    fi

    local count=$(echo "$hashes" | wc -l)
    log_info "Found $count suffering torrents"

    # Add trackers to each
    local processed=0
    while read -r hash; do
        [[ -z "$hash" ]] && continue
        add_trackers_to_torrent "$hash" "$trackers"
        ((processed++))
        echo -n "."
    done <<< "$hashes"
    echo ""

    log_info "Added trackers to $processed torrents"

    # Force reannounce all
    log_info "Forcing reannounce..."
    local hash_list=$(echo "$hashes" | tr '\n' '|' | sed 's/|$//')
    qbt_api "torrents/reannounce" -X POST -d "hashes=$hash_list" > /dev/null

    log_info "Done!"

    # Show status
    echo ""
    log_info "Current status of suffering torrents:"
    qbt_api "torrents/info" | python3 -c "
import json, sys
data = json.load(sys.stdin)

hashes = set('$hashes'.strip().split('\n'))

for t in data:
    if t['hash'] in hashes:
        state = t.get('state', '')
        progress = t.get('progress', 0) * 100
        seeds = t.get('num_complete', 0)
        peers = t.get('num_incomplete', 0)
        name = t['name'][:50]
        print(f'  [{progress:5.1f}%] S:{seeds:3} P:{peers:3} | {name}')
"
}

main "$@"
