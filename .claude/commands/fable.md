---
description: Fable 우선 모드 상태 확인 / 켜기 / 끄기
---

Fable 우선 모드를 확인하거나 토글합니다.

인자가 없으면 현재 상태를, `on`/`off` 를 주면 설정을 바꿉니다.

```bash
ccswitch.sh --fable-priority $ARGUMENTS
```

- **off** (기본) — `adjusted = max(5h,7d)+handicap` 만 보고 계정을 고릅니다. Fable 사용량은 표에 계속 보이지만 선택에는 영향을 주지 않습니다.
- **on** — Fable 잔량이 tier 보다 우선합니다. Fable 여유가 남은 계정을 먼저 쓰고, 전부 소진되면 일반 사용량 기준으로 넘어갑니다.

설정은 `~/.claude-switch-backup/sequence.json` 의 `.settings.fablePriority` 에 저장됩니다.
