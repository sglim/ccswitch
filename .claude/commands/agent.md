---
description: ccswitch 매시 자동 전환 LaunchAgent 상태 (launchctl print).
---

`ccswitch.sh --agent-status` 실행, 출력 그대로 보여줄 것.

핵심 필드:
- `state = running` — 정상
- `state = not running` — 이것도 정상. agent 는 매시 `:00` 에 한 번 돌고 나머지 시간은 idle 대기.
- `last exit code = 0` — 직전 hourly 실행 성공
- `last exit code = non-zero` — 무언가 실패. `~/.claude-switch-backup/cron.log` tail 로 진단.

이어 쓸만한 관련 명령:
- `ccswitch.sh --agent-kick` — agent 즉시 트리거
- `ccswitch.sh --agent-install` — LaunchAgent 설치/재설치 (스크립트 내 스케줄 수정 후에도 사용)
- `ccswitch.sh --agent-remove` — LaunchAgent 제거 (`~/.claude-switch-backup` 데이터는 보존)
- `ccswitch.sh --cron-log 50` — agent 로그 마지막 50줄

Agent 가 설치 안 된 상태면 해당 메시지가 뜸 — `--agent-install` 이나 README 의 "LaunchAgent vs cron" 섹션으로 안내.
