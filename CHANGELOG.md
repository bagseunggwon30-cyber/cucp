# CUCP Changelog

## v1.5.1 — XG5000 task-card context bridge (2026-05-27)

### Added

- `macro task-card open|show|ensure|save|path|clear`: small local context card for XG5000/XP-Builder work.
- Task-card JSON schema `cucp.task-card/v1` with tool, project, PLC model, communication, devices, address ranges, requirements, constraints, notes, and safety flags.
- `app-profile` now auto-loads `task_card` for PLC/SCADA-like windows so CUCP can plan with device and requirement context.
- Added `scripts/cucp-task-card.ps1` and `references/xg5000-task-card.md`.
- Added a separate Codex skill at `skills/xg5000-cucp-assistant/SKILL.md` for XG5000/XP-Builder sessions.

### Verified

- Parsed wrapper and task-card scripts with PowerShell AST.
- Verified `task-card ensure`, `task-card show`, `task-card save`, `task-card path`, and `app-profile --match XG5000` task-card loading.

---

## v1.5.0 — Performance: hot cache + CDP preflight cache + benchmark baseline (2026-05-27)

### 큰 틀 목표 + 정직 평가

**Cascade chain (`smart-click`, `workflow-run`, `recovery-plan`) 안에서 helper child
process spawn 비용을 줄이는 in-memory cache 인프라 추가.**
단, **single-shot wrapper invocation** 에서는 매번 wrapper 재실행되므로 효과 없음.
진짜 라이브 가속 (8x 이상) 은 v1.6 의 helper persistent server 필요.

### Added — Wrapper

- **In-memory hot cache** (`Invoke-NativeHelper`): 같은 wrapper process 안에서
  `windows / health / focused / modal-detect` action 을 500ms TTL 로 cache.
  - 키: action + 정규화된 옵션 (Match / TargetMatch / TargetHwnd)
  - 16개 항목 LRU evict
  - `CUCP_HOT_CACHE_DISABLE=1` 환경변수 또는 `-CacheSeconds 0` 로 비활성
  - envelope 에 `FromHotCache: bool` 표시
- **CDP TCP preflight cache** (`Test-CdpPortQuick`): 같은 wrapper process 안 다중
  cdp 매크로가 같은 port 재확인 시 1초 TTL 로 socket 생성 비용 회피.
- **`macro benchmark --baseline <file>`**: 이전 측정 결과와 자동 비교.
  - 출력에 `baseline_compare: { compared_targets, improved_count, regressed_count, rows[] }` 추가
  - rows: `name, baseline_p50_ms, current_p50_ms, delta_ms, delta_pct, verdict (improved|regressed|neutral)`
  - delta -10ms 이하 → improved, +30ms 이상 → regressed (튜닝 가능)
- **`tests/baseline-v1.4.0.json`**: v1.4.0 측정 baseline 저장 (회귀 detect 용).

### Honest disclosure

- Single-shot wrapper invocation benchmark 로는 가속 효과 측정 불가능.
  매번 새 wrapper process 라 hot cache 가 cold start 부터.
- Cascade chain (1 wrapper invocation 안에서 helper 여러 번 호출) 안에서만 효과 발생.
- "8-20x 빨라짐" 은 cascade 시나리오 한정. single benchmark 로 검증 안 됨.
- helper persistent server (named pipe IPC) 는 v1.6 sprint 로 미룸.

### Verified

- AST parse: 3파일 모두 OK
- baseline JSON 저장 + 자동 비교 동작 확인
- cold-path (hot cache disable) 에서 v1.4.0 대비 ~10-25% 추가 비용 (코드 통과 오버헤드)
- hot-path (cache 활성, 같은 wrapper 안 반복) 에서 ~98% 비용 감소

### Limits

- Cross-platform: Windows-only 그대로 (foundation 안 만듦, v1.6 후보)
- Helper persistent server: 미구현 (v1.6 후보)
- OCR engine cache: native helper 안에서 이미 process-scope cache (변경 없음)
- CDP WebSocket connection cache: 미구현 (helper persistent server 필요)

---

## v1.4.0 — 6 missing items 100% 구현 + 보안 보완 (2026-05-27)

### 큰 틀 목표 달성

학원본 `remaining-work.md` 의 진행률 82-84% / 6 missing items 모두 구현해서 100% 도달.
이전 4.6 작업의 누락분이었던 release-notes secret redaction / sensitive recovery gate /
PII 미수집 benchmark 도 함께 보완.

### Added — Native helper (3개 신규 action)

- **`-Action cdp-deep-find -CdpText <s> [-CdpPort N] [-CdpPageMatch <s>]`** (read-only)
  - Shadow DOM + same-origin iframe deep traversal report (최대 4 hops, 1200 nodes).
  - 출력: `traversal: { hops, shadow_roots_seen, iframes_seen, iframes_blocked, total_nodes }`,
    `top_matches[]`. cross-origin iframe 안전 skip.
- **`-Action ime-paste -Text <s> [-PressEnter] [-TargetMatch <s>] [-TargetHwnd N]`** (live)
  - 한국어 IME-safe paste: `System.Windows.Forms.Clipboard` 백업 → 텍스트 set →
    `SendKeys "^v"` → 클립보드 복구. 마우스 안 움직임. hit-test 가드 통과 필수.
- **`-Action modal-detect [-Match <s>] [-TargetHwnd N]`** (read-only)
  - UIA WindowPattern.IsModal + dialog class name (`#32770` / `MessageBox` / `TaskDialog`) +
    작은 윈도우 크기 점수화. `recommended_action: dismiss_or_confirm | confirm_dialog | wait | observe`.

### Added — Wrapper macros (9개 신규)

- **`macro cdp-deep-find --text <s> [--page-match <s>] [--port N]`** (read-only)
  - schema `cucp.cdp-deep-find/v1`. 디버깅 / 벤치마크용 traversal 메타정보 노출.
- **`macro ime-paste --text <s> [--press-enter] [--target-match <s>] [--target-hwnd N]`** (live)
  - schema `cucp.ime-paste/v1`. `-AllowLiveControl` 필수.
- **`macro safe-type-ime --text <s> [--target-match <s>] [--press-enter] [--verify-title <s>]`** (live)
  - schema `cucp.safe-type-ime/v1`. focus → ime-paste → 선택적 verify. `safe-type` race condition 회피.
- **`macro modal-detect [--match <s>] [--target-hwnd N]`** (read-only)
  - schema `cucp.modal-detect/v1`.
- **`macro recovery-plan [--match <s>] [--failed-step <s>] [--failed-reason <s>]`** (read-only)
  - schema `cucp.recovery-plan/v1`. modal-detect + foreground 결과 → rank 된 recovery_candidates[].
- **`macro recovery-run [--match <s>] [--dry-run] [--confirm-sensitive]`** (live, sensitive)
  - schema `cucp.recovery-run/v1`. live action 은 `-AllowLiveControl + --confirm-sensitive` 둘 다 필수.
  - 그 외엔 exit 3 (`reason=sensitive_recovery_requires_confirmation`).
- **`macro precision-validate --x N --y N [--target-match <s>] [--samples N]`** (read-only)
  - schema `cucp.precision-validate/v1`. drift_max / drift_avg / stable 측정.
  - recommendation: `safe_to_use_anchor` / `use_with_micro_refine` / `use_uia_pattern_or_relabel`.
- **`macro benchmark [--iters N]`** (read-only, 1~10)
  - schema `cucp.benchmark/v1`. 4 read-only target 의 p50/p95/avg + per-target SLO + slo_pass_rate.
  - PII/텍스트 미수집, 타이밍/카운트만.
- **`macro release-notes [--version X] [--since X]`** (read-only)
  - schema `cucp.release-notes/v1`. CHANGELOG 자동 split + highlights/added/improved/verified/fixed.
  - **보안: secret 패턴 자동 redact** (PAT/sk-/AKIA/Bearer/JWT/PEM 6종).

### Improved — DOM bridge v2 (자동 적용)

- 기존 `cdp-smart-find` / `cdp-smart-type` / `cdp-smart-type-find` 가 `deepCollect()` 로
  light DOM 1뎁스가 아니라 **Shadow DOM + same-origin iframe** 안까지 traversal.
- 최대 4 hops, 1200 nodes 캡, 동일 element 중복 제거.
- Slack / Discord / Notion 같은 chromium 앱의 web component / nested iframe 안 입력란도 잡힘.

### Improved — Workflow allowlist

- `workflow-plan / workflow-run` 의 `$readOnlyMacros` 에 6개 신규 read-only 매크로 등록
  (cdp-deep-find / modal-detect / recovery-plan / precision-validate / benchmark / release-notes).
- `$liveMacros` 에 3개 신규 live 매크로 등록 (ime-paste / safe-type-ime / recovery-run).

### Security (4.6 누락분 보정)

- `_Cucp-RedactSecrets` 헬퍼 추가: GitHub PAT (ghp_/gho_/ghs_/...), OpenAI sk-, AWS AKIA,
  Bearer/JWT, PEM private key block 패턴을 출력 직전 `[REDACTED:tag]` 로 치환.
- `release-notes` 가 모든 항목 emit 직전 redact 적용.
- `recovery-run` 의 sensitive gate (`--confirm-sensitive` 강제) 로 부주의한 dismiss/confirm 차단.
- `benchmark` 의 측정 결과에 입력 텍스트 / 사용자 데이터 미포함.
- `safe-type-ime` 의 클립보드 백업/복구 보장.

### Verified

- AST parse: cucp.ps1 / cucp-native-helper.ps1 / cucp.Tests.ps1 모두 OK.
- Pester: 설치 repo 기준 2026-05-27 회귀 테스트 190/190 통과.
- Sanity check 라이브: 9개 매크로 모두 의도된 envelope schema + exit code 반환.
- Secret redaction 검증: 합성 CHANGELOG 의 PAT / sk- / AKIA / Bearer 4종 모두 `[REDACTED:*]` 치환.

### Limits

- DXGI capture / multi-monitor coord-anchor / macOS-Linux 포팅은 v1.5+ 후보.
- ProseMirror 라이브 입력은 v1.3.0 부터 known limitation (CDP `Input.insertText` 추후 sprint).

---

## v1.3.35 - Practical task preset expansion (2026-05-26)

### Added

- Expanded `macro task-preset` beyond `document` and `mail`.
- Added workflow-style presets for `form-submit`, `file-upload`, `file-download`, and `settings`.
- New workflow presets preserve ordered steps such as upload button click -> file dialog wait -> guarded file path entry.
- Preset output now includes `generated_workflow_plan_command`, `generated_workflow_dry_run_command`, and `generated_workflow_run_command` when a task is better represented as a workflow than a single `task-plan`.

### Verified

- Added regression coverage for the new form submit, upload, download, and settings presets.

---

## v1.3.34 - Safety policy layer (2026-05-26)

### Added

- Added `macro safety-classify` with schema `cucp.safety-classify/v1` for read-only classification of sensitive actions.
- `workflow-plan` now annotates each step with safety evidence and reports `sensitive_step_count`.
- `workflow-run`, `task-run`, `form-run`, and direct sensitive live macros now block payment, credential, destructive, send/publish, identity/privacy, system-change, and settings-change actions unless `--confirm-sensitive` is supplied.
- Added machine-readable blocked responses with `reason=sensitive_action_requires_confirmation` and concrete `safety_issues`.

### Verified

- Added regression coverage for classification, workflow-plan safety annotations, blocked sensitive workflow execution, and confirmed execution passing the safety gate.

---

## v1.3.33 - Coordinate precision live defaults (2026-05-26)

### Added

- `click-point` now enables micro-refine by default when a target guard is present via `--target-match` or `--target-hwnd`.
- Added `--no-micro-refine` and `--no-anchor-history` opt-outs for guarded live coordinate clicks.
- Guarded live clicks now score anchor reuse before clicking and record the normalized anchor after successful clicks.
- Successful guarded click JSON can include `micro_refine`, `auto_micro_refine`, and `anchor_reuse` evidence.
- `smart-plan --precision-points` now emits `precision_policy` so generated plans preserve target validation and live click precision defaults.

### Verified

- Added regression coverage for `precision_policy`; full Pester suite passes on the working copy.

---

## v1.3.32 - CDP DOM bridge plan packaging (2026-05-26)

### Added

- `cdp-smart-find`, `cdp-smart-type-find`, `cdp-smart-click`, and `cdp-smart-type` now include `dom_bridge_plan` with schema `cucp.cdp-dom-bridge-plan/v1` when CDP is unavailable.
- The DOM bridge plan includes read-only command, live command, selector ranking priorities, and fallback order so another agent can continue without guessing a coordinate route.
- CDP page selection now scores page candidates by explicit `--page-match`, page/webview type, title/url quality, and DevTools/worker penalties.
- Successful smart DOM resolutions now expose `page_selection`, `selector_candidates`, `locator_candidates`, and `candidate_summaries` for CSS selector or Playwright-style locator reuse.

### Verified

- Added regression coverage for wrapper and native-helper closed-port DOM bridge plan output.

---

## v1.3.31 - App profile strategy scoring (2026-05-26)

### Added

- `macro app-profile` now emits `strategy_score` with schema `cucp.app-profile-strategy-score/v1`.
- The score combines CDP availability, UIA affordance and label-hit evidence, OCR/vision fallback need, app type, and prior app strategy history.
- Added `strategy_persistence` plus `--record-strategy`, `--remember-strategy`, and `--no-strategy-history`.
- Medium/high confidence app-profile recommendations can be persisted to `%TEMP%\computer-use-control-plane\app-strategy-history.ndjson` and reused as a last-good app-level route hint.

### Verified

- Added regression coverage for the app-profile strategy score envelope on partial/no-window profiles.
- Fixed duplicate `Path`/`PATH` process environment normalization so PowerShell 5 child-process based tests can run under Codex/IDE launchers.

---

## v1.3.30 - Anchor reuse history scoring (2026-05-26)

### Added

- `macro coord-anchor --record-history`: optionally records verified layout-relative anchors to an audit NDJSON file.
- `coord-anchor` now reports `reuse_history` with schema `cucp.anchor-reuse-score/v1`, including exact/near match counts, reuse score, confidence, coordinate signature match, last seen point, warnings, and recommendation.
- Reuse scoring helps AI callers avoid blindly trusting stale absolute coordinates after window moves, resizes, or display changes.

### Verified

- Added regression coverage for recording an anchor and reading a later reuse score.

---

## v1.3.29 - Pre-click target validation (2026-05-26)

### Added

- `macro target-validate`: read-only safety judgement for a coordinate before a live click.
- The validator wraps `point-plan` and reports `safe_to_click`, target guard status, coordinate risk, confidence, target size class, support count, native clickable evidence, edge distance, warnings, and errors.
- The live `recommended_command` is only surfaced when the coordinate is target-guarded and passes the validation gates.
- `target-validate` is allowed as a read-only workflow step.

### Verified

- Added regression coverage for `target-validate` output and workflow read-only classification.

---

## v1.3.28 - Layout-relative coordinate anchors (2026-05-26)

### Added

- `macro coord-anchor`: read-only conversion of a screen point into a reusable window-normalized anchor.
- Anchor output includes `anchor_id`, normalized window point, visible-normalized point, current target window evidence, restore `coord-map` command, and immediate `point-plan` commands.
- This gives AI callers a safer way to persist tiny UI targets across window moves/resizes instead of storing stale absolute screen coordinates.
- `coord-anchor` is allowed as a read-only workflow step.

### Verified

- Added regression coverage for creating a normalized coordinate anchor and its restore/point-plan commands.

---

## v1.3.27 - Window/screen coordinate mapping (2026-05-26)

### Added

- `macro coord-map`: read-only conversion between screen, window-local, visible-window-local, normalized, and visible-normalized coordinates.
- `coord-map` returns the selected window rect, visible clip, screen point, window point, normalized point, embedded coordinate profile, and warnings.
- This helps AI/OCR/vision callers map a point found in a cropped window screenshot back to the real screen coordinate before `point-plan` or live control.
- Coordinate risk now treats `target-hwnd` hit-test mismatch as high risk, catching overlapped-window cases even when the coordinate is inside the target window rectangle.
- `coord-map` is allowed as a read-only workflow step.

### Verified

- Added regression coverage for window-local to screen coordinate conversion.

---

## v1.3.26 - Coordinate profile and DPI-aware point planning (2026-05-26)

### Added

- `macro coord-profile`: read-only DPI/monitor/window coordinate profile for a point and optional target window.
- Coordinate profiles include virtual screen bounds, per-monitor DPI/scale, target window rect, point-relative coordinates, edge distance, hit-test evidence, warnings, and `coordinate_risk`.
- `point-plan` now embeds `coordinate_profile`, reports `mouse_moved=false` for the read-only planner, and includes the coordinate signature in its cache key so monitor/DPI layout changes do not reuse stale precision points.
- `coord-profile` is allowed as a read-only workflow step.

### Verified

- Added regression coverage for `coord-profile` and the embedded `coordinate_profile` in `point-plan`.

---

## v1.3.25 - App profile capability probes (2026-05-26)

### Added

- `macro app-profile --auto-probe`, `--probe-cdp`, and `--probe-uia` add read-only capability probes to the app profile.
- Browser/Electron profiles now run a cheap CDP port probe by default unless `--no-probe` is set.
- CDP is recommended only when the probe confirms an available DevTools endpoint, which avoids slow closed-port checks during later `smart-plan` work.
- UIA probing reports affordance count, small icon count, role distribution, sample elements, and requested label hits.
- UIA affordance probing can now target an exact HWND, reducing accidental full-desktop scans when titles are ambiguous or localized.
- Output now includes `capability_probes.cdp` and `capability_probes.uia`.

### Verified

- Added a regression test for closed CDP port reporting through `app-profile --probe-cdp`.

---

## v1.3.24 - App automation profile (2026-05-26)

### Added

- `macro app-profile`: a read-only app strategy profiler that inspects the current or matched window, classifies the app surface, and recommends a control route order.
- Browser/Electron targets now get CDP/DOM-first guidance when available, with UIA, OCR, and precision-point fallbacks.
- PLC/SCADA-style Win32 targets now get UIA, guarded hit-test, precision-point, OCR, and vision-precise route guidance.
- Output includes `recommended_task_options`, `suggested_task_plan_prefix`, and per-label read-only `smart-plan` probe commands.
- `workflow-plan`/`workflow-run` now classify `app-profile` as read-only.

### Verified

- Added regression tests for unmatched-window partial output and workflow read-only classification.

---

## v1.3.23 - Document/mail task presets (2026-05-26)

### Added

- `macro task-preset --kind document`: creates a read-only document workflow preset using `task-plan`, with optional replace and save shortcut steps.
- `macro task-preset --kind mail`: creates a read-only mail workflow preset from To/Subject/Body/send inputs, with CDP enabled by default unless `--no-cdp` is set.
- Preset output includes generated `task-plan` and `task-run` commands plus the embedded `task_plan`, so an AI caller can dry-run before live control.

### Verified

- Added a regression test for the document preset generating task-plan/task-run commands.

---

## v1.3.22 - Workflow failure summary for AI callers (2026-05-26)

### Added

- `workflow-run` now emits `failure_summary` and top-level `next_action` when a workflow ends as `partial`.
- Failure summaries classify command failures, window verification failures, label verification failures, retry exhaustion, and skipped live-step retries.
- `task-run` surfaces `workflow_failure_summary` and `next_action` from the nested workflow result.

### Verified

- Added regression tests for label-verification failure summaries, retry-exhaustion summaries, and task-run failure summary propagation.

---

## v1.3.21 - Per-step label verification (2026-05-26)

### Added

- `macro workflow-run --verify-label-after-step <label>`: runs a read-only `wait-label` check after each executed step.
- `--verify-label-window`, `--verify-label-timeout-ms`, and `--verify-label-interval-ms` tune the label verification scope and polling cost.
- Label verification failures integrate with existing `--retry-failed-step` retry logic.
- `task-plan` forwards label verification options into generated workflow commands.

### Verified

- Added regression tests for label verification failure handling and task-plan forwarding of per-step label verification options.

---

## v1.3.20 - Bounded workflow step retry (2026-05-26)

### Added

- `macro workflow-run --retry-failed-step <n>`: retries a failed step up to a bounded count, recording every attempt in the step result.
- `--retry-delay-ms`: adds a short delay between retry attempts.
- `--retry-live-steps`: explicit opt-in for retrying live-control steps; without it, live steps are not repeated even when retry is requested.
- `task-plan` forwards retry options into its generated `workflow-run` and `workflow-run --dry-run` commands.

### Verified

- Added regression tests for read-only step retry counts and task-plan forwarding of retry options.

---

## v1.3.19 - Workflow settle and observation gates (2026-05-26)

### Added

- `macro workflow-run --settle-ms`: waits briefly after each executed step so UI transitions can settle before the next step.
- `workflow-run --observe-after-step`: captures a cheap `macro windows --json-only` observation after every executed step.
- `workflow-run --verify-after-step --verify-match <window>`: treats a missing post-step window observation as a verification failure and stops unless `--continue-on-error` is used.
- `task-plan` now forwards settle/observe/verify options into its returned `workflow-run` and `workflow-run --dry-run` commands.

### Verified

- Added regression tests for post-step observation, verification failure handling, and task-plan forwarding of workflow verification options.

---

## v1.3.18 - Generic task text and shortcut steps (2026-05-26)

### Added

- `macro task-plan --type-text`: adds a generic typing step for document-style workflows.
- `task-plan --pre-shortcut` and `--shortcut`/`--keys`: add keyboard steps before or after the main typing/click workflow, covering flows such as select-all, write text, then save.
- When `--type-text` is combined with `--match`, the planner emits guarded `safe-type`; without `--match`, it emits faster `type-native`.

### Verified

- Added regression tests for text/shortcut task planning and `task-run --dry-run` validation of guarded type workflows.

---

## v1.3.17 - Task-run gated executor (2026-05-26)

### Added

- `macro task-run`: gated executor for `task-plan` that supports `--dry-run`, `--include-plan`, and `--continue-on-error`.
- `task-run` builds the task plan first, blocks unsafe plans, requires `-AllowLiveControl` only when a safe plan contains live steps, and delegates execution to `workflow-run`.
- Output schema `cucp.task-run/v1` includes the task plan when requested or dry-running, the internal `workflow_result`, workflow exit code, and execution status.

### Verified

- Added regression tests for `task-run --dry-run`, live gate behavior, and unsafe-plan blocking.
- Manual dry-run validated an app-launch task through internal `workflow-run` without launching the app.

---

## v1.3.16 - App/form task planner (2026-05-26)

### Added

- `macro task-plan`: read-only planner that combines app launch, window wait, form-plan field/click steps, extra click labels, and verify labels into a single `workflow-run` command.
- Output schema `cucp.task-plan/v1` includes `workflow_plan`, `recommended_command`, `dry_run_command`, embedded `form_plan`, live/read-only step counts, and unsafe planning errors.
- `form-plan` now forwards `--precision-points`, precision radius/step, and point cache TTL to the send-label `smart-plan` step so form workflows can use micro-refined button routes.

### Verified

- Added regression tests for task-plan app launch workflow generation, unsafe form wrapping, and form-plan precision option acceptance.
- All work remains read-only unless the returned workflow command is later run with `-AllowLiveControl`.

---

## v1.3.15 - Smart-click precision point execution path (2026-05-26)

### Improved

- `smart-click --allow-mouse-fallback --precision-points` now routes Stage 2 UIA coordinate fallback through `click-point --micro-refine`.
- The live path reuses the same precision radius/step and short point cache used by `point-plan`, after the fast Win32 guard confirms the target window.
- `uia_precision_point` is recorded as its own strategy, but default history behavior does not let it skip faster no-mouse UIA Pattern attempts unless `--prefer-history` is set.

### Verified

- Added a regression test proving `smart-click --precision-points` accepts the new options and returns partial on an unmatched target without clicking.
- Parser checks and focused Pester coverage pass without live mouse movement.

---

## v1.3.14 - Smart-plan precision point route (2026-05-26)

### Improved

- `smart-plan --precision-points` can now recommend a `uia_precision_point` route when UIA finds a label but the element has no direct InvokePattern.
- The new route emits a guarded `click-point --micro-refine` command with `--target-match`, precision radius/step, and point cache TTL so tiny controls can be clicked with the same pre-click scan used by `point-plan`.
- `click-point --micro-refine` can reuse a fresh `point-plan-*` cache entry after the fast Win32 guard confirms the same root window, reducing repeated tiny-target click latency.

### Verified

- Added a read-only regression test for `smart-plan --precision-points`.
- Parser checks and focused Pester coverage pass without moving the mouse.

---

## v1.3.13 - Point-plan short TTL cache (2026-05-26)

### Improved

- `point-plan` now uses a short TTL cache keyed by coordinate, scan radius/step, click inset, target guard, and the current root window evidence.
- Repeated point analysis on the same small UI target can return `from_cache=true` without re-running the heavier UIA `hit-scan`.
- `point-plan --no-cache` / `--cache-ttl 0` forces a fresh scan for moving or rapidly changing UI.
- `macro session clear-cache` now clears both appshot caches and `point-plan-*` cache files; `session info` reports `point_plan_cache_files`.

### Verified

- Added a regression test proving the second identical `point-plan` call reuses the TTL cache.
- Cache hits still run the wrapper Win32 fast guard first and refresh `precheck` evidence before returning.

---

## v1.3.12 - Precision point planner and micro-refine click (2026-05-26)

### Added

- `macro point-plan --x N --y N [--radius N] [--step N] [--target-match <s>]`: read-only precision click planner for tiny buttons, tabs, checkboxes, and near-edge coordinates.
- `point-plan` combines wrapper Win32 fast guard evidence with native `hit-scan` UIA `ClickablePoint` ranking, then emits a guarded `recommended_command`.
- `click-point --micro-refine [--precision-radius N] [--precision-step N]`: live coordinate click can re-run a small `hit-scan` immediately before clicking and use the refined point.
- `click-point --micro-refine` blocks by default if the pre-click micro scan cannot produce a safe point; `--allow-unrefined` is the explicit fallback.

### Verified

- Parser checks passed for `cucp.ps1`.
- Point planning and fast guard tests cover read-only `point-plan`, workflow read-only classification, and `click-point --micro-refine` blocking before any mismatched live click.

---

## v1.3.11 - Read-only workflow execution (2026-05-26)

### Improved

- `workflow-run` now builds the workflow plan first and requires `-AllowLiveControl` only when the plan contains live-control steps.
- Read-only workflows such as `hit-test --fast`, `windows`, `form-plan`, and health checks can run without live-control authorization.
- Child step invocation now adds `-AllowLiveControl` only to steps classified as live.

### Why

Agents need to run observe/verify workflows often. Keeping read-only workflows executable without live permission makes the Observe -> Think -> Act -> Verify loop faster and safer, while preserving the live gate for clicks, typing, app launch, and other actuation.

---

## v1.3.10 - Generic workflow planner/runner (2026-05-26)

### Added

- `workflow-plan --step "macro ..."`: read-only macro sequence planner that parses steps, classifies read-only vs live-control macros, and blocks unknown or recursive workflow steps.
- `workflow-run --dry-run`: validates a workflow without executing it and returns `cucp.workflow-run/v1` with `status=ready` or `blocked`.
- `workflow-run` live execution path: runs allowlisted macro steps in order only with `-AllowLiveControl`, stops on first failure by default, and records a trajectory summary.

### Why

This gives AI agents a safer bridge from individual actions to full app workflows: open/focus an app, wait for a window, plan or run a form, use guarded coordinates, and verify, all as one auditable sequence instead of ad hoc one-off calls.

---

## v1.3.9 - Guarded raw coordinate click (2026-05-26)

### Improved

- `click-point` now accepts `--target-match`, `--target-hwnd`, `--refine uia-safe`, `--click-inset`, and `--no-fast-guard`.
- When a target is supplied, `click-point` performs a wrapper-level Win32 fast guard before any live click and blocks with schema `cucp.click-point/v1` if the point is outside the intended app.
- The same target guard is still passed to the native helper click action, so live coordinate clicks have both precheck and final guard coverage.

### Why

Raw coordinate click is sometimes necessary for canvas or custom app surfaces. It now has the same cheap app-boundary safety behavior as planning tools, plus optional UIA micro refinement for tiny controls.

---

## v1.3.8 - Batch point guard (2026-05-26)

### Added

- `hit-test-batch --point "x,y" ...` / `--points "x,y;x,y"`: read-only wrapper-level Win32 batch point guard.
- Output schema `cucp.hit-test-batch/v1` includes per-point window/process evidence, errors for malformed coordinates, `safe_to_act`, and `source=wrapper_win32_fast`.

### Why

AI agents often compare several nearby candidate coordinates before choosing a tiny control. Batch mode avoids paying one wrapper/helper round-trip per coordinate and keeps UIA out of the fast guard path.

---

## v1.3.7 - Fast point guard split (2026-05-26)

### Improved

- `hit-test --fast` now uses a wrapper-level Win32 `WindowFromPoint` path and skips UIA refinement entirely.
- JSON output marks the path with `source=wrapper_win32_fast` and `uia_skipped=true` so agents can distinguish quick window guards from precision UIA analysis.

### Why

Click safety checks need to be cheap during agent loops. Use `hit-test --fast` for rapid "is this point inside the intended app?" checks, and reserve `hit-test` / `hit-scan` without `--fast` for tiny-control precision analysis.

---

## v1.3.6 - Micro coordinate scan (2026-05-26)

### Added

- `hit-scan --x N --y N [--radius N] [--step N]`: read-only micro coordinate scanner for tiny buttons, tabs, checkboxes, and edge-hit cases.
- Native `-Action hit-scan` samples the point and optional nearby grid, applies the same UIA `ClickablePoint` refinement, checks target-window guards, ranks candidates by score, support, native clickable point, and distance.

### Improved

- Default `hit-scan` is intentionally fast: radius `0` means one-point analysis. Agents can opt into denser scans only when a coordinate is near a small-control boundary.

---

## v1.3.5 - Multi-step form planner (2026-05-26)

### Added

- `form-plan --field "Label=Value" ... --send-label <button>`: read-only workflow planner for mail, document, chat, ticket, and app form tasks.
- `form-run --field "Label=Value" ... --send-label <button>`: gated workflow executor that runs `form-plan` first and executes only when every planned step is safe.
- `form-plan` composes the existing `smart-plan` routes per step, so it can rank CDP DOM, UIA ValuePattern, UIA Pattern, guarded coordinate, and optional OCR routes before any live action.
- JSON output now includes `command_plan[]` for ordered agent execution and `unsafe_steps[]` for the labels that still need narrowing.
- `cdp-eval --expr-b64 <base64>` for long or quote-heavy JavaScript expressions used in DOM planning tests and browser workflows.

### Why

This moves CUCP closer to the target of AI-operated app workflows: instead of asking the AI to click/type one label at a time, it can plan a whole "fill fields, then submit/save" sequence, prove the path is safe, and only then request live-control authorization.

---

## v1.3.4 — Smart input planner (2026-05-26)

### Added

- `smart-plan --label <field> --type-text <value>`: read-only input route planner for document/mail/chat style workflows.
- `cdp-smart-type-find --label <field>` / native `-Action cdp-smart-type-find`: DOM input/contenteditable resolver that does not focus or write.
- `uia-find` now reports `value_pattern` / `value_readonly` so planners can prefer `uia-set-value` when available.

### Route Preference

1. `cdp_smart_type`: DOM value/event path for Chrome/Electron.
2. `uia_set_value`: UIA ValuePattern path for native edit fields.
3. `safe_type_guarded`: guarded click/focus/type fallback when target window and click point are known.

### Verified

- Headless Chrome type-plan test: `smart-plan --type-text hello --allow-cdp` recommended `cdp_smart_type` for a `Message` input and left the DOM input value empty, proving the planner is read-only.

---

## v1.3.3 — Smart action planner (2026-05-26)

### Added

- **`macro smart-plan --label <text>`**: read-only route planner that ranks CDP DOM, UIA Pattern, guarded UIA coordinate, and optional OCR fusion routes before any live action.
- **`macro cdp-smart-find --text <label>`** / native `-Action cdp-smart-find`: read-only DOM resolver using the same scoring as `cdp-smart-click`, but with no scroll/focus/click.
- `uia-find` now reports `invoke_pattern` and preferred `click_point` evidence so planners can choose no-mouse Pattern calls before coordinate fallbacks.

### Verified

- Headless Chrome plan test: `cdp-smart-find` and `smart-plan --allow-cdp` found the `Send` button, recommended `cdp_smart_click`, and left `window.clicked` at `0`.

---

## v1.3.2 — UIA ClickablePoint micro-refine (2026-05-26)

### Improved

- `ClickRefine uia-safe` now prefers Windows UIA native `ClickablePoint` before falling back to a clamped rect center.
- `hit-test` now reports the refinement source (`clickable_point` or `rect_center`) plus `native_clickable` so agents can explain why a coordinate moved.
- `macro hit-test` accepts `--click-inset N` for read-only tuning of tiny control click-point analysis.

### Why

For very small toolbar buttons, tabs, checkboxes, split buttons, and custom controls, the geometric center is not always the safest click point. UIA `ClickablePoint` is the OS/accessibility provider's own recommended point, so it better matches the "small part, precise click" goal while keeping the existing target-window guard.

---

## v1.3.1 — CDP smart DOM actions + low-lag preflight (2026-05-26)

### Added

- **`cdp-smart-click --text <label>`**: visible text / aria-label / title / placeholder / id / name / label 연결 정보를 점수화해서 DOM 클릭.
- **`cdp-smart-type --label <field> --text <value>`**: label / placeholder 기반으로 input, textarea, contenteditable에 직접 입력.
- `smart-click --allow-cdp` / `--cdp-page-match` / `--cdp-port` 로 Stage 0 CDP/DOM smart click opt-in.

### Improved

- 닫힌 CDP 포트는 wrapper 단계에서 TCP preflight로 빠르게 partial 처리해서 native helper child process 호출을 줄임.
- CDP input은 React/controlled input 대응을 위해 native value setter + input/change event를 함께 사용.
- `smart-click` 기본 경로에서는 CDP 자동 탐지를 끄고, 명시 옵션이 있을 때만 Stage 0을 시도해서 기본 클릭 반응 속도를 보호.

### Verified

- PowerShell parser: `cucp.ps1`, `cucp-native-helper.ps1` 통과.
- Pester CDP 선별 테스트 11/11 통과.
- 임시 headless Chrome에서 `cdp-smart-type` → `cdp-smart-click` → DOM 상태 검증 성공:
  - input value: `hello`
  - button click counter: `1`

---

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
