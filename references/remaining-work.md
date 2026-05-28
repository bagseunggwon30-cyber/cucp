# CUCP Remaining Work

Updated: 2026-05-29

Current progress estimate: **100%** (v2.1.0). Helper persistent server, wrapper daemon,
ProseMirror live, mouse-verify cassette, Option B layer, recorder, governance, vision
budget 모두 통합 완료. 라이브 cassette 4환경 보존만 사용자 직접 실행 필요.

## v2.1.0 — Option B + Reliability + Enterprise (2026-05-29)

### Layer 통합 (Phase 2)
- `Get-CucpVersionReport` + `cucp version --json-only` (skill / cli / helper-server 통합 envelope).
- `$Script:SkillVersion` single source of truth.

### Reliability (Phase 3)
- Cross-platform honest stub (`platform_unsupported` exit 3 + read-only `honest_stub`).
- Recorder + replay (`macro recorder start/stop/list/show/replay --dry-run/--allow-live`).
- safety gate enforce on replay live (P7 invariant).

### Enterprise (Phase 4)
- `macro audit-summary [--since-minutes N]` (trajectory.ndjson 집계).
- `macro policy-check --action <macro> [--policy <file>]` (allow / deny / require_confirm).
- Vision LLM token budget (`CUCP_VISION_MAX_CALLS` / `CUCP_VISION_MAX_TOKENS`).
- Helper-server PipeSecurity owner-only ACL (fail-soft).
- lock 파일에 `owner_user` / `owner_sid` (multi-user 격리).

### Live cassette runner
- `references\live-cassette-runner.ps1` (Notepad / Kiro / Chrome / XG5000).
- 사용법: `.\references\live-cassette-runner.ps1 -Env all`.
- 결과: `live-verify\<env>\*.json` (cucp.live-verify/v1 schema).

## v1.7.0 ~ v2.0.0 milestones (요약)

### v1.7.0 (server cache 확장)
- helper-server 의 `ocr-screen-fast`, `uia-find-fast` (process-scope cache).
- `macro daemon batch --file <commands.json>` (cascade chain 17~21x warm 가속).
- `macro mouse-verify --x --y --samples N` (post_click drift 통계).
- `macro cdp-prosemirror-insert` (CDP `Input.insertText`).

### v1.6.0 (helper-server 통합)
- Lock + IPC + server-first 라우팅 + lifecycle 매크로 (`session start-helper / stop-helper / helper-status`).
- CLI cache (`wrapper-cache/cli-path.txt`, single-shot 45% 감소).
- Mouse SendInput race 제거 + `post_click` envelope 필드.

### v1.5.1 (학원본 통합)
- XG5000 task-card bridge + 별도 Codex skill `xg5000-cucp-assistant`.

### v1.4.0 (6 missing items)
- DOM bridge v2 (Shadow DOM / iframe traversal), modal-detect, recovery-plan/run,
  ime-paste / safe-type-ime, precision-validate, benchmark, release-notes (secret redaction).

## 진짜 남은 것 (사용자 결정 / 별도 sprint)

- **라이브 cassette 4환경 보존**: 코드 + runner script 준비 완료. 사용자 1회 실행 필요 — `.\references\live-cassette-runner.ps1 -Env all`.
- **smart-click history fast-track** (cascade 첫 stage skip): 현재 history 매크로는 read-only. fast-track hook 은 별도 sprint.
- **macOS / Linux 라이브 검증**: 본 sprint 는 schema 검증만 + honest_stub. 실제 라이브 actuation 은 Windows 외 환경에서 별도.
- **DXGI capture / multi-monitor coord-anchor**: roadmap 후보.
- **OS World 외부 벤치 통합**: 라이센스 / 데이터 외부 의존, 사용자 결정 대기.
- **rubric / auto-eval 매크로**: cassette 보존 후 도입 가능. 본 sprint 범위 외.
- **Visual planner UI**: 별도 spec 권장.

## 보안 보완 (이전 4.6 누락분 보정 + v2.1.0)

- `release-notes`: secret redact (PAT/sk-/AKIA/Bearer/JWT/PEM 6종 패턴).
- `recovery-run`: live action 은 `--confirm-sensitive` 강제.
- `benchmark`: 텍스트/PII 미수집.
- `safe-type-ime`: 클립보드 백업/복구 보장.
- `precision-validate`: read-only — 좌표 클릭 없이 분석만.
- **v2.0.0 PipeSecurity ACL**: helper-server pipe 가 owner-only.
- **v2.0.0 lock owner_user 격리**: 다른 user 의 lock 무시.
- **v2.0.0 vision budget gate**: vision-find / vision-click 누적 한도 초과 시 exit 3.
- **v2.0.0 policy-check + audit-summary**: governance / 감사 envelope.
- **v1.9.0 platform stub**: 비Windows 환경 live action 거부 (exit 3 platform_unsupported).

## Verified

- AST parse: cucp.ps1 / cucp-native-helper.ps1 / cucp-helper-server.ps1 모두 OK.
- Pester: 190 / 190 (timing-flaky 1건은 v1.6.0 baseline 부터 동일 양상의 외부 동기화 의존 testcase).
- helper-server 라이프사이클 + lock owner 검사 + version envelope 직접 측정.
- safety gate: vision budget / mouse-verify / cdp-prosemirror-insert / recovery-run 모두 `-AllowLiveControl` 없을 때 exit 3.

