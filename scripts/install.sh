#!/bin/bash
# Set shell options
if [ -n "$BASH_VERSION" ]; then
    set -euo pipefail
else
    set -eu
fi

# Define text formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
BOLD='\033[1m'
NORMAL='\033[0m'


# Variables
OS_NAME=$(uname -s)
DLP_BASE_URL="https://raw.githubusercontent.com/ADORSYS-GIS/wazuh-auditd/refs/heads/feat/DLP"
DLP_SH_URL="${DLP_BASE_URL}/scripts/dlp.sh"
SURICATA_CONFIG_URL="${DLP_BASE_URL}/config/"
SURICATA_RULE_FILE="suricata-exfiltration.rules"
ACTIVE_RESPONSE_DIR="/Library/Ossec/active-response/bin"
PF_CONF_PATH="/etc/pf.conf"
case "$OS_NAME" in
    Darwin)
        SURICATA_YAML_PATH="/etc/suricata/suricata.yaml"
        ;;
    *)
        error "Unsupported operating system: $OS_NAME. This script is designed for MacOS systems only."
        exit 1
        ;;
esac

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
error() { log "${RED}${BOLD}[ERROR]${NORMAL}" "$*"; exit 1; }
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
download "$DLP_SH_URL" "$ACTIVE_RESPONSE_DIR/dlp.sh" 755 || error "Failed to download dlp.sh"
success "DLP active response script installed successfully."

# PF Configuration
info "Configuring PF..."
ensure_pf_rules
maybe_sudo pfctl -E 2>/dev/null || true
maybe_sudo pfctl -f "$PF_CONF_PATH" 2>/dev/null || warn "PF reload failed."
success "PF configured successfully."

info "Installing Suricata Rules for Exfiltration Detection"
info "Backing up existing Suricata configuration..."
if [ -f "$SURICATA_YAML_PATH" ]; then
    maybe_sudo cp "$SURICATA_YAML_PATH" "${SURICATA_YAML_PATH}.bak" || warn "Failed to backup Suricata configuration. Please ensure you have a backup of your suricata.yaml before proceeding."
    success "Suricata configuration backed up successfully."
else
    warn "Suricata configuration file not found at $SURICATA_YAML_PATH. Please ensure Suricata is installed and configured correctly."
fi
info "Installing Suricata Rules for Exfiltration Detection"
maybe_sudo curl -fsSL "${SURICATA_CONFIG_URL}/${SURICATA_RULE_FILE}" -o /var/lib/suricata/rules/$SURICATA_RULE_FILE || error_exit "Failed to install suricata rules"

maybe_sudo yq -i "
  .[\"rule-files\"] += [\"$SURICATA_RULE_FILE\"] |
  .[\"rule-files\"] |= unique
" "$SURICATA_YAML_PATH" || warn "Failed to update Suricata configuration. Please ensure suricata.yaml is configured correctly."
success "Suricata rules installed successfully."
info "Restarting Suricata service..."
if [ -f /Library/LaunchDaemons/com.suricata.suricata.plist ]; then
    info "Restarting Suricata (launchd)..."
    maybe_sudo launchctl kickstart -k system/com.suricata.suricata \
        || warn "Failed to restart Suricata via launchctl"
else
    warn "Suricata LaunchDaemon not found; restart manually"
fi

info "Verifying installation"
info "Verifying Suricata rules..."
if suricata -T -c $SURICATA_YAML_PATH 2>&1 >/dev/null; then
    success "Suricata rules validated."
else
    warn "Suricata rules validation failed, restoring backup."
    maybe_sudo cp "${SURICATA_YAML_PATH}.bak" "$SURICATA_YAML_PATH" || warn "Failed to restore Suricata configuration backup. Please check your suricata.yaml file."
    maybe_sudo systemctl restart suricata-wazuh > /dev/null 2>&1 || warn "Failed to restart Suricata service after restoring configuration. Please check your Suricata setup."
fi
maybe_sudo rm -f "${SURICATA_YAML_PATH}.bak" || warn "Failed to remove Suricata configuration backup. Please check your suricata.yaml file."

info "Checking Dependencies..."
if command_exists jq; then
    success "jq is installed"
else
    warn "jq is not installed. Please install it with: brew install jq"
fi

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

success "Installation complete!"
