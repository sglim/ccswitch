---
description: Switch to the account the picker recommends (lowest adjusted utilization). Honors hysteresis.
argument-hint: "[CCSWITCH_HYSTERESIS_DELTA=N]"
---

Run `ccswitch.sh --switch-lowest`. If the user passed `$ARGUMENTS` containing `CCSWITCH_HYSTERESIS_DELTA=...`, prefix the command with that env var:

```bash
CCSWITCH_HYSTERESIS_DELTA=$N ccswitch.sh --switch-lowest
```

Print the output verbatim. The interesting lines:
- `Decision: ...` — what the picker chose and why (tier / hysteresis)
- `Switched to Account-N ...` — actual switch happened
- `already on lowest-usage account` — no-op
- `staying to avoid session churn` — hysteresis blocked the switch

If `Switched to ...` appears, remind the user to **restart Claude Code** for the new account to take effect (Claude Code reads credentials at startup).

If `staying to avoid session churn` appears and the user wants to force the switch anyway, suggest:

```bash
CCSWITCH_HYSTERESIS_DELTA=0 ccswitch.sh --switch-lowest
```

or switch by explicit number with `ccswitch.sh --switch-to <num>`.
