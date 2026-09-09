# CLAUDE.md — ccswitch

이 레포에서 `claude` 를 실행하면 Claude Code 의 컨텍스트에 자동 로드되는 파일입니다. README 가 이미 있으니 여기서는 짧게 — 핵심만.

## 레포 정체

ccswitch 는 **macOS 전용** bash 도구. Anthropic 의 `/api/oauth/usage` API 를 활용해 여러 Claude Code 계정 사이를 자동 전환합니다.

- 메인 스크립트: `ccswitch.sh` (약 2250 줄, 단일 파일, bash 3.2+ 호환)
- 메뉴바 위젯: `ccswitch-statusbar` (SwiftBar/xbar 플러그인)
- 인스톨러: `install.sh`

## 자동화 구조 (cmd_tick)

LaunchAgent 는 `StartInterval 60` 으로 매분 `--tick` 을 실행. `cmd_tick` 은:
1. **긴급 포화**: 현재 계정만 1개 fetch → 5h 또는 7d 가 100% 면 즉시 `cmd_switch_lowest` (hysteresis 강제 off, `CCSWITCH_HYSTERESIS_DELTA=0`).
2. **7d 리셋 fast-path**: 각 계정 캐시의 7d_reset epoch(캐시 field 4)를 확인 — now 가 그 epoch 를 방금(120초 window) 지난 비-current 계정이 있으면 `cmd_switch_to` 로 즉시 그 계정으로. **API 호출 0회** (캐시만 읽음). ⚠️ **이 경로는 picker 를 우회하므로 Fable(캐시 field 7)을 직접 확인한다** — Fable 여유가 남은 계정이 하나라도 있으면 Fable 100% 계정으로는 발동하지 않는다. 이 검사가 없어서 "표는 Fable 우선인데 자동 전환만 계속 Fable 소진 계정으로 가는" 버그가 있었다(2026-09). 120초 window 는 재발동 방지 + stale 캐시(만료 계정의 오래된 reset epoch) 무시 역할.
3. **정기**: `date +%M` 이 `00` 이면 (매시 정각) 일반 `cmd_switch_lowest` (전 계정 sweep).
4. 그 외 분: 무출력 no-op — cron.log 를 조용히 유지하고 분당 API 호출을 active 1개로 제한 (429 회피).

wrapper 스크립트(`agent-switch-lowest`, 이름은 레거시)는 `exec ... ${CRON_COMMAND}` 로 `--tick` 을 호출. `CRON_COMMAND` 상수만 바꾸면 wrapper·plist 가 `--agent-install` 재실행 시 함께 갱신됨.

## 이 폴더에서 쓸 수 있는 slash 명령

| Slash | 실행 내용 |
|---|---|
| `/usage` | `ccswitch.sh --show-usage` — 계정별 사용량 표 |
| `/switch` | `ccswitch.sh --switch-lowest` — picker 추천 계정으로 전환 |
| `/list` | `ccswitch.sh --list` — 관리 중인 계정 목록 |
| `/add` | `ccswitch.sh --add-account` — 현재 active 계정 등록 |
| `/handicap` | `ccswitch.sh --set-handicap <num> <pct>` — 계정별 handicap 설정 |
| `/agent` | `ccswitch.sh --agent-status` — LaunchAgent 상태 (`launchctl print`) |
| `/help` | `ccswitch.sh --help` — 전체 명령어 reference |

`.claude/commands/*.md` 에 정의되어 있고 이 레포 안에서만 활성화됩니다.

## 스크립트 수정 시 주의

- `set -euo pipefail` 유지. 상단의 `USER=${USER:-$(id -un)}` fallback 은 cron 환경에서 USER 미설정 시 `set -u` 가 죽이는 회귀를 막기 위해 의도적으로 추가한 거 — 대체 없이 제거 금지.
- Bash 3.2 타겟. associative array 사용 금지. macOS 기본 `/bin/bash` 가 3.2.
- 스크립트 내부 TSV 구분자는 `\x1f` (ASCII US), tab 아님 — tab 은 `read -r` 의 기본 IFS 가 collapse 시켜 빈 필드를 날려버림.
- `gather_all_usage` 출력 contract: `num<US>email<US>five<US>seven<US>handicap<US>adjusted<US>status<US>five_rem<US>seven_rem<US>has_extra<US>extra_util`. 변경 금지 — `pick_from_usage_data`, `render_usage_table`, `cmd_show_usage` 모두 이걸 파싱.
- adjusted 공식: `max(5h, 7d) + handicap − urgency_bonus`. `urgency_bonus = max(0, 48 − binding_window_hours)` (handicap == 0 일 때만, 아니면 0). `blocked-handicap` 검사는 urgency 보정 전 raw `max + handicap` 기준.
- 캐시/`gather_all_usage` 필드가 7개(+TSV 12컬럼)로 늘었다. 7번째 = **Fable %** (`limits[]` 의 `weekly_scoped` + `scope.model.display_name=="Fable"`). 한도 없는 계정은 `-1`.
- Picker tier 순서 (중요): stale > **cold-fable** > **fable-first** > cold > healthy >  ← Fable 잔량이 tier 보다 우선. cold 는 Fable 여유 유무로 둘로 갈라진다(`cold_fable_num` / `cold_num`). 이렇게 안 하면 Fable 100% 계정이 "5h 가 0" 이라는 이유만으로 계속 뽑힌다(2026-08 실제 버그). maxed-extra-alt > maxed-extra > maxed-no-extra > blocked-handicap. healthy 는 handicap 유무로 나누지 않음 — handicap 은 `adjusted` 에만 반영되고, handicap 계정도 adjusted 최저면 healthy tier 에서 선택됨. handicap 의 강한 회피는 blocked-handicap(raw+handicap>=100) 에서만 발동. Tie-break: lowest `adjusted` → smallest `seven_rem` (0 은 `+∞` 로 정규화 — 미상 reset 이 이기지 않게) → lowest `num`.
- Hysteresis (`HYSTERESIS_DELTA`, 기본 10%p) 는 current+target 둘 다 `status=="ok"` 일 때만 switch 차단. `stale`/`cold`/`estimated`/`blocked-handicap` 은 우회.

## 테스트

- `bash -n ccswitch.sh` — syntax 체크
- `--show-usage` — 가장 가벼운 end-to-end smoke test (캐시 활용)
- cron 환경 재현 (역사적으로 `USER` 회귀가 발생했던 환경):
  ```bash
  env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    /opt/homebrew/bin/bash ./ccswitch.sh --switch-lowest
  ```
- Picker 단위 테스트 (수작업 TSV 입력). zsh 는 `status` 가 readonly 라 반드시 `bash` 사용:
  ```bash
  bash -c 'source ./ccswitch.sh
  printf "3\x1fa@x\x1f0\x1f55\x1f0\x1f55\x1fok\x1f0\x1f120000\x1ffalse\x1f0\n" | pick_from_usage_data ""'
  ```

## 커밋 시

- 커밋 메시지는 한글로.
- push 전 sanity 체크: `grep -nE "sglim|/Users/" ccswitch.sh ccswitch-statusbar` — 개인 경로 누출 없어야 함.
