#!/bin/bash
# Setup passwordless qBittorrent restart for user and cron
# Run with: sudo ./setup-qbt-restart-cron.sh

set -e

USER="${SUDO_USER:-anon}"
HOME_DIR="/home/$USER"

echo "=== Setting up qBittorrent Auto-Restart ==="
echo ""

# 1. Create the restart script
echo "[1/4] Installing restart script..."
mkdir -p "$HOME_DIR/.local/bin"
mkdir -p "$HOME_DIR/.local/log"

cat > "$HOME_DIR/.local/bin/restart-qbittorrent.sh" << 'SCRIPT'
#!/bin/bash
# Restart qBittorrent to prevent memory/CPU buildup

LOG="$HOME/.local/log/qbt-restart.log"
mkdir -p "$(dirname $LOG)"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restarting qBittorrent..." >> $LOG

# Get current stats before restart
STATS=$(ps aux | grep qbittorrent-nox | grep -v grep | awk '{print "CPU="$3"% MEM="$4"%"}')
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Before: $STATS" >> $LOG

# Restart the service (this also rotates to a new VPN server if available)
sudo /usr/bin/systemctl restart qbittorrent-vpn.service 2>> $LOG

sleep 10

# Log result
if systemctl is-active --quiet qbittorrent-vpn.service; then
    STATS=$(ps aux | grep qbittorrent-nox | grep -v grep | awk '{print "CPU="$3"% MEM="$4"%"}')
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restart successful. After: $STATS" >> $LOG
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Restart failed!" >> $LOG
fi
SCRIPT

chmod +x "$HOME_DIR/.local/bin/restart-qbittorrent.sh"
chown "$USER:$USER" "$HOME_DIR/.local/bin/restart-qbittorrent.sh"
chown "$USER:$USER" "$HOME_DIR/.local/log"
echo "  Created: $HOME_DIR/.local/bin/restart-qbittorrent.sh"

# 2. Setup passwordless sudo
echo "[2/4] Configuring passwordless sudo..."
cat > /etc/sudoers.d/qbittorrent-restart << EOF
# Allow $USER to restart qBittorrent VPN service without password
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart qbittorrent-vpn.service
EOF
chmod 440 /etc/sudoers.d/qbittorrent-restart
echo "  Created: /etc/sudoers.d/qbittorrent-restart"

# 3. Setup cron job
echo "[3/4] Installing cron job..."
CRON_CMD="0 */4 * * * $HOME_DIR/.local/bin/restart-qbittorrent.sh"
CRON_COMMENT="# Restart qBittorrent every 4 hours to prevent CPU/memory buildup"

# Get existing crontab (excluding any existing qbt restart entries)
sudo -u "$USER" crontab -l 2>/dev/null | grep -v "restart-qbittorrent" | grep -v "Restart qBittorrent every" > /tmp/cron_tmp || true

# Add new entries
echo "$CRON_COMMENT" >> /tmp/cron_tmp
echo "$CRON_CMD" >> /tmp/cron_tmp

# Install crontab
sudo -u "$USER" crontab /tmp/cron_tmp
rm /tmp/cron_tmp
echo "  Cron job: Every 4 hours (0:00, 4:00, 8:00, 12:00, 16:00, 20:00)"

# 4. Verify setup
echo "[4/4] Verifying setup..."
echo ""

# Test sudo access
if sudo -u "$USER" sudo -n /usr/bin/systemctl restart qbittorrent-vpn.service 2>/dev/null; then
    echo "  ✓ Passwordless sudo works"
else
    echo "  ✗ Passwordless sudo failed - check /etc/sudoers.d/qbittorrent-restart"
fi

# Verify cron
if sudo -u "$USER" crontab -l | grep -q "restart-qbittorrent"; then
    echo "  ✓ Cron job installed"
else
    echo "  ✗ Cron job not found"
fi

# Check qBittorrent VPN status
if systemctl is-active --quiet qbittorrent-vpn.service; then
    echo "  ✓ qBittorrent VPN is running"
else
    echo "  ✗ qBittorrent VPN is not running"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Manual restart:  $HOME_DIR/.local/bin/restart-qbittorrent.sh"
echo "View logs:       tail -f $HOME_DIR/.local/log/qbt-restart.log"
echo "Edit schedule:   crontab -e"
echo ""
