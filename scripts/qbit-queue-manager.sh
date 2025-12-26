#!/bin/bash
# Reorder qBittorrent queue: healthy torrents first, struggling ones last

QB_URL="${QB_URL:-http://10.200.200.2:8080}"
QB_USER="${QB_USER:-admin}"
QB_PASS="${QB_PASS:-adminadmin}"

# Login
curl -s -c /tmp/qb_mgr.txt -X POST "$QB_URL/api/v2/auth/login" -d "username=$QB_USER&password=$QB_PASS" > /dev/null

# Get ALL torrents that need downloading (queued or active)
curl -s -b /tmp/qb_mgr.txt "$QB_URL/api/v2/torrents/info" | python3 << 'PYTHON'
import sys
import json
import subprocess

data = json.load(sys.stdin)

# Filter to only downloading-related states
dl_states = ['downloading', 'stalledDL', 'queuedDL', 'metaDL', 'pausedDL', 'stoppedDL']
torrents = [t for t in data if t['state'] in dl_states]

if not torrents:
    print("No downloading torrents")
    sys.exit(0)

# Score each torrent (higher = healthier, should download first)
scored = []
for t in torrents:
    score = 0
    
    # Availability (1.0+ = fully available)
    avail = t.get('availability', 0)
    if avail >= 1.0:
        score += 100
    elif avail > 0:
        score += int(avail * 80)
    else:
        score -= 50  # No availability = very bad
    
    # Number of seeds
    seeds = t.get('num_seeds', 0)
    score += min(seeds * 3, 50)
    
    # Download speed (bytes/s -> KB/s)
    speed = t.get('dlspeed', 0) / 1024
    if speed > 500:
        score += 40
    elif speed > 100:
        score += 25
    elif speed > 10:
        score += 10
    
    # Penalize stalled/stuck states
    if t['state'] == 'stalledDL':
        score -= 30
    elif t['state'] == 'metaDL':
        score -= 40  # Can't even get metadata
    elif t['state'] in ['pausedDL', 'stoppedDL']:
        score -= 100  # Paused, lowest priority
    
    # Bonus for nearly complete
    progress = t.get('progress', 0)
    if progress > 0.9:
        score += 30  # Almost done, prioritize finishing
    elif progress > 0.5:
        score += 15
    
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

# Sort by score descending (healthiest first)
scored.sort(key=lambda x: -x['score'])

print(f"{'Score':<6} {'Prog%':<6} {'Seeds':<6} {'Avail':<6} {'KB/s':<8} {'State':<12} Name")
print("-" * 100)
for t in scored:
    print(f"{t['score']:<6} {t['progress']:<6.1f} {t['seeds']:<6} {t['avail']:<6.2f} {t['speed']:<8.0f} {t['state']:<12} {t['name']}")

print(f"\nTotal: {len(scored)} download queue torrents")

# Reorder: move each torrent to its correct position
print("\nReordering queue...")
for i, t in enumerate(reversed(scored)):
    subprocess.run([
        'curl', '-s', '-b', '/tmp/qb_mgr.txt', '-X', 'POST',
        'http://10.200.200.2:8080/api/v2/torrents/bottomPrio',
        '-d', f"hashes={t['hash']}"
    ], capture_output=True)

print("Done - healthy torrents now prioritized")
PYTHON
