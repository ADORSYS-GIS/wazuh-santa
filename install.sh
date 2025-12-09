#!/bin/sh

# Set shell options
if [ -n "$BASH_VERSION" ]; then
    set -euo pipefail
else
    set -eu
fi

# Variables
LOG_LEVEL=${LOG_LEVEL:-INFO}
WAZUH_MANAGER=${WAZUH_MANAGER:-'wazuh.example.com'}
WAZUH_AGENT_VERSION=${WAZUH_AGENT_VERSION:-'4.13.1-1'}

# Define text formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
BOLD='\033[1m'
NORMAL='\033[0m'

# Function for logging with timestamp
log() {
    local LEVEL="$1"
    shift
    local MESSAGE="$*"
    local TIMESTAMP
    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    echo -e "${TIMESTAMP} ${LEVEL} ${MESSAGE}"
}

# Logging helpers
info_message() {
    log "${BLUE}${BOLD}[INFO]${NORMAL}" "$*"
}

warn_message() {
    log "${YELLOW}${BOLD}[WARNING]${NORMAL}" "$*"
}

error_message() {
    log "${RED}${BOLD}[ERROR]${NORMAL}" "$*"
}

success_message() {
    log "${GREEN}${BOLD}[SUCCESS]${NORMAL}" "$*"
}

print_step() {
    log "${BLUE}${BOLD}[STEP]${NORMAL}" "$1: $2"
}


print_step_header() {
    echo -e "\n${BOLD}===== STEP $1: $2 =====${NORMAL}\n";
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Ensure root privileges, either directly or through sudo
maybe_sudo() {
    if [ "$(id -u)" -ne 0 ]; then
        if command_exists sudo; then
            sudo "$@"
        else
            error_message "This script requires root privileges. Please run with sudo or as root."
            exit 1
        fi
    else
        "$@"
    fi
}

sed_alternative() {
    if command_exists gsed; then
        gsed "$@"
    else
        sed "$@"
    fi
}

# Error Handler
error_exit() {
    error_message "$1"
    exit 1
}

# Check if running on macOS
if [[ "$(uname)" != "Darwin" ]]; then
    error_exit "This script is designed for macOS only."
fi

# Configuration
SANTA_VERSION="2025.11"
SANTA_PKG_NAME="santa-$SANTA_VERSION.pkg"
SANTA_PKG_URL="https://github.com/northpolesec/santa/releases/download/$SANTA_VERSION/$SANTA_PKG_NAME"
SANTA_LOG_DIR="/var/db/santa"
SANTA_LOG_FILE="$SANTA_LOG_DIR/santa.log"
OSSEC_CONF_PATH="/Library/Ossec/etc/ossec.conf"

# Ensure required directories exist
info_message "Ensuring required directories exist..."
maybe_sudo mkdir -p "$SANTA_LOG_DIR"

# Installation Process
TEMP_DIR=$(mktemp -d) || error_exit "Failed to create temporary directory"
trap 'rm -rf "$TEMP_DIR"' EXIT

print_step_header 1 "Santa Package Download"
info_message "Downloading Santa package from $SANTA_PKG_URL..."
curl -SL --progress-bar -o "$TEMP_DIR/$SANTA_PKG_NAME" "$SANTA_PKG_URL" || error_exit "Failed to download $SANTA_PKG_NAME"
success_message "Santa package downloaded successfully."

print_step_header 2 "Santa Installation"
info_message "Installing Santa package..."
maybe_sudo installer -pkg "$TEMP_DIR/$SANTA_PKG_NAME" -target / || error_exit "Failed to install Santa package"
success_message "Santa installed successfully."

print_step_header 4 "Wazuh Agent Configuration"
info_message "Configuring Wazuh agent to collect Santa logs..."

# Check if Wazuh config file exists
if [ ! -f "$OSSEC_CONF_PATH" ]; then
    error_exit "Wazuh configuration file not found at $OSSEC_CONF_PATH"
fi

# Backup original config file
info_message "Backing up original Wazuh configuration..."
maybe_sudo cp "$OSSEC_CONF_PATH" "$OSSEC_CONF_PATH.backup.$(date +%s)"

# Add Santa log monitoring to Wazuh configuration
info_message "Adding Santa log monitoring to Wazuh configuration..."

# Check if Santa log monitoring is already configured
if ! maybe_sudo grep -q "<location>/var/db/santa/santa.log</location>" "$OSSEC_CONF_PATH"; then
    info_message "Configuring santa logs in $OSSEC_CONF_PATH"
    sed_alternative -i -e "/<\/ossec_config>/i\\
                <!-- santa logs -->\\
                <localfile>\\
                    <log_format>syslog</log_format>\\
                    <location>/var/db/santa/santa.log</location>\\
                </localfile>" "$OSSEC_CONF_PATH"
    info_message "santa logs are now being monitored"
else
    info_message "santa logs already being monitored in $OSSEC_CONF_PATH"
fi

print_step_header 5 "Restarting Services"
info_message "Restarting Wazuh agent to apply configuration changes..."
maybe_sudo /Library/Ossec/bin/wazuh-control restart || warn_message "Failed to restart Wazuh agent"

print_step_header 6 "Validating installation"
# Validate installation
if command_exists santactl; then
    success_message "Santa CLI tool is available."
else
    error_exit "Santa CLI tool is not available after installation."
fi

# Check if Santa daemon is running
if maybe_sudo launchctl list | grep -q "com.northpolesec.santa.daemon"; then
    success_message "Santa daemon is running."
else
    warn_message "Santa daemon does not appear to be running."
fi

# Check if Wazuh configuration includes Santa logs
if maybe_sudo grep -q "<location>/var/db/santa/santa.log</location>" "$OSSEC_CONF_PATH"; then
    success_message "Wazuh configuration includes Santa log monitoring."
else
    warn_message "Wazuh configuration may not include Santa log monitoring."
fi

success_message "Installation and configuration complete!"