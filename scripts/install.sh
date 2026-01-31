#!/bin/bash
# Set shell options
if [ -n "$BASH_VERSION" ]; then
    set -euo pipefail
else
    set -eu
fi

# Variables & Constants
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
BOLD='\033[1m'
NORMAL='\033[0m'

DLP_URL="https://raw.githubusercontent.com/ADORSYS-GIS/wazuh-santa/refs/heads/feature/DLP/scripts/dlp.sh"
PLIST_URL="https://raw.githubusercontent.com/ADORSYS-GIS/wazuh-santa/refs/heads/feature/DLP/config/refresh.plist"
ACTIVE_RESPONSE_DIR="/Library/Ossec/active-response/bin"
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

download() {
    local url="$1" dest="$2" mode="${3:-644}"
    local tmp; tmp=$(mktemp)
    if command -v curl >/dev/null 2>&1; then
        curl -sSL "$url" -o "$tmp" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$url" -O "$tmp" || return 1
    else
        return 1
    fi
    maybe_sudo mkdir -p "$(dirname "$dest")"
    maybe_sudo mv "$tmp" "$dest"
    maybe_sudo chmod "$mode" "$dest"
    maybe_sudo chown root:wheel "$dest" 2>/dev/null || true
}

ensure_pf_rules() {
    if grep -q "wazuh_blocked" "$PF_CONF_PATH" 2>/dev/null; then return 0; fi
    local tmp; tmp=$(mktemp)
    awk '/^anchor "com\.apple\/\*"/ { 
        if (!inserted) {
            print "table <wazuh_blocked> persist"; 
            print "block out quick from any to <wazuh_blocked>"; 
            print "block in  quick from <wazuh_blocked> to any"; 
            print "";
            inserted=1;
        }
    } { print } 
    END { if (!inserted) { 
        print ""; print "table <wazuh_blocked> persist"; 
        print "block out quick from any to <wazuh_blocked>"; 
        print "block in  quick from <wazuh_blocked> to any" 
    } }' "$PF_CONF_PATH" > "$tmp"
    maybe_sudo cp "$tmp" "$PF_CONF_PATH"
    rm -f "$tmp"
}

# Main
[ "$(uname)" != "Darwin" ] && error "This script runs on macOS only."

TEMP_DIR=$(mktemp -d); trap 'rm -rf "$TEMP_DIR"' EXIT

# Santa Installation
SANTA_VERSION="2025.11"
SANTA_PKG="santa-$SANTA_VERSION.pkg"
if ! command_exists santactl; then
    info "Downloading Santa $SANTA_VERSION..."
    curl -SL --progress-bar "https://github.com/northpolesec/santa/releases/download/$SANTA_VERSION/$SANTA_PKG" -o "$TEMP_DIR/$SANTA_PKG"
    info "Installing Santa $SANTA_VERSION..."
    maybe_sudo installer -pkg "$TEMP_DIR/$SANTA_PKG" -target / >/dev/null 2>&1 || error "Santa install failed."
    success "Santa installed successfully."
else
    info "Santa already installed."
fi

# Active Response Scripts
info "Installing DLP active response script..."
download "$DLP_URL" "$ACTIVE_RESPONSE_DIR/dlp.sh" 755 || error "Failed to download dlp.sh"
success "DLP active response script installed successfully."

# LaunchDaemons
info "Configuring LaunchDaemon..."
plist="$LAUNCHDAEMONS_DIR/com.wazuh.refresh.plist"
download "$PLIST_URL" "$plist" 644 || error "Failed to download refresh.plist"
maybe_sudo launchctl bootout system "$plist" 2>/dev/null || true
success "LaunchDaemon configured successfully."

# PF Configuration
info "Configuring PF..."
ensure_pf_rules
maybe_sudo pfctl -E 2>/dev/null || true
maybe_sudo pfctl -f "$PF_CONF_PATH" 2>/dev/null || warn "PF reload failed."
success "PF configured successfully."

info "Verifying installation"
info "Checking Santa..."
if command_exists santactl; then
    success "Santa is installed"
else
    error "Santa is not installed"
fi

info "Checking PF configuration..."
if maybe_sudo pfctl -sr | grep -q "wazuh_blocked"; then
    success "PF is configured"
else
    error "PF is not configured"
fi

info "Checking LaunchDaemon..."
plist="$LAUNCHDAEMONS_DIR/com.wazuh.refresh.plist"
if [[ ! -f "$plist" ]]; then
    error "LaunchDaemon not found: $plist"
fi
success "LaunchDaemon present."

success "Installation complete!"
