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

**풀**(`.pools[이름] = {dir, accounts, active}`, 없으면 `default` = `~/.claude` + 모든 계정): 모든 명령은 전역 `POOL`(`--pool`/`CCSWITCH_POOL`) 기준으로 돈다. 풀에 묶이는 곳은 `get_claude_config_path`·`read_live_store`·`write_credentials`(폴더·키체인 이름)뿐이고, 계정 선택은 `pool_eligible`(풀의 계정 + 다른 풀이 안 쓰는 중)과 `filter_pool_rows` 로 거른다. `cmd_tick` 은 풀마다 서브셸로 `cmd_tick_pool` 을 부른다. `perform_switch` 는 새 풀처럼 지금 계정이 없으면 설정 백업을 건너뛴다(남의 칸 덮어쓰기 방지).

**TUI**(`cmd_tui`, 인자 없음/`--tui`): 동작은 전부 기존 명령 함수를 **서브셸로** 부른다 — 그 함수들의 `exit 1` 이 TUI 를 죽이지 않게. 사용량은 `CCSWITCH_TUI_INTERVAL`(기본 60초)마다만 받는다(짧게 잡으면 429). bash 3.2 의 `read -t` 는 정수 초만 받는다.

**백업이 저장 못 한 토큰**: 풀이 오래 쉬어 access token 이 만료되면 프로필 API 로 주인을 못 확인한다. `backup_live_credentials` 는 refresh token 이 백업 칸과 같으면 넘어가고, 아니면 그 풀 설정 파일의 계정 칸에 더 새 토큰일 때만 쓰고, 그래도 못 쓰면 `BACKUP_UNSAVED=1`. `--pool-remove` 는 이때 지우지 않는다.

wrapper 스크립트(`agent-switch-lowest`, 이름은 레거시)는 `exec ... ${CRON_COMMAND}` 로 `--tick` 을 호출. `CRON_COMMAND` 상수만 바꾸면 wrapper·plist 가 `--agent-install` 재실행 시 함께 갱신됨.

## 이 폴더에서 쓸 수 있는 slash 명령

| Slash | 실행 내용 |
|---|---|
| `/usage` | `ccswitch.sh --show-usage` — 계정별 사용량 표 |
| `/switch` | `ccswitch.sh --switch-lowest` — picker 추천 계정으로 전환 |
| `/list` | `ccswitch.sh --list` — 관리 중인 계정 목록 |
| `/add` | `ccswitch.sh --add-account` — 현재 active 계정 등록 |
| `/handicap` | `ccswitch.sh --set-handicap <num> <pct>` — 계정별 handicap 설정 |
| `/fable` | `ccswitch.sh --fable-priority` — Fable 우선 모드 상태/토글 |
| `/agent` | `ccswitch.sh --agent-status` — LaunchAgent 상태 (`launchctl print`) |
| `/help` | `ccswitch.sh --help` — 전체 명령어 reference |

`.claude/commands/*.md` 에 정의되어 있고 이 레포 안에서만 활성화됩니다.

## 스크립트 수정 시 주의

- `set -euo pipefail` 유지. 상단의 `USER=${USER:-$(id -un)}` fallback 은 cron 환경에서 USER 미설정 시 `set -u` 가 죽이는 회귀를 막기 위해 의도적으로 추가한 거 — 대체 없이 제거 금지.
- Bash 3.2 타겟. associative array 사용 금지. macOS 기본 `/bin/bash` 가 3.2.
- 스크립트 내부 TSV 구분자는 `\x1f` (ASCII US), tab 아님 — tab 은 `read -r` 의 기본 IFS 가 collapse 시켜 빈 필드를 날려버림.
- `gather_all_usage` 출력 contract: `num<US>email<US>five<US>seven<US>handicap<US>adjusted<US>status<US>five_rem<US>seven_rem<US>has_extra<US>extra_util`. 변경 금지 — `pick_from_usage_data`, `render_usage_table`, `cmd_show_usage` 모두 이걸 파싱.
- adjusted 공식: `max(5h, 7d) + handicap − urgency_bonus`. `urgency_bonus = max(0, 48 − binding_window_hours)` (handicap == 0 일 때만, 아니면 0). `blocked-handicap` 검사는 urgency 보정 전 raw `max + handicap` 기준.
- **`ccswitch-statusbar` 도 캐시 롤오버 보정을 똑같이 해야 한다** (`apply_rollover()`). 위젯은 캐시만 읽으므로 보정이 없으면 CLI 와 다른 숫자를 보여준다 — 2026-09 에 위젯이 `7d 59% / Fable 100%` 를 띄웠지만 실제 API 는 `0% / 0%` 였다. 표시 로직(Fable handicap `53+100` 등)도 CLI 와 맞출 것.
- 캐시 롤오버 보정(`status=="estimated"` + `seven_reset <= now`)은 `seven` 뿐 아니라 **`fable` 도 0 으로 되돌려야 한다**. API 에서 Fable 은 `kind=weekly_scoped`/`group=weekly` 이고 `resets_at` 이 `seven_day` 와 마이크로초까지 동일 — 7d 가 롤오버했으면 Fable 도 리셋된 상태다. 이 보정이 없으면 캐시에 남은 `Fable=100` 때문에 방금 주간한도가 리셋된 계정이 소진으로 오인돼 최하위로 밀린다(2026-09 실제 버그).
- TSV 는 13컬럼. 13번째 = **fableHandicap** (`sequence.json` 의 `.accounts[N].fableHandicap`). picker 는 `fable_eff = min(100, fable + fableHandicap)` 를 쓰고, 표시는 raw 값 + `53+100` 형태. tick 의 fast-path 는 캐시에 handicap 이 없으므로 `get_account_fable_handicap()` 으로 별도 조회한다.
- 캐시/`gather_all_usage` 필드가 7개(+TSV 12컬럼)로 늘었다. 7번째 = **Fable %** (`limits[]` 의 `weekly_scoped` + `scope.model.display_name=="Fable"`). 한도 없는 계정은 `-1`.
- **Fable 우선 모드는 기본 off**. `fable_priority_enabled()` 가 게이트 — env `CCSWITCH_FABLE_PRIORITY` > `sequence.json` 의 `.settings.fablePriority` > 기본 false 순. off 면 `cold_fable_num`/`fable_num` 수집기가 아예 채워지지 않아 tier 가 예전 구조로 동작하고, tick 의 fast-path 도 `any_fable_left=0` 이라 skip 분기가 죽는다. **Fable 관련 동작을 건드릴 땐 off 경로가 예전과 동일한지 반드시 확인할 것** (다른 사용자 기본값).
- **TUI: 화살표·번호는 선택만 바꾼다** — `tui_build_view`(현재 계정·풀 검사·표·picker, 약 0.3초)를 다시 부르지 말고 `tui_draw` 로 강조만 다시 입힌다(약 7ms). 상태가 바뀌는 키(전환·설정·새로고침)와 5초 무입력 때만 `view_dirty=1`. 화면은 `\e[2J` 로 지우지 말고 `\e[H` 덮어쓰기 + `\e[K`/`\e[J`. 이동 순서는 표와 같은 숫자 순(`pool_accounts | sort -n`) — jq `keys` 는 문자열 순(10,11,…,4,…,9)이다.
- `--refresh [num...]`: 만료된 백업 토큰을 **Claude Code 가 직접 갱신**하게 한다 — 계정마다 임시 `CLAUDE_CONFIG_DIR` 에 백업 토큰을 넣고 `claude -p --model haiku ok` 한 번. ccswitch 는 갱신 규칙을 흉내 내지 않는다. 갱신된 토큰은 `creds_owner`(프로필 API)로 본인·더 새것인지 확인한 뒤에만 백업 칸에 쓰고, 임시 폴더·키체인 항목은 즉시 삭제(trap + 시작 시 찌꺼기 청소). 지금 쓰는 계정(`pool_current_account <풀>` — 인자로 받는다, 환경변수 아님)은 반드시 제외하고, 못 찾으면 중단. `claude -p` 실패는 `|| rc=$?` 로 받아 `set -e` 에 죽지 않게. `could not be refreshed` 면 refresh 토큰이 이미 죽은 것 → 그 계정으로 /login 후 --add-account.
- **live 키체인은 반드시 `-a "$USER"` 로 읽는다.** Claude Code 는 `(서비스명, 계정속성=사용자명)` 쌍으로 읽고 쓰는데, 같은 서비스명 `Claude Code-credentials` 에 `acct="unknown"` 인 옛 항목이 남아 있으면 `-a` 없는 조회가 그 옛 항목을 먼저 집는다. 2026-09 에 이것 때문에 ccswitch 가 이틀간 현재 로그인 토큰을 못 읽어 **모든 계정이 `accessToken expired`** 로 보였고, 전환 때 백업도 죽은 토큰으로 덮여 계정들이 재로그인을 요구했다.
- **실측으로 멀쩡한 현재 계정을 두고 실측 없는 계정(`estimated`·`unavailable`)으로는 넘어가지 않는다** — `cmd_switch_lowest` 와 `--show-usage` 예측 양쪽. 캐시 추정치는 마지막 조회 이후 쓴 양이 빠져 늘 낮게 나오므로 picker 가 '가장 모르는 계정' 을 고르게 된다. 현재 계정이 포화일 때만 넘어간다.
- `read_account_credentials` 는 macOS 에서 `security find-generic-password` 를 호출한다 — **계정당 ~60ms**. `gather_all_usage` 루프에서 두 번 읽으면 9계정 기준 0.5초가 그냥 늘어난다. 자격증명은 루프에서 한 번만 읽고 `fetch_account_utilization <num> <email> <cred>` 의 3번째 인자로 넘겨 재사용할 것.
- **전환 불가 계정은 picker 에서 완전 제외**. `account_has_backup()` 이 config 백업 파일 존재(`-s`) + 자격증명 비어있지 않음을 확인하고, 아니면 `status="nobackup"` → picker 가 `continue`, `--switch` 라운드로빈도 건너뜀, tick fast-path 도 skip. 키체인 항목이 "있지만 빈 값" 인 경우(로그인 만료)가 실제로 있었고, 캐시 추정치 때문에 `5h=0/7d=0` 으로 보여 최우선 선택 → `perform_switch` 에서 죽었다(2026-09).
  ⚠️ **config 백업(수백 KB)은 어떤 함수에서도 변수로 읽지 말 것** — `account_has_backup()` 과 `cmd_refresh()` 에서 두 번 같은 실수를 했다. 존재 확인은 `-s`, 옮길 땐 `cp`. — 백업 config 는 388KB 이고 `${var//[[:space:]]/}` 치환이 CPU 를 통째로 태워 `--show-usage` 가 무한정 멈춘다. 파일 크기 테스트만 쓴다.
- 한 계정의 429 는 캐시가 있으면 그 계정만 `estimated` 로 대체하고 나머지 조회를 계속한다. 캐시가 없을 때만 `return 2`(전체 중단).
- **표시 경로(`--show-usage`·TUI)는 API 를 아껴 쓴다.** 사용량 캐시 TTL 은 `USAGE_CACHE_TTL`(기본 120초, `CCSWITCH_USAGE_CACHE_TTL` 로 조절, `0` = 강제 조회). 10초였을 때는 `--show-usage` 한 번에 살아 있는 계정 수만큼(9회, 약 8초) 호출했다. tick 이 현재 계정 캐시를 매분 다시 쓰므로 TTL 을 늘려도 늦어지는 건 다른 계정 숫자뿐이다. TUI 의 `r` 은 캐시를 건너뛴다. **판단 경로(`--switch-lowest`)는 캐시를 읽지 않는다** — 이건 바꾸지 말 것.
- `creds_owner()` 는 profile API 결과를 `owner-cache`(토큰 sha256 → uuid, org, 만료시각)에 저장하고 토큰 만료 전까지 재호출하지 않는다. 주인 확인 실패(빈 값)는 캐시하지 않는다. 토큰 원문을 이 파일에 쓰지 말 것.
- `--why` / `CCSWITCH_WHY=1` 은 picker 분류 근거를 **stderr** 로만 낸다(`why` / `why_acct`). stdout 은 `pick_from_usage_data` 의 계약(계정 번호 한 줄)이라 절대 건드리지 않는다. 새 판단을 하지 않고 이미 계산된 값을 찍기만 하므로 결과가 달라지지 않는다 — tier 로직을 바꿀 때 해당 지점의 why 문구도 같이 고칠 것.
- cold-warmup 판정은 `is_cold_candidate()` 하나로 통일한다(picker + 사유 메시지 2곳). 7d 상한은 `COLD_MAX_SEVEN`(기본 90, `CCSWITCH_COLD_MAX_SEVEN`). 예전엔 `seven != "100"` 문자열 비교라 **7d=99% 계정이 cold 로 뽑혀** 전환 직후 100% 로 확인됐다(2026-09). cold 는 5h 클럭을 시작해 두는 투자이므로 주간 여유가 실제로 있어야 의미가 있다.
- Picker tier 순서 (중요): stale > **cold-fable** > **fable-first** > cold > healthy >  ← Fable 잔량이 tier 보다 우선. cold 는 Fable 여유 유무로 둘로 갈라진다(`cold_fable_num` / `cold_num`). 이렇게 안 하면 Fable 100% 계정이 "5h 가 0" 이라는 이유만으로 계속 뽑힌다(2026-08 실제 버그). maxed-extra-alt > maxed-extra > maxed-no-extra > blocked-handicap. healthy 는 handicap 유무로 나누지 않음 — handicap 은 `adjusted` 에만 반영되고, handicap 계정도 adjusted 최저면 healthy tier 에서 선택됨. handicap 의 강한 회피는 blocked-handicap(raw+handicap>=100) 에서만 발동. Tie-break: lowest `adjusted` → smallest `seven_rem` (0 은 `+∞` 로 정규화 — 미상 reset 이 이기지 않게) → lowest `num`.
- adjusted 의 `urgency_bonus` 는 `raw_max < 100` 일 때만 적용. 포화 계정에 보너스를 주면 7d=100 인 죽은 계정이 adjusted 66 으로 보여 hysteresis 가 전환을 막는다(2026-09 실제 버그).
- Hysteresis 는 **현재 계정이 포화(5h/7d ≥ 100)면 우회**. `cmd_switch_lowest` 와 `cmd_show_usage` 양쪽에 같은 검사가 있어야 표의 "Next target" 과 실제 동작이 일치한다.
- Hysteresis (`HYSTERESIS_DELTA`, 기본 10%p) 는 current+target 둘 다 `status=="ok"` 일 때만 switch 차단. `stale`/`cold`/`estimated`/`blocked-handicap` 은 우회.

- **자격증명 저장소는 둘이다**(키체인 `Claude Code-credentials` / 키체인이 잠긴 ssh 세션용 `~/.claude/.credentials.json`). 서로 다른 계정일 수 있다. 백업은 `backup_live_credentials` 로 **토큰 주인(프로필 API `/api/oauth/profile`)의 칸에만** 쓴다. `.claude.json` 의 `oauthAccount` 를 믿고 쓰면 남의 토큰이 들어간다(2026-09: 1·2번 칸이 같은 토큰 → 폐기). 주인 확인 실패·더 오래된 토큰이면 쓰지 않는다.
- live 에 쓸 때(`write_credentials`)는 Claude Code 와 같은 규칙: 키체인이 되면 키체인만, 잠겼으면 파일. 같은 토큰을 두 저장소에 넣지 말 것 — 한쪽이 갱신(회전)하면 다른 쪽이 무효가 된다.
- 풀 폴더 키체인 이름: 기본 폴더는 `Claude Code-credentials`, 그 밖은 `Claude Code-credentials-<sha256(폴더 절대경로) 앞 8자>`. default 풀은 `CLAUDE_CONFIG_DIR` 를 **비운 채** 띄운다(명시하면 접미사 이름을 찾는다). **같은 토큰을 두 저장소·두 풀에 두지 말 것** — 한쪽이 갱신(회전)하면 다른 쪽이 무효가 된다(2026-09-26 실제로 로그인이 풀림). 풀 전환은 백업 칸 ↔ 풀 저장소로 옮기는 것이고, 배타 규칙이 동시 사용을 막는다.

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
