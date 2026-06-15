# CLAUDE.md — ccswitch

This file is loaded into Claude Code's context whenever you start `claude` from inside this repo. Keep it concise — Claude already has the README.

## What this repo is

ccswitch is a **macOS-only** bash tool that manages multiple Claude Code accounts and auto-switches between them based on Anthropic's `/api/oauth/usage` API.

- Main script: `ccswitch.sh` (~2250 lines, single file, bash 3.2+ compatible)
- Menu-bar widget: `ccswitch-statusbar` (SwiftBar/xbar plugin)
- Installer: `install.sh`

## Convenience slash commands available in this folder

| Slash | What it runs |
|---|---|
| `/usage` | `ccswitch.sh --show-usage` — per-account utilization table |
| `/switch` | `ccswitch.sh --switch-lowest` — switch to picker's recommendation |
| `/list` | `ccswitch.sh --list` — list managed accounts |
| `/add` | `ccswitch.sh --add-account` — add the currently-active account |
| `/handicap` | `ccswitch.sh --set-handicap <num> <pct>` — set per-account handicap |
| `/agent` | `ccswitch.sh --agent-status` — LaunchAgent state via `launchctl print` |
| `/help` | `ccswitch.sh --help` — full command reference |

These are defined in `.claude/commands/*.md` and live only inside this repo.

## When editing the script

- Preserve `set -euo pipefail` semantics. The `USER=${USER:-$(id -un)}` fallback at the top exists specifically because `set -u` was killing cron invocations on macOS where USER is unset — don't remove without a replacement.
- Bash 3.2 target. No associative arrays. macOS's stock `/bin/bash` is 3.2.
- TSV separator inside the script is `\x1f` (ASCII US), not tab — tab gets collapsed by `read -r` with default IFS, dropping empty fields.
- `gather_all_usage` returns: `num<US>email<US>five<US>seven<US>handicap<US>adjusted<US>status<US>five_rem<US>seven_rem<US>has_extra<US>extra_util`. Keep this contract — `pick_from_usage_data`, `render_usage_table`, and `cmd_show_usage` all parse it.
- Adjusted formula: `max(5h, 7d) + handicap − urgency_bonus`. `urgency_bonus = max(0, 48 − binding_window_hours)` when `handicap == 0`, otherwise `0`. `blocked-handicap` check uses raw `max + handicap`, not the urgency-discounted `adjusted`.
- Picker tier order matters: stale > cold > healthy-clean > maxed-extra-alt > maxed-extra > healthy-handicap > maxed-no-extra > blocked-handicap. Tie-break: lowest `adjusted`, then smallest `seven_rem` (with `0` normalized to `+∞` so unknown reset doesn't win), then lowest `num`.
- Hysteresis (`HYSTERESIS_DELTA`, default 10%p) only blocks switches where both current+target are `status=="ok"`. `stale`/`cold`/`estimated`/`blocked-handicap` bypass.

## When testing

- `bash -n ccswitch.sh` for syntax.
- `--show-usage` is the cheapest end-to-end smoke test (uses cache when available).
- Reproduce a cron-like env (the one that historically broke `USER`):
  ```bash
  env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    /opt/homebrew/bin/bash ./ccswitch.sh --switch-lowest
  ```
- Synthetic picker tests: pipe a hand-crafted TSV into `pick_from_usage_data` after sourcing the script (use `bash`, not `zsh` — zsh treats `status` as readonly):
  ```bash
  bash -c 'source ./ccswitch.sh
  printf "3\x1fa@x\x1f0\x1f55\x1f0\x1f55\x1fok\x1f0\x1f120000\x1ffalse\x1f0\n" | pick_from_usage_data ""'
  ```

## When committing

- Korean is fine for commit messages — this is a personal-scale tool.
- Sanity-check `grep -nE "sglim|/Users/" ccswitch.sh ccswitch-statusbar` before pushing — no personal paths should leak.
