#!/bin/bash
# Setup daily restart for all *arr services
# Run with: sudo ./setup-arr-restart-cron.sh

set -e

USER="${SUDO_USER:-anon}"
HOME_DIR="/home/$USER"

echo "=== Setting up Daily *arr Services Restart ==="
echo ""

# 1. Create the restart script
echo "[1/4] Installing restart script..."
mkdir -p "$HOME_DIR/.local/bin"
mkdir -p "$HOME_DIR/.local/log"

cat > "$HOME_DIR/.local/bin/restart-arr-services.sh" << 'SCRIPT'
#!/bin/bash
# Restart all *arr services daily to prevent memory buildup

LOG="$HOME/.local/log/arr-restart.log"
mkdir -p "$(dirname $LOG)"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Daily *arr Services Restart ===" >> $LOG

SERVICES="radarr sonarr lidarr readarr prowlarr flaresolverr unpackerr"

for svc in $SERVICES; do
    if systemctl is-active --quiet $svc.service; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restarting $svc..." >> $LOG
        sudo /usr/bin/systemctl restart $svc.service 2>> $LOG
        sleep 2
        if systemctl is-active --quiet $svc.service; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')]   ✓ $svc restarted" >> $LOG
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')]   ✗ $svc FAILED" >> $LOG
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Skipping $svc (not running)" >> $LOG
    fi
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Complete ===" >> $LOG
echo "" >> $LOG
SCRIPT

chmod +x "$HOME_DIR/.local/bin/restart-arr-services.sh"
chown "$USER:$USER" "$HOME_DIR/.local/bin/restart-arr-services.sh"
echo "  Created: $HOME_DIR/.local/bin/restart-arr-services.sh"

# 2. Setup passwordless sudo for all services
echo "[2/4] Configuring passwordless sudo..."
cat > /etc/sudoers.d/arr-restart << EOF
# Allow $USER to restart *arr services without password
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart radarr.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart sonarr.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart lidarr.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart readarr.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart prowlarr.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart flaresolverr.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart unpackerr.service
EOF
chmod 440 /etc/sudoers.d/arr-restart
echo "  Created: /etc/sudoers.d/arr-restart"

# 3. Setup cron job (daily at 04:00)
echo "[3/4] Installing cron job..."
CRON_CMD="0 4 * * * $HOME_DIR/.local/bin/restart-arr-services.sh"
CRON_COMMENT="# Restart *arr services daily at 04:00"

# Get existing crontab (excluding any existing arr restart entries)
sudo -u "$USER" crontab -l 2>/dev/null | grep -v "restart-arr-services" | grep -v "Restart \*arr services" > /tmp/cron_tmp || true

# Add new entries
echo "$CRON_COMMENT" >> /tmp/cron_tmp
echo "$CRON_CMD" >> /tmp/cron_tmp

# Install crontab
sudo -u "$USER" crontab /tmp/cron_tmp
rm /tmp/cron_tmp
echo "  Cron job: Daily at 04:00"

# 4. Verify setup
echo "[4/4] Verifying setup..."
echo ""

# Test sudo access for one service
if sudo -u "$USER" sudo -n /usr/bin/systemctl restart radarr.service 2>/dev/null; then
    echo "  ✓ Passwordless sudo works"
else
    echo "  ✗ Passwordless sudo failed"
fi

# Verify cron
if sudo -u "$USER" crontab -l | grep -q "restart-arr-services"; then
    echo "  ✓ Cron job installed"
else
    echo "  ✗ Cron job not found"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Services restarted daily: radarr, sonarr, lidarr, readarr, prowlarr, flaresolverr, unpackerr"
echo "Schedule: 04:00 every day"
echo "Logs: $HOME_DIR/.local/log/arr-restart.log"
echo ""
