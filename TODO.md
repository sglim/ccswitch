# TODO

풀 구조(`--pool`, `--pool-add` …) 다음 단계. (2026-09-26 기록)

## 1. TUI — `ccswitch.sh` 만 치면 뜨는 계정 관리판 (진행 중)

- 풀별 사용량 표를 몇 초마다 갱신해서 보여 준다.
- 키로 조작한다: 전환(그 풀 안에서), 새 tmux 창으로 그 풀의 claude 띄우기, 풀 바꿔 보기.
- 설정 화면: handicap, Fable 우선, 자동 전환 켜기·끄기.
- 범위 밖: 원격 접속은 `ssh m5 -t ccswitch.sh` 로 하고, Claude 창들의 상태판은 tmux 훅으로 따로 둔다.

## 2. 모델에 따라 고르기 — `--switch-lowest --model fable|opus`

- 사용량 API(`/api/oauth/usage`)의 모델별 한도는 **Fable 하나뿐**이다(`limits[]` 의 `weekly_scoped`,
  `scope.model.display_name == "Fable"`). `seven_day_opus`·`seven_day_sonnet` 은 null —
  Opus·Sonnet 은 전체 주간 한도(`weekly_all`)와 5시간 한도(`session`)에만 걸린다(2026-09-26 실측).
- 그러므로 풀마다 「이 풀은 Fable 일을 한다 / Opus 일을 한다」를 정해 두고 picker 기준을 바꾼다.
  - fable 풀: Fable 여유 → 5h·7d 순. Fable 이 찬 계정은 제외.
  - opus 풀: 5h·7d 만. Fable 이 남은 계정은 가능하면 fable 풀에 양보한다.
- 지금의 `fablePriority` 는 전역 설정이다 → 풀별 설정(`.pools[이름].model`)으로 옮긴다.

## 3. Claude 플러그인 — 세션 안에서 보는 창구 (선택)

- claude-hud 처럼 상태줄에 「풀 · 지금 계정 · 5h/7d 사용량」 표시.
- `/ccswitch` 슬래시 명령: 표 보기, 이 풀 전환.
- 계정을 바꾸는 방법은 ccswitch 와 같다(풀 저장소의 토큰 교체). 플러그인은 보여 주고 부르는 층일 뿐이다.

## 4. 캐시를 아끼는 전환

- 실측: 계정이 바뀌면 프롬프트 캐시를 못 쓴다(캐시는 계정·조직마다 따로). 7만 토큰 대화를 다른 계정이
  이어 받으면 첫 호출에 68,917 토큰을 새로 캐시에 쓰고, 같은 계정이면 76,396 토큰을 캐시에서 읽었다.
- 풀 전환은 그 폴더의 모든 세션을 옮기므로, 긴 대화가 많은 풀일수록 전환 한 번의 값이 크다.
  hysteresis(기본 10%p)를 풀별로 둘 수 있게 하고, 긴 작업 풀은 크게 잡는다.

## 5. 남은 정리

- 키체인이 잠긴 세션(ssh 에서 뜬 tmux)의 Claude 는 `<풀 폴더>/.credentials.json` 을 쓰고, 에이전트(화면 로그인
  쪽)는 키체인을 바꾼다 → 전환이 세션에 안 닿는다. m1 은 tmux 서버를 화면 로그인 쪽에서 띄워(TmuxLauncher.app)
  해결했다. `claude`/tick 이 이 어긋남을 감지해 알리게 한다.
- `--switch-lowest` 의 「Account-2 only -23%p below」처럼 음수가 나오는 문구(cold 대상일 때) 정리.
- m5 에도 같은 구성을 깐다. m3(회사 9계정)는 풀 하나(default) 그대로.
