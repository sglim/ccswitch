---
description: Show macOS LaunchAgent state (launchctl print) for the ccswitch hourly auto-switch.
---

Run `ccswitch.sh --agent-status` and show the output verbatim.

Key fields:
- `state = running` — fine
- `state = not running` — also fine; the agent runs once per hour at `:00`, otherwise it's idle waiting for the next trigger
- `last exit code = 0` — last hourly run succeeded
- `last exit code = non-zero` — something failed; tail `~/.claude-switch-backup/cron.log` to diagnose

Related commands the user might want next:
- `ccswitch.sh --agent-kick` — trigger the agent immediately
- `ccswitch.sh --agent-install` — install/reinstall the LaunchAgent (also use after editing the schedule in the script)
- `ccswitch.sh --agent-remove` — remove the LaunchAgent (does not touch `~/.claude-switch-backup` data)
- `ccswitch.sh --cron-log 50` — last 50 lines of the agent log

If the agent isn't installed, the command will say so — point the user at `--agent-install` or the README's "LaunchAgent vs cron" section.
