# ccswitch

**Multi-account switcher for [Claude Code](https://docs.claude.com/en/docs/claude-code) — macOS only.**

Cycle through several Claude accounts automatically so a single 5h or weekly cap on one account doesn't block you. ccswitch picks the account with the most headroom right now, hands it to Claude Code, and (optionally) re-checks every hour via a LaunchAgent.

> macOS-only by design. The whole point is integrating with the login keychain (`/usr/bin/security`), `launchd`, and `osascript` notifications. There is no plan to support Linux/WSL beyond what's already in the script as best-effort.

---

## What it does

- **Manages multiple Claude Code accounts** — backs up each account's OAuth credential + config into `~/.claude-switch-backup`, keyed by a stable account number.
- **Switches by lowest utilization** — calls Anthropic's `/api/oauth/usage` for every managed account (without switching to them) and picks the best candidate using a tiered algorithm.
- **Per-account handicap** — mark accounts you want to use less (e.g. a personal account); the picker treats them as if they were `+N%` more loaded.
- **Hourly auto-switch via LaunchAgent** — runs inside the Aqua GUI session so keychain access and macOS notifications Just Work. (cron is supported too but loses keychain access.)
- **Menu-bar widget (SwiftBar/xbar)** — cache-only readout of the current account + per-account 5h / 7d / extra-usage saturation, with one-click "switch to lowest".
- **Zero new daemons** — single bash script plus an optional plist; everything else is your system's `launchd` + `security` + `curl` + `jq`.

---

## Requirements

| | |
|---|---|
| OS | macOS (Darwin) |
| Shell | `/opt/homebrew/bin/bash` or any bash 3.2+ |
| Tools | `jq`, `curl` — `brew install jq curl` |
| Claude Code | installed and logged in to at least one account |
| Optional | [SwiftBar](https://swiftbar.app) for the menu-bar widget |

---

## Install

```bash
git clone git@github.com:sglim/ccswitch.git ~/repos/ccswitch
cd ~/repos/ccswitch
./install.sh              # symlinks scripts into ~/.local/bin
./install.sh --agent      # …and enables hourly LaunchAgent
./install.sh --statusbar  # …and links the SwiftBar plugin (10s refresh)
./install.sh --all        # both
./install.sh --uninstall  # remove symlinks (preserves ~/.claude-switch-backup)
```

Make sure `~/.local/bin` is on your PATH:

```bash
export PATH="$HOME/.local/bin:$PATH"   # add to ~/.zshrc or ~/.bashrc
```

---

## Quick start

```bash
# 1) Add the account you're currently logged into Claude Code with:
ccswitch.sh --add-account

# 2) `claude /logout`, log in to another account, then add it too:
ccswitch.sh --add-account

# 3) Repeat for every account you want managed.
ccswitch.sh --list

# 4) See utilization across all of them (no switching):
ccswitch.sh --show-usage

# 5) Pick the best one right now:
ccswitch.sh --switch-lowest

# 6) Enable hourly auto-switch:
ccswitch.sh --agent-install
```

The picker prints a per-account table like this:

```
    #  Email                              5h%  5h-rst   7d%  7d-rst  Handicap  Adjusted  Ext
    1  alice@example.com                   0       -    48   4d10h         0        48  69%
*   2  alice-personal@example.com         20     37m    10   4d18h        30        50  22%
    3  alice-work@example.com              0       -    64    3h7m         0        19    -
Next target: Account-3 (cold-warmup — 5h window untouched)
```

Cells with `?` are last-known values from the local cache (used when a token has expired and ccswitch couldn't reach the API).

---

## Commands

| Command | Description |
|---|---|
| `--add-account` | Snapshot the currently-active Claude Code account into managed storage |
| `--remove-account <num>` | Remove a managed account (data stays in backup dir) |
| `--list` | List managed accounts, with `*` marking the active one |
| `--switch` | Round-robin to the next account in `sequence.json` |
| `--switch-to <num\|email\|"email (org)">` | Switch to a specific account |
| `--switch-lowest` | Switch to the account the picker recommends |
| `--show-usage` | Print the utilization table (no switch); reuses 10s API cache |
| `--set-handicap <num> <pct>` | Set per-account handicap (0–100); higher = picked less often |
| `--sync-current` | Refresh active account's backup from live keychain/config |
| `--agent-install` | Install the macOS LaunchAgent (hourly, `:00` mark) |
| `--agent-status` | `launchctl print` for the agent |
| `--agent-kick` | Trigger the agent immediately (`launchctl kickstart`) |
| `--agent-remove` | Remove the LaunchAgent (preserves `~/.claude-switch-backup`) |
| `--cron-install` | Legacy: install a `crontab` entry (loses keychain access — prefer agent) |
| `--cron-status` / `--cron-log [N]` / `--cron-remove` | Legacy cron control |
| `--help` | Help screen |

`--switch-to` accepts an account number, an email, or `"email (org)"` if the same email appears under multiple orgs.

---

## Picker algorithm

The picker assigns each account an **adjusted score** and walks tiered priority bands. Lower adjusted = better.

```
adjusted = max(5h%, 7d%) + handicap − urgency_bonus
urgency_bonus = max(0, 48 − binding_window_hours_until_reset)   # 48h ramp
```

- `binding_window` = whichever of 5h/7d is currently the larger utilization (the one that will rate-limit you first).
- `urgency_bonus` is **suppressed when handicap > 0** — handicap says "use less", urgency says "use more"; the two would cancel each other otherwise.
- `blocked-handicap` tier uses **raw** `max + handicap >= 100`, not the urgency-discounted adjusted, so a handicapped account near reset can't sneak under the block.

### Tiers (highest priority first)

| # | Tier | Trigger |
|---|---|---|
| 1 | **stale** | `status=="unavailable"` — token expired, refresh by switching to it |
| 2 | **cold** | `5h=0` and no `5h_reset` and `7d != 100` — start the 5h clock |
| 3 | **healthy-clean** | both windows < 100, `handicap == 0` |
| 4 | **maxed-with-extra (alt)** | some window at 100% but `hasExtraUsageEnabled` — and *not* the current account, to round-robin between equally-eligible ext accounts |
| 5 | **maxed-with-extra** | same as 4 but `current` is the only candidate |
| 6 | **healthy-handicap** | both windows < 100, `handicap > 0` (used only after maxed-with-extra is exhausted) |
| 7 | **maxed-no-extra** | some window at 100%, no extra-usage |
| 8 | **blocked-handicap** | `handicap > 0 && raw_max + handicap >= 100` — last resort fallback |

### Tie-breaks

Within each tier:
1. lowest `adjusted`
2. then smallest `seven_rem` (account whose 7d window resets soonest is preferred — its cap is about to refresh anyway, so spend it)
3. then lowest account number (deterministic fallback)

### Hysteresis

`--switch-lowest` skips the switch if the recommended target is only marginally better than the current account (default: within 10 percentage points). Override per-invocation:

```bash
CCSWITCH_HYSTERESIS_DELTA=5 ccswitch.sh --switch-lowest
```

`stale`, `cold`, and `blocked-handicap` decisions **bypass hysteresis** — those signal an account issue worth fixing immediately.

---

## LaunchAgent vs cron

| | LaunchAgent (`--agent-install`) | cron (`--cron-install`) |
|---|---|---|
| Runs inside Aqua session | ✓ | ✗ |
| Can read login keychain | ✓ | only while login keychain is unlocked |
| Can show macOS notifications | ✓ | ✗ |
| Survives reboot | ✓ | ✓ |
| Schedule | `:00` of every hour (`StartCalendarInterval`) | `0 * * * *` |

**On macOS, always use the LaunchAgent.** The cron path is kept for parity and edge cases; cron on macOS can't reach the keychain so `security find-generic-password` returns empty and every fetch fails.

---

## SwiftBar widget

Optional menu-bar readout. Install SwiftBar first (`brew install --cask swiftbar`), then either:

```bash
./install.sh --statusbar
```

or manually:

```bash
ln -s "$HOME/.local/bin/ccswitch-statusbar" \
      "$HOME/Library/Application Support/SwiftBar/Plugins/ccswitch.10s.sh"
```

The `10s` suffix is the refresh interval — change it to `60s`, `5m`, etc. The widget reads from `~/.claude-switch-backup/usage-cache/` only, so high refresh rates cost zero API calls.

The dropdown has two actions:
- **Show usage (live, hits API)** — runs `ccswitch.sh --show-usage` in a terminal
- **Switch lowest** — runs `ccswitch.sh --switch-lowest`

---

## File layout

```
~/.claude-switch-backup/
├── sequence.json                          # canonical account registry
├── configs/.claude-config-<N>-<email>.json
├── credentials/.claude-credentials-<N>-<email>.json
├── usage-cache/account-<N>                # 10s TTL, fed by every successful fetch
└── cron.log                               # LaunchAgent / cron output sink

~/Library/LaunchAgents/com.ccswitch.auto-switch.plist
```

Removing the LaunchAgent and uninstalling the symlinks does **not** touch `~/.claude-switch-backup`. To wipe state:

```bash
ccswitch.sh --agent-remove
rm -rf ~/.claude-switch-backup
```

---

## Troubleshooting

**"accessToken expired; skipping"** — the OAuth token for that account expired. ccswitch doesn't refresh tokens itself; switch to that account once (Claude Code refreshes on first real call) or run `claude` interactively on it. The picker has a `stale` tier that prioritizes expired-token accounts for exactly this purpose.

**LaunchAgent never fires** — check `~/.claude-switch-backup/cron.log` for any errors. Run `ccswitch.sh --agent-status` to see `launchctl print` output and `--agent-kick` to trigger it manually.

**`Adjusted` shows tiny numbers like `2`** — that's `urgency_bonus` at work. An account near its reset gets a big bonus subtracted. If `handicap > 0` the bonus is suppressed automatically.

**Notifications stopped working** — check "System Settings > Notifications > Script Editor" (osascript posts via Script Editor) is allowed.

**Used to work, broke after `cron` install** — macOS cron lacks `USER`/keychain access. Reinstall the LaunchAgent: `--cron-remove` then `--agent-install`.

---

## License

MIT. See `LICENSE`.

Inspired by — and uses the same usage API as — [claude-hud](https://github.com/Piebald-AI/claude-hud).
