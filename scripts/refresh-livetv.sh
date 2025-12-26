#!/bin/bash
# Refresh Live TV EPG and trigger Jellyfin guide update
# Run this after adding new channels or if guide data is stale

set -e

SCRIPTS_DIR="/home/anon/nas-media-server/scripts"
JELLYFIN_URL="http://localhost:8096"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[LiveTV]${NC} $1"; }
warn() { echo -e "${YELLOW}[LiveTV]${NC} $1"; }

echo ""
log "=== Live TV Refresh ==="
echo ""

# Step 1: Update IPTV channels and EPG data
log "Step 1/3: Updating IPTV channels and EPG data..."
"$SCRIPTS_DIR/update-iptv.sh"

# Step 2: Update combined EPG (epghub sources)
log "Step 2/3: Updating combined EPG sources..."
"$SCRIPTS_DIR/update-epg.sh"

# Step 3: Trigger Jellyfin guide refresh via API
log "Step 3/3: Triggering Jellyfin guide refresh..."

# Get Jellyfin API key from config
JELLYFIN_API_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' /etc/jellyfin/system.xml 2>/dev/null || echo "")

if [[ -z "$JELLYFIN_API_KEY" ]]; then
    warn "Could not find Jellyfin API key - manual refresh required"
    warn "Go to: Jellyfin Dashboard → Live TV → TV Guide Data Providers → Refresh Guide Data"
else
    # Refresh all guide providers
    # This triggers Jellyfin to re-download and process EPG data
    response=$(curl -s -w "%{http_code}" -o /dev/null -X POST \
        "$JELLYFIN_URL/ScheduledTasks/Running/7738148ffcd07979c7ceb148e06b3aed" \
        -H "X-Emby-Token: $JELLYFIN_API_KEY" 2>/dev/null || echo "000")

    if [[ "$response" == "204" || "$response" == "200" ]]; then
        log "Jellyfin guide refresh triggered successfully"
    else
        # Try alternative: refresh live TV data
        response=$(curl -s -w "%{http_code}" -o /dev/null -X POST \
            "$JELLYFIN_URL/LiveTv/GuideInfo/Refresh" \
            -H "X-Emby-Token: $JELLYFIN_API_KEY" 2>/dev/null || echo "000")

        if [[ "$response" == "204" || "$response" == "200" ]]; then
            log "Jellyfin guide refresh triggered successfully"
        else
            warn "Could not trigger Jellyfin refresh via API (HTTP $response)"
            warn "Manual refresh: Dashboard → Live TV → TV Guide Data Providers → Refresh"
        fi
    fi
fi

echo ""
log "=== Refresh Complete ==="
echo ""
log "EPG Sources Updated:"
ls -la /tank/media/livetv/epg/*.xml 2>/dev/null | awk '{print "  " $NF ": " $5 " bytes"}' | sed 's|/tank/media/livetv/epg/||'
echo ""
log "M3U Playlists Updated:"
for f in pluto-tv-us.m3u samsungtvplus.m3u plex.m3u roku.m3u stirr.m3u; do
    count=$(grep -c "^#EXTINF" "/tank/media/livetv/$f" 2>/dev/null || echo 0)
    echo "  $f: $count channels"
done
echo ""
log "If guide data still doesn't appear in Jellyfin:"
log "  1. Go to Dashboard → Live TV"
log "  2. Click 'TV Guide Data Providers'"
log "  3. Click 'Refresh Guide Data' for each provider"
echo ""
