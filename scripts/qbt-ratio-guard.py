#!/usr/bin/env python3
"""
qBittorrent Ratio Guard - Automatic protection against ratio abuse

Monitors torrents and takes action when:
1. Incomplete torrents exceed max ratio (stop seeding, keep downloading)
2. Complete torrents exceed max ratio (pause based on global settings)
3. Dead swarms detected (low availability + high ratio = remove)

Run via cron every 15-30 minutes:
  */15 * * * * /home/anon/nas-media-server/scripts/qbt-ratio-guard.py

Environment variables:
  QB_URL      - qBittorrent API URL (default: http://10.200.200.2:8080)
  QB_USER     - Username (default: admin)
  QB_PASS     - Password (default: adminadmin)
"""

import os
import sys
import json
import logging
import requests
from datetime import datetime

# Configuration
QB_URL = os.environ.get("QB_URL", "http://10.200.200.2:8080")
QB_USER = os.environ.get("QB_USER", "admin")
QB_PASS = os.environ.get("QB_PASS", "adminadmin")

# Thresholds
MAX_RATIO = 1.5                 # Stop seeding ANY torrent above this ratio
MAX_RATIO_INCOMPLETE = 1.0      # Stop seeding incomplete torrents above this (stricter)
MAX_RATIO_DEAD_SWARM = 5.0      # Consider removing if ratio exceeds this
MIN_AVAILABILITY_DEAD = 0.5     # Below this + high ratio = dead swarm
NOTIFY_RATIO = 1.0              # Log warning when ratio exceeds this

# Logging
LOG_FILE = "/var/log/qbt-ratio-guard.log"
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(LOG_FILE, mode='a') if os.access(os.path.dirname(LOG_FILE) or '/var/log', os.W_OK) else logging.NullHandler()
    ]
)
log = logging.getLogger(__name__)


class QBittorrentAPI:
    def __init__(self, url, username, password):
        self.url = url.rstrip('/')
        self.session = requests.Session()
        self._login(username, password)

    def _login(self, username, password):
        resp = self.session.post(
            f"{self.url}/api/v2/auth/login",
            data={"username": username, "password": password}
        )
        if resp.text != "Ok.":
            raise Exception(f"Login failed: {resp.text}")

    def get_torrents(self):
        resp = self.session.get(f"{self.url}/api/v2/torrents/info")
        return resp.json()

    def set_share_limits(self, hashes, ratio_limit=-2, seeding_time=-2, inactive_time=-2):
        """Set per-torrent share limits. -2 = use global, -1 = unlimited, 0 = no seeding"""
        self.session.post(
            f"{self.url}/api/v2/torrents/setShareLimits",
            data={
                "hashes": "|".join(hashes) if isinstance(hashes, list) else hashes,
                "ratioLimit": ratio_limit,
                "seedingTimeLimit": seeding_time,
                "inactiveSeedingTimeLimit": inactive_time
            }
        )

    def delete_torrents(self, hashes, delete_files=True):
        self.session.post(
            f"{self.url}/api/v2/torrents/delete",
            data={
                "hashes": "|".join(hashes) if isinstance(hashes, list) else hashes,
                "deleteFiles": str(delete_files).lower()
            }
        )

    def pause_torrents(self, hashes):
        self.session.post(
            f"{self.url}/api/v2/torrents/pause",
            data={"hashes": "|".join(hashes) if isinstance(hashes, list) else hashes}
        )


def calculate_ratio(torrent):
    downloaded = torrent.get('downloaded', 0)
    uploaded = torrent.get('uploaded', 0)

    if downloaded > 0:
        return uploaded / downloaded
    elif uploaded > 0:
        return float('inf')
    return 0.0


def format_size(bytes_val):
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if abs(bytes_val) < 1024:
            return f"{bytes_val:.1f}{unit}"
        bytes_val /= 1024
    return f"{bytes_val:.1f}PB"


def get_arr_api_key(config_path):
    """Extract API key from *arr config file"""
    try:
        with open(config_path) as f:
            import re
            match = re.search(r'<ApiKey>([^<]+)</ApiKey>', f.read())
            return match.group(1) if match else None
    except:
        return None


def trigger_arr_searches(dead_swarms):
    """Trigger re-searches in Radarr/Sonarr for dead swarm torrents"""
    # Get API keys
    radarr_key = get_arr_api_key(os.path.expanduser("~/.config/Radarr/config.xml"))
    sonarr_key = get_arr_api_key(os.path.expanduser("~/.config/Sonarr/config.xml"))

    for swarm in dead_swarms:
        category = swarm.get('category', '')
        name = swarm.get('name', '')

        try:
            if category == 'radarr' and radarr_key:
                # Find movie in Radarr queue and trigger search
                queue = requests.get(
                    "http://localhost:7878/api/v3/queue",
                    headers={"X-Api-Key": radarr_key}
                ).json()

                for item in queue.get('records', []):
                    if item.get('title', '') in name or name in item.get('title', ''):
                        movie_id = item.get('movieId')
                        if movie_id:
                            requests.post(
                                "http://localhost:7878/api/v3/command",
                                headers={"X-Api-Key": radarr_key, "Content-Type": "application/json"},
                                json={"name": "MoviesSearch", "movieIds": [movie_id]}
                            )
                            log.info(f"  Triggered Radarr re-search for movie ID {movie_id}")
                        break

            elif category == 'sonarr' and sonarr_key:
                # Find series in Sonarr queue and trigger search
                queue = requests.get(
                    "http://localhost:8989/api/v3/queue",
                    headers={"X-Api-Key": sonarr_key}
                ).json()

                for item in queue.get('records', []):
                    if item.get('title', '') in name or name in item.get('title', ''):
                        series_id = item.get('seriesId')
                        if series_id:
                            requests.post(
                                "http://localhost:8989/api/v3/command",
                                headers={"X-Api-Key": sonarr_key, "Content-Type": "application/json"},
                                json={"name": "SeriesSearch", "seriesId": series_id}
                            )
                            log.info(f"  Triggered Sonarr re-search for series ID {series_id}")
                        break

        except Exception as e:
            log.error(f"  Failed to trigger re-search for {name}: {e}")


def main():
    log.info("=== qBittorrent Ratio Guard Starting ===")

    try:
        qb = QBittorrentAPI(QB_URL, QB_USER, QB_PASS)
    except Exception as e:
        log.error(f"Failed to connect to qBittorrent: {e}")
        sys.exit(1)

    torrents = qb.get_torrents()
    log.info(f"Monitoring {len(torrents)} torrents")

    # Track actions
    stop_seeding = []      # Set ratio limit to 0
    dead_swarms = []       # Candidates for removal (log only, manual review)
    warnings = []          # High ratio warnings

    for t in torrents:
        name = t.get('name', 'Unknown')[:60]
        ratio = t.get('ratio', 0)  # Use qBittorrent's ratio directly
        progress = t.get('progress', 0)
        availability = t.get('availability', -1)
        state = t.get('state', '')
        current_limit = t.get('ratio_limit', -2)
        uploaded = t.get('uploaded', 0)
        is_complete = progress >= 1.0

        # Skip if already limited to 0 (no seeding)
        if current_limit == 0:
            continue

        # Skip if not actively seeding (already paused/stopped)
        if state in ('pausedUP', 'stoppedUP', 'pausedDL', 'stoppedDL'):
            continue

        # Determine the threshold based on completion status
        threshold = MAX_RATIO if is_complete else MAX_RATIO_INCOMPLETE

        # Check for abuse - applies to ALL torrents
        if ratio > threshold:
            stop_seeding.append({
                'hash': t['hash'],
                'name': name,
                'ratio': ratio,
                'uploaded': uploaded,
                'progress': progress,
                'availability': availability,
                'complete': is_complete
            })

            # Check if it's a dead swarm (incomplete with very high ratio and low availability)
            if not is_complete and ratio > MAX_RATIO_DEAD_SWARM and 0 <= availability < MIN_AVAILABILITY_DEAD:
                dead_swarms.append({
                    'hash': t['hash'],
                    'name': name,
                    'ratio': ratio,
                    'availability': availability,
                    'category': t.get('category', '')
                })

        elif ratio > NOTIFY_RATIO:
            warnings.append({
                'name': name,
                'ratio': ratio,
                'uploaded': uploaded,
                'progress': progress
            })

    # Take action: Stop seeding on abusive incomplete torrents
    if stop_seeding:
        hashes = [t['hash'] for t in stop_seeding]
        qb.set_share_limits(hashes, ratio_limit=0)

        log.warning(f"Stopped seeding on {len(stop_seeding)} abusive torrents:")
        for t in stop_seeding:
            ratio_str = f"{t['ratio']:.1f}" if t['ratio'] < 10000 else "INF"
            log.warning(f"  Ratio:{ratio_str}x Up:{format_size(t['uploaded'])} "
                       f"Prog:{t['progress']*100:.0f}% Avail:{t['availability']:.2f} - {t['name']}")

    # Handle dead swarms - delete and trigger re-search
    if dead_swarms:
        log.warning(f"REMOVING {len(dead_swarms)} DEAD SWARMS and triggering re-searches:")

        for t in dead_swarms:
            ratio_str = f"{t['ratio']:.1f}" if t['ratio'] < 10000 else "INF"
            log.warning(f"  Ratio:{ratio_str}x Avail:{t['availability']:.2f} - {t['name']}")

        # Delete the torrents and their files
        dead_hashes = [t['hash'] for t in dead_swarms]
        qb.delete_torrents(dead_hashes, delete_files=True)

        # Trigger re-searches in Radarr/Sonarr
        trigger_arr_searches(dead_swarms)

    # Remove completed torrents that hit ratio limit (keep files)
    completed_done = [t for t in stop_seeding if t.get('complete', False)]
    if completed_done:
        log.info(f"Removing {len(completed_done)} completed torrents that hit ratio limit (keeping files):")
        for t in completed_done:
            log.info(f"  Ratio:{t['ratio']:.1f}x - {t['name']}")
        done_hashes = [t['hash'] for t in completed_done]
        qb.delete_torrents(done_hashes, delete_files=False)

    # Log warnings
    if warnings:
        log.info(f"High ratio warnings ({len(warnings)}):")
        for t in warnings[:10]:  # Limit to 10
            log.info(f"  Ratio:{t['ratio']:.1f}x Up:{format_size(t['uploaded'])} - {t['name']}")

    # Summary
    log.info(f"Summary: {len(stop_seeding)} stopped, {len(dead_swarms)} dead swarms, {len(warnings)} warnings")
    log.info("=== Ratio Guard Complete ===")


if __name__ == "__main__":
    main()
