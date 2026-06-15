---
description: 계정별 handicap 설정 (0–100). 높을수록 picker 가 회피.
argument-hint: "<num> <percent>"
---

`$ARGUMENTS` 를 두 값으로 파싱: 계정 번호 + handicap 퍼센트 (0–100).

둘 다 제공됐으면:
```bash
ccswitch.sh --set-handicap <num> <pct>
```

인자 없이 호출됐으면 먼저 `ccswitch.sh --list` 를 실행해 사용자가 계정 번호를 볼 수 있게 한 후, 어떤 계정에 얼마 설정할지 질문.

Handicap 동작 설명 (필요 시 사용자에게 안내):

- `max(5h, 7d)` 에 더해져서 picker 가 최소화하는 `Adjusted` 점수가 됨.
- `handicap > 0` 계정은 `healthy-clean` tier 에서 우선순위 낮은 `healthy-handicap` tier 로 격하 — 즉 picker 가 maxed-with-extra 계정을 먼저 쓰고, handicap 적용 계정은 그 다음 fallback.
- handicap 계정이 `raw_max + handicap >= 100` 이 되면 최후의 fallback인 `blocked-handicap` tier 로.
- `urgency_bonus` (임박 reset 할인) 는 handicap 적용 계정엔 적용 안 됨 — "덜 써라" 의도와 "임박했으니 써라" 가 충돌하기 때문.

전형적 use case: 덜 쓰고 싶은 개인 계정. `--set-handicap 2 30` 으로 picker 가 30%p 더 부하 있는 것처럼 취급하게 함.

handicap 해제는 0 으로 다시 설정.
