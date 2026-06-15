---
description: List all managed Claude Code accounts (number, email, org, handicap). `*` marks active.
---

Run `ccswitch.sh --list`. Show the output verbatim.

If the user asks to add an account, point them at `/add`. To remove, use `ccswitch.sh --remove-account <num>` — this removes from the registry but **does not** delete the backup files in `~/.claude-switch-backup/{configs,credentials}/`.
