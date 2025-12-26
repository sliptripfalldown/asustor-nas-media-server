#!/usr/bin/env python3
"""
Match M3U channels to EPG by channel name using fuzzy matching.
Creates a modified M3U with corrected tvg-id values.
"""

import re
import gzip
import xml.etree.ElementTree as ET
from pathlib import Path
from difflib import SequenceMatcher
import argparse

def load_epg_channels(epg_path):
    """Load channel names and IDs from EPG XML file."""
    channels = {}

    if epg_path.endswith('.gz'):
        with gzip.open(epg_path, 'rt', encoding='utf-8') as f:
            content = f.read()
    else:
        with open(epg_path, 'r', encoding='utf-8') as f:
            content = f.read()

    root = ET.fromstring(content)

    for channel in root.findall('.//channel'):
        ch_id = channel.get('id')
        display_name = channel.find('display-name')
        if ch_id and display_name is not None:
            name = display_name.text.strip() if display_name.text else ''
            # Store by lowercase name for matching
            channels[name.lower()] = {
                'id': ch_id,
                'name': name
            }

    return channels

def parse_m3u(m3u_path):
    """Parse M3U file and extract channel info."""
    with open(m3u_path, 'r', encoding='utf-8') as f:
        content = f.read()

    channels = []
    lines = content.split('\n')

    for i, line in enumerate(lines):
        if line.startswith('#EXTINF'):
            # Extract channel name (last part after last comma)
            match = re.search(r',(.+)$', line)
            name = match.group(1).strip() if match else ''

            # Extract current tvg-id
            tvg_match = re.search(r'tvg-id="([^"]*)"', line)
            tvg_id = tvg_match.group(1) if tvg_match else ''

            # Get the stream URL (next non-empty line)
            url = ''
            for j in range(i + 1, len(lines)):
                if lines[j].strip() and not lines[j].startswith('#'):
                    url = lines[j].strip()
                    break

            channels.append({
                'name': name,
                'tvg_id': tvg_id,
                'url': url,
                'original_line': line
            })

    return channels

def fuzzy_match(name, epg_channels, threshold=0.7):
    """Find best matching EPG channel using fuzzy matching."""
    name_lower = name.lower()

    # Try exact match first
    if name_lower in epg_channels:
        return epg_channels[name_lower], 1.0

    # Try fuzzy matching
    best_match = None
    best_score = 0

    for epg_name, epg_data in epg_channels.items():
        # Calculate similarity
        score = SequenceMatcher(None, name_lower, epg_name).ratio()

        # Also try matching without common suffixes
        clean_name = re.sub(r'\s*(hd|sd|fhd|uhd|4k|\+)$', '', name_lower, flags=re.IGNORECASE)
        clean_epg = re.sub(r'\s*(hd|sd|fhd|uhd|4k|\+)$', '', epg_name, flags=re.IGNORECASE)
        clean_score = SequenceMatcher(None, clean_name, clean_epg).ratio()

        score = max(score, clean_score)

        if score > best_score and score >= threshold:
            best_score = score
            best_match = epg_data

    return best_match, best_score

def main():
    parser = argparse.ArgumentParser(description='Match M3U channels to EPG')
    parser.add_argument('--m3u', required=True, help='Input M3U file')
    parser.add_argument('--epg', required=True, help='EPG XML file')
    parser.add_argument('--output', help='Output M3U file (optional)')
    parser.add_argument('--threshold', type=float, default=0.7, help='Match threshold (0-1)')
    parser.add_argument('--report-only', action='store_true', help='Only show matches, do not modify')
    args = parser.parse_args()

    print(f"Loading EPG from {args.epg}...")
    epg_channels = load_epg_channels(args.epg)
    print(f"  Found {len(epg_channels)} channels in EPG")

    print(f"\nLoading M3U from {args.m3u}...")
    m3u_channels = parse_m3u(args.m3u)
    print(f"  Found {len(m3u_channels)} channels in M3U")

    print(f"\nMatching channels (threshold: {args.threshold})...")
    matched = 0
    unmatched = 0
    results = []

    for ch in m3u_channels:
        match, score = fuzzy_match(ch['name'], epg_channels, args.threshold)

        if match:
            matched += 1
            results.append({
                'm3u_name': ch['name'],
                'epg_name': match['name'],
                'epg_id': match['id'],
                'score': score,
                'original': ch
            })
            if args.report_only:
                print(f"  [MATCH {score:.0%}] {ch['name']} -> {match['name']} ({match['id']})")
        else:
            unmatched += 1
            results.append({
                'm3u_name': ch['name'],
                'epg_name': None,
                'epg_id': None,
                'score': 0,
                'original': ch
            })
            if args.report_only:
                print(f"  [NO MATCH] {ch['name']}")

    print(f"\n=== Summary ===")
    print(f"  Matched: {matched}/{len(m3u_channels)} ({matched/len(m3u_channels)*100:.1f}%)")
    print(f"  Unmatched: {unmatched}/{len(m3u_channels)}")

    # Generate output M3U if requested
    if args.output and not args.report_only:
        print(f"\nGenerating output M3U: {args.output}")

        with open(args.m3u, 'r', encoding='utf-8') as f:
            content = f.read()

        for result in results:
            if result['epg_id']:
                old_line = result['original']['original_line']
                # Update tvg-id in the line
                if 'tvg-id="' in old_line:
                    new_line = re.sub(r'tvg-id="[^"]*"', f'tvg-id="{result["epg_id"]}"', old_line)
                else:
                    # Add tvg-id if not present
                    new_line = old_line.replace('#EXTINF:-1 ', f'#EXTINF:-1 tvg-id="{result["epg_id"]}" ')
                content = content.replace(old_line, new_line)

        with open(args.output, 'w', encoding='utf-8') as f:
            f.write(content)

        print(f"  Output written to {args.output}")

if __name__ == '__main__':
    main()
