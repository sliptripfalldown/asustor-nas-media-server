#!/bin/bash
# Start qBittorrent with VPN in isolated network namespace
# This ensures ONLY qBittorrent traffic goes through VPN
# Supports multiple servers with automatic failover

set -e

NAMESPACE="vpn"
SERVERS_DIR="/home/anon/nas-media-server/config/wireguard/servers"
ACTIVE_CONF="/home/anon/nas-media-server/config/wireguard/active.conf"
QBT_USER="anon"
QBT_PORT=8080
WG_IF="proton0"

# Local networks that should always be accessible (for API access from *arr apps)
LOCAL_NETS="10.200.40.0/24 192.168.0.0/16 172.16.0.0/12 10.200.200.0/24"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[QBT-VPN]${NC} $1"; }
warn() { echo -e "${YELLOW}[QBT-VPN]${NC} $1"; }
error() { echo -e "${RED}[QBT-VPN]${NC} $1"; exit 1; }

list_servers() {
    ls -1 "$SERVERS_DIR"/*.conf 2>/dev/null | while read f; do
        name=$(basename "$f" .conf)
        endpoint=$(grep "^Endpoint" "$f" | cut -d= -f2 | tr -d ' ')
        echo "  $name ($endpoint)"
    done
}

check_requirements() {
    [[ -d "$SERVERS_DIR" ]] || mkdir -p "$SERVERS_DIR"

    local count=$(ls -1 "$SERVERS_DIR"/*.conf 2>/dev/null | wc -l)
    if [[ $count -eq 0 ]]; then
        error "No WireGuard configs found in $SERVERS_DIR

Download from: https://account.protonvpn.com/downloads#wireguard-configuration
Select: Linux > WireGuard > Choose P2P servers (for port forwarding)
Save configs to: $SERVERS_DIR/<server-name>.conf

Recommended: Download 3-4 configs from different regions for failover"
    fi

    ip netns list | grep -q "$NAMESPACE" || error "Namespace not found. Run: sudo vpn-namespace-setup.sh setup"
}

select_server() {
    local server="$1"

    if [[ -n "$server" ]]; then
        # Specific server requested
        if [[ -f "$SERVERS_DIR/$server.conf" ]]; then
            cp "$SERVERS_DIR/$server.conf" "$ACTIVE_CONF"
            log "Selected server: $server"
            return 0
        else
            error "Server not found: $server. Available servers:
$(list_servers)"
        fi
    fi

    # Try servers in order until one works
    for conf in "$SERVERS_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue
        name=$(basename "$conf" .conf)
        log "Trying server: $name..."

        cp "$conf" "$ACTIVE_CONF"
        if test_vpn_connection; then
            log "Connected to: $name"
            return 0
        fi
        warn "Server $name failed, trying next..."
        teardown_vpn
    done

    error "All servers failed to connect"
}

setup_vpn_in_namespace() {
    log "Setting up WireGuard ($WG_IF) in namespace..."

    # Clean up any existing interface
    ip netns exec $NAMESPACE ip link del $WG_IF 2>/dev/null || true
    ip link del $WG_IF 2>/dev/null || true

    # Create interface and move to namespace
    ip link add $WG_IF type wireguard
    ip link set $WG_IF netns $NAMESPACE

    # Configure WireGuard
    ip netns exec $NAMESPACE wg setconf $WG_IF <(grep -v "^Address\|^DNS" "$ACTIVE_CONF")

    # Get address from config and apply
    local wg_addr=$(grep -i "^Address" "$ACTIVE_CONF" | cut -d= -f2 | tr -d ' ' | cut -d, -f1)
    ip netns exec $NAMESPACE ip addr add $wg_addr dev $WG_IF
    ip netns exec $NAMESPACE ip link set $WG_IF up

    # Replace default route with WireGuard
    ip netns exec $NAMESPACE ip route replace default dev $WG_IF

    # Add routes for local networks to bypass VPN (go through veth)
    for net in $LOCAL_NETS; do
        ip netns exec $NAMESPACE ip route replace $net via 10.200.200.1 2>/dev/null || true
    done

    log "WireGuard interface configured"
}

teardown_vpn() {
    ip netns exec $NAMESPACE ip link del $WG_IF 2>/dev/null || true
    ip link del $WG_IF 2>/dev/null || true
}

test_vpn_connection() {
    # Quick connectivity test
    ip netns exec $NAMESPACE ping -c 1 -W 3 1.1.1.1 &>/dev/null
}

get_vpn_ip() {
    ip netns exec $NAMESPACE curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "unknown"
}

get_host_ip() {
    curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "unknown"
}

# NAT-PMP Port Forwarding for ProtonVPN
NATPMP_GATEWAY="10.2.0.1"
PORT_FILE="/tmp/qbt-vpn-port"
PORT_REFRESH_PID_FILE="/tmp/qbt-port-refresh.pid"

request_port_forward() {
    # Request port forward via NAT-PMP
    local result=$(ip netns exec $NAMESPACE natpmpc -g $NATPMP_GATEWAY -a 1 0 tcp 60 2>&1)
    local port=$(echo "$result" | grep "Mapped public port" | awk '{print $4}')

    if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
        # Also request UDP
        ip netns exec $NAMESPACE natpmpc -g $NATPMP_GATEWAY -a $port $port udp 60 &>/dev/null
        ip netns exec $NAMESPACE natpmpc -g $NATPMP_GATEWAY -a $port $port tcp 60 &>/dev/null
        echo "$port"
        return 0
    fi
    return 1
}

update_qbt_port() {
    local port="$1"
    local current_port=$(curl -s "http://10.200.200.2:$QBT_PORT/api/v2/app/preferences" 2>/dev/null | \
        python3 -c "import sys,json; print(json.load(sys.stdin).get('listen_port',0))" 2>/dev/null)

    if [[ "$current_port" != "$port" ]]; then
        curl -s -X POST "http://10.200.200.2:$QBT_PORT/api/v2/app/setPreferences" \
            -d "json={\"listen_port\":$port}" &>/dev/null
        log "Updated qBittorrent listen port: $port"
    fi
}

start_port_refresh_loop() {
    # Kill any existing refresh loop
    [[ -f "$PORT_REFRESH_PID_FILE" ]] && kill $(cat "$PORT_REFRESH_PID_FILE") 2>/dev/null || true

    # Create refresh script
    cat > /tmp/qbt-port-refresh.sh << 'SCRIPT'
#!/bin/bash
while true; do
    port=$(ip netns exec vpn natpmpc -g 10.2.0.1 -a 1 0 tcp 60 2>&1 | grep "Mapped public port" | awk '{print $4}')
    if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
        ip netns exec vpn natpmpc -g 10.2.0.1 -a $port $port udp 60 &>/dev/null
        ip netns exec vpn natpmpc -g 10.2.0.1 -a $port $port tcp 60 &>/dev/null
        echo "$port" > /tmp/qbt-vpn-port
        current=$(curl -s "http://10.200.200.2:8080/api/v2/app/preferences" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('listen_port',0))" 2>/dev/null)
        if [[ "$current" != "$port" ]]; then
            curl -s -X POST "http://10.200.200.2:8080/api/v2/app/setPreferences" -d "json={\"listen_port\":$port}" &>/dev/null
        fi
    fi
    sleep 45
done
SCRIPT
    chmod +x /tmp/qbt-port-refresh.sh

    # Run fully detached
    setsid /tmp/qbt-port-refresh.sh </dev/null &>/dev/null &
    echo $! > "$PORT_REFRESH_PID_FILE"
    log "Port forwarding refresh loop started (PID: $(cat $PORT_REFRESH_PID_FILE))"
}

stop_port_refresh_loop() {
    if [[ -f "$PORT_REFRESH_PID_FILE" ]]; then
        kill $(cat "$PORT_REFRESH_PID_FILE") 2>/dev/null || true
        rm -f "$PORT_REFRESH_PID_FILE"
    fi
}

setup_port_forwarding() {
    log "Setting up NAT-PMP port forwarding..."

    # Check if natpmpc is installed
    if ! command -v natpmpc &>/dev/null; then
        warn "natpmpc not installed. Install with: sudo apt install natpmpc"
        return 1
    fi

    # Request initial port forward
    local port=$(request_port_forward)
    if [[ -n "$port" ]]; then
        echo "$port" > "$PORT_FILE"
        log "Got forwarded port: $port"

        # Wait for qBittorrent API to be ready
        sleep 3
        update_qbt_port "$port"

        # Start background refresh loop
        start_port_refresh_loop
        return 0
    else
        warn "Could not get port forward from VPN"
        return 1
    fi
}

start_qbittorrent() {
    log "Starting qBittorrent in VPN namespace..."

    # Check if already running
    if ip netns pids $NAMESPACE 2>/dev/null | xargs -r ps -p 2>/dev/null | grep -q qbittorrent; then
        warn "qBittorrent already running in namespace"
        return
    fi

    # Start qBittorrent in namespace as the correct user
    ip netns exec $NAMESPACE sudo -u $QBT_USER /usr/local/bin/qbittorrent-nox \
        --webui-port=$QBT_PORT \
        --profile=/home/$QBT_USER/.config/qBittorrent &

    sleep 2

    if ip netns pids $NAMESPACE 2>/dev/null | xargs -r ps -p 2>/dev/null | grep -q qbittorrent; then
        log "qBittorrent started successfully"
        log "WebUI: http://10.200.200.2:$QBT_PORT (VPN namespace)"

        # Setup port forwarding after qBittorrent is running
        setup_port_forwarding
    else
        error "Failed to start qBittorrent"
    fi
}

stop_all() {
    log "Stopping qBittorrent and VPN..."

    # Stop port refresh loop
    stop_port_refresh_loop

    # Kill processes in namespace
    ip netns pids $NAMESPACE 2>/dev/null | xargs -r kill 2>/dev/null || true
    sleep 1
    ip netns pids $NAMESPACE 2>/dev/null | xargs -r kill -9 2>/dev/null || true

    # Bring down WireGuard
    teardown_vpn

    log "Stopped"
}

show_status() {
    echo ""
    log "=== Available Servers ==="
    list_servers

    echo ""
    log "=== VPN Status ==="
    if ip netns exec $NAMESPACE wg show 2>/dev/null | grep -q interface; then
        echo "WireGuard: Connected"
        ip netns exec $NAMESPACE wg show
        echo ""
        local vpn_ip=$(get_vpn_ip)
        local host_ip=$(get_host_ip)
        echo "VPN IP (qBittorrent): $vpn_ip"
        echo "Host IP (everything else): $host_ip"

        if [[ "$vpn_ip" != "$host_ip" ]] && [[ "$vpn_ip" != "unknown" ]]; then
            log "Split tunnel working correctly"
        else
            warn "IPs match - check split tunnel config"
        fi
    else
        echo "WireGuard: Not connected"
    fi

    echo ""
    log "=== Port Forwarding ==="
    if [[ -f "$PORT_FILE" ]]; then
        local fwd_port=$(cat "$PORT_FILE")
        echo "Forwarded port: $fwd_port"
        if [[ -f "$PORT_REFRESH_PID_FILE" ]] && kill -0 $(cat "$PORT_REFRESH_PID_FILE") 2>/dev/null; then
            echo "Refresh loop: Running (PID: $(cat $PORT_REFRESH_PID_FILE))"
        else
            echo "Refresh loop: Not running"
        fi
    else
        echo "Port forwarding: Not active"
    fi

    echo ""
    log "=== qBittorrent Status ==="
    if ip netns pids $NAMESPACE 2>/dev/null | xargs -r ps -p 2>/dev/null | grep -q qbittorrent; then
        echo "qBittorrent: Running"
        ip netns pids $NAMESPACE 2>/dev/null | xargs -r ps -fp 2>/dev/null | grep qbittorrent || true
        local qbt_port=$(curl -s "http://10.200.200.2:$QBT_PORT/api/v2/app/preferences" 2>/dev/null | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('listen_port',0))" 2>/dev/null)
        echo "Listen port: $qbt_port"
        local conn_status=$(curl -s "http://10.200.200.2:$QBT_PORT/api/v2/transfer/info" 2>/dev/null | \
            python3 -c "import sys,json; print(json.load(sys.stdin).get('connection_status','unknown'))" 2>/dev/null)
        echo "Connection: $conn_status"
    else
        echo "qBittorrent: Not running"
    fi

    echo ""
    log "=== Namespace Routes ==="
    ip netns exec $NAMESPACE ip route show
}

rotate_server() {
    log "Rotating to next server..."

    # Get current server
    local current=""
    [[ -f "$ACTIVE_CONF" ]] && current=$(grep "^# " "$ACTIVE_CONF" | head -1 | sed 's/^# //')

    # Get list of servers
    local servers=($(ls -1 "$SERVERS_DIR"/*.conf 2>/dev/null))
    local count=${#servers[@]}

    [[ $count -lt 2 ]] && { warn "Need at least 2 servers for rotation"; return 1; }

    # Find next server
    local next_idx=0
    for i in "${!servers[@]}"; do
        local name=$(basename "${servers[$i]}" .conf)
        if [[ "$current" == *"$name"* ]]; then
            next_idx=$(( (i + 1) % count ))
            break
        fi
    done

    local next_server=$(basename "${servers[$next_idx]}" .conf)
    log "Switching to: $next_server"

    stop_all
    sleep 2
    select_server "$next_server"
    setup_vpn_in_namespace
    start_qbittorrent
}

case "${1:-}" in
    start)
        check_requirements
        select_server "${2:-}"
        setup_vpn_in_namespace
        start_qbittorrent
        ;;
    stop)
        stop_all
        ;;
    status)
        show_status
        ;;
    restart)
        stop_all
        sleep 2
        check_requirements
        select_server "${2:-}"
        setup_vpn_in_namespace
        start_qbittorrent
        ;;
    rotate)
        rotate_server
        ;;
    servers)
        echo "Available servers:"
        list_servers
        ;;
    *)
        echo "Usage: $0 {start|stop|status|restart|rotate|servers} [server-name]"
        echo ""
        echo "Commands:"
        echo "  start [server]  - Start VPN and qBittorrent (auto-selects if no server given)"
        echo "  stop            - Stop everything"
        echo "  status          - Show current status"
        echo "  restart [server]- Restart with optional server change"
        echo "  rotate          - Switch to next server"
        echo "  servers         - List available servers"
        echo ""
        echo "This runs qBittorrent in an isolated network namespace."
        echo "Only qBittorrent traffic goes through VPN."
        echo "Local networks stay accessible for *arr apps."
        echo ""
        echo "Server configs: $SERVERS_DIR/"
        exit 1
        ;;
esac
