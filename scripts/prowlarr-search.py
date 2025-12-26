#!/usr/bin/env python3
"""
Prowlarr Search Tool - Search across indexers, sort by seeds, filter by language
Usage: prowlarr-search.py <query> [options]

Examples:
  prowlarr-search.py "python programming" --category ebooks --limit 50
  prowlarr-search.py "game of thrones" --category tv --english-only
  prowlarr-search.py "dune" --category movies --min-seeds 10
"""

import argparse
import xml.etree.ElementTree as ET
import urllib.request
import urllib.parse
import json
import sys
import os
from concurrent.futures import ThreadPoolExecutor, as_completed

# Configuration
PROWLARR_URL = os.environ.get("PROWLARR_URL", "http://10.200.200.2:9696")
PROWLARR_API_KEY = os.environ.get("PROWLARR_API_KEY", "")

if not PROWLARR_API_KEY:
    print("ERROR: PROWLARR_API_KEY environment variable not set")
    print("Get your API key from Prowlarr: Settings > General > API Key")
    print("Usage: PROWLARR_API_KEY=your_key python3 prowlarr-search.py ...")
    sys.exit(1)

# Category mappings (Newznab standard)
CATEGORIES = {
    "movies": "2000",
    "tv": "5000",
    "music": "3000",
    "audiobooks": "3030",
    "ebooks": "7000,7020,7030",
    "books": "7000,7020,7030",
    "comics": "7030",
    "games": "4000",
    "software": "4000",
    "xxx": "6000",
    "anime": "5070",
    "all": ""
}

# Non-English patterns to filter out
NON_ENGLISH_PATTERNS = [
    'french', 'français', 'vostfr', 'truefrench', 'vff', 'vf ',
    'german', 'deutsch', 'german.dl',
    'spanish', 'español', 'castellano', 'latino',
    'italian', 'italiano', 'ita ',
    'russian', 'русский', 'rus ',
    'portuguese', 'português', 'dublado',
    'polish', 'polski', 'lektor.pl',
    'dutch', 'nederlands', 'flemish',
    'swedish', 'svenska',
    'danish', 'dansk',
    'norwegian', 'norsk',
    'finnish', 'suomi',
    'japanese', '日本語', 'jap ',
    'korean', '한국어', 'kor ',
    'chinese', '中文', 'mandarin', 'cantonese',
    'hindi', 'हिंदी',
    'arabic', 'عربي',
    'turkish', 'türkçe',
    'thai', 'ไทย',
    'vietnamese', 'tiếng việt',
    'czech', 'český',
    'hungarian', 'magyar',
    'romanian', 'română',
    'greek', 'ελληνικά',
    'hebrew', 'עברית',
    '.ita.', '.fra.', '.deu.', '.esp.', '.rus.', '.por.', '.pol.',
    'multi.', 'multilang',
]

def get_indexers():
    """Get list of enabled indexers from Prowlarr"""
    url = f"{PROWLARR_URL}/api/v1/indexer"
    req = urllib.request.Request(url, headers={"X-Api-Key": PROWLARR_API_KEY})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            indexers = json.loads(resp.read())
            return [(i['id'], i['name']) for i in indexers if i.get('enable', True)]
    except Exception as e:
        print(f"Error fetching indexers: {e}", file=sys.stderr)
        return []

def search_indexer(indexer_id, indexer_name, query, categories, browse_mode=False):
    """Search a single indexer via Torznab API"""
    params = {
        "apikey": PROWLARR_API_KEY,
    }

    if browse_mode:
        # Use RSS feed mode to get recent torrents
        params["t"] = "search"
        params["q"] = ""  # Empty query for browse
    else:
        params["t"] = "search"
        params["q"] = query

    if categories:
        params["cat"] = categories

    url = f"{PROWLARR_URL}/{indexer_id}/api?{urllib.parse.urlencode(params)}"

    results = []
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "prowlarr-search/1.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            xml_data = resp.read()
            root = ET.fromstring(xml_data)

            ns = {'torznab': 'http://torznab.com/schemas/2015/feed'}

            for item in root.findall('.//item'):
                title = item.find('title')
                title = title.text if title is not None else "Unknown"

                guid = item.find('guid')
                guid = guid.text if guid is not None else ""

                size_elem = item.find('size')
                size = int(size_elem.text) if size_elem is not None else 0

                link = item.find('link')
                link = link.text if link is not None else ""

                # Get torznab attributes
                seeders = 0
                leechers = 0
                for attr in item.findall('.//torznab:attr', ns):
                    name = attr.get('name')
                    value = attr.get('value', '0')
                    if name == 'seeders':
                        seeders = int(value)
                    elif name == 'peers':
                        leechers = int(value) - seeders if int(value) > seeders else 0

                results.append({
                    'title': title,
                    'seeders': seeders,
                    'leechers': leechers,
                    'size': size,
                    'indexer': indexer_name,
                    'guid': guid,
                    'link': link,
                })
    except Exception as e:
        pass  # Silently skip failed indexers

    return results

def is_likely_english(title):
    """Check if title is likely English content"""
    title_lower = title.lower()

    # Check for non-English patterns
    for pattern in NON_ENGLISH_PATTERNS:
        if pattern in title_lower:
            return False

    # Check for non-ASCII characters (Japanese, Chinese, Korean, Cyrillic, etc.)
    non_ascii_count = sum(1 for c in title if ord(c) > 127)
    # If more than 20% non-ASCII, likely not English
    if len(title) > 0 and non_ascii_count / len(title) > 0.2:
        return False

    # Check for specific character ranges
    for char in title:
        code = ord(char)
        # Japanese Hiragana, Katakana, CJK
        if 0x3040 <= code <= 0x30FF or 0x4E00 <= code <= 0x9FFF:
            return False
        # Korean Hangul
        if 0xAC00 <= code <= 0xD7AF:
            return False
        # Cyrillic
        if 0x0400 <= code <= 0x04FF:
            return False
        # Arabic
        if 0x0600 <= code <= 0x06FF:
            return False

    return True

def parse_add_indices(add_str, max_idx):
    """Parse add string into list of indices.

    Supports:
      - 'all' - all results
      - '1-10' - range
      - '1,3,5' - individual items
      - '1-5,10,15-20' - mixed
    """
    indices = []
    add_str = add_str.strip().lower()

    if add_str == 'all':
        return list(range(1, max_idx + 1))

    for part in add_str.split(','):
        part = part.strip()
        if '-' in part:
            # Range like "1-10"
            try:
                start, end = part.split('-', 1)
                start = int(start.strip())
                end = int(end.strip())
                for i in range(start, end + 1):
                    if 1 <= i <= max_idx and i not in indices:
                        indices.append(i)
            except ValueError:
                continue
        else:
            # Single number
            try:
                i = int(part)
                if 1 <= i <= max_idx and i not in indices:
                    indices.append(i)
            except ValueError:
                continue

    return sorted(indices)

def format_size(size_bytes):
    """Format bytes to human readable"""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size_bytes < 1024:
            return f"{size_bytes:.1f}{unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f}PB"

def add_to_qbittorrent(link, category, save_path=None):
    """Add a torrent to qBittorrent via API"""
    import http.cookiejar

    qb_url = os.environ.get("QBITTORRENT_URL", "http://10.200.200.2:8080")
    qb_user = os.environ.get("QBITTORRENT_USER", "admin")
    qb_pass = os.environ.get("QBITTORRENT_PASS", "adminadmin")

    # Default save paths by category
    SAVE_PATHS = {
        "movies": "/tank/media/movies",
        "tv": "/tank/media/tv",
        "music": "/tank/media/music",
        "audiobooks": "/tank/media/audiobooks",
        "ebooks": "/tank/media/ebooks",
        "books": "/tank/media/ebooks",
        "comics": "/tank/media/comics",
        "games": "/tank/media/downloads",
        "anime": "/tank/media/tv",
    }

    if save_path is None:
        save_path = SAVE_PATHS.get(category, "/tank/media/downloads")

    cj = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

    try:
        # Login
        login_data = urllib.parse.urlencode({"username": qb_user, "password": qb_pass}).encode()
        opener.open(f"{qb_url}/api/v2/auth/login", login_data, timeout=10)

        # Add torrent
        boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
        body = f"""--{boundary}\r
Content-Disposition: form-data; name="urls"\r
\r
{link}\r
--{boundary}\r
Content-Disposition: form-data; name="savepath"\r
\r
{save_path}\r
--{boundary}\r
Content-Disposition: form-data; name="category"\r
\r
{category}\r
--{boundary}--\r
"""
        req = urllib.request.Request(
            f"{qb_url}/api/v2/torrents/add",
            data=body.encode(),
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"}
        )
        resp = opener.open(req, timeout=10)
        return resp.read().decode() == "Ok."
    except Exception as e:
        print(f"Error adding to qBittorrent: {e}", file=sys.stderr)
        return False

def main():
    parser = argparse.ArgumentParser(
        description="Search Prowlarr indexers for torrents",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Categories: movies, tv, music, audiobooks, ebooks, books, comics, games, anime, all

Examples:
  %(prog)s "python programming" -c ebooks              # Search ebooks
  %(prog)s "breaking bad" -c tv -e --limit 20          # English TV, top 20
  %(prog)s --browse -c movies -e --limit 50            # Browse top 50 movies
  %(prog)s --browse -c ebooks -e --add all             # Browse & add ALL results
  %(prog)s --browse -c ebooks -e --add 1-10            # Add results 1-10
  %(prog)s --browse -c ebooks -e --add 1,3,5,10-15     # Add specific + range
  %(prog)s "dune" -c movies --interactive              # Interactive add mode
        """
    )
    parser.add_argument("query", nargs="?", default="", help="Search query (optional with --browse)")
    parser.add_argument("-c", "--category", default="all",
                        choices=list(CATEGORIES.keys()),
                        help="Content category (default: all)")
    parser.add_argument("-l", "--limit", type=int, default=100,
                        help="Max results to show (default: 100)")
    parser.add_argument("-e", "--english-only", action="store_true",
                        help="Filter to likely English content")
    parser.add_argument("-m", "--min-seeds", type=int, default=0,
                        help="Minimum seeders required")
    parser.add_argument("-j", "--json", action="store_true",
                        help="Output as JSON")
    parser.add_argument("-i", "--indexer", type=int,
                        help="Search specific indexer ID only")
    parser.add_argument("--list-indexers", action="store_true",
                        help="List available indexers and exit")
    parser.add_argument("-b", "--browse", action="store_true",
                        help="Browse mode - get top seeded torrents without search query")
    parser.add_argument("-a", "--add", type=str,
                        help="Add to qBittorrent: 'all', '1-10', '1,3,5', or '1-5,10,15-20'")
    parser.add_argument("--interactive", action="store_true",
                        help="Interactive mode - prompt to add torrents after search")

    args = parser.parse_args()

    # List indexers mode
    if args.list_indexers:
        indexers = get_indexers()
        print(f"{'ID':>4}  Indexer Name")
        print("-" * 40)
        for idx_id, idx_name in sorted(indexers):
            print(f"{idx_id:>4}  {idx_name}")
        return

    # Get indexers
    if args.indexer:
        indexers = [(args.indexer, f"Indexer {args.indexer}")]
    else:
        indexers = get_indexers()

    if not indexers:
        print("No indexers available", file=sys.stderr)
        sys.exit(1)

    # Validate args
    if not args.query and not args.browse:
        print("Error: Either provide a search query or use --browse mode", file=sys.stderr)
        sys.exit(1)

    categories = CATEGORIES.get(args.category, "")
    browse_mode = args.browse or not args.query

    # Search all indexers in parallel
    all_results = []
    if browse_mode:
        print(f"Browsing {len(indexers)} indexers for top seeded {args.category} torrents...", file=sys.stderr)
    else:
        print(f"Searching {len(indexers)} indexers for '{args.query}'...", file=sys.stderr)

    with ThreadPoolExecutor(max_workers=10) as executor:
        futures = {
            executor.submit(search_indexer, idx_id, idx_name, args.query, categories, browse_mode): idx_name
            for idx_id, idx_name in indexers
        }

        for future in as_completed(futures):
            results = future.result()
            all_results.extend(results)

    # Filter results
    if args.english_only:
        all_results = [r for r in all_results if is_likely_english(r['title'])]

    if args.min_seeds > 0:
        all_results = [r for r in all_results if r['seeders'] >= args.min_seeds]

    # Sort by seeders (descending)
    all_results.sort(key=lambda x: x['seeders'], reverse=True)

    # Limit results
    all_results = all_results[:args.limit]

    # Output
    if args.json:
        print(json.dumps(all_results, indent=2))
    else:
        if not all_results:
            print("No results found")
            return

        print(f"\nFound {len(all_results)} results (sorted by seeders):\n")
        print(f"{'#':>3}  {'Seeds':>6} {'Lchs':>5} {'Size':>8}  {'Indexer':<20} Title")
        print("-" * 105)

        for idx, r in enumerate(all_results, 1):
            seeds = r['seeders']
            leechers = r['leechers']
            size = format_size(r['size'])
            indexer = r['indexer'][:19]
            title = r['title'][:60]

            # Color coding for seeds
            if seeds >= 100:
                seed_str = f"\033[92m{seeds:>6}\033[0m"  # Green
            elif seeds >= 10:
                seed_str = f"\033[93m{seeds:>6}\033[0m"  # Yellow
            else:
                seed_str = f"{seeds:>6}"

            print(f"{idx:>3}. {seed_str} {leechers:>5} {size:>8}  {indexer:<20} {title}")

        # Handle --add flag
        if args.add:
            indices = parse_add_indices(args.add, len(all_results))
            if not indices:
                print(f"\nNo valid indices to add.", file=sys.stderr)
            else:
                print(f"\nAdding {len(indices)} torrents to qBittorrent...")
                for idx in indices:
                    r = all_results[idx - 1]
                    if r.get('link'):
                        success = add_to_qbittorrent(r['link'], args.category)
                        status = "✓ Added" if success else "✗ Failed"
                        print(f"  {idx:>3}. {status}: {r['title'][:55]}")
                    else:
                        print(f"  {idx:>3}. ✗ No link: {r['title'][:55]}")

        # Handle --interactive mode
        if args.interactive:
            print("\nEnter indices to add (e.g., '1-10', '1,3,5', 'all'), or 'q' to quit:")
            try:
                user_input = input("> ").strip()
                if user_input.lower() != 'q' and user_input:
                    indices = parse_add_indices(user_input, len(all_results))
                    if indices:
                        print(f"\nAdding {len(indices)} torrents to qBittorrent...")
                        for idx in indices:
                            r = all_results[idx - 1]
                            if r.get('link'):
                                success = add_to_qbittorrent(r['link'], args.category)
                                status = "✓ Added" if success else "✗ Failed"
                                print(f"  {idx:>3}. {status}: {r['title'][:55]}")
                            else:
                                print(f"  {idx:>3}. ✗ No link: {r['title'][:55]}")
                    else:
                        print("No valid indices provided.")
            except (KeyboardInterrupt, EOFError):
                print("\nCancelled.")

if __name__ == "__main__":
    main()
