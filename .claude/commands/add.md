---
description: 현재 active 인 Claude Code 계정을 관리 대상에 등록. credential + config 스냅샷.
---

`ccswitch.sh --add-account` 실행.

실행 전 확인할 것:
1. 사용자가 지금 Claude Code 에 로그인 상태인가 (`~/.claude/.claude.json` 존재 + `oauthAccount` 필드 보유). 아니면 먼저 `/login` 하라고 안내.
2. 현재 active 인 계정이 사용자가 등록하려는 그 계정인지. ccswitch 는 "지금 active 인 계정" 을 그대로 스냅샷함.

명령 실행 후:
- 다음 비어있는 슬롯에 계정 번호 할당 (`~/.claude-switch-backup/sequence.json`).
- 백업 config + credential 복사, 키체인에 `Claude Code-Account-<N>-<email>` 항목 추가.

여러 계정 등록 흐름: `claude /logout` → 다음 계정 로그인 → `/add` 다시. 반복.

계정이 2개 이상 모이면 `/usage` 로 picker 가 어떻게 점수 매기는지 확인하고 `/switch` 로 최적 계정 전환 가능.
