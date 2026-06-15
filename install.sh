#!/usr/bin/env bash
# ccswitch installer (macOS).
#
# Usage:
#   ./install.sh                # symlink scripts into ~/.local/bin
#   ./install.sh --agent        # …and install the LaunchAgent
#   ./install.sh --statusbar    # …and install the SwiftBar plugin (if SwiftBar is present)
#   ./install.sh --all          # both of the above
#   ./install.sh --uninstall    # remove symlinks (does NOT touch ~/.claude-switch-backup data)
#
# Idempotent: re-running just refreshes symlinks.

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
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
red() { printf "\033[31m%s\033[0m\n" "$*" >&2; }

# ─────────────────────────────────────────────────────────────────────────────
# Uninstall path
# ─────────────────────────────────────────────────────────────────────────────
if (( uninstall )); then
    for f in ccswitch.sh ccswitch-statusbar; do
        if [[ -L "${BIN_DIR}/${f}" ]]; then
            rm "${BIN_DIR}/${f}"
            yellow "removed symlink ${BIN_DIR}/${f}"
        fi
    done
    if [[ -f "$AGENT_PLIST" ]]; then
        launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
        rm "$AGENT_PLIST"
        yellow "removed LaunchAgent ${AGENT_LABEL}"
    fi
    sb_link="${SWIFTBAR_DIR}/ccswitch.10s.sh"
    if [[ -L "$sb_link" ]]; then
        rm "$sb_link"
        yellow "removed SwiftBar plugin symlink"
    fi
    green "uninstall complete. user data in ~/.claude-switch-backup left intact."
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Platform + dependency checks
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
    red "ccswitch is macOS-only (relies on /usr/bin/security + LaunchAgent + osascript)."
    exit 1
fi

missing=()
for cmd in jq curl bash; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if (( ${#missing[@]} > 0 )); then
    red "missing required dependencies: ${missing[*]}"
    echo "  install with: brew install ${missing[*]}" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Symlink scripts
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "$BIN_DIR"
for f in ccswitch.sh ccswitch-statusbar; do
    src="${REPO_DIR}/${f}"
    dst="${BIN_DIR}/${f}"
    [[ -f "$src" ]] || { red "missing source file: $src"; exit 1; }
    chmod +x "$src"
    ln -sfn "$src" "$dst"
    green "linked ${dst} -> ${src}"
done

case ":$PATH:" in
    *":${BIN_DIR}:"*) ;;
    *) yellow "note: ${BIN_DIR} is not on your PATH yet."
       echo "      add this line to your shell rc:"
       echo "        export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# Optional: LaunchAgent
# ─────────────────────────────────────────────────────────────────────────────
if (( want_agent )); then
    echo
    green "installing LaunchAgent (hourly auto-switch)..."
    "${BIN_DIR}/ccswitch.sh" --agent-install
fi

# ─────────────────────────────────────────────────────────────────────────────
# Optional: SwiftBar plugin
# ─────────────────────────────────────────────────────────────────────────────
if (( want_statusbar )); then
    echo
    if [[ ! -d "$SWIFTBAR_DIR" ]]; then
        yellow "SwiftBar plugin dir not found: $SWIFTBAR_DIR"
        echo "  install SwiftBar first:  brew install --cask swiftbar"
        echo "  then run this with --statusbar again."
    else
        sb_link="${SWIFTBAR_DIR}/ccswitch.10s.sh"
        ln -sfn "${BIN_DIR}/ccswitch-statusbar" "$sb_link"
        green "linked SwiftBar plugin (10s refresh): $sb_link"
        echo "  rename the link to ccswitch.<N>s.sh to change refresh interval"
    fi
fi

echo
green "done. quick start:"
echo "  ccswitch.sh --add-account          # add the currently-logged-in Claude account"
echo "  ccswitch.sh --list                 # then add more by /login + add-account again"
echo "  ccswitch.sh --show-usage           # see per-account utilization"
echo "  ccswitch.sh --switch-lowest        # switch to the lowest-utilization account"
echo "  ccswitch.sh --agent-install        # enable hourly auto-switch (LaunchAgent)"
