---
description: 관리 중인 Claude Code 계정 목록 (번호, 이메일, org, handicap). `*` 가 active 표시.
---

`ccswitch.sh --list` 실행. 출력은 그대로.

사용자가 계정을 추가하고 싶다고 하면 `/add` 를 안내. 제거는 `ccswitch.sh --remove-account <num>` — 단 registry 에서만 빠지고 `~/.claude-switch-backup/{configs,credentials}/` 의 백업 파일은 **삭제되지 않음**.
