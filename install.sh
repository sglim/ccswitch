#!/usr/bin/env bash
# ccswitch 인스톨러 (macOS).
#
# 사용법:
#   ./install.sh                # ~/.local/bin 에 심볼릭 링크
#   ./install.sh --agent        # …+ LaunchAgent 설치
#   ./install.sh --statusbar    # …+ SwiftBar 플러그인 (SwiftBar 가 설치돼 있어야 함)
#   ./install.sh --all          # 위 둘 다
#   ./install.sh --uninstall    # 심볼릭 링크 제거 (~/.claude-switch-backup 데이터는 보존)
#
# 멱등: 재실행해도 심볼릭 링크만 재생성.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
AGENT_LABEL="com.ccswitch.auto-switch"
AGENT_PLIST="${HOME}/Library/LaunchAgents/${AGENT_LABEL}.plist"
SWIFTBAR_DIR="${HOME}/Library/Application Support/SwiftBar/Plugins"

want_agent=0
want_statusbar=0
uninstall=0
for arg in "$@"; do
    case "$arg" in
        --agent)     want_agent=1 ;;
        --statusbar) want_statusbar=1 ;;
        --all)       want_agent=1; want_statusbar=1 ;;
        --uninstall) uninstall=1 ;;
        -h|--help)
            sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "알 수 없는 인자: $arg" >&2; exit 2 ;;
    esac
done

green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
red() { printf "\033[31m%s\033[0m\n" "$*" >&2; }

# ─────────────────────────────────────────────────────────────────────────────
# Uninstall
# ─────────────────────────────────────────────────────────────────────────────
if (( uninstall )); then
    for f in ccswitch.sh ccswitch-statusbar; do
        if [[ -L "${BIN_DIR}/${f}" ]]; then
            rm "${BIN_DIR}/${f}"
            yellow "심볼릭 링크 제거: ${BIN_DIR}/${f}"
        fi
    done
    if [[ -f "$AGENT_PLIST" ]]; then
        launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
        rm "$AGENT_PLIST"
        yellow "LaunchAgent 제거: ${AGENT_LABEL}"
    fi
    sb_link="${SWIFTBAR_DIR}/ccswitch.10s.sh"
    if [[ -L "$sb_link" ]]; then
        rm "$sb_link"
        yellow "SwiftBar 플러그인 심볼릭 링크 제거"
    fi
    green "uninstall 완료. ~/.claude-switch-backup 데이터는 그대로 보존됨."
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# 플랫폼 + 의존성 체크
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
    red "ccswitch 는 macOS 전용입니다 (/usr/bin/security + LaunchAgent + osascript 의존)."
    exit 1
fi

missing=()
for cmd in jq curl bash; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if (( ${#missing[@]} > 0 )); then
    red "필수 의존성 누락: ${missing[*]}"
    echo "  설치 명령:  brew install ${missing[*]}" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 스크립트 심볼릭 링크
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "$BIN_DIR"
for f in ccswitch.sh ccswitch-statusbar; do
    src="${REPO_DIR}/${f}"
    dst="${BIN_DIR}/${f}"
    [[ -f "$src" ]] || { red "원본 파일 없음: $src"; exit 1; }
    chmod +x "$src"
    ln -sfn "$src" "$dst"
    green "링크 생성: ${dst} -> ${src}"
done

case ":$PATH:" in
    *":${BIN_DIR}:"*) ;;
    *) yellow "안내: ${BIN_DIR} 가 PATH 에 없습니다."
       echo "      쉘 rc 파일에 추가하세요:"
       echo "        export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# 선택: LaunchAgent
# ─────────────────────────────────────────────────────────────────────────────
if (( want_agent )); then
    echo
    green "LaunchAgent 설치 중 (매시 자동 전환)..."
    "${BIN_DIR}/ccswitch.sh" --agent-install
fi

# ─────────────────────────────────────────────────────────────────────────────
# 선택: SwiftBar 플러그인
# ─────────────────────────────────────────────────────────────────────────────
if (( want_statusbar )); then
    echo
    if [[ ! -d "$SWIFTBAR_DIR" ]]; then
        yellow "SwiftBar 플러그인 디렉토리를 찾을 수 없습니다: $SWIFTBAR_DIR"
        echo "  먼저 SwiftBar 를 설치하세요:  brew install --cask swiftbar"
        echo "  그 후 --statusbar 로 재실행."
    else
        sb_link="${SWIFTBAR_DIR}/ccswitch.10s.sh"
        ln -sfn "${BIN_DIR}/ccswitch-statusbar" "$sb_link"
        green "SwiftBar 플러그인 링크 생성 (10초 refresh): $sb_link"
        echo "  파일명을 ccswitch.<N>s.sh 로 바꾸면 refresh 간격 조정 가능"
    fi
fi

echo
green "완료. 빠른 시작:"
echo "  ccswitch.sh --add-account          # 현재 로그인된 Claude 계정 등록"
echo "  ccswitch.sh --list                 # 계정 더 추가: /login 후 add-account 반복"
echo "  ccswitch.sh --show-usage           # 계정별 사용량 조회"
echo "  ccswitch.sh --switch-lowest        # 가장 여유 있는 계정으로 전환"
echo "  ccswitch.sh --agent-install        # 매시 자동 전환 활성화 (LaunchAgent)"
