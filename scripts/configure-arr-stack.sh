#!/bin/bash
set -e

# ============================================
# API Keys - Load from environment or config files
# ============================================
# API keys are read from each app's config.xml file if not set in environment
get_api_key() {
    local app=$1
    local config_path="$HOME/.config/$app/config.xml"
    if [[ -f "$config_path" ]]; then
        grep -oP '(?<=<ApiKey>)[^<]+' "$config_path" 2>/dev/null || echo ""
    fi
}

# Use environment variables if set, otherwise read from config files
PROWLARR_API="${PROWLARR_API:-$(get_api_key Prowlarr)}"
RADARR_API="${RADARR_API:-$(get_api_key Radarr)}"
SONARR_API="${SONARR_API:-$(get_api_key Sonarr)}"
LIDARR_API="${LIDARR_API:-$(get_api_key Lidarr)}"
READARR_API="${READARR_API:-$(get_api_key Readarr)}"

# Validate API keys
for key_name in PROWLARR_API RADARR_API SONARR_API LIDARR_API READARR_API; do
    if [[ -z "${!key_name}" ]]; then
        echo "ERROR: $key_name not found. Make sure the app is running and has generated a config."
        exit 1
    fi
done

# VPN namespace services (Prowlarr, qBittorrent) are at 10.200.200.2
# Host network services (Sonarr, Radarr, Lidarr) are at localhost
VPN_HOST="${VPN_HOST:-10.200.200.2}"
HOST="${ARR_HOST:-localhost}"

# qBittorrent credentials (change after initial setup!)
QB_USER="${QB_USER:-admin}"
QB_PASS="${QB_PASS:-adminadmin}"

echo "=== Configuring *arr Stack ==="

# ============================================
# PROWLARR - Add FlareSolverr
# ============================================
echo ""
echo "[1/6] Configuring Prowlarr - Adding FlareSolverr..."

curl -s -X POST "http://$VPN_HOST:9696/api/v1/indexerProxy" \
  -H "X-Api-Key: $PROWLARR_API" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "FlareSolverr",
    "fields": [
      {"name": "host", "value": "http://10.200.200.2:8191/"},
      {"name": "requestTimeout", "value": 60}
    ],
    "implementationName": "FlareSolverr",
    "implementation": "FlareSolverr",
    "configContract": "FlareSolverrSettings",
    "tags": []
  }' > /dev/null 2>&1 && echo "  ✓ FlareSolverr proxy added" || echo "  → FlareSolverr may already exist"

# ============================================
# PROWLARR - Add Apps for Sync
# ============================================
echo ""
echo "[2/6] Configuring Prowlarr - Adding Apps for sync..."

# Add Radarr to Prowlarr
curl -s -X POST "http://$VPN_HOST:9696/api/v1/applications" \
  -H "X-Api-Key: $PROWLARR_API" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Radarr",
    "syncLevel": "fullSync",
    "fields": [
      {"name": "prowlarrUrl", "value": "http://10.200.200.2:9696"},
      {"name": "baseUrl", "value": "http://10.200.200.1:7878"},
      {"name": "apiKey", "value": "'"$RADARR_API"'"},
      {"name": "syncCategories", "value": [2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060, 2070, 2080]}
    ],
    "implementationName": "Radarr",
    "implementation": "Radarr",
    "configContract": "RadarrSettings",
    "tags": []
  }' > /dev/null 2>&1 && echo "  ✓ Radarr app added" || echo "  → Radarr may already exist"

# Add Sonarr to Prowlarr
curl -s -X POST "http://$VPN_HOST:9696/api/v1/applications" \
  -H "X-Api-Key: $PROWLARR_API" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Sonarr",
    "syncLevel": "fullSync",
    "fields": [
      {"name": "prowlarrUrl", "value": "http://10.200.200.2:9696"},
      {"name": "baseUrl", "value": "http://10.200.200.1:8989"},
      {"name": "apiKey", "value": "'"$SONARR_API"'"},
      {"name": "syncCategories", "value": [5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060, 5070, 5080]}
    ],
    "implementationName": "Sonarr",
    "implementation": "Sonarr",
    "configContract": "SonarrSettings",
    "tags": []
  }' > /dev/null 2>&1 && echo "  ✓ Sonarr app added" || echo "  → Sonarr may already exist"

# Add Lidarr to Prowlarr
curl -s -X POST "http://$VPN_HOST:9696/api/v1/applications" \
  -H "X-Api-Key: $PROWLARR_API" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Lidarr",
    "syncLevel": "fullSync",
    "fields": [
      {"name": "prowlarrUrl", "value": "http://10.200.200.2:9696"},
      {"name": "baseUrl", "value": "http://10.200.200.1:8686"},
      {"name": "apiKey", "value": "'"$LIDARR_API"'"},
      {"name": "syncCategories", "value": [3000, 3010, 3020, 3030, 3040]}
    ],
    "implementationName": "Lidarr",
    "implementation": "Lidarr",
    "configContract": "LidarrSettings",
    "tags": []
  }' > /dev/null 2>&1 && echo "  ✓ Lidarr app added" || echo "  → Lidarr may already exist"

# Add Readarr to Prowlarr
curl -s -X POST "http://$VPN_HOST:9696/api/v1/applications" \
  -H "X-Api-Key: $PROWLARR_API" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Readarr",
    "syncLevel": "fullSync",
    "fields": [
      {"name": "prowlarrUrl", "value": "http://10.200.200.2:9696"},
      {"name": "baseUrl", "value": "http://10.200.200.1:8787"},
      {"name": "apiKey", "value": "'"$READARR_API"'"},
      {"name": "syncCategories", "value": [7000, 7010, 7020, 7030, 7040, 7050, 7060]}
    ],
    "implementationName": "Readarr",
    "implementation": "Readarr",
    "configContract": "ReadarrSettings",
    "tags": []
  }' > /dev/null 2>&1 && echo "  ✓ Readarr app added" || echo "  → Readarr may already exist"

# ============================================
# RADARR - Add Download Client + Root Folder
# ============================================
echo ""
echo "[3/6] Configuring Radarr..."

# Add qBittorrent
curl -s -X POST "http://$HOST:7878/api/v3/downloadclient" \
  -H "X-Api-Key: $RADARR_API" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "qBittorrent",
    "enable": true,
    "protocol": "torrent",
    "priority": 1,
    "fields": [
      {"name": "host", "value": "10.200.200.2"},
      {"name": "port", "value": 8080},
      {"name": "username", "value": "'"$QB_USER"'"},
      {"name": "password", "value": "'"$QB_PASS"'"},
      {"name": "movieCategory", "value": "radarr"},
      {"name": "movieImportedCategory", "value": ""},
      {"name": "recentMoviePriority", "value": 0},
      {"name": "olderMoviePriority", "value": 0},
      {"name": "initialState", "value": 0},
      {"name": "sequentialOrder", "value": false},
      {"name": "firstAndLast", "value": false}
    ],
    "implementationName": "qBittorrent",
    "implementation": "QBittorrent",
    "configContract": "QBittorrentSettings",
    "tags": []
  }' > /dev/null 2>&1 && echo "  ✓ qBittorrent download client added" || echo "  → qBittorrent may already exist"

# Add Root Folder
curl -s -X POST "http://$HOST:7878/api/v3/rootfolder" \
  -H "X-Api-Key: $RADARR_API" \
  -H "Content-Type: application/json" \
  -d '{"path": "/tank/media/movies"}' > /dev/null 2>&1 && echo "  ✓ Root folder /tank/media/movies added" || echo "  → Root folder may already exist"

# ============================================
# SONARR - Add Download Client + Root Folder
# ============================================
echo ""
echo "[4/6] Configuring Sonarr..."

# Add qBittorrent
curl -s -X POST "http://$HOST:8989/api/v3/downloadclient" \
  -H "X-Api-Key: $SONARR_API" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "qBittorrent",
    "enable": true,
    "protocol": "torrent",
    "priority": 1,
    "fields": [
      {"name": "host", "value": "10.200.200.2"},
      {"name": "port", "value": 8080},
      {"name": "username", "value": "'"$QB_USER"'"},
      {"name": "password", "value": "'"$QB_PASS"'"},
      {"name": "tvCategory", "value": "sonarr"},
      {"name": "tvImportedCategory", "value": ""},
      {"name": "recentTvPriority", "value": 0},
      {"name": "olderTvPriority", "value": 0},
      {"name": "initialState", "value": 0},
      {"name": "sequentialOrder", "value": false},
      {"name": "firstAndLast", "value": false}
    ],
    "implementationName": "qBittorrent",
    "implementation": "QBittorrent",
    "configContract": "QBittorrentSettings",
    "tags": []
  }' > /dev/null 2>&1 && echo "  ✓ qBittorrent download client added" || echo "  → qBittorrent may already exist"

# Add Root Folder
curl -s -X POST "http://$HOST:8989/api/v3/rootfolder" \
  -H "X-Api-Key: $SONARR_API" \
  -H "Content-Type: application/json" \
  -d '{"path": "/tank/media/tv"}' > /dev/null 2>&1 && echo "  ✓ Root folder /tank/media/tv added" || echo "  → Root folder may already exist"

# ============================================
# LIDARR - Add Download Client + Root Folder
# ============================================
echo ""
echo "[5/6] Configuring Lidarr..."

# Add qBittorrent
curl -s -X POST "http://$HOST:8686/api/v1/downloadclient" \
  -H "X-Api-Key: $LIDARR_API" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "qBittorrent",
    "enable": true,
    "protocol": "torrent",
    "priority": 1,
    "fields": [
      {"name": "host", "value": "10.200.200.2"},
      {"name": "port", "value": 8080},
      {"name": "username", "value": "'"$QB_USER"'"},
      {"name": "password", "value": "'"$QB_PASS"'"},
      {"name": "musicCategory", "value": "lidarr"},
      {"name": "musicImportedCategory", "value": ""},
      {"name": "recentMusicPriority", "value": 0},
      {"name": "olderMusicPriority", "value": 0},
      {"name": "initialState", "value": 0},
      {"name": "sequentialOrder", "value": false},
      {"name": "firstAndLast", "value": false}
    ],
    "implementationName": "qBittorrent",
    "implementation": "QBittorrent",
    "configContract": "QBittorrentSettings",
    "tags": []
  }' > /dev/null 2>&1 && echo "  ✓ qBittorrent download client added" || echo "  → qBittorrent may already exist"

# Add Root Folder
curl -s -X POST "http://$HOST:8686/api/v1/rootfolder" \
  -H "X-Api-Key: $LIDARR_API" \
  -H "Content-Type: application/json" \
  -d '{"path": "/tank/media/music", "name": "Music"}' > /dev/null 2>&1 && echo "  ✓ Root folder /tank/media/music added" || echo "  → Root folder may already exist"

# ============================================
# READARR - Add Download Client + Root Folders
# ============================================
echo ""
echo "[6/6] Configuring Readarr..."

# Add qBittorrent
curl -s -X POST "http://$HOST:8787/api/v1/downloadclient" \
  -H "X-Api-Key: $READARR_API" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "qBittorrent",
    "enable": true,
    "protocol": "torrent",
    "priority": 1,
    "fields": [
      {"name": "host", "value": "10.200.200.2"},
      {"name": "port", "value": 8080},
      {"name": "username", "value": "'"$QB_USER"'"},
      {"name": "password", "value": "'"$QB_PASS"'"},
      {"name": "bookCategory", "value": "readarr"},
      {"name": "bookImportedCategory", "value": ""},
      {"name": "recentBookPriority", "value": 0},
      {"name": "olderBookPriority", "value": 0},
      {"name": "initialState", "value": 0},
      {"name": "sequentialOrder", "value": false},
      {"name": "firstAndLast", "value": false}
    ],
    "implementationName": "qBittorrent",
    "implementation": "QBittorrent",
    "configContract": "QBittorrentSettings",
    "tags": []
  }' > /dev/null 2>&1 && echo "  ✓ qBittorrent download client added" || echo "  → qBittorrent may already exist"

# Add Root Folders for Books and Audiobooks
curl -s -X POST "http://$HOST:8787/api/v1/rootfolder" \
  -H "X-Api-Key: $READARR_API" \
  -H "Content-Type: application/json" \
  -d '{"path": "/tank/media/books", "name": "Books", "isCalibreLibrary": false}' > /dev/null 2>&1 && echo "  ✓ Root folder /tank/media/books added" || echo "  → Books folder may already exist"

curl -s -X POST "http://$HOST:8787/api/v1/rootfolder" \
  -H "X-Api-Key: $READARR_API" \
  -H "Content-Type: application/json" \
  -d '{"path": "/tank/media/audiobooks", "name": "Audiobooks", "isCalibreLibrary": false}' > /dev/null 2>&1 && echo "  ✓ Root folder /tank/media/audiobooks added" || echo "  → Audiobooks folder may already exist"

echo ""
echo "============================================"
echo "           Configuration Complete!"
echo "============================================"
echo ""
echo "Next Steps:"
echo ""
echo "1. PROWLARR (http://192.168.10.239:9696)"
echo "   → Indexers → Add indexers (1337x, RARBG, etc.)"
echo "   → They will auto-sync to all *arr apps"
echo ""
echo "2. JELLYFIN (http://192.168.10.239:8096)"
echo "   → Complete initial setup wizard"
echo "   → Add libraries:"
echo "     • Movies: /tank/media/movies"
echo "     • TV Shows: /tank/media/tv"
echo "     • Music: /tank/media/music"
echo "     • Books: /tank/media/books"
echo ""
echo "3. Each *arr app - Settings → Media Management:"
echo "   → Enable 'Use Hardlinks instead of Copy'"
echo "   → Set appropriate naming conventions"
echo ""
echo "4. Change default passwords!"
echo "   → qBittorrent: $QB_USER/$QB_PASS (set QB_USER/QB_PASS env vars to customize)"
echo ""
