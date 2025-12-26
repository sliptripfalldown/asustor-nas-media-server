#!/bin/bash
# Restart all *arr services daily to prevent memory buildup
# Runs daily at 04:00 via cron

LOG="$HOME/.local/log/arr-restart.log"
mkdir -p "$(dirname $LOG)"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Daily *arr Services Restart ===" >> $LOG

# System services to restart (all services are now system-level)
SYSTEM_SERVICES="radarr sonarr lidarr prowlarr flaresolverr unpackerr lazylibrarian"

# Note: readarr is deprecated in favor of lazylibrarian

# Restart system services
for svc in $SYSTEM_SERVICES; do
    if systemctl is-active --quiet $svc.service; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restarting $svc..." >> $LOG
        sudo /usr/bin/systemctl restart $svc.service 2>> $LOG
        sleep 2
        if systemctl is-active --quiet $svc.service; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')]   ✓ $svc restarted successfully" >> $LOG
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')]   ✗ $svc failed to restart!" >> $LOG
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Skipping $svc (not running)" >> $LOG
    fi
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Restart complete ===" >> $LOG
echo "" >> $LOG
