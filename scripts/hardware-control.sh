#!/bin/bash
#
# hardware-control.sh - Hardware control for ASUSTOR Flashstor 6 (FS6706T)
#
# Controls: Fan speed, LEDs, blinking, sensors
# Requires: asustor-platform-driver, asustor_it87 kernel modules
#
# Usage:
#   ./hardware-control.sh status          - Show all hardware status
#   ./hardware-control.sh fan <0-255>     - Set fan PWM (0=off, 255=max)
#   ./hardware-control.sh fan auto        - Enable automatic fan control
#   ./hardware-control.sh fan manual      - Switch to manual fan control
#   ./hardware-control.sh led <name> <0|1> - Set LED on/off
#   ./hardware-control.sh led <name> trigger <trigger> - Set LED trigger
#   ./hardware-control.sh blink <on|off>  - Control status LED blinking
#   ./hardware-control.sh temps           - Show all temperatures
#   ./hardware-control.sh leds            - List all available LEDs
#

set -euo pipefail

# Find IT8625 hwmon device
find_hwmon() {
    for hwmon in /sys/class/hwmon/hwmon*; do
        if [[ "$(cat "$hwmon/name" 2>/dev/null)" == "it8625" ]]; then
            echo "$hwmon"
            return 0
        fi
    done
    echo "ERROR: IT8625 hwmon device not found. Is asustor_it87 module loaded?" >&2
    return 1
}

HWMON=$(find_hwmon)
LEDS_PATH="/sys/class/leds"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Get fan speed percentage
fan_percent() {
    local pwm=$1
    echo $((pwm * 100 / 255))
}

# Show hardware status
cmd_status() {
    echo -e "${BLUE}=== Fan Status ===${NC}"
    local fan_rpm=$(cat "$HWMON/fan1_input" 2>/dev/null || echo "N/A")
    local pwm=$(cat "$HWMON/pwm1" 2>/dev/null || echo "0")
    local pwm_enable=$(cat "$HWMON/pwm1_enable" 2>/dev/null || echo "0")
    local mode="unknown"
    case $pwm_enable in
        0) mode="full speed" ;;
        1) mode="manual" ;;
        2) mode="automatic" ;;
    esac

    echo "Fan 1 Speed:  $fan_rpm RPM"
    echo "PWM Value:    $pwm/255 ($(fan_percent $pwm)%)"
    echo "Control Mode: $mode"
    echo ""

    echo -e "${BLUE}=== LED Status ===${NC}"
    for led in blue:power red:power green:status red:status blue:lan nvme1:green:disk nvme1:red:disk; do
        if [[ -d "$LEDS_PATH/$led" ]]; then
            local brightness=$(cat "$LEDS_PATH/$led/brightness" 2>/dev/null || echo "?")
            local trigger=$(cat "$LEDS_PATH/$led/trigger" 2>/dev/null | grep -oP '\[\K[^\]]+' || echo "none")
            printf "  %-20s brightness=%s trigger=%s\n" "$led" "$brightness" "$trigger"
        fi
    done
    echo ""

    echo -e "${BLUE}=== Side LEDs (RGB Accent) ===${NC}"
    for led in red:side_inner red:side_mid red:side_outer; do
        if [[ -d "$LEDS_PATH/$led" ]]; then
            local brightness=$(cat "$LEDS_PATH/$led/brightness" 2>/dev/null || echo "?")
            printf "  %-20s brightness=%s\n" "$led" "$brightness"
        fi
    done
    echo ""

    echo -e "${BLUE}=== Blink Control ===${NC}"
    local blink1=$(cat "$HWMON/gpled1_blink" 2>/dev/null || echo "0")
    local blink2=$(cat "$HWMON/gpled2_blink" 2>/dev/null || echo "0")
    local freq1=$(cat "$HWMON/gpled1_blink_freq" 2>/dev/null || echo "0")
    echo "GPLED1 Blink: $blink1 (freq=$freq1)"
    echo "GPLED2 Blink: $blink2"
    echo ""

    echo -e "${BLUE}=== Chassis Intrusion ===${NC}"
    local intrusion=$(cat "$HWMON/intrusion0_alarm" 2>/dev/null || echo "?")
    if [[ "$intrusion" == "1" ]]; then
        echo -e "  Status: ${RED}TRIGGERED${NC}"
    else
        echo -e "  Status: ${GREEN}OK${NC}"
    fi
}

# Show all temperatures
cmd_temps() {
    echo -e "${BLUE}=== Temperature Sensors ===${NC}"
    sensors 2>/dev/null | grep -E '(^[a-z]|temp[0-9]|Composite|Core|Package)' | while read line; do
        if [[ "$line" =~ ^[a-z] ]]; then
            echo -e "\n${GREEN}$line${NC}"
        else
            echo "  $line"
        fi
    done
}

# Fan control
cmd_fan() {
    local action="${1:-}"

    case "$action" in
        auto)
            echo 2 | sudo tee "$HWMON/pwm1_enable" > /dev/null
            log_info "Fan control set to automatic mode"
            ;;
        manual)
            echo 1 | sudo tee "$HWMON/pwm1_enable" > /dev/null
            log_info "Fan control set to manual mode"
            ;;
        [0-9]*)
            if [[ $action -lt 0 || $action -gt 255 ]]; then
                log_error "PWM value must be 0-255"
                return 1
            fi
            # Switch to manual mode first
            echo 1 | sudo tee "$HWMON/pwm1_enable" > /dev/null
            echo "$action" | sudo tee "$HWMON/pwm1" > /dev/null
            log_info "Fan PWM set to $action ($(fan_percent $action)%)"
            ;;
        "")
            local pwm=$(cat "$HWMON/pwm1")
            local rpm=$(cat "$HWMON/fan1_input")
            echo "Current: $rpm RPM, PWM=$pwm ($(fan_percent $pwm)%)"
            ;;
        *)
            log_error "Unknown fan command: $action"
            echo "Usage: $0 fan [0-255|auto|manual]"
            return 1
            ;;
    esac
}

# LED control
cmd_led() {
    local led="${1:-}"
    local action="${2:-}"
    local value="${3:-}"

    if [[ -z "$led" ]]; then
        log_error "LED name required"
        echo "Available LEDs:"
        cmd_leds
        return 1
    fi

    local led_path="$LEDS_PATH/$led"
    if [[ ! -d "$led_path" ]]; then
        log_error "LED '$led' not found"
        return 1
    fi

    case "$action" in
        0|1|off|on)
            local brightness=0
            [[ "$action" == "1" || "$action" == "on" ]] && brightness=1
            echo "$brightness" | sudo tee "$led_path/brightness" > /dev/null
            log_info "LED $led set to $brightness"
            ;;
        trigger)
            if [[ -z "$value" ]]; then
                echo "Current trigger: $(cat "$led_path/trigger" | grep -oP '\[\K[^\]]+')"
                echo "Available triggers:"
                cat "$led_path/trigger" | tr ' ' '\n' | sed 's/\[//;s/\]//' | sort | head -20
                return 0
            fi
            echo "$value" | sudo tee "$led_path/trigger" > /dev/null
            log_info "LED $led trigger set to $value"
            ;;
        "")
            echo "Brightness: $(cat "$led_path/brightness")"
            echo "Trigger: $(cat "$led_path/trigger" | grep -oP '\[\K[^\]]+')"
            ;;
        *)
            log_error "Unknown LED action: $action"
            echo "Usage: $0 led <name> [0|1|trigger <trigger>]"
            return 1
            ;;
    esac
}

# List all LEDs
cmd_leds() {
    echo -e "${BLUE}=== Available LEDs ===${NC}"
    for led in "$LEDS_PATH"/*; do
        if [[ -d "$led" ]]; then
            local name=$(basename "$led")
            # Skip network PHY LEDs (noisy)
            [[ "$name" =~ ^enp ]] && continue
            [[ "$name" =~ ^input ]] && continue
            local brightness=$(cat "$led/brightness" 2>/dev/null || echo "?")
            local trigger=$(cat "$led/trigger" 2>/dev/null | grep -oP '\[\K[^\]]+' || echo "none")
            printf "  %-25s brightness=%-3s trigger=%s\n" "$name" "$brightness" "$trigger"
        fi
    done
}

# Blink control
cmd_blink() {
    local action="${1:-}"

    case "$action" in
        on|1)
            # Enable blinking on status LED (GP47)
            echo 47 | sudo tee "$HWMON/gpled1_blink" > /dev/null
            log_info "Status LED blinking enabled"
            ;;
        off|0)
            echo 0 | sudo tee "$HWMON/gpled1_blink" > /dev/null
            log_info "Status LED blinking disabled"
            ;;
        freq)
            local freq="${2:-}"
            if [[ -z "$freq" || $freq -lt 0 || $freq -gt 11 ]]; then
                log_error "Frequency must be 0-11 (11=always on)"
                return 1
            fi
            echo "$freq" | sudo tee "$HWMON/gpled1_blink_freq" > /dev/null
            log_info "Blink frequency set to $freq"
            ;;
        "")
            echo "GPLED1: $(cat "$HWMON/gpled1_blink") (freq=$(cat "$HWMON/gpled1_blink_freq"))"
            echo "GPLED2: $(cat "$HWMON/gpled2_blink")"
            ;;
        *)
            log_error "Unknown blink command: $action"
            echo "Usage: $0 blink [on|off|freq <0-11>]"
            return 1
            ;;
    esac
}

# Side LED control (RGB accent lights)
cmd_side() {
    local action="${1:-}"

    case "$action" in
        on|1)
            for led in red:side_inner red:side_mid red:side_outer; do
                echo 1 | sudo tee "$LEDS_PATH/$led/brightness" > /dev/null
            done
            log_info "Side LEDs enabled"
            ;;
        off|0)
            for led in red:side_inner red:side_mid red:side_outer; do
                echo 0 | sudo tee "$LEDS_PATH/$led/brightness" > /dev/null
            done
            log_info "Side LEDs disabled"
            ;;
        "")
            for led in red:side_inner red:side_mid red:side_outer; do
                echo "$led: $(cat "$LEDS_PATH/$led/brightness")"
            done
            ;;
        *)
            log_error "Unknown side command: $action"
            echo "Usage: $0 side [on|off]"
            return 1
            ;;
    esac
}

# Main
case "${1:-}" in
    status)
        cmd_status
        ;;
    temps|temp|temperatures)
        cmd_temps
        ;;
    fan)
        shift
        cmd_fan "$@"
        ;;
    led)
        shift
        cmd_led "$@"
        ;;
    leds)
        cmd_leds
        ;;
    blink)
        shift
        cmd_blink "$@"
        ;;
    side)
        shift
        cmd_side "$@"
        ;;
    help|-h|--help)
        echo "ASUSTOR Flashstor 6 Hardware Control"
        echo ""
        echo "Usage: $0 <command> [options]"
        echo ""
        echo "Commands:"
        echo "  status              Show all hardware status"
        echo "  temps               Show all temperature sensors"
        echo "  fan [0-255|auto|manual]  Control fan speed"
        echo "  led <name> [0|1]    Set LED on/off"
        echo "  led <name> trigger [name]  Set/show LED trigger"
        echo "  leds                List all available LEDs"
        echo "  blink [on|off]      Control status LED blinking"
        echo "  blink freq <0-11>   Set blink frequency"
        echo "  side [on|off]       Control side accent LEDs"
        echo ""
        echo "Examples:"
        echo "  $0 fan 128          Set fan to 50%"
        echo "  $0 fan auto         Enable automatic fan control"
        echo "  $0 led green:status 0  Turn off green status LED"
        echo "  $0 led nvme1:green:disk trigger disk-activity"
        echo "  $0 blink off        Stop status LED blinking"
        echo "  $0 side off         Turn off side accent LEDs"
        ;;
    *)
        cmd_status
        ;;
esac
