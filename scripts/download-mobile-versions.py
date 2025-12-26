#!/usr/bin/env python3
"""
Download mobile-friendly versions of movies via Prowlarr/qBittorrent.

Searches for 1080p/720p WEB-DL or BluRay versions of movies that only have
large 4K/REMUX files, and downloads them as mobile alternatives.

Usage:
    python3 download-mobile-versions.py [--dry-run] [--limit N] [--movie "Name"]
"""

import os
import sys
import json
import time
import re
import argparse
import requests
from pathlib import Path
from urllib.parse import quote

# Configuration - uses environment variables with defaults
PROWLARR_URL = os.environ.get("PROWLARR_URL", "http://10.200.200.2:9696")
PROWLARR_API = os.environ.get("PROWLARR_API", "")  # Required - get from Prowlarr Settings > General

QBITTORRENT_URL = os.environ.get("QBITTORRENT_URL", "http://10.200.200.2:8080")
QBITTORRENT_USER = os.environ.get("QBITTORRENT_USER", "admin")
QBITTORRENT_PASS = os.environ.get("QBITTORRENT_PASS", "adminadmin")

MOVIES_DIR = "/tank/media/movies"
DOWNLOAD_DIR = "/tank/media/downloads/mobile"

# Search preferences (in order of preference)
QUALITY_PREFERENCES = [
    "1080p web",
    "1080p bluray",
    "1080p webrip",
    "720p web",
    "720p bluray",
]

# Minimum file size (GB) to consider source for needing mobile version
MIN_SOURCE_SIZE_GB = 4.0

# Max size for mobile version (GB) - skip if larger
MAX_MOBILE_SIZE_GB = 8.0

# Patterns to avoid (usually bad quality or wrong content)
AVOID_PATTERNS = [
    r"cam",
    r"hdcam",
    r"ts\b",
    r"telesync",
    r"hdts",
    r"screener",
    r"dvdscr",
    r"workprint",
    r"hindi",
    r"hin\b",
    r"tamil",
    r"telugu",
    r"dubbed",
    r"dual.audio",
    r"multi",
    r"rus\b",
    r"russian",
]

# Validate required API key
if not PROWLARR_API:
    print("ERROR: PROWLARR_API environment variable not set")
    print("Get your API key from Prowlarr: Settings > General > API Key")
    print("Usage: PROWLARR_API=your_key python3 download-mobile-versions.py")
    sys.exit(1)


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}")


def get_qbt_session():
    """Login to qBittorrent and return session."""
    session = requests.Session()
    resp = session.post(
        f"{QBITTORRENT_URL}/api/v2/auth/login",
        data={"username": QBITTORRENT_USER, "password": QBITTORRENT_PASS}
    )
    if resp.text != "Ok.":
        raise Exception(f"qBittorrent login failed: {resp.text}")
    return session


def search_prowlarr(query, categories=[2000]):
    """Search Prowlarr for torrents."""
    params = {
        "query": query,
        "categories": categories,  # 2000 = Movies
        "type": "search",
    }
    headers = {"X-Api-Key": PROWLARR_API}

    try:
        resp = requests.get(
            f"{PROWLARR_URL}/api/v1/search",
            params=params,
            headers=headers,
            timeout=60
        )
        resp.raise_for_status()
        return resp.json()
    except Exception as e:
        log(f"  Search error: {e}")
        return []


def score_result(result, movie_name, year):
    """Score a search result based on quality preferences."""
    title = result.get("title", "").lower()
    size_gb = result.get("size", 0) / (1024**3)
    seeders = result.get("seeders", 0)

    # Skip if too large
    if size_gb > MAX_MOBILE_SIZE_GB:
        return -1000, "too large"

    # Skip if too small (probably fake or bad quality)
    if size_gb < 0.5:
        return -1000, "too small"

    # Skip avoided patterns
    for pattern in AVOID_PATTERNS:
        if re.search(pattern, title, re.IGNORECASE):
            return -1000, f"avoided pattern: {pattern}"

    # Must contain year
    if year and year not in title:
        return -500, "wrong year"

    # Score based on quality preference
    score = 0
    quality_match = None

    for i, pref in enumerate(QUALITY_PREFERENCES):
        pref_parts = pref.lower().split()
        if all(p in title for p in pref_parts):
            score += (len(QUALITY_PREFERENCES) - i) * 100
            quality_match = pref
            break

    if not quality_match:
        return -100, "no quality match"

    # Bonus for x264/h264 (more compatible than x265)
    if "x264" in title or "h264" in title or "h.264" in title:
        score += 50

    # Bonus for good release groups
    good_groups = ["yts", "yify", "sparks", "geckos", "rarbg", "ettv"]
    for group in good_groups:
        if group in title:
            score += 30
            break

    # Bonus for seeders (capped)
    score += min(seeders, 100)

    # Prefer smaller files (within reason)
    if 1.0 <= size_gb <= 3.0:
        score += 20
    elif 3.0 < size_gb <= 5.0:
        score += 10

    return score, quality_match


def find_best_torrent(movie_name, year):
    """Search for the best mobile-friendly torrent for a movie."""
    # Try different search queries
    queries = [
        f"{movie_name} {year} 1080p",
        f"{movie_name} {year} 720p",
        f"{movie_name} {year}",
    ]

    all_results = []

    for query in queries:
        log(f"  Searching: {query}")
        results = search_prowlarr(query)
        all_results.extend(results)
        time.sleep(1)  # Rate limit

    if not all_results:
        return None, "no results"

    # Score all results
    scored = []
    for result in all_results:
        score, reason = score_result(result, movie_name, year)
        if score > 0:
            scored.append((score, reason, result))

    if not scored:
        return None, "no suitable results"

    # Sort by score descending
    scored.sort(key=lambda x: x[0], reverse=True)

    best_score, best_quality, best_result = scored[0]
    return best_result, best_quality


def add_torrent(session, torrent_url, movie_dir, movie_name):
    """Add torrent to qBittorrent."""
    # Create download directory if needed
    os.makedirs(DOWNLOAD_DIR, exist_ok=True)

    data = {
        "urls": torrent_url,
        "savepath": DOWNLOAD_DIR,
        "category": "mobile",
        "tags": f"mobile,{movie_name}",
        "rename": f"{movie_name} - Mobile",
    }

    resp = session.post(
        f"{QBITTORRENT_URL}/api/v2/torrents/add",
        data=data
    )

    return resp.status_code == 200


def get_movies_needing_mobile():
    """Find movies that need mobile versions."""
    needs_mobile = []

    for dirname in sorted(os.listdir(MOVIES_DIR)):
        movie_dir = os.path.join(MOVIES_DIR, dirname)
        if not os.path.isdir(movie_dir):
            continue

        # Check if already has mobile version
        has_mobile = False
        has_large_source = False
        largest_file = None
        largest_size = 0

        for f in os.listdir(movie_dir):
            if not f.endswith((".mkv", ".mp4", ".avi")):
                continue

            filepath = os.path.join(movie_dir, f)
            lower = f.lower()

            if "mobile" in lower:
                has_mobile = True
                break

            try:
                size_gb = os.path.getsize(filepath) / (1024**3)
                if size_gb > largest_size:
                    largest_size = size_gb
                    largest_file = f
                if size_gb >= MIN_SOURCE_SIZE_GB:
                    has_large_source = True
            except:
                pass

        if not has_mobile and has_large_source:
            # Extract movie name and year
            match = re.match(r"(.+?)\s*\((\d{4})\)", dirname)
            if match:
                name, year = match.group(1).strip(), match.group(2)
                needs_mobile.append({
                    "dir": movie_dir,
                    "dirname": dirname,
                    "name": name,
                    "year": year,
                    "source_file": largest_file,
                    "source_size_gb": largest_size,
                })

    return needs_mobile


def main():
    parser = argparse.ArgumentParser(description="Download mobile-friendly movie versions")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be done")
    parser.add_argument("--limit", type=int, help="Limit number of movies to process")
    parser.add_argument("--movie", type=str, help="Process specific movie (partial name match)")
    parser.add_argument("--list", action="store_true", help="List movies needing mobile versions")
    args = parser.parse_args()

    log("=" * 60)
    log("Mobile Version Downloader")
    log("=" * 60)

    # Get movies needing mobile versions
    movies = get_movies_needing_mobile()

    # Filter by movie name if specified
    if args.movie:
        movies = [m for m in movies if args.movie.lower() in m["name"].lower()]

    log(f"Found {len(movies)} movies needing mobile versions")

    if args.list:
        print(f"\nMovies needing mobile versions ({len(movies)}):\n")
        for m in movies:
            print(f"  {m['dirname']}")
            print(f"    Source: {m['source_file']} ({m['source_size_gb']:.1f} GB)")
        return

    if args.limit:
        movies = movies[:args.limit]

    if not movies:
        log("No movies to process")
        return

    # Login to qBittorrent
    if not args.dry_run:
        try:
            qbt = get_qbt_session()
            log("Connected to qBittorrent")
        except Exception as e:
            log(f"Failed to connect to qBittorrent: {e}")
            return

    # Process each movie
    found = 0
    for i, movie in enumerate(movies, 1):
        log(f"\n[{i}/{len(movies)}] {movie['dirname']}")

        # Search for mobile-friendly version
        result, quality = find_best_torrent(movie["name"], movie["year"])

        if not result:
            log(f"  No suitable torrent found: {quality}")
            continue

        title = result.get("title", "Unknown")
        size_gb = result.get("size", 0) / (1024**3)
        seeders = result.get("seeders", 0)
        download_url = result.get("downloadUrl") or result.get("magnetUrl")

        log(f"  Found: {title[:60]}...")
        log(f"  Quality: {quality}, Size: {size_gb:.1f} GB, Seeders: {seeders}")

        if args.dry_run:
            log(f"  [DRY RUN] Would add to qBittorrent")
            found += 1
            continue

        if not download_url:
            log(f"  No download URL available")
            continue

        # Add to qBittorrent
        if add_torrent(qbt, download_url, movie["dir"], f"{movie['name']} ({movie['year']})"):
            log(f"  Added to qBittorrent!")
            found += 1
        else:
            log(f"  Failed to add torrent")

        time.sleep(2)  # Rate limit

    log(f"\n{'=' * 60}")
    log(f"Found/added {found} mobile versions")
    log("=" * 60)


if __name__ == "__main__":
    main()
