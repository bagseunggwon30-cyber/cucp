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
C:\Users\K\Documents\Codex\2026-05-22\new-chat\src\cli.mjs
```

Wrapper (use this for every call from any project):

```powershell
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 [-AllowLiveControl] [-Brief] [-CacheSeconds <n>] [-InvokeTimeoutMs <n>] <args>
```

Audit logs and artifacts are under:

```text
C:\Users\K\AppData\Local\Temp\computer-use-control-plane
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
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 desktop session release --lease-file <lease.json> --force
```

## Macro Reference (claude-grade)

### find-label (read-only)

라벨/역할로 요소 위치를 찾고 좌표/윈도우/observation_id를 반환. CUCP fusion이 비어 있으면 PowerShell UIAutomation으로 자동 폴백.

```powershell
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro find-label --label "확인" --window "XG5000"
```

옵션: `--label` (필수), `--window` (제목 일부), `--match` (appshot 필터, 기본은 window), `--role` (button/edit/etc).

`-Brief`를 붙이면 한 줄 요약: `ok find-label '확인' @(120,80) win='XG5000'`.

### list-affordances (read-only)

현재 화면에서 클릭 가능한 모든 요소 목록 (영문/한글 라벨 모두). 모델이 무엇을 클릭할 수 있는지 한 번에 조망할 때 사용.

```powershell
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro list-affordances --window "설정" --limit 20
```

각 항목에 `affordance_id`, `text`, `role`, `window`, `center` 좌표, `confidence`, `sources` 포함.

### click-id (live)

affordance_id로 직접 클릭 (라벨이 중복되거나 라벨 매칭이 모호할 때).

```powershell
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 -AllowLiveControl macro click-id --id "aff:설정:단추:시작:0-1032-55-48:uia"
```

### click-label / double-click-label / right-click-label (live)

```powershell
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 -AllowLiveControl macro click-label --label "Save" --window "Notepad"
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 -AllowLiveControl macro double-click-label --label "MyFile.txt" --window "File Explorer"
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 -AllowLiveControl macro right-click-label --label "Item" --window "ListView"
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
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 -AllowLiveControl macro fill-label --label "Name" --text "Alice" --clear --enter
```

옵션: `--label`(필수), `--text`(필수), `--window`, `--clear`, `--enter`.

### focus-window (live)

윈도우/프로세스 이름으로 포커스 이동.

```powershell
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 -AllowLiveControl macro focus-window --name "XG5000"
```

### wait-window (read-only)

윈도우가 보일 때까지 대기 (앱 실행 직후 등).

```powershell
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro wait-window --title "XG5000" --timeout-ms 10000 --interval-ms 500
```

### wait-label (read-only)

특정 라벨이 화면에 등장할 때까지 폴링 (다이얼로그 열림 / 작업 완료 신호 대기에 유용).

```powershell
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro wait-label --label "다운로드 완료" --window "XG5000" --timeout-ms 30000
```

### shortcut (live)

```powershell
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 -AllowLiveControl macro shortcut --keys "ctrl+s"
```

자주 쓰는 키: `ctrl+c`, `ctrl+v`, `ctrl+s`, `ctrl+shift+s`, `alt+tab`, `alt+f4`, `win+e`, `win+d`, `enter`, `tab`, `escape`, `f1`–`f12`. 한글 IME 토글은 보통 `win+space`(시스템 설정).

### goal (live, autonomous)

목표 자연어를 받아 L5 자율 실행. **자가 검증** 옵션 포함: 실행 후 특정 라벨이 등장하는지 자동 확인.

```powershell
# 드라이런으로 계획만 미리보기
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro goal --objective "Open Notepad and type hello world" --dry-run

# 실제 실행 + 자가 검증
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 -AllowLiveControl macro goal `
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
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro self-test

# 풀 검증 (UIA fallback + appshot 캡처 포함)
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro self-test --deep

# strict 모드: skipped도 실패로 간주 (helper 가동을 강제하고 싶을 때)
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro self-test --deep --strict

# 한 줄 요약 (모델 루프용)
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 -Brief macro self-test
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
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro session info
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro session clear-cache
```

### task-card (XG5000/XP-Builder context, read-only storage)

`task-card` opens or reads a small local context card for PLC/SCADA work. Use it before asking CUCP to help with XG5000 or XP-Builder so the agent has the active device list, address ranges, requirements, and safety constraints.

```powershell
& <wrapper> macro task-card open
& <wrapper> macro task-card show
& <wrapper> macro task-card save --tool XG5000 --project "packing-sim" --plc "XGI/XGB" --devices "X0,Y20,M10,D100" --requirements "check interlocks before editing" --constraints "download forbidden during class"
& <wrapper> macro task-card path
```

The JSON file is stored at `%TEMP%\computer-use-control-plane\task-card\current-task-card.json` and uses schema `cucp.task-card/v1`. `app-profile` automatically includes this JSON as `task_card` when it profiles PLC/SCADA-like windows such as XG5000, XP-Builder, CIMON, SCADA, XGT, PLC, or Modbus tools.

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
& <wrapper> macro native-screenshot --out-path C:\Users\K\AppData\Local\Temp\shot.png
& <wrapper> -AllowLiveControl macro click-point --x 500 --y 300 --button left
& <wrapper> -AllowLiveControl macro click-point --x 500 --y 300 --target-match Kiro --refine uia-safe --click-inset 2
& <wrapper> -AllowLiveControl macro click-point --x 500 --y 300 --target-match Kiro --micro-refine --precision-radius 6 --precision-step 2 --cache-ttl 2
& <wrapper> -AllowLiveControl macro click-point --x 500 --y 300 --target-match Kiro --no-micro-refine
& <wrapper> -AllowLiveControl macro type-native --text "한글 입력 테스트" --enter
& <wrapper> -AllowLiveControl macro shortcut-native --keys "ctrl+s"
& <wrapper> -AllowLiveControl macro uia-click-label --label "최소화" --match "Kiro"
```

`click-point --target-match/--target-hwnd`는 실제 클릭 전에 wrapper Win32 fast guard로 좌표가 의도한 앱 안인지 확인하고, helper click에도 같은 target guard를 전달합니다. `--refine uia-safe`를 붙이면 마지막 클릭 직전에 UIA `ClickablePoint` 보정까지 적용합니다.

모든 actuation 매크로는 `-AllowLiveControl` 필수 (안전 기본값).

### UIA Pattern 직접 호출 (마우스 안 움직임)

UIA Pattern 으로 element를 직접 invoke. BoundingRectangle 좌표만 알면 화면이 가려져도 동작.

```powershell
& <wrapper> -AllowLiveControl macro uia-invoke --label "Save" --match "Notepad"
& <wrapper> -AllowLiveControl macro uia-set-value --label "Name" --value "Alice"
& <wrapper> -AllowLiveControl macro uia-toggle --label "Enable telemetry"
```

신뢰도 score < 60 매칭은 자동 거부 (`low_confidence_match` → partial(2)). 잘못된 element 클릭 방지.

### smart-plan (실행 전 route planner, read-only)

실제 클릭/입력 없이 CDP DOM, UIA Pattern, UIA 좌표, OCR fusion 후보를 순서대로 평가하고
가장 안전한 다음 명령을 제안합니다. AI agent가 바로 actuation으로 들어가기 전에
`safe_to_act`, `best_route`, `recommended_command`, 후보 근거를 확인하는 용도입니다.

```powershell
& <wrapper> macro smart-plan --label "Save"
& <wrapper> macro smart-plan --label "Send" --allow-cdp --cdp-page-match Kiro
& <wrapper> macro smart-plan --label "Save" --match "Kiro" --precision-points --precision-radius 6 --precision-step 2
& <wrapper> macro smart-plan --label "Message" --type-text "hello" --allow-cdp
& <wrapper> macro smart-plan --label "제목" --type-text "보고서" --match "메모장"
& <wrapper> macro smart-plan --label "확인" --match "XG5000" --include-ocr
& <wrapper> macro smart-plan --label "Send" --allow-cdp --json-only
```

출력 route:
- `cdp_smart_click` — Chrome/Electron DOM에서 visible text/aria 후보를 찾음. 좌표/마우스 이동 없음.
- `cdp_smart_type` — Chrome/Electron DOM input/contenteditable 후보를 찾음. 좌표/IME 없이 value/event 입력 가능.
- `uia_pattern` — UIA Invoke/Toggle/SelectionItem 등 패턴으로 호출 가능. 마우스 이동 없음.
- `uia_set_value` — UIA ValuePattern으로 input/edit 값을 직접 설정 가능. 키보드 시뮬레이션 없음.
- `uia_coord` — UIA 라벨은 안정적으로 찾았지만 패턴 없음. `smart-click --allow-mouse-fallback` 권장.
- `uia_precision_point` — `--precision-points` 사용 시 UIA 라벨의 click point를 `click-point --micro-refine` 경로로 추천. 작은 버튼/탭/체크박스에서 클릭 직전 `hit-scan`과 짧은 point cache를 사용.
- `safe_type_guarded` — ValuePattern은 없지만 입력 후보와 target window가 있어 `safe-type` 가드로 입력 가능.
- `fusion_uia_invoke` — OCR 텍스트와 UIA element가 융합되어 invoke 가능.
- `ocr_text` — OCR 후보가 충분히 높아 `ocr-click` 가능. 클릭 직전 `ClickRefine uia-safe` 보정 적용.

`smart-plan`은 `-AllowLiveControl`이 필요 없습니다. 출력된 `recommended_command`를 실행할 때만
명시 허락 후 `-AllowLiveControl`을 붙입니다.

### app-profile (app automation strategy profile, read-only)

`app-profile` inspects the current or matched top-level window and recommends the safest automation
route order before an AI caller builds a task. It is read-only: it does not click, type, focus, or move
the mouse.

```powershell
& <wrapper> macro app-profile --match "Chrome" --label "Send" --label "Subject" --auto-probe --json-only
& <wrapper> macro app-profile --match "XG5000" --label "OK" --probe-uia --include-affordances --json-only
& <wrapper> macro app-profile --match "Kiro" --label "Run" --auto-probe --record-strategy --json-only
& <wrapper> macro app-profile --label "Save"
```

Output schema is `cucp.app-profile/v1`. Important fields:
- `app_type`: `browser_or_electron`, `industrial_win32`, `document_or_mail_app`, or `win32_desktop`.
- `strategy_score`: numeric route confidence with schema `cucp.app-profile-strategy-score/v1`.
  It combines CDP probe state, UIA affordance/label evidence, OCR/vision fallback need, app type, and
  the last persisted good strategy for the same app.
- `strategy_persistence`: app-level strategy history metadata. `--record-strategy` stores a medium/high
  confidence recommendation in `%TEMP%\computer-use-control-plane\app-strategy-history.ndjson`; use
  `--no-strategy-history` to ignore that history.
- `route_order`: recommended control order, for example CDP/DOM first for Chrome/Electron, UIA and
  guarded precision points first for PLC/SCADA tools.
- `capability_probes`: optional read-only probe results for CDP and UIA. Browser/Electron windows run a
  cheap CDP port probe by default unless `--no-probe` is set. Use `--auto-probe`, `--probe-cdp`,
  `--probe-uia`, `--cdp-port <n>`, and `--probe-uia-limit <n>` to tune probing.
- `recommended_task_options`: options to append to `task-plan` or `task-run`.
- `probe_commands`: read-only `smart-plan` commands generated from each `--label`.
- `suggested_task_plan_prefix`: a starter `task-plan` command for the selected app.
- `task_card`: the current `cucp.task-card/v1` JSON. PLC/SCADA-like apps auto-create/load it so devices,
  requirements, and safety flags can guide the plan.

Use this before document/mail/app automation when the target program is unknown or when coordinates feel
unstable. The normal flow is: `app-profile` -> `smart-plan` probes -> `task-plan` -> `task-run --dry-run`
-> live control only after explicit approval.

### safety-classify (sensitive action classifier, read-only)

`safety-classify` checks proposed text, commands, or workflow steps for sensitive live actions before
the agent touches the desktop. It classifies credentials, payments, destructive changes, external
sending/publishing, private identity data, system changes, and app settings changes.

```powershell
& <wrapper> macro safety-classify --text "Delete account and enter password" --json-only
& <wrapper> macro safety-classify --step "macro cdp-smart-click --text Send --port 9999" --json-only
```

Output schema is `cucp.safety-classify/v1`. Important fields:
- `risk_level`: `none`, `low`, `medium`, `high`, or `critical`.
- `requires_explicit_confirmation`: true when live control must be confirmed with `--confirm-sensitive`.
- `categories`: matched risk categories with reasons.

`workflow-plan` embeds the classifier result on each step and reports `sensitive_step_count`.
`workflow-run`, `task-run`, `form-run`, and direct sensitive live macros block with
`reason=sensitive_action_requires_confirmation` unless `--confirm-sensitive` is supplied. Use that flag
only after the user has explicitly approved the exact payment, deletion, credential entry, send/publish,
or other sensitive action.

### form-plan (여러 입력칸 + 마지막 버튼 planner, read-only)

메일, 문서 작성, 티켓 등록처럼 여러 필드를 채운 뒤 저장/전송 버튼을 누르는 작업을 실행 전에
한 번에 계획합니다. 내부적으로 각 단계마다 `smart-plan`을 다시 호출하므로, DOM/CDP, UIA
ValuePattern, UIA Pattern, guarded coordinate 후보를 같은 기준으로 비교합니다.

```powershell
& <wrapper> macro form-plan --field "To=a@example.com" --field "Subject=Report" --field "Body=Done" --send-label "Send" --allow-cdp
& <wrapper> macro form-plan --field "제목=보고서" --field "본문=완료했습니다" --send-label "저장" --match "메모장"
& <wrapper> macro form-plan --field "Message=hello" --allow-cdp --json-only
```

출력 schema는 `cucp.form-plan/v1`입니다. `command_plan[]`은 AI agent가 순서대로 실행할
후보 명령을 담고, `unsafe_steps[]`는 아직 신뢰할 수 없는 단계만 따로 보여줍니다.
`form-plan` 자체는 read-only이며 마우스 이동, 클릭, 입력을 하지 않습니다. 실제 실행은
각 단계의 `recommended_command`를 사용자가 허락한 뒤 `-AllowLiveControl`로 실행합니다.

### form-run (safe form-plan 실행기, live gate)

`form-run`은 먼저 `form-plan`을 내부에서 실행하고, 모든 단계가 `safe_to_act=true`일 때만
`command_plan[]`을 순서대로 실행합니다. 하나라도 안전하지 않으면 `status=blocked`,
`executed_count=0`으로 멈춥니다.

```powershell
& <wrapper> macro form-run --field "To=a@example.com" --field "Subject=Report" --send-label "Send" --allow-cdp --dry-run
& <wrapper> -AllowLiveControl macro form-run --field "To=a@example.com" --field "Subject=Report" --field "Body=Done" --send-label "Send" --allow-cdp --confirm-sensitive
& <wrapper> -AllowLiveControl macro form-run --field "제목=보고서" --field "본문=완료했습니다" --send-label "저장" --match "메모장"
```

`--dry-run`은 실행하지 않고 plan 결과를 `ready/blocked`로만 확인합니다. 실제 실행은
`-AllowLiveControl`이 필요하며, 기본은 첫 실패에서 멈춥니다. 여러 단계를 계속 시도해야 할
때만 `--continue-on-error`를 사용합니다.

### task-plan (앱 + 폼 + 검증 workflow planner, read-only)

`task-plan`은 앱 실행, 대기할 창, 여러 입력 필드, 마지막 클릭 버튼, 검증 라벨을 하나의
`workflow-run` 계획으로 묶습니다. 자체는 read-only이며, 반환된 `dry_run_command`를 먼저 확인하고
`recommended_command`는 사용자 허가 후 `-AllowLiveControl`로 실행하는 흐름입니다.

### task-preset (common task/workflow presets, read-only)

`task-preset` builds common document, mail, form submit, file upload/download, and settings-change plans.
It does not execute the workflow. Document/mail presets still return `generated_task_plan_command` and
`generated_task_run_command`; workflow-style presets return `generated_workflow_plan_command`,
`generated_workflow_dry_run_command`, and `generated_workflow_run_command`.

```powershell
& <wrapper> macro task-preset --kind document --text "meeting notes" --replace --save
& <wrapper> macro task-preset --kind mail --to "a@example.com" --subject "Report" --body "Done" --send-label "Send" --match Gmail
& <wrapper> macro task-preset --kind form-submit --field "Email=a@example.com" --send-label "Submit" --match Chrome
& <wrapper> macro task-preset --kind file-upload --path "C:\Temp\a.txt" --upload-label "Upload" --match Chrome
& <wrapper> macro task-preset --kind file-download --download-label "Download" --verify-label "Done" --match Chrome
& <wrapper> macro task-preset --kind settings --settings-label "Settings" --field "Theme=Dark" --save-label "Apply" --match App
```

Use the generated dry-run command first, then live control only after explicit approval. Presets involving
submit, upload, or settings usually set `requires_sensitive_confirmation=true`; live execution then needs
`--confirm-sensitive` in addition to `-AllowLiveControl`.

### task-plan examples

```powershell
& <wrapper> macro task-plan --app chrome --wait-title Chrome --field "To=a@example.com" --field "Subject=Report" --field "Body=Done" --send-label "Send" --allow-cdp --precision-points
& <wrapper> macro task-plan --field "제목=보고서" --field "본문=완료했습니다" --send-label "저장" --match "메모장" --verify-label "저장됨"
& <wrapper> macro task-plan --app notepad --wait-title Notepad --json-only
& <wrapper> macro task-plan --app notepad --wait-title Notepad --type-text "meeting notes" --shortcut "ctrl+s"
& <wrapper> macro task-plan --pre-shortcut "ctrl+a" --type-text "draft" --match Notepad --enter --json-only
```

`--type-text` adds a generic typing step. With `--match`, it plans guarded `safe-type`; without `--match`,
it plans faster `type-native`. `--pre-shortcut` runs before typing, and `--shortcut`/`--keys` runs after
typing/click steps, covering select-all, write text, and save flows.

출력 schema는 `cucp.task-plan/v1`입니다. `workflow_plan`에는 각 step의 read-only/live 분류가 들어가며,
`recommended_command`는 `macro workflow-run --step ...` 형태입니다. `form_plan`이 unsafe이면
`status=partial`로 끝나고 실행 명령을 추천하지 않습니다.

### task-run (task-plan 실행기, live gate)

`task-run`은 먼저 `task-plan`을 만들고, unsafe plan이면 즉시 `blocked`로 멈춥니다.
`--dry-run`은 반환된 workflow를 read-only로 검증하고, 실제 실행은 live step이 있을 때
`-AllowLiveControl`이 필요합니다.

```powershell
& <wrapper> macro task-run --dry-run --app chrome --wait-title Chrome --field "To=a@example.com" --send-label "Send" --allow-cdp --precision-points
& <wrapper> -AllowLiveControl macro task-run --app chrome --wait-title Chrome --field "To=a@example.com" --field "Subject=Report" --send-label "Send" --allow-cdp --precision-points --include-plan --confirm-sensitive
& <wrapper> macro task-run --dry-run --app notepad --wait-title Notepad --type-text "meeting notes" --shortcut "ctrl+s"
& <wrapper> macro task-run --dry-run --app chrome --wait-title Chrome --field "Subject=Report" --settle-ms 150 --verify-after-step --verify-match Chrome --retry-failed-step 1
```

출력 schema는 `cucp.task-run/v1`입니다. `workflow_result`는 내부 `workflow-run` 결과이며,
실제 실행 전에는 `--dry-run`으로 `status=ready`를 확인하는 흐름을 권장합니다.

### workflow-plan / workflow-run (범용 macro sequence)

`workflow-plan`은 여러 macro step을 실행 없이 파싱하고, read-only step과 live-control step을
분류합니다. `workflow-run`은 같은 계획을 먼저 만든 뒤, `--dry-run`이면 실행하지 않고
`ready/blocked`만 반환합니다. read-only step만 있는 workflow는 `-AllowLiveControl` 없이
실행할 수 있고, live-control step이 하나라도 있으면 `-AllowLiveControl`이 필요합니다.

```powershell
& <wrapper> macro workflow-plan --step "macro hit-test --x 1200 --y 720 --fast" --step "macro form-plan --field Message=hello"
& <wrapper> macro workflow-run --step "macro hit-test --x 1200 --y 720 --fast" --step "macro windows"
& <wrapper> macro workflow-run --observe-after-step --step "macro hit-test --x 1200 --y 720 --fast"
& <wrapper> macro workflow-run --verify-after-step --verify-match Notepad --settle-ms 150 --step "macro hit-test --x 1200 --y 720 --fast"
& <wrapper> -AllowLiveControl macro workflow-run --confirm-sensitive --step "macro cdp-smart-click --text Send --port 9222"
& <wrapper> macro workflow-run --verify-label-after-step "Saved" --verify-label-timeout-ms 1000 --step "macro windows"
& <wrapper> macro workflow-run --retry-failed-step 2 --retry-delay-ms 100 --step "macro windows --match Notepad"
& <wrapper> macro workflow-run --dry-run --step "macro hit-test --x 1200 --y 720 --fast" --step "macro click-point --x 1200 --y 720 --target-match Kiro"
& <wrapper> -AllowLiveControl macro workflow-run --step "macro app-launch --name notepad --wait-title Notepad" --step "macro shortcut --keys ctrl+s"
```

`--settle-ms` waits briefly after each executed step. `--observe-after-step` captures a cheap `windows`
observation after each step, and `--verify-after-step --verify-match <window>` treats a missing window
observation as a failed verification step.
`--verify-label-after-step <label>` runs a read-only `wait-label` check after each step, useful when the
success condition is a visible button, status text, or saved indicator.
`--retry-failed-step <n>` retries a failed step up to `n` times. Live steps are not retried unless
`--retry-live-steps` is explicitly set.
When a workflow ends as `partial`, the result includes `failure_summary` and `next_action` so an AI
caller can decide whether to re-ground, widen a selector, increase timeout, or ask before retrying.

허용된 macro allowlist만 실행할 수 있고, `workflow-plan`/`workflow-run` 재귀 호출은 차단합니다.
좌표 step은 `click-point --target-match` 같은 target guard를 함께 쓰는 방식이 권장됩니다.

### smart-click cascade (한 번 호출로 가장 안정적인 클릭)

기본은 빠른 UIA Pattern부터 시도하고, 실패하면 다음 단계로 넘어갑니다. 웹/Chrome/Electron처럼
DOM 접근이 가능한 환경에서는 `--allow-cdp`, `--cdp-page-match`, `--cdp-port` 중 하나로
Stage 0(CDP/DOM smart click)을 먼저 켤 수 있습니다.

```powershell
& <wrapper> -AllowLiveControl macro smart-click --label "Save"
# Stage 1: UIA Pattern (마우스 안 움직임)

& <wrapper> -AllowLiveControl macro smart-click --label "Save" --allow-cdp
# Stage 0: CDP/DOM 라벨 기반 클릭 → 실패 시 Stage 1~6

& <wrapper> -AllowLiveControl macro smart-click --label "Save" --allow-mouse-fallback
# Stage 1 → 2 (UIA 좌표) → 3 (icon-find) → 4 (OCR text)

& <wrapper> -AllowLiveControl macro smart-click --label "Save" --match "Kiro" --allow-mouse-fallback --precision-points --precision-radius 6 --precision-step 2
# Stage 2 UIA coordinate fallback uses click-point --micro-refine and short point cache

& <wrapper> -AllowLiveControl macro smart-click --label "Save" --allow-mouse-fallback --allow-vision
# Stage 1~4 → 5 (vision-click-precise)

& <wrapper> -AllowLiveControl macro smart-click --label "Save" --verify-label "Saved"
# 클릭 후 "Saved" 라벨 wait-label 검증
```

옵션:
- `--allow-cdp` — Stage 0 CDP/DOM smart click 활성화. 웹/Electron에서 좌표 없이 DOM 클릭.
- `--cdp-page-match <text>` — CDP 대상 페이지 title/url 필터. 지정하면 Stage 0도 활성화.
- `--cdp-port <n>` — CDP 포트 지정. 지정하면 Stage 0도 활성화. 기본 9222.
- `--no-cdp` — CDP Stage 0 비활성화.
- `--allow-mouse-fallback` — Stage 2/3/4 활성화 (좌표 클릭, 마우스 이동)
- `--precision-points` — Stage 2 UIA 좌표 fallback을 `click-point --micro-refine`으로 실행. `--precision-radius`, `--precision-step`, `--point-cache-ttl`로 작은 버튼/탭 보정 범위와 캐시 TTL 조정.
- `--allow-vision` — Stage 5 활성화 (vision-click-precise)
- `--no-ocr` — Stage 4 비활성화 (default ON)
- `--verify-label <text>` — 클릭 후 검증 라벨 (timeout 기본 3초)
- `--ocr-language ko` — OCR 엔진 언어 강제 (기본은 사용자 프로필 자동)
- `--ocr-match contains|exact|prefix|fuzzy` — smart-click OCR stage matching mode. `fuzzy` is opt-in.
- `--ocr-max-candidates N` - smart-click OCR/fusion fallback 후보 수. 기본 4, 최대 8.
- `--prefer-history` - OCR/vision fallback 성공 이력까지 우선 사용. 기본값은 빠른 UIA 경로를 먼저 시도.

CDP direct 매크로:
```powershell
& <wrapper> macro cdp-detect --port 9222
& <wrapper> macro cdp-eval --expr "document.title" --page-match Kiro
& <wrapper> macro cdp-eval --expr-b64 <utf8-base64-javascript> --page-match Kiro
& <wrapper> macro cdp-smart-find --text "Send" --page-match Kiro
& <wrapper> macro cdp-smart-type-find --label "Message" --page-match Kiro
& <wrapper> -AllowLiveControl macro cdp-click --selector "button[aria-label='Send']" --page-match Kiro
& <wrapper> -AllowLiveControl macro cdp-type --selector "textarea" --text "hello" --press-enter --page-match Kiro
& <wrapper> -AllowLiveControl macro cdp-smart-click --text "Send" --page-match Kiro
& <wrapper> -AllowLiveControl macro cdp-smart-type --label "Message" --text "hello" --press-enter --page-match Kiro
```

DOM bridge planning:

- Closed CDP ports now still return `dom_bridge_plan` with schema `cucp.cdp-dom-bridge-plan/v1`
  in JSON mode for `cdp-smart-find`, `cdp-smart-type-find`, `cdp-smart-click`, and `cdp-smart-type`.
- The plan includes `read_only_command`, `live_command`, selector ranking priorities, and fallback order.
- When CDP is available, smart DOM actions also return `page_selection`, `selector_candidates`,
  `locator_candidates`, and `candidate_summaries` so an external agent can reuse a stable CSS
  selector or Playwright-style locator instead of falling back to coordinates.
- Page selection is scored by explicit `--page-match`, page/webview type, title/url quality, and
  DevTools/worker penalties. Use `--page-match` when Chrome/Electron exposes multiple pages.

`cdp-smart-click` / `cdp-smart-type`은 visible text, `aria-label`, `title`, `placeholder`,
`id`, `name`, label 연결 정보를 보고 후보를 점수화합니다. 닫힌 CDP 포트 때문에 기본 클릭이 느려지지 않도록
`smart-click`에서는 명시 옵션이 있을 때만 Stage 0으로 들어갑니다.

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
& <wrapper> macro ocr-find-text --text "5end" --match fuzzy --max-candidates 8
& <wrapper> macro ocr-find-text --text "Send" --target-match "Kiro"
& <wrapper> macro ocr-find-text --text "전송" --match exact --region 1400,700,500,400
& <wrapper> macro ocr-find-text --text "Submit" --path screenshot.png --max-candidates 5

# 4) OCR로 좌표 찾고 클릭 (라이브)
& <wrapper> -AllowLiveControl macro ocr-click --text "Send" --min-score 70
& <wrapper> -AllowLiveControl macro ocr-click --text "확인" --button left --match contains
```

옵션 (공통):
- `--language ko` / `en-US` / 기타 — OCR 엔진 언어 (기본 자동)
- `--match contains` (default) / `exact` / `prefix` / `fuzzy` — 매칭 모드. `fuzzy`는 OCR이 `Send`를 `5end`처럼 읽는 경우용 opt-in.
- `--region x,y,w,h` — 화면 영역
- `--target-match <window>` - 화면 OCR을 해당 창 영역으로 crop 해서 속도와 좌표 안전성을 높임.
- `--path <png>` — 화면 대신 PNG 파일에서 검색
- `--max-candidates N` (default 8) — 후보 개수 한도
- `--min-score N` (default 70, ocr-click 전용) — 최소 신뢰도

OCR 한계는 [`troubleshooting.md`](troubleshooting.md) 의 OCR 섹션 참고.

OCR 확장: 후보는 line/word뿐 아니라 연속 2~3단어 n-gram도 포함해 `Save As`, `Send Message` 같은 다중 단어 라벨의 중심 좌표를 더 좁게 잡습니다. 단일 단어 검색은 n-gram 생성을 줄이고, 동점 후보는 더 작은 word/ngram 박스를 우선해 클릭 좌표를 보수적으로 잡습니다.

정밀 클릭 보강: `smart-click`의 icon/OCR 좌표 fallback과 `ocr-click`은 실제 클릭 직전에 `ClickRefine uia-safe`를 사용합니다. 즉 좌표 아래의 UIA 요소를 한 번 더 보고, 작은 버튼/탭/체크박스/링크처럼 안전한 컨트롤이면 Windows UIA의 native `ClickablePoint`를 우선 사용하고, 없을 때만 안전 inset이 적용된 중심점으로 미세 보정합니다. 보정 후에도 target-window hit-test를 다시 통과할 때만 클릭합니다. 캔버스나 큰 문서 영역처럼 보정 위험이 큰 표면은 원래 OCR 좌표를 유지합니다.

```powershell
# read-only: 특정 좌표의 실제 윈도우/프로세스와 UIA 보정 후보를 함께 확인
& <wrapper> macro coord-profile --x 1200 --y 720 --target-match Kiro
& <wrapper> macro coord-map --from window --x 40 --y 24 --target-match Kiro
& <wrapper> macro coord-map --from normalized --norm-x 0.5 --norm-y 0.5 --target-match Kiro
& <wrapper> macro coord-anchor --x 1200 --y 720 --target-match Kiro
& <wrapper> macro coord-anchor --x 1200 --y 720 --target-match Kiro --record-history
& <wrapper> macro hit-test --x 1200 --y 720 --target-match Kiro --click-inset 3
# brief 출력 예: uia_refine=(1214,718) role='button' score=158 source=clickable_point

# read-only: 빠른 Win32-only 좌표 가드. UIA 보정 없이 윈도우/프로세스만 확인
& <wrapper> macro hit-test --x 1200 --y 720 --target-match Kiro --fast
# JSON 출력의 source=wrapper_win32_fast, uia_skipped=true

# read-only: 여러 후보 좌표를 한 번에 빠르게 검사. AI가 작은 버튼 후보를 비교할 때 사용
& <wrapper> macro hit-test-batch --points "1200,720;1210,720;1220,720" --target-match Kiro
& <wrapper> macro hit-test-batch --point "1200,720" --point "1210,720" --point "1220,720"
# JSON 출력 schema=cucp.hit-test-batch/v1, source=wrapper_win32_fast

# read-only: 작은 버튼/경계 좌표 주변을 UIA로 미세 scan
& <wrapper> macro hit-scan --x 1200 --y 720 --target-match Kiro
& <wrapper> macro hit-scan --x 1200 --y 720 --radius 4 --step 2 --target-match Kiro --click-inset 2
& <wrapper> macro point-plan --x 1200 --y 720 --radius 6 --step 2 --target-match Kiro --cache-ttl 2
& <wrapper> macro target-validate --x 1200 --y 720 --target-match Kiro --min-confidence medium
# brief 출력 예: best=(1214,718) confidence=high role='button' support=3 source=clickable_point
```

`point-plan`은 기본적으로 wrapper의 `-CacheSeconds` 값을 짧은 TTL로 사용합니다. 같은 좌표/창/root hwnd/scan 옵션이면 두 번째 호출부터 `from_cache=true`로 빠르게 반환합니다. 레이아웃이 변하는 화면에서는 `--no-cache` 또는 `--cache-ttl 0`을 붙이면 항상 새로 scan합니다.

`coord-profile` returns schema `cucp.coord-profile/v1` with virtual screen bounds, monitor DPI/scale,
target window rect, point-relative coordinates, edge distance, hit-test evidence, and `coordinate_risk`.
`coord-map` returns schema `cucp.coord-map/v1` and converts between screen, window-local,
visible-window-local, normalized, and visible-normalized coordinates. Use it when OCR/vision returns a
point inside a cropped window screenshot and the AI caller needs the real screen point for `point-plan`.
`coord-anchor` returns schema `cucp.coord-anchor/v1` and packages a screen point as a reusable
window-normalized anchor plus restore and immediate `point-plan` commands. Store the normalized anchor,
not the absolute screen coordinate, when an AI agent needs to revisit the same control after a resize.
It also reports `reuse_history` with schema `cucp.anchor-reuse-score/v1`; use `--record-history`
after a verified anchor so future calls can score exact/near matches, coordinate signature changes,
safe reuse rate, and a `reuse_ok_after_target_validate` recommendation.
`point-plan` embeds this profile and includes the coordinate signature in its cache key, so DPI/monitor
layout changes do not silently reuse stale precision points.
`target-validate` returns schema `cucp.target-validate/v1` and wraps `point-plan` with a final
pre-click judgement. It reports `safe_to_click`, target guard status, coordinate risk, confidence,
target size class (`tiny`/`small`/`medium`/`large`), support count, native clickable evidence, edge
distance, warnings, and the live `recommended_command` only when the point is target-guarded and safe.
Use it just before a live coordinate click when the target is a small button, tab, checkbox, toolbar
icon, or narrow SCADA/PLC control.

Coordinate precision v2:

- `click-point` now enables micro-refine by default whenever `--target-match` or `--target-hwnd`
  is present. Use `--no-micro-refine` only when latency matters more than click precision.
- Guarded live clicks score anchor reuse before clicking and record the normalized anchor after a
  successful click unless `--no-anchor-history` is set.
- `smart-plan --precision-points` returns `precision_policy`, including the target-validation
  expectation and the live click defaults an agent should preserve.

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
& <wrapper> plan validate --file C:\Users\K\.codex\skills\cucp-computer-use\plans\notepad-hello-world.json

# 드라이런 (actuation 없이 단계 미리보기)
& <wrapper> plan dry-run --file C:\Users\K\.codex\skills\cucp-computer-use\plans\notepad-hello-world.json

# Readiness + capability preflight
& <wrapper> plan readiness --file C:\Users\K\.codex\skills\cucp-computer-use\plans\notepad-hello-world.json --strict
& <wrapper> plan preflight --file C:\Users\K\.codex\skills\cucp-computer-use\plans\notepad-hello-world.json

# 실제 실행 (사용자 명시 허락 후)
& <wrapper> -AllowLiveControl plan run `
    --file C:\Users\K\.codex\skills\cucp-computer-use\plans\notepad-hello-world.json `
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


---

## v1.4.0 — 9개 신규 매크로 (6 missing items + 보안 보완)

### `macro cdp-deep-find` (read-only)

```powershell
& <wrapper> macro cdp-deep-find --text <label> [--page-match <s>] [--port 9222]
```

- schema: `cucp.cdp-deep-find/v1`
- 동기: `cdp-smart-find/type` 가 Shadow DOM/iframe 까지 deepCollect 하지만 그 traversal
  메타정보가 안 보여서 디버깅/벤치마크용으로 분리.
- 출력: `traversal: { hops, shadow_roots_seen, iframes_seen, iframes_blocked, total_nodes }`,
  `top_matches[]` (최대 8개, score 정렬).
- exit: 0 ok / 2 partial(cdp_port_closed | no_matching_page | no_result) / 1 helper_failed.

### `macro ime-paste` (live)

```powershell
& <wrapper> -AllowLiveControl macro ime-paste --text "안녕" [--press-enter] [--target-match Notepad] [--target-hwnd <n>]
```

- schema: `cucp.ime-paste/v1`
- 동기: SendInput WM_CHAR 가 IME 조합 모드에서 한글을 깨뜨리거나 분리. clipboard route 로 우회.
- 동작: `Clipboard.GetText` 백업 → `SetDataObject(text, persist=true)` → `SendKeys "^v"` →
  `Clipboard.SetDataObject(old)` 복구. 마우스 안 움직임.
- 보안: `--target-match` / `--target-hwnd` 가드 통과해야 paste, hit-test 실패 시 exit 3.
- exit: 0 ok / 3 blocked(target_mismatch) / 2 partial / 1 error.

### `macro safe-type-ime` (live)

```powershell
& <wrapper> -AllowLiveControl macro safe-type-ime --text "회의록" --target-match Notepad [--press-enter] [--verify-title Notepad]
```

- schema: `cucp.safe-type-ime/v1`
- 동기: 기존 `safe-type` 의 race (probe → main_type focus 손실) 회피.
- 흐름: `focus(--target-match)` → 80ms 대기 → `ime-paste` → 선택적 `--verify-title` 검사 (windows enum).
- 출력에 `focus`, `paste`, `verify` evidence 포함.
- exit: 0 ok / 3 blocked / 2 partial / 1 error.

### `macro modal-detect` (read-only)

```powershell
& <wrapper> macro modal-detect [--match <s>] [--target-hwnd <n>]
```

- schema: `cucp.modal-detect/v1`
- 동작: UIA root.FindAll(ControlType=Window|Pane) → IsModal + dialog class name +
  작은 윈도우 크기 점수화 → 정렬된 `modal_candidates[]`.
- 추천: `dismiss_or_confirm` (score≥100) / `confirm_dialog` (score≥60) / `wait` / `observe`.
- exit: 항상 0.

### `macro recovery-plan` (read-only)

```powershell
& <wrapper> macro recovery-plan [--match <s>] [--failed-step "<macro cmd>"] [--failed-reason <s>]
```

- schema: `cucp.recovery-plan/v1`
- 동작: `modal-detect` + foreground 결과 → rank 된 `recovery_candidates[]`.
- 후보 종류:
  - rank 1: `dismiss_modal` (modal 감지 + score≥100, command=`shortcut --keys escape`)
  - rank 2: `confirm_modal` (command=`shortcut --keys enter`)
  - rank 1 alt: `observe_dialog` / `find_dialog_button` (score≥60)
  - rank 1 fallback: `re_observe` (no modal)
  - rank 2 fallback: `retry_failed_step` (사용자 제공 step)
- 각 후보의 `live` / `sensitive` 플래그로 다음 호출 시 `-AllowLiveControl` / `--confirm-sensitive` 필요 여부 표시.
- exit: 항상 0.

### `macro recovery-run` (live, sensitive)

```powershell
# Plan only (안전, AllowLiveControl 불필요)
& <wrapper> macro recovery-run --dry-run

# Live actuation (sensitive gate)
& <wrapper> -AllowLiveControl macro recovery-run --confirm-sensitive [--match <s>]
```

- schema: `cucp.recovery-run/v1`
- 동기: recovery-plan 결과 중 가장 안전한 1개 (dismiss_modal 또는 observe_only) 자동 실행.
- **보안 게이트**:
  - `--dry-run` 단독: 누구나 실행 가능, plan 만 반환 (`status=ready`).
  - 그 외 live: `-AllowLiveControl` + `--confirm-sensitive` 둘 다 필수.
  - 둘 중 하나라도 없으면 exit 3 (`reason=sensitive_recovery_requires_confirmation`).
- exit: 0 ok / 3 blocked / 2 partial / 1 error.

### `macro precision-validate` (read-only)

```powershell
& <wrapper> macro precision-validate --x 1200 --y 720 [--target-match Kiro] [--samples 5]
```

- schema: `cucp.precision-validate/v1`
- 동기: 작은 toolbar 버튼 / canvas-인접 좌표가 라이브 클릭 전에 안정적인지 검증.
- 동작: 같은 (x,y) 에 대해 `hit-scan` 을 N번 (1~20, 기본 5) 반복 → 각 결과의 best 좌표 →
  평균 점에서의 거리 계산 → `drift_max` / `drift_avg` / `stable` (≤2px) 판정.
- recommendation:
  - `safe_to_use_anchor` (drift_max ≤ 2px)
  - `use_with_micro_refine` (drift_max ≤ 5px)
  - `use_uia_pattern_or_relabel` (drift_max > 5px)
- exit: 항상 0.

### `macro benchmark` (read-only)

```powershell
& <wrapper> macro benchmark [--iters 3]
```

- schema: `cucp.benchmark/v1`
- 측정 대상 (모두 read-only native helper actions):
  - `windows` (SLO 600ms)
  - `health` (400ms)
  - `focused` (500ms)
  - `modal-detect` (800ms)
- 출력: per-target `p50_ms` / `p95_ms` / `avg_ms` / `slo_ms` / `slo_ok` / `samples[]`,
  전체 `slo_pass_count` / `slo_pass_rate_pct` / `recommendation`.
- 보안: 텍스트 / PII 미수집, 타이밍 / 카운트 / 에러 메시지만.
- exit: 항상 0.

### `macro release-notes` (read-only, secret redact)

```powershell
& <wrapper> macro release-notes                     # latest 1건
& <wrapper> macro release-notes --version 1.4.0     # 특정 버전
& <wrapper> macro release-notes --since 1.3.0       # 1.3.0 이상
```

- schema: `cucp.release-notes/v1`
- 동작: CHANGELOG.md 를 `## v?(\d+\.\d+\.\d+)` 헤더로 split →
  각 버전 body 에서 `### Added/Improved/Verified/Fixed` 라인 분리 →
  `_Cucp-RedactSecrets` 로 secret 패턴 치환 후 emit.
- redact 패턴 (6종):
  - GitHub PAT: `\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}` → `[REDACTED:github_pat]`
  - OpenAI API key: `\bsk-[A-Za-z0-9]{20,}` → `[REDACTED:openai_key]`
  - AWS access key: `\bAKIA[A-Z0-9]{16}\b` → `[REDACTED:aws_key]`
  - Bearer token: `(?i)bearer\s+[A-Za-z0-9_\-\.=]{20,}` → `[REDACTED:bearer]`
  - JWT: `eyJ[...]\.[...]\.[...]` → `[REDACTED:jwt]`
  - PEM private key: `-----BEGIN [...] PRIVATE KEY-----` → `[REDACTED:pem_block]`
- 출력에 `migration_notes` / `external_agent_usage` 포함.
- exit: 0 ok / throw 시 1.

## 표준 exit code (재확인)

- `0` ok
- `1` generic / not_found / helper_failed / 입력 누락
- `2` partial / ambiguous / cdp_port_closed / no_match
- `3` safety blocked (sensitive_recovery_requires_confirmation, target_mismatch, missing -AllowLiveControl 등)
- `124` timeout (wrapper -InvokeTimeoutMs)
