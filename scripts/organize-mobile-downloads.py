#!/usr/bin/env python3
"""
Move completed mobile downloads to their movie folders.

Scans /tank/media/downloads/mobile for completed downloads and moves
video files to the corresponding movie folder with "- Mobile" suffix.
"""

import os
import sys
import re
import shutil
from pathlib import Path

DOWNLOAD_DIR = "/tank/media/downloads/mobile"
MOVIES_DIR = "/tank/media/movies"


def normalize_name(name):
    """Normalize movie name for matching."""
    name = name.lower()
    # Remove common prefixes/suffixes
    name = re.sub(r'\b(episode|ep)\s*[ivxlcdm\d]+\s*', '', name)  # Episode VII -> ""
    name = re.sub(r'\b(the|a|an)\s+', '', name)  # Remove articles
    name = re.sub(r'\s*[:\-–]\s*', ' ', name)  # Normalize separators
    name = re.sub(r'[^\w\s]', '', name)  # Remove special chars
    name = re.sub(r'\s+', ' ', name).strip()  # Collapse whitespace
    return name


def find_movie_folder(name, year):
    """Find the movie folder that matches name and year."""
    target = f"{name} ({year})"

    # Build list of candidates with scores
    candidates = []

    for dirname in os.listdir(MOVIES_DIR):
        # Must have matching year
        if f"({year})" not in dirname:
            continue

        # Exact match
        if dirname.lower() == target.lower():
            return os.path.join(MOVIES_DIR, dirname)

        # Fuzzy match - remove special chars
        clean_dirname = re.sub(r'[^\w\s]', '', dirname.lower())
        clean_target = re.sub(r'[^\w\s]', '', target.lower())
        if clean_dirname == clean_target:
            return os.path.join(MOVIES_DIR, dirname)

        # Normalized match
        norm_dirname = normalize_name(dirname.replace(f"({year})", ""))
        norm_target = normalize_name(name)
        if norm_dirname == norm_target:
            return os.path.join(MOVIES_DIR, dirname)

        # Substring match - check if key words overlap
        dirname_words = set(norm_dirname.split())
        target_words = set(norm_target.split())
        overlap = len(dirname_words & target_words)
        if overlap >= min(len(dirname_words), len(target_words)) * 0.7:
            candidates.append((overlap, dirname))

    # Return best candidate if good enough
    if candidates:
        candidates.sort(reverse=True)
        best_overlap, best_dir = candidates[0]
        if best_overlap >= 2:  # At least 2 words match
            return os.path.join(MOVIES_DIR, best_dir)

    return None


def extract_movie_info(filename):
    """Extract movie name and year from filename."""
    # Common patterns
    patterns = [
        r"(.+?)[.\s](\d{4})[.\s]",  # Movie.Name.2021.1080p
        r"(.+?)\s*\((\d{4})\)",      # Movie Name (2021)
    ]

    for pattern in patterns:
        match = re.search(pattern, filename)
        if match:
            name = match.group(1).replace(".", " ").strip()
            year = match.group(2)
            return name, year

    return None, None


def find_video_file(path):
    """Find the main video file in a folder or return the file itself."""
    if os.path.isfile(path):
        if path.endswith((".mkv", ".mp4", ".avi")):
            return path
        return None

    # Find largest video file in folder
    largest = None
    largest_size = 0

    for root, dirs, files in os.walk(path):
        for f in files:
            if f.endswith((".mkv", ".mp4", ".avi")):
                filepath = os.path.join(root, f)
                size = os.path.getsize(filepath)
                if size > largest_size:
                    largest_size = size
                    largest = filepath

    return largest


def main():
    if not os.path.exists(DOWNLOAD_DIR):
        print(f"Download directory doesn't exist: {DOWNLOAD_DIR}")
        return

    print("Scanning for completed mobile downloads...")

    moved = 0
    for item in os.listdir(DOWNLOAD_DIR):
        item_path = os.path.join(DOWNLOAD_DIR, item)

        # Find the video file
        video_file = find_video_file(item_path)
        if not video_file:
            continue

        # Extract movie info from filename
        name, year = extract_movie_info(os.path.basename(video_file))
        if not name or not year:
            name, year = extract_movie_info(item)

        if not name or not year:
            print(f"  Skipping (can't parse): {item}")
            continue

        # Find target movie folder
        movie_folder = find_movie_folder(name, year)
        if not movie_folder:
            print(f"  Skipping (no match): {item} -> {name} ({year})")
            continue

        # Determine target filename (Jellyfin edition format)
        ext = os.path.splitext(video_file)[1]
        target_name = f"{os.path.basename(movie_folder)} {{edition-Mobile}}{ext}"
        target_path = os.path.join(movie_folder, target_name)

        if os.path.exists(target_path):
            print(f"  Already exists: {target_name}")
            continue

        print(f"  Moving: {os.path.basename(video_file)}")
        print(f"      -> {target_path}")

        try:
            shutil.move(video_file, target_path)
            moved += 1

            # Clean up empty folder if it was a directory
            if os.path.isdir(item_path):
                shutil.rmtree(item_path, ignore_errors=True)
        except Exception as e:
            print(f"  Error: {e}")

    print(f"\nMoved {moved} files to movie folders")


if __name__ == "__main__":
    main()
