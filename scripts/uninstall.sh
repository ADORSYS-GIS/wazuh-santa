#!/bin/bash
set -eu

# Variables & Constants
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
BOLD='\033[1m'
NORMAL='\033[0m'

SANTA_UNINSTALL_URL="https://raw.githubusercontent.com/northpolesec/santa/refs/heads/main/Conf/uninstall.sh"
ACTIVE_RESPONSE_DIR="/Library/Ossec/active-response"
ACTIVE_RESPONSE_BIN_DIR="$ACTIVE_RESPONSE_DIR/bin"
LAUNCHDAEMONS_DIR="/Library/LaunchDaemons"
PF_CONF_PATH="/etc/pf.conf"

# Helpers
log() {
    local LEVEL="$1"
    shift
    local MESSAGE="$*"
    local TIMESTAMP
    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    echo -e "${TIMESTAMP} ${LEVEL} ${MESSAGE}"
}

info() { log "${BLUE}${BOLD}[INFO]${NORMAL}" "$*"; }
warn() { log "${YELLOW}${BOLD}[WARNING]${NORMAL}" "$*"; }
error() { log "${RED}${BOLD}[ERROR]${NORMAL}"; exit 1; }
success() { log "${GREEN}${BOLD}[SUCCESS]${NORMAL}" "$*"; }

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

maybe_sudo() {
    if [ "$(id -u)" -ne 0 ]; then
        if command_exists sudo; then
            sudo "$@"
        else
            error "This script requires root privileges. Please run with sudo or as root."
            exit 1
        fi
    else
        "$@"
    fi
}

remove_pf_rules() {
    if [ ! -f "$PF_CONF_PATH" ] || ! grep -q "wazuh_blocked" "$PF_CONF_PATH"; then return 0; fi
    local tmp; tmp=$(mktemp)
    awk '
        $0 == "table <wazuh_blocked> persist" { next }
        $0 == "block out quick from any to <wazuh_blocked>" { next }
        $0 == "block in  quick from <wazuh_blocked> to any" { next }
        { print }
    ' "$PF_CONF_PATH" > "$tmp"
    maybe_sudo cp "$tmp" "$PF_CONF_PATH"
    rm -f "$tmp"
}

# Main
[ "$(uname)" != "Darwin" ] && error "macOS only."

TEMP_DIR=$(mktemp -d); trap 'rm -rf "$TEMP_DIR"' EXIT

info "Removing Wazuh integration components..."
for p in blockdomain unblock; do
    plist="$LAUNCHDAEMONS_DIR/com.wazuh.$p.plist"
    maybe_sudo launchctl bootout system "$plist" 2>/dev/null || true
    maybe_sudo rm -f "$plist"
done
# Active Response Scripts
info "Removing DLP active response scripts and state directory..."
maybe_sudo rm -f "$ACTIVE_RESPONSE_BIN_DIR/block.sh" "$ACTIVE_RESPONSE_BIN_DIR/unblock.sh" "$ACTIVE_RESPONSE_BIN_DIR/dlp.sh" || warn "Failed to remove one or more DLP active response scripts."
maybe_sudo rm -rf "$ACTIVE_RESPONSE_DIR/dlp-state" || warn "Failed to remove DLP state directory."

info "Cleaning up PF rules..."
maybe_sudo pfctl -t wazuh_blocked -T flush 2>/dev/null || true
remove_pf_rules
maybe_sudo pfctl -f "$PF_CONF_PATH" 2>/dev/null || warn "PF reload failed."

if command -v santactl >/dev/null 2>&1; then
    info "Uninstalling Santa..."
    curl -sSL "$SANTA_UNINSTALL_URL" -o "$TEMP_DIR/uninstall_santa.sh"
    chmod +x "$TEMP_DIR/uninstall_santa.sh"
    maybe_sudo "$TEMP_DIR/uninstall_santa.sh" || warn "Santa uninstall script failed."
    maybe_sudo rm -rf "/var/db/santa"
else
    info "Santa not found, skipping."
fi

success "Uninstallation complete!"
