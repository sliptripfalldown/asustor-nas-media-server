#!/bin/bash
# Add XMLTV EPG providers to Jellyfin via API
# Run this after setting up Live TV tuners

set -e

JELLYFIN_URL="http://localhost:8096"
JELLYFIN_USER="${JELLYFIN_USER:-admin}"
JELLYFIN_PASS="${JELLYFIN_PASS:-}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[Jellyfin EPG]${NC} $1"; }
warn() { echo -e "${YELLOW}[Jellyfin EPG]${NC} $1"; }
error() { echo -e "${RED}[Jellyfin EPG]${NC} $1"; exit 1; }

# Prompt for password if not set
if [[ -z "$JELLYFIN_PASS" ]]; then
    echo -n "Enter Jellyfin password for user '$JELLYFIN_USER': "
    read -s JELLYFIN_PASS
    echo ""
fi

log "Authenticating with Jellyfin..."

# Authenticate and get access token
AUTH_RESPONSE=$(curl -s -X POST "$JELLYFIN_URL/Users/AuthenticateByName" \
    -H "Content-Type: application/json" \
    -H "X-Emby-Authorization: MediaBrowser Client=\"Setup Script\", Device=\"NAS\", DeviceId=\"setup-script\", Version=\"1.0\"" \
    -d "{\"Username\":\"$JELLYFIN_USER\",\"Pw\":\"$JELLYFIN_PASS\"}")

ACCESS_TOKEN=$(echo "$AUTH_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('AccessToken',''))" 2>/dev/null)
USER_ID=$(echo "$AUTH_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('User',{}).get('Id',''))" 2>/dev/null)

if [[ -z "$ACCESS_TOKEN" ]]; then
    error "Authentication failed. Check username/password."
fi

log "Authenticated successfully"

# Function to add XMLTV provider
add_xmltv_provider() {
    local name="$1"
    local epg_url="$2"
    local tuner_id="$3"

    log "Adding EPG provider: $name"

    response=$(curl -s -w "\n%{http_code}" -X POST "$JELLYFIN_URL/LiveTv/ListingProviders" \
        -H "Content-Type: application/json" \
        -H "X-Emby-Token: $ACCESS_TOKEN" \
        -d "{
            \"Type\": \"XmlTv\",
            \"Path\": \"$epg_url\",
            \"EnabledTuners\": [\"$tuner_id\"],
            \"EnableAllTuners\": false
        }")

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | head -n -1)

    if [[ "$http_code" == "200" || "$http_code" == "204" ]]; then
        log "  Added: $name"
    else
        warn "  Failed to add $name (HTTP $http_code): $body"
    fi
}

# Get existing tuner IDs
log "Fetching tuner information..."
TUNERS=$(curl -s "$JELLYFIN_URL/LiveTv/TunerHosts" -H "X-Emby-Token: $ACCESS_TOKEN")

# Extract tuner IDs by M3U URL pattern
get_tuner_id() {
    local pattern="$1"
    echo "$TUNERS" | python3 -c "
import sys,json
tuners = json.load(sys.stdin)
for t in tuners:
    if '$pattern' in t.get('Url',''):
        print(t.get('Id',''))
        break
" 2>/dev/null
}

PLUTO_TUNER=$(get_tuner_id "pluto-tv-us.m3u")
SAMSUNG_TUNER=$(get_tuner_id "samsungtvplus.m3u")
PLEX_TUNER=$(get_tuner_id "plex.m3u")
ROKU_TUNER=$(get_tuner_id "roku.m3u")
STIRR_TUNER=$(get_tuner_id "stirr.m3u")

log "Found tuners:"
[[ -n "$PLUTO_TUNER" ]] && echo "  Pluto TV: $PLUTO_TUNER"
[[ -n "$SAMSUNG_TUNER" ]] && echo "  Samsung TV Plus: $SAMSUNG_TUNER"
[[ -n "$PLEX_TUNER" ]] && echo "  Plex: $PLEX_TUNER"
[[ -n "$ROKU_TUNER" ]] && echo "  Roku: $ROKU_TUNER"
[[ -n "$STIRR_TUNER" ]] && echo "  Stirr: $STIRR_TUNER"

echo ""
log "Adding EPG providers..."

# Add EPG providers for each tuner (using local file paths)
EPG_DIR="/tank/media/livetv/epg"
[[ -n "$PLUTO_TUNER" ]] && add_xmltv_provider "Pluto TV" "$EPG_DIR/pluto-us.xml" "$PLUTO_TUNER"
[[ -n "$SAMSUNG_TUNER" ]] && add_xmltv_provider "Samsung TV Plus" "$EPG_DIR/samsungtvplus.xml" "$SAMSUNG_TUNER"
[[ -n "$PLEX_TUNER" ]] && add_xmltv_provider "Plex" "$EPG_DIR/plex.xml" "$PLEX_TUNER"
[[ -n "$ROKU_TUNER" ]] && add_xmltv_provider "Roku" "$EPG_DIR/roku.xml" "$ROKU_TUNER"
[[ -n "$STIRR_TUNER" ]] && add_xmltv_provider "Stirr" "$EPG_DIR/stirr.xml" "$STIRR_TUNER"

echo ""
log "Triggering guide refresh..."
curl -s -X POST "$JELLYFIN_URL/ScheduledTasks/Running/$(curl -s "$JELLYFIN_URL/ScheduledTasks" -H "X-Emby-Token: $ACCESS_TOKEN" | python3 -c "import sys,json; tasks=json.load(sys.stdin); print(next((t['Id'] for t in tasks if 'guide' in t.get('Name','').lower()), ''))" 2>/dev/null)" \
    -H "X-Emby-Token: $ACCESS_TOKEN" &>/dev/null || true

echo ""
log "=== Setup Complete ==="
log "EPG providers have been added to Jellyfin"
log "Go to Dashboard → Live TV → TV Guide Data Providers to verify"
log "The guide will populate within 2-3 minutes"
