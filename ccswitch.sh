#!/usr/bin/env bash

# Multi-Account Switcher for Claude Code
# Simple tool to manage and switch between multiple Claude Code accounts

set -euo pipefail

# launchd/cron invoke us with a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`),
# which does not include Homebrew. Without this line `jq`, `curl`,
# modern `bash`, etc. are not found.
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"

# cron's environment lacks USER/LOGNAME on macOS. `security add-generic-password
# -a "$USER"` then aborts under `set -u`, killing perform_switch before any
# keychain write — the agent looks like it ran (cron fired, decision logged)
# but no actual switch happens. Backfill from `id -un` so the keychain
# account-attribute matches what an interactive session would write.
export USER="${USER:-$(id -un 2>/dev/null)}"
export LOGNAME="${LOGNAME:-$USER}"

# Configuration
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"
readonly CRON_LOG="$BACKUP_DIR/cron.log"

# LaunchAgent integration (macOS). User LaunchAgents run inside the Aqua
# GUI session, so `security` can read the login keychain and `osascript`
# can post notifications — neither works from a plain cron invocation.
readonly AGENT_LABEL="com.ccswitch.auto-switch"
readonly AGENT_PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"

# Cron integration (Linux / legacy macOS). Kept for parity but on macOS
# prefer --agent-install which avoids the keychain/notification issues.
readonly CRON_MARKER="# ccswitch-auto-switch"
readonly CRON_SCHEDULE="0 * * * *"
readonly CRON_COMMAND="--switch-lowest"

# Anthropic OAuth usage API constants (see claude-hud usage-api.js)
readonly USAGE_API_URL="https://api.anthropic.com/api/oauth/usage"
readonly USAGE_API_BETA="oauth-2025-04-20"
readonly USAGE_API_UA="claude-code/2.1"
readonly USAGE_API_TIMEOUT=5

# Per-account usage cache. Short TTL because we want decisions on near-fresh
# data; only --show-usage / repeat manual queries benefit. --switch-lowest
# (the LaunchAgent path) deliberately bypasses the cache by never setting
# CCSWITCH_USE_CACHE=1, so its decision always reflects current API state.
readonly USAGE_CACHE_DIR="$BACKUP_DIR/usage-cache"
readonly USAGE_CACHE_TTL=10

# Switch hysteresis. If the picker's target is on a different account
# but its adjusted utilization is only this many percentage points
# lower than the current account, stay put. Avoids thrashing between
# near-equal accounts, which kills active Claude Code sessions on
# every cron tick. Override per-invocation with the env var.
readonly HYSTERESIS_DELTA="${CCSWITCH_HYSTERESIS_DELTA:-10}"

# Container detection
is_running_in_container() {
    # Check for Docker environment file
    if [[ -f /.dockerenv ]]; then
        return 0
    fi
    
    # Check cgroup for container indicators
    if [[ -f /proc/1/cgroup ]] && grep -q 'docker\|lxc\|containerd\|kubepods' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi
    
    # Check mount info for container filesystems
    if [[ -f /proc/self/mountinfo ]] && grep -q 'docker\|overlay' /proc/self/mountinfo 2>/dev/null; then
        return 0
    fi
    
    # Check for common container environment variables
    if [[ -n "${CONTAINER:-}" ]] || [[ -n "${container:-}" ]]; then
        return 0
    fi
    
    return 1
}

# Platform detection
detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux) 
            if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

# Get Claude configuration file path with fallback
get_claude_config_path() {
    local primary_config="$HOME/.claude/.claude.json"
    local fallback_config="$HOME/.claude.json"
    
    # Check primary location first
    if [[ -f "$primary_config" ]]; then
        # Verify it has valid oauthAccount structure
        if jq -e '.oauthAccount' "$primary_config" >/dev/null 2>&1; then
            echo "$primary_config"
            return
        fi
    fi
    
    # Fallback to standard location
    echo "$fallback_config"
}

# Basic validation that JSON is valid
validate_json() {
    local file="$1"
    if ! jq . "$file" >/dev/null 2>&1; then
        echo "Error: Invalid JSON in $file"
        return 1
    fi
}

# Email validation function
validate_email() {
    local email="$1"
    # Use robust regex for email validation
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Send a macOS notification about an account switch.
# No-op on non-macOS; non-fatal if notification tooling is unavailable or
# blocked by permissions (does not fail the switch).
notify_switch_macos() {
    local from_label="$1"
    local to_label="$2"

    [[ "$(detect_platform)" == "macos" ]] || return 0

    local title="Claude Code 계정 전환"
    local msg="${from_label} → ${to_label}"

    if command -v terminal-notifier >/dev/null 2>&1; then
        terminal-notifier -title "$title" -message "$msg" -sound default \
            >/dev/null 2>&1 || true
    else
        osascript \
            -e "display notification \"$msg\" with title \"$title\" sound name \"default\"" \
            >/dev/null 2>&1 || true
    fi
}

# Format a short organization label.
# Strategy: strip trailing "'s Organization"; if result is empty or collides
# with the account email, fall back to the first 8 chars of organizationUuid.
# Args: org_name org_uuid email
format_org_label() {
    local org_name="$1"
    local org_uuid="$2"
    local email="$3"

    local label="${org_name%\'s Organization}"

    if [[ -z "$label" || "$label" == "$email" ]]; then
        if [[ -n "$org_uuid" && "$org_uuid" != "null" ]]; then
            label="${org_uuid:0:8}"
        else
            label="unknown"
        fi
    fi

    echo "$label"
}

# Read current account info from .claude.json as TSV:
# email<TAB>accountUuid<TAB>organizationUuid<TAB>organizationName
get_current_account_full() {
    local config
    config=$(get_claude_config_path)

    if [[ ! -f "$config" ]] || ! jq . "$config" >/dev/null 2>&1; then
        printf '\t\t\t\n'
        return
    fi

    jq -r '[
        .oauthAccount.emailAddress // "",
        .oauthAccount.accountUuid // "",
        .oauthAccount.organizationUuid // "",
        .oauthAccount.organizationName // ""
    ] | @tsv' "$config" 2>/dev/null || printf '\t\t\t\n'
}

# Backfill organizationUuid/organizationName for an existing account by
# reading its backup config. No-op when the fields already exist or the
# backup cannot be read.
ensure_org_info() {
    local account_num="$1"

    [[ -f "$SEQUENCE_FILE" ]] || return

    local has_org
    has_org=$(jq -r --arg num "$account_num" '.accounts[$num].organizationUuid // ""' "$SEQUENCE_FILE")
    if [[ -n "$has_org" && "$has_org" != "null" ]]; then
        return
    fi

    local email
    email=$(jq -r --arg num "$account_num" '.accounts[$num].email // ""' "$SEQUENCE_FILE")
    [[ -n "$email" ]] || return

    local cfg
    cfg=$(read_account_config "$account_num" "$email")
    [[ -n "$cfg" ]] || return

    local org_uuid org_name
    org_uuid=$(echo "$cfg" | jq -r '.oauthAccount.organizationUuid // ""')
    org_name=$(echo "$cfg" | jq -r '.oauthAccount.organizationName // ""')
    [[ -n "$org_uuid" ]] || return

    local updated
    updated=$(jq --arg num "$account_num" --arg ou "$org_uuid" --arg on "$org_name" '
        .accounts[$num].organizationUuid = $ou |
        .accounts[$num].organizationName = $on
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated"
}

# Resolve identifier to account number.
# Accepts: "<num>" | "<email>" | "<email> (<org_label>)"
# Returns: account number on stdout, empty string when not found or ambiguous.
# On ambiguous email (multiple matches), prints candidate list to stderr.
resolve_account_identifier() {
    local identifier="$1"

    # Numeric: trust as-is (existence check happens at caller).
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        echo "$identifier"
        return
    fi

    [[ -f "$SEQUENCE_FILE" ]] || { echo ""; return; }

    # Parse "email (label)" form.
    local wanted_email="" wanted_label=""
    if [[ "$identifier" =~ ^(.+[^[:space:]])[[:space:]]+\((.+)\)$ ]]; then
        wanted_email="${BASH_REMATCH[1]}"
        wanted_label="${BASH_REMATCH[2]}"
    else
        wanted_email="$identifier"
    fi

    # Sanity: the email part must look like an email.
    if ! validate_email "$wanted_email"; then
        echo ""
        return
    fi

    local candidates
    candidates=$(jq -r --arg email "$wanted_email" '
        .accounts | to_entries[] | select(.value.email == $email) | .key
    ' "$SEQUENCE_FILE" 2>/dev/null)

    if [[ -z "$candidates" ]]; then
        echo ""
        return
    fi

    # Lazy-migrate org info so label comparison is meaningful.
    while read -r c; do
        [[ -n "$c" ]] && ensure_org_info "$c"
    done <<< "$candidates"

    if [[ -n "$wanted_label" ]]; then
        local match=""
        while read -r c; do
            [[ -z "$c" ]] && continue
            local entry e_email e_org_uuid e_org_name e_label
            entry=$(jq -r --arg num "$c" '.accounts[$num]' "$SEQUENCE_FILE")
            e_email=$(echo "$entry" | jq -r '.email // ""')
            e_org_uuid=$(echo "$entry" | jq -r '.organizationUuid // ""')
            e_org_name=$(echo "$entry" | jq -r '.organizationName // ""')
            e_label=$(format_org_label "$e_org_name" "$e_org_uuid" "$e_email")
            if [[ "$e_label" == "$wanted_label" ]]; then
                match="$c"
                break
            fi
        done <<< "$candidates"
        echo "$match"
        return
    fi

    local count
    count=$(echo "$candidates" | grep -c '.')
    if [[ "$count" == "1" ]]; then
        echo "$candidates" | head -n1
        return
    fi

    # Ambiguous: report candidates and return empty.
    {
        echo "Error: Multiple accounts match email '$wanted_email'. Disambiguate with org label:"
        while read -r c; do
            [[ -z "$c" ]] && continue
            local entry e_email e_org_uuid e_org_name e_label
            entry=$(jq -r --arg num "$c" '.accounts[$num]' "$SEQUENCE_FILE")
            e_email=$(echo "$entry" | jq -r '.email // ""')
            e_org_uuid=$(echo "$entry" | jq -r '.organizationUuid // ""')
            e_org_name=$(echo "$entry" | jq -r '.organizationName // ""')
            e_label=$(format_org_label "$e_org_name" "$e_org_uuid" "$e_email")
            echo "  $c: $e_email ($e_label)"
        done <<< "$candidates"
        echo ""
        echo "Use: --switch-to \"<email> (<label>)\"   or   --switch-to <number>"
    } >&2
    echo ""
}

# Safe JSON write with validation
write_json() {
    local file="$1"
    local content="$2"
    local temp_file
    temp_file=$(mktemp "${file}.XXXXXX")
    
    echo "$content" > "$temp_file"
    if ! jq . "$temp_file" >/dev/null 2>&1; then
        rm -f "$temp_file"
        echo "Error: Generated invalid JSON"
        return 1
    fi
    
    mv "$temp_file" "$file"
    chmod 600 "$file"
}

# Check Bash version (4.4+ required)
check_bash_version() {
    local version
    version=$(bash --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    if ! awk -v ver="$version" 'BEGIN { exit (ver >= 4.4 ? 0 : 1) }'; then
        echo "Error: Bash 4.4+ required (found $version)"
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    for cmd in jq curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command '$cmd' not found"
            echo "Install with: apt install $cmd (Linux) or brew install $cmd (macOS)"
            exit 1
        fi
    done
}

# Setup backup directories
setup_directories() {
    mkdir -p "$BACKUP_DIR"/{configs,credentials}
    chmod 700 "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"/{configs,credentials}
}

# Claude Code process detection (Node.js app)
is_claude_running() {
    ps -eo pid,comm,args | awk '$2 == "claude" || $3 == "claude" {exit 0} END {exit 1}'
}

# Wait for Claude Code to close (no timeout - user controlled)
wait_for_claude_close() {
    if ! is_claude_running; then
        return 0
    fi
    
    echo "Claude Code is running. Please close it first."
    echo "Waiting for Claude Code to close..."
    
    while is_claude_running; do
        sleep 1
    done
    
    echo "Claude Code closed. Continuing..."
}

# Get current account info from .claude.json
get_current_account() {
    if [[ ! -f "$(get_claude_config_path)" ]]; then
        echo "none"
        return
    fi
    
    if ! validate_json "$(get_claude_config_path)"; then
        echo "none"
        return
    fi
    
    local email
    email=$(jq -r '.oauthAccount.emailAddress // empty' "$(get_claude_config_path)" 2>/dev/null)
    echo "${email:-none}"
}

# Read credentials based on platform
read_credentials() {
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            if [[ -f "$HOME/.claude/.credentials.json" ]]; then
                cat "$HOME/.claude/.credentials.json"
            else
                echo ""
            fi
            ;;
    esac
}

# Write credentials based on platform
write_credentials() {
    local credentials="$1"
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            mkdir -p "$HOME/.claude"
            printf '%s' "$credentials" > "$HOME/.claude/.credentials.json"
            chmod 600 "$HOME/.claude/.credentials.json"
            ;;
    esac
}

# Read account credentials from backup.
# macOS: keychain is authoritative. When it returns usable creds we also
# mirror them to a chmod-600 file so that cron (which runs in a session
# with no keychain access) can still perform read-only usage lookups.
# If the keychain read fails (typical cron context), we fall back to that
# file mirror. Same security tier as the existing $BACKUP_DIR/configs/ files.
read_account_credentials() {
    local account_num="$1"
    local email="$2"
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            local keychain_result
            keychain_result=$(security find-generic-password -s "Claude Code-Account-${account_num}-${email}" -w 2>/dev/null || true)
            if [[ -n "$keychain_result" ]]; then
                # Opportunistically mirror to file so cron can read later.
                if printf '%s' "$keychain_result" > "$cred_file" 2>/dev/null; then
                    chmod 600 "$cred_file" 2>/dev/null || true
                fi
                echo "$keychain_result"
                return
            fi
            # Keychain inaccessible (locked / cron). Fall back to file mirror.
            if [[ -f "$cred_file" ]]; then
                cat "$cred_file"
            else
                echo ""
            fi
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            if [[ -f "$cred_file" ]]; then
                cat "$cred_file"
            else
                echo ""
            fi
            ;;
    esac
}

# Write account credentials to backup.
# macOS: keychain is authoritative; also mirror to file so cron can read.
write_account_credentials() {
    local account_num="$1"
    local email="$2"
    local credentials="$3"
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-Account-${account_num}-${email}" -a "$USER" -w "$credentials" 2>/dev/null
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            printf '%s' "$credentials" > "$cred_file"
            chmod 600 "$cred_file"
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            printf '%s' "$credentials" > "$cred_file"
            chmod 600 "$cred_file"
            ;;
    esac
}

# Read account config from backup
read_account_config() {
    local account_num="$1"
    local email="$2"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    if [[ -f "$config_file" ]]; then
        cat "$config_file"
    else
        echo ""
    fi
}

# Write account config to backup
write_account_config() {
    local account_num="$1"
    local email="$2"
    local config="$3"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    echo "$config" > "$config_file"
    chmod 600 "$config_file"
}

# Initialize sequence.json if it doesn't exist
init_sequence_file() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        local init_content='{
  "activeAccountNumber": null,
  "lastUpdated": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "sequence": [],
  "accounts": {}
}'
        write_json "$SEQUENCE_FILE" "$init_content"
    fi
}

# Get next account number
get_next_account_number() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "1"
        return
    fi
    
    local max_num
    max_num=$(jq -r '.accounts | keys | map(tonumber) | max // 0' "$SEQUENCE_FILE")
    echo $((max_num + 1))
}

# Fetch the live utilization% for a managed account without switching to it.
# Usage: fetch_account_utilization <num> <email>
#   Returns: "<five_hour> <seven_day>" on stdout (space-separated integers 0-100)
#   Exit: 0 on success, non-zero (silent except stderr) on any failure.
# Strategy: read the per-account keychain credential, drop accounts whose
# accessToken has expired, and call Anthropic's OAuth usage API. See
# claude-hud project ("usage-api.js") — https://github.com/Piebald-AI/claude-hud
# for the shape reference.
fetch_account_utilization() {
    local account_num="$1"
    local email="$2"

    local cred
    cred=$(read_account_credentials "$account_num" "$email")
    if [[ -z "$cred" ]]; then
        echo "  [Account-$account_num $email] no credentials in backup" >&2
        return 1
    fi

    local access_token expires_at_ms
    access_token=$(echo "$cred" | jq -r '.claudeAiOauth.accessToken // ""' 2>/dev/null)
    expires_at_ms=$(echo "$cred" | jq -r '.claudeAiOauth.expiresAt // 0' 2>/dev/null)

    if [[ -z "$access_token" || "$access_token" == "null" ]]; then
        echo "  [Account-$account_num $email] no accessToken in credential blob" >&2
        return 1
    fi

    if [[ "$expires_at_ms" =~ ^[0-9]+$ ]]; then
        local now_ms=$(( $(date +%s) * 1000 ))
        if (( expires_at_ms > 0 && expires_at_ms <= now_ms )); then
            echo "  [Account-$account_num $email] accessToken expired; skipping" >&2
            return 1
        fi
    fi

    # Cache lookup: when CCSWITCH_USE_CACHE=1 and a fresh cache row exists,
    # skip the API call entirely. Honored only by --show-usage; --switch-lowest
    # never sets the env var so its decision uses live data.
    local cache_file="$USAGE_CACHE_DIR/account-$account_num"
    if [[ "${CCSWITCH_USE_CACHE:-0}" == "1" && -f "$cache_file" ]]; then
        local cache_mtime now_sec age
        if [[ "$(detect_platform)" == "macos" ]]; then
            cache_mtime=$(/usr/bin/stat -f %m "$cache_file" 2>/dev/null || echo 0)
        else
            cache_mtime=$(/usr/bin/stat -c %Y "$cache_file" 2>/dev/null || echo 0)
        fi
        now_sec=$(date +%s)
        age=$(( now_sec - cache_mtime ))
        if (( age >= 0 && age < USAGE_CACHE_TTL )); then
            cat "$cache_file"
            return 0
        fi
    fi

    # Fetch fresh. Capture body, headers, and HTTP status so we can detect
    # rate-limit (429) clearly and read its Retry-After header.
    local body_file hdrs_file status
    body_file=$(/usr/bin/mktemp -t ccswitch_body) || {
        echo "  [Account-$account_num $email] mktemp failed" >&2
        return 1
    }
    hdrs_file=$(/usr/bin/mktemp -t ccswitch_hdrs) || {
        /bin/rm -f "$body_file"
        echo "  [Account-$account_num $email] mktemp failed" >&2
        return 1
    }
    status=$(curl -sS --max-time "$USAGE_API_TIMEOUT" \
        -D "$hdrs_file" \
        -o "$body_file" \
        -w "%{http_code}" \
        -H "Authorization: Bearer $access_token" \
        -H "anthropic-beta: $USAGE_API_BETA" \
        -H "User-Agent: $USAGE_API_UA" \
        "$USAGE_API_URL" 2>/dev/null) || {
        /bin/rm -f "$body_file" "$hdrs_file"
        echo "  [Account-$account_num $email] usage API request failed (network/timeout)" >&2
        return 1
    }

    if [[ "$status" == "429" ]]; then
        # Anthropic returns a Retry-After header (seconds) on rate limits.
        # Extract case-insensitively and strip CR.
        local retry_after
        retry_after=$(/usr/bin/grep -i '^retry-after:' "$hdrs_file" 2>/dev/null \
            | /usr/bin/awk '{gsub(/\r/,""); print $2; exit}')
        /bin/rm -f "$body_file" "$hdrs_file"
        if [[ -n "$retry_after" ]]; then
            echo "  [Account-$account_num $email] rate-limited by Anthropic API (HTTP 429); Retry-After: ${retry_after}s" >&2
        else
            echo "  [Account-$account_num $email] rate-limited by Anthropic API (HTTP 429); no Retry-After header" >&2
        fi
        return 2
    fi

    if [[ "$status" != "200" ]]; then
        /bin/rm -f "$body_file" "$hdrs_file"
        echo "  [Account-$account_num $email] usage API HTTP $status" >&2
        return 1
    fi

    local response
    response=$(/bin/cat "$body_file")
    /bin/rm -f "$body_file" "$hdrs_file"

    if ! echo "$response" | jq -e '.five_hour.utilization' >/dev/null 2>&1; then
        echo "  [Account-$account_num $email] unexpected usage API response" >&2
        return 1
    fi

    # Returns six space-separated fields:
    #   <5h%> <7d%> <5h_resets_epoch> <7d_resets_epoch> <extra_enabled> <extra_util>
    # resets_at are Unix epoch seconds; 0 if missing or unparsable.
    # extra_enabled is "true"/"false" from the live API (preferred over the
    # snapshot in backup config). extra_util is the rounded extra-usage
    # percentage (0 when disabled or absent).
    local five seven five_reset seven_reset extra_enabled extra_util
    five=$(echo "$response" | jq -r '((.five_hour.utilization // 0) | floor)')
    seven=$(echo "$response" | jq -r '((.seven_day.utilization // 0) | floor)')
    # Anthropic returns "2026-04-26T21:10:00.809428+00:00" (microseconds +
    # numeric tz). jq's fromdateiso8601 doesn't handle either; strip both,
    # then strptime+mktime as UTC. resets_at IS UTC per API contract.
    local _iso_to_epoch='(. // "") | sub("\\.[0-9]+"; "") | sub("[+-][0-9]{2}:[0-9]{2}$"; "Z") | if . == "" then 0 else (try (strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch 0) end'
    five_reset=$(echo "$response" | jq -r ".five_hour.resets_at | $_iso_to_epoch")
    seven_reset=$(echo "$response" | jq -r ".seven_day.resets_at | $_iso_to_epoch")
    extra_enabled=$(echo "$response" | jq -r '.extra_usage.is_enabled // false')
    extra_util=$(echo "$response" | jq -r '((.extra_usage.utilization // 0) | floor)')

    local result="$five $seven $five_reset $seven_reset $extra_enabled $extra_util"
    # Always write cache on success — even when the caller didn't request
    # cache use. Costs nothing and means a subsequent --show-usage hit
    # within TTL serves from disk without burning more API quota.
    /bin/mkdir -p "$USAGE_CACHE_DIR" 2>/dev/null
    printf '%s\n' "$result" > "$cache_file" 2>/dev/null
    echo "$result"
}

# Read this account's handicap from sequence.json.
# Args: account_num. Missing / null / non-integer yields 0.
get_account_handicap() {
    local account_num="$1"
    [[ -f "$SEQUENCE_FILE" ]] || { echo 0; return; }
    local h
    h=$(jq -r --arg num "$account_num" '.accounts[$num].handicap // 0' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ "$h" =~ ^[0-9]+$ ]]; then
        echo "$h"
    else
        echo 0
    fi
}

# Collect usage for all managed accounts in ONE sweep. Performs one API
# call per account (unavoidable — each has its own token). Writes one TSV
# row per account to stdout:
#   num <TAB> email <TAB> five <TAB> seven <TAB> handicap <TAB> adjusted <TAB> status
# status is either "ok" or "unavailable"; on "unavailable" the numeric
# columns are blank except handicap.
# Callers compose this with render_usage_table and/or pick_from_usage_data
# so --switch-lowest and --show-usage can share one fetch.
gather_all_usage() {
    [[ -f "$SEQUENCE_FILE" ]] || return

    local nums
    nums=$(jq -r '.accounts | keys | map(tonumber) | sort | .[]' "$SEQUENCE_FILE")

    while read -r num; do
        [[ -z "$num" ]] && continue
        local email
        email=$(jq -r --arg num "$num" '.accounts[$num].email // ""' "$SEQUENCE_FILE")
        [[ -z "$email" ]] && continue

        local handicap util_pair five seven five_reset seven_reset
        local five_rem seven_rem adjusted status now has_extra
        local cache_file cached
        handicap=$(get_account_handicap "$num")
        # hasExtraUsageEnabled lives in this account's backup config blob.
        # Missing field → treat as no extra usage. Used by the saturated
        # tier in pick_from_usage_data.
        has_extra=$(jq -r '.oauthAccount.hasExtraUsageEnabled // false' \
            "$BACKUP_DIR/configs/.claude-config-${num}-${email}.json" 2>/dev/null)
        [[ "$has_extra" == "true" ]] || has_extra=false

        # Fetch fresh; on any failure other than rate-limit, fall back to
        # the last cached values (regardless of TTL). Stale-but-actionable
        # numbers beat blanks; render marks them with "?" so the operator
        # knows it's an estimate. Reset times are stored as absolute epochs
        # so remaining-time still tracks correctly even from old cache.
        if util_pair=$(fetch_account_utilization "$num" "$email"); then
            status="ok"
        else
            local fetch_rc=$?
            if (( fetch_rc == 2 )); then
                return 2
            fi
            cache_file="$USAGE_CACHE_DIR/account-$num"
            if [[ -f "$cache_file" ]] && cached=$(cat "$cache_file" 2>/dev/null) && [[ -n "$cached" ]]; then
                util_pair="$cached"
                status="estimated"
                echo "  [Account-$num $email] falling back to cached estimate" >&2
            else
                status="unavailable"
            fi
        fi

        local extra_util=""
        if [[ "$status" == "ok" || "$status" == "estimated" ]]; then
            five=$(echo "$util_pair" | awk '{print $1}')
            seven=$(echo "$util_pair" | awk '{print $2}')
            five_reset=$(echo "$util_pair" | awk '{print $3}')
            seven_reset=$(echo "$util_pair" | awk '{print $4}')
            # Fields 5-6 may be absent in legacy 4-field caches written
            # before the extra_usage extraction landed; fall back gracefully.
            local extra_enabled_live
            extra_enabled_live=$(echo "$util_pair" | awk '{print $5}')
            extra_util=$(echo "$util_pair" | awk '{print $6}')
            if [[ "$extra_enabled_live" == "true" || "$extra_enabled_live" == "false" ]]; then
                # Live API value supersedes the snapshot from backup config
                # so plan changes show up immediately.
                has_extra="$extra_enabled_live"
            fi
            now=$(date +%s)
            # Cache rollover: when working from cached data and a stored
            # reset epoch is already in the past, the window has rolled
            # over since cache write. The cached utilization (typically
            # the 100% reading from when the cap was hit) is stale —
            # treat that window as 0% so the algorithm doesn't keep
            # avoiding a slot that already refreshed.
            if [[ "$status" == "estimated" ]]; then
                if (( five_reset > 0 && five_reset <= now )); then
                    five=0
                fi
                if (( seven_reset > 0 && seven_reset <= now )); then
                    seven=0
                fi
            fi
            # Remaining-time fields are still needed for the table's
            # "5h-rst"/"7d-rst" columns and for cold-tier qualification
            # in the picker.
            five_rem=$(( five_reset > now ? five_reset - now : 0 ))
            seven_rem=$(( seven_reset > now ? seven_reset - now : 0 ))
            # Adjusted utilization = max(5h, 7d) + handicap - urgency_bonus.
            #
            # raw component: whichever window is tighter is the binding
            # cap right now. handicap stacks on top per the existing
            # "leave headroom" semantic.
            #
            # urgency_bonus: when the *binding* window's reset is
            # imminent, the account's headroom is about to refresh
            # anyway, so we should prefer spending it now over saving
            # an account whose 7d cap won't refresh for days. Without
            # this, an account at 7d=65 with 8h to reset loses to an
            # account at 7d=48 with 4 days to reset — but the 65/8h one
            # is the better pick because right after reset it gives a
            # fresh 7d of full cap, contributing far more total usage
            # to the fleet than the 48/4d one will over the same horizon.
            #
            # Threshold = 48h. Outside that window urgency is 0. Inside,
            # each remaining hour costs 1 point of urgency bonus, capped
            # at 48 (i.e. reset-in-an-hour gets +47). The bonus stays
            # smaller than typical raw-max differences so a 7d=20 account
            # still beats a 7d=95 account even when 95's reset is hours
            # away — urgency tips the scale only between near-equal
            # candidates or when an account is about to refresh and
            # another is sitting on weeks of stale cap.
            local raw_max bind_rem
            if (( five > seven )); then
                raw_max=$five; bind_rem=$five_rem
            else
                raw_max=$seven; bind_rem=$seven_rem
            fi
            local urgency_bonus=0
            # Skip urgency for handicapped accounts. Handicap's whole
            # point is "leave headroom on this account" — urgency would
            # invert that intent by promoting a handicapped account
            # whose 5h is about to reset to the top of the picker.
            if (( handicap == 0 )) && [[ "$bind_rem" =~ ^[0-9]+$ ]] && (( bind_rem > 0 )); then
                local bind_hours=$(( bind_rem / 3600 ))
                if (( bind_hours < 48 )); then
                    urgency_bonus=$(( 48 - bind_hours ))
                fi
            fi
            adjusted=$(( raw_max + handicap - urgency_bonus ))
            (( adjusted < 0 )) && adjusted=0
        else
            five=""; seven=""; five_rem=""; seven_rem=""; adjusted=""
        fi

        # Use ASCII US (\x1f, Unit Separator) instead of tab as the TSV
        # delimiter. Bash `read -r` with IFS=$'\t' treats tab as whitespace
        # and collapses consecutive tabs, dropping empty fields. With a
        # non-whitespace separator, empty fields are preserved.
        printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
            "$num" "$email" "$five" "$seven" "$handicap" "$adjusted" "$status" \
            "$five_rem" "$seven_rem" "$has_extra" "$extra_util"
    done <<< "$nums"
}

# Format seconds-remaining as a compact human string.
# < 1h: "Nm"   < 1d: "NhMm"   else: "NdNh".  Empty input → "-".
format_remaining() {
    local sec="${1:-}"
    if [[ -z "$sec" || "$sec" == "0" ]]; then echo "-"; return; fi
    if (( sec < 0 )); then echo "0m"; return; fi
    local d=$(( sec / 86400 ))
    local h=$(( (sec % 86400) / 3600 ))
    local m=$(( (sec % 3600) / 60 ))
    if (( d > 0 )); then
        printf '%dd%dh' "$d" "$h"
    elif (( h > 0 )); then
        printf '%dh%dm' "$h" "$m"
    else
        printf '%dm' "$m"
    fi
}

# Render a usage table from gather_all_usage TSV on stdin.
# Args: current_account_num (used for the "*" active marker).
render_usage_table() {
    local current_account="${1:-}"
    printf '%-3s %-2s %-32s %5s %7s %5s %7s %9s %9s %4s\n' \
        "" "#" "Email" "5h%" "5h-rst" "7d%" "7d-rst" "Handicap" "Adjusted" "Ext"
    local num email five seven handicap adjusted status five_rem seven_rem has_extra extra_util prefix ext_disp
    while IFS=$'\x1f' read -r num email five seven handicap adjusted status five_rem seven_rem has_extra extra_util; do
        [[ -z "$num" ]] && continue
        if [[ "$num" == "$current_account" ]]; then prefix="*"; else prefix=" "; fi
        # Ext column: prefer the live extra_usage.utilization% from the
        # API. Fall back to "yes" (enabled but utilization unknown) when
        # cached/legacy. "-" when extra usage is not enabled.
        if [[ "$has_extra" == "true" ]]; then
            if [[ "$extra_util" =~ ^[0-9]+$ ]]; then
                ext_disp="${extra_util}%"
            else
                ext_disp="yes"
            fi
        else
            ext_disp="-"
        fi
        if [[ "$status" == "ok" ]]; then
            printf '%-3s %-2s %-32s %5s %7s %5s %7s %9s %9s %4s\n' \
                "$prefix" "$num" "$email" \
                "$five" "$(format_remaining "$five_rem")" \
                "$seven" "$(format_remaining "$seven_rem")" \
                "$handicap" "$adjusted" "$ext_disp"
        elif [[ "$status" == "estimated" ]]; then
            # "?" suffix marks values as cached estimates. Reset-time columns
            # interpolate naturally because cached reset epochs are absolute.
            printf '%-3s %-2s %-32s %5s %7s %5s %7s %9s %9s %4s\n' \
                "$prefix" "$num" "$email" \
                "${five}?" "$(format_remaining "$five_rem")" \
                "${seven}?" "$(format_remaining "$seven_rem")" \
                "$handicap" "${adjusted}?" "$ext_disp"
        else
            printf '%-3s %-2s %-32s %5s %7s %5s %7s %9s %9s %4s\n' \
                "$prefix" "$num" "$email" "-" "-" "-" "-" "$handicap" "N/A" "$ext_disp"
        fi
    done
}

# Pick account number from gather_all_usage TSV on stdin.
# Optional arg: current active num — used for round-robin tie-break in
# maxed-with-extra and to keep "Next target" stable when nothing better
# exists.
#
# Priority tiers (higher tier wins; tie-break = lowest adjusted, except
# stale tier which uses smaller num):
#   1) stale  (status=="unavailable") — refresh expired token.
#   2) cold   (5h=0 AND no 5h reset_at AND 7d != 100) — start the 5h
#      clock so the slot becomes a usable resource later.
#   3) healthy-clean (status=="ok" AND neither window at 100% AND
#      handicap==0) — normal pick.
#   4) maxed-with-extra (some window at 100% but hasExtraUsageEnabled
#      for that account) — overage usage is paid but works. Within this
#      tier the current active num is excluded first, so the picker
#      rotates between equally-eligible ext accounts on each run instead
#      of always re-picking the same lowest-extra_util one. Falls back
#      to including current only if it's the sole candidate.
#   5) healthy-handicap (status=="ok" AND neither window at 100% AND
#      handicap>0) — handicap means "leave headroom", so prefer paying
#      for overage on a maxed-with-extra account before dipping into
#      this slot. Only picked when no ext capacity is available.
#   6) maxed-no-extra (some window at 100% AND no extra usage) — last
#      resort before blocked-handicap.
#   7) blocked-handicap (handicap>0 AND adjusted>=100) — handicap
#      treats the account as if it were maxed regardless of available
#      extra capacity. Picked only if every other tier is empty so a
#      cron run never silently fails when the whole fleet is exhausted.
# Prints empty only if absolutely no rows.
pick_from_usage_data() {
    local current_num="${1:-}"
    local stale_num=""
    local cold_num="" cold_score="" cold_rem=""
    local healthy_clean_num="" healthy_clean_score="" healthy_clean_rem=""
    local healthy_hd_num="" healthy_hd_score="" healthy_hd_rem=""
    # maxed-extra has two collectors: "_alt" excludes the current active
    # num to enforce round-robin; the unsuffixed one keeps every ext
    # candidate so we can still fall back when current is the only one.
    local maxed_extra_num="" maxed_extra_eu="" maxed_extra_adj=""
    local maxed_extra_alt_num="" maxed_extra_alt_eu="" maxed_extra_alt_adj=""
    local maxed_noextra_num="" maxed_noextra_score="" maxed_noextra_rem=""
    local blocked_num="" blocked_score=""
    local num email five seven handicap adjusted status five_rem seven_rem has_extra extra_util
    while IFS=$'\x1f' read -r num email five seven handicap adjusted status five_rem seven_rem has_extra extra_util; do
        [[ -z "$num" ]] && continue
        if [[ "$status" == "unavailable" ]]; then
            if [[ -z "$stale_num" ]] || (( num < stale_num )); then
                stale_num="$num"
            fi
            continue
        fi
        # status=="ok" from here on.
        local has_handicap=0
        if [[ "$handicap" =~ ^[0-9]+$ ]] && (( handicap > 0 )); then
            has_handicap=1
        fi
        # Normalize seven_rem for tie-break math. seven_rem==0 means we
        # don't know when this account's 7d window resets (no
        # resets_at from the API). Treat unknown as "infinity remaining"
        # so it loses every closer-reset tie-break — otherwise a 0
        # would *win* the "smaller is better" comparison and incorrectly
        # promote unknown-reset accounts over known-imminent-reset ones.
        local seven_rem_norm="${seven_rem:-0}"
        [[ "$seven_rem_norm" =~ ^[0-9]+$ ]] || seven_rem_norm=0
        if [[ "$seven_rem_norm" == "0" ]]; then
            seven_rem_norm=999999999
        fi
        # Handicap override: any handicap>0 account whose raw-max +
        # handicap reaches 100% is treated as effectively blocked, even
        # if extra usage would normally rescue it. The user's intent for
        # handicap is "leave headroom" — honoring extra here would defeat
        # that. Route to blocked tier and skip all other classification so
        # one such account can't masquerade as healthy/cold elsewhere.
        # NOTE: must check raw+handicap, not the displayed `adjusted`,
        # because adjusted now subtracts an urgency_bonus when reset is
        # near — that would let an account at raw=80+handicap=30 (=110,
        # should be blocked) slip through with a 2h-to-reset bonus of
        # 46 lowering adjusted to 64.
        local raw_max_p
        if [[ "$five" =~ ^[0-9]+$ ]] && [[ "$seven" =~ ^[0-9]+$ ]]; then
            if (( five > seven )); then raw_max_p=$five; else raw_max_p=$seven; fi
        else
            raw_max_p=0
        fi
        local raw_with_handicap=$(( raw_max_p + handicap ))
        if (( has_handicap )) && (( raw_with_handicap >= 100 )); then
            if [[ -z "$blocked_num" ]] || (( raw_with_handicap < blocked_score )); then
                blocked_num="$num"
                blocked_score="$raw_with_handicap"
            fi
            continue
        fi
        # Cold-tier qualification: 5h=0 + no known 5h reset + 7d not maxed.
        # Cold ignores handicap because its purpose is starting the 5h
        # clock, which doesn't conflict with "use this account less".
        # Tie-break: smaller seven_rem wins (closer 7d reset = the
        # account's headroom is about to refresh anyway, so spend it
        # first rather than burning a slot with weeks of cap left).
        if [[ "$five" == "0" \
              && ( -z "$five_rem" || "$five_rem" == "0" ) \
              && "$seven" != "100" ]]; then
            if [[ -z "$cold_num" ]]; then
                cold_num="$num"; cold_score="$adjusted"; cold_rem="$seven_rem_norm"
            elif (( adjusted < cold_score )); then
                cold_num="$num"; cold_score="$adjusted"; cold_rem="$seven_rem_norm"
            elif (( adjusted == cold_score && seven_rem_norm < cold_rem )); then
                cold_num="$num"; cold_score="$adjusted"; cold_rem="$seven_rem_norm"
            fi
        fi
        # Saturation classification.
        # Healthy tie-break: same seven_rem rule as cold — when two
        # accounts have identical adjusted (common when the API hands
        # back integer percentages), prefer the one whose 7d window is
        # closer to resetting. Otherwise the picker would lock onto the
        # lowest num forever and waste imminent-reset headroom.
        if [[ "$five" != "100" && "$seven" != "100" ]]; then
            if (( has_handicap )); then
                if [[ -z "$healthy_hd_num" ]]; then
                    healthy_hd_num="$num"; healthy_hd_score="$adjusted"; healthy_hd_rem="$seven_rem_norm"
                elif (( adjusted < healthy_hd_score )); then
                    healthy_hd_num="$num"; healthy_hd_score="$adjusted"; healthy_hd_rem="$seven_rem_norm"
                elif (( adjusted == healthy_hd_score && seven_rem_norm < healthy_hd_rem )); then
                    healthy_hd_num="$num"; healthy_hd_score="$adjusted"; healthy_hd_rem="$seven_rem_norm"
                fi
            else
                if [[ -z "$healthy_clean_num" ]]; then
                    healthy_clean_num="$num"; healthy_clean_score="$adjusted"; healthy_clean_rem="$seven_rem_norm"
                elif (( adjusted < healthy_clean_score )); then
                    healthy_clean_num="$num"; healthy_clean_score="$adjusted"; healthy_clean_rem="$seven_rem_norm"
                elif (( adjusted == healthy_clean_score && seven_rem_norm < healthy_clean_rem )); then
                    healthy_clean_num="$num"; healthy_clean_score="$adjusted"; healthy_clean_rem="$seven_rem_norm"
                fi
            fi
        elif [[ "$has_extra" == "true" ]]; then
            # maxed-with-extra. Treat all candidates as equal-priority
            # (every pick costs paid overage), but prefer "not current" so
            # consecutive runs alternate between them. Tie-break inside
            # each collector: lowest extra_util%, then lowest adjusted.
            # extra_util missing → assume 100 so unknown-ext doesn't beat
            # an account with a known low ext%.
            local eu
            if [[ "$extra_util" =~ ^[0-9]+$ ]]; then eu="$extra_util"; else eu=100; fi
            if [[ -z "$maxed_extra_num" ]]; then
                maxed_extra_num="$num"; maxed_extra_eu="$eu"; maxed_extra_adj="$adjusted"
            elif (( eu < maxed_extra_eu )); then
                maxed_extra_num="$num"; maxed_extra_eu="$eu"; maxed_extra_adj="$adjusted"
            elif (( eu == maxed_extra_eu && adjusted < maxed_extra_adj )); then
                maxed_extra_num="$num"; maxed_extra_eu="$eu"; maxed_extra_adj="$adjusted"
            fi
            if [[ -n "$current_num" && "$num" != "$current_num" ]]; then
                if [[ -z "$maxed_extra_alt_num" ]]; then
                    maxed_extra_alt_num="$num"; maxed_extra_alt_eu="$eu"; maxed_extra_alt_adj="$adjusted"
                elif (( eu < maxed_extra_alt_eu )); then
                    maxed_extra_alt_num="$num"; maxed_extra_alt_eu="$eu"; maxed_extra_alt_adj="$adjusted"
                elif (( eu == maxed_extra_alt_eu && adjusted < maxed_extra_alt_adj )); then
                    maxed_extra_alt_num="$num"; maxed_extra_alt_eu="$eu"; maxed_extra_alt_adj="$adjusted"
                fi
            fi
        else
            if [[ -z "$maxed_noextra_num" ]]; then
                maxed_noextra_num="$num"; maxed_noextra_score="$adjusted"; maxed_noextra_rem="$seven_rem_norm"
            elif (( adjusted < maxed_noextra_score )); then
                maxed_noextra_num="$num"; maxed_noextra_score="$adjusted"; maxed_noextra_rem="$seven_rem_norm"
            elif (( adjusted == maxed_noextra_score && seven_rem_norm < maxed_noextra_rem )); then
                maxed_noextra_num="$num"; maxed_noextra_score="$adjusted"; maxed_noextra_rem="$seven_rem_norm"
            fi
        fi
    done
    if [[ -n "$stale_num" ]]; then
        echo "$stale_num"
    elif [[ -n "$cold_num" ]]; then
        echo "$cold_num"
    elif [[ -n "$healthy_clean_num" ]]; then
        echo "$healthy_clean_num"
    elif [[ -n "$maxed_extra_alt_num" ]]; then
        echo "$maxed_extra_alt_num"
    elif [[ -n "$maxed_extra_num" ]]; then
        echo "$maxed_extra_num"
    elif [[ -n "$healthy_hd_num" ]]; then
        echo "$healthy_hd_num"
    elif [[ -n "$maxed_noextra_num" ]]; then
        echo "$maxed_noextra_num"
    else
        echo "$blocked_num"
    fi
}

# Check if account exists. Matches by (email, organizationUuid) when the uuid
# is provided, falling back to email-only for callers that have no uuid.
account_exists() {
    local email="$1"
    local org_uuid="${2:-}"

    [[ -f "$SEQUENCE_FILE" ]] || return 1

    if [[ -n "$org_uuid" ]]; then
        jq -e --arg email "$email" --arg ou "$org_uuid" '
            .accounts[] | select(.email == $email and (.organizationUuid // "") == $ou)
        ' "$SEQUENCE_FILE" >/dev/null 2>&1
    else
        jq -e --arg email "$email" '.accounts[] | select(.email == $email)' "$SEQUENCE_FILE" >/dev/null 2>&1
    fi
}

# Add account
cmd_add_account() {
    setup_directories
    init_sequence_file

    local current_email current_account_uuid current_org_uuid current_org_name
    IFS=$'\t' read -r current_email current_account_uuid current_org_uuid current_org_name < <(get_current_account_full)

    if [[ -z "$current_email" ]]; then
        echo "Error: No active Claude account found. Please log in first."
        exit 1
    fi

    if account_exists "$current_email" "$current_org_uuid"; then
        local label
        label=$(format_org_label "$current_org_name" "$current_org_uuid" "$current_email")
        echo "Account $current_email ($label) is already managed."
        exit 0
    fi

    local account_num
    account_num=$(get_next_account_number)

    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")

    if [[ -z "$current_creds" ]]; then
        echo "Error: No credentials found for current account"
        exit 1
    fi

    write_account_credentials "$account_num" "$current_email" "$current_creds"
    write_account_config "$account_num" "$current_email" "$current_config"

    local updated_sequence
    updated_sequence=$(jq \
        --arg num "$account_num" \
        --arg email "$current_email" \
        --arg uuid "$current_account_uuid" \
        --arg ou "$current_org_uuid" \
        --arg on "$current_org_name" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num] = {
            email: $email,
            uuid: $uuid,
            organizationUuid: $ou,
            organizationName: $on,
            added: $now
        } |
        .sequence += [$num | tonumber] |
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"

    local label
    label=$(format_org_label "$current_org_name" "$current_org_uuid" "$current_email")
    echo "Added Account $account_num: $current_email ($label)"
}

# Remove account
cmd_remove_account() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --remove-account <account_number>"
        exit 1
    fi

    local identifier="$1"
    local account_num

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    # Accept account number only. Email is intentionally rejected to avoid
    # ambiguity when the same email exists in multiple organizations.
    if ! [[ "$identifier" =~ ^[0-9]+$ ]]; then
        echo "Error: --remove-account accepts account number only (see --list for numbers)." >&2
        exit 1
    fi
    account_num="$identifier"

    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")

    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$account_num does not exist"
        exit 1
    fi

    local email
    email=$(echo "$account_info" | jq -r '.email')
    
    local active_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    
    if [[ "$active_account" == "$account_num" ]]; then
        echo "Warning: Account-$account_num ($email) is currently active"
    fi
    
    echo -n "Are you sure you want to permanently remove Account-$account_num ($email)? [y/N] "
    read -r confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Cancelled"
        exit 0
    fi
    
    # Remove backup files
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            security delete-generic-password -s "Claude Code-Account-${account_num}-${email}" 2>/dev/null || true
            ;;
        linux|wsl)
            rm -f "$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            ;;
    esac
    rm -f "$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    # Update sequence.json
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        del(.accounts[$num]) |
        .sequence = (.sequence | map(select(. != ($num | tonumber)))) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    
    write_json "$SEQUENCE_FILE" "$updated_sequence"
    
    echo "Account-$account_num ($email) has been removed"
}

# First-run setup workflow
first_run_setup() {
    local current_email
    current_email=$(get_current_account)
    
    if [[ "$current_email" == "none" ]]; then
        echo "No active Claude account found. Please log in first."
        return 1
    fi
    
    echo -n "No managed accounts found. Add current account ($current_email) to managed list? [Y/n] "
    read -r response
    
    if [[ "$response" == "n" || "$response" == "N" ]]; then
        echo "Setup cancelled. You can run '$0 --add-account' later."
        return 1
    fi
    
    cmd_add_account
    return 0
}

# List accounts
cmd_list() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "No accounts are managed yet."
        first_run_setup
        exit 0
    fi

    # Lazy-migrate all accounts to fill in org info from their backup configs.
    local all_nums
    all_nums=$(jq -r '.accounts | keys[]' "$SEQUENCE_FILE")
    while read -r n; do
        [[ -n "$n" ]] && ensure_org_info "$n"
    done <<< "$all_nums"

    local current_email current_account_uuid current_org_uuid
    IFS=$'\t' read -r current_email current_account_uuid current_org_uuid _ < <(get_current_account_full)

    # Match on (accountUuid, organizationUuid): Anthropic reuses the same
    # accountUuid across orgs for the same user, so uuid alone is not unique.
    local active_account_num=""
    if [[ -n "$current_account_uuid" && -n "$current_org_uuid" ]]; then
        active_account_num=$(jq -r --arg uuid "$current_account_uuid" --arg ou "$current_org_uuid" \
            '.accounts | to_entries[] | select(.value.uuid == $uuid and (.value.organizationUuid // "") == $ou) | .key' \
            "$SEQUENCE_FILE" 2>/dev/null | head -n1)
    fi
    if [[ -z "$active_account_num" && -n "$current_org_uuid" ]]; then
        active_account_num=$(jq -r --arg ou "$current_org_uuid" \
            '.accounts | to_entries[] | select((.value.organizationUuid // "") == $ou) | .key' \
            "$SEQUENCE_FILE" 2>/dev/null | head -n1)
    fi
    if [[ -z "$active_account_num" && -n "$current_email" ]]; then
        active_account_num=$(jq -r --arg email "$current_email" \
            '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null | head -n1)
    fi

    # Header: clearly state the current active session up-front.
    if [[ -n "$active_account_num" ]]; then
        local a_entry a_email a_org_uuid a_org_name a_label
        a_entry=$(jq -r --arg num "$active_account_num" '.accounts[$num]' "$SEQUENCE_FILE")
        a_email=$(echo "$a_entry" | jq -r '.email // ""')
        a_org_uuid=$(echo "$a_entry" | jq -r '.organizationUuid // ""')
        a_org_name=$(echo "$a_entry" | jq -r '.organizationName // ""')
        a_label=$(format_org_label "$a_org_name" "$a_org_uuid" "$a_email")
        echo "Current: Account-$active_account_num  $a_email ($a_label)"
    elif [[ -n "$current_email" ]]; then
        echo "Current: (unmanaged live session)  $current_email  org=${current_org_uuid:-?}"
    else
        echo "Current: (no active session)"
    fi
    echo ""

    echo "Accounts:"
    local seq_nums
    seq_nums=$(jq -r '.sequence[]' "$SEQUENCE_FILE")
    while read -r num; do
        [[ -z "$num" ]] && continue
        local entry email org_uuid org_name label prefix handicap suffix
        entry=$(jq -r --arg num "$num" '.accounts[$num]' "$SEQUENCE_FILE")
        email=$(echo "$entry" | jq -r '.email // ""')
        org_uuid=$(echo "$entry" | jq -r '.organizationUuid // ""')
        org_name=$(echo "$entry" | jq -r '.organizationName // ""')
        label=$(format_org_label "$org_name" "$org_uuid" "$email")

        if [[ "$num" == "$active_account_num" ]]; then
            prefix="* "
        else
            prefix="  "
        fi

        handicap=$(echo "$entry" | jq -r '.handicap // 0')
        if [[ "$handicap" =~ ^[0-9]+$ ]] && (( handicap > 0 )); then
            suffix=" [handicap: ${handicap}%]"
        else
            suffix=""
        fi

        echo "${prefix}${num}: $email ($label)${suffix}"
    done <<< "$seq_nums"
}

# Switch to next account
cmd_switch() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local current_email current_account_uuid current_org_uuid
    IFS=$'\t' read -r current_email current_account_uuid current_org_uuid _ < <(get_current_account_full)

    if [[ -z "$current_email" ]]; then
        echo "Error: No active Claude account found"
        exit 1
    fi

    # Match on (accountUuid, organizationUuid): Anthropic reuses the same
    # accountUuid across orgs for the same user.
    local active_account=""
    if [[ -n "$current_account_uuid" && -n "$current_org_uuid" ]]; then
        active_account=$(jq -r --arg uuid "$current_account_uuid" --arg ou "$current_org_uuid" \
            '.accounts | to_entries[] | select(.value.uuid == $uuid and (.value.organizationUuid // "") == $ou) | .key' \
            "$SEQUENCE_FILE" 2>/dev/null | head -n1)
    fi
    if [[ -z "$active_account" && -n "$current_org_uuid" ]]; then
        active_account=$(jq -r --arg ou "$current_org_uuid" \
            '.accounts | to_entries[] | select((.value.organizationUuid // "") == $ou) | .key' \
            "$SEQUENCE_FILE" 2>/dev/null | head -n1)
    fi

    if [[ -z "$active_account" ]]; then
        echo "Notice: Active account '$current_email' was not managed."
        cmd_add_account
        local account_num
        account_num=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
        echo "It has been automatically added as Account-$account_num."
        echo "Please run './ccswitch.sh --switch' again to switch to the next account."
        exit 0
    fi

    # Keep activeAccountNumber in sequence.json consistent with reality.
    local stored_active
    stored_active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    if [[ "$stored_active" != "$active_account" ]]; then
        local fixed
        fixed=$(jq --arg num "$active_account" '.activeAccountNumber = ($num | tonumber)' "$SEQUENCE_FILE")
        write_json "$SEQUENCE_FILE" "$fixed"
    fi

    # wait_for_claude_close

    local sequence
    sequence=($(jq -r '.sequence[]' "$SEQUENCE_FILE"))
    
    # Find next account in sequence
    local next_account current_index=0
    for i in "${!sequence[@]}"; do
        if [[ "${sequence[i]}" == "$active_account" ]]; then
            current_index=$i
            break
        fi
    done
    
    next_account="${sequence[$(((current_index + 1) % ${#sequence[@]}))]}"
    
    perform_switch "$next_account"
}

# Switch to specific account
cmd_switch_to() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --switch-to <account_number|email>"
        exit 1
    fi
    
    local identifier="$1"
    local target_account
    
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    
    target_account=$(resolve_account_identifier "$identifier")
    if [[ -z "$target_account" ]]; then
        # Ambiguous case already reported to stderr by resolver.
        if [[ "$identifier" =~ ^[0-9]+$ ]]; then
            echo "Error: Account-$identifier does not exist"
        else
            echo "Error: No account found matching: $identifier" >&2
        fi
        exit 1
    fi

    local account_info
    account_info=$(jq -r --arg num "$target_account" '.accounts[$num] // empty' "$SEQUENCE_FILE")

    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$target_account does not exist"
        exit 1
    fi

    # wait_for_claude_close
    perform_switch "$target_account"
}

# Resolve currently-active account number via (uuid, organizationUuid)
# match, falling back to organizationUuid-only. Empty when unknown.
identify_current_account() {
    local current_email current_account_uuid current_org_uuid
    IFS=$'\t' read -r current_email current_account_uuid current_org_uuid _ < <(get_current_account_full)

    local current_account=""
    if [[ -n "$current_account_uuid" && -n "$current_org_uuid" ]]; then
        current_account=$(jq -r --arg uuid "$current_account_uuid" --arg ou "$current_org_uuid" \
            '.accounts | to_entries[] | select(.value.uuid == $uuid and (.value.organizationUuid // "") == $ou) | .key' \
            "$SEQUENCE_FILE" 2>/dev/null | head -n1)
    fi
    if [[ -z "$current_account" && -n "$current_org_uuid" ]]; then
        current_account=$(jq -r --arg ou "$current_org_uuid" \
            '.accounts | to_entries[] | select((.value.organizationUuid // "") == $ou) | .key' \
            "$SEQUENCE_FILE" 2>/dev/null | head -n1)
    fi
    echo "$current_account"
}

# Switch to the account with the lowest adjusted utilization.
# Prints the same table --show-usage would, then the decision, using ONE
# sweep of API calls. No-op if already on lowest, or no usable reading.
cmd_switch_lowest() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    # Refresh the current account's backup from the live keychain so a
    # token rotated by a recent interactive /login propagates before we
    # call the usage API. Subshell isolates cmd_sync_current's "exit 1"
    # and silences its normal chatter — any failure is non-fatal here.
    ( cmd_sync_current ) >/dev/null 2>&1 || true

    local current_account data target
    current_account=$(identify_current_account)
    data=$(gather_all_usage)
    local gather_rc=$?

    # If any account triggered HTTP 429, gather_all_usage bailed out early.
    # Don't switch — fresh data isn't available and continuing would just
    # add to the throttle. Diagnostic line was already printed by the
    # underlying fetch helper to stderr.
    if (( gather_rc == 2 )); then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Aborted: rate-limited by Anthropic API; not switching."
        return 0
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Usage snapshot:"
    echo "$data" | render_usage_table "$current_account"

    target=$(echo "$data" | pick_from_usage_data "$current_account")

    if [[ -z "$target" ]]; then
        echo "Decision: no eligible account (all usage lookups failed); skipping switch."
        return 0
    fi

    if [[ "$target" == "$current_account" ]]; then
        echo "Decision: already on lowest-usage account (Account-$current_account); skipping."
        return 0
    fi

    # Hysteresis: if the candidate's adjusted utilization isn't
    # meaningfully lower than the current account's, stay put. Picker
    # already prefers tier-aware ordering (stale > cold > healthy > ext
    # > etc.), so we only apply this guard when current+target are
    # both within the "healthy_clean / healthy_handicap / maxed_noextra"
    # bands where switching = killing the active session for marginal
    # gain. Stale / cold / blocked-handicap decisions still go through
    # immediately — those signal an account issue, not a tie.
    local current_adj target_adj current_status
    current_adj=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$current_account" '$1==n{print $6}')
    target_adj=$(echo "$data"  | /usr/bin/awk -F$'\x1f' -v n="$target"          '$1==n{print $6}')
    current_status=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$current_account" '$1==n{print $7}')
    local target_status_pre
    target_status_pre=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$target" '$1==n{print $7}')
    if [[ "$current_status" == "ok" && "$target_status_pre" == "ok" \
          && "$current_adj" =~ ^[0-9]+$ && "$target_adj" =~ ^[0-9]+$ ]]; then
        local delta=$((current_adj - target_adj))
        if (( delta < HYSTERESIS_DELTA )); then
            echo "Decision: target Account-$target only ${delta}%p below current Account-$current_account (threshold ${HYSTERESIS_DELTA}%p); staying to avoid session churn."
            return 0
        fi
    fi

    # Tier-aware decision message.
    local target_status target_five target_seven target_five_rem target_extra
    target_status=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$target" '$1==n{print $7}')
    target_five=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$target" '$1==n{print $3}')
    target_seven=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$target" '$1==n{print $4}')
    target_five_rem=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$target" '$1==n{print $8}')
    target_extra=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$target" '$1==n{print $10}')
    if [[ "$target_status" == "unavailable" ]]; then
        echo "Decision: rotating to stale Account-$target (idle ≥1h, token expired — switching so Claude Code refreshes it)."
    elif [[ "$target_five" == "0" \
            && ( -z "$target_five_rem" || "$target_five_rem" == "0" ) \
            && "$target_seven" != "100" ]]; then
        echo "Decision: warming up cold Account-$target (5h window untouched — touching now starts the clock for a future reset)."
    elif [[ "$target_five" == "100" || "$target_seven" == "100" ]]; then
        if [[ "$target_extra" == "true" ]]; then
            echo "Decision: switching to Account-$target (all candidates saturated; this one has extra-usage available)."
        else
            echo "Decision: switching to Account-$target (last-resort: every account is saturated and none have extra usage)."
        fi
    else
        echo "Decision: switching to Account-$target (lower than current Account-${current_account:-?})."
    fi
    perform_switch "$target"
}

# Set a per-account handicap (percentage points added to that account's
# utilization before the lowest-usage comparison). Higher handicap means
# the account is picked less often.
cmd_set_handicap() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 --set-handicap <account_number> <percent>"
        exit 1
    fi

    local account_num="$1"
    local percent="$2"

    if ! [[ "$account_num" =~ ^[0-9]+$ ]]; then
        echo "Error: account number must be a positive integer"
        exit 1
    fi
    if ! [[ "$percent" =~ ^[0-9]+$ ]] || (( percent < 0 || percent > 100 )); then
        echo "Error: percent must be an integer in [0, 100]"
        exit 1
    fi

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local email
    email=$(jq -r --arg num "$account_num" '.accounts[$num].email // ""' "$SEQUENCE_FILE")
    if [[ -z "$email" ]]; then
        echo "Error: Account-$account_num does not exist"
        exit 1
    fi

    local updated
    updated=$(jq --arg num "$account_num" --argjson pct "$percent" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num].handicap = $pct |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated"
    echo "Set handicap for Account-$account_num ($email): ${percent}%"
}

# Print a per-account usage table using gather_all_usage + render.
cmd_show_usage() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    # Refresh active account's backup in case the user just /login'd. Same
    # silent pattern as cmd_switch_lowest — failure is non-fatal.
    ( cmd_sync_current ) >/dev/null 2>&1 || true

    # Cache reads are enabled here (10s TTL) so repeated manual
    # `--show-usage` invocations don't burn API quota. --switch-lowest
    # never sets this var so its decisions still use live data.
    local data
    data=$(CCSWITCH_USE_CACHE=1 gather_all_usage)
    local gather_rc=$?
    if (( gather_rc == 2 )); then
        echo "Aborted: rate-limited by Anthropic API; try again in a moment." >&2
        return 1
    fi
    local current target target_status
    current=$(identify_current_account)
    echo "$data" | render_usage_table "$current"

    # Preview: which account would --switch-lowest pick right now?
    target=$(echo "$data" | pick_from_usage_data "$current")
    if [[ -z "$target" ]]; then
        echo "Next target: (no eligible account)"
    elif [[ "$target" == "$current" ]]; then
        echo "Next target: Account-$target (already active — would skip)"
    else
        local target_five target_seven target_five_rem target_extra
        target_status=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$target" '$1==n{print $7}')
        target_five=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$target" '$1==n{print $3}')
        target_seven=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$target" '$1==n{print $4}')
        target_five_rem=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$target" '$1==n{print $8}')
        target_extra=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$target" '$1==n{print $10}')
        # Hysteresis preview: mirror the guard in cmd_switch_lowest so
        # the operator sees "would stay" instead of a misleading
        # "Next target" when the real cron tick will no-op.
        local current_adj_p target_adj_p current_status_p
        current_adj_p=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$current" '$1==n{print $6}')
        target_adj_p="$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$target" '$1==n{print $6}')"
        current_status_p=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$current" '$1==n{print $7}')
        if [[ "$current_status_p" == "ok" && "$target_status" == "ok" \
              && "$current_adj_p" =~ ^[0-9]+$ && "$target_adj_p" =~ ^[0-9]+$ ]]; then
            local delta_p=$((current_adj_p - target_adj_p))
            if (( delta_p < HYSTERESIS_DELTA )); then
                echo "Next target: Account-$current (staying — Account-$target only ${delta_p}%p lower, below ${HYSTERESIS_DELTA}%p threshold)"
                return 0
            fi
        fi
        if [[ "$target_status" == "unavailable" ]]; then
            echo "Next target: Account-$target (stale-token refresh)"
        elif [[ "$target_five" == "0" \
                && ( -z "$target_five_rem" || "$target_five_rem" == "0" ) \
                && "$target_seven" != "100" ]]; then
            echo "Next target: Account-$target (cold-warmup — 5h window untouched)"
        elif [[ "$target_five" == "100" || "$target_seven" == "100" ]]; then
            if [[ "$target_extra" == "true" ]]; then
                echo "Next target: Account-$target (saturated but has extra-usage)"
            else
                echo "Next target: Account-$target (last-resort: all saturated, no extra-usage)"
            fi
        else
            echo "Next target: Account-$target (lowest adjusted)"
        fi
    fi
}

# Perform the actual account switch
perform_switch() {
    local target_account="$1"

    local target_email
    target_email=$(jq -r --arg num "$target_account" '.accounts[$num].email' "$SEQUENCE_FILE")

    local current_email current_account_uuid current_org_uuid current_org_name
    IFS=$'\t' read -r current_email current_account_uuid current_org_uuid current_org_name < <(get_current_account_full)

    # Match on (accountUuid, organizationUuid) so the backup lands in the right slot
    # when the same email is registered under multiple orgs.
    local current_account=""
    if [[ -n "$current_account_uuid" && -n "$current_org_uuid" ]]; then
        current_account=$(jq -r --arg uuid "$current_account_uuid" --arg ou "$current_org_uuid" \
            '.accounts | to_entries[] | select(.value.uuid == $uuid and (.value.organizationUuid // "") == $ou) | .key' \
            "$SEQUENCE_FILE" 2>/dev/null | head -n1)
    fi
    if [[ -z "$current_account" && -n "$current_org_uuid" ]]; then
        current_account=$(jq -r --arg ou "$current_org_uuid" \
            '.accounts | to_entries[] | select((.value.organizationUuid // "") == $ou) | .key' \
            "$SEQUENCE_FILE" 2>/dev/null | head -n1)
    fi
    if [[ -z "$current_account" ]]; then
        current_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    fi

    # Step 1: Backup current account
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")

    write_account_credentials "$current_account" "$current_email" "$current_creds"
    write_account_config "$current_account" "$current_email" "$current_config"
    
    # Step 2: Retrieve target account
    local target_creds target_config
    target_creds=$(read_account_credentials "$target_account" "$target_email")
    target_config=$(read_account_config "$target_account" "$target_email")
    
    if [[ -z "$target_creds" || -z "$target_config" ]]; then
        echo "Error: Missing backup data for Account-$target_account"
        exit 1
    fi
    
    # Step 3: Activate target account
    write_credentials "$target_creds"
    
    # Extract oauthAccount from backup and validate
    local oauth_section
    oauth_section=$(echo "$target_config" | jq '.oauthAccount' 2>/dev/null)
    if [[ -z "$oauth_section" || "$oauth_section" == "null" ]]; then
        echo "Error: Invalid oauthAccount in backup"
        exit 1
    fi
    
    # Merge with current config and validate
    local merged_config
    merged_config=$(jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' "$(get_claude_config_path)" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to merge config"
        exit 1
    fi
    
    # Use existing safe write_json function
    write_json "$(get_claude_config_path)" "$merged_config"
    
    # Step 4: Update state
    local updated_sequence
    updated_sequence=$(jq --arg num "$target_account" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    
    write_json "$SEQUENCE_FILE" "$updated_sequence"

    local target_org_uuid target_org_name target_label
    target_org_uuid=$(jq -r --arg num "$target_account" '.accounts[$num].organizationUuid // ""' "$SEQUENCE_FILE")
    target_org_name=$(jq -r --arg num "$target_account" '.accounts[$num].organizationName // ""' "$SEQUENCE_FILE")
    target_label=$(format_org_label "$target_org_name" "$target_org_uuid" "$target_email")

    local from_label
    from_label=$(format_org_label "$current_org_name" "$current_org_uuid" "$current_email")
    notify_switch_macos "${current_email} (${from_label})" "${target_email} (${target_label})"

    echo "Switched to Account-$target_account ($target_email - $target_label)"
    # Display updated account list
    cmd_list
    echo ""
    echo "Please restart Claude Code to use the new authentication."
    echo ""

}

# Refresh the backup slot for the currently-active account from the live state.
# Useful after /login or silent token refresh while staying on the same account.
# Only touches the single slot matched by (accountUuid, organizationUuid);
# other accounts' backups are untouched.
cmd_sync_current() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local current_email current_account_uuid current_org_uuid current_org_name
    IFS=$'\t' read -r current_email current_account_uuid current_org_uuid current_org_name < <(get_current_account_full)

    if [[ -z "$current_email" || -z "$current_account_uuid" || -z "$current_org_uuid" ]]; then
        echo "Error: Cannot read a valid live session from $(get_claude_config_path)"
        exit 1
    fi

    local current_account
    current_account=$(jq -r --arg uuid "$current_account_uuid" --arg ou "$current_org_uuid" \
        '.accounts | to_entries[] | select(.value.uuid == $uuid and (.value.organizationUuid // "") == $ou) | .key' \
        "$SEQUENCE_FILE" 2>/dev/null | head -n1)

    if [[ -z "$current_account" ]]; then
        echo "Error: Current live session is not managed."
        echo "       email=$current_email organizationUuid=$current_org_uuid"
        echo "       Run '$0 --add-account' to register it first."
        exit 1
    fi

    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")

    if [[ -z "$current_creds" ]]; then
        echo "Error: No live credentials found to sync"
        exit 1
    fi

    if ! echo "$current_creds" | jq . >/dev/null 2>&1; then
        echo "Error: Live credentials are not valid JSON; refusing to overwrite backup"
        exit 1
    fi

    write_account_credentials "$current_account" "$current_email" "$current_creds"
    write_account_config "$current_account" "$current_email" "$current_config"

    local label
    label=$(format_org_label "$current_org_name" "$current_org_uuid" "$current_email")
    echo "Synced Account-$current_account backup: $current_email ($label)"
}

# Resolve this script's absolute path so cron entries don't depend on $PATH/cwd.
cron_script_path() {
    local raw="${BASH_SOURCE[0]}"
    if [[ "$raw" != /* ]]; then
        raw="$(cd "$(dirname "$raw")" 2>/dev/null && pwd)/$(basename "$raw")"
    fi
    echo "$raw"
}

# Pick an absolute bash binary meeting the 4.4+ requirement. Cron's default
# PATH does not include Homebrew, so we must hard-code the full path in
# the cron entry. `which bash` in the installing shell is preferred, then
# common homebrew locations, then /bin/bash (likely 3.2 and rejected).
resolve_modern_bash() {
    local candidates=() b ver
    local which_bash
    which_bash=$(command -v bash 2>/dev/null || true)
    [[ -n "$which_bash" ]] && candidates+=("$which_bash")
    candidates+=("/opt/homebrew/bin/bash" "/usr/local/bin/bash" "/bin/bash")

    for b in "${candidates[@]}"; do
        [[ -x "$b" ]] || continue
        ver=$("$b" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null || true)
        if awk -v v="$ver" 'BEGIN { exit (v >= 4.4 ? 0 : 1) }' 2>/dev/null; then
            echo "$b"
            return 0
        fi
    done
    return 1
}

cron_entry_line() {
    local path bash_path
    path=$(cron_script_path)
    if ! bash_path=$(resolve_modern_bash); then
        bash_path="bash"
    fi
    echo "$CRON_SCHEDULE $bash_path $path $CRON_COMMAND >> $CRON_LOG 2>&1 $CRON_MARKER"
}

# Read current user's crontab; tolerate "no crontab" exit status under set -e.
cron_list_current() {
    crontab -l 2>/dev/null || true
}

cmd_cron_install() {
    local new_entry existing current_entry
    new_entry=$(cron_entry_line)
    existing=$(cron_list_current)
    current_entry=$(printf '%s\n' "$existing" | grep -F "$CRON_MARKER" || true)

    if [[ -n "$current_entry" ]]; then
        if [[ "$current_entry" == "$new_entry" ]]; then
            echo "Cron entry already installed:"
            echo "  $current_entry"
            exit 0
        fi
        # Replace old ccswitch entry with the current expected one.
        local filtered
        filtered=$(printf '%s\n' "$existing" | grep -Fv "$CRON_MARKER" || true)
        if [[ -n "$filtered" ]]; then
            printf '%s\n%s\n' "$filtered" "$new_entry" | crontab -
        else
            printf '%s\n' "$new_entry" | crontab -
        fi
        echo "Updated cron entry:"
        echo "  was: $current_entry"
        echo "  now: $new_entry"
        exit 0
    fi

    if [[ -n "$existing" ]]; then
        printf '%s\n%s\n' "$existing" "$new_entry" | crontab -
    else
        printf '%s\n' "$new_entry" | crontab -
    fi

    echo "Installed auto-switch:"
    echo "  $new_entry"
    echo ""
    echo "Note: on macOS cron accesses the login keychain only while that"
    echo "      keychain is unlocked (typical during an active user session)."
}

cmd_cron_status() {
    local line
    line=$(cron_list_current | grep -F "$CRON_MARKER" || true)
    if [[ -z "$line" ]]; then
        echo "Not installed."
        exit 1
    fi
    echo "Installed:"
    echo "  $line"
}

# Tail the cron log. Useful when auto-switch does not seem to be happening.
cmd_cron_log() {
    if [[ ! -f "$CRON_LOG" ]]; then
        echo "No cron log yet at $CRON_LOG (cron has not produced any output)."
        return 0
    fi
    local lines="${1:-50}"
    if ! [[ "$lines" =~ ^[0-9]+$ ]]; then
        lines=50
    fi
    echo "=== $CRON_LOG (last $lines lines) ==="
    tail -n "$lines" "$CRON_LOG"
}

# --- LaunchAgent (macOS) ----------------------------------------------------

# macOS "Background Activity" displays ProgramArguments[0]'s basename as
# the job name. Handing launchd a bash path would show "bash", so we
# install a thin wrapper next to ccswitch.sh with a meaningful filename
# and point the plist at it.
agent_wrapper_path() {
    local script_dir
    script_dir=$(dirname "$(cron_script_path)")
    echo "$script_dir/agent-switch-lowest"
}

write_agent_wrapper() {
    local wrapper bash_path script_path
    wrapper=$(agent_wrapper_path)
    bash_path=$(resolve_modern_bash) || bash_path="/bin/bash"
    script_path=$(cron_script_path)

    cat > "$wrapper" <<EOF
#!${bash_path}
# Auto-generated wrapper so macOS Background Activity shows
# "agent-switch-lowest" instead of "bash". Re-run
# '$(basename "$script_path") --agent-install' to regenerate.
exec "${bash_path}" "${script_path}" --switch-lowest
EOF
    chmod +x "$wrapper"
}

# Build the plist XML for the LaunchAgent. All paths are resolved fresh
# each time so re-installs upgrade schedule/paths correctly.
agent_plist_body() {
    local wrapper
    wrapper=$(agent_wrapper_path)
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${wrapper}</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Minute</key><integer>0</integer></dict>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${CRON_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${CRON_LOG}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
EOF
}

agent_domain_target() {
    echo "gui/$(id -u)"
}

agent_service_target() {
    echo "$(agent_domain_target)/${AGENT_LABEL}"
}

cmd_agent_install() {
    if [[ "$(detect_platform)" != "macos" ]]; then
        echo "Error: --agent-install is macOS-only. Use --cron-install on Linux."
        exit 1
    fi

    mkdir -p "$(dirname "$AGENT_PLIST")"

    # If already loaded, bootout first so we re-register with the new plist.
    if launchctl print "$(agent_service_target)" >/dev/null 2>&1; then
        launchctl bootout "$(agent_service_target)" 2>/dev/null || true
    fi

    write_agent_wrapper
    agent_plist_body > "$AGENT_PLIST"
    chmod 644 "$AGENT_PLIST"

    if ! launchctl bootstrap "$(agent_domain_target)" "$AGENT_PLIST" 2>&1; then
        echo "Error: launchctl bootstrap failed."
        echo "Plist written to: $AGENT_PLIST (you can inspect / retry manually)."
        exit 1
    fi

    echo "Installed LaunchAgent: ${AGENT_LABEL}"
    echo "  plist:    $AGENT_PLIST"
    # echo "  schedule: every 60 seconds (StartInterval)"
    echo "  schedule: every hour on the :00 mark (wall clock)"
    echo "  log:      $CRON_LOG"
    echo ""
    echo "To trigger immediately:  launchctl kickstart $(agent_service_target)"
    if crontab -l 2>/dev/null | grep -Fq "$CRON_MARKER"; then
        echo ""
        echo "Note: a legacy cron entry is still installed. Remove it with:"
        echo "      $0 --cron-remove"
    fi
}

cmd_agent_status() {
    if [[ "$(detect_platform)" != "macos" ]]; then
        echo "macOS-only."
        exit 1
    fi
    local target
    target=$(agent_service_target)
    if launchctl print "$target" 2>/dev/null | /usr/bin/grep -E 'state|last exit code|program|next run' | head -20; then
        :
    else
        echo "Not loaded."
        exit 1
    fi
}

cmd_agent_kick() {
    if [[ "$(detect_platform)" != "macos" ]]; then
        echo "macOS-only."
        exit 1
    fi
    local target
    target=$(agent_service_target)
    if launchctl kickstart "$target" 2>&1; then
        echo "Kicked $target"
    else
        echo "Error: kickstart failed (is the agent loaded? run --agent-install)"
        exit 1
    fi
}

cmd_agent_remove() {
    if [[ "$(detect_platform)" != "macos" ]]; then
        echo "macOS-only."
        exit 1
    fi
    local target
    target=$(agent_service_target)
    launchctl bootout "$target" 2>/dev/null || true
    if [[ -f "$AGENT_PLIST" ]]; then
        rm -f "$AGENT_PLIST"
    fi
    local wrapper
    wrapper=$(agent_wrapper_path)
    if [[ -f "$wrapper" ]]; then
        rm -f "$wrapper"
    fi
    echo "Removed LaunchAgent ${AGENT_LABEL}"
}

# --- /LaunchAgent -----------------------------------------------------------

cmd_cron_remove() {
    if ! cron_list_current | grep -Fq "$CRON_MARKER"; then
        echo "No ccswitch cron entry found."
        exit 0
    fi

    local filtered
    filtered=$(cron_list_current | grep -Fv "$CRON_MARKER" || true)

    if [[ -z "$filtered" ]]; then
        crontab -r 2>/dev/null || true
    else
        printf '%s\n' "$filtered" | crontab -
    fi

    echo "Removed ccswitch cron entry."
}

# Show usage
show_usage() {
    echo "Multi-Account Switcher for Claude Code"
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  --add-account                              Add current account to managed accounts"
    echo "  --remove-account <num>                     Remove account (number only, see --list)"
    echo "  --list                                     List all managed accounts"
    echo "  --switch                                   Rotate to next account in sequence"
    echo "  --switch-to <num|email|\"email (org)\">       Switch to specific account"
    echo "  --switch-lowest                            Switch to the account with lowest adjusted utilization"
    echo "  --show-usage                               Print per-account 5h/7d utilization + handicap table"
    echo "  --set-handicap <num> <percent>             Set per-account handicap (0-100); higher = picked less often"
    echo "  --sync-current                             Refresh current account's backup from live state"
    echo "  --agent-install                            Install/update the macOS LaunchAgent (recommended on macOS)"
    echo "  --agent-status                             Show LaunchAgent state (launchctl print)"
    echo "  --agent-kick                               Trigger the LaunchAgent now (launchctl kickstart)"
    echo "  --agent-remove                             Remove the LaunchAgent"
    echo "  --cron-install                             [Linux/legacy] Install cron entry (*/10 min)"
    echo "  --cron-status                              [Linux/legacy] Show cron entry"
    echo "  --cron-log [lines]                         Tail cron.log (default 50 lines) — works for both"
    echo "  --cron-remove                              [Linux/legacy] Remove cron entry"
    echo "  --help                                     Show this help message"
    echo ""
    echo "Identifier forms:"
    echo "  <num>                  Account number shown by --list"
    echo "  <email>                Email (must be unique across managed accounts)"
    echo "  \"<email> (<org>)\"      Email with org label when the same email appears in multiple orgs"
    echo ""
    echo "Examples:"
    echo "  $0 --add-account"
    echo "  $0 --list"
    echo "  $0 --switch"
    echo "  $0 --switch-to 2"
    echo "  $0 --switch-to user@example.com"
    echo "  $0 --switch-to \"user@example.com (Acme)\""
    echo "  $0 --remove-account 2"
}

# Main script logic
main() {
    # Basic checks - allow root execution in containers
    if [[ $EUID -eq 0 ]] && ! is_running_in_container; then
        echo "Error: Do not run this script as root (unless running in a container)"
        exit 1
    fi
    
    check_bash_version
    check_dependencies
    
    case "${1:-}" in
        --add-account)
            cmd_add_account
            ;;
        --remove-account)
            shift
            cmd_remove_account "$@"
            ;;
        --list)
            cmd_list
            ;;
        --switch)
            cmd_switch
            ;;
        --switch-to)
            shift
            cmd_switch_to "$@"
            ;;
        --switch-lowest)
            cmd_switch_lowest
            ;;
        --show-usage)
            cmd_show_usage
            ;;
        --set-handicap)
            shift
            cmd_set_handicap "$@"
            ;;
        --sync-current)
            cmd_sync_current
            ;;
        --agent-install)
            cmd_agent_install
            ;;
        --agent-status)
            cmd_agent_status
            ;;
        --agent-kick)
            cmd_agent_kick
            ;;
        --agent-remove)
            cmd_agent_remove
            ;;
        --cron-install)
            cmd_cron_install
            ;;
        --cron-status)
            cmd_cron_status
            ;;
        --cron-log)
            shift
            cmd_cron_log "${1:-}"
            ;;
        --cron-remove)
            cmd_cron_remove
            ;;
        --help)
            show_usage
            ;;
        "")
            show_usage
            ;;
        *)
            echo "Error: Unknown command '$1'"
            show_usage
            exit 1
            ;;
    esac
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
