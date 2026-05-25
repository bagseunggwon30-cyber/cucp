# CUCP Changelog

## v1.3.0 — Electron CDP integration (2026-05-25)

### 큰 틀 목표 달성

CUCP 가 Electron 앱 (Kiro / VS Code / Slack / Discord / Notion / Postman 등 chromium 기반)
에 대해서는 좌표 클릭이 아닌 **DOM API 로 element 직접 제어**. UIA tree 에 안 보이는
contenteditable / nested input 도 안정적으로 focus + value set + dispatchEvent.

### 동기 — 라이브 검증 사이클의 결론

좌표/UIA 길의 본질적 한계가 명확해짐:

| 라이브에서 발견된 문제 | 좌표/UIA 한계 | CDP 가 해결 |
|---|---|---|
| Kiro AI 입력란 좌표 정확한데 textarea focus 안 잡힘 | UIA tree 에 contenteditable 미노출 | `element.focus()` 한 줄 |
| 메이플 Chrome 이 Kiro 위에 떠서 hit-test 가 다른 윈도우 잡음 | 좌표 기반 본질적 한계 | DOM 은 윈도우 layout 무관 |
| Kiro 가 창모드 ↔ 전체화면 토글 시 좌표 의미 잃음 | 좌표 기반 본질적 한계 | DOM 좌표 계산 안 함 |
| OCR 이 작은 폰트 입력란 안 텍스트 못 잡음 (false negative) | 시각 기반 한계 | DOM `element.value` 직접 |
| `safe-type` 매크로 main_type_blocked race | helper child process race | CDP WebSocket 단일 connection |

### Added — Native helper

- **`-Action cdp-detect [-CdpPort 9222]`** (read-only)
  - `/json/version` + `/json/list` 으로 디버그 포트 + 페이지 목록 조회
- **`-Action cdp-eval -CdpExpr "<js>" [-CdpPageMatch Kiro]`** (read-only) — JS 실행
- **`-Action cdp-type -CdpSelector "<css>" -Text "<msg>" [-PressEnter] [-ClearFirst]`**
  - DOM selector → focus + value/textContent set + input/change event dispatch
  - `KeyboardEvent('keydown'/'keypress'/'keyup', { key:'Enter', ... })` 정확히 dispatch
  - **마우스 좌표 안 씀, 화면 위치 무관**
- **`-Action cdp-click -CdpSelector "<css>"`** — `element.click()` + scrollIntoView

### Added — Wrapper macros

- `macro cdp-detect [--port N]` (read-only)
- `macro cdp-eval --expr "<js>" [--page-match X]` (read-only)
- `macro cdp-type --selector "<css>" --text "<msg>" [--press-enter] [--clear-first]` (-AllowLiveControl 필수)
- `macro cdp-click --selector "<css>"` (-AllowLiveControl 필수)

### Internal — CDP 클라이언트

- `_Cdp-HttpGet` — HTTP /json/list (System.Net.WebRequest)
- `_Cdp-WsCall` — WebSocket 단일 명령 (ClientWebSocket, .NET 4.5+)
  - JSON message id auto-increment + response correlation
  - Event 메시지 자동 무시 (id 매칭만)
- `_Cdp-Detect` — 포트 + 페이지 detect
- `_Cdp-FindPage` — title/url 부분일치로 페이지 선택

### Documentation

- **`references/cdp-setup.md`** 신규 — Kiro / VS Code / Slack 활성화 가이드
- 보안 주의 (localhost 내 다른 프로세스 DOM 접근 가능)

### Tests

- 신규 Pester 8건 (CDP detect / safety gates / direct envelope)
- **Pester 109/109 통과**, 178초

### Limits

| 시나리오 | 결과 |
|---|---|
| ✅ Electron 앱 + 9222 포트 활성 | DOM 직접 제어, 좌표 무관 |
| ⚠️ 디버그 포트 활성 안 됨 | partial(2) cdp_port_closed → 사용자 안내 |
| ⚠️ Kiro 재시작 필요 (런타임 토글 안 됨) | 한 번 작업 끊김 |
| ❌ Native Win32 앱 (메모장, XG5000) | CDP 미지원 → Stage 1~6 fallback |

### 솔직 평가

**라이브 검증 안 됨** — 9222 포트 닫혀있는 상태에서 코드 + 테스트만 통과. 실제
Kiro DOM 직접 입력은 사용자가 `--remote-debugging-port=9222` 옵션 추가해서 Kiro
재시작한 후 검증 가능. envelope 형식 / safety gates / partial 응답은 모두 검증됨.

---

## v1.2.0 — hit-test guard + safe-type (2026-05-25)

### 큰 틀 목표 달성

라이브 사고 두 가지 ((a) 코드 에디터 의도치 않은 입력, (b) Kiro 전체화면 → 창모드
변경) 의 본질인 "좌표 클릭 직전 검증 부재" 를 해결.

### Added — Native helper

- **`-Action hit-test -X N -Y N [-TargetMatch <s>] [-TargetHwnd N]`** (read-only)
  - Win32 `WindowFromPoint` + `GetAncestor(GA_ROOT)` 로 좌표가 어떤 윈도우 안인지
  - 출력: `{ child_hwnd, root_hwnd, root_title, process_name, matched, match_reason }`
- **`click` action 에 `-TargetHwnd / -TargetMatch` 가드** 추가
  - 좌표가 의도한 윈도우 안 아니면 status=blocked + exit 3
  - 메이플 라이브 케이스에서 실제로 차단 검증됨
- **`type` action 에 focus 가드** 추가
  - 현재 foreground 가 target 아니면 blocked + exit 3

### Added — Wrapper macros

- `macro hit-test --x N --y N [--target-match <s>]` (read-only)
- `macro safe-type --target-match <s> --click-x N --click-y N --text "<msg>" [--ctrl-enter] [--skip-probe] [--max-attempts N]`
  - focus + click (hit-test 가드) + probe (옵션) + main type + 전송 단축키
  - **-AllowLiveControl 필수**

### 솔직 평가

- `hit-test` action + 가드: ✅ **메이플 케이스로 라이브 검증 완료** — 의도치 않은 다른 윈도우 클릭 정확히 차단
- `safe-type` 매크로: ⚠️ probe 후 main_type race condition 미해결 → **legacy / Win32 앱용** 권장.
  Electron 앱은 v1.3.0 cdp-type 권장.

### Tests

- 신규 Pester 8건 (hit-test action / click guard / safety gates)
- **Pester 101/101 통과**

---

## v1.1.0 — smart-click history learning + PS5 audit (2026-05-25)

### 큰 틀 목표 달성

CUCP가 자율 작업의 클릭 결정을 점점 빨라지고 안정되게 만든다 — 이전에 성공한
cascade stage를 기억하고 거기서 시작하며, PS5 함정으로 인한 잠재 실패를 진단 가능.

### Added — smart-click history learning

`smart-click` 이 매번 cascade Stage 1 부터 시작하면 같은 라벨에 대해 시간 낭비.
v1.1.0 은 과거 시도를 NDJSON 으로 기록하고, 같은 (label, match) 의 최근 5건 중
가장 자주 성공한 strategy 를 자동 추천.

- **저장**: `%TEMP%\computer-use-control-plane\smart-click-history.ndjson`
- **레코드**: `{ts, label, match, strategy, success, elapsed_ms}`
- **추천 로직**:
  - `_History-PickBestStrategy` — 최근 5건 매칭, success=true 들의 strategy 빈도 계산
  - 최다 strategy 반환 (동률 시 더 최근 것)
  - 5건 모두 fail / 매칭 없음 → null (기존 cascade)
- **smart-click 통합**:
  - hint 가 있으면 그 stage 만 활성화 (앞 stages skip)
  - hint stage 가 fail 하면 cascade 전체 활성으로 자동 fallback (안전망)
  - 결과를 history append (성공 strategy 또는 "none" 실패)
- **--no-history**: 학습 비활성 옵션
- **rotate**: 1MB 또는 1000라인 초과 시 최신 800라인만 유지

### Added — macro history (NEW)

```powershell
& <wrapper> macro history stats              # 전체 통계 (성공률, strategy 분포)
& <wrapper> macro history show [--last N]    # 최근 N건
& <wrapper> macro history show --label X     # 특정 라벨만
& <wrapper> macro history clear              # 학습 데이터 삭제
```

JSON 출력은 `cucp.history/v1` schema.

### Added — references/audit-ps5-pitfalls.ps1 (PS5 함정 진단 도구)

CUCP 스크립트들의 PS5 알려진 함정 패턴을 read-only 진단:

1. **inline-if** statement context (`$x = if (...) {...}`) — numeric return 위험
2. **$args 자동변수** — 함수 매개변수와 충돌
3. **Get-Content 단일 라인 함정** — `@(Get-Content)` 강제 권장
4. **Start-Process ExitCode** — proc.Refresh() + by-PID + JSON fallback 패턴 권장

진단만 — 자동 수정 안 함 (이미 동작하는 코드 깰 위험). 결과 JSON 으로 출력.
실제 진단 결과: 146 findings (high 10 / medium 97 / low 39). high 10건 중 9건은
v0.9 까지 통과한 케이스라 위험도 낮음. 1건 (`screenshot-diff` 의 `$ratio = if`)
은 v0.9 에서 실제 깨져서 v0.9.0 sprint 에서 수정됨.

### Fixed — Get-Content 단일 라인 함정

`_History-PickBestStrategy / _History-Stats / Invoke-MacroHistory.show` 가
`Get-Content` 결과를 직접 사용하던 걸 `@(Get-Content ...)` 로 array 강제. 단일
라인 history 파일 (첫 번째 시도 후) 에서 `.Count` 가 string 길이로 잘못 동작
하던 잠재 버그 차단.

### Tests

- 신규 Pester 7건:
  - history macro 6건 (stats 빈/계산 / clear / show 라벨필터 / show JSON schema / 알 수 없는 subcommand)
  - smart-click --no-history 옵션 1건
- **Pester 93/93 통과**, 165초 (이전 86 + 신규 7)

### Limits

| 시나리오 | 결과 |
|---|---|
| ✅ 같은 (label, match) 반복 사용 | 평균 응답 단축 (cascade 앞 stages skip) |
| ✅ 학습된 strategy 가 환경 변화로 fail | 안전망 — cascade 전체 fallback 자동 |
| ⚠️ 매번 다른 label 사용 | 학습 효과 없음 (history hit 0) |
| ⚠️ corrupt NDJSON 라인 | try/catch 로 individual line 무시. 정렬은 어그러질 수 있음 |
| ⚠️ history 파일 동시 쓰기 | NDJSON append 는 atomic이지만 rotate 중엔 race 가능. 단일 사용자 PC 에선 무시 |

### 주석/리팩토링

- `Invoke-MacroSmartClick` 헤더 — v1.1.0 history learning 섹션 추가
- `_History-*` 함수들 — 책임 / NDJSON 형식 / 통계 로직 / rotate 정책 주석
- `references/audit-ps5-pitfalls.ps1` — PS5 함정 카테고리별 설명 + 권장 패턴

---

## v1.0.0 — Self-correcting click + diff masking + helper refactor (2026-05-25)

### 큰 틀 목표 달성

CUCP가 클릭 오류를 자기 발로 회복한다 — fusion 매칭은 Name 외 식별자까지,
diff 검증은 노이즈 영역을 마스킹하고, smart-click은 실패하면 다른 전략으로 자동 재시도.

### Added — Native helper

- **`-Action ocr-uia-invoke -OcrText <s>`**: fusion 탐색 + 곧바로 InvokePattern 호출
  - 한 프로세스 안에서 OCR 매칭 + UIA element 탐색 + element handle 직접 invoke
  - **UIA Name 비어있어도 동작** — AutomationId / ClassName 만 있어도 invoke
  - v0.9.0 의 fuse → wrapper 가 element name 으로 다시 uia-invoke 하던 우회 패턴
    이 Name 없는 element 에 대해 못 동작하던 한계를 닫음
  - 출력: method (InvokePattern/TogglePattern/SelectionItemPattern), uia_name,
    uia_automation_id, uia_class_name, mouse_moved=false
- **`-Action ocr-uia-fuse` 응답에 `preferred_identifier` 추가**:
  - "name" / "automation_id" / "class_name" / "none" 중 어느 키로 invoke 시도해야
    하는지 wrapper 에게 가이드
- **`-Action screenshot-diff` 의 `-DiffIgnoreRegions`**:
  - "x1,y1,w1,h1;x2,y2,w2,h2" 형식. 동영상/애니메이션 영역 마스킹
  - 응답에 `effective_pixels` (= total - ignored), `ignored_pixels`, `ignored_regions` 추가
  - false positive (동영상 자동 재생으로 changed=True) 방지

### Added — Wrapper macros

- **`macro ocr-uia-invoke --text <s> [--match] [--match-window] [--language]`**:
  - **-AllowLiveControl 필수** (실제 actuation, 마우스 안 움직임)
  - trajectory 자동 기록
- **`macro screenshot-diff --ignore-region "x,y,w,h;x2,y2,w2,h2"`** 옵션 추가
- **`macro smart-click --retry-on-no-change N`** 옵션 추가:
  - `--verify-screen-changed` 활성 + 화면 변화 없을 때 cascade 한 번 더 시도
  - 한 번 더 시도하는 stage: UIA Pattern → fusion (둘 중 가장 가능성 높은 둘)
  - 결과에 `retries=N` 보고

### Changed — smart-click cascade Stage 4 업그레이드

기존 Stage 4 (fusion) 는 `ocr-uia-fuse` (read-only) → wrapper 가 element Name 으로
다시 `uia-invoke` 우회 호출. Name 비어있는 element 는 못 잡았음.

신규 Stage 4 는 `ocr-uia-invoke` 한 번에 처리 — element handle 직접 invoke.
Name 비어도 OK. `fusion_uia_invoke` strategy 로 보고됨.

### Refactored — native-helper 공통 OCR 헬퍼 추출 (v1.0.0)

OCR 관련 action 4개가 똑같은 캡처+OCR+매칭 흐름을 4번 복사하던 걸 헬퍼로 통합:

- **`_Capture-ScreenRegionToTempPng`** — 화면 영역 캡처 → 임시 PNG 경로 반환
  - 영역 결정 (vx/vy/vw/vh fallback), MaxImageDimension 검사, GUID temp path
- **`_Match-OcrCandidates`** — OCR result body 에서 needle score 매칭 후보들 반환
  - line + word 단위 모두 시도, score 내림차순 정렬, PS5 array 함정 회피

`_Action-OcrFindText / _Action-OcrUiaFuse / _Action-OcrUiaInvoke` 가 이 두 헬퍼를
공유. 코드 중복 ~120 라인 → ~30 라인 (4배 줄임).

### Comments — 의도/근거 주석 보강 (v1.0.0)

핵심 함수에 "왜 이렇게 짰는지" + "PS5 함정" 주석 추가:

- 파일 헤더: 책임 / exit code 매핑 / PS5 함정 (inline-if, $args, JSON 출력 방식, BOM)
- `Invoke-NativeHelper`: 3-tier exit code fallback (proc.Refresh → by-PID → JSON status)
  의 근거와 v0.6.0~0.8.0 잠재 버그 설명
- `Invoke-MacroSmartClick`: 6단계 cascade 의 우선순위 + 각 stage 의 안전 정책

### Tests

- 신규 Pester 7건:
  - ocr-uia-invoke safety gates 3건 (`-AllowLiveControl` 없으면 3 / `--text` 없으면 throw / 매칭 없으면 partial(2))
  - screenshot-diff ignore-region 2건 (마스킹 없이 changed=True / 마스킹 시 changed=False)
  - native-helper direct 2건 (ocr-uia-invoke partial / ocr-uia-fuse preferred_identifier)
- **Pester 86/86 통과**, 142초 (이전 79 + 신규 7)

### Limits

| 시나리오 | 결과 |
|---|---|
| ✅ OCR + UIA Name 있는 element | uia_invoke 정확 |
| ✅ OCR + UIA Name 비고 AutomationId 있는 element | v1.0.0 부터 ocr-uia-invoke 로 OK (이전엔 fail) |
| ✅ 동영상 영역 마스킹 후 diff | false positive 제거 |
| ⚠️ retry-on-no-change | 단순화 — Stage 1/4 만 재시도. icon-find 나 vision 은 재시도 안 함 (비용 우려) |
| ⚠️ ignore-region picker | 사용자가 좌표를 직접 알아야 함. 자동 마스크 추출은 v1.1.0 후보 |

---

## v0.9.0 — OCR+UIA fusion + screenshot diff verify (2026-05-25)

### 큰 틀 목표 달성

CUCP가 클릭 **전에는** OCR과 UIA를 융합해서 가장 정확한 element를 찾고,
**후에는** 화면 변화를 자동으로 검증한다.

이걸로 v0.7.0 의 Kiro send 화살표 사례에서 마지막 남은 두 가지 약점을 닫았다:

1. "OCR이 보지만 UIA는 못 쓰는 좌표 클릭의 위험성" → fusion 으로 InvokePattern 변환
2. "클릭이 정말 통했는지 모름" → screenshot-diff 로 픽셀 단위 검증

### Added — Native helper

- **`-Action ocr-uia-fuse -OcrText <s>`**: OCR 1순위 좌표 위에 UIA element 가
  있는지 확인 (read-only). InvokePattern/TogglePattern/SelectionItemPattern 지원
  여부 판단. 결과:
  - `recommendation: "uia_invoke"` — UIA Pattern 호출 가능 (마우스 안 움직임)
  - `recommendation: "ocr_click"` — UIA element 없거나 패턴 미지원 → 좌표 클릭 fallback
  - `recommendation: "low_confidence_skip"` — OCR score < 70, 거부
- **`-Action screenshot-diff -DiffBefore <png> -DiffAfter <png> [-DiffThreshold N]`**:
  두 PNG 의 픽셀 단위 RGB 변화율 측정. LockBits + Marshal.Copy 로 빠른 직접 접근.
  - 1920x1080 PNG 두 장 비교 ~600ms
  - 출력: `changed_ratio` (0.0~1.0), `changed=bool` (0.1% 이상이면 true)

### Added — Wrapper macros

- **`macro ocr-uia-fuse --text <s> [--match contains|exact|prefix] [--match-window]`**:
  fusion 결과 보고 (read-only)
- **`macro screenshot-diff --before <png> --after <png> [--threshold N] [--region]`**:
  PNG diff (read-only)
- **`macro click-and-verify-screen --x <n> --y <n> [--button] [--region] [--wait-ms]`**:
  before 캡처 → 클릭 → after 캡처 → diff. 변화 없으면 partial(2). `-AllowLiveControl` 필수.

### Changed — smart-click cascade (5 → 6 단계)

기존:
```
1. UIA Pattern → 2. UIA 좌표 → 3. icon-find → 4. OCR text → 5. vision-precise
```

신규:
```
1. UIA Pattern (마우스 안 움직임)
2. UIA 좌표 (--allow-mouse-fallback)
3. icon-find (--allow-mouse-fallback)
4. OCR+UIA fusion ← NEW. UIA element 있으면 InvokePattern (마우스 안 움직임!)
5. OCR text 좌표 (--allow-mouse-fallback)
6. vision-precise (--allow-vision)
```

Stage 4가 핵심: OCR이 텍스트는 보지만 UIA Name 이 비어있어 `uia-find` 로 못 잡는
Electron 일부 표면에서, OCR 좌표 위 UIA element 의 Name 을 알아내 `uia-invoke`
재시도. 성공하면 마우스 안 움직임으로 클릭됨.

### Added — smart-click verify-screen-changed 옵션

```powershell
& <wrapper> -AllowLiveControl macro smart-click --label "Save" --verify-screen-changed
```

cascade 시작 전 foreground 윈도우 영역 캡처 → cascade 끝 → wait → 다시 캡처 → diff.
화면이 변하지 않았으면 `screen_unchanged` partial(2). "클릭은 됐는데 아무 일도 안
일어났다" 케이스를 명시적으로 잡음.

### Fixed — wrapper exit code propagation 버그 (v0.6.0~0.8.0 잠재 버그)

`Invoke-NativeHelper` 가 helper 의 partial(2) / error(1) 를 항상 0 으로 반환하던
버그 수정. 원인: `Start-Process -PassThru -Wait` 로 만든 Process 객체에서
`$proc.ExitCode` 가 `InvalidOperationException` 을 던지는 케이스가 있었음.

해결:
- `proc.Refresh()` + by-PID 재조회 + JSON `status` 기반 보정 (3-tier fallback)
- 이제 `macro ocr-image --path <missing>` → exit 1 (was: 0)
- `macro ocr-uia-fuse --text <no-match>` → exit 2 (was: 0)

### Tests

- 신규 Pester 8건:
  - safety gates 3건 (click-and-verify-screen / ocr-uia-fuse / screenshot-diff)
  - screenshot-diff 3건 (same / different / missing-path)
  - ocr-uia-fuse 1건 (no-match → partial(2) + recommendation)
  - native-helper screenshot-diff 직접 호출 1건
- **Pester 79/79 통과**, 117초 (이전 71 + 신규 8)

### Limits — fusion 의 정확도

| 시나리오 | fusion 결과 |
|---|---|
| ✅ OCR 보고 UIA Name 있는 element | uia_invoke 추천 (마우스 안 움직임) |
| ✅ OCR 보지만 UIA element 없음 | ocr_click 추천 (좌표 클릭 fallback) |
| ⚠️ UIA element 있는데 Name 비어있음 | UIA element 의 AutomationId/Class 있어도 uia-invoke 는 Name 으로 매칭 → fallback to coord |
| ⚠️ OCR score < 70 | low_confidence_skip — 안전 거부 |
| ❌ DRM / 게임 | OCR 화면 캡처 실패 |

### Limits — screenshot-diff 의 한계

| 시나리오 | diff 동작 |
|---|---|
| ✅ 메뉴 열림, dialog 등장, 색깔 변화 | changed=True 정확 |
| ⚠️ 마우스 커서가 캡처에 잡혀 약간 변함 | changed_ratio < 0.001 → changed=False (의도) |
| ⚠️ 동영상/애니메이션 자동 재생 표면 | 클릭 안 해도 changed=True (false positive) |
| ❌ off-screen 변화 | foreground 영역만 비교하므로 못 잡음 |

---

## v0.8.0 — OCR 통합 (Windows.Media.Ocr) (2026-05-25)

### 큰 틀 목표 달성

CUCP가 Windows 데스크톱의 어떤 표면이든 — 표준 앱 / Electron / 브라우저 캔버스 /
이미지 안 텍스트 — 가장 정확한 방법으로 클릭/조작합니다.

표면별 cascade:

| 표면 | 1순위 | 2순위 | 3순위 | 4순위 | 5순위 |
|---|---|---|---|---|---|
| 표준 Win32/UWP | UIA Pattern | UIA 좌표 | icon-find | OCR | (vision) |
| Electron | UIA Pattern | UIA 좌표 | icon-find | OCR | (vision) |
| 브라우저 캔버스 | — | — | — | OCR | (vision) |
| 이미지 안 텍스트 | — | — | — | OCR | (vision) |
| DirectX 게임 | 거부 (정책) |  |  |  |  |

### Added — Native helper

OCR 엔진은 **Windows.Media.Ocr** (UWP Runtime API). Windows 10/11 기본 내장이라
별도 설치 불필요. 사용자 시스템 언어팩에 따라 한국어/영어/일본어/중국어 등 25+ 언어 지원.

- **`-Action ocr-image -OcrPath <png>`**: 임의 PNG 파일 OCR
  - 출력: 라인/단어 + BoundingRectangle (이미지 픽셀 좌표)
- **`-Action ocr-screen [-ScreenshotX/Y/W/H]`**: 화면 영역 캡처 + OCR
  - 출력: 라인/단어 + BoundingRectangle (절대 화면 좌표)
- **`-Action ocr-find-text -OcrText <s> [-OcrMatch contains|exact|prefix]`**:
  - 화면(또는 -OcrPath PNG)에서 텍스트 위치 찾기
  - 점수 매칭 (exact=100, prefix=80, contains=50~95)
  - 출력: 후보들 (점수 내림차순) + top.cx/cy 클릭 좌표
- `-Action health` 가 `ocr` / `ocr_languages` / `ocr_engine_language` 추가 노출

### Added — Wrapper macros

- **`macro ocr-image --path <png> [--language ko]`**: PNG OCR (read-only)
- **`macro ocr-screen [--region x,y,w,h] [--language ko]`**: 화면 OCR (read-only)
- **`macro ocr-find-text --text <s> [--match contains|exact|prefix] [--region ...]`**:
  - 화면/이미지에서 텍스트 위치 찾기 (read-only). 클릭 좌표만 반환.
- **`macro ocr-click --text <s> [--match ...] [--button left|right|double] [--min-score 70]`**:
  - OCR로 좌표 찾고 즉시 클릭. **`-AllowLiveControl` 필수** (라이브 actuation).
  - score < min-score → partial(2) 거부 (잘못된 텍스트 클릭 방지)

### Changed — smart-click cascade

기존 4단계 → **5단계** 로 확장. OCR 단계가 icon-find 다음, vision 직전에 삽입됨.

```
Stage 1: UIA Pattern  (마우스 안 움직임)
Stage 2: UIA 좌표      (--allow-mouse-fallback 필요)
Stage 3: icon-find     (--allow-mouse-fallback 필요)
Stage 4: OCR text     (--allow-mouse-fallback 필요, default ON, --no-ocr 로 끔)
Stage 5: vision-precise (--allow-vision 필요)
```

OCR Stage는 default ON이지만 좌표 클릭이라 `--allow-mouse-fallback` 게이트는 통과해야 함.

### Tests

- 신규 Pester 8건:
  - OCR safety gates 2건 (ocr-click without -AllowLiveControl, missing --text)
  - Native helper OCR actions 3건 (ocr-image, ocr-find-text 매칭, ocr-find-text no-match → partial)
  - Wrapper macros 3건 (ocr-image brief, ocr-find-text brief, native-health 가 ocr 노출)
- **Pester 71/71 통과**, 84초 (이전 63건 + 신규 8건)

### Limits — OCR이 잘 안 되는 경우

| 표면 | OCR 결과 |
|---|---|
| ✅ 영어/한국어 일반 글씨 (12pt+) | 정확도 매우 높음 (synthetic 테스트 score=100) |
| ✅ 안티에일리어스 + 충분한 대비 | OK |
| ⚠️ 매우 작은 폰트 (8pt 이하) | 정확도 떨어짐, 부분 매칭만 가능 |
| ⚠️ 회전된/기울어진 텍스트 | 인식 안 됨 |
| ⚠️ 비표준 폰트 / 손글씨 | 인식 안 됨 |
| ⚠️ 저대비 / 그라데이션 배경 | 정확도 크게 떨어짐 |
| ❌ 게임 UI 일부 (rasterize 시점 의존) | 캡처 자체가 안 될 수 있음 |
| ❌ DRM 보호 화면 (Netflix 등) | 검은 화면 캡처 |

### Limits — 정책

- DirectX/게임 표면은 anti-cheat / exclusive fullscreen 시 capture 실패 가능
- 그 경우 borderless/windowed mode 권장
- UAC, 비밀번호, 결제, 신분 인증 화면은 OCR + 자동 클릭 모두 정책상 거부

---

## v0.7.0 — UIA Pattern 직접 호출 + smart-click cascade (2026-05-25)

### Kiro send 화살표 사례에서 발견된 정확도 문제 해결

전 sprint에서 Codex가 Kiro 보라색 send 화살표를 못 찾고 여러 번 빗나가다가
결국 잘못된 버튼을 눌러 명령이 정지된 사례 — **세 가지 근본 원인**을 다 해결:

1. **UIA 데이터 무시하고 vision으로 직행** → UIA Pattern 직접 호출 추가
2. **Ambiguity 거부 안 됨** → score<60 자동 partial(2) 거부
3. **연속 관찰 부재** → `macro watch` 추가

### Added — Native helper

- **`-Action uia-invoke`**: InvokePattern.Invoke() 직접 호출
  - 마우스가 움직이지 않음 (`mouse_moved=false`)
  - Button/MenuItem/Hyperlink/SelectionItem/ExpandCollapse 패턴 cascade
  - 화면이 가려져도 동작 (BoundingRectangle만 알면 됨)
  - 신뢰도 score<60 매칭은 Pattern 호출 거부 (low_confidence_match → partial)
- **`-Action uia-set-value`**: ValuePattern.SetValue() 직접 호출
  - Edit/ComboBox에 키보드 시뮬레이션 없이 값 즉시 설정
  - 한글/이모지/긴 텍스트 한 번에, IME 안 거침
- **`-Action uia-toggle`**: TogglePattern.Toggle() 직접 호출
  - 체크박스/라디오 상태 전환

### Added — Wrapper macros

- **`macro uia-invoke --label <text>`**: UIA Pattern 직접 호출 wrapper
- **`macro uia-set-value --label <text> --value <text>`**: 값 설정
- **`macro uia-toggle --label <text>`**: 토글
- **`macro smart-click --label <text>`**: Cascade 전략 통합
  - Stage 1: UIA Pattern (마우스 안 움직임) ← 가장 안정적
  - Stage 2: UIA 좌표 클릭 (`--allow-mouse-fallback`)
  - Stage 3: icon-find synonym 매칭 (`--allow-mouse-fallback`)
  - Stage 4: vision-click-precise (`--allow-vision`)
  - score<60 → 즉시 거부 (잘못된 element 클릭 방지)
  - `--verify-label` 으로 클릭 후 의도 검증
- **`macro watch --interval-ms N --max-cycles M [--until-label X]`**: 연속 관찰
  - foreground 변화 감지 (delta=init/same/changed)
  - 자율 작업 중 화면 변화를 모르고 캐시된 좌표로 재시도하는 문제 방지

### Fixed

- `_Action-UiaFind` 가 SetOut/RestoreOut redirect 에서 stdout이 비어있는 race condition 수정 (in-process resolver 직접 호출로 변경)

### Tests

- 신규 Pester 8건:
  - UIA Pattern safety gates 4건 (uia-invoke/set-value/toggle/smart-click)
  - Low-confidence rejection 1건
  - Watch 2건 (cycles + until-label)
  - Native helper UIA Pattern 1건 (한글 라벨 매칭)
- **Pester 63/63 통과**, 163초

### Limits

| 표면 | uia-invoke 동작 |
|---|---|
| ✅ 표준 Button (Win32/UWP) | InvokePattern.Invoke() — 마우스 안 움직임 |
| ✅ 메뉴 항목 | InvokePattern 또는 ExpandCollapsePattern |
| ✅ 체크박스/라디오 | uia-toggle 권장 (TogglePattern) |
| ✅ Edit/ComboBox 값 입력 | uia-set-value (ValuePattern) |
| ⚠️ 일부 Electron 버튼 | UIA에 노출되지만 InvokePattern 미지원 → smart-click 의 Stage 2/3 fallback 사용 |
| ❌ 브라우저 캔버스 (YouTube 등) | UIA 미지원 → smart-click `--allow-vision` 으로만 |

---

## v0.6.0 — Native helper sprint (이전)
- `cucp-native-helper.ps1` Win32 + UIA + Screenshot 직접 호출
- 외부 windows-mcp / Codex helper 의존 제거
- `_Validate-CliMjs` 로 잘못된 cli.mjs (CUCP Lite 등) 거부

## v0.5.0 — Selector ranking + observation envelope (이전)
- `cucp.observation/v1` 통합 envelope
- Selector ranking + `--explain`
- `find-label --fast`, `icon-find`, `vision-click-precise`

## v0.4.0 — Diagnostics (이전)
- `diagnose-lag`, `cleanup`, `log-tail`
- `health-quick` vs `health-detail` 분리

## v0.3.0 — Win32 fallback (이전)
- helper 빈 응답 시 Win32 EnumWindows 자동 fallback

## v0.2.0 — Safety gates (이전)
- `-AllowLiveControl`, `--after` 강제, ambiguity 거부

## v0.1.0 — Initial (이전)
- 기본 매크로: `click-label`, `fill-label`, `shortcut`, `goal`

### Added — 외부 helper 의존 제거

CUCP가 더 이상 Windows MCP helper나 Codex 공식 helper(`~/.codex/bin/codex-win.ps1`)에 우회 의존하지 않습니다.

- **`scripts/cucp-native-helper.ps1`** 신규
  - Win32 P/Invoke (user32.dll): `EnumWindows`, `SendInput`, `GetForegroundWindow`, `BringWindowToTop`, `SetForegroundWindow`, `SetCursorPos`, `GetSystemMetrics`
  - UIAutomationClient: 일반 Windows 앱의 BoundingRectangle 기반 결정론적 element 추출
  - System.Drawing: `Graphics.CopyFromScreen`을 통한 PNG 캡처
  - 11개 action: `health`, `windows`, `focused`, `focus`, `screenshot`, `click`, `type`, `shortcut`, `uia-tree`, `uia-find`, `uia-click`
- **신규 매크로 7개 (cucp.ps1)**
  - `macro native-health` — helper 자체 health (Win32 + UIA 가용성)
  - `macro native-windows [--match]` — EnumWindows 기반 윈도우 enum
  - `macro native-screenshot [--out-path] [--x --y --width --height]` — PNG 캡처
  - `macro click-point --x --y [--button left|right|middle|double]` — 좌표 클릭
  - `macro type-native --text [--clear] [--enter]` — 유니코드 텍스트 (한글/이모지)
  - `macro shortcut-native --keys "ctrl+s"` — 단축키
  - `macro uia-click-label --label [--match] [--role]` — UIA BoundingRectangle 기반 결정론적 클릭

### Changed — resolver 안전성

- `_Find-CliPath` 가 `_Validate-CliMjs`를 호출해 잘못된 cli.mjs(예: CUCP Lite 같은 판매용 워크플로 검증 도구)를 자동으로 거부합니다. `package.json` name 또는 cli 본문 시그니처(`ControlPlane`, `observeAppshot`)로 검증.
- `Invoke-Cucp`는 `cli.mjs`를 못 찾으면 즉시 envelope 에러 반환(`error_type: cli_missing` + recommended_action).

### Tests

- 신규 Pester 9건:
  - `cucp native helper - read-only` (3건): native-health, native-windows, native-screenshot
  - `cucp native helper - safety gates` (4건): click-point/type-native/shortcut-native/uia-click-label가 -AllowLiveControl 없으면 exit 3
  - `cucp native helper - direct invocation` (2건): helper 자체 호출이 health JSON / windows enum 반환

### Limits — 솔직한 한계

| 표면 | 동작 |
|---|---|
| ✅ 표준 Win32/UWP 앱 (메모장, 탐색기, Office, XG5000 등) | UIA + 좌표 모두 결정론적 |
| ✅ Electron 앱 (Codex/Kiro/Discord 등) | UIA 트리 노출됨, 동작 |
| ⚠️ 브라우저 캔버스 (YouTube 재생 버튼, 게임 안 클릭) | UIA에 안 잡힘. `vision-click-precise` 또는 좌표 직접 (`click-point`) |
| ⚠️ DirectX 게임 / exclusive fullscreen | screenshot 캡처 자체가 검은 화면일 수 있음 |
| ❌ Anti-cheat 보호 게임 (Vanguard, EAC 등) | SendInput 차단됨, 운영체제 정책상 정상 |
| ⚠️ UAC 다이얼로그 / Windows Hello / 비밀번호 입력 | 정책상 자동 조작 금지 (`-AllowLiveControl` 게이트 외에도 사용자 명시 승인 필요) |
| ⚠️ DPI scaling 다른 모니터 | 좌표 계산은 가상 데스크톱 기준, 일부 앱은 per-monitor DPI 영향 받음 |

### Recommended actions for limited surfaces

- **브라우저 캔버스**: `cucp macro vision-click-precise --describe "the play button"` 또는 좌표 직접 + screenshot diff 검증
- **DirectX 게임**: 가능하면 borderless windowed 모드로 전환, 그래도 안 되면 사용자에게 직접 조작 요청
- **Anti-cheat**: 자동화 시도 금지. 정책 위반 시 계정 정지 위험

### Migration notes

기존 사용자:
- `macro click-label`/`fill-label`/`shortcut`은 그대로 동작 (cli.mjs가 잡히는 경우)
- cli.mjs를 못 찾는 환경에서도 새 native 매크로(`uia-click-label`, `click-point`, `type-native`, `shortcut-native`)는 동작
- 환경변수 `CUCP_CLI_PATH`로 cli.mjs 경로 강제 지정 가능

---

## v0.5.0 — Selector ranking + observation envelope (이전)
- `cucp.observation/v1` 통합 envelope
- Selector ranking + `--explain`
- `find-label --fast`, `icon-find`, `vision-click-precise`

## v0.4.0 — Diagnostics (이전)
- `diagnose-lag`, `cleanup`, `log-tail` (bounded read + secret redact)
- `health-quick` vs `health-detail` 분리

## v0.3.0 — Win32 fallback (이전)
- helper 빈 응답 시 Win32 EnumWindows 자동 fallback
- `degraded_helper_empty` 플래그

## v0.2.0 — Safety gates (이전)
- `-AllowLiveControl`, `--after` 강제, ambiguity 거부

## v0.1.0 — Initial (이전)
- 기본 매크로: `click-label`, `fill-label`, `shortcut`, `goal`
