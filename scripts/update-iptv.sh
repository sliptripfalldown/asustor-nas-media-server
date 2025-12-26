#!/bin/bash
# Update and filter IPTV channels for Jellyfin
# Run daily to keep channels fresh

set -e

LIVETV_DIR="/tank/media/livetv"
SCRIPTS_DIR="/home/anon/nas-media-server/scripts"

echo "[$(date)] Starting IPTV update..."

EPG_DIR="$LIVETV_DIR/epg"
mkdir -p "$EPG_DIR"

# Download service-specific EPG files
echo "  Downloading EPG files..."
curl -sL "https://i.mjh.nz/PlutoTV/us.xml" -o "$EPG_DIR/pluto-us.xml" &
curl -sL "https://i.mjh.nz/SamsungTVPlus/us.xml" -o "$EPG_DIR/samsungtvplus.xml" &
curl -sL "https://i.mjh.nz/Plex/us.xml" -o "$EPG_DIR/plex.xml" &
curl -sL "https://i.mjh.nz/Roku/all.xml" -o "$EPG_DIR/roku.xml" &
curl -sL "https://i.mjh.nz/Stirr/all.xml" -o "$EPG_DIR/stirr.xml" &
wait
echo "  EPG downloads complete"

# Download fresh M3U sources
echo "  Downloading iptv-org US channels..."
curl -sL "https://iptv-org.github.io/iptv/countries/us.m3u" -o "$LIVETV_DIR/iptv-org-us.m3u"

echo "  Downloading DistroTV channels..."
curl -sL "https://www.apsattv.com/distro.m3u" -o "$LIVETV_DIR/distro.m3u" || true

echo "  Downloading mjh.nz channels..."
curl -sL "https://i.mjh.nz/all/kodi-tv.m3u8" -o "$LIVETV_DIR/mjh-all-tv.m3u" || true

# Run the filter script
echo "  Filtering channels..."
python3 "$SCRIPTS_DIR/filter-iptv-channels.py" \
    --input "$LIVETV_DIR/iptv-org-us.m3u" "$LIVETV_DIR/distro.m3u" "$LIVETV_DIR/mjh-all-tv.m3u" \
    --output "$LIVETV_DIR/curated-temp.m3u" \
    --epg "$LIVETV_DIR/combined-epg.xml" "$LIVETV_DIR/mjh-all-epg.xml" \
    --us-only \
    --no-religious 2>/dev/null || true

# Apply strict US filter
python3 << 'PYEOF'
import re

NON_US_STRICT = [
    'Hindi', 'Punjabi', 'Tamil', 'Telugu', 'Bengali', 'Marathi', 'Gujarati',
    'Kannada', 'Malayalam', 'Urdu', 'Arabic', 'Portuguese', 'Russian',
    'Chinese', 'Korean', 'Japanese', 'Turkish', 'Polish', 'Italian',
    'India', 'Pakistan', 'Bangladesh', 'Nepal', 'Mexico', 'Brazil',
    'UK', 'Britain', 'Canada', 'Australia', 'Africa', 'Saudi', 'Iran',
    'Russia', 'Ukraine', 'China', 'Japan', 'Korea', 'Taiwan',
    'ABP', 'NDTV', 'Zee', 'Star India', 'Colors', 'Aaj Tak', 'TV9',
    'Telemundo', 'Univision', 'Azteca', 'Al Arabiya', 'MBC', 'Globo',
]

def is_us(name, group):
    text = f"{name} {group}".lower()
    for ind in NON_US_STRICT:
        if ind.lower() in text:
            return False
    return True

try:
    with open('/tank/media/livetv/curated-temp.m3u', 'r') as f:
        content = f.read()
except:
    exit(0)

lines = content.split('\n')
output = ['#EXTM3U']

i = 0
while i < len(lines):
    line = lines[i].strip()
    if line.startswith('#EXTINF'):
        name = re.search(r',(.+)$', line)
        name = name.group(1).strip() if name else ''
        group = re.search(r'group-title="([^"]*)"', line)
        group = group.group(1) if group else ''

        url = ''
        for j in range(i + 1, min(i + 3, len(lines))):
            if lines[j].strip() and not lines[j].strip().startswith('#'):
                url = lines[j].strip()
                break

        if is_us(name, group) and url:
            output.append(line)
            output.append(url)
    i += 1

with open('/tank/media/livetv/curated-us-final.m3u', 'w') as f:
    f.write('\n'.join(output))

print(f"  Final channel count: {len([l for l in output if l.startswith('#EXTINF')])}")
PYEOF

# Clean up temp file
rm -f "$LIVETV_DIR/curated-temp.m3u"

# Generate M3U files from online EPG sources
echo "  Generating M3U files from online EPG sources..."
python3 << 'PYEOF'
import urllib.request
import re
import os

LIVETV_DIR = "/tank/media/livetv"

# Service configs: (name, epg_url, m3u_filename, stream_prefix, group_name)
SERVICES = [
    ("Pluto TV", "https://i.mjh.nz/PlutoTV/us.xml", "pluto-tv-us.m3u", "https://jmp2.uk/plu-", "Pluto TV"),
    ("Samsung TV Plus", "https://i.mjh.nz/SamsungTVPlus/us.xml", "samsungtvplus.m3u", "https://jmp2.uk/sam-", "Samsung TV Plus"),
    ("Plex", "https://i.mjh.nz/Plex/us.xml", "plex.m3u", "https://jmp2.uk/plex-", "Plex"),
    ("Roku", "https://i.mjh.nz/Roku/all.xml", "roku.m3u", "https://jmp2.uk/rok-", "Roku"),
    ("Stirr", "https://i.mjh.nz/Stirr/all.xml", "stirr.m3u", "https://jmp2.uk/stir-", "Stirr"),
]

def generate_m3u_from_epg(service_name, epg_url, m3u_file, stream_prefix, group_name):
    try:
        print(f"    Fetching {service_name} EPG...")
        req = urllib.request.Request(epg_url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=60) as response:
            content = response.read().decode('utf-8', errors='ignore')

        # Extract channels from EPG
        channels = []
        for match in re.finditer(r'<channel id="([^"]*)">.*?<display-name[^>]*>([^<]*)</display-name>', content, re.DOTALL):
            ch_id = match.group(1)
            ch_name = match.group(2).strip()
            if ch_id and ch_name:
                channels.append({'id': ch_id, 'name': ch_name})

        if not channels:
            print(f"    Warning: No channels found for {service_name}")
            return 0

        # Generate M3U
        m3u_lines = [f'#EXTM3U x-tvg-url="{epg_url}"']
        for ch in channels:
            m3u_lines.append(f'#EXTINF:-1 tvg-id="{ch["id"]}" group-title="{group_name}",{ch["name"]}')
            m3u_lines.append(f'{stream_prefix}{ch["id"]}.m3u8')

        m3u_path = os.path.join(LIVETV_DIR, m3u_file)
        with open(m3u_path, 'w') as f:
            f.write('\n'.join(m3u_lines))

        print(f"    {service_name}: {len(channels)} channels -> {m3u_file}")
        return len(channels)
    except Exception as e:
        print(f"    Error processing {service_name}: {e}")
        return 0

total = 0
for svc in SERVICES:
    total += generate_m3u_from_epg(*svc)

print(f"  Total channels across all services: {total}")
PYEOF

echo "[$(date)] IPTV update complete!"
