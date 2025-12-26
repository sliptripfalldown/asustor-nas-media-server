#!/usr/bin/env python3
"""Reorder qBittorrent queue: healthy torrents first, struggling ones last"""

import os
import requests
import sys

QB_URL = os.environ.get("QB_URL", "http://10.200.200.2:8080")
QB_USER = os.environ.get("QB_USER", "admin")
QB_PASS = os.environ.get("QB_PASS", "adminadmin")

# Create session and login
session = requests.Session()
r = session.post(f"{QB_URL}/api/v2/auth/login", data={"username": QB_USER, "password": QB_PASS})
if r.text != "Ok.":
    print(f"Login failed: {r.text}")
    sys.exit(1)

# Get all torrents
torrents = session.get(f"{QB_URL}/api/v2/torrents/info").json()

# Filter to downloading-related states
dl_states = ['downloading', 'stalledDL', 'queuedDL', 'metaDL', 'pausedDL', 'stoppedDL']
dl_torrents = [t for t in torrents if t['state'] in dl_states]

if not dl_torrents:
    print("No downloading torrents")
    sys.exit(0)

# Score each torrent
scored = []
for t in dl_torrents:
    score = 0
    avail = t.get('availability', 0)
    seeds = t.get('num_seeds', 0)
    speed = t.get('dlspeed', 0) / 1024
    progress = t.get('progress', 0)
    
    # Availability scoring
    if avail >= 1.0:
        score += 100
    elif avail > 0:
        score += int(avail * 80)
    else:
        score -= 50
    
    # Seeds scoring
    score += min(seeds * 3, 50)
    
    # Speed scoring
    if speed > 500: score += 40
    elif speed > 100: score += 25
    elif speed > 10: score += 10
    
    # State penalties
    if t['state'] == 'stalledDL': score -= 30
    elif t['state'] == 'metaDL': score -= 40
    elif t['state'] in ['pausedDL', 'stoppedDL']: score -= 100
    
    # Progress bonus
    if progress > 0.9: score += 30
    elif progress > 0.5: score += 15
    
    scored.append({
        'hash': t['hash'],
        'name': t['name'][:45],
        'score': score,
        'avail': avail,
        'seeds': seeds,
        'speed': speed,
        'progress': progress * 100,
        'state': t['state']
    })

# Sort by score descending
scored.sort(key=lambda x: -x['score'])

# Print status
print(f"{'Score':<6} {'Prog%':<6} {'Seeds':<6} {'Avail':<6} {'KB/s':<8} {'State':<12} Name")
print("-" * 100)
for t in scored:
    print(f"{t['score']:<6} {t['progress']:<6.1f} {t['seeds']:<6} {t['avail']:<6.2f} {t['speed']:<8.0f} {t['state']:<12} {t['name']}")

print(f"\nTotal: {len(scored)} torrents in download queue")

# Reorder queue
print("\nReordering...")
for t in reversed(scored):
    session.post(f"{QB_URL}/api/v2/torrents/bottomPrio", data={"hashes": t['hash']})

print("Done - healthy torrents prioritized")
