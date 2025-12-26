#!/bin/bash
# VPN Network Namespace Setup for qBittorrent
# This isolates qBittorrent traffic through ProtonVPN while keeping all other traffic local

set -e

NAMESPACE="vpn"
VETH_HOST="veth-host"
VETH_NS="veth-vpn"
HOST_IP="10.200.200.1"
NS_IP="10.200.200.2"
SUBNET="10.200.200.0/24"

# Auto-detect primary network interface (the one with default route)
# Override by setting WAN_IF environment variable
WAN_IF="${WAN_IF:-$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+' | head -1)}"
[[ -z "$WAN_IF" ]] && WAN_IF="eth0"  # Fallback

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[VPN-NS]${NC} $1"; }
warn() { echo -e "${YELLOW}[VPN-NS]${NC} $1"; }
error() { echo -e "${RED}[VPN-NS]${NC} $1"; }

cleanup() {
    log "Cleaning up existing namespace configuration..."

    # Kill any processes in the namespace
    ip netns pids $NAMESPACE 2>/dev/null | xargs -r kill 2>/dev/null || true

    # Delete namespace (this also removes veth pairs)
    ip netns del $NAMESPACE 2>/dev/null || true

    # Clean up any orphaned veth
    ip link del $VETH_HOST 2>/dev/null || true

    # Remove iptables rules
    iptables -t nat -D POSTROUTING -s $SUBNET -o $WAN_IF -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i $VETH_HOST -o $WAN_IF -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i $WAN_IF -o $VETH_HOST -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

    # Remove port forwarding rules
    iptables -t nat -D PREROUTING -p tcp --dport 8080 -j DNAT --to-destination $NS_IP:8080 2>/dev/null || true
    iptables -D FORWARD -p tcp -d $NS_IP --dport 8080 -j ACCEPT 2>/dev/null || true
    iptables -t nat -D PREROUTING -p tcp --dport 9696 -j DNAT --to-destination $NS_IP:9696 2>/dev/null || true
    iptables -D FORWARD -p tcp -d $NS_IP --dport 9696 -j ACCEPT 2>/dev/null || true
    iptables -t nat -D PREROUTING -p tcp --dport 8191 -j DNAT --to-destination $NS_IP:8191 2>/dev/null || true
    iptables -D FORWARD -p tcp -d $NS_IP --dport 8191 -j ACCEPT 2>/dev/null || true
}

setup_namespace() {
    log "Creating network namespace: $NAMESPACE"
    ip netns add $NAMESPACE

    log "Creating veth pair: $VETH_HOST <-> $VETH_NS"
    ip link add $VETH_HOST type veth peer name $VETH_NS

    log "Moving $VETH_NS to namespace"
    ip link set $VETH_NS netns $NAMESPACE

    log "Configuring host side: $HOST_IP"
    ip addr add $HOST_IP/24 dev $VETH_HOST
    ip link set $VETH_HOST up

    log "Configuring namespace side: $NS_IP"
    ip netns exec $NAMESPACE ip addr add $NS_IP/24 dev $VETH_NS
    ip netns exec $NAMESPACE ip link set $VETH_NS up
    ip netns exec $NAMESPACE ip link set lo up

    log "Setting default route in namespace"
    ip netns exec $NAMESPACE ip route add default via $HOST_IP

    log "Enabling IP forwarding"
    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    log "Setting up NAT for namespace traffic (WAN interface: $WAN_IF)"
    iptables -t nat -A POSTROUTING -s $SUBNET -o $WAN_IF -j MASQUERADE
    iptables -A FORWARD -i $VETH_HOST -o $WAN_IF -j ACCEPT
    iptables -A FORWARD -i $WAN_IF -o $VETH_HOST -m state --state RELATED,ESTABLISHED -j ACCEPT

    log "Adding DNS to namespace (Proton's DNS - no logging)"
    mkdir -p /etc/netns/$NAMESPACE
    echo "nameserver 10.2.0.1" > /etc/netns/$NAMESPACE/resolv.conf

    log "Setting up port forwarding for services in namespace"
    # qBittorrent WebUI (8080)
    iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination $NS_IP:8080
    iptables -A FORWARD -p tcp -d $NS_IP --dport 8080 -j ACCEPT
    # Prowlarr (9696)
    iptables -t nat -A PREROUTING -p tcp --dport 9696 -j DNAT --to-destination $NS_IP:9696
    iptables -A FORWARD -p tcp -d $NS_IP --dport 9696 -j ACCEPT
    # FlareSolverr (8191)
    iptables -t nat -A PREROUTING -p tcp --dport 8191 -j DNAT --to-destination $NS_IP:8191
    iptables -A FORWARD -p tcp -d $NS_IP --dport 8191 -j ACCEPT
}

test_namespace() {
    log "Testing namespace connectivity..."

    if ip netns exec $NAMESPACE ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1; then
        log "Namespace has internet connectivity"
        return 0
    else
        error "Namespace cannot reach internet"
        return 1
    fi
}

show_status() {
    echo ""
    log "=== Namespace Status ==="
    echo "Namespace exists: $(ip netns list | grep -q $NAMESPACE && echo 'Yes' || echo 'No')"
    echo ""

    if ip netns list | grep -q $NAMESPACE; then
        log "=== Namespace Interfaces ==="
        ip netns exec $NAMESPACE ip addr show
        echo ""
        log "=== Namespace Routes ==="
        ip netns exec $NAMESPACE ip route show
        echo ""
        log "=== Processes in Namespace ==="
        ip netns pids $NAMESPACE 2>/dev/null | xargs -r ps -p 2>/dev/null || echo "None"
    fi
}

case "${1:-}" in
    setup)
        cleanup
        setup_namespace
        test_namespace
        log "Namespace ready. Use: sudo ip netns exec $NAMESPACE <command>"
        ;;
    cleanup)
        cleanup
        log "Cleanup complete"
        ;;
    status)
        show_status
        ;;
    test)
        test_namespace
        ;;
    exec)
        shift
        exec ip netns exec $NAMESPACE "$@"
        ;;
    *)
        echo "Usage: $0 {setup|cleanup|status|test|exec <command>}"
        echo ""
        echo "Commands:"
        echo "  setup   - Create namespace and configure networking"
        echo "  cleanup - Remove namespace and clean up"
        echo "  status  - Show namespace status"
        echo "  test    - Test namespace connectivity"
        echo "  exec    - Run command in namespace"
        exit 1
        ;;
esac
