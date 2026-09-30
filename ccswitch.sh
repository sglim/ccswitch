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
readonly CRON_COMMAND="--tick"

# Anthropic OAuth usage API constants (see claude-hud usage-api.js)
readonly USAGE_API_URL="https://api.anthropic.com/api/oauth/usage"
readonly USAGE_API_BETA="oauth-2025-04-20"
readonly USAGE_API_UA="claude-code/2.1"
readonly USAGE_API_TIMEOUT=5

# Per-account usage cache. Only display paths (--show-usage, TUI) read it;
# --switch-lowest (the LaunchAgent path) deliberately bypasses the cache by
# never setting CCSWITCH_USE_CACHE=1, so its decision always reflects current
# API state. The TTL used to be 10s, which meant nearly every manual
# --show-usage re-queried every account (9 calls, ~8s) and risked 429s.
# The tick rewrites the current account's cache every minute anyway, so a
# longer TTL only delays the *other* accounts' numbers.
# Force a live fetch: CCSWITCH_USAGE_CACHE_TTL=0 ccswitch.sh --show-usage
readonly USAGE_CACHE_DIR="$BACKUP_DIR/usage-cache"
readonly USAGE_CACHE_TTL="${CCSWITCH_USAGE_CACHE_TTL:-120}"
# 토큰 해시 → 주인(accountUuid, organizationUuid). creds_owner 참고.
readonly OWNER_CACHE_FILE="$BACKUP_DIR/owner-cache"

# Switch hysteresis. If the picker's target is on a different account
# but its adjusted utilization is only this many percentage points
# lower than the current account, stay put. Avoids thrashing between
# near-equal accounts, which kills active Claude Code sessions on
# every cron tick. Override per-invocation with the env var.
readonly HYSTERESIS_DELTA="${CCSWITCH_HYSTERESIS_DELTA:-10}"

# cold-warmup tier 에 들어갈 수 있는 7d 사용률 상한.
# cold 의 목적은 "5h 창을 건드려 클럭을 시작해 두는 것" 인데, 주간 한도가
# 거의 찬 계정은 어차피 쓸 게 없어 그 투자가 의미 없다. 예전엔 조건이
# `seven != "100"` 이라는 문자열 비교였고, 7d=99% 인 계정이 cold 로 뽑혀
# 전환 직후 100% 로 확인되는 일이 있었다(2026-09 실제 사례).
readonly COLD_MAX_SEVEN="${CCSWITCH_COLD_MAX_SEVEN:-90}"

# --why / CCSWITCH_WHY=1 일 때 picker 의 분류 근거를 stderr 로 남긴다.
# LLM 을 쓰지 않는다 — 이미 계산해 놓고 버리던 값을 그대로 찍는 것뿐이라
# 결정 결과에 영향이 없고 비용·지연도 0 이다.
# stdout 은 pick_from_usage_data 의 계약(계정 번호 한 줄)이라 건드리지 않는다.
why() {
    [[ "${CCSWITCH_WHY:-0}" == "1" ]] || return 0
    printf '  %s\n' "$*" >&2
}

# 계정 번호를 폭 맞춰 찍는 why. 첫 인자가 번호, 나머지가 본문.
why_acct() {
    [[ "${CCSWITCH_WHY:-0}" == "1" ]] || return 0
    local n="$1"; shift
    printf '  %-3s %s\n' "$n" "$*" >&2
}

# cold-warmup 후보인가: 5h 미사용 + 5h 리셋 시각 미상 + 7d 에 실질 여유.
# picker 와 두 곳의 사유 메시지가 반드시 같은 판정을 써야 표와 실제가 어긋나지 않는다.
is_cold_candidate() {
    local five="$1" five_rem="$2" seven="$3"
    [[ "$five" == "0" ]] || return 1
    [[ -z "$five_rem" || "$five_rem" == "0" ]] || return 1
    [[ "$seven" =~ ^[0-9]+$ ]] || return 1
    (( seven < COLD_MAX_SEVEN ))
}

# Fable 우선 모드. 기본은 꺼짐 — 켜지 않으면 ccswitch 는 예전처럼
# adjusted(전체 사용량)만 보고 고른다. Fable 을 주력으로 쓰는 사람만
# 켜면 되고, 그 외 사용자의 동작은 이 플래그가 꺼져 있는 한 바뀌지 않는다.
#
# 우선순위: 환경변수 > sequence.json 의 .settings.fablePriority > 기본(off)
# 결과를 캐시해 두 번째 호출부터는 jq 를 돌리지 않는다.
_FABLE_PRIORITY_CACHED=""
fable_priority_enabled() {
    if [[ -n "$_FABLE_PRIORITY_CACHED" ]]; then
        [[ "$_FABLE_PRIORITY_CACHED" == "1" ]] && return 0 || return 1
    fi
    local v=""
    if [[ -n "${CCSWITCH_FABLE_PRIORITY:-}" ]]; then
        v="$CCSWITCH_FABLE_PRIORITY"
    elif [[ -f "$SEQUENCE_FILE" ]]; then
        v=$(jq -r '.settings.fablePriority // false' "$SEQUENCE_FILE" 2>/dev/null)
    fi
    case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
        1|true|on|yes) _FABLE_PRIORITY_CACHED=1 ;;
        *)             _FABLE_PRIORITY_CACHED=0 ;;
    esac
    [[ "$_FABLE_PRIORITY_CACHED" == "1" ]]
}

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
    # default 가 아닌 풀은 그 폴더의 .claude.json (CLAUDE_CONFIG_DIR 규칙).
    if [[ "${POOL:-default}" != "default" ]]; then
        echo "$(pool_dir)/.claude.json"
        return
    fi
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
    # PATH 의 bash 가 아니라 지금 이 스크립트를 돌리는 bash 를 본다 — LaunchAgent 는 PATH 에 옛 /bin/bash(3.2)만
    # 있어도 새 bash 의 절대경로로 실행되므로, PATH 를 보면 멀쩡한데도 멈춘다(brew bash 가 없는 맥에서).
    local version="${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
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

# 살아 있는 자격증명 저장소. macOS 에는 둘이 있다:
#   keychain — 키체인을 열 수 있는 세션(GUI·잠금 푼 터미널)의 Claude Code 가 쓴다
#   file     — 키체인이 잠긴 세션(ssh)의 Claude Code 가 쓰는 <풀 폴더>/.credentials.json
# 둘은 서로 다른 계정일 수 있다(실측: 키체인=3번, 파일=1번). 그래서 .claude.json 이
# 말하는 계정을 믿지 않고, 토큰의 실제 주인을 프로필 API 로 확인해 다룬다.
live_credential_sources() {
    [[ "$(detect_platform)" == "macos" ]] && echo keychain
    echo file
}

read_live_store() {
    case "$1" in
        # -a "$USER" 필수. Claude Code 는 (서비스명, 계정속성=사용자명) 쌍으로 읽고 쓴다.
        # 같은 서비스명에 다른 계정속성(예: "unknown")의 옛 항목이 남아 있으면, -a 없이
        # 조회할 때 그 옛 항목이 먼저 걸려 현재 로그인 토큰을 못 읽는다(2026-09 실제 사례:
        # 모든 계정이 "accessToken expired" 로 보이고 전부 오래된 캐시로 판단했다).
        keychain) security find-generic-password -s "$(dir_keychain_service "$(pool_dir)")" -a "$USER" -w 2>/dev/null || true ;;
        file)     [[ -f "$(pool_dir)/.credentials.json" ]] && cat "$(pool_dir)/.credentials.json" || true ;;
    esac
}

creds_expires_at() {
    local e
    e=$(jq -r '.claudeAiOauth.expiresAt // 0' <<<"$1" 2>/dev/null || echo 0)
    [[ "$e" =~ ^[0-9]+$ ]] && echo "$e" || echo 0
}

# 토큰의 실제 주인 → "accountUuid<TAB>organizationUuid". 만료·폐기·네트워크 실패면 빈 값.
# access token 의 주인은 바뀌지 않으므로, 한 번 확인한 토큰은 만료 시각까지 다시 묻지 않는다.
# (예전엔 --show-usage·--switch-lowest 를 부를 때마다 profile API 를 불렀다.)
# 캐시 파일에는 토큰 자체가 아니라 sha256 만 둔다.
creds_owner() {
    local token hash exp now_ms hit owner tmp
    token=$(jq -r '.claudeAiOauth.accessToken // empty' <<<"$1" 2>/dev/null || true)
    [[ -n "$token" ]] || return 0
    hash=$(printf '%s' "$token" | shasum -a 256 | cut -c1-64)
    exp=$(creds_expires_at "$1")
    now_ms=$(( $(date +%s) * 1000 ))
    if [[ -f "$OWNER_CACHE_FILE" ]]; then
        hit=$(awk -F'\t' -v h="$hash" -v now="$now_ms" \
            '$1 == h && $4 + 0 > now + 0 { print $2 "\t" $3; exit }' "$OWNER_CACHE_FILE" 2>/dev/null || true)
        if [[ -n "$hit" ]]; then
            echo "$hit"
            return 0
        fi
    fi
    owner=$(curl -s -m 10 "https://api.anthropic.com/api/oauth/profile" \
        -H "Authorization: Bearer $token" -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null \
        | jq -r 'select(.account.uuid and .organization.uuid) | [.account.uuid, .organization.uuid] | @tsv' 2>/dev/null || true)
    [[ -n "$owner" ]] || return 0
    if (( exp > now_ms )); then
        tmp="$OWNER_CACHE_FILE.$$"
        {
            # 만료된 줄과 같은 토큰의 옛 줄은 버린다 — 파일이 계속 자라지 않게.
            if [[ -f "$OWNER_CACHE_FILE" ]]; then
                awk -F'\t' -v h="$hash" -v now="$now_ms" '$1 != h && $4 + 0 > now + 0' "$OWNER_CACHE_FILE" 2>/dev/null || true
            fi
            printf '%s\t%s\t%s\n' "$hash" "$owner" "$exp"
        } > "$tmp" 2>/dev/null && /bin/mv -f "$tmp" "$OWNER_CACHE_FILE" 2>/dev/null || true
    fi
    echo "$owner"
}

# 살아 있는 저장소 중 주인이 (accountUuid, organizationUuid) 인 것. 없으면 빈 값.
read_live_credentials_of() {
    local uuid="$1" org="$2" src creds
    for src in $(live_credential_sources); do
        creds=$(read_live_store "$src")
        [[ -n "${creds//[[:space:]]/}" ]] || continue
        if [[ "$(creds_owner "$creds")" == "$uuid"$'\t'"$org" ]]; then
            echo "$creds"
            return
        fi
    done
}

# 살아 있는 저장소를 각각 «토큰 주인»의 칸에 백업한다.
# 예전엔 .claude.json 이 말하는 계정 칸에 키체인 값을 무조건 썼다. 두 저장소가 어긋나면
# 남의 토큰이 들어가, 1·2번 칸이 같은 토큰(나중에 폐기됨)을 갖게 됐다(2026-09-26 실측).
# 백업보다 오래된 토큰이면 쓰지 않는다.
# 주인 확인이 안 되면(access token 만료 — 풀이 8시간 넘게 쉬면 흔하다):
#   refresh token 이 어느 백업 칸과 같으면 이미 저장된 것이라 넘어가고,
#   아니면 그 풀 설정 파일이 가리키는 계정 칸에, 그 칸보다 새 토큰일 때만 쓴다.
#   그래도 못 쓰면 BACKUP_UNSAVED=1 — 이 토큰을 지우면 그 계정 로그인을 잃는다.
BACKUP_UNSAVED=0
backup_live_credentials() {
    local src creds uuid org slot email old rt n
    BACKUP_UNSAVED=0
    for src in $(live_credential_sources); do
        creds=$(read_live_store "$src")
        [[ -n "${creds//[[:space:]]/}" ]] || continue
        IFS=$'\t' read -r uuid org < <(creds_owner "$creds"; echo) || true
        slot=""
        if [[ -n "$uuid" ]]; then
            slot=$(jq -r --arg u "$uuid" --arg o "$org" \
                '.accounts | to_entries[] | select(.value.uuid == $u and (.value.organizationUuid // "") == $o) | .key' \
                "$SEQUENCE_FILE" 2>/dev/null | head -n1)
        fi
        if [[ -z "$slot" ]]; then
            rt=$(jq -r '.claudeAiOauth.refreshToken // ""' <<<"$creds" 2>/dev/null || true)
            for n in $(jq -r '.accounts | keys[]' "$SEQUENCE_FILE"); do
                if [[ -n "$rt" && "$(jq -r '.claudeAiOauth.refreshToken // ""' <<<"$(read_account_credentials "$n" "$(jq -r --arg n "$n" '.accounts[$n].email' "$SEQUENCE_FILE")")" 2>/dev/null)" == "$rt" ]]; then
                    slot="same"
                    break
                fi
            done
            [[ "$slot" == "same" ]] && continue
            slot=$(identify_current_account)
            if [[ -n "$slot" ]]; then
                email=$(jq -r --arg n "$slot" '.accounts[$n].email' "$SEQUENCE_FILE")
                old=$(read_account_credentials "$slot" "$email")
                if (( $(creds_expires_at "$creds") > $(creds_expires_at "$old") )); then
                    echo "  [$src] 토큰 주인 확인 불가(만료) — 설정 파일 기준 Account-$slot 칸에 백업" >&2
                    write_account_credentials "$slot" "$email" "$creds"
                    continue
                fi
            fi
            echo "  [$src] 토큰 주인을 확인 못 했고 저장된 적도 없는 토큰 — 백업하지 못함" >&2
            BACKUP_UNSAVED=1
            continue
        fi
        email=$(jq -r --arg n "$slot" '.accounts[$n].email' "$SEQUENCE_FILE")
        old=$(read_account_credentials "$slot" "$email")
        if (( $(creds_expires_at "$creds") < $(creds_expires_at "$old") )); then
            continue
        fi
        write_account_credentials "$slot" "$email" "$creds"
    done
}

# Write credentials based on platform
write_credentials() {
    local credentials="$1"
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            # Claude Code 와 같은 규칙: 키체인을 쓸 수 있으면 키체인, 잠겨 있으면(ssh) 파일.
            # 같은 토큰을 두 저장소에 다 넣으면 한쪽이 갱신(회전)될 때 다른 쪽이 무효가 된다.
            local dir
            dir=$(pool_dir)
            if ! security add-generic-password -U -s "$(dir_keychain_service "$dir")" -a "$USER" -w "$credentials" 2>/dev/null; then
                echo "  키체인이 잠겨 있어 $dir/.credentials.json 에 씀" >&2
                mkdir -p "$dir"
                printf '%s' "$credentials" > "$dir/.credentials.json"
                chmod 600 "$dir/.credentials.json"
            fi
            ;;
        linux|wsl)
            mkdir -p "$(pool_dir)"
            printf '%s' "$credentials" > "$(pool_dir)/.credentials.json"
            chmod 600 "$(pool_dir)/.credentials.json"
            ;;
    esac
}

# ── 풀(pool) ────────────────────────────────────────────────────────────────
# 풀 = Claude 설정 폴더 하나 + 그 폴더가 돌려 쓰는 계정 목록. 풀 안에서는 예전처럼
# 토큰을 갈아 끼워, 그 폴더로 떠 있는 세션 전부가 함께 바뀐다.
#   sequence.json 의 .pools 가 없으면 → 모든 계정이 든 "default" 풀(~/.claude) 하나.
#   .pools[이름] = {dir, accounts:[번호…]} 로 풀을 더한다(--pool-add).
# 명령은 `--pool <이름>`(또는 CCSWITCH_POOL) 이 가리키는 풀에 적용된다. 기본 "default".
# 한 계정은 동시에 한 풀에서만 쓴다 — 같은 토큰을 두 폴더가 번갈아 갱신하면 한쪽이
# 무효가 되므로, 다른 풀이 쓰는 중인 계정은 전환 대상에서 뺀다.
#
# Claude Code 의 키체인 항목 이름(공식 문서 + 실측):
#   기본 ~/.claude → "Claude Code-credentials"
#   그 밖의 폴더    → "Claude Code-credentials-<sha256(폴더 경로) 앞 8자>"
# 기본 폴더를 CLAUDE_CONFIG_DIR 로 명시하면 접미사 붙은 이름을 찾아 로그인이 깨진다
# → 기본 폴더 풀은 변수를 비운 채 띄운다.
POOL="${CCSWITCH_POOL:-default}"

pool_names() {
    echo default
    jq -r '.pools // {} | keys[] | select(. != "default")' "$SEQUENCE_FILE" 2>/dev/null || true
}

pool_exists() {
    [[ "$1" == "default" ]] || jq -e --arg p "$1" '.pools[$p]' "$SEQUENCE_FILE" >/dev/null 2>&1
}

# 풀의 설정 폴더(절대 경로). default 는 늘 ~/.claude.
pool_dir() {
    local p="${1:-$POOL}" d
    if [[ "$p" == "default" ]]; then
        echo "$HOME/.claude"
        return
    fi
    d=$(jq -r --arg p "$p" '.pools[$p].dir // ""' "$SEQUENCE_FILE" 2>/dev/null)
    d="${d/#\~/$HOME}"
    echo "${d%/}"
}

is_default_dir() {
    [[ "${1%/}" == "$HOME/.claude" ]]
}

dir_keychain_service() {
    if is_default_dir "$1"; then
        echo "Claude Code-credentials"
    else
        echo "Claude Code-credentials-$(printf '%s' "${1%/}" | shasum -a 256 | cut -c1-8)"
    fi
}

# 풀의 계정 번호들. default 풀은 .pools.default.accounts 가 없으면 등록된 전부.
pool_accounts() {
    local p="${1:-$POOL}"
    jq -r --arg p "$p" '
        if (.pools[$p].accounts // null) != null then .pools[$p].accounts[] | tostring
        else .accounts | keys[] end' "$SEQUENCE_FILE" 2>/dev/null
}

# 풀이 지금 쓰는 계정 번호(그 풀 설정 파일의 oauthAccount 기준). 없으면 빈 값.
pool_current_account() {
    ( POOL="$1"; identify_current_account )
}

# 지금 풀(POOL)에서 계정 N 으로 전환할 수 있나: 풀의 계정이고, 다른 풀이 쓰는 중이 아니어야 한다.
pool_eligible() {
    local n="$1" p
    pool_accounts | grep -qx "$n" || return 1
    for p in $(pool_names); do
        [[ "$p" == "$POOL" ]] && continue
        [[ "$(pool_current_account "$p")" == "$n" ]] && return 1
    done
    return 0
}

# stdin 의 gather_all_usage 행 중 지금 풀에서 고를 수 있는 것만(지금 계정은 늘 남긴다).
filter_pool_rows() {
    local current="${1:-}" row n
    while IFS= read -r row; do
        n="${row%%$'\x1f'*}"
        [[ -z "$n" ]] && continue
        if [[ "$n" == "$current" ]] || pool_eligible "$n"; then
            printf '%s\n' "$row"
        fi
    done
}

# 풀 쪽 .pools[p].active 기록(표시용). default 풀은 예전처럼 activeAccountNumber.
set_pool_active() {
    local n="$1" updated
    if [[ "$POOL" == "default" ]]; then
        updated=$(jq --arg n "$n" '.activeAccountNumber = ($n | tonumber)' "$SEQUENCE_FILE")
    else
        updated=$(jq --arg p "$POOL" --arg n "$n" '.pools[$p].active = ($n | tonumber)' "$SEQUENCE_FILE")
    fi
    write_json "$SEQUENCE_FILE" "$updated"
}

# 풀이 둘 이상이면 「Pools: default(~/.claude)=1 · work(~/.claude-work)=4」 한 줄.
print_pools_line() {
    local names p cur out=()
    names=$(pool_names)
    [[ $(echo "$names" | wc -l) -gt 1 ]] || return 0
    for p in $names; do
        cur=$(pool_current_account "$p")
        out+=("$([[ "$p" == "$POOL" ]] && echo "*")$p($(pool_dir "$p" | sed "s|^$HOME|~|"))=${cur:--}")
    done
    echo "Pools: ${out[*]}"
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
    local config_file
    config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"

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
    # $3: 호출자가 이미 읽어 둔 자격증명(선택). 키체인 조회는 계정당 ~30ms 라
    # 같은 루프에서 두 번 읽으면 그대로 두 배가 된다. 있으면 재사용한다.
    local cred="${3-}"

    if [[ -z "$cred" ]]; then
        cred=$(read_account_credentials "$account_num" "$email")
    fi
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

    # Returns seven space-separated fields:
    #   <5h%> <7d%> <5h_resets_epoch> <7d_resets_epoch> <extra_enabled> <extra_util> <fable%>
    # resets_at are Unix epoch seconds; 0 if missing or unparsable.
    # extra_enabled is "true"/"false" from the live API (preferred over the
    # snapshot in backup config). extra_util is the rounded extra-usage
    # percentage (0 when disabled or absent).
    local five seven five_reset seven_reset extra_enabled extra_util fable
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
    # Fable 은 별도 필드가 없고 limits[] 안에 weekly_scoped 로 들어온다:
    #   {kind:"weekly_scoped", percent:31, scope:{model:{display_name:"Fable"}}}
    # 없는 계정/플랜이면 -1 (미지원)로 두어 0%(=여유 만땅)와 구분한다.
    fable=$(echo "$response" | jq -r '[.limits[]? | select(.scope.model.display_name == "Fable") | .percent] | if length > 0 then (.[0] | floor) else -1 end')
    [[ "$fable" =~ ^-?[0-9]+$ ]] || fable=-1

    local result="$five $seven $five_reset $seven_reset $extra_enabled $extra_util $fable"
    # Always write cache on success — even when the caller didn't request
    # cache use. Costs nothing and means a subsequent --show-usage hit
    # within TTL serves from disk without burning more API quota.
    /bin/mkdir -p "$USAGE_CACHE_DIR" 2>/dev/null
    printf '%s\n' "$result" > "$cache_file" 2>/dev/null
    echo "$result"
}

# Read this account's handicap from sequence.json.
# Args: account_num. Missing / null / non-integer yields 0.
# Fable 전용 handicap. 일반 handicap 과 별개로, "이 계정의 Fable 은
# 마지막에 써라" 를 표현한다. picker 는 fable + fable_handicap 을
# 유효값으로 보고, 그게 100 이상이면 Fable 여유 그룹에서 빠진다.
# 즉 100 을 주면 다른 계정 Fable 이 전부 소진된 뒤에야 쓰인다.
# 이 계정으로 실제 전환할 수 있는지 = 자격증명과 config 백업이 둘 다 비어 있지 않은지.
# 키체인 항목이 "존재하지만 비어 있는" 경우(로그인 만료 후 덮어써진 경우 등)도
# 여기서 걸러진다. perform_switch 가 "Missing backup data" 로 죽는 조건과 동일.
account_has_backup() {
    local account_num="$1" email="$2"
    # config 백업은 수 MB 라 변수로 읽지 않는다. 파일 크기만 본다.
    # (한 번 슬럽해서 ${var//...} 치환하면 bash 가 CPU 를 통째로 태운다.)
    local config_file
    config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    [[ -s "$config_file" ]] || return 1
    # 자격증명은 작다. 키체인 항목이 "있지만 비어 있는" 경우까지 걸러낸다.
    local creds
    creds=$(read_account_credentials "$account_num" "$email")
    [[ -n "${creds//[[:space:]]/}" ]]
}

get_account_fable_handicap() {
    local account_num="$1"
    [[ -f "$SEQUENCE_FILE" ]] || { echo 0; return; }
    local h
    h=$(jq -r --arg num "$account_num" '.accounts[$num].fableHandicap // 0' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ "$h" =~ ^[0-9]+$ ]]; then
        echo "$h"
    else
        echo 0
    fi
}

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

        local handicap util_pair five seven five_reset seven_reset fable
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
        # 자격증명은 이 루프에서 딱 한 번만 읽는다(키체인 조회가 계정당 ~30ms).
        # 읽은 값을 nobackup 판정과 fetch 양쪽에 재사용한다.
        local cred_cached config_backup
        cred_cached=$(read_account_credentials "$num" "$email")
        config_backup="$BACKUP_DIR/configs/.claude-config-${num}-${email}.json"
        if [[ ! -s "$config_backup" || -z "${cred_cached//[[:space:]]/}" ]]; then
            # 전환 불가 계정. 캐시 추정치로 채우면 "5h=0/7d=0" 처럼 보여 picker 가
            # 최우선으로 고른 뒤 perform_switch 에서 죽는다. 아예 후보에서 뺀다.
            status="nobackup"
            echo "  [Account-$num $email] no backup credentials — excluded (re-login and run --add-account)" >&2
        elif util_pair=$(fetch_account_utilization "$num" "$email" "$cred_cached"); then
            status="ok"
        else
            local fetch_rc=$?
            cache_file="$USAGE_CACHE_DIR/account-$num"
            if [[ -f "$cache_file" ]] && cached=$(cat "$cache_file" 2>/dev/null) && [[ -n "$cached" ]]; then
                # 429 도 캐시가 있으면 그 계정만 추정치로 대체하고 나머지는 계속 조회한다.
                # 예전엔 한 계정의 429 가 표 전체를 중단시켰다.
                util_pair="$cached"
                status="estimated"
                echo "  [Account-$num $email] falling back to cached estimate" >&2
            elif (( fetch_rc == 2 )); then
                return 2
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
            # 7번째 = Fable %. 구버전 캐시(6필드)면 비어 있으므로 -1(미지원) 처리.
            fable=$(echo "$util_pair" | awk '{print $7}')
            [[ "$fable" =~ ^-?[0-9]+$ ]] || fable=-1
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
                    # Fable 도 같이 되돌린다. API 에서 Fable 은
                    # kind=weekly_scoped / group=weekly 이고 resets_at 이
                    # seven_day 와 동일하다(마이크로초까지). 즉 7d 가 롤오버했으면
                    # Fable 도 반드시 리셋된 상태다.
                    # 이 보정이 없으면 캐시에 남은 Fable=100 때문에 "방금 주간
                    # 한도가 리셋된 계정"이 Fable 소진으로 오인돼 최하위로 밀린다.
                    if [[ "$fable" =~ ^[0-9]+$ ]]; then
                        fable=0
                    fi
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
            # 임계는 binding 창의 길이에 맞춘다. 48h 는 7d 창을 전제로 고른
            # 값이라, 5h 창이 binding 일 때 그대로 쓰면 남은 시간이 항상
            # 5시간 미만이라 보너스가 매번 44~48 이 되어 raw_max 를 통째로
            # 덮어쓴다. 그러면 5h 9% 와 5h 38% 가 똑같이 adjusted 0 이 되어
            # picker 가 둘을 구분하지 못한다.
            local raw_max bind_rem urgency_window
            if (( five > seven )); then
                raw_max=$five; bind_rem=$five_rem; urgency_window=5
            else
                raw_max=$seven; bind_rem=$seven_rem; urgency_window=48
            fi
            local urgency_bonus=0
            # Skip urgency for handicapped accounts. Handicap's whole
            # point is "leave headroom on this account" — urgency would
            # invert that intent by promoting a handicapped account
            # whose 5h is about to reset to the top of the picker.
            # 이미 포화(100%)된 계정엔 urgency 를 주지 않는다. 보너스의 취지는
            # "곧 리셋되니 남은 걸 지금 써라" 인데, 100% 면 쓸 게 없어서 그
            # 전제가 성립하지 않는다. 그대로 두면 7d=100 인 죽은 계정이
            # adjusted 66 처럼 보여 hysteresis 가 전환을 막는다(실제 버그).
            if (( raw_max < 100 )) \
               && (( handicap == 0 )) && [[ "$bind_rem" =~ ^[0-9]+$ ]] && (( bind_rem > 0 )); then
                local bind_hours=$(( bind_rem / 3600 ))
                if (( bind_hours < urgency_window )); then
                    urgency_bonus=$(( urgency_window - bind_hours ))
                fi
            fi
            adjusted=$(( raw_max + handicap - urgency_bonus ))
            (( adjusted < 0 )) && adjusted=0
        else
            five=""; seven=""; five_rem=""; seven_rem=""; adjusted=""; fable=-1
        fi

        # Use ASCII US (\x1f, Unit Separator) instead of tab as the TSV
        # delimiter. Bash `read -r` with IFS=$'\t' treats tab as whitespace
        # and collapses consecutive tabs, dropping empty fields. With a
        # non-whitespace separator, empty fields are preserved.
        local fable_hc
        fable_hc=$(get_account_fable_handicap "$num")
        printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
            "$num" "$email" "$five" "$seven" "$handicap" "$adjusted" "$status" \
            "$five_rem" "$seven_rem" "$has_extra" "$extra_util" "$fable" "$fable_hc"
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
    printf '%-3s %-2s %-32s %5s %7s %5s %7s %8s %9s %9s %4s\n' \
        "" "#" "Email" "5h%" "5h-rst" "7d%" "7d-rst" "Fable" "Handicap" "Adjusted" "Ext"
    local num email five seven handicap adjusted status five_rem seven_rem has_extra extra_util fable fable_hc prefix ext_disp fable_disp
    while IFS=$'\x1f' read -r num email five seven handicap adjusted status five_rem seven_rem has_extra extra_util fable fable_hc; do
        [[ -z "$num" ]] && continue
        if [[ "$num" == "$current_account" ]]; then prefix="*"; else prefix=" "; fi
        # Fable 컬럼: -1(또는 비어있음)은 이 계정/플랜에 Fable 한도가 없다는 뜻.
        # Fable handicap 이 걸려 있으면 "53+100" 처럼 붙여 보여준다.
        # 왜 안 뽑히는지 표에서 바로 보이게 하기 위함.
        if [[ "$fable" =~ ^[0-9]+$ ]]; then
            if [[ "$fable_hc" =~ ^[0-9]+$ ]] && (( fable_hc > 0 )); then
                fable_disp="${fable}+${fable_hc}"
            else
                fable_disp="${fable}%"
            fi
        else
            fable_disp="-"
        fi
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
            printf '%-3s %-2s %-32s %5s %7s %5s %7s %8s %9s %9s %4s\n' \
                "$prefix" "$num" "$email" \
                "$five" "$(format_remaining "$five_rem")" \
                "$seven" "$(format_remaining "$seven_rem")" \
                "$fable_disp" "$handicap" "$adjusted" "$ext_disp"
        elif [[ "$status" == "estimated" ]]; then
            # "?" suffix marks values as cached estimates. Reset-time columns
            # interpolate naturally because cached reset epochs are absolute.
            printf '%-3s %-2s %-32s %5s %7s %5s %7s %8s %9s %9s %4s\n' \
                "$prefix" "$num" "$email" \
                "${five}?" "$(format_remaining "$five_rem")" \
                "${seven}?" "$(format_remaining "$seven_rem")" \
                "$fable_disp" "$handicap" "${adjusted}?" "$ext_disp"
        else
            printf '%-3s %-2s %-32s %5s %7s %5s %7s %8s %9s %9s %4s\n' \
                "$prefix" "$num" "$email" "-" "-" "-" "-" "-" "$handicap" \
                "$([[ "$status" == "nobackup" ]] && echo "no-backup" || echo "N/A")" "$ext_disp"
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
    # cold 도 Fable 여유 유무로 갈라 담는다. Fable 이 남은 계정이 하나라도
    # 있으면 소진된 계정은 어떤 tier 로도 이기지 못하게 하기 위함.
    local cold_fable_num="" cold_fable_score="" cold_fable_rem=""
    local healthy_num="" healthy_score="" healthy_rem=""
    # maxed-extra has two collectors: "_alt" excludes the current active
    # num to enforce round-robin; the unsuffixed one keeps every ext
    # candidate so we can still fall back when current is the only one.
    local maxed_extra_num="" maxed_extra_eu="" maxed_extra_adj=""
    local maxed_extra_alt_num="" maxed_extra_alt_eu="" maxed_extra_alt_adj=""
    local maxed_noextra_num="" maxed_noextra_score="" maxed_noextra_rem=""
    local blocked_num="" blocked_score=""
    local num email five seven handicap adjusted status five_rem seven_rem has_extra extra_util fable fable_hc
    # Fable 우선 선택용 수집기. healthy tier 안에서 "Fable 여유 있는 계정" 을
    # 별도로 모아, 있으면 그쪽을 먼저 쓴다. 전부 소진(100%)되면 기존 로직대로.
    local fable_num="" fable_score="" fable_rem=""
    while IFS=$'\x1f' read -r num email five seven handicap adjusted status five_rem seven_rem has_extra extra_util fable fable_hc; do
        [[ -z "$num" ]] && continue
        # 유효 Fable = 실제 사용률 + 계정별 Fable handicap.
        # handicap 100 을 주면 유효값이 항상 100 이상이라 Fable 여유 그룹에서
        # 빠지고, 결과적으로 그 계정 Fable 은 가장 마지막에 쓰이게 된다.
        # Fable 미지원(-1)은 handicap 과 무관하게 -1 로 유지한다.
        local fable_eff="$fable"
        if [[ "$fable" =~ ^[0-9]+$ ]]; then
            [[ "$fable_hc" =~ ^[0-9]+$ ]] || fable_hc=0
            fable_eff=$(( fable + fable_hc ))
            (( fable_eff > 100 )) && fable_eff=100
            if (( fable_hc > 0 )); then
                why_acct "$num" "Fable 유효 ${fable_eff} = 실제 ${fable}% + handicap ${fable_hc}"
            fi
        fi
        if [[ "$status" == "nobackup" ]]; then
            why_acct "$num" "제외: 백업 자격증명 없음 (전환 불가)"
            continue
        fi
        if [[ "$status" == "unavailable" ]]; then
            why_acct "$num" "stale 후보: 사용량 조회 실패 (토큰 갱신 목적)"
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
            why_acct "$num" "blocked-handicap: raw ${raw_max_p}% + handicap ${handicap} = ${raw_with_handicap} >= 100 (최후 수단)"
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
        if ! is_cold_candidate "$five" "$five_rem" "$seven"; then
            if [[ "$five" == "0" && ( -z "$five_rem" || "$five_rem" == "0" ) ]]; then
                why_acct "$num" "cold 제외: 7d ${seven}% >= COLD_MAX_SEVEN(${COLD_MAX_SEVEN})"
            fi
        fi
        if is_cold_candidate "$five" "$five_rem" "$seven"; then
            if fable_priority_enabled \
               && [[ "$fable_eff" =~ ^[0-9]+$ ]] && (( fable_eff < 100 )); then
                # Fable 여유 있는 cold — 최우선 그룹 (Fable 우선 모드일 때만).
                why_acct "$num" "cold(Fable 여유) 후보: 5h 미사용, 7d ${seven}%, Fable 유효 ${fable_eff}, adjusted ${adjusted}"
                if [[ -z "$cold_fable_num" ]]; then
                    cold_fable_num="$num"; cold_fable_score="$adjusted"; cold_fable_rem="$seven_rem_norm"
                elif (( adjusted < cold_fable_score )); then
                    cold_fable_num="$num"; cold_fable_score="$adjusted"; cold_fable_rem="$seven_rem_norm"
                elif (( adjusted == cold_fable_score && seven_rem_norm < cold_fable_rem )); then
                    cold_fable_num="$num"; cold_fable_score="$adjusted"; cold_fable_rem="$seven_rem_norm"
                fi
            else
                # Fable 소진(100%) 또는 미지원(-1) — 후순위 그룹.
                why_acct "$num" "cold 후보: 5h 미사용, 7d ${seven}%, Fable 유효 ${fable_eff}, adjusted ${adjusted}"
                if [[ -z "$cold_num" ]]; then
                    cold_num="$num"; cold_score="$adjusted"; cold_rem="$seven_rem_norm"
                elif (( adjusted < cold_score )); then
                    cold_num="$num"; cold_score="$adjusted"; cold_rem="$seven_rem_norm"
                elif (( adjusted == cold_score && seven_rem_norm < cold_rem )); then
                    cold_num="$num"; cold_score="$adjusted"; cold_rem="$seven_rem_norm"
                fi
            fi
        fi
        # Saturation classification.
        # Healthy tie-break: same seven_rem rule as cold — when two
        # accounts have identical adjusted (common when the API hands
        # back integer percentages), prefer the one whose 7d window is
        # closer to resetting. Otherwise the picker would lock onto the
        # lowest num forever and waste imminent-reset headroom.
        if [[ "$five" != "100" && "$seven" != "100" ]]; then
            # Single healthy tier: handicap already lives in `adjusted`
            # (max + handicap), so a handicapped account competes on its
            # score alone — no separate lower tier. This is what lets a
            # handicapped account with the lowest adjusted win over a
            # non-handicap account sitting at, say, 94%. The
            # blocked-handicap guard above still fully excludes a
            # handicapped account whose raw+handicap >= 100.
            why_acct "$num" "healthy 후보: 5h ${five}%, 7d ${seven}%, adjusted ${adjusted}"
            if [[ -z "$healthy_num" ]]; then
                healthy_num="$num"; healthy_score="$adjusted"; healthy_rem="$seven_rem_norm"
            elif (( adjusted < healthy_score )); then
                healthy_num="$num"; healthy_score="$adjusted"; healthy_rem="$seven_rem_norm"
            elif (( adjusted == healthy_score && seven_rem_norm < healthy_rem )); then
                healthy_num="$num"; healthy_score="$adjusted"; healthy_rem="$seven_rem_norm"
            fi
            # Fable 여유가 남은 계정(0 <= fable < 100)만 따로 모은다.
            # 정렬 키는 Fable 사용률 오름차순(가장 많이 남은 순), 동률이면
            # adjusted, 그 다음 7d reset 임박 순.
            if fable_priority_enabled \
               && [[ "$fable_eff" =~ ^[0-9]+$ ]] && (( fable_eff < 100 )); then
                why_acct "$num" "fable-first 후보: Fable 유효 ${fable_eff} (< 100), adjusted ${adjusted}"
                if [[ -z "$fable_num" ]]; then
                    fable_num="$num"; fable_score="$fable_eff"; fable_rem="$adjusted"
                elif (( fable_eff < fable_score )); then
                    fable_num="$num"; fable_score="$fable_eff"; fable_rem="$adjusted"
                elif (( fable_eff == fable_score && adjusted < fable_rem )); then
                    fable_num="$num"; fable_score="$fable_eff"; fable_rem="$adjusted"
                fi
            fi
        elif [[ "$has_extra" == "true" ]]; then
            why_acct "$num" "maxed-with-extra: 5h ${five}% / 7d ${seven}% 포화, extra-usage 있음"
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
            why_acct "$num" "maxed-no-extra: 포화 + extra-usage 없음 (최후 수단)"
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
        why "→ 선택: Account-$stale_num (tier=stale — 토큰 갱신 우선)"
        echo "$stale_num"
    elif [[ -n "$cold_fable_num" ]]; then
        why "→ 선택: Account-$cold_fable_num (tier=cold-fable — Fable 여유 + 5h 미사용)"
        # ── Fable 여유가 있는 그룹 (cold → healthy) ──────────────────
        # Fable 잔량이 tier 보다 우선한다. 예전엔 cold 가 fable 보다 위라
        # Fable 100% 계정이 "5h 가 0" 이라는 이유만으로 계속 뽑혔다.
        echo "$cold_fable_num"
    elif [[ -n "$fable_num" ]]; then
        why "→ 선택: Account-$fable_num (tier=fable-first — Fable 유효 ${fable_score})"
        echo "$fable_num"
    elif [[ -n "$cold_num" ]]; then
        why "→ 선택: Account-$cold_num (tier=cold — 5h 클럭 시작)"
        # ── 여기부터 Fable 소진/미지원 그룹 ───────────────────────────
        echo "$cold_num"
    elif [[ -n "$healthy_num" ]]; then
        why "→ 선택: Account-$healthy_num (tier=healthy — adjusted ${healthy_score} 최저)"
        echo "$healthy_num"
    elif [[ -n "$maxed_extra_alt_num" ]]; then
        why "→ 선택: Account-$maxed_extra_alt_num (tier=maxed-extra-alt — 포화지만 extra-usage)"
        echo "$maxed_extra_alt_num"
    elif [[ -n "$maxed_extra_num" ]]; then
        why "→ 선택: Account-$maxed_extra_num (tier=maxed-extra)"
        echo "$maxed_extra_num"
    elif [[ -n "$maxed_noextra_num" ]]; then
        why "→ 선택: Account-$maxed_noextra_num (tier=maxed-no-extra — 최후 수단)"
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
    current_creds=$(read_live_credentials_of "$current_account_uuid" "$current_org_uuid")
    current_config=$(cat "$(get_claude_config_path)")

    if [[ -z "$current_creds" ]]; then
        echo "Error: $current_email 의 유효한 자격증명을 키체인·~/.claude/.credentials.json 어디서도 찾지 못함"
        echo "  → Claude Code 에서 그 계정으로 /login 한 뒤 다시 실행"
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
    print_pools_line
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

    # Keep the pool's active record in sequence.json consistent with reality.
    set_pool_active "$active_account"

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
    
    local seq_len=${#sequence[@]} step cand cand_email
    next_account=""
    for ((step = 1; step < seq_len; step++)); do
        cand="${sequence[$(((current_index + step) % seq_len))]}"
        cand_email=$(jq -r --arg n "$cand" '.accounts[$n].email // ""' "$SEQUENCE_FILE")
        pool_eligible "$cand" || continue
        if account_has_backup "$cand" "$cand_email"; then
            next_account="$cand"
            break
        fi
        echo "Skipping Account-$cand ($cand_email): no backup credentials — re-login and run --add-account" >&2
    done
    if [[ -z "$next_account" ]]; then
        echo "Error: 이 풀에서 전환할 수 있는 다른 계정이 없다 (백업이 없거나 다른 풀이 쓰는 중)"
        exit 1
    fi

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

# Lightweight 1-minute tick, meant to be driven by the LaunchAgent.
# Two triggers, cheapest-first so the common case costs one API call:
#   1) EMERGENCY: fetch ONLY the current account. If it's saturated
#      (5h>=100 or 7d>=100), switch away immediately — hysteresis is
#      forced off because staying on a 100% account is never right.
#   2) HOURLY: once an hour, on this machine's sweep minute (see
#      sweep_minute), run the normal switch-lowest, which sweeps every
#      account. This preserves the old once-an-hour cadence.
# Every other minute does nothing and prints nothing, so cron.log stays
# quiet and we make at most one usage-API call per minute (the active
# account), well under any rate limit.
# 매시 전체 조회(sweep)를 돌릴 «분»(0-59).
# 예전엔 모든 PC 가 :00 에 돌려, 같은 공인 IP·같은 계정으로 조회(PC 당 계정 수만큼)가
# 한꺼번에 몰렸다(429). 호스트 이름 해시로 PC 마다 다른 분에 흩는다.
# CCSWITCH_SWEEP_MINUTE 로 고정할 수 있다.
sweep_minute() {
    local m="${CCSWITCH_SWEEP_MINUTE:-}"
    if [[ -z "$m" ]]; then
        m=$( (hostname -s 2>/dev/null || hostname) | cksum | cut -d' ' -f1 )
    elif [[ ! "$m" =~ ^[0-9]+$ ]] || (( 10#$m > 59 )); then
        echo "Error: CCSWITCH_SWEEP_MINUTE must be 0-59 (got '$m')" >&2
        return 1
    fi
    echo $(( 10#$m % 60 ))
}

# 모든 풀을 차례로 한 번씩 tick 한다(풀마다 서브셸 — POOL 과 exit 이 서로 새지 않게).
cmd_tick() {
    [[ -f "$SEQUENCE_FILE" ]] || return 0
    local p
    for p in $(pool_names); do
        ( POOL="$p"; cmd_tick_pool ) || true
    done
}

cmd_tick_pool() {
    [[ -f "$SEQUENCE_FILE" ]] || return 0

    local minute current email util five seven
    minute=$(date +%M)
    current=$(identify_current_account)

    # Emergency saturation check: current account only (1 API call).
    if [[ -n "$current" ]]; then
        email=$(jq -r --arg n "$current" '.accounts[$n].email // ""' "$SEQUENCE_FILE")
        if [[ -n "$email" ]] && util=$(fetch_account_utilization "$current" "$email" 2>/dev/null); then
            five=$(echo "$util" | awk '{print $1}')
            seven=$(echo "$util" | awk '{print $2}')
            [[ "$five" =~ ^[0-9]+$ ]] || five=0
            [[ "$seven" =~ ^[0-9]+$ ]] || seven=0
            if (( five >= 100 || seven >= 100 )); then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Emergency: Account-$current saturated (5h=${five}% 7d=${seven}%) — switching now."
                CCSWITCH_HYSTERESIS_DELTA=0 cmd_switch_lowest
                return 0
            fi
        fi
    fi

    # 7d weekly-reset fast path: if any managed account's 7d window has
    # just rolled over (its cached reset epoch is now in the past, within
    # a short window), switch to it immediately instead of waiting for
    # the top of the hour. A freshly-reset account is the most valuable
    # slot to start using right away. Uses cached reset epochs only —
    # zero API calls. The window (2 ticks) keeps it from re-firing
    # forever: once picked, the account becomes current and is skipped;
    # otherwise the window simply passes.
    #
    # ⚠️ Fable 을 반드시 함께 본다. 이 경로는 picker(pick_from_usage_data)를
    # 통째로 우회하기 때문에, 확인하지 않으면 7d 가 리셋될 때마다 Fable 이
    # 소진된 계정으로 강제 이동한다 (2026-09 실제 버그: 표는 Fable 우선인데
    # 자동 전환만 계속 Fable 100% 계정으로 갔다).
    # 규칙: Fable 여유가 남은 계정이 하나라도 있으면, Fable 소진(100%) 계정으로는
    # fast-path 를 발동하지 않는다. 전부 소진된 상태면 예전처럼 그냥 전환한다.
    local reset_window=120 now_s n ncache nseven_reset since nfable
    now_s=$(date +%s)

    # 현재 Fable 여유가 남은 계정이 존재하는지 먼저 확인 (캐시만 사용).
    # Fable 우선 모드가 꺼져 있으면 any_fable_left 를 0 으로 둬서
    # 아래 skip 분기가 절대 발동하지 않게 한다 = 예전 동작 그대로.
    local any_fable_left=0 cfable
    if fable_priority_enabled; then
        for n in $(jq -r '.accounts | keys | map(tonumber) | sort | .[]' "$SEQUENCE_FILE" 2>/dev/null); do
            [[ "$n" == "$current" ]] || pool_eligible "$n" || continue
            ncache="$USAGE_CACHE_DIR/account-$n"
            [[ -f "$ncache" ]] || continue
            cfable=$(awk '{print $7}' "$ncache" 2>/dev/null)
            if [[ "$cfable" =~ ^[0-9]+$ ]]; then
                # 캐시엔 handicap 이 없으므로 sequence.json 에서 읽어 더한다.
                local chc
                chc=$(get_account_fable_handicap "$n")
                if (( cfable + chc < 100 )); then
                    any_fable_left=1
                    break
                fi
            fi
        done
    fi

    for n in $(jq -r '.accounts | keys | map(tonumber) | sort | .[]' "$SEQUENCE_FILE" 2>/dev/null); do
        [[ "$n" == "$current" ]] && continue
        pool_eligible "$n" || continue
        ncache="$USAGE_CACHE_DIR/account-$n"
        [[ -f "$ncache" ]] || continue
        nseven_reset=$(awk '{print $4}' "$ncache" 2>/dev/null)
        [[ "$nseven_reset" =~ ^[0-9]+$ ]] || continue
        (( nseven_reset > 0 )) || continue
        since=$(( now_s - nseven_reset ))
        if (( since >= 0 && since < reset_window )); then
            local nemail
            nemail=$(jq -r --arg n "$n" '.accounts[$n].email // ""' "$SEQUENCE_FILE")
            if ! account_has_backup "$n" "$nemail"; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Account-$n 7d window just reset but has no backup credentials — skipping fast-path."
                continue
            fi
            nfable=$(awk '{print $7}' "$ncache" 2>/dev/null)
            local nhc=0
            [[ "$nfable" =~ ^[0-9]+$ ]] && nhc=$(get_account_fable_handicap "$n")
            if (( any_fable_left == 1 )) \
               && [[ "$nfable" =~ ^[0-9]+$ ]] && (( nfable + nhc >= 100 )); then
                if (( nhc > 0 )); then
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Account-$n 7d window just reset but Fable ${nfable}% + handicap ${nhc} >= 100 — skipping fast-path."
                else
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Account-$n 7d window just reset but Fable exhausted (${nfable}%) — skipping fast-path."
                fi
                continue
            fi
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Account-$n 7d window just reset — switching now."
            cmd_switch_to "$n"
            return 0
        fi
    done

    # Hourly cadence: only act on this machine's sweep minute.
    local sweep
    sweep=$(sweep_minute)
    if (( 10#$minute == sweep )); then
        cmd_switch_lowest
    fi
    return 0
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
    print_pools_line

    # 이 풀에서 고를 수 있는 계정만 picker 에 넣는다(다른 풀이 쓰는 계정·풀 밖 계정 제외).
    data=$(echo "$data" | filter_pool_rows "$current_account")
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
    # both within the "healthy / maxed_noextra"
    # bands where switching = killing the active session for marginal
    # gain. Stale / cold / blocked-handicap decisions still go through
    # immediately — those signal an account issue, not a tie.
    local current_adj target_adj current_status
    current_adj=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$current_account" '$1==n{print $6}')
    target_adj=$(echo "$data"  | /usr/bin/awk -F$'\x1f' -v n="$target"          '$1==n{print $6}')
    current_status=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$current_account" '$1==n{print $7}')
    local target_status_pre
    target_status_pre=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$target" '$1==n{print $7}')
    # 현재 계정이 이미 포화면 hysteresis 를 적용하지 않는다. "세션 끊김을
    # 피한다" 는 취지는 지금 계정을 계속 쓸 수 있을 때만 의미가 있고,
    # 100% 면 어차피 아무 작업도 못 하므로 붙잡아 둘 이유가 없다.
    local cur_five cur_seven cur_saturated=0
    cur_five=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$current_account" '$1==n{print $3}')
    cur_seven=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$current_account" '$1==n{print $4}')
    if [[ "$cur_five" =~ ^[0-9]+$ ]] && (( cur_five >= 100 )); then cur_saturated=1; fi
    if [[ "$cur_seven" =~ ^[0-9]+$ ]] && (( cur_seven >= 100 )); then cur_saturated=1; fi
    if (( cur_saturated == 1 )); then
        echo "Note: current Account-$current_account is saturated (5h ${cur_five}% / 7d ${cur_seven}%) — bypassing hysteresis."
    fi
    # 실측으로 멀쩡한 현재 계정을 두고, 실측이 없는(캐시 추정치·조회 불가) 계정으로는
    # 넘어가지 않는다. 캐시 추정치는 마지막 조회 이후 쓴 양이 빠져 있어 늘 실제보다 낮고,
    # 그래서 picker 가 "가장 모르는 계정" 을 가장 좋아 보이게 고른다(2026-09: 다 쓴
    # 8번을 7d 16% 로 보고 멀쩡한 9번에서 넘어가려 함). 현재 계정이 포화일 때만 넘어간다.
    if (( cur_saturated == 0 )) && [[ "$current_status" == "ok" && "$target_status_pre" != "ok" ]]; then
        echo "Decision: current Account-$current_account is live and healthy (5h ${cur_five}% / 7d ${cur_seven}%); target Account-$target has no live data (status=$target_status_pre) — staying."
        return 0
    fi
    if (( cur_saturated == 0 )) \
       && [[ "$current_status" == "ok" && "$target_status_pre" == "ok" \
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
    elif is_cold_candidate "$target_five" "$target_five_rem" "$target_seven"; then
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
cmd_set_fable_handicap() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 --set-fable-handicap <account_number> <percent>"
        echo "  100 = 이 계정의 Fable 을 가장 마지막에 사용 (다른 계정이 모두 소진된 뒤)"
        echo "    0 = 기본 (Fable 잔량 그대로 평가)"
        exit 1
    fi
    local account_num="$1" percent="$2"
    if ! [[ "$account_num" =~ ^[0-9]+$ ]]; then
        echo "Error: account number must be a positive integer"; exit 1
    fi
    if ! [[ "$percent" =~ ^[0-9]+$ ]] || (( percent < 0 || percent > 100 )); then
        echo "Error: percent must be an integer in [0, 100]"; exit 1
    fi
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"; exit 1
    fi
    local email
    email=$(jq -r --arg num "$account_num" '.accounts[$num].email // ""' "$SEQUENCE_FILE")
    if [[ -z "$email" ]]; then
        echo "Error: Account-$account_num does not exist"; exit 1
    fi
    local updated
    updated=$(jq --arg num "$account_num" --argjson pct "$percent" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num].fableHandicap = $pct |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    if [[ -z "$updated" ]]; then
        echo "Error: failed to update $SEQUENCE_FILE"; exit 1
    fi
    printf '%s\n' "$updated" > "$SEQUENCE_FILE"
    if (( percent >= 100 )); then
        echo "Account-$account_num ($email) Fable handicap = ${percent} — 이 계정의 Fable 은 가장 마지막에 사용됩니다."
    elif (( percent == 0 )); then
        echo "Account-$account_num ($email) Fable handicap 해제 (0)"
    else
        echo "Account-$account_num ($email) Fable handicap = ${percent} — 유효 Fable 사용률에 ${percent}%p 가산됩니다."
    fi
    if ! fable_priority_enabled; then
        echo "Note: Fable 우선 모드가 꺼져 있어 지금은 선택에 영향이 없습니다. --fable-priority on 으로 켜세요."
    fi
}

cmd_fable_priority() {
    local arg="${1:-}"
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    # 인자 없으면 현재 상태만 출력.
    if [[ -z "$arg" ]]; then
        local stored
        stored=$(jq -r '.settings.fablePriority // false' "$SEQUENCE_FILE" 2>/dev/null)
        if fable_priority_enabled; then
            echo "Fable priority: ON"
        else
            echo "Fable priority: OFF"
        fi
        echo "  stored setting : $stored"
        if [[ -n "${CCSWITCH_FABLE_PRIORITY:-}" ]]; then
            echo "  env override   : CCSWITCH_FABLE_PRIORITY=$CCSWITCH_FABLE_PRIORITY (takes precedence)"
        fi
        echo
        echo "Usage: $0 --fable-priority <on|off>"
        echo "  ON  : Fable 잔량이 tier 보다 우선. Fable 이 남은 계정을 먼저 쓰고,"
        echo "        전부 소진되면 일반 사용량 기준으로 넘어간다."
        echo "  OFF : (기본) adjusted = max(5h,7d)+handicap 만 보고 고른다."
        echo "        Fable 사용량은 표에 계속 표시되지만 선택에는 영향을 주지 않는다."
        return 0
    fi

    local want
    case "$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]')" in
        on|1|true|yes)  want=true ;;
        off|0|false|no) want=false ;;
        *)
            echo "Error: expected 'on' or 'off', got '$arg'"
            exit 1
            ;;
    esac

    local updated
    updated=$(jq --argjson v "$want" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .settings = ((.settings // {}) | .fablePriority = $v) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    if [[ -z "$updated" ]]; then
        echo "Error: failed to update $SEQUENCE_FILE"
        exit 1
    fi
    printf '%s\n' "$updated" > "$SEQUENCE_FILE"

    if [[ "$want" == "true" ]]; then
        echo "Fable priority: ON — Fable 여유가 남은 계정을 우선 선택합니다."
    else
        echo "Fable priority: OFF — 전체 사용량(adjusted) 기준으로 선택합니다."
    fi
    if [[ -n "${CCSWITCH_FABLE_PRIORITY:-}" ]]; then
        echo "Note: CCSWITCH_FABLE_PRIORITY=$CCSWITCH_FABLE_PRIORITY 가 설정돼 있어 이 세션에서는 env 값이 우선합니다."
    fi
}

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
# --switch-lowest 가 지금 할 일을 한 줄("Next target: ...")로 예측한다.
# cmd_switch_lowest 와 같은 규칙(실측 유지·포화·hysteresis)을 따른다.
# --show-usage 와 TUI 가 함께 쓴다 — 예측이 두 군데 있으면 한쪽만 고쳐져
# 표시와 실제 동작이 어긋난다(2026-09: TUI 만 "Account-8" 을 계속 보여 줬다).
# 입력: stdin 에 filter_pool_rows 까지 거친 TSV, $1 = 현재 계정.
predict_next_target() {
    local current="$1" data target target_status
    data=$(cat)
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
        # cmd_switch_lowest 와 동일하게: 현재 계정이 포화면 hysteresis 미적용.
        # 여기서 안 맞추면 표의 "Next target" 과 실제 전환 결과가 어긋난다.
        local cf_p cs_p cur_sat_p=0
        cf_p=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$current" '$1==n{print $3}')
        cs_p=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$current" '$1==n{print $4}')
        [[ "$cf_p" =~ ^[0-9]+$ ]] && (( cf_p >= 100 )) && cur_sat_p=1
        [[ "$cs_p" =~ ^[0-9]+$ ]] && (( cs_p >= 100 )) && cur_sat_p=1
        if (( cur_sat_p == 0 )) && [[ "$current_status_p" == "ok" && "$target_status" != "ok" ]]; then
            echo "Next target: Account-$current (staying — live and healthy; Account-$target has no live data, status=$target_status)"
            return 0
        fi
        if (( cur_sat_p == 0 )) \
           && [[ "$current_status_p" == "ok" && "$target_status" == "ok" \
              && "$current_adj_p" =~ ^[0-9]+$ && "$target_adj_p" =~ ^[0-9]+$ ]]; then
            local delta_p=$((current_adj_p - target_adj_p))
            if (( delta_p < HYSTERESIS_DELTA )); then
                echo "Next target: Account-$current (staying — Account-$target only ${delta_p}%p lower, below ${HYSTERESIS_DELTA}%p threshold)"
                return 0
            fi
        fi
        local target_fable
        target_fable=$(echo "$data" | /usr/bin/awk -F$'\x1f' -v n="$target" '$1==n{print $12}')
        local fable_note=""
        if [[ "$target_fable" =~ ^[0-9]+$ ]] && (( target_fable < 100 )); then
            fable_note=", Fable ${target_fable}%"
        elif [[ "$target_fable" == "100" ]]; then
            fable_note=", Fable 소진"
        fi
        if [[ "$target_status" == "unavailable" ]]; then
            echo "Next target: Account-$target (stale-token refresh)"
        elif is_cold_candidate "$target_five" "$target_five_rem" "$target_seven"; then
            echo "Next target: Account-$target (cold-warmup — 5h window untouched${fable_note})"
        elif [[ "$target_five" == "100" || "$target_seven" == "100" ]]; then
            if [[ "$target_extra" == "true" ]]; then
                echo "Next target: Account-$target (saturated but has extra-usage)"
            else
                echo "Next target: Account-$target (last-resort: all saturated, no extra-usage)"
            fi
        else
            echo "Next target: Account-$target (lowest adjusted${fable_note})"
        fi
    fi
}

cmd_show_usage() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    # Refresh active account's backup in case the user just /login'd. Same
    # silent pattern as cmd_switch_lowest — failure is non-fatal.
    ( cmd_sync_current ) >/dev/null 2>&1 || true

    # Cache reads are enabled here (USAGE_CACHE_TTL) so repeated manual
    # `--show-usage` invocations don't burn API quota. --switch-lowest
    # never sets this var so its decisions still use live data.
    local data
    data=$(CCSWITCH_USE_CACHE=1 gather_all_usage)
    local gather_rc=$?
    if (( gather_rc == 2 )); then
        echo "Aborted: rate-limited by Anthropic API; try again in a moment." >&2
        return 1
    fi
    local current
    # 표는 모든 계정을 보여 주고, `*` 와 아래 Next target 은 지금 풀(--pool) 기준이다.
    current=$(identify_current_account)
    echo "$data" | render_usage_table "$current"
    print_pools_line
    data=$(echo "$data" | filter_pool_rows "$current")

    echo "$data" | predict_next_target "$current"
}

# Perform the actual account switch
perform_switch() {
    local target_account="$1"
    # 이 풀의 계정이 아니거나 다른 풀이 쓰는 중이면 전환하지 않는다(같은 토큰을 두 폴더가 쓰면 한쪽이 무효).
    if [[ "$(identify_current_account)" != "$target_account" ]] && ! pool_eligible "$target_account"; then
        echo "Error: Account-$target_account 는 풀 '$POOL' 에서 쓸 수 없다 (풀의 계정이 아니거나 다른 풀이 쓰는 중)"
        exit 1
    fi

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
    if [[ -z "$current_account" && "$POOL" == "default" ]]; then
        current_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    fi

    # Step 1: Backup current account
    # 자격증명은 토큰 주인의 칸에, 설정은 .claude.json 이 말하는 계정 칸에.
    # 새 풀처럼 지금 계정이 없으면 설정 백업은 건너뛴다(남의 칸을 덮어쓰지 않게).
    local config_path current_config
    config_path=$(get_claude_config_path)
    [[ -f "$config_path" ]] || { mkdir -p "$(dirname "$config_path")"; echo '{}' > "$config_path"; chmod 600 "$config_path"; }
    current_config=$(cat "$config_path")

    backup_live_credentials
    if [[ -n "$current_account" && "$current_account" != "null" && -n "$current_email" ]]; then
        write_account_config "$current_account" "$current_email" "$current_config"
    fi
    
    # Step 2: Retrieve target account
    local target_creds target_config
    target_creds=$(read_account_credentials "$target_account" "$target_email")
    target_config=$(read_account_config "$target_account" "$target_email")
    
    if [[ -z "$target_creds" || -z "$target_config" ]]; then
        echo "Error: Missing backup data for Account-$target_account ($target_email)"
        echo "  → Log in to that account in Claude Code, then run: $0 --add-account"
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
    set_pool_active "$target_account"
    local updated_sequence
    updated_sequence=$(jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.lastUpdated = $now' "$SEQUENCE_FILE")
    write_json "$SEQUENCE_FILE" "$updated_sequence"

    local target_org_uuid target_org_name target_label
    target_org_uuid=$(jq -r --arg num "$target_account" '.accounts[$num].organizationUuid // ""' "$SEQUENCE_FILE")
    target_org_name=$(jq -r --arg num "$target_account" '.accounts[$num].organizationName // ""' "$SEQUENCE_FILE")
    target_label=$(format_org_label "$target_org_name" "$target_org_uuid" "$target_email")

    local from_label
    from_label=$(format_org_label "$current_org_name" "$current_org_uuid" "$current_email")
    notify_switch_macos "${current_email} (${from_label})" "${target_email} (${target_label})"

    echo "Switched to Account-$target_account ($target_email - $target_label)$([[ "$POOL" != "default" ]] && echo " [pool $POOL]")"
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
# 백업 칸의 만료된 토큰을 Claude Code 에게 갱신시킨다(--refresh).
#
# ccswitch 는 토큰을 직접 갱신하지 않는다 — 갱신 규칙을 흉내 내다 틀리면 계정이
# 날아간다. 대신 계정마다 임시 설정 폴더(CLAUDE_CONFIG_DIR)에 백업 토큰을 넣고
# `claude -p` 를 한 번 돌려, Claude Code 가 스스로 갱신하게 한다. 지금 쓰는 세션
# (~/.claude)은 건드리지 않는다.
#
# 갱신된 토큰은 프로필 API 로 그 계정 본인 것인지·더 새것인지 확인한 뒤에만 백업
# 칸에 쓰고, 임시 폴더와 그 키체인 항목은 바로 지운다(같은 토큰을 두 곳에 두면 한쪽
# 갱신이 다른 쪽을 무효로 만든다).
#
# 비용: 계정마다 Haiku 호출 한 번("ok"). 그 계정의 5h 창이 시작된다.
# 제외: 풀이 지금 쓰는 계정(Claude Code 가 관리), 백업 없는 계정, 아직 10분 이상
# 유효한 토큰. 인자로 번호를 주면 그 계정만.
cmd_refresh() {
    [[ -f "$SEQUENCE_FILE" ]] || { echo "Error: No accounts are managed yet"; exit 1; }
    local bin now_ms targets=() active=" " p n
    bin=$(command -v claude || echo "$HOME/.local/bin/claude")
    now_ms=$(( $(date +%s) * 1000 ))
    for p in $(pool_names); do
        n=$(pool_current_account "$p" 2>/dev/null || true)
        [[ -n "$n" ]] && active+="$n "
    done
    # 지금 쓰는 계정을 못 찾으면 멈춘다. 그 계정을 건드리면 쓰고 있는 세션이 흔들린다.
    if [[ "$active" == " " ]]; then
        echo "Error: 지금 쓰는 계정을 확인하지 못해 중단한다."
        exit 1
    fi
    if (( $# > 0 )); then
        targets=("$@")
    else
        targets=($(jq -r '.accounts | keys | map(tonumber) | sort | .[]' "$SEQUENCE_FILE"))
    fi

    local email uuid org creds cfgfile old_exp new_exp D svc out rc new owner first reason stale
    local ok=0 fail=0 skip=0
    # 중간에 끊긴 이전 실행이 남긴 임시 폴더·키체인 항목을 먼저 치운다.
    for stale in "$BACKUP_DIR"/refresh.*; do
        [[ -d "$stale" ]] || continue
        security delete-generic-password -s "$(dir_keychain_service "$stale")" -a "$USER" >/dev/null 2>&1 || true
        rm -rf "$stale"
    done
    # 이번 실행이 도중에 끊겨도(Ctrl-C 등) 임시 폴더에 토큰이 남지 않게.
    REFRESH_TMP=""
    trap 'if [[ -n "$REFRESH_TMP" ]]; then security delete-generic-password -s "$(dir_keychain_service "$REFRESH_TMP")" -a "$USER" >/dev/null 2>&1; rm -rf "$REFRESH_TMP"; fi' EXIT
    for n in "${targets[@]}"; do
        email=$(jq -r --arg n "$n" '.accounts[$n].email // ""' "$SEQUENCE_FILE")
        if [[ -z "$email" ]]; then echo "  Account-$n  없는 계정 — 건너뜀"; skip=$((skip+1)); continue; fi
        if [[ "$active" == *" $n "* ]]; then
            echo "  Account-$n  지금 쓰는 계정 — Claude Code 가 직접 갱신하므로 건너뜀"; skip=$((skip+1)); continue
        fi
        creds=$(read_account_credentials "$n" "$email")
        # config 백업은 수백 KB 라 변수로 읽지 않는다 — ${var//…} 치환이 CPU 를 태워
        # 몇 분씩 멈춘다(account_has_backup 과 같은 함정). 파일째 검사·복사한다.
        cfgfile="$BACKUP_DIR/configs/.claude-config-${n}-${email}.json"
        if [[ -z "${creds//[[:space:]]/}" || ! -s "$cfgfile" ]]; then
            echo "  Account-$n  백업 없음 — 재로그인 후 --add-account 필요"; skip=$((skip+1)); continue
        fi
        old_exp=$(jq -r '.claudeAiOauth.expiresAt // 0' <<<"$creds" 2>/dev/null || echo 0)
        if (( old_exp > now_ms + 600000 )); then
            echo "  Account-$n  아직 유효 — 건너뜀"; skip=$((skip+1)); continue
        fi
        uuid=$(jq -r --arg n "$n" '.accounts[$n].uuid // ""' "$SEQUENCE_FILE")
        org=$(jq -r --arg n "$n" '.accounts[$n].organizationUuid // ""' "$SEQUENCE_FILE")

        D=$(mktemp -d "$BACKUP_DIR/refresh.XXXXXX")
        REFRESH_TMP="$D"
        svc=$(dir_keychain_service "$D")
        cp "$cfgfile" "$D/.claude.json"
        chmod 600 "$D/.claude.json"
        # Claude Code 와 같은 규칙: 키체인이 되면 키체인, 잠겼으면 파일.
        if ! security add-generic-password -U -s "$svc" -a "$USER" -w "$creds" 2>/dev/null; then
            printf '%s' "$creds" > "$D/.credentials.json"
            chmod 600 "$D/.credentials.json"
        fi
        # 실패(갱신 불가 등)해도 set -e 로 스크립트가 죽지 않게 rc 를 따로 받는다.
        rc=0
        out=$(cd "$D" && perl -e 'alarm shift; exec @ARGV' 90 \
            env CLAUDE_CONFIG_DIR="$D" "$bin" -p --model haiku "ok" </dev/null 2>&1) || rc=$?
        new=$(security find-generic-password -s "$svc" -a "$USER" -w 2>/dev/null || true)
        [[ -z "$new" && -f "$D/.credentials.json" ]] && new=$(cat "$D/.credentials.json")
        security delete-generic-password -s "$svc" -a "$USER" >/dev/null 2>&1 || true
        rm -rf "$D"
        REFRESH_TMP=""

        new_exp=$(jq -r '.claudeAiOauth.expiresAt // 0' <<<"$new" 2>/dev/null || echo 0)
        [[ "$new_exp" =~ ^[0-9]+$ ]] || new_exp=0
        owner=$(creds_owner "$new")
        if (( new_exp > old_exp )) && [[ "$owner" == "$uuid"$'\t'"$org" ]]; then
            write_account_credentials "$n" "$email" "$new"
            echo "  Account-$n  ✅ 갱신 ($email, 만료 $(date -r $((new_exp / 1000)) '+%m-%d %H:%M'))"
            ok=$((ok+1))
        else
            first=$( { echo "$out" | grep -v '^Warning: no stdin' || true; } | head -1 | cut -c1-70 )
            if [[ "$out" == *"could not be refreshed"* || "$out" == *"/login"* ]]; then
                reason="refresh 토큰이 이미 죽음 — 이 계정으로 /login 후 --add-account 필요"
            elif (( new_exp <= old_exp )); then
                reason="토큰이 갱신되지 않음"
            else
                reason="갱신된 토큰의 주인이 이 계정이 아님 — 저장 안 함"
            fi
            echo "  Account-$n  ❌ $reason ($email; rc=$rc; ${first:-출력 없음})"
            fail=$((fail+1))
        fi
        sleep 1
    done
    trap - EXIT
    echo
    echo "갱신 $ok · 실패 $fail · 건너뜀 $skip"
}

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

    local current_config
    current_config=$(cat "$(get_claude_config_path)")

    backup_live_credentials
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
exec "${bash_path}" "${script_path}" ${CRON_COMMAND}
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
    <key>StartInterval</key>
    <integer>60</integer>
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
    echo "  schedule: every 60s (--tick): emergency switch if the active"
    echo "            account hits 100%, plus the normal hourly switch at :$(printf '%02d' "$(sweep_minute)")"
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
# ── 풀 명령 ─────────────────────────────────────────────────────────────────

# 풀 폴더로 claude 를 띄운다. 인자는 claude 에 그대로 넘긴다.
# default 풀(~/.claude)은 CLAUDE_CONFIG_DIR 를 비운 채 띄운다(명시하면 키체인 이름이 달라진다).
# 셸의 `claude` 를 이 명령으로 감싸도 되게, 풀을 안 쓰는 맥에서는 그냥 claude 를 실행한다.
cmd_claude() {
    local bin dir
    bin=$(command -v claude || echo "$HOME/.local/bin/claude")
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        exec "$bin" "$@"
    fi
    pool_exists "$POOL" || { echo "Error: 풀 '$POOL' 이 없다 (--pool-list)" >&2; exit 1; }
    dir=$(pool_dir)
    if is_default_dir "$dir"; then
        exec env -u CLAUDE_CONFIG_DIR "$bin" "$@"
    fi
    echo "[ccswitch] pool $POOL · $dir" >&2
    exec env CLAUDE_CONFIG_DIR="$dir" "$bin" "$@"
}

cmd_pool_list() {
    local p cur email
    for p in $(pool_names); do
        cur=$(pool_current_account "$p")
        email=$([[ -n "$cur" ]] && jq -r --arg n "$cur" '.accounts[$n].email' "$SEQUENCE_FILE")
        printf '%s %-10s %-22s 계정 [%s]  지금: %s\n' \
            "$([[ "$p" == "$POOL" ]] && echo '*' || echo ' ')" "$p" "$(pool_dir "$p" | sed "s|^$HOME|~|")" \
            "$(pool_accounts "$p" | tr '\n' ' ' | sed 's/ $//')" "$([[ -n "$cur" ]] && echo "Account-$cur $email" || echo -)"
    done
}

# 새 풀 폴더가 ~/.claude 와 나눠 쓸 것(설정·스킬·플러그인·대화 기록). 로그인·계정 상태
# (.credentials.json·.claude.json)만 폴더마다 따로다.
readonly POOL_SHARED=(settings.json CLAUDE.md skills agents commands hooks output-styles plugins projects history.jsonl keybindings.json)

# 풀의 계정 목록을 정한다. default 도 된다(정하지 않으면 등록된 전부).
cmd_pool_set() {
    local name="${1:-}"
    [[ $# -ge 2 ]] || { echo "Usage: $0 --pool-set <이름> <번호…>"; exit 1; }
    shift
    pool_exists "$name" || { echo "Error: 풀 '$name' 이 없다"; exit 1; }
    local n nums=()
    for n in "$@"; do
        jq -e --arg n "$n" '.accounts[$n]' "$SEQUENCE_FILE" >/dev/null || { echo "Error: Account-$n 이 없다"; exit 1; }
        nums+=("$n")
    done
    local updated
    updated=$(jq --arg p "$name" --argjson a "$(printf '%s\n' "${nums[@]}" | jq -s 'map(tonumber)')" \
        '.pools[$p] = ((.pools[$p] // {}) + {accounts: $a})' "$SEQUENCE_FILE")
    write_json "$SEQUENCE_FILE" "$updated"
    echo "풀 '$name' 계정: ${nums[*]}"
}

# 풀을 더한다: 폴더를 만들고(공유 항목은 ~/.claude 로 링크), 쓸 수 있는 첫 계정으로 전환한다.
cmd_pool_add() {
    local name="${1:-}" dir="${2:-}"
    if [[ -z "$name" || -z "$dir" || $# -lt 3 ]]; then
        echo "Usage: $0 --pool-add <이름> <폴더> <번호…>   예) $0 --pool-add work ~/.claude-work 2 3"
        exit 1
    fi
    shift 2
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ && "$name" != "default" ]] || { echo "Error: 풀 이름은 영문·숫자·-_ 이고 default 는 안 된다"; exit 1; }
    pool_exists "$name" && { echo "Error: 풀 '$name' 이 이미 있다"; exit 1; }
    dir="${dir/#\~/$HOME}"; dir="${dir%/}"
    [[ "$dir" == /* ]] || dir="$PWD/$dir"
    is_default_dir "$dir" && { echo "Error: ~/.claude 는 default 풀의 폴더다"; exit 1; }
    local p
    for p in $(pool_names); do
        [[ "$(pool_dir "$p")" == "$dir" ]] && { echo "Error: $dir 는 풀 '$p' 가 쓰고 있다"; exit 1; }
    done

    mkdir -p "$dir"
    chmod 700 "$dir"
    local it
    for it in "${POOL_SHARED[@]}"; do
        [[ -e "$HOME/.claude/$it" ]] || continue
        if [[ -e "$dir/$it" && ! -L "$dir/$it" ]]; then
            mv "$dir/$it" "$dir/$it.pre-pool"
            echo "  옮김: $dir/$it → $it.pre-pool"
        fi
        ln -sfn "$HOME/.claude/$it" "$dir/$it"
    done
    # 사용자 범위 MCP 서버는 .claude.json 안에 있어 링크할 수 없으므로 복사한다.
    local mcp
    mcp=$(jq -c '.mcpServers // {}' "$HOME/.claude.json" 2>/dev/null || echo '{}')
    if [[ -f "$dir/.claude.json" ]]; then
        jq --argjson m "$mcp" '.mcpServers = $m' "$dir/.claude.json" > "$dir/.claude.json.tmp" && mv "$dir/.claude.json.tmp" "$dir/.claude.json"
    else
        jq -n --argjson m "$mcp" '{mcpServers: $m, hasCompletedOnboarding: true}' > "$dir/.claude.json"
    fi
    chmod 600 "$dir/.claude.json"

    local rel="${dir/#$HOME/\~}" updated
    updated=$(jq --arg p "$name" --arg d "$rel" '.pools[$p] = {dir: $d, accounts: []}' "$SEQUENCE_FILE")
    write_json "$SEQUENCE_FILE" "$updated"
    cmd_pool_set "$name" "$@"

    # 쓸 수 있는 첫 계정(다른 풀이 안 쓰고 백업이 있는 것)으로 전환해 폴더에 로그인 정보를 넣는다.
    local n email
    for n in "$@"; do
        email=$(jq -r --arg n "$n" '.accounts[$n].email' "$SEQUENCE_FILE")
        if ( POOL="$name"; pool_eligible "$n" ) && account_has_backup "$n" "$email"; then
            ( POOL="$name"; perform_switch "$n" >/dev/null )
            echo "풀 '$name' ($rel) 을 만들고 Account-$n ($email) 으로 맞췄다."
            echo "띄우기: $0 --pool $name claude"
            return 0
        fi
    done
    echo "풀 '$name' 을 만들었지만 지금 쓸 수 있는 계정이 없다(모두 다른 풀이 쓰는 중이거나 백업이 없다)."
    echo "다른 풀을 전환해 계정을 비운 뒤: $0 --pool $name --switch-to <번호>"
}

# 풀을 지운다(default 는 못 지움). 폴더의 로그인 정보는 백업 칸으로 되돌린 뒤 폴더에서 지운다 —
# 남겨 두면 그 계정이 다른 풀에서 쓰일 때 같은 토큰이 두 곳에 있게 된다. 폴더 자체는 남긴다.
cmd_pool_remove() {
    local name="${1:-}"
    [[ -n "$name" && "$name" != "default" ]] || { echo "Usage: $0 --pool-remove <이름> (default 제외)"; exit 1; }
    pool_exists "$name" || { echo "Error: 풀 '$name' 이 없다"; exit 1; }
    local dir
    dir=$(pool_dir "$name")
    local unsaved
    unsaved=$( POOL="$name"; backup_live_credentials >/dev/null; echo "$BACKUP_UNSAVED" )
    if [[ "$unsaved" == "1" ]]; then
        echo "Error: 풀 '$name' 폴더의 토큰을 백업 칸에 저장하지 못해 지우지 않았다(지우면 그 계정 로그인을 잃는다)."
        echo "  그 풀로 claude 를 한 번 띄워 토큰을 갱신한 뒤 다시 시도: $0 --pool $name claude"
        exit 1
    fi
    security delete-generic-password -s "$(dir_keychain_service "$dir")" -a "$USER" >/dev/null 2>&1 || true
    rm -f "$dir/.credentials.json"
    local updated
    updated=$(jq --arg p "$name" 'del(.pools[$p])' "$SEQUENCE_FILE")
    write_json "$SEQUENCE_FILE" "$updated"
    echo "풀 '$name' 을 지웠다. 로그인 정보는 백업 칸으로 옮기고 $dir 에서는 지웠다(폴더는 남김)."
}

# ── TUI ─────────────────────────────────────────────────────────────────────
# 인자 없이 `ccswitch.sh`(또는 --tui). 풀별 사용량 표를 보여 주고 키로 전환·실행·설정한다.
# 사용량은 CCSWITCH_TUI_INTERVAL 초(기본 60)마다만 새로 받는다 — 자주 부르면 429 가 난다.
# 동작은 전부 기존 명령 함수를 서브셸로 부른다(오류 exit 이 TUI 를 죽이지 않게).

tui_restore() {
    printf '\e[?25h\e[?1049l'
}

# 키 하나를 읽어 이름으로: UP DOWN ENTER TIMEOUT 또는 그 글자.
tui_read_key() {
    local k rest
    if ! IFS= read -rsn1 -t "$1" k; then
        echo TIMEOUT
        return
    fi
    if [[ "$k" == $'\e' ]]; then
        rest=""
        IFS= read -rsn2 -t 1 rest || true
        case "$rest" in
            '[A') echo UP ;;
            '[B') echo DOWN ;;
            *)    echo ESC ;;
        esac
        return
    fi
    [[ -z "$k" ]] && { echo ENTER; return; }
    echo "$k"
}

# 화면에서 무거운 부분(현재 계정 기준 표·picker·풀 줄)을 한 번 만들어 둔다.
# 화살표는 선택 줄만 바꾸므로 이걸 다시 만들 필요가 없다. 예전엔 키 하나에
# 이 전부와 현재 계정·풀 검사까지 다시 계산해 약 0.3초씩 걸렸고, 누르고 있으면
# 입력이 밀려 끊겼다.
tui_build_view() {
    local data="$1" cur="$2"
    local fable agent pnext next
    fable=$(jq -r 'if .settings.fablePriority then "켬" else "끔" end' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ -f "$AGENT_PLIST" ]]; then agent="켬"; else agent="끔"; fi
    TUI_HEAD=$(printf '\e[1mccswitch\e[0m  풀: \e[1m%s\e[0m (%s)   Fable 우선: %s   자동 전환: %s   사용량: ' \
        "$POOL" "$(pool_dir | sed "s|^$HOME|~|")" "$fable" "$agent")
    TUI_TABLE=$(echo "$data" | render_usage_table "$cur")
    # picker 결과를 그대로 보여 주지 않고, 실제 전환 규칙까지 거친 예측을 보여 준다.
    next=$(echo "$data" | filter_pool_rows "$cur" | predict_next_target "$cur" 2>/dev/null || true)
    [[ $(pool_names | wc -l) -gt 1 ]] && pnext="  p 다음 풀" || pnext=""
    TUI_TAIL=$(
        print_pools_line
        echo
        [[ -n "$next" ]] && echo "자동 전환 판단: ${next#Next target: }"
        printf '\n\e[2m↑↓/번호 선택  Enter 전환  c claude 띄우기%s  r 새로고침  h handicap  f Fable 우선  a 자동 전환  q 끝\e[0m' "$pnext"
    )
    return 0
}

# 만들어 둔 화면에 선택 줄 강조만 입혀 그린다(가벼움).
tui_draw() {
    local sel="$1" status="$2" age="$3" eligible="$4" frame
    frame=$(
        printf '%s%s초 전\n\n' "$TUI_HEAD" "$age"
        # 선택한 줄은 반전, 이 풀에서 못 쓰는 계정은 흐리게.
        printf '%s\n' "$TUI_TABLE" | awk -v sel="$sel" -v ok=" $eligible " '
            NR == 1 { print; next }
            {
                n = ($1 == "*") ? $2 : $1
                line = $0
                if (index(ok, " " n " ") == 0) line = "\033[2m" line "  (이 풀 밖·다른 풀 사용 중)\033[0m"
                if (n == sel) line = "\033[7m" line "\033[0m"
                print line
            }'
        printf '%s\n' "$TUI_TAIL"
        [[ -n "$status" ]] && printf '\n%s\n' "$status"
        true
    )
    # 화면 전체를 지우지(\e[2J) 않고 커서를 맨 위로 옮겨 덮어쓴 뒤, 줄 끝(\e[K)과
    # 화면 끝(\e[J)의 남은 글자만 지운다. 한 번에 써서 깜빡이지 않는다.
    printf '\e[H%s\e[J' "$(printf '%s\n' "$frame" | sed $'s/$/\e[K/')"
    return 0
}

cmd_tui() {
    if [[ ! -t 0 || ! -t 1 ]]; then
        show_usage
        return
    fi
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        cmd_list
        return
    fi
    local interval="${CCSWITCH_TUI_INTERVAL:-60}"
    local data="" fetched=0 now cur sel="" status="" key nums=() eligible n i out v script names view_dirty=1 use_cache=1
    printf '\e[?1049h\e[?25l'
    trap 'tui_restore' EXIT
    trap 'tui_restore; exit 130' INT TERM
    while true; do
        now=$(date +%s)
        if [[ -z "$data" ]] || (( now - fetched >= interval )); then
            printf '\e[H\e[2J사용량을 받는 중…\n'
            data=$(CCSWITCH_USE_CACHE=$use_cache gather_all_usage 2>/dev/null) || true
            use_cache=1
            fetched=$(date +%s)
            view_dirty=1
        fi
        if (( view_dirty )); then
            cur=$(identify_current_account)
            # 표는 계정 번호 순(4,5,…,14)인데 pool_accounts 는 jq keys 라 문자열 순
            # (10,11,…,4,…,9)이다. 그대로 쓰면 화살표가 표와 다른 순서로 움직인다
            # (9 에서 ↓ 가 안 먹고 ↑ 가 8 로 감). 화면과 같은 숫자 순으로 맞춘다.
            nums=($(pool_accounts | sort -n))
            eligible=""
            for n in "${nums[@]}"; do
                if [[ "$n" == "$cur" ]] || pool_eligible "$n"; then eligible+="$n "; fi
            done
            [[ -z "$sel" ]] && sel="${cur:-${nums[0]}}"
            tui_build_view "$data" "$cur"
            view_dirty=0
        fi
        tui_draw "$sel" "$status" "$(( $(date +%s) - fetched ))" "$eligible"
        key=$(tui_read_key 5)
        # 5초간 입력 없음: 자동 전환 등으로 계정이 바뀌었을 수 있으니 다음에 다시 계산.
        [[ "$key" == TIMEOUT ]] && { view_dirty=1; continue; }
        status=""
        # 기본은 다시 계산. 선택만 바꾸는 키(화살표·번호)는 아래에서 0 으로 되돌린다.
        view_dirty=1
        case "$key" in
            q|Q)
                break
                ;;
            UP|k|DOWN|j)
                for i in "${!nums[@]}"; do [[ "${nums[i]}" == "$sel" ]] && break; done
                if [[ "$key" == UP || "$key" == k ]]; then
                    (( i > 0 )) && sel="${nums[i-1]}"
                else
                    (( i + 1 < ${#nums[@]} )) && sel="${nums[i+1]}"
                fi
                view_dirty=0
                ;;
            [0-9])
                for n in "${nums[@]}"; do [[ "$n" == "$key" ]] && sel="$key"; done
                view_dirty=0
                ;;
            ENTER|s)
                if [[ "$sel" == "$cur" ]]; then
                    status="Account-$sel 은 이미 이 풀의 계정이다."
                else
                    printf '\e[H\e[2JAccount-%s 으로 전환 중…\n' "$sel"
                    out=$( (perform_switch "$sel") 2>&1 ) || true
                    status=$(echo "$out" | grep -E '^(Switched|Error)' | head -1)
                    [[ "$status" == Switched* ]] && status="$status — 이 풀의 떠 있는 세션도 다음 토큰 갱신 때 바뀐다."
                fi
                ;;
            c|C)
                script=$(cron_script_path)
                if [[ -n "${TMUX:-}" ]]; then
                    tmux new-window -n "claude:$POOL" "CCSWITCH_POOL='$POOL' '$script' claude" \
                        && status="tmux 새 창에서 claude 를 띄웠다 (풀 $POOL)." \
                        || status="tmux 새 창을 못 열었다."
                else
                    tui_restore
                    trap - EXIT INT TERM
                    cmd_claude
                fi
                ;;
            p|P)
                names=($(pool_names))
                for i in "${!names[@]}"; do [[ "${names[i]}" == "$POOL" ]] && break; done
                POOL="${names[$(( (i + 1) % ${#names[@]} ))]}"
                sel=""
                ;;
            r|R)
                # 직접 누른 새로고침은 캐시를 건너뛰고 API 에서 새로 받는다.
                data=""
                use_cache=0
                ;;
            h|H)
                printf '\e[?25h'
                read -r -p "Account-$sel handicap (0-100): " v || true
                printf '\e[?25l'
                if [[ -n "$v" ]]; then
                    out=$( (cmd_set_handicap "$sel" "$v") 2>&1 ) || true
                    status=$(echo "$out" | tail -1)
                    data=""
                fi
                ;;
            f|F)
                if [[ "$(jq -r '.settings.fablePriority // false' "$SEQUENCE_FILE")" == "true" ]]; then v=off; else v=on; fi
                out=$( (cmd_fable_priority "$v") 2>&1 ) || true
                status="Fable 우선: $v"
                data=""
                ;;
            a|A)
                if [[ -f "$AGENT_PLIST" ]]; then
                    out=$( (cmd_agent_remove) 2>&1 ) || true
                    status="자동 전환을 껐다."
                else
                    out=$( (cmd_agent_install) 2>&1 ) || true
                    status="자동 전환을 켰다 (매분 tick, 매시 $(sweep_minute)분에 전환)."
                fi
                ;;
        esac
    done
    tui_restore
    trap - EXIT INT TERM
}

show_usage() {
    echo "Multi-Account Switcher for Claude Code"
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  --pool <name> <command>                    그 풀에 명령 적용 (기본 default = ~/.claude; CCSWITCH_POOL 도 됨)"
    echo "  (인자 없음) | --tui                         계정 관리판(TUI): 사용량 표·전환·claude 띄우기·설정"
    echo "  claude [claude args]                       풀 폴더로 claude 실행 (default 풀은 CLAUDE_CONFIG_DIR 없이)"
    echo "  --pool-list                                풀 목록·폴더·계정·지금 계정"
    echo "  --pool-add <name> <dir> <num...>           풀 추가 (공유 항목은 ~/.claude 로 링크, 쓸 수 있는 첫 계정으로 전환)"
    echo "  --pool-set <name> <num...>                 풀의 계정 목록 변경 (default 도 가능)"
    echo "  --pool-remove <name>                       풀 삭제 (로그인 정보는 백업 칸으로 되돌림)"
    echo "  --add-account                              Add current account to managed accounts"
    echo "  --remove-account <num>                     Remove account (number only, see --list)"
    echo "  --list                                     List all managed accounts"
    echo "  --switch                                   Rotate to next account in sequence"
    echo "  --switch-to <num|email|\"email (org)\">       Switch to specific account"
    echo "  --switch-lowest                            Switch to the account with lowest adjusted utilization"
    echo "  --tick                                     LaunchAgent tick: emergency switch if active account is 100%, else hourly switch (per-machine minute)"
    echo "  --show-usage                               Print per-account 5h/7d utilization + handicap table"
    echo "  --set-handicap <num> <percent>             Set per-account handicap (0-100); higher = picked less often"
    echo "  --why <command>                            Print picker reasoning to stderr (no API/LLM; e.g. --why --show-usage)"
    echo "  --fable-priority [on|off]                  Prefer accounts with Fable quota left (default: off; no arg = show status)"
    echo "  --set-fable-handicap <num> <percent>       Per-account Fable handicap (0-100); 100 = use that account's Fable last"
    echo "  --sync-current                             Refresh current account's backup from live state"
    echo "  --refresh [num...]                         만료된 백업 토큰을 claude -p 로 갱신 (지금 쓰는 계정 제외, 계정당 Haiku 1회)"
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

    # 모든 명령 앞에 `--pool <이름>` 과 `--why` 를 붙일 수 있다(순서 무관).
    #   --pool <이름> : 해당 풀로 동작
    #   --why         : picker 판단 근거를 stderr 로 출력 (LLM·API 없음)
    while [[ "${1:-}" == "--pool" || "${1:-}" == "--why" ]]; do
        if [[ "$1" == "--why" ]]; then
            CCSWITCH_WHY=1
            export CCSWITCH_WHY
            shift
            continue
        fi
        [[ -n "${2:-}" ]] || { echo "Usage: $0 --pool <name> <command>"; exit 1; }
        POOL="$2"
        shift 2
        if [[ -f "$SEQUENCE_FILE" ]] && ! pool_exists "$POOL"; then
            echo "Error: 풀 '$POOL' 이 없다 (--pool-list)"
            exit 1
        fi
    done

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
        --tick)
            cmd_tick
            ;;
        --show-usage)
            cmd_show_usage
            ;;
        --set-handicap)
            shift
            cmd_set_handicap "$@"
            ;;
        --fable-priority)
            shift
            cmd_fable_priority "${1:-}"
            ;;
        --set-fable-handicap)
            shift
            cmd_set_fable_handicap "$@"
            ;;
        --refresh)
            shift
            cmd_refresh "$@"
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
        claude)
            shift
            cmd_claude "$@"
            ;;
        --pool-list)
            cmd_pool_list
            ;;
        --pool-add)
            shift
            cmd_pool_add "$@"
            ;;
        --pool-set)
            shift
            cmd_pool_set "$@"
            ;;
        --pool-remove)
            shift
            cmd_pool_remove "$@"
            ;;
        --help)
            show_usage
            ;;
        ""|--tui)
            cmd_tui
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
