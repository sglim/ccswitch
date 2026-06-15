---
description: Set per-account handicap (0–100). Higher = picker avoids this account.
argument-hint: "<num> <percent>"
---

Parse `$ARGUMENTS` as two values: account number and handicap percent (0–100).

If the user provided both:
```bash
ccswitch.sh --set-handicap <num> <pct>
```

If they didn't provide arguments, first run `ccswitch.sh --list` so they can see account numbers, then ask which account and what handicap.

What handicap does (so you can explain):

- Added to `max(5h, 7d)` to produce the `Adjusted` score the picker minimizes.
- A `handicap > 0` account is moved from the `healthy-clean` tier to the lower-priority `healthy-handicap` tier — i.e. the picker will use maxed-with-extra accounts before falling back to a handicapped one.
- A handicapped account with `raw_max + handicap >= 100` goes to the very-last-resort `blocked-handicap` tier.
- `urgency_bonus` (the imminent-reset discount) is suppressed on handicapped accounts so the "use less" intent isn't undone by "spend it before reset".

Typical use case: a personal account you'd rather not burn — `--set-handicap 2 30` makes the picker treat it as 30%p more loaded than it really is.

To clear a handicap, set it back to 0.
