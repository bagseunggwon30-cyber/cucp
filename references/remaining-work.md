# CUCP Remaining Work

Updated: 2026-05-27

Current progress estimate: **100%** (functional 6 missing items) +
**v1.5.1 XG5000 task-card bridge**. Next sprint: helper persistent server (named pipe IPC)
가 진짜 8-20x 가속을 single-shot 에서도 측정 가능하게 만드는 핵심.

## v1.5.1 — XG5000 / XP-Builder context bridge

- Added `macro task-card open|show|ensure|save|path|clear` for device, address range, requirement, and safety context.
- Added `scripts/cucp-task-card.ps1`, a small WinForms card that writes `%TEMP%\computer-use-control-plane\task-card\current-task-card.json`.
- `app-profile` now auto-loads `task_card` for PLC/SCADA-like windows such as XG5000, XP-Builder, CIMON, XGT, PLC, and Modbus tools.
- Added `references/xg5000-task-card.md` and a separate Codex skill under `skills/xg5000-cucp-assistant/`.

## v1.4.0 — 6 missing items 구현 결과

### 1. Browser/Electron DOM bridge v2 — 완료
- `cdp-smart-find` / `cdp-smart-type` / `cdp-smart-type-find` 가 `deepCollect()` 로
  Shadow DOM 과 same-origin iframe 안까지 traversal (최대 4 hops, 1200 nodes 캡).
- 새 read-only 매크로 `cdp-deep-find` 가 traversal 메타정보
  (shadow_roots_seen / iframes_seen / iframes_blocked / total_nodes) 보고.
- cross-origin iframe 은 `contentDocument` 접근 차단 시 안전하게 skip.

### 2. Coordinate precision v2 validation — 완료
- 새 read-only 매크로 `precision-validate --x N --y N --samples N` 가
  같은 좌표를 반복 `hit-scan` 해서 drift_max / drift_avg / stable / recommendation 보고.
- micro-toolbar / canvas-인접 좌표가 안정적인지 라이브 클릭 없이 사전 검증 가능.

### 3. UI recovery loop — 완료
- 새 read-only 매크로 `modal-detect` 가 UIA WindowPattern.IsModal +
  dialog class name (`#32770`/`MessageBox`/`TaskDialog`) + 작은 윈도우 크기를 점수화.
- 새 read-only 매크로 `recovery-plan` 이 modal-detect + foreground 결과로
  rank 된 recovery_candidates[] (dismiss_modal / confirm_modal / re_observe / retry_failed_step) 추천.
- 새 live 매크로 `recovery-run` 은 `--dry-run` 또는
  `-AllowLiveControl + --confirm-sensitive` 둘 다 있어야 actuation. 그 외엔 exit 3 (sensitive gate).

### 4. Korean input/IME handling — 완료
- 새 native helper action `ime-paste` 가 `System.Windows.Forms.Clipboard` 백업 →
  텍스트 set → `SendKeys "^v"` → 클립보드 복구 순서로 IME 조합 모드 우회.
- 새 wrapper macro `safe-type-ime` 가 focus → ime-paste → 선택적 verify(window title)
  를 묶어서 노트패드 / 브라우저 contenteditable / 메일 앱 한글 입력 안정화.
- 마우스 안 움직이고 hit-test 가드 (`--target-match` / `--target-hwnd`) 통과해야 paste.

### 5. Benchmark suite — 완료
- 새 read-only 매크로 `benchmark --iters N` 이 4 read-only target
  (windows / health / focused / modal-detect) 에 대해 p50/p95/avg + per-target SLO + slo_pass_rate 측정.
- 텍스트/PII 미포함, 타이밍/카운트만 출력. 라이브 클래스룸 안 씀.

### 6. Packaging — 완료
- 새 read-only 매크로 `release-notes [--version X] [--since X]` 가 CHANGELOG 를
  버전별로 split 해서 highlights / added / improved / verified / fixed 추출.
- 보안: `_Cucp-RedactSecrets` 헬퍼가 GitHub PAT / OpenAI sk- / AWS AKIA / Bearer / JWT / PEM 패턴
  을 출력 직전 `[REDACTED:...]` 로 치환. release_notes 가 외부 push 시 secret leak 방지.
- migration_notes / external_agent_usage 자동 포함.

## 보안 보완 (이전 4.6 누락분 보정)

- `release-notes`: secret/credential 패턴 출력 전 redact (5개 패턴 + 6번째 PEM block).
- `recovery-run`: live action 은 `--confirm-sensitive` 강제 (sensitive_recovery_requires_confirmation gate).
- `benchmark`: 입력 텍스트 미수집, helper child 만 호출, audit log 따로 안 만듦.
- `safe-type-ime`: 클립보드 백업/복구 보장, hit-test 가드 통과해야 actuation.
- `precision-validate`: read-only — 좌표 클릭 없이 분석만.

## Done — Verification

- AST parse: cucp.ps1 / cucp-native-helper.ps1 / cucp.Tests.ps1 모두 OK.
- Pester: 설치 repo 기준 2026-05-27 회귀 테스트 190/190 통과.
- Sanity check 라이브: cdp-deep-find / modal-detect / recovery-plan / recovery-run --dry-run /
  precision-validate / benchmark / release-notes 모두 의도된 envelope + exit code 반환.
- Secret redaction: 합성 CHANGELOG 의 PAT / sk- / AKIA / Bearer 4종 모두 [REDACTED:*] 치환 검증.

## v1.5+ 후보 (현재 100%, 추가 확장은 옵션)

- **Helper persistent server (named pipe IPC)** — single-shot wrapper invocation
  에서도 8-20x 가속 측정 가능하게. v1.5.0 의 hot cache 가 cascade chain 한정인
  이유를 정공법으로 해결.
- **CDP WebSocket connection 재사용** — helper server 안에서만 의미 있음.
- **smart-click history fast-track** — 최근 3회 같은 strategy + score≥80 이면
  cascade 첫 stage 부터 시작하지 말고 그 stage 부터 skip.
- DXGI capture (game/full-screen surface) — 게임 / 풀스크린 영역 capture 우회.
- Auto-mask region — `screenshot-diff` 가 노이즈가 큰 영역(시계/배지/캐럿 등) 자동 식별.
- Multi-monitor coord-anchor — display layout 변화 시 anchor 자동 재 anchor.
- macOS / Linux 포팅 — 현재 Windows 10/11 전용.
- Vision-language fallback 의 token cost 측정 + budget gate.
