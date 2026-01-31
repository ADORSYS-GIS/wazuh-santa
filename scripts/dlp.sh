#!/bin/bash
# DLP Active Response Script (macOS)
# Actions: Blocks destination IP/domain temporarily or permanently

# -------------------------------------------------------------------------
# Global Configuration & Arguments
# -------------------------------------------------------------------------

set -euo pipefail

# Default Configuration
LOG_FILE="/Library/Ossec/active-response/active-responses.log"
ICON_PATH="/Library/Application Support/Ossec/wazuh-logo.png"
STATE_DIR="/Library/Ossec/active-response/dlp-state"
STATE_FILE="${STATE_DIR}/dlp_state.json"
REFRESH_PLIST="/Library/LaunchDaemons/com.wazuh.refresh.plist"
PF_TABLE="wazuh_blocked"
UNBLOCK_DURATION=${UNBLOCK_DURATION:-60}
OS_NAME=$(uname -s)

# Argument Parsing
REFRESH=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -refresh) REFRESH=true; shift ;;
        *) break ;;
    esac
done

# Ensure state directory exists
[[ -d "$STATE_DIR" ]] || mkdir -p "$STATE_DIR" && chmod 750 "$STATE_DIR"

# -------------------------------------------------------------------------
# Logging & Cleanup
# -------------------------------------------------------------------------
log() {
    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    echo "$ts wazuh-dlp: $1" >> "$LOG_FILE"
}

cleanup() {
    :
}

trap cleanup EXIT INT TERM

# -------------------------------------------------------------------------
# State Management
# -------------------------------------------------------------------------
get_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        log "Warning: State file not found, creating new state file"
        echo '{"domains":{},"ips":{}}' > "$STATE_FILE"
        chmod 640 "$STATE_FILE"
    else
        log "Info: Loaded state file: $STATE_FILE"
    fi
    cat "$STATE_FILE"
}

save_state() {
    local state="$1"
    echo "$state" > "$STATE_FILE"
}

# -------------------------------------------------------------------------
# Dependency Check
# -------------------------------------------------------------------------
for bin in jq pfctl; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        log "Error: $bin not found. Ensure it is installed and in PATH."
        exit 1
    fi
done

# -------------------------------------------------------------------------
# Network & Blocking Logic
# -------------------------------------------------------------------------
resolve_domain() {
    local domain=$1
    local ips=()

    if command -v dig &>/dev/null; then
        while IFS= read -r ip; do
            [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$ip" =~ : ]] && ips+=("$ip")
        done < <({ dig +short "$domain" A; dig +short "$domain" AAAA; } 2>/dev/null)
    elif command -v nslookup &>/dev/null; then
        while IFS= read -r ip; do
            [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$ip" =~ : ]] && ips+=("$ip")
        done < <(nslookup "$domain" 2>/dev/null | awk 'found && $1=="Address:" {print $2} /^Name:/{found=1}' | sed 's/#.*//')
    fi
    
    [[ ${#ips[@]} -eq 0 ]] && return 1
    printf "%s\n" "${ips[@]}"
}

block_ip() {
    local ip="$1"
    local source="${2:-Unknown}"
    local unblock_at="${3:-Never}"
    
    log "Info: Attempting to block IP: $ip (Source: $source, Unblock: $unblock_at)"
    
    if ! pfctl -t "$PF_TABLE" -T test "$ip" &>/dev/null; then
        if pfctl -t "$PF_TABLE" -T add "$ip" &>/dev/null; then
            log "Info: Successfully blocked IP: $ip (Source: $source)"
            return 0
        else
            log "Error: Failed to block IP: $ip"
            return 1
        fi
    else
        log "Info: $ip already exists in pf table ($PF_TABLE)"
        return 0
    fi
}

unblock_ip() {
    local ip="$1"
    log "Info: Attempting to unblock IP: $ip"
    if pfctl -t "$PF_TABLE" -T test "$ip" &>/dev/null; then
        if pfctl -t "$PF_TABLE" -T delete "$ip" &>/dev/null; then
            log "Info: Successfully unblocked IP: $ip"
            return 0
        else
            log "Error: Failed to unblock IP: $ip"
            return 1
        fi
    else
        log "Info: No pf entry found for IP: $ip - nothing to unblock"
        return 0
    fi
}

update_domain() {
    local domain=$1
    local block_type=$2
    local unblock_time=$3
    local state="$4"
    
    log "Info: Updating IPs for target: $domain (Type: $block_type, Unblock: $unblock_time)"
    
    local resolved_ips
    resolved_ips=$(resolve_domain "$domain" || echo "")
    
    local old_ips
    old_ips=$(echo "$state" | jq -r ".domains[\"$domain\"].ips // [] | .[]")
    
    # Block new IPs
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        if ! echo "$old_ips" | grep -q "^$ip$"; then
            block_ip "$ip" "$domain" "$unblock_time"
        fi
    done <<< "$resolved_ips"

    # Unblock removed IPs
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        if ! echo "$resolved_ips" | grep -q "^$ip$"; then
            unblock_ip "$ip"
        fi
    done <<< "$old_ips"

    local new_ips_json
    new_ips_json=$(echo "$resolved_ips" | jq -R . | jq -s .)
    echo "$state" | jq --arg domain "$domain" --arg type "$block_type" --arg utime "$unblock_time" --argjson ips "$new_ips_json" \
        '.domains[$domain] = {ips: $ips, type: $type, unblockTime: $utime}'
}

# -------------------------------------------------------------------------
# Periodic Refresh Mode
# -------------------------------------------------------------------------
if $REFRESH; then
    log "Info: Running periodic domain refresh and timeout check"
    state=$(get_state)
    now=$(date +%s)
    changed=false

    # Check IP timeouts
    ip_keys=$(echo "$state" | jq -r '.ips | keys | .[]' 2>/dev/null || true)
    log "Debug: Checking $(echo "$ip_keys" | wc -l | tr -d ' ') IPs for timeout"
    for ip in $ip_keys; do
        ip_data=$(echo "$state" | jq -c ".ips[\"$ip\"]")
        type=$(echo "$ip_data" | jq -r '.type')
        unblock_time=$(echo "$ip_data" | jq -r '.unblockTime')
        
        if [[ "$type" == "temp" && "$unblock_time" != "Never" ]]; then
            unblock_ts=$(date -j -f "%Y-%m-%d %H:%M:%S" "$unblock_time" +%s 2>/dev/null || echo 0)
            if [[ $now -ge $unblock_ts ]]; then
                log "Info: IP $ip has expired (unblock_time: $unblock_time), removing from block list"
                unblock_ip "$ip"
                state=$(echo "$state" | jq "del(.ips[\"$ip\"])")
                changed=true
            else
                log "Debug: IP $ip still valid until $unblock_time"
            fi
        fi
    done

    # Check Domain timeouts and refresh
    domain_keys=$(echo "$state" | jq -r '.domains | keys | .[]' 2>/dev/null || true)
    log "Debug: Checking $(echo "$domain_keys" | wc -l | tr -d ' ') domains for timeout and refresh"
    for domain in $domain_keys; do
        domain_data=$(echo "$state" | jq -c ".domains[\"$domain\"]")
        type=$(echo "$domain_data" | jq -r '.type')
        unblock_time=$(echo "$domain_data" | jq -r '.unblockTime')
        
        if [[ "$type" == "temp" && "$unblock_time" != "Never" ]]; then
            unblock_ts=$(date -j -f "%Y-%m-%d %H:%M:%S" "$unblock_time" +%s 2>/dev/null || echo 0)
            if [[ $now -ge $unblock_ts ]]; then
                log "Info: Domain $domain has expired (unblock_time: $unblock_time), removing from block list"
                domain_ips=$(echo "$domain_data" | jq -r '.ips[]' 2>/dev/null || true)
                for ip in $domain_ips; do
                    unblock_ip "$ip"
                done
                state=$(echo "$state" | jq "del(.domains[\"$domain\"])")
                changed=true
                continue
            else
                log "Debug: Domain $domain still valid until $unblock_time"
            fi
        fi
        
        state=$(update_domain "$domain" "$type" "$unblock_time" "$state")
        changed=true
    done

    if $changed; then
        log "Debug: Saving updated state to $STATE_FILE"
        save_state "$state"
    fi
    
    # Check if state is empty and unload refresh daemon if so
    if echo "$state" | jq -e '.domains == {} and .ips == {}' > /dev/null 2>&1; then
        log "State is empty, unloading refresh daemon"
        launchctl unload "$REFRESH_PLIST" 2>/dev/null || log "Warning: Failed to unload refresh daemon (may not be loaded)"
    else
        log "Refresh cycle completed. Active blocks: $(echo "$state" | jq -r '.domains | length') domains, $(echo "$state" | jq -r '.ips | length') IPs"
    fi
    
    exit 0
fi

# -------------------------------------------------------------------------
# Argument Extraction
# -------------------------------------------------------------------------
extract_match() {
    local value="$1"
    local ip_regex='([0-9]{1,3}(\.[0-9]{1,3}){3})'
    local domain_regex='https?://([^:/]+)'

    if [[ $value =~ $ip_regex ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    elif [[ $value =~ $domain_regex ]]; then
        local domain="${BASH_REMATCH[1]}"
        if [[ ! $domain =~ \.(txt|log|conf|json|yaml|yml)$ ]]; then
            echo "$domain"
            return 0
        fi
    fi
    return 1
}

extract_destination() {
    local input="$1"
    local arg

    if [[ "$OS_NAME" == "Darwin" ]]; then
        extract_match "$input"
    elif [[ "$OS_NAME" == "Linux" ]]; then
        while read -r arg; do
            if extract_match "$arg"; then
                return
            fi
        done < <(jq -r '.[]' <<< "$input")
    fi
}

# -------------------------------------------------------------------------
# Blocking Logic Handlers
# -------------------------------------------------------------------------
block_destination() {
    local target="$1"
    local duration="${2:-$UNBLOCK_DURATION}"
    local state
    state=$(get_state)
    local unblock_time="Never"
    local type="perm"
    
    log "Info: Initiating block for $target (Duration: ${duration}s)"
    log "Debug: State before block: $(echo "$state" | jq -c '.')"
    
    if [[ $duration -gt 0 ]]; then
        unblock_time=$(date -v+${duration}S +"%Y-%m-%d %H:%M:%S")
        type="temp"
    fi
    
    if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$target" =~ : ]]; then
        block_ip "$target" "Manual" "$unblock_time"
        state=$(echo "$state" | jq --arg ip "$target" --arg type "$type" --arg utime "$unblock_time" \
            '.ips[$ip] = {type: $type, unblockTime: $utime}')
    else
        state=$(update_domain "$target" "$type" "$unblock_time" "$state")
    fi
    
    save_state "$state"
    log "Debug: State after block: $(echo "$state" | jq -c '.')"
    
    if ! launchctl list | grep -q "com.wazuh.refresh"; then
        log "Info: Loading refresh daemon at $REFRESH_PLIST"
        launchctl load "$REFRESH_PLIST" 2>/dev/null || log "Warning: Failed to load refresh daemon"
    fi
}

# -------------------------------------------------------------------------
# Notification Logic
# -------------------------------------------------------------------------
confirm_action() {
    local action="$1"
    local message="$2"
    
    if [[ "$OS_NAME" == "Darwin" ]]; then
        local cmd="display dialog \"$message\" with title \"Wazuh DLP Confirmation\" buttons {\"Cancel\", \"$action\"} default button \"Cancel\" with icon caution"
        if osascript -e "$cmd" 2>/dev/null | grep -q "button returned:$action"; then
            return 0
        fi
    fi
    return 1
}

send_notification() {
    local title="Wazuh-DLP Exfiltration Alert"
    local message="$1"
    local target="$2"
    local action=""
    
    log "Info: Sending exfiltration alert for target: $target"

    if [[ "$OS_NAME" == "Darwin" ]]; then
        local icon_arg=""
        [[ -f "$ICON_PATH" ]] && icon_arg="with icon POSIX file \"$ICON_PATH\""
        local cmd="display dialog \"$message\" with title \"$title\" buttons {\"Block Temporarily\", \"Block Permanently\", \"Dismiss\"} default button \"Dismiss\" $icon_arg"
        local result=$(osascript -e "$cmd" 2>/dev/null || echo "button returned:Dismiss")
        
        if [[ "$result" == *"Block Temporarily"* ]]; then action="temp"
        elif [[ "$result" == *"Block Permanently"* ]]; then action="perm"
        else action="temp"; fi
    fi

    case "$action" in
        "temp")
            log "Info: User selected 'Block Temporarily' for $target"
            if confirm_action "Block Temporarily" "Block $target for $UNBLOCK_DURATION seconds?"; then
                block_destination "$target" "$UNBLOCK_DURATION"
            fi
            ;;
        "perm")
            log "Info: User selected 'Block Permanently' for $target"
            if confirm_action "Block Permanently" "Are you sure you want to block $target permanently?"; then
                block_destination "$target" "0"
            fi
            ;;
        "dismiss")
            log "Info: User dismissed alert for $target"
            ;;
    esac
}

# -------------------------------------------------------------------------
# Main Execution
# -------------------------------------------------------------------------
read INPUT_JSON
EXFIL_COMMAND==$(echo "$INPUT_JSON" | jq -r .parameters.alert.data.args)
RULE_ID=$(echo "$INPUT_JSON" | jq -r .parameters.alert.rule.id)

destination=$(extract_destination "$EXFIL_COMMAND")

if [[ -z "$destination" ]]; then
    log "Error: Could not extract destination from input"
    exit 0
fi

log "Info: Processing exfiltration event [Rule: $RULE_ID, Destination: $destination]"

send_notification "Potential data exfiltration detected to $destination. Rule: $RULE_ID" "$destination"