---
description: Add the currently-active Claude Code account to managed accounts. Snapshots credentials + config.
---

Run `ccswitch.sh --add-account`.

Preconditions to check before running:
1. The user is logged into Claude Code at this moment (`~/.claude/.claude.json` should exist and have an `oauthAccount` field). If not, tell them to `/login` first.
2. The currently-active account is the one they want to add. ccswitch snapshots whatever is currently active.

After the command runs:
- A new account number is assigned (next free slot in `~/.claude-switch-backup/sequence.json`).
- The backup config and credential are copied; the keychain entry is duplicated under `Claude Code-Account-<N>-<email>`.

To add multiple accounts: `claude /logout` → log into the next account → `/add` again. Repeat.

Once you have ≥ 2 accounts, suggest `/usage` to see how the picker scores them and `/switch` to switch to the best one.
