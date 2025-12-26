#!/bin/bash
set -e

# ============================================
# Add Public Indexers to Prowlarr
# ============================================
# This script adds recommended public indexers to Prowlarr.
# Indexers blocked by CloudFlare will fail to add - this is expected.
# Run after FlareSolverr is configured for CloudFlare-protected sites.

# Get API key from config
get_api_key() {
    local config_path="$HOME/.config/Prowlarr/config.xml"
    if [[ -f "$config_path" ]]; then
        grep -oP '(?<=<ApiKey>)[^<]+' "$config_path" 2>/dev/null || echo ""
    fi
}

PROWLARR_API="${PROWLARR_API:-$(get_api_key)}"
# Prowlarr runs in VPN namespace at 10.200.200.2
HOST="${PROWLARR_HOST:-10.200.200.2}"

if [[ -z "$PROWLARR_API" ]]; then
    echo "ERROR: Could not find Prowlarr API key"
    echo "Make sure Prowlarr is running and has generated a config"
    exit 1
fi

echo "=== Adding Public Indexers to Prowlarr ==="
echo ""

# Save schema to temp file
echo "Fetching indexer schemas..."
curl -s -o /tmp/prowlarr_schema.json \
    "http://$HOST:9696/api/v1/indexer/schema" \
    -H "X-Api-Key: $PROWLARR_API"

# Define indexers to add (non-porn, public)
INDEXERS=(
    # General purpose
    "thepiratebay"
    "bitsearch"
    "limetorrents"
    "torrentdownloads"
    "magnetdl"
    "yts"
    # TV/Movies
    "eztv"
    "torrent9"
    "showrss"
    # Books
    "internetarchive"
    # Anime/Asian
    "nyaasi"
    "tokyotosho"
    "bangumi-moe"
    "dmhy"
    "anidex"
    "bigfangroup"
    "u3c3"
    # Linux
    "linuxtracker"
    # Russian
    "rutor"
    "rutracker-ru"
    "noname-club"
    "nortorrent"
    "uztracker"
    # French
    "oxtorrent-co"
    "zktorrent"
)

added=0
failed=0

for indexer in "${INDEXERS[@]}"; do
    # Extract schema for this indexer
    config=$(python3 << EOF
import json
import sys

with open('/tmp/prowlarr_schema.json') as f:
    schemas = json.load(f)

for schema in schemas:
    if schema.get('definitionName') == '$indexer':
        config = {
            "name": schema.get('name', '$indexer'),
            "definitionName": '$indexer',
            "implementation": schema.get('implementation', 'Cardigann'),
            "implementationName": schema.get('implementationName', 'Cardigann'),
            "configContract": schema.get('configContract', 'CardigannSettings'),
            "enable": True,
            "redirect": False,
            "supportsRss": schema.get('supportsRss', True),
            "supportsSearch": schema.get('supportsSearch', True),
            "supportsRedirect": schema.get('supportsRedirect', False),
            "appProfileId": 1,
            "priority": 25,
            "tags": [],
            "fields": schema.get('fields', [])
        }
        print(json.dumps(config))
        sys.exit(0)

sys.exit(1)
EOF
    )

    if [[ -z "$config" ]]; then
        echo "  ? $indexer: Definition not found"
        continue
    fi

    # Add the indexer
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "http://$HOST:9696/api/v1/indexer" \
        -H "X-Api-Key: $PROWLARR_API" \
        -H "Content-Type: application/json" \
        -d "$config" \
        --connect-timeout 30 \
        --max-time 60)

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | head -n -1)

    if [[ "$http_code" == "201" ]]; then
        echo "  ✓ $indexer: Added"
        ((added++))
    elif echo "$body" | grep -q "CloudFlare"; then
        echo "  ✗ $indexer: CloudFlare blocked"
        ((failed++))
    elif echo "$body" | grep -q "already exists"; then
        echo "  → $indexer: Already exists"
    else
        echo "  ✗ $indexer: Failed ($http_code)"
        ((failed++))
    fi
done

echo ""
echo "=== Summary ==="
echo "Added: $added"
echo "Failed: $failed (CloudFlare or connection issues)"
echo ""

# Trigger sync to all apps
echo "Triggering sync to *arr apps..."
curl -s -X POST "http://$HOST:9696/api/v1/command" \
    -H "X-Api-Key: $PROWLARR_API" \
    -H "Content-Type: application/json" \
    -d '{"name": "ApplicationIndexerSync"}' > /dev/null

echo "Done! Indexers will sync to connected *arr apps."
