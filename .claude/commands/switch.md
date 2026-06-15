---
description: Picker 추천 계정 (가장 낮은 adjusted 사용량) 으로 전환. Hysteresis 적용.
argument-hint: "[CCSWITCH_HYSTERESIS_DELTA=N]"
---

`ccswitch.sh --switch-lowest` 를 실행. 사용자가 `$ARGUMENTS` 에 `CCSWITCH_HYSTERESIS_DELTA=...` 를 넘겼으면 env var prefix 로 붙임:

```bash
CCSWITCH_HYSTERESIS_DELTA=$N ccswitch.sh --switch-lowest
```

출력은 그대로 보여줄 것. 중요한 줄:
- `Decision: ...` — picker 가 선택한 결과와 이유 (tier / hysteresis)
- `Switched to Account-N ...` — 실제로 switch 발생
- `already on lowest-usage account` — no-op
- `staying to avoid session churn` — hysteresis 가 switch 차단

`Switched to ...` 가 떴으면 **Claude Code 를 재시작** 해야 새 계정이 적용된다고 안내 (Claude Code 는 시작 시점에 credential 을 읽음).

`staying to avoid session churn` 이 떴는데 사용자가 강제 switch 를 원하면:

```bash
CCSWITCH_HYSTERESIS_DELTA=0 ccswitch.sh --switch-lowest
```

또는 `ccswitch.sh --switch-to <num>` 로 명시 지정.
