---
description: 계정별 사용량 표 출력 (5h / 7d / handicap / adjusted / extra-usage). 10초 API 캐시 활용.
---

`ccswitch.sh --show-usage` 를 실행하고 출력은 그대로 보여줄 것 — 표를 임의로 재해석하지 말 것.

표 뒤에 다음을 짧게 요약:
- 현재 active 인 계정 (`*` 표시된 행)
- picker 가 다음에 switch 할 계정 (`Next target:` 줄)
- 비정상 상태 계정 (`?` 표시, 만료 토큰, blocked-handicap 등)

사용자가 "왜 그 계정을 골랐냐" 물으면 CLAUDE.md / README.md 의 알고리즘 기준으로 설명할 것: target 의 tier, `adjusted` 점수, tie-break (가장 짧은 `seven_rem`, 가장 낮은 num). 문서에 없는 규칙을 만들어내지 말 것.
