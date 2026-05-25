---
name: cucp-computer-use
description: Use the local CUCP (Computer Use Control Plane) CLI from any Codex project to observe, ground, and operate the user's Windows desktop at Claude Computer Use grade. Trigger on cucp, CUP, computer use, computer-use, Windows control, desktop control, appshot, snapshot, live benchmark, desktop benchmark, screen control, GUI automation, PC/app control, "컴퓨터 유즈", "컴퓨터 사용", "컴퓨터 조작", "내 컴퓨터 조작", "내 컴퓨터를 조작", "내 PC 조작", "앱 조작", "윈도우 조작", "화면 조작", "데스크톱 자동화", "자동화 실행", "GUI 자동화", "라벨 클릭", "버튼 클릭해줘", or whenever the user asks Codex to inspect, click, type, drag, scroll, switch apps, follow a goal, or autonomously operate the local Windows desktop.
---

# CUCP Computer Use (Claude-grade)

This skill turns the local CUCP CLI into a Claude Computer Use grade agent loop. It adds three things on top of the raw CLI:

1. **Observation cache** with automatic `--after <observation-id>` injection.
2. **Label-based grounding** — click and type by visible UI text. Uses CUCP's fused/grounded elements when available, and **falls back to a native UI Automation tree walk** (PowerShell + UIAutomationClient) so label grounding works even when the host build's fusion layer is empty.
3. **Composite macros** — `wait-window`, `click-label`, `click-id`, `fill-label`, `focus-window`, `wait-label`, `shortcut`, and a goal loop (`goal`) with self-verification.

CUCP CLI path:

```powershell
C:\Users\bark\Documents\Codex\2026-05-22\new-chat\src\cli.mjs
```

Wrapper (use this for every call from any project):

```powershell
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 [-AllowLiveControl] [-Brief] [-CacheSeconds <n>] [-InvokeTimeoutMs <n>] <args>
```

Audit logs and artifacts are under:

```text
C:\Users\bark\AppData\Local\Temp\computer-use-control-plane
```

## When to Activate

- 관찰: 현재 화면, 활성 창, 특정 앱 상태, 보이는 UI 라벨/요소를 캡처/분석.
- 조작: 클릭, 우클릭, 더블클릭, 드래그, 스크롤, 텍스트 입력, 단축키, 윈도우 전환.
- 라벨 grounding: "확인 버튼 눌러줘", "Save 버튼 클릭", "이름 필드에 입력" 같은 자연어 지시.
- 시나리오/플랜 실행: JSON plan 검증·드라이런·실행, 시나리오 실행, 데스크톱 벤치마크.
- 자율 실행: L5 컴퓨터 유즈로 목표 기반 자동 수행 (`macro goal --objective "..."`).

## Operating Loop (Observe → Think → Act → Verify)

이 루프는 Claude Computer Use가 사용하는 패턴이에요. 모든 작업을 이 4단계로 진행:

1. **Observe** — `observe appshot --match "<app>" --semantic` 또는 매크로 `find-label`.
2. **Think** — fused_elements에서 라벨/역할 매칭, 의도와 가능한 행동을 짧게 정리.
3. **Act** — `macro click-label`/`fill-label`/`shortcut` 같은 라벨 기반 매크로를 우선 사용. 좌표는 라벨이 없을 때만.
4. **Verify** — 직후 또 한 번 `observe appshot`. 변경된 상태(타이틀, 새 다이얼로그, 새 텍스트)가 보이는지 확인.

루프가 막히면:
- 라벨이 안 잡히면 `--match` 좁히기, 캐시 비우기 (`macro session clear-cache`), 다시 관찰.
- 클릭은 됐는데 결과가 없으면 윈도우 포커스 잃었을 가능성. `macro focus-window --name "<title>"` 후 재관찰.
- 모달이 떴으면 무조건 멈추고 사용자 승인.

## Safety Defaults

- 기본은 read-only: `observe appshot`, `observe context`, `observe windows`, `observe screenshot`.
- 라이브 컨트롤 분류: 모든 `act ...`, `app switch`, `plan run`, `scenario run --execute`, `desktop benchmark run --live`(--preflight-only 없이), `desktop benchmark collect --live`(--preflight-only 없이), `desktop benchmark runbook --allow-live-control`, `l5 ... --allow-control`, `l5 run`, 그리고 모든 매크로 중 actuation 동반(`click-label`/`fill-label`/`focus-window`/`shortcut`/`goal`).
- 모든 라이브 명령은 `-AllowLiveControl` 플래그 필수. 없으면 래퍼가 사전 차단.
- 좌표 기반 `act`는 항상 `--after <observation-id>`. 매크로는 자동 처리. 직접 호출할 땐 `observe`를 먼저.
- UAC, 비밀번호, 결제, 개인 메시지, 자격 증명 다이얼로그는 사용자가 그 행동을 명시 허락한 경우에만.
- 비밀, 토큰, 라이선스, OTP는 사용자가 직접 제공한 경우에만 입력.
- 라이브 작업 후 세션 리스 해제:

```powershell
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 desktop session release --lease-file <lease.json> --force
```

## Macro Reference (claude-grade)

### find-label (read-only)

라벨/역할로 요소 위치를 찾고 좌표/윈도우/observation_id를 반환. CUCP fusion이 비어 있으면 PowerShell UIAutomation으로 자동 폴백.

```powershell
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro find-label --label "확인" --window "XG5000"
```

옵션: `--label` (필수), `--window` (제목 일부), `--match` (appshot 필터, 기본은 window), `--role` (button/edit/etc).

`-Brief`를 붙이면 한 줄 요약: `ok find-label '확인' @(120,80) win='XG5000'`.

### list-affordances (read-only)

현재 화면에서 클릭 가능한 모든 요소 목록 (영문/한글 라벨 모두). 모델이 무엇을 클릭할 수 있는지 한 번에 조망할 때 사용.

```powershell
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro list-affordances --window "설정" --limit 20
```

각 항목에 `affordance_id`, `text`, `role`, `window`, `center` 좌표, `confidence`, `sources` 포함.

### click-id (live)

affordance_id로 직접 클릭 (라벨이 중복되거나 라벨 매칭이 모호할 때).

```powershell
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 -AllowLiveControl macro click-id --id "aff:설정:단추:시작:0-1032-55-48:uia"
```

### click-label / double-click-label / right-click-label (live)

```powershell
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 -AllowLiveControl macro click-label --label "Save" --window "Notepad"
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 -AllowLiveControl macro double-click-label --label "MyFile.txt" --window "File Explorer"
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 -AllowLiveControl macro right-click-label --label "Item" --window "ListView"
```

옵션: `--label`(필수), `--window`, `--match`, `--role`, `--offset-x <n>`, `--offset-y <n>`(라벨 중심에서 오프셋).

매크로가 자동으로:
1. fresh appshot 캡처
2. fused_elements에서 라벨 매칭 (UIA + OCR + screenshot 융합)
3. 매칭 요소 중심 좌표 계산
4. observation_id를 자동으로 `--after`에 주입
5. 적절한 `act` 호출 (target-window 자동 설정)

### fill-label (live)

라벨 매칭 위치를 클릭하고 텍스트 입력.

```powershell
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 -AllowLiveControl macro fill-label --label "Name" --text "Alice" --clear --enter
```

옵션: `--label`(필수), `--text`(필수), `--window`, `--clear`, `--enter`.

### focus-window (live)

윈도우/프로세스 이름으로 포커스 이동.

```powershell
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 -AllowLiveControl macro focus-window --name "XG5000"
```

### wait-window (read-only)

윈도우가 보일 때까지 대기 (앱 실행 직후 등).

```powershell
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro wait-window --title "XG5000" --timeout-ms 10000 --interval-ms 500
```

### wait-label (read-only)

특정 라벨이 화면에 등장할 때까지 폴링 (다이얼로그 열림 / 작업 완료 신호 대기에 유용).

```powershell
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro wait-label --label "다운로드 완료" --window "XG5000" --timeout-ms 30000
```

### shortcut (live)

```powershell
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 -AllowLiveControl macro shortcut --keys "ctrl+s"
```

자주 쓰는 키: `ctrl+c`, `ctrl+v`, `ctrl+s`, `ctrl+shift+s`, `alt+tab`, `alt+f4`, `win+e`, `win+d`, `enter`, `tab`, `escape`, `f1`–`f12`. 한글 IME 토글은 보통 `win+space`(시스템 설정).

### goal (live, autonomous)

목표 자연어를 받아 L5 자율 실행. **자가 검증** 옵션 포함: 실행 후 특정 라벨이 등장하는지 자동 확인.

```powershell
# 드라이런으로 계획만 미리보기
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro goal --objective "Open Notepad and type hello world" --dry-run

# 실제 실행 + 자가 검증
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 -AllowLiveControl macro goal `
    --objective "Open Notepad and type hello world" `
    --max-steps 60 --max-phase-ms 600000 --provider heuristic `
    --verify-label "Notepad" --verify-timeout-ms 10000
```

옵션: `--objective` (필수), `--max-steps`, `--max-phase-ms`, `--provider heuristic|codex`, `--dry-run`, `--verify-label`, `--verify-window`, `--verify-timeout-ms`.

종료 코드: 0=성공+검증통과, 1=실행실패, 2=실행성공이지만 verify-label 미발견.

### self-test (read-only)

스킬과 helper backend의 동작을 자체 검증. CI/배포 직후 sanity check에 사용. **계층별로 결과를 분리**하므로 helper가 꺼져 있어도 wrapper/cli/uia 계층은 깔끔히 통과로 보고됩니다.

```powershell
# 빠른 검증 (wrapper + cli + helper)
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro self-test

# 풀 검증 (UIA fallback + appshot 캡처 포함)
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro self-test --deep

# strict 모드: skipped도 실패로 간주 (helper 가동을 강제하고 싶을 때)
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro self-test --deep --strict

# 한 줄 요약 (모델 루프용)
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 -Brief macro self-test
# 출력 예: ok self-test passed=3/6 skipped=3 failed=0
```

검증 항목 (계층 분리):

| 계층 | 항목 | helper 필요 | 검증 내용 |
|---|---|---|---|
| `wrapper` | `live_gate_blocks` | ✗ | -AllowLiveControl 없으면 라이브 차단 |
| `wrapper` | `coord_gate_requires_after` | ✗ | 좌표 act에 --after 강제 |
| `cli` | `cli_version` | ✗ | CUCP CLI 응답 확인 |
| `helper` | `helper_tools` | ✓ | Windows-MCP HTTP 가용성 |
| `helper` | `observe_windows` | ✓ | 윈도우 목록 캡처 |
| `helper` | `cache_hit` | ✓ | 관찰 캐시 동작 |
| `uia` | `uia_fallback` (deep) | ✗ | PowerShell UIAutomation 단독 검증 |
| `helper` | `appshot_fullscreen` (deep) | ✓ | 의미론적 캡처 + affordance 추출 |

종료 코드:
- `0`: 모든 ok 항목 통과 (skipped 허용)
- `1`: 하나 이상 fail (또는 strict + skipped)

helper가 꺼져있다면 출력의 `summary` 필드가 `cucp start` 안내를 포함합니다.

### session (read-only)

```powershell
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro session info
& C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro session clear-cache
```

### trajectory (read-only, working memory)

직전 관찰/행동을 NDJSON으로 영속 기록. 모델이 직전 N개 step을 working memory처럼 사용.

```powershell
# 최근 20개 trajectory 항목
& <wrapper> macro trajectory show --last 20

# 가장 최근 1개만
& <wrapper> macro trajectory tail

# 비우기
& <wrapper> macro trajectory clear
```

자동으로 기록되는 항목:
- `kind: observation` — 매번 appshot 호출 시 (observation_id, focused_window, affordance_count)
- `kind: click` — click-label 호출 시 (label, window, x, y, observation_id, exit, double, right)

저장 위치: `%TEMP%\computer-use-control-plane\trajectory.ndjson` (1MB 초과 시 최신 200개만 유지)

### ensure-helper (read-only)

Windows-MCP HTTP helper가 안 떠 있으면 `cucp start`를 호출해 자동 기동.

```powershell
& <wrapper> macro ensure-helper
& <wrapper> macro ensure-helper --wait-ms 15000
```

`-Brief`로 한 줄 요약: `ok helper running=True` 또는 `fail helper running=False`.

### Native helper 직통 매크로 (외부 helper 의존 0)

`scripts/cucp-native-helper.ps1` (Win32 P/Invoke + UIA + System.Drawing + Windows.Media.Ocr)
을 직접 호출. windows-mcp / Codex helper / cli.mjs 모두 없어도 동작.

```powershell
& <wrapper> macro native-health           # win32/uia/ocr 가용성 + 사용 가능 OCR 언어
& <wrapper> macro native-windows --match Kiro
& <wrapper> macro native-screenshot --out-path C:\Users\bark\AppData\Local\Temp\shot.png
& <wrapper> -AllowLiveControl macro click-point --x 500 --y 300 --button left
& <wrapper> -AllowLiveControl macro type-native --text "한글 입력 테스트" --enter
& <wrapper> -AllowLiveControl macro shortcut-native --keys "ctrl+s"
& <wrapper> -AllowLiveControl macro uia-click-label --label "최소화" --match "Kiro"
```

모든 actuation 매크로는 `-AllowLiveControl` 필수 (안전 기본값).

### UIA Pattern 직접 호출 (마우스 안 움직임)

UIA Pattern 으로 element를 직접 invoke. BoundingRectangle 좌표만 알면 화면이 가려져도 동작.

```powershell
& <wrapper> -AllowLiveControl macro uia-invoke --label "Save" --match "Notepad"
& <wrapper> -AllowLiveControl macro uia-set-value --label "Name" --value "Alice"
& <wrapper> -AllowLiveControl macro uia-toggle --label "Enable telemetry"
```

신뢰도 score < 60 매칭은 자동 거부 (`low_confidence_match` → partial(2)). 잘못된 element 클릭 방지.

### smart-click cascade (한 번 호출로 가장 안정적인 클릭)

5단계 cascade. UIA Pattern 부터 시도, 실패하면 다음 단계로.

```powershell
& <wrapper> -AllowLiveControl macro smart-click --label "Save"
# Stage 1: UIA Pattern (마우스 안 움직임)

& <wrapper> -AllowLiveControl macro smart-click --label "Save" --allow-mouse-fallback
# Stage 1 → 2 (UIA 좌표) → 3 (icon-find) → 4 (OCR text)

& <wrapper> -AllowLiveControl macro smart-click --label "Save" --allow-mouse-fallback --allow-vision
# Stage 1~4 → 5 (vision-click-precise)

& <wrapper> -AllowLiveControl macro smart-click --label "Save" --verify-label "Saved"
# 클릭 후 "Saved" 라벨 wait-label 검증
```

옵션:
- `--allow-mouse-fallback` — Stage 2/3/4 활성화 (좌표 클릭, 마우스 이동)
- `--allow-vision` — Stage 5 활성화 (vision-click-precise)
- `--no-ocr` — Stage 4 비활성화 (default ON)
- `--verify-label <text>` — 클릭 후 검증 라벨 (timeout 기본 3초)
- `--ocr-language ko` — OCR 엔진 언어 강제 (기본은 사용자 프로필 자동)

### OCR 매크로 (Windows.Media.Ocr — UIA가 못 보는 표면용)

브라우저 캔버스 / Electron 커스텀 그리기 / PDF 이미지 / 이미지 안 텍스트 처럼 UIA로
안 잡히는 표면을 **OCR**로 텍스트 + 좌표 추출. Windows 10/11 기본 내장 엔진.

```powershell
# 1) PNG 파일 OCR (read-only)
& <wrapper> macro ocr-image --path C:\path\to\screenshot.png --language ko
# 출력: 라인/단어 + BoundingRectangle (이미지 픽셀 좌표)

# 2) 화면 영역 캡처 + OCR (read-only)
& <wrapper> macro ocr-screen                                  # 전체 가상 데스크톱
& <wrapper> macro ocr-screen --region 0,0,1920,1080           # 특정 영역
& <wrapper> macro ocr-screen --region 800,400,400,200 --language en-US

# 3) 텍스트 위치 찾기 (read-only)
& <wrapper> macro ocr-find-text --text "Send" --match contains
& <wrapper> macro ocr-find-text --text "전송" --match exact --region 1400,700,500,400
& <wrapper> macro ocr-find-text --text "Submit" --path screenshot.png --max-candidates 5

# 4) OCR로 좌표 찾고 클릭 (라이브)
& <wrapper> -AllowLiveControl macro ocr-click --text "Send" --min-score 70
& <wrapper> -AllowLiveControl macro ocr-click --text "확인" --button left --match contains
```

옵션 (공통):
- `--language ko` / `en-US` / 기타 — OCR 엔진 언어 (기본 자동)
- `--match contains` (default) / `exact` / `prefix` — 매칭 모드
- `--region x,y,w,h` — 화면 영역
- `--path <png>` — 화면 대신 PNG 파일에서 검색
- `--max-candidates N` (default 8) — 후보 개수 한도
- `--min-score N` (default 70, ocr-click 전용) — 최소 신뢰도

OCR 한계는 [`troubleshooting.md`](troubleshooting.md) 의 OCR 섹션 참고.

### OCR+UIA fusion 매크로 (v0.9.0)

UIA가 못 보는 element 인데 OCR 텍스트가 보일 때, 또는 그 반대로 UIA element 가
있는데 Name 이 비어있어 `uia-find` 로 못 잡힐 때 — 두 신호를 융합해서 가장 정확한
호출 방식을 찾는다.

```powershell
# OCR 좌표 위에 UIA element 가 있는지 + InvokePattern 가능한지 보고 (read-only)
& <wrapper> macro ocr-uia-fuse --text "Send" --match contains
& <wrapper> macro ocr-uia-fuse --text "전송" --match-window "Kiro" --language ko

# 두 PNG 의 픽셀 변화 측정 (read-only)
& <wrapper> macro screenshot-diff --before before.png --after after.png
& <wrapper> macro screenshot-diff --before a.png --after b.png --threshold 32

# 클릭 + 화면 변화 자동 검증 (라이브)
& <wrapper> -AllowLiveControl macro click-and-verify-screen --x 500 --y 300
& <wrapper> -AllowLiveControl macro click-and-verify-screen --x 500 --y 300 --wait-ms 800

# smart-click 에 fusion + verify 통합 (default + 옵션)
& <wrapper> -AllowLiveControl macro smart-click --label "Save"
# (cascade 4번째 stage 가 자동으로 ocr-uia-fuse 시도)

& <wrapper> -AllowLiveControl macro smart-click --label "Save" --verify-screen-changed
# (cascade + 화면 변화 검증, 변화 없으면 partial(2))
```

`ocr-uia-fuse` 의 `recommendation`:
- `uia_invoke` — UIA element 의 Name으로 `uia-invoke` 가능 (마우스 안 움직임)
- `ocr_click` — UIA element 없거나 패턴 미지원, OCR 좌표 클릭 fallback
- `low_confidence_skip` — OCR score < 70, 안전 거부

`screenshot-diff` 의 `changed_ratio`: 픽셀 RGB 절대 차이의 합 > threshold(기본 16)인
픽셀의 비율. `changed = (ratio > 0.001)` (0.1% 이상 의미있는 변화).

### 연속 관찰 (watch)

자율 작업 시 화면 변화를 모르고 캐시된 좌표로 재시도하는 문제 방지.

```powershell
& <wrapper> macro watch --interval-ms 500 --max-cycles 20
& <wrapper> macro watch --interval-ms 500 --max-cycles 30 --until-label "저장 완료"
```

매 cycle 한 줄 emit: `cycle=N title='...' delta=init|same|changed`. `--until-label` 보이면 즉시 종료.

### smart-click history learning (v1.1.0)

`smart-click` 의 학습된 strategy 데이터 조회/관리. `smart-click` 매크로 자체는
호출할 때마다 자동으로 history 를 읽고 (가능하면 hint stage 부터) 결과를 기록.

```powershell
# 전체 통계 — total / success / rate / strategy 분포
& <wrapper> macro history stats

# 최근 N건 (또는 특정 라벨만)
& <wrapper> macro history show --last 20
& <wrapper> macro history show --label "Save" --last 10

# 학습 데이터 삭제
& <wrapper> macro history clear

# JSON schema 출력 (cucp.history/v1)
& <wrapper> macro history show --last 50 --json-only

# smart-click 이 학습 비활성으로 동작 (기본 cascade)
& <wrapper> -AllowLiveControl macro smart-click --label "Save" --no-history
```

저장 위치: `%TEMP%\computer-use-control-plane\smart-click-history.ndjson` (NDJSON,
1MB / 1000라인 초과 시 자동 rotate). 같은 (label, match) 의 최근 5건 중 가장
자주 성공한 strategy 가 다음 호출의 hint 가 됨.

### PS5 함정 진단 (v1.1.0, read-only)

```powershell
& <wrapper-dir>\references\audit-ps5-pitfalls.ps1 -ScriptRoot <wrapper-dir>
```

CUCP 스크립트들의 inline-if numeric / `$args` 자동변수 / Get-Content 단일라인 /
Start-Process ExitCode 패턴을 진단. 자동 수정 안 함 — JSON report 출력해서 사람이
검토. 권장 패턴은 스크립트 헤더 주석 참고.

## Wrapper Flags

- `-AllowLiveControl`: 라이브 명령/매크로 허용 (사용자 명시 허락 후에만).
- `-Brief`: 한 줄 결과(`ok ...` / `err ...`). 모델 루프에 적합.
- `-Quiet`: 진단 메시지 억제.
- `-CacheSeconds <n>`: appshot 캐시 유효 시간(기본 2초). 0이면 비활성화.
- `-InvokeTimeoutMs <n>`: 단일 CLI 호출 타임아웃(기본 30000ms). helper가 멈춰도 래퍼가 무한 대기하지 않도록 강제 종료. 타임아웃 시 종료 코드 124.

## Plans (typed JSON workflows)

스킬에 검증된 샘플 plan이 함께 들어 있어요. plan은 typed JSON 시나리오 — observation/action을 명시적 순서로 묶고, `$lastObservation` 토큰으로 직전 관찰을 actuation에 자동 연결합니다.

스킬에 포함된 plan:

| 파일 | 목적 | 실행 모드 |
|---|---|---|
| `plans/notepad-hello-world.json` | 메모장에 결정론적 한 줄 입력 (라이브 시연) | live |
| `plans/xg5000-program-check.json` | XG5000 저장→Program Check(F7)→결과 캡처 | live |

```powershell
# 스키마 검증
& <wrapper> plan validate --file C:\Users\bark\.codex\skills\cucp-computer-use\plans\notepad-hello-world.json

# 드라이런 (actuation 없이 단계 미리보기)
& <wrapper> plan dry-run --file C:\Users\bark\.codex\skills\cucp-computer-use\plans\notepad-hello-world.json

# Readiness + capability preflight
& <wrapper> plan readiness --file C:\Users\bark\.codex\skills\cucp-computer-use\plans\notepad-hello-world.json --strict
& <wrapper> plan preflight --file C:\Users\bark\.codex\skills\cucp-computer-use\plans\notepad-hello-world.json

# 실제 실행 (사용자 명시 허락 후)
& <wrapper> -AllowLiveControl plan run `
    --file C:\Users\bark\.codex\skills\cucp-computer-use\plans\notepad-hello-world.json `
    --readiness --strict-readiness --preflight
```

**Plan 작성 규칙**
- 첫 단계는 `observe_context` (관찰을 plan 안에서 발급).
- 이후 actuation은 `"after": "$lastObservation"`을 넣어 좌표/입력을 직전 관찰과 묶음.
- `targetWindow`는 적극적으로 명시 — readiness가 `--strict-readiness`에서 경고 → 차단.
- 위험한 단축키(Alt+F4, Win+L 등)는 plan에 넣지 말고 사용자 명시 작업으로 분리.

## Scenarios (built-in evals)

내장 시나리오는 dry-run에서는 결정론적 plan을 출력하고, `--execute` 시 실제 actuation을 수행합니다. 스킬을 신규 환경에서 빠르게 검증할 때 유용해요.

```powershell
# 사용 가능한 시나리오 목록
& <wrapper> scenario list

# 결정론적 dry-run (관찰 + 계획만)
& <wrapper> scenario run --name notepad_entry

# 실제 실행 (라이브 컨트롤)
& <wrapper> -AllowLiveControl scenario run --name notepad_entry --execute
```

내장 시나리오 (CUCP v1.0.0 기준):

| 이름 | 설명 |
|---|---|
| `notepad_entry` | Notepad을 열고 결정론적 텍스트 입력 |
| `browser_qa` | 브라우저 포커스 + QA 관찰 |
| `code_edit_test_loop` | 결정론적 테스트 명령을 셸 에이전트로 실행 |

## Desktop Benchmark (live workflow matrix)

CUCP에는 8개 라이브 워크플로우 매트릭스가 있습니다 (browser_to_editor_summary, file_explorer_organization, settings_app_configuration, multi_window_copy_transfer, dialog_form_fill, visual_ui_repair, native_app_smoke_suite, native_save_dialog_roundtrip). 컴퓨터 유즈 신뢰도를 정량 측정할 때 사용.

```powershell
# 워크플로우 목록
& <wrapper> desktop benchmark list

# 라이브 작업 공간 준비 (lease + permission + runbook 생성, actuation 없음)
& <wrapper> desktop benchmark prepare `
    --out-dir "$env:TEMP\cucp-live" --attempts 3 `
    --owner codex-live --ttl-ms 7200000 --operator-idle --force

# Runbook 드라이런
& <wrapper> desktop benchmark runbook `
    --runbook "$env:TEMP\cucp-live\desktop-live-benchmark-runbook.json" --dry-run

# 실제 라이브 실행 (사용자 명시 허락 후)
& <wrapper> -AllowLiveControl desktop benchmark runbook `
    --runbook "$env:TEMP\cucp-live\desktop-live-benchmark-runbook.json" `
    --resume --allow-live-control --fail-fast --timeout-ms 720000

# 증거 감사 (target-grade 도달 여부)
& <wrapper> desktop benchmark audit --evidence "$env:TEMP\cucp-live\merged-live-evidence.json"
```

## Direct CLI Patterns (when macros aren't enough)

매크로는 가장 흔한 패턴을 덮지만, 세밀한 제어가 필요하면 CLI를 직접 호출:

### Observation

```powershell
# 앱 단위 (권장)
& <wrapper> observe appshot --match "Notepad" --annotate --semantic --out "$env:TEMP\notepad.json"

# 풀스크린 + 의미 융합
& <wrapper> observe context --semantic --annotate --out "$env:TEMP\ctx.json"

# 윈도우 목록만
& <wrapper> observe windows --match "Code"

# 단순 스크린샷
& <wrapper> observe screenshot --annotate --out "$env:TEMP\shot.png"
```

### Action (필요할 때 좌표 직접 사용)

```powershell
& <wrapper> -AllowLiveControl act click --x 120 --y 80 --after <observation-id> --target-window "App"
& <wrapper> -AllowLiveControl act right-click --x 120 --y 80 --after <observation-id>
& <wrapper> -AllowLiveControl act drag --from-x 100 --from-y 50 --to-x 300 --to-y 50 --duration-ms 250 --after <observation-id>
& <wrapper> -AllowLiveControl act scroll --x 400 --y 300 --delta-y -480 --after <observation-id>
& <wrapper> -AllowLiveControl act type --text "hello" --x 200 --y 100 --after <observation-id> --clear --enter
& <wrapper> -AllowLiveControl act shortcut --keys "ctrl+shift+s"
```

### Plan / Scenario / Benchmark / L5

(전체 옵션은 `& <wrapper>` (인자 없이) 출력 참조.)

```powershell
& <wrapper> plan validate --file plan.json
& <wrapper> plan dry-run  --file plan.json
& <wrapper> plan readiness --file plan.json --strict
& <wrapper> plan preflight --file plan.json
& <wrapper> -AllowLiveControl plan run --file plan.json --readiness --strict-readiness --preflight

& <wrapper> scenario list
& <wrapper> -AllowLiveControl scenario run --name <id> --execute

& <wrapper> desktop benchmark list
& <wrapper> desktop benchmark prepare --out-dir "$env:TEMP\cucp-live" --attempts 3 --owner codex-live --ttl-ms 7200000 --operator-idle --force
& <wrapper> desktop benchmark runbook --runbook "$env:TEMP\cucp-live\desktop-live-benchmark-runbook.json" --dry-run
& <wrapper> -AllowLiveControl desktop benchmark runbook --runbook "$env:TEMP\cucp-live\desktop-live-benchmark-runbook.json" --resume --allow-live-control --fail-fast --timeout-ms 720000

& <wrapper> l5 capability --objective "<goal>" --provider heuristic
& <wrapper> -AllowLiveControl l5 run --objective "<goal>" --provider heuristic --allow-control --max-steps 60 --max-phase-ms 600000
```

## Diagnostics

```powershell
& <wrapper> version
& <wrapper> health
& <wrapper> tools
& <wrapper> desktop target
& <wrapper> macro session info
```

`health`/`tools`가 실패하면 helper HTTP 서버가 안 떠 있을 가능성이 큼:

```powershell
& <wrapper> start
```

## Error Recovery Patterns

| 증상 | 원인 | 복구 |
|---|---|---|
| `Coordinate-based act ... requires --after` | observation 누락 | 매크로 사용하거나 `observe appshot` 먼저 실행 |
| `Live desktop control blocked` | `-AllowLiveControl` 누락 | 사용자 명시 허락 후 플래그와 함께 재실행 |
| `Label not found: <text>` | 라벨이 화면에 없거나 OCR/UIA 실패 | `--match` 좁히기, `macro session clear-cache`, 다시 시도 |
| 클릭은 되는데 효과 없음 | 포커스 빠졌거나 좌표가 직전 화면 기준 | `macro focus-window` 후 재관찰 |
| 모달/UAC 등장 | 권한 요구 | 즉시 멈추고 사용자에게 다이얼로그 내용 보고 |
| L5가 clarification 일시정지 | 정보 부족 | 체크포인트 읽고 사용자에게 질문, `l5 resume --input "<답>"` |
| 리스 충돌 | 이전 라이브 세션 잔존 | `desktop benchmark status`, `desktop session release --force` |
| OCR이 한글을 못 읽음 | helper 인코딩 문제 | 윈도우 타이틀로 매칭하거나 영어 라벨 우선 |

## Result Reporting

라이브 작업 후 보고는 다음을 포함:

- 모드: 관찰/시뮬레이션/라이브.
- 사용한 매크로/명령과 라벨/좌표/타깃 윈도우.
- 사용한 observation_id (Verify 단계 캡처 포함).
- 변경된 결과 증거: 새 윈도우 타이틀, 새 텍스트 등.
- 획득/해제한 리스 정보.
- 감사 로그/스크린샷 경로.

## Response Style

- 기본 응답 언어: 한국어. 명령 스니펫은 영어 원문 유지.
- 라이브 명령은 실행 전에 read-only/live-control 여부를 명시.
- 라이브 명령이 한 번에 여러 건일 때는 첫 번째 실행 전에 묶어서 한 번 확인.
- 매크로 우선, 직접 좌표는 라벨이 안 잡힐 때만.
