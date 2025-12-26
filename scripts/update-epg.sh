#!/bin/bash
# Combine multiple EPG sources into one XMLTV file for Jellyfin

EPG_DIR="/tank/media/livetv/epg"
COMBINED="/tank/media/livetv/combined-epg.xml"
mkdir -p "$EPG_DIR"

EPG_SOURCES=(
    "https://epghub.xyz/epg/EPG-ALJAZEERA.xml.gz"
    "https://epghub.xyz/epg/EPG-DELUXEMUSIC.xml.gz"
    "https://epghub.xyz/epg/EPG-DISTROTV.xml.gz"
    "https://epghub.xyz/epg/EPG-DRAFTKINGS.xml.gz"
    "https://epghub.xyz/epg/EPG-FANDUEL.xml.gz"
    "https://epghub.xyz/epg/EPG-PEACOCK.xml.gz"
    "https://epghub.xyz/epg/EPG-POWERNATION.xml.gz"
    "https://epghub.xyz/epg/EPG-SPORTKLUB.xml.gz"
    "https://epghub.xyz/epg/EPG-SSPORTPLUS.xml.gz"
    "https://epghub.xyz/epg/EPG-TBNPLUS.xml.gz"
    "https://epghub.xyz/epg/EPG-THESPORTPLUS.xml.gz"
    "https://epghub.xyz/epg/EPG-UK.xml.gz"
    "https://epghub.xyz/epg/EPG-US.xml.gz"
    "https://epghub.xyz/epg/EPG-US-LOCALS.xml.gz"
    "https://epghub.xyz/epg/EPG-US-SPORTS.xml.gz"
    "https://epghub.xyz/epg/EPG-VOA.xml.gz"
)

echo "[$(date)] Starting EPG update..."

# Download all EPG files
for url in "${EPG_SOURCES[@]}"; do
    filename=$(basename "$url")
    echo "  Downloading $filename..."
    curl -sL "$url" -o "$EPG_DIR/$filename" 2>/dev/null
done

# Combine into single XMLTV file
echo "  Combining EPG files..."
python3 << 'PYEOF'
import gzip
import os
import xml.etree.ElementTree as ET
from pathlib import Path

epg_dir = Path("/tank/media/livetv/epg")
output = "/tank/media/livetv/combined-epg.xml"

# Create combined root
root = ET.Element("tv")
root.set("generator-info-name", "NAS Media Server EPG Combiner")

channels = {}
programmes = []

for gz_file in epg_dir.glob("*.xml.gz"):
    try:
        with gzip.open(gz_file, 'rt', encoding='utf-8') as f:
            content = f.read()
        
        # Parse XML
        tree = ET.fromstring(content)
        
        # Extract channels (dedupe by id)
        for channel in tree.findall('.//channel'):
            ch_id = channel.get('id')
            if ch_id and ch_id not in channels:
                channels[ch_id] = channel
        
        # Extract programmes
        for prog in tree.findall('.//programme'):
            programmes.append(prog)
        
        print(f"  Parsed {gz_file.name}: {len(tree.findall('.//channel'))} channels, {len(tree.findall('.//programme'))} programmes")
    except Exception as e:
        print(f"  Error parsing {gz_file.name}: {e}")

# Add channels to root
for channel in channels.values():
    root.append(channel)

# Add programmes to root
for prog in programmes:
    root.append(prog)

# Write combined file
tree = ET.ElementTree(root)
ET.indent(tree, space="  ")
tree.write(output, encoding='utf-8', xml_declaration=True)

print(f"\nCombined EPG: {len(channels)} channels, {len(programmes)} programmes")
print(f"Output: {output}")
PYEOF

# Compress a copy for faster loading
gzip -kf "$COMBINED" 2>/dev/null

echo "[$(date)] EPG update complete!"
echo "  Combined EPG: $COMBINED"
echo "  Compressed: ${COMBINED}.gz"

# Update Pluto TV M3U from EPG
echo "  Updating Pluto TV M3U..."
python3 << 'PYEOF'
import re

# Download fresh EPG
import urllib.request
urllib.request.urlretrieve("https://i.mjh.nz/PlutoTV/us.xml", "/tank/media/livetv/epg/pluto-us.xml")

# Parse and generate M3U
with open('/tank/media/livetv/epg/pluto-us.xml', 'r', encoding='utf-8', errors='ignore') as f:
    content = f.read()

channels = []
for match in re.finditer(r'<channel id="([^"]*)">\s*<display-name>([^<]*)</display-name>', content):
    channels.append({'id': match.group(1), 'name': match.group(2)})

m3u = ['#EXTM3U x-tvg-url="http://192.168.10.239:8888/livetv/epg/pluto-us.xml"']
for ch in channels:
    m3u.append(f'#EXTINF:-1 tvg-id="{ch["id"]}" group-title="Pluto TV",{ch["name"]}')
    m3u.append(f'https://jmp2.uk/plu-{ch["id"]}.m3u8')

with open('/tank/media/livetv/pluto-tv-us.m3u', 'w') as f:
    f.write('\n'.join(m3u))

print(f"  Updated Pluto TV: {len(channels)} channels")
PYEOF
