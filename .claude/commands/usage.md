---
description: Show per-account utilization table (5h / 7d / handicap / adjusted / extra-usage). Uses 10s API cache.
---

Run `ccswitch.sh --show-usage` and present the output verbatim — do NOT reinterpret the table.

After the table, briefly summarize:
- which account is currently active (the row marked with `*`)
- which account the picker would switch to next (the `Next target:` line)
- whether any account is in a degraded state (`?` markers, expired tokens, blocked-handicap)

If the user follows up asking *why* a particular account was picked, explain in terms of the algorithm documented in CLAUDE.md / README.md: the tier the target falls into, the `adjusted` score, and any tie-breaks (smallest `seven_rem`, lowest num). Do not invent rules not in those docs.
