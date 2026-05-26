---
name: cucp-computer-use
description: Use the local CUCP (Computer Use Control Plane) CLI from any Codex project to observe, ground, and operate the user's Windows desktop at Claude Computer Use grade. Trigger on cucp, CUP, computer use, computer-use, Windows control, desktop control, appshot, snapshot, live benchmark, desktop benchmark, screen control, GUI automation, PC/app control, "컴퓨터 유즈", "컴퓨터 사용", "컴퓨터 조작", "내 컴퓨터 조작", "내 컴퓨터를 조작", "내 PC 조작", "앱 조작", "윈도우 조작", "화면 조작", "데스크톱 자동화", "자동화 실행", "GUI 자동화", "라벨 클릭", "버튼 클릭해줘", or whenever the user asks Codex to inspect, click, type, drag, scroll, switch apps, follow a goal, or autonomously operate the local Windows desktop.
---

# CUCP Computer Use (Claude-grade)

CUCP wrapper:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 [-AllowLiveControl] [-Brief] [-Quiet] [-CacheSeconds <n>] [-InvokeTimeoutMs <n>] <args>
```

핵심 4가지:
1. **Unified observation envelope** (`cucp.observation/v1`) — windows/find-label/list-affordances/health-quick/log-tail가 같은 schema/sources/provenance/cache/recoverable_errors 반환
2. **Win32 deterministic fallback** — helper가 빈 결과여도 `macro windows`는 EnumWindows로 항상 답함
3. **Selector ranking + ambiguity** — find-label은 exact / substring / role / source-confidence 점수 정렬, 동률(±10) 시 partial(2). `--explain` 으로 근거 노출
4. **Composite macros** — 라벨 매칭, 자가 검증, 자율 목표, working memory

상세 명령은 [`references/command-reference.md`](references/command-reference.md), 진단·복구·셀렉터 점수표·perf 해석은 [`references/troubleshooting.md`](references/troubleshooting.md).

## When to Activate

- 관찰: "지금 화면 뭐야", "이 앱 상태 봐줘", "appshot 찍어줘", "윈도우 목록"
- 조작: "확인 버튼 클릭", "이름 필드에 입력", "메모장 켜고 hello 써줘"
- 자율: "Notepad 열고 저장까지 해줘", "X 메뉴 들어가서 Y 설정 바꿔줘"

## Operating Loop

`Observe → Think → Act → Verify`. 모든 라이브 작업을 이 4단계로:

1. **Observe**: `macro windows` (Win32) 또는 `macro find-label --explain`
2. **Think**: envelope의 `foreground`, `windows[]`, `top` 후보, `ambiguous` 플래그로 결정
3. **Act**: `macro click-label / fill-label / shortcut` 우선, 좌표는 fallback (`--after` 필수)
4. **Verify**: 직후 `macro windows` 또는 `find-label`. focus 대상은 `macro focus-verify`

복구: `recoverable_errors[].recommended_action` 그대로 따라가기. helper 빈 응답 → win32 fallback (`degraded_helper_empty=true`).

## Safety Defaults

- 기본 read-only: `observe *`, `macro windows / find-label / list-affordances / health-quick / health-detail / metrics / perf / log-tail / trajectory / wait-window / wait-label`
- 라이브 컨트롤은 **모두 `-AllowLiveControl` 필수**: `act *`, `app switch`, `plan run`, `scenario run --execute`, `desktop benchmark *`, `l5 run/resume`, 모든 actuation 매크로 (`click-label`, `fill-label`, `focus-window`, `focus-verify`, `shortcut`, `goal`, `app-launch/close/with-app`, `auto-do`, `vision-click`, `click-and-verify`)
- 좌표 기반 act은 `--after <observation-id>` 강제
- UAC, 비밀번호, 결제, 자격증명은 사용자 명시 허락 후만
- helper 멈춤 보호 옵션은 [Wrapper Flags](#wrapper-flags) 참고

## Low-lag operating pattern (Codex + Kiro 동시 사용)

긴 세션에서 Codex/Kiro 데스크톱 앱이 느려질 수 있어요. 권장:

- 자주 쓰는 read-only는 `macro windows`, `macro health-quick` (helper 안 부름)
- 반복 screenshot/vision-click 피하기, 필요하면 `--no-vision`
- 긴 세션 시작 전 `macro cleanup --dry-run` 으로 wrapper-cache 점검 → 필요시 `--execute`
- `macro perf --iters 1` (full) 와 전체 Pester 는 인터랙티브 작업 중엔 피하기 (validate 시점에만)
- 실제 lag 발생 시 `macro diagnose-lag --sample-ms 3000` 으로 evidence 수집 후 수동 조치
- 자세한 가이드: [`references/troubleshooting.md`](references/troubleshooting.md)

## Quickstart Macros

```powershell
& <wrapper> macro windows                       # Win32 fallback, brief
& <wrapper> macro windows --rich --json-only    # helper 통합 envelope JSON
& <wrapper> macro find-label --label "확인" --explain        # 후보 + 점수
& <wrapper> macro smart-plan --label "Save" --allow-cdp      # read-only route planner (CDP/UIA/OCR)
& <wrapper> macro smart-plan --label "Save" --match "Kiro" --precision-points  # planner can recommend micro-refined click-point route
& <wrapper> macro smart-plan --label "Message" --type-text "hello" --allow-cdp  # read-only input planner
& <wrapper> macro app-profile --match "Chrome" --label "Send" --label "Subject" --auto-probe  # read-only app profile and capability probes
& <wrapper> macro workflow-plan --step "macro hit-test --x 1200 --y 720 --fast" --step "macro form-plan --field Message=hello"  # read-only multi-step workflow plan
& <wrapper> macro workflow-run --step "macro hit-test --x 1200 --y 720 --fast" --step "macro windows"  # run read-only workflow without live control
& <wrapper> macro workflow-run --observe-after-step --step "macro hit-test --x 1200 --y 720 --fast"  # execute read-only step, then capture a cheap window observation
& <wrapper> macro workflow-run --verify-label-after-step "Saved" --verify-label-timeout-ms 1000 --step "macro windows"  # verify a UI label after each step
& <wrapper> macro workflow-run --retry-failed-step 2 --retry-delay-ms 100 --step "macro windows --match Notepad"  # bounded retry for flaky read-only step
& <wrapper> macro workflow-run --dry-run --step "macro hit-test --x 1200 --y 720 --fast" --step "macro click-point --x 1200 --y 720 --target-match Kiro"  # gated macro sequence dry-run
& <wrapper> macro task-preset --kind document --text "meeting notes" --replace --save  # read-only document preset, emits task-plan/task-run commands
& <wrapper> macro task-preset --kind mail --to "a@example.com" --subject "Report" --body "Done" --send-label "Send" --match Gmail  # read-only mail preset
& <wrapper> macro task-plan --app chrome --wait-title Chrome --field "To=a@example.com" --field "Subject=Report" --send-label "Send" --allow-cdp --precision-points  # read-only app/form workflow planner
& <wrapper> macro task-plan --app notepad --wait-title Notepad --type-text "meeting notes" --shortcut "ctrl+s"  # app + free text + keyboard workflow planner
& <wrapper> macro task-run --dry-run --app chrome --wait-title Chrome --field "To=a@example.com" --field "Subject=Report" --send-label "Send" --allow-cdp --precision-points --settle-ms 150 --verify-after-step --verify-match Chrome --retry-failed-step 1  # validate task-plan with per-step verification/retry options
& <wrapper> macro task-run --dry-run --pre-shortcut "ctrl+a" --type-text "draft" --match Notepad --enter  # validate guarded text workflow before live control
& <wrapper> macro form-plan --field "To=a@example.com" --field "Subject=Report" --field "Body=Done" --send-label "Send" --allow-cdp  # read-only mail/document workflow planner
& <wrapper> -AllowLiveControl macro form-run --field "To=a@example.com" --field "Subject=Report" --field "Body=Done" --send-label "Send" --allow-cdp  # execute only if form-plan is fully safe
& <wrapper> macro hit-test --x 1200 --y 720 --target-match Kiro --fast  # fast Win32-only point guard
& <wrapper> macro hit-test-batch --points "1200,720;1210,720;1220,720" --target-match Kiro  # fast multi-point guard
& <wrapper> macro hit-scan --x 1200 --y 720 --radius 4 --step 2 --target-match Kiro  # read-only micro coordinate scan
& <wrapper> macro coord-profile --x 1200 --y 720 --target-match Kiro  # read-only DPI/monitor/window coordinate profile
& <wrapper> macro coord-map --from window --x 40 --y 24 --target-match Kiro  # read-only window/screen/normalized coordinate transform
& <wrapper> macro coord-anchor --x 1200 --y 720 --target-match Kiro  # read-only reusable layout-relative coordinate anchor
& <wrapper> macro coord-anchor --x 1200 --y 720 --target-match Kiro --record-history  # optionally remember verified anchors for reuse scoring
& <wrapper> macro point-plan --x 1200 --y 720 --radius 6 --step 2 --target-match Kiro --cache-ttl 2  # read-only precision click plan with short TTL cache
& <wrapper> macro target-validate --x 1200 --y 720 --target-match Kiro --min-confidence medium  # read-only pre-click small target safety check
& <wrapper> macro find-label --label "X" --match "App" --fast # Win32 fast no-match
& <wrapper> macro icon-find --label "send" --max-size 64      # 작은 toolbar 아이콘 전용 (synonym mining)
& <wrapper> macro list-affordances --window "설정" --limit 20

& <wrapper> -AllowLiveControl macro click-label --label "Save"            # icon-find → vision 자동 fallback
& <wrapper> -AllowLiveControl macro smart-click --label "Save" --match "Kiro" --allow-mouse-fallback --precision-points  # cascade click with micro-refined UIA coordinate fallback
& <wrapper> -AllowLiveControl macro click-point --x 1200 --y 720 --target-match Kiro --refine uia-safe  # guarded raw coordinate click
& <wrapper> -AllowLiveControl macro click-point --x 1200 --y 720 --target-match Kiro --micro-refine --precision-radius 6 --precision-step 2  # live click with pre-click micro scan
& <wrapper> -AllowLiveControl macro icon-click --label "send" --max-size 64
& <wrapper> -AllowLiveControl macro vision-click-precise --describe "purple send arrow" --crop-size 320
& <wrapper> -AllowLiveControl macro fill-label --label "Name" --text "Alice" --clear --enter
& <wrapper> -AllowLiveControl macro shortcut --keys "ctrl+s"
& <wrapper> -AllowLiveControl macro focus-verify --name "Notepad"
& <wrapper> -AllowLiveControl macro with-app --name "메모장" --wait-title "메모장" --hold-ms 2000 --close-after
& <wrapper> -AllowLiveControl macro auto-do --label "Save" --max-attempts 3 --verify-label "Saved"
```

**작은 아이콘 정확도**: `click-label` 은 fusion 실패 시 자동으로 `icon-find` (UIA tooltip/AutomationId/AccessKey 기반) → vision 순서로 fallback. toolbar 아이콘 (16~32px) 도 한 번에 잡힘. `vision-click-precise` 는 crop-and-refine 2단계로 더 정확.

**OCR (Windows.Media.Ocr — 브라우저 캔버스 / 이미지 표면용)**: `macro ocr-image --path <png>` / `macro ocr-screen --region x,y,w,h` / `macro ocr-find-text --text "Send" --match contains|fuzzy --target-match <window>` / `-AllowLiveControl macro ocr-click --text "Send" --min-score 70`. OCR candidates include line/word/2~3-word n-grams, but single-word searches skip n-grams for lower lag and tie-break toward smaller word/ngram boxes for steadier click coordinates. `smart-click` keeps fast UIA paths ahead of OCR history by default (`--prefer-history` to override, `--no-ocr` to disable). `references/command-reference.md` 의 OCR 섹션 참고.

**OCR+UIA fusion + screen verify + history (v0.9.0~v1.1.0)**: `macro ocr-uia-fuse --text "Send"` (fusion 가이드, read-only) / `-AllowLiveControl macro ocr-uia-invoke --text "Send"` (Name 비어도 AutomationId 로 invoke) / `macro screenshot-diff --before a.png --after b.png [--ignore-region "x,y,w,h"]` / `smart-click --verify-screen-changed --retry-on-no-change 2` / `macro history stats / show / clear` (`--no-history` 로 비활성). OCR/icon fallback clicks use `ClickRefine uia-safe`: just before the physical click, CUCP checks the UIA element under the point and may shift to Windows UIA's native `ClickablePoint` first, then a safe rect center fallback, while preserving target-window hit-test guards.

**hit-test guard + Electron/Chrome CDP (v1.2.0~v1.3.0)**: `macro hit-test --x N --y N --target-match Kiro` (좌표 검증 + UIA 보정 후보 표시) / `safe-type` (Win32 앱용). **CDP/DOM**: `macro cdp-detect` / `cdp-eval --expr` / `-AllowLiveControl macro cdp-type --selector "textarea" --text "msg" --press-enter` / `cdp-smart-click --text "Send"` / `cdp-smart-type --label "Message" --text "msg"` (DOM 직접). `smart-click --allow-cdp` 또는 `--cdp-page-match`로 Stage 0 opt-in. 활성화: `--remote-debugging-port=9222` (`references/cdp-setup.md`).

**v1.4.0 신규 — DOM bridge v2 + IME + recovery + benchmark + packaging**:
```powershell
# DOM bridge v2 traversal report (Shadow DOM + iframe)
& <wrapper> macro cdp-deep-find --text "Send" --page-match Kiro

# 한국어 IME-safe paste (live)
& <wrapper> -AllowLiveControl macro ime-paste --text "안녕" --target-match Notepad --press-enter
& <wrapper> -AllowLiveControl macro safe-type-ime --text "회의록" --target-match Notepad --verify-title Notepad

# UI recovery loop (실패 후 재관찰 + retry 추천)
& <wrapper> macro modal-detect
& <wrapper> macro recovery-plan --failed-step "macro click-label --label Save"
& <wrapper> macro recovery-run --dry-run             # plan only, no actuation
& <wrapper> -AllowLiveControl macro recovery-run --confirm-sensitive   # actuate (sensitive gate)

# Coordinate precision validation (read-only)
& <wrapper> macro precision-validate --x 1200 --y 720 --target-match Kiro --samples 5

# Benchmark suite (read-only, PII 미수집)
& <wrapper> macro benchmark --iters 3

# Release notes (CHANGELOG 자동 split + secret redact)
& <wrapper> macro release-notes
& <wrapper> macro release-notes --version 1.4.0 --json-only
& <wrapper> macro release-notes --since 1.3.0 --json-only
```

**v1.4.0 보안 보완**: `release-notes` 출력 직전 GitHub PAT / OpenAI sk- / AWS AKIA / Bearer / JWT / PEM 6종 자동 redact (`[REDACTED:tag]`). `recovery-run` 의 live action 은 `--confirm-sensitive` 강제. `benchmark` 측정 결과에 입력 텍스트/PII 미포함.

## Diagnostics & Performance

```powershell
& <wrapper> macro self-test --deep
& <wrapper> macro health-quick                 # ~500ms, helper 안 부름 + temp/log 압력 + recent timeouts
& <wrapper> macro health-detail                # 7-component, helper HTTP 포함
& <wrapper> macro metrics
& <wrapper> macro perf --iters 1 --quick       # 7 cheap targets, ~3초, slo[]/budgets 포함
& <wrapper> macro perf --iters 1               # 12 targets, helper 포함 (느림, validate 용)
& <wrapper> macro log-tail --lines 50 --max-bytes 65536 --errors-only   # bounded read + secret redact
& <wrapper> macro diagnose-lag --sample-ms 3000   # Codex/Kiro/Chrome/node 프로세스 + 경고
& <wrapper> macro cleanup --dry-run            # CUCP temp 정리 미리보기 (xg5000 폴더는 절대 안 건드림)
& <wrapper> macro cleanup --execute --older-than-minutes 30 --keep-latest 50
& <wrapper> macro trajectory show --last 20
& <wrapper> macro session info
& <wrapper> macro session clear-cache
& <wrapper> macro ensure-helper
```

## Wrapper Flags

- `-AllowLiveControl`: 라이브 actuation 허용
- `-Brief`: 한 줄 결과 (모델 루프용)
- `-Quiet`: 진단 메시지 억제
- `-CacheSeconds <n>` (기본 2): appshot 캐시 TTL, 0=비활성
- `-InvokeTimeoutMs <n>` (기본 30000): 단일 CLI 호출 타임아웃, 만료 시 exit 124. envelope에 `command_id`/`elapsed_ms`/`recommended_action` 포함

## Plans / Scenarios / Benchmarks

샘플: `plans/notepad-hello-world.json`, `plans/xg5000-program-check.json`. 흐름: `plan validate` → `dry-run` → `readiness --strict` → `preflight` → `run --readiness --strict-readiness --preflight`. 모든 옵션은 [`references/command-reference.md`](references/command-reference.md).

## Standardized Exit Codes

`0=ok`, `1=generic/not_found`, `2=partial/ambiguous/appshot_failed/no_window`, `3=safety blocked (live-control gate, missing --after, label not found)`, `124=timeout`. CI/CD: 0만 통과, 2는 검토, 3은 진행 금지, 124는 helper restart 후 재시도.

## Regression Tests

```powershell
Invoke-Pester C:\Users\K\.codex\skills\cucp-computer-use\tests\cucp.Tests.ps1
```

## Audit Trail

`%TEMP%\computer-use-control-plane\` 아래 (`cucp-wrapper.log`, `wrapper-cache/`, `trajectory.ndjson`, `screenshots/`). 안전 열람: `macro log-tail` (token/password/Bearer/JWT 자동 마스킹).

## Response Style

응답 한국어, 명령 스니펫 영어 원문. 라이브 전 read-only/live 여부 명시. 매크로 우선. 라이브 후 trajectory/observation_id로 검증.
