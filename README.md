# ccswitch

**[Claude Code](https://docs.claude.com/en/docs/claude-code) 다계정 자동 전환기 — macOS 전용.**

여러 Claude 계정을 자동으로 돌려가며 사용해서, 한 계정의 5시간/주간 한도가 차도 작업이 막히지 않게 합니다. ccswitch 는 지금 시점에 가장 여유가 많은 계정을 골라 Claude Code 에 넘기고, LaunchAgent 로 매시 정각마다 자동 재평가합니다.

> macOS 전용입니다. 로그인 키체인 (`/usr/bin/security`), `launchd`, `osascript` 알림과의 통합이 핵심이라서 그렇습니다. 스크립트 안에 best-effort 수준의 Linux/WSL 분기가 일부 있지만 공식 지원 계획은 없습니다.

---

## 주요 기능

- **다계정 관리** — 각 계정의 OAuth credential + config 를 `~/.claude-switch-backup` 에 안정된 계정 번호로 백업
- **최저 사용량 계정으로 전환** — 관리 중인 모든 계정에 대해 (실제 switch 없이) Anthropic `/api/oauth/usage` 를 호출하고 tier 기반 알고리즘으로 최적 후보 선택
- **계정별 handicap** — 덜 쓰고 싶은 계정 (예: 개인 계정) 에 가중치를 줘서 picker 가 일부러 회피하도록 설정
- **LaunchAgent 매시 자동 전환** — Aqua GUI 세션 안에서 돌기 때문에 키체인 접근과 macOS 알림이 정상 동작 (cron 도 지원되지만 키체인 접근 불가)
- **메뉴바 위젯 (SwiftBar/xbar)** — 캐시 전용 readout 으로 현재 active 계정 + 계정별 5h/7d/extra-usage 표시, 클릭 한 번으로 "최저 계정 전환"
- **새 데몬 없음** — bash 스크립트 하나 + 선택적 plist. 나머지는 시스템의 `launchd` + `security` + `curl` + `jq`

---

## 요구 사항

| | |
|---|---|
| OS | macOS (Darwin) |
| Shell | `/opt/homebrew/bin/bash` 또는 bash 3.2+ |
| 도구 | `jq`, `curl` — `brew install jq curl` |
| Claude Code | 설치되어 있고 최소 1개 계정 로그인 상태 |
| 선택 | 메뉴바 위젯용 [SwiftBar](https://swiftbar.app) |

---

## 설치

```bash
git clone git@github.com:sglim/ccswitch.git ~/repos/ccswitch
cd ~/repos/ccswitch
./install.sh              # ~/.local/bin 에 심볼릭 링크만
./install.sh --agent      # + 매시 정각 LaunchAgent 활성화
./install.sh --statusbar  # + SwiftBar 플러그인 (10초 refresh)
./install.sh --all        # 전부 다
./install.sh --uninstall  # 링크 제거 (~/.claude-switch-backup 데이터는 보존)
```

`~/.local/bin` 이 PATH 에 없다면 추가:

```bash
export PATH="$HOME/.local/bin:$PATH"   # ~/.zshrc 또는 ~/.bashrc 에
```

---

## 빠른 시작

```bash
# 1) 현재 로그인된 Claude Code 계정을 등록:
ccswitch.sh --add-account

# 2) `claude /logout`, 다른 계정으로 로그인 후 등록:
ccswitch.sh --add-account

# 3) 관리하고 싶은 모든 계정에 대해 반복.
ccswitch.sh --list

# 4) 전체 사용량 표 (switch 없이 조회):
ccswitch.sh --show-usage

# 5) 지금 가장 여유 있는 계정으로 전환:
ccswitch.sh --switch-lowest

# 6) 매시 자동 전환 활성화:
ccswitch.sh --agent-install
```

Picker 출력 예시:

```
    #  Email                              5h%  5h-rst   7d%  7d-rst  Handicap  Adjusted  Ext
    1  alice@example.com                   0       -    48   4d10h         0        48  69%
*   2  alice-personal@example.com         20     37m    10   4d18h        30        50  22%
    3  alice-work@example.com              0       -    64    3h7m         0        19    -
Next target: Account-3 (cold-warmup — 5h window untouched)
```

값 옆 `?` 표시는 API 호출 실패 시 (예: 토큰 만료) 로컬 캐시에서 가져온 추정치라는 의미입니다.

---

## 명령어

| 명령 | 설명 |
|---|---|
| `--add-account` | 현재 active 인 Claude Code 계정을 관리 대상으로 등록 |
| `--remove-account <num>` | 관리 대상에서 제거 (백업 데이터는 보존) |
| `--list` | 관리 중인 계정 목록, `*` 는 active 표시 |
| `--switch` | `sequence.json` 순서대로 다음 계정 round-robin |
| `--switch-to <num\|email\|"email (org)">` | 특정 계정으로 전환 |
| `--switch-lowest` | picker 가 추천하는 계정으로 전환 |
| `--show-usage` | 사용량 표 출력 (switch 안 함, 10초 API 캐시 활용) |
| `--set-handicap <num> <pct>` | 계정별 handicap 설정 (0–100); 클수록 picker 가 회피 |
| `--sync-current` | 현재 계정 백업을 live 키체인/config 로 새로고침 |
| `--agent-install` | macOS LaunchAgent 설치 (매시 `:00` 정각) |
| `--agent-status` | `launchctl print` 으로 agent 상태 |
| `--agent-kick` | agent 즉시 트리거 (`launchctl kickstart`) |
| `--agent-remove` | LaunchAgent 제거 (`~/.claude-switch-backup` 보존) |
| `--cron-install` | 레거시: cron 항목 설치 (macOS 에선 키체인 접근 불가 — agent 권장) |
| `--cron-status` / `--cron-log [N]` / `--cron-remove` | 레거시 cron 제어 |
| `--help` | 도움말 |

`--switch-to` 는 계정 번호, 이메일, 또는 같은 이메일이 여러 org 에 속할 경우 `"email (org)"` 형식으로 지정 가능.

---

## Picker 알고리즘

각 계정에 **adjusted 점수**를 부여하고 tier 기반 우선순위로 선택. 낮을수록 좋음.

```
adjusted = max(5h%, 7d%) + handicap − urgency_bonus
urgency_bonus = max(0, 48 − binding_window_hours_until_reset)   # 48h 램프
```

- `binding_window` = 5h/7d 중 사용률이 더 높은 쪽 (먼저 rate-limit 걸리는 윈도우).
- `urgency_bonus` 는 **handicap > 0 일 때는 적용되지 않음** — "덜 써라" 와 "임박했으니 써라" 가 서로 상쇄되는 걸 막기 위함.
- `blocked-handicap` 판정은 **raw** `max + handicap >= 100` 기준 (urgency 보정 전). 임박 reset 보너스로 차단을 우회하는 것 방지.

### Tier (높은 우선순위부터)

| # | Tier | 진입 조건 |
|---|---|---|
| 1 | **stale** | `status=="unavailable"` — 토큰 만료, switch 로 refresh 유도 |
| 2 | **cold** | `5h=0` + `5h_reset` 없음 + `7d != 100` — 5h 클럭 시작 목적 |
| 3 | **healthy-clean** | 두 윈도우 모두 100% 미만, `handicap == 0` |
| 4 | **maxed-with-extra (alt)** | 한 윈도우 100% 이지만 `hasExtraUsageEnabled` 이고 **현재 active 가 아닌** 계정 — 동등 후보 간 round-robin |
| 5 | **maxed-with-extra** | 4번과 동일하나 `current` 가 유일 후보일 때 |
| 6 | **healthy-handicap** | 두 윈도우 100% 미만, `handicap > 0` (maxed-with-extra 소진 후에만 진입) |
| 7 | **maxed-no-extra** | 한 윈도우 100%, extra-usage 없음 |
| 8 | **blocked-handicap** | `handicap > 0 && raw_max + handicap >= 100` — 최후의 fallback |

### Tie-break

각 tier 내부 순서:
1. 가장 낮은 `adjusted`
2. 그 다음 가장 짧은 `seven_rem` (7d 윈도우 reset 임박 계정 우선 — 어차피 곧 cap 갱신될 거니 먼저 소비)
3. 그 다음 가장 낮은 계정 번호 (결정적 fallback)

### Hysteresis

`--switch-lowest` 는 추천 target 이 current 계정 대비 미세하게만 좋을 때 switch 를 생략합니다 (기본 10%p 임계값). 호출별 override:

```bash
CCSWITCH_HYSTERESIS_DELTA=5 ccswitch.sh --switch-lowest
```

`stale`, `cold`, `blocked-handicap` 결정은 **hysteresis 무시** — 계정 자체 이슈를 즉시 해소해야 하기 때문.

---

## LaunchAgent vs cron

| | LaunchAgent (`--agent-install`) | cron (`--cron-install`) |
|---|---|---|
| Aqua 세션 내 실행 | ✓ | ✗ |
| 로그인 키체인 읽기 | ✓ | 키체인 unlock 상태일 때만 |
| macOS 알림 표시 | ✓ | ✗ |
| 재부팅 후 생존 | ✓ | ✓ |
| 스케줄 | 매시 `:00` (`StartCalendarInterval`) | `0 * * * *` |

**macOS 에서는 무조건 LaunchAgent 쓰세요.** cron 경로는 parity 와 edge case 용으로만 남겨둔 거고, macOS cron 은 키체인 접근이 안 돼서 `security find-generic-password` 가 빈 값을 반환하고 모든 fetch 가 실패합니다.

---

## SwiftBar 위젯

선택사항. SwiftBar 먼저 설치 (`brew install --cask swiftbar`) 한 다음:

```bash
./install.sh --statusbar
```

또는 수동:

```bash
ln -s "$HOME/.local/bin/ccswitch-statusbar" \
      "$HOME/Library/Application Support/SwiftBar/Plugins/ccswitch.10s.sh"
```

파일명의 `10s` 접미사가 refresh 간격입니다 — `60s`, `5m` 등으로 변경 가능. 위젯은 `~/.claude-switch-backup/usage-cache/` 만 읽으므로 빈도가 높아도 API 호출 비용 0.

드롭다운에서 두 액션 제공:
- **Show usage (live, hits API)** — 터미널에서 `ccswitch.sh --show-usage`
- **Switch lowest** — `ccswitch.sh --switch-lowest`

---

## 파일 구조

```
~/.claude-switch-backup/
├── sequence.json                          # 계정 레지스트리 (정본)
├── configs/.claude-config-<N>-<email>.json
├── credentials/.claude-credentials-<N>-<email>.json
├── usage-cache/account-<N>                # 10초 TTL, fetch 성공 시마다 갱신
└── cron.log                               # LaunchAgent / cron 출력 sink

~/Library/LaunchAgents/com.ccswitch.auto-switch.plist
```

LaunchAgent 제거 + 심볼릭 링크 uninstall 해도 `~/.claude-switch-backup` 은 **건드리지 않음**. 완전 초기화:

```bash
ccswitch.sh --agent-remove
rm -rf ~/.claude-switch-backup
```

---

## 문제 해결

**"accessToken expired; skipping"** — 해당 계정의 OAuth 토큰 만료. ccswitch 는 토큰 refresh 를 직접 수행하지 않습니다. 그 계정으로 한 번 switch 하면 Claude Code 가 다음 호출 시 refresh 합니다. picker 의 `stale` tier 가 정확히 이런 만료 계정을 우선 선택하도록 설계됨.

**LaunchAgent 가 발동 안 함** — `~/.claude-switch-backup/cron.log` 에서 에러 확인. `ccswitch.sh --agent-status` 로 `launchctl print` 결과 확인, `--agent-kick` 로 수동 트리거.

**`Adjusted` 가 `2` 같이 작게 나옴** — `urgency_bonus` 효과. reset 임박한 계정은 큰 보너스가 차감됨. `handicap > 0` 이면 보너스 자동 억제.

**알림이 안 옴** — "시스템 설정 > 알림 > Script Editor" (osascript 가 Script Editor 로 알림 전송) 가 허용되어 있는지 확인.

**잘 되다가 cron 설치 후 망가짐** — macOS cron 은 `USER` 환경변수 + 키체인 접근이 없음. LaunchAgent 로 재설치: `--cron-remove` 후 `--agent-install`.

---

## License

MIT. `LICENSE` 파일 참조.

[claude-hud](https://github.com/Piebald-AI/claude-hud) 와 동일한 usage API 를 사용하며, 영감도 거기서 받았습니다.
