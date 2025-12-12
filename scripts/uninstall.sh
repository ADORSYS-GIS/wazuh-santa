#!/bin/sh

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
UNINSTALL_SCRIPT_URL="https://raw.githubusercontent.com/northpolesec/santa/refs/heads/main/Conf/uninstall.sh"
TEMP_DIR=$(mktemp -d)
UNINSTALL_SCRIPT_PATH="${TEMP_DIR}/uninstall_santa.sh"

cleanup() {
    rm -rf "${TEMP_DIR}" || true
    
    # Remove Santa configuration directory if it exists
    if [[ -d "/var/db/santa" ]]; then
        info_message "Removing Santa configuration directory..."
        maybe_sudo rm -rf "/var/db/santa" || warn_message "Failed to remove /var/db/santa"
    fi
}

# Set up trap to ensure cleanup happens on exit
trap cleanup EXIT

# Check if Santa is installed and running
check_santa_installed() {
    # Check if Santa components exist
    if [[ ! -f "/var/db/santa/config.plist" && ! -x "$(command -v santactl 2>/dev/null)" ]]; then
        info_message "Santa is not installed. Nothing to uninstall."
        return 1
    fi
    
    # Check if Santa daemon is running
    if pgrep -q "^com\.google\.santad$"; then
        info_message "Santa daemon is running. Version: $(santactl version 2>/dev/null || echo 'unknown')"
    else
        warn_message "Santa daemon is not running. Proceeding with uninstallation of installed components."
    fi
    
    return 0
}

# Main execution
main() {
    # Check if Santa is installed before proceeding
    if ! check_santa_installed; then
        exit 0
    fi
    
    print_step "1" "Downloading Santa uninstall script..."
    if command_exists curl; then
        if ! curl -sSL "${UNINSTALL_SCRIPT_URL}" -o "${UNINSTALL_SCRIPT_PATH}"; then
            error_exit "Failed to download Santa uninstall script"
        fi
    elif command_exists wget; then
        if ! wget -q "${UNINSTALL_SCRIPT_URL}" -O "${UNINSTALL_SCRIPT_PATH}"; then
            error_exit "Failed to download Santa uninstall script"
        fi
    else
        error_exit "Neither curl nor wget is available. Please install one of them and try again."
    fi

    # Make the script executable
    chmod +x "${UNINSTALL_SCRIPT_PATH}"

    print_step "2" "Running Santa uninstall script..."
    maybe_sudo "${UNINSTALL_SCRIPT_PATH}" || {
        warn_message "Santa uninstall script returned non-zero exit status. Continuing..."
    }

    success_message "Santa has been successfully uninstalled."
}

# Execute main function
main "$@"

exit 0
