#!/bin/bash
# Common library for NAS Media Server scripts
# Source this at the start of scripts: source "$(dirname "$0")/lib/common.sh"

# Exit on error, undefined vars, and pipe failures
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_fatal() {
    log_error "$*"
    exit 1
}

# Error trap - shows line number on failure
trap_error() {
    local line_num=$1
    local command=$2
    local exit_code=$3
    log_error "Command failed at line ${line_num}: ${command}"
    log_error "Exit code: ${exit_code}"
}
trap 'trap_error ${LINENO} "$BASH_COMMAND" $?' ERR

# Requirement checks
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_fatal "This script must be run as root (use sudo)"
    fi
}

require_user() {
    if [[ $EUID -eq 0 ]]; then
        log_fatal "This script must NOT be run as root"
    fi
}

require_command() {
    local cmd=$1
    if ! command -v "$cmd" &>/dev/null; then
        log_fatal "Required command not found: $cmd"
    fi
}

require_file() {
    local file=$1
    if [[ ! -f "$file" ]]; then
        log_fatal "Required file not found: $file"
    fi
}

require_dir() {
    local dir=$1
    if [[ ! -d "$dir" ]]; then
        log_fatal "Required directory not found: $dir"
    fi
}

# Network checks
require_network() {
    if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        log_fatal "No network connectivity"
    fi
}

check_port() {
    local host=$1
    local port=$2
    local timeout=${3:-5}

    if timeout "$timeout" bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

wait_for_port() {
    local host=$1
    local port=$2
    local max_wait=${3:-60}
    local interval=${4:-2}
    local elapsed=0

    log_info "Waiting for ${host}:${port}..."
    while ! check_port "$host" "$port"; do
        sleep "$interval"
        elapsed=$((elapsed + interval))
        if [[ $elapsed -ge $max_wait ]]; then
            log_fatal "Timeout waiting for ${host}:${port}"
        fi
    done
    log_success "${host}:${port} is available"
}

# Service helpers
service_running() {
    local service=$1
    systemctl is-active --quiet "$service"
}

wait_for_service() {
    local service=$1
    local max_wait=${2:-30}
    local elapsed=0

    log_info "Waiting for $service..."
    while ! service_running "$service"; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [[ $elapsed -ge $max_wait ]]; then
            log_fatal "Timeout waiting for $service"
        fi
    done
    log_success "$service is running"
}

# API helpers
api_call() {
    local method=$1
    local url=$2
    local data=${3:-}
    local api_key=${4:-}

    local curl_args=(-s -f -X "$method")

    if [[ -n "$api_key" ]]; then
        curl_args+=(-H "X-Api-Key: $api_key")
    fi

    if [[ -n "$data" ]]; then
        curl_args+=(-H "Content-Type: application/json" -d "$data")
    fi

    if ! curl "${curl_args[@]}" "$url"; then
        log_error "API call failed: $method $url"
        return 1
    fi
}

# Get API key from *arr config
get_arr_api_key() {
    local config_path=$1

    require_file "$config_path"

    local api_key
    api_key=$(grep -oP '(?<=<ApiKey>)[^<]+' "$config_path" 2>/dev/null || true)

    if [[ -z "$api_key" ]]; then
        log_error "Could not extract API key from $config_path"
        return 1
    fi

    echo "$api_key"
}

# Load configuration
load_config() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"

    local config_file="${script_dir}/../config/defaults.env"

    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file"
    else
        log_warn "Config file not found: $config_file"
    fi
}

# Cleanup trap
declare -a CLEANUP_COMMANDS=()

add_cleanup() {
    CLEANUP_COMMANDS+=("$1")
}

run_cleanup() {
    for cmd in "${CLEANUP_COMMANDS[@]:-}"; do
        eval "$cmd" 2>/dev/null || true
    done
}
trap run_cleanup EXIT

# Print section header
section() {
    echo ""
    echo "=========================================="
    echo "  $*"
    echo "=========================================="
}

# Confirmation prompt
confirm() {
    local prompt=${1:-"Continue?"}
    read -p "$prompt (y/n) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

# Safe download with retry
download() {
    local url=$1
    local output=$2
    local max_retries=${3:-3}
    local retry=0

    while [[ $retry -lt $max_retries ]]; do
        if curl -fsSL -o "$output" "$url"; then
            return 0
        fi
        retry=$((retry + 1))
        log_warn "Download failed, retry $retry/$max_retries: $url"
        sleep 2
    done

    log_fatal "Failed to download after $max_retries attempts: $url"
}
