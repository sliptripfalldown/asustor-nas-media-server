#!/bin/bash
# Configure Jellyfin Media Libraries via API
# Run after Jellyfin is installed and initial setup wizard completed

set -e

JELLYFIN_URL="${JELLYFIN_URL:-http://localhost:8096}"

# Media library definitions
# Format: "Name|Type|Path"
LIBRARIES=(
    "Movies|movies|/tank/media/movies"
    "TV Shows|tvshows|/tank/media/tv"
    "Music|music|/tank/media/music"
    "Audiobooks|music|/tank/media/audiobooks"
    "Live TV|livetv|/tank/media/livetv"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[Jellyfin]${NC} $1"; }
warn() { echo -e "${YELLOW}[Jellyfin]${NC} $1"; }
error() { echo -e "${RED}[Jellyfin]${NC} $1"; exit 1; }

# Check if Jellyfin is accessible
check_jellyfin() {
    if ! curl -s "$JELLYFIN_URL/health" | grep -q "Healthy"; then
        error "Cannot connect to Jellyfin at $JELLYFIN_URL"
    fi
    log "Connected to Jellyfin"
}

# Get API key from Jellyfin config
get_api_key() {
    local config="/var/lib/jellyfin/data/system.xml"
    if [[ -f "$config" ]]; then
        grep -oP '(?<=<ApiKey>)[^<]+' "$config" 2>/dev/null || echo ""
    fi
}

# Create a library via API
create_library() {
    local name="$1"
    local type="$2"
    local path="$3"
    local api_key="$4"

    # Check if library already exists
    existing=$(curl -s "$JELLYFIN_URL/Library/VirtualFolders" \
        -H "X-Emby-Token: $api_key" | grep -o "\"Name\":\"$name\"" || true)

    if [[ -n "$existing" ]]; then
        echo "  → $name already exists"
        return
    fi

    # Create library
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "$JELLYFIN_URL/Library/VirtualFolders?name=$name&collectionType=$type&refreshLibrary=false" \
        -H "X-Emby-Token: $api_key" \
        -H "Content-Type: application/json" \
        -d "{\"LibraryOptions\":{\"PathInfos\":[{\"Path\":\"$path\"}]}}")

    http_code=$(echo "$response" | tail -1)

    if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
        echo "  ✓ Created library: $name ($path)"
    else
        echo "  ✗ Failed to create $name: HTTP $http_code"
    fi
}

show_status() {
    local api_key=$(get_api_key)
    if [[ -z "$api_key" ]]; then
        warn "No API key found. Complete Jellyfin setup wizard first."
        return
    fi

    echo ""
    log "=== Jellyfin Libraries ==="
    curl -s "$JELLYFIN_URL/Library/VirtualFolders" \
        -H "X-Emby-Token: $api_key" | \
        python3 -c "
import sys, json
try:
    libs = json.load(sys.stdin)
    for lib in libs:
        name = lib.get('Name', 'Unknown')
        paths = [p.get('Path', '?') for p in lib.get('Locations', [])]
        print(f\"  {name}: {', '.join(paths)}\")
except:
    print('  (could not parse)')
"
}

configure_libraries() {
    log "Configuring Jellyfin libraries..."

    local api_key=$(get_api_key)
    if [[ -z "$api_key" ]]; then
        error "No API key found. Complete Jellyfin setup wizard first at $JELLYFIN_URL"
    fi

    check_jellyfin

    for lib in "${LIBRARIES[@]}"; do
        IFS='|' read -r name type path <<< "$lib"

        # Check path exists
        if [[ ! -d "$path" ]]; then
            warn "Path $path does not exist, skipping $name"
            continue
        fi

        create_library "$name" "$type" "$path" "$api_key"
    done

    # Trigger library scan
    log "Triggering library scan..."
    curl -s -X POST "$JELLYFIN_URL/Library/Refresh" \
        -H "X-Emby-Token: $api_key" > /dev/null

    log "Libraries configured. Scan started in background."
}

configure_livetv() {
    log "Configuring Live TV tuner..."

    local api_key=$(get_api_key)
    if [[ -z "$api_key" ]]; then
        error "No API key found"
    fi

    # Add M3U tuner for IPTV
    local m3u_url="http://localhost:8888/livetv/pluto-us.m3u"
    local epg_url="http://localhost:8888/livetv/epg/pluto-us.xml"

    curl -s -X POST "$JELLYFIN_URL/LiveTv/TunerHosts" \
        -H "X-Emby-Token: $api_key" \
        -H "Content-Type: application/json" \
        -d "{
            \"Type\": \"m3u\",
            \"Url\": \"$m3u_url\",
            \"FriendlyName\": \"IPTV\",
            \"DeviceId\": \"iptv-m3u\",
            \"ImportFavoritesOnly\": false,
            \"AllowHWTranscoding\": true,
            \"EnableStreamLooping\": false
        }" > /dev/null 2>&1 && echo "  ✓ M3U tuner added" || echo "  → Tuner may already exist"

    # Add EPG provider
    curl -s -X POST "$JELLYFIN_URL/LiveTv/ListingProviders" \
        -H "X-Emby-Token: $api_key" \
        -H "Content-Type: application/json" \
        -d "{
            \"Type\": \"XmlTV\",
            \"Path\": \"$epg_url\",
            \"EnableAutoDiscovery\": true,
            \"EnableAllTuners\": true
        }" > /dev/null 2>&1 && echo "  ✓ EPG provider added" || echo "  → EPG may already exist"

    log "Live TV configured"
}

case "${1:-status}" in
    configure)
        configure_libraries
        ;;
    livetv)
        configure_livetv
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 {configure|livetv|status}"
        echo ""
        echo "Commands:"
        echo "  configure - Create media libraries"
        echo "  livetv    - Configure Live TV tuner and EPG"
        echo "  status    - Show current libraries"
        echo ""
        echo "Prerequisites:"
        echo "  1. Jellyfin must be running"
        echo "  2. Complete the setup wizard at $JELLYFIN_URL first"
        exit 1
        ;;
esac
