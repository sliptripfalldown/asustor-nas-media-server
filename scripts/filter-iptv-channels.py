#!/usr/bin/env python3
"""
Filter IPTV M3U channels:
- Keep only US-based channels
- Remove religious channels
- Optionally filter to only channels with EPG data
- Test if streams are actually working
"""

import re
import gzip
import subprocess
import concurrent.futures
from pathlib import Path
import argparse

# Religious keywords to filter out
RELIGIOUS_KEYWORDS = [
    'church', 'jesus', 'christ', 'christian', 'gospel', 'bible', 'faith',
    'prayer', 'worship', 'ministry', 'ministries', 'pastor', 'sermon',
    'catholic', 'baptist', 'methodist', 'lutheran', 'episcopal', 'orthodox',
    'jewish', 'torah', 'kosher', 'islam', 'muslim', 'quran', 'allah',
    'hindu', 'buddhist', 'sikh', 'religious', 'god tv', 'tbn', 'daystar',
    'ewtn', 'ctv', 'salvation', 'healing', 'miracle', 'angel', 'heaven',
    'trinity', 'divine', 'blessed', 'holy', 'spirit', 'apostolic',
    'pentecostal', 'evangelical', 'televangelism', 'preacher', 'revival',
    'hillsong', 'bethel', 'creflo', 'joel osteen', 'kenneth copeland',
    'benny hinn', 'joyce meyer', '3abn', 'hope channel', 'upliftv',
    'inspiration', 'word network', 'son life', 'victory channel',
    'god\'s learning', 'juce tv', 'smile of a child', 'nrb', 'fetv'
]

# Non-US country indicators to filter out
NON_US_INDICATORS = [
    '🇬🇧', '🇨🇦', '🇦🇺', '🇩🇪', '🇫🇷', '🇪🇸', '🇮🇹', '🇧🇷', '🇲🇽', '🇯🇵',
    '🇰🇷', '🇨🇳', '🇮🇳', '🇷🇺', '🇵🇱', '🇳🇱', '🇧🇪', '🇦🇹', '🇨🇭', '🇸🇪',
    '🇳🇴', '🇩🇰', '🇫🇮', '🇵🇹', '🇬🇷', '🇹🇷', '🇮🇱', '🇦🇪', '🇸🇦', '🇪🇬',
    '🇿🇦', '🇳🇬', '🇰🇪', '🇵🇭', '🇮🇩', '🇹🇭', '🇻🇳', '🇲🇾', '🇸🇬', '🇭🇰',
    '🇹🇼', '🇦🇷', '🇨🇱', '🇨🇴', '🇵🇪', '🇻🇪', '🇵🇰', '🇧🇩', '🇱🇰', '🇳🇵',
    'UK:', 'CA:', 'AU:', 'DE:', 'FR:', 'ES:', 'IT:', 'BR:', 'MX:', 'IN:',
    '(UK)', '(CA)', '(AU)', '(DE)', '(FR)', '(ES)', '(IT)', '(BR)', '(MX)',
    'United Kingdom', 'Canada', 'Australia', 'Germany', 'France', 'Spain',
    'Italy', 'Brazil', 'Mexico', 'India', 'Russia', 'China', 'Japan',
    'Arabic', 'Hindi', 'Spanish', 'Portuguese', 'French', 'German',
    'Korean', 'Chinese', 'Japanese', 'Russian', 'Turkish', 'Polish',
    'Telemundo', 'Univision', 'Azteca',  # Spanish-language US but often foreign content
]

# US indicators (positive match)
US_INDICATORS = [
    '🇺🇸', 'US:', 'USA:', '(US)', '(USA)', 'United States',
    'ABC', 'CBS', 'NBC', 'FOX', 'CNN', 'MSNBC', 'ESPN', 'NFL', 'NBA', 'MLB',
    'PBS', 'CW', 'AMC', 'FX', 'TNT', 'TBS', 'USA Network', 'Syfy', 'Bravo',
    'HGTV', 'Food Network', 'Discovery', 'History', 'A&E', 'Lifetime',
    'Comedy Central', 'MTV', 'VH1', 'BET', 'Nickelodeon', 'Cartoon Network',
    'Disney', 'Freeform', 'Hallmark', 'Paramount', 'Showtime', 'HBO', 'Starz',
    'Cinemax', 'Epix', 'Weather Channel', 'C-SPAN', 'Bloomberg', 'CNBC',
    'Newsmax', 'OAN', 'Pluto', 'Tubi', 'Roku', 'Peacock', 'Xumo',
]


def is_religious(name, group=''):
    """Check if channel is religious."""
    text = f"{name} {group}".lower()
    return any(kw in text for kw in RELIGIOUS_KEYWORDS)


def is_likely_us(name, group=''):
    """Check if channel is likely US-based."""
    text = f"{name} {group}"

    # Negative indicators (non-US)
    for indicator in NON_US_INDICATORS:
        if indicator.lower() in text.lower():
            return False

    # Positive indicators (US)
    for indicator in US_INDICATORS:
        if indicator.lower() in text.lower():
            return True

    # Default: include if no clear country indicator
    return True


def load_epg_channel_ids(epg_paths):
    """Load all channel IDs from EPG files."""
    ids = set()

    for epg_path in epg_paths:
        try:
            if epg_path.endswith('.gz'):
                with gzip.open(epg_path, 'rt', encoding='utf-8', errors='ignore') as f:
                    content = f.read()
            else:
                with open(epg_path, 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read()

            # Extract channel IDs
            for match in re.finditer(r'<channel\s+id="([^"]*)"', content):
                ids.add(match.group(1).lower())

        except Exception as e:
            print(f"  Warning: Could not load {epg_path}: {e}")

    return ids


def test_stream(url, timeout=5):
    """Test if a stream URL is working."""
    try:
        result = subprocess.run(
            ['ffprobe', '-v', 'quiet', '-i', url, '-show_entries', 'format=duration', '-of', 'csv=p=0'],
            timeout=timeout,
            capture_output=True
        )
        return result.returncode == 0
    except:
        return None  # Unknown


def parse_m3u(m3u_path):
    """Parse M3U file and extract channel info."""
    with open(m3u_path, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()

    channels = []
    lines = content.split('\n')
    header = lines[0] if lines[0].startswith('#EXTM3U') else '#EXTM3U'

    i = 0
    while i < len(lines):
        line = lines[i].strip()

        if line.startswith('#EXTINF'):
            # Extract channel name
            name_match = re.search(r',(.+)$', line)
            name = name_match.group(1).strip() if name_match else ''

            # Extract group
            group_match = re.search(r'group-title="([^"]*)"', line)
            group = group_match.group(1) if group_match else ''

            # Extract tvg-id
            tvg_match = re.search(r'tvg-id="([^"]*)"', line)
            tvg_id = tvg_match.group(1) if tvg_match else ''

            # Get URL (next non-comment line)
            url = ''
            for j in range(i + 1, min(i + 5, len(lines))):
                if lines[j].strip() and not lines[j].strip().startswith('#'):
                    url = lines[j].strip()
                    break

            if url:
                channels.append({
                    'name': name,
                    'group': group,
                    'tvg_id': tvg_id,
                    'url': url,
                    'extinf': line
                })

        i += 1

    return header, channels


def main():
    parser = argparse.ArgumentParser(description='Filter IPTV M3U channels')
    parser.add_argument('--input', '-i', required=True, nargs='+', help='Input M3U file(s)')
    parser.add_argument('--output', '-o', required=True, help='Output M3U file')
    parser.add_argument('--epg', '-e', nargs='+', help='EPG file(s) for filtering')
    parser.add_argument('--epg-only', action='store_true', help='Only include channels with EPG')
    parser.add_argument('--test-streams', action='store_true', help='Test if streams work (slow)')
    parser.add_argument('--us-only', action='store_true', default=True, help='Only US channels')
    parser.add_argument('--no-religious', action='store_true', default=True, help='Filter religious')
    parser.add_argument('--include-keywords', nargs='+', help='Must contain these keywords')
    parser.add_argument('--exclude-keywords', nargs='+', help='Must not contain these keywords')
    args = parser.parse_args()

    # Load EPG channel IDs if filtering by EPG
    epg_ids = set()
    if args.epg:
        print("Loading EPG channel IDs...")
        epg_ids = load_epg_channel_ids(args.epg)
        print(f"  Found {len(epg_ids)} EPG channel IDs")

    # Parse all input M3U files
    all_channels = []
    for m3u_path in args.input:
        print(f"Loading {m3u_path}...")
        header, channels = parse_m3u(m3u_path)
        all_channels.extend(channels)
        print(f"  Found {len(channels)} channels")

    print(f"\nTotal channels: {len(all_channels)}")

    # Filter channels
    filtered = []
    stats = {'religious': 0, 'non_us': 0, 'no_epg': 0, 'keyword': 0, 'dead': 0}

    print("Filtering channels...")

    for ch in all_channels:
        name = ch['name']
        group = ch['group']
        tvg_id = ch['tvg_id']

        # Filter religious
        if args.no_religious and is_religious(name, group):
            stats['religious'] += 1
            continue

        # Filter non-US
        if args.us_only and not is_likely_us(name, group):
            stats['non_us'] += 1
            continue

        # Filter by EPG
        if args.epg_only and epg_ids:
            if tvg_id.lower() not in epg_ids:
                stats['no_epg'] += 1
                continue

        # Custom keyword filters
        text = f"{name} {group}".lower()

        if args.include_keywords:
            if not any(kw.lower() in text for kw in args.include_keywords):
                stats['keyword'] += 1
                continue

        if args.exclude_keywords:
            if any(kw.lower() in text for kw in args.exclude_keywords):
                stats['keyword'] += 1
                continue

        filtered.append(ch)

    print(f"\nFiltering results:")
    print(f"  Religious removed: {stats['religious']}")
    print(f"  Non-US removed: {stats['non_us']}")
    print(f"  No EPG removed: {stats['no_epg']}")
    print(f"  Keyword filtered: {stats['keyword']}")
    print(f"  Remaining: {len(filtered)}")

    # Test streams if requested
    if args.test_streams and filtered:
        print(f"\nTesting {len(filtered)} streams (this may take a while)...")
        working = []

        with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
            futures = {executor.submit(test_stream, ch['url']): ch for ch in filtered}

            for i, future in enumerate(concurrent.futures.as_completed(futures)):
                ch = futures[future]
                result = future.result()
                if result is True or result is None:  # Working or unknown
                    working.append(ch)
                else:
                    stats['dead'] += 1

                if (i + 1) % 50 == 0:
                    print(f"  Tested {i + 1}/{len(filtered)}...")

        filtered = working
        print(f"  Dead streams removed: {stats['dead']}")
        print(f"  Working streams: {len(filtered)}")

    # Deduplicate by name
    seen_names = set()
    deduped = []
    for ch in filtered:
        if ch['name'].lower() not in seen_names:
            seen_names.add(ch['name'].lower())
            deduped.append(ch)

    if len(deduped) < len(filtered):
        print(f"  Duplicates removed: {len(filtered) - len(deduped)}")
        filtered = deduped

    # Sort by group then name
    filtered.sort(key=lambda x: (x['group'].lower(), x['name'].lower()))

    # Write output
    print(f"\nWriting {len(filtered)} channels to {args.output}")

    with open(args.output, 'w', encoding='utf-8') as f:
        f.write('#EXTM3U\n')
        for ch in filtered:
            f.write(f"{ch['extinf']}\n")
            f.write(f"{ch['url']}\n")

    print("Done!")

    # Show sample of included channels
    print(f"\nSample channels included:")
    for ch in filtered[:20]:
        print(f"  [{ch['group']}] {ch['name']}")


if __name__ == '__main__':
    main()
