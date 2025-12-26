#!/usr/bin/env python3
"""
Create mobile-friendly versions of movies for Jellyfin.

Scans movie folders and creates phone-optimized encodes:
- H.264 codec (universal compatibility)
- 1080p max resolution
- SDR (tonemapped from HDR if needed)
- AAC stereo audio
- SRT subtitles only (no PGS burn-in)
- ~4-8 Mbps bitrate (VPN-friendly)

Jellyfin will show version selector when multiple versions exist.

Usage:
    python3 create-mobile-versions.py [--dry-run] [--limit N] [--movie "Name"]
"""

import os
import sys
import json
import subprocess
import argparse
import re
from pathlib import Path
from datetime import datetime

MOVIES_DIR = "/tank/media/movies"
LOG_FILE = "/home/anon/nas-media-server/logs/mobile-encode.log"
STATE_FILE = "/home/anon/nas-media-server/logs/mobile-encode-state.json"

# Mobile encode settings
MOBILE_SETTINGS = {
    "video_codec": "libx264",
    "video_preset": "veryfast",  # Much faster encoding (good enough quality)
    "video_crf": "23",  # Standard quality (~3-5 Mbps for 1080p)
    "max_width": 1920,
    "max_height": 1080,
    "audio_codec": "aac",
    "audio_bitrate": "128k",  # Lower bitrate for mobile
    "audio_channels": "2",  # Stereo for mobile
    "hw_decode": False,  # Software decode (more compatible)
}

# Minimum file size (GB) to consider for mobile version
# Files smaller than this are likely already mobile-friendly
MIN_SIZE_GB = 4.0

# File patterns that indicate high-quality source
HQ_PATTERNS = [
    r"remux",
    r"2160p",
    r"4k",
    r"uhd",
    r"bluray",
    r"blu-ray",
    r"hdr",
    r"dv",  # Dolby Vision
    r"atmos",
    r"truehd",
    r"dts-hd",
    r"dts.hd",
    r"dts-x",
]

# Patterns that indicate already mobile-friendly
MOBILE_PATTERNS = [
    r"mobile",
    r"720p.*web",
    r"web.*720p",
    r"1080p.*web",
    r"web.*1080p",
    r"x264.*1080p",
    r"1080p.*x264",
]


def log(msg):
    """Log message to file and stdout."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{timestamp}] {msg}"
    print(line)
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")


def load_state():
    """Load processing state."""
    if os.path.exists(STATE_FILE):
        with open(STATE_FILE) as f:
            return json.load(f)
    return {"completed": [], "failed": [], "in_progress": None}


def save_state(state):
    """Save processing state."""
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)


def get_video_info(filepath):
    """Get video metadata using ffprobe."""
    cmd = [
        "ffprobe", "-v", "quiet",
        "-print_format", "json",
        "-show_format", "-show_streams",
        filepath
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        return json.loads(result.stdout)
    except Exception as e:
        log(f"  Error probing {filepath}: {e}")
        return None


def is_hdr(video_info):
    """Check if video is HDR."""
    if not video_info:
        return False
    for stream in video_info.get("streams", []):
        if stream.get("codec_type") == "video":
            # Check for HDR indicators
            color_transfer = stream.get("color_transfer", "")
            color_primaries = stream.get("color_primaries", "")
            if any(x in color_transfer for x in ["smpte2084", "arib-std-b67"]):
                return True
            if "bt2020" in color_primaries:
                return True
    return False


def get_resolution(video_info):
    """Get video resolution."""
    if not video_info:
        return 0, 0
    for stream in video_info.get("streams", []):
        if stream.get("codec_type") == "video":
            return stream.get("width", 0), stream.get("height", 0)
    return 0, 0


def has_mobile_version(movie_dir):
    """Check if movie folder already has a mobile version."""
    for f in os.listdir(movie_dir):
        if f.endswith((".mkv", ".mp4")):
            lower = f.lower()
            if "mobile" in lower or "- mobile" in lower:
                return True
            # Check for web-dl 1080p/720p which is usually mobile-friendly
            for pattern in MOBILE_PATTERNS:
                if re.search(pattern, lower):
                    return True
    return False


def find_best_source(movie_dir):
    """Find the best source file for encoding (only large HQ files)."""
    candidates = []

    for f in os.listdir(movie_dir):
        if not f.endswith((".mkv", ".mp4", ".avi")):
            continue

        filepath = os.path.join(movie_dir, f)
        lower = f.lower()

        # Skip if already a mobile version
        if "mobile" in lower:
            continue

        # Check file size - skip small files (already mobile-friendly)
        try:
            size_gb = os.path.getsize(filepath) / (1024**3)
            if size_gb < MIN_SIZE_GB:
                continue  # Skip files under 4GB
        except:
            continue

        # Calculate quality score
        score = 0
        for pattern in HQ_PATTERNS:
            if re.search(pattern, lower):
                score += 10

        # Prefer larger files (usually higher quality)
        score += min(size_gb * 2, 20)  # Cap at 20 points

        candidates.append((filepath, score, f, size_gb))

    if not candidates:
        return None

    # Return highest scoring file
    candidates.sort(key=lambda x: x[1], reverse=True)
    return candidates[0][0]


def get_movie_name(movie_dir):
    """Extract movie name and year from directory."""
    dirname = os.path.basename(movie_dir)
    # Match "Movie Name (Year)" pattern
    match = re.match(r"(.+?)\s*\((\d{4})\)", dirname)
    if match:
        return match.group(1).strip(), match.group(2)
    return dirname, ""


def create_mobile_version(source_path, movie_dir, dry_run=False):
    """Create mobile-friendly encode of the source file."""
    movie_name, year = get_movie_name(movie_dir)

    if year:
        output_name = f"{movie_name} ({year}) - Mobile.mkv"
    else:
        output_name = f"{movie_name} - Mobile.mkv"

    output_path = os.path.join(movie_dir, output_name)

    if os.path.exists(output_path):
        log(f"  Mobile version already exists: {output_name}")
        return True

    # Get source info
    info = get_video_info(source_path)
    width, height = get_resolution(info)
    hdr = is_hdr(info)

    log(f"  Source: {width}x{height}, HDR={hdr}")

    # Build ffmpeg command
    cmd = [
        "/usr/lib/jellyfin-ffmpeg/ffmpeg",
        "-i", source_path,
        "-map", "0:v:0",  # First video stream
        "-map", "0:a:0",  # First audio stream
    ]

    # Map SRT/text subtitles only (skip PGS)
    # We'll add subtitle mapping after checking streams
    if info:
        sub_idx = 0
        for i, stream in enumerate(info.get("streams", [])):
            if stream.get("codec_type") == "subtitle":
                codec = stream.get("codec_name", "")
                if codec in ["subrip", "srt", "ass", "ssa", "mov_text"]:
                    cmd.extend(["-map", f"0:s:{sub_idx}"])
                sub_idx += 1

    # Video filters
    vf_filters = []

    # Scale down if needed (always scale to max 1080p)
    if width > MOBILE_SETTINGS["max_width"] or height > MOBILE_SETTINGS["max_height"]:
        # Scale to fit within 1920x1080 while maintaining aspect ratio
        vf_filters.append(f"scale='min({MOBILE_SETTINGS['max_width']},iw)':'min({MOBILE_SETTINGS['max_height']},ih)':force_original_aspect_ratio=decrease")

    # Tonemap HDR to SDR if needed
    if hdr:
        vf_filters.append("zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p")

    # Ensure output is yuv420p for compatibility
    vf_filters.append("format=yuv420p")

    if vf_filters:
        cmd.extend(["-vf", ",".join(vf_filters)])

    # Video codec settings
    cmd.extend([
        "-c:v", MOBILE_SETTINGS["video_codec"],
        "-preset", MOBILE_SETTINGS["video_preset"],
        "-crf", MOBILE_SETTINGS["video_crf"],
        "-profile:v", "high",
        "-level", "4.1",
    ])

    # Audio settings
    cmd.extend([
        "-c:a", MOBILE_SETTINGS["audio_codec"],
        "-b:a", MOBILE_SETTINGS["audio_bitrate"],
        "-ac", MOBILE_SETTINGS["audio_channels"],
    ])

    # Subtitle settings (copy text subs)
    cmd.extend(["-c:s", "copy"])

    # Output
    cmd.extend([
        "-movflags", "+faststart",
        "-y",
        output_path
    ])

    if dry_run:
        log(f"  [DRY RUN] Would encode to: {output_name}")
        log(f"  Command: {' '.join(cmd[:20])}...")
        return True

    log(f"  Encoding to: {output_name}")
    log(f"  This may take a while...")

    try:
        # Run ffmpeg
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            universal_newlines=True
        )

        # Monitor progress
        for line in process.stdout:
            if "frame=" in line and "fps=" in line:
                # Extract progress info
                print(f"\r  {line.strip()[:80]}", end="", flush=True)

        print()  # Newline after progress

        process.wait()

        if process.returncode != 0:
            log(f"  ERROR: ffmpeg exited with code {process.returncode}")
            # Clean up partial file
            if os.path.exists(output_path):
                os.remove(output_path)
            return False

        # Verify output
        if os.path.exists(output_path):
            size_mb = os.path.getsize(output_path) / (1024**2)
            log(f"  Success! Output: {size_mb:.1f} MB")
            return True
        else:
            log(f"  ERROR: Output file not created")
            return False

    except Exception as e:
        log(f"  ERROR: {e}")
        if os.path.exists(output_path):
            os.remove(output_path)
        return False


def scan_movies(limit=None, movie_filter=None):
    """Scan movie directories and find those needing mobile versions."""
    needs_mobile = []
    has_mobile = []

    for dirname in sorted(os.listdir(MOVIES_DIR)):
        movie_dir = os.path.join(MOVIES_DIR, dirname)
        if not os.path.isdir(movie_dir):
            continue

        # Filter by movie name if specified
        if movie_filter and movie_filter.lower() not in dirname.lower():
            continue

        if has_mobile_version(movie_dir):
            has_mobile.append(dirname)
        else:
            source = find_best_source(movie_dir)
            if source:
                needs_mobile.append((movie_dir, source))

    log(f"Found {len(has_mobile)} movies with mobile versions")
    log(f"Found {len(needs_mobile)} movies needing mobile versions")

    if limit:
        needs_mobile = needs_mobile[:limit]

    return needs_mobile


def main():
    parser = argparse.ArgumentParser(description="Create mobile-friendly movie versions")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be done")
    parser.add_argument("--limit", type=int, help="Limit number of movies to process")
    parser.add_argument("--movie", type=str, help="Process specific movie (partial name match)")
    parser.add_argument("--list", action="store_true", help="List movies needing mobile versions")
    parser.add_argument("--status", action="store_true", help="Show processing status")
    args = parser.parse_args()

    state = load_state()

    if args.status:
        print(f"Completed: {len(state['completed'])}")
        print(f"Failed: {len(state['failed'])}")
        print(f"In progress: {state['in_progress']}")
        if state['failed']:
            print("\nFailed movies:")
            for f in state['failed']:
                print(f"  - {f}")
        return

    log("=" * 60)
    log("Mobile Version Creator")
    log("=" * 60)

    # Scan for movies needing mobile versions
    needs_mobile = scan_movies(limit=args.limit, movie_filter=args.movie)

    if args.list:
        print(f"\nMovies needing mobile versions ({len(needs_mobile)}):\n")
        for movie_dir, source in needs_mobile:
            dirname = os.path.basename(movie_dir)
            source_name = os.path.basename(source)
            size_gb = os.path.getsize(source) / (1024**3)
            print(f"  {dirname}")
            print(f"    Source: {source_name} ({size_gb:.1f} GB)")
        return

    if not needs_mobile:
        log("All movies have mobile versions!")
        return

    # Process each movie
    for i, (movie_dir, source) in enumerate(needs_mobile, 1):
        dirname = os.path.basename(movie_dir)

        # Skip if already completed
        if dirname in state["completed"]:
            log(f"[{i}/{len(needs_mobile)}] Skipping (already done): {dirname}")
            continue

        log(f"\n[{i}/{len(needs_mobile)}] Processing: {dirname}")

        state["in_progress"] = dirname
        save_state(state)

        success = create_mobile_version(source, movie_dir, dry_run=args.dry_run)

        if success:
            if not args.dry_run:
                state["completed"].append(dirname)
        else:
            state["failed"].append(dirname)

        state["in_progress"] = None
        save_state(state)

    log("\n" + "=" * 60)
    log(f"Completed: {len(state['completed'])}")
    log(f"Failed: {len(state['failed'])}")
    log("=" * 60)


if __name__ == "__main__":
    main()
