#!/bin/bash
# VPN Watchdog - Monitors VPN health and auto-reconnects/rotates on failure
# Designed to run as a systemd service

set -u

NAMESPACE="vpn"
WG_IF="proton0"
MAX_HANDSHAKE_AGE=180  # Max seconds since last handshake before considered stale
CHECK_INTERVAL=30       # Check every 30 seconds
CONNECTIVITY_TIMEOUT=5  # Timeout for connectivity tests
FAILED_CHECKS_THRESHOLD=3  # Number of failed checks before rotating
QBT_START_SCRIPT="/home/anon/nas-media-server/scripts/qbt-vpn-start.sh"

# State tracking
failed_checks=0
last_server_rotation=0
MIN_ROTATION_INTERVAL=300  # Don't rotate more than once per 5 minutes

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[VPN-WD]${NC} $1"; }
warn() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[VPN-WD]${NC} $1"; }
error() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${RED}[VPN-WD]${NC} $1"; }

# Check if WireGuard interface exists and is up
check_interface() {
    ip netns exec $NAMESPACE ip link show $WG_IF &>/dev/null
}

# Get time since last WireGuard handshake in seconds
get_handshake_age() {
    local handshake_line=$(ip netns exec $NAMESPACE wg show $WG_IF 2>/dev/null | grep "latest handshake")

    if [[ -z "$handshake_line" ]]; then
        echo "999999"  # No handshake ever
        return
    fi

    # Parse handshake time (e.g., "5 seconds ago", "2 minutes, 30 seconds ago", "1 hour, 5 minutes ago")
    local seconds=0

    if [[ "$handshake_line" =~ ([0-9]+)\ hour ]]; then
        seconds=$((seconds + ${BASH_REMATCH[1]} * 3600))
    fi
    if [[ "$handshake_line" =~ ([0-9]+)\ minute ]]; then
        seconds=$((seconds + ${BASH_REMATCH[1]} * 60))
    fi
    if [[ "$handshake_line" =~ ([0-9]+)\ second ]]; then
        seconds=$((seconds + ${BASH_REMATCH[1]}))
    fi

    echo "$seconds"
}

# Test actual connectivity through VPN
check_connectivity() {
    # Try to reach a reliable endpoint
    ip netns exec $NAMESPACE curl -s --max-time $CONNECTIVITY_TIMEOUT https://1.1.1.1/cdn-cgi/trace &>/dev/null
}

# Get current VPN IP
get_vpn_ip() {
    ip netns exec $NAMESPACE curl -s --max-time $CONNECTIVITY_TIMEOUT https://api.ipify.org 2>/dev/null || echo "unknown"
}

# Check qBittorrent connection status
check_qbittorrent() {
    local status=$(curl -s --max-time 3 "http://10.200.200.2:8080/api/v2/transfer/info" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('connection_status','unknown'))" 2>/dev/null)

    [[ "$status" == "connected" || "$status" == "firewalled" ]]
}

# Rotate to next server
rotate_server() {
    local now=$(date +%s)
    local time_since_rotation=$((now - last_server_rotation))

    if [[ $time_since_rotation -lt $MIN_ROTATION_INTERVAL ]]; then
        warn "Skipping rotation - only $time_since_rotation seconds since last rotation (min: $MIN_ROTATION_INTERVAL)"
        return 1
    fi

    log "Rotating to next VPN server..."

    # Use the rotate command from qbt-vpn-start.sh
    if $QBT_START_SCRIPT rotate; then
        last_server_rotation=$now
        failed_checks=0
        log "Server rotation complete"
        return 0
    else
        error "Server rotation failed"
        return 1
    fi
}

# Restart VPN without rotation
restart_vpn() {
    log "Restarting VPN connection..."

    if $QBT_START_SCRIPT restart; then
        failed_checks=0
        log "VPN restart complete"
        return 0
    else
        error "VPN restart failed"
        return 1
    fi
}

# Full health check
health_check() {
    local issues=()

    # Check 1: WireGuard interface exists
    if ! check_interface; then
        issues+=("WireGuard interface missing")
    else
        # Check 2: Handshake freshness
        local handshake_age=$(get_handshake_age)
        if [[ $handshake_age -gt $MAX_HANDSHAKE_AGE ]]; then
            issues+=("Handshake stale (${handshake_age}s ago, max: ${MAX_HANDSHAKE_AGE}s)")
        fi
    fi

    # Check 3: Internet connectivity
    if ! check_connectivity; then
        issues+=("No internet connectivity")
    fi

    # Check 4: qBittorrent status (optional, don't fail on this alone)
    if ! check_qbittorrent; then
        warn "qBittorrent connection not optimal"
    fi

    if [[ ${#issues[@]} -eq 0 ]]; then
        return 0
    else
        for issue in "${issues[@]}"; do
            warn "Health check failed: $issue"
        done
        return 1
    fi
}

# Main monitoring loop
main_loop() {
    log "VPN Watchdog started"
    log "Check interval: ${CHECK_INTERVAL}s, Max handshake age: ${MAX_HANDSHAKE_AGE}s"

    while true; do
        if health_check; then
            if [[ $failed_checks -gt 0 ]]; then
                log "VPN recovered after $failed_checks failed checks"
            fi
            failed_checks=0

            # Periodic status (every 10 minutes if healthy)
            if [[ $((SECONDS % 600)) -lt $CHECK_INTERVAL ]]; then
                local vpn_ip=$(get_vpn_ip)
                log "VPN healthy - IP: $vpn_ip, Handshake: $(get_handshake_age)s ago"
            fi
        else
            failed_checks=$((failed_checks + 1))
            warn "Failed check $failed_checks of $FAILED_CHECKS_THRESHOLD"

            if [[ $failed_checks -ge $FAILED_CHECKS_THRESHOLD ]]; then
                error "Too many failed checks, attempting recovery..."

                # First try restart
                if restart_vpn; then
                    sleep 10
                    if health_check; then
                        log "Recovery via restart successful"
                        continue
                    fi
                fi

                # If restart didn't work, try rotation
                warn "Restart didn't fix it, trying server rotation..."
                if rotate_server; then
                    sleep 10
                    if health_check; then
                        log "Recovery via rotation successful"
                        continue
                    fi
                fi

                error "All recovery attempts failed, will retry next cycle"
                failed_checks=0  # Reset to avoid constant rotation attempts
            fi
        fi

        sleep $CHECK_INTERVAL
    done
}

# Handle signals for clean shutdown
trap 'log "Watchdog shutting down"; exit 0' SIGTERM SIGINT

# Start the main loop
main_loop
