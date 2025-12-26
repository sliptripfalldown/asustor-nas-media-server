#!/bin/bash
# Restart qBittorrent VPN service to prevent memory/CPU buildup
# Runs every 4 hours via cron
#
# Setup:
# 1. Copy to ~/.local/bin/restart-qbittorrent.sh
# 2. chmod +x ~/.local/bin/restart-qbittorrent.sh
# 3. Add sudoers rule (run as root):
#    echo "anon ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart qbittorrent-vpn.service" > /etc/sudoers.d/qbittorrent-restart
# 4. Add cron job:
#    crontab -e
#    0 */4 * * * /home/anon/.local/bin/restart-qbittorrent.sh

LOG="$HOME/.local/log/qbt-restart.log"
mkdir -p "$(dirname $LOG)"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restarting qBittorrent VPN service..." >> $LOG

# Get current stats before restart
STATS=$(ps aux | grep qbittorrent-nox | grep -v grep | awk '{print "CPU="$3"% MEM="$4"%"}')
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Before: $STATS" >> $LOG

# Restart the service (this also rotates to a new VPN server if available)
sudo systemctl restart qbittorrent-vpn.service 2>> $LOG

sleep 10

# Log result
if systemctl is-active --quiet qbittorrent-vpn.service; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restart successful" >> $LOG
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Restart failed!" >> $LOG
fi
