# CUCP — Computer Use Control Plane

CUCP는 Codex/Kiro 같은 AI 에이전트가 Windows 데스크톱을 자동으로 관찰하고 조작하기 위한 control plane. Win32 API + UIA + System.Drawing + Windows.Media.Ocr + Chrome DevTools Protocol을 결합해서 표준 앱부터 Electron 앱까지 다룬다.

## 주요 기능

| 영역 | 기능 |
|---|---|
| **관찰** | window enum, foreground 추출, UIA tree, OCR (한국어/영어/일본어/중국어) |
| **조작** | UIA Pattern.Invoke (마우스 안 움직임), Win32 SendInput, OCR+UIA fusion |
| **검증** | screenshot diff (픽셀 단위), hit-test guard, click-and-verify-screen |
| **학습** | smart-click history learning (5회 lookback) |
| **Electron** | CDP 통합 (DOM 직접 접근, 좌표 무관) |

## 설치

이 폴더를 Codex skill 디렉토리에 복사:

```powershell
# Codex 사용자
$dest = "$env:USERPROFILE\.codex\skills\cucp-computer-use"
# 또는 Kiro / 기타 호환 환경의 skills 폴더
```

또는 직접 `cucp.ps1` 호출:

```powershell
& <path>\scripts\cucp.ps1 -Brief macro health-quick
```

## 핵심 매크로 빠른 시작

```powershell
# 관찰 (read-only)
& <wrapper> macro windows
& <wrapper> macro find-label --label "Save" --explain
& <wrapper> macro ocr-find-text --text "Send" --match contains

# 조작 (-AllowLiveControl 필수)
& <wrapper> -AllowLiveControl macro click-label --label "Save"
& <wrapper> -AllowLiveControl macro smart-click --label "Save"
&    # cascade: UIA Pattern → UIA 좌표 → icon-find → fusion → OCR → vision
& <wrapper> -AllowLiveControl macro fill-label --label "Name" --text "Alice" --enter

# Electron 앱 (Kiro / VS Code / Slack / Discord)
# 1. 앱을 --remote-debugging-port=9222 옵션으로 실행
# 2. 그 후:
& <wrapper> macro cdp-detect
& <wrapper> -AllowLiveControl macro cdp-type --selector "textarea" --text "msg" --press-enter
```

## 안전 정책

- 모든 라이브 actuation은 `-AllowLiveControl` 게이트 통과 필수
- 좌표 클릭은 `--target-match` / `--target-hwnd` 가드로 의도한 윈도우 검증 가능
- low-confidence (score < 60) 매칭은 자동 거부
- UAC, 비밀번호, 결제, 자격증명 화면은 정책상 자동 클릭 거부
- 모든 라이브 동작은 trajectory NDJSON 에 기록

## 표준 exit code

| code | 의미 |
|---|---|
| 0 | ok |
| 1 | generic failure / not found |
| 2 | partial / ambiguous / no_match (회복 가능) |
| 3 | safety blocked (-AllowLiveControl, hit-test 가드, low-confidence 등) |
| 124 | timeout |

## 폴더 구조

```
cucp-computer-use/
├── SKILL.md                       # 스킬 표면 문서 (130 라인 이내)
├── CHANGELOG.md                   # 버전별 변경사항 (v0.1.0 ~ v1.3.0)
├── agents/                        # Codex agent 설정 (openai.yaml)
├── plans/                         # 샘플 plan 파일들
├── references/                    # 상세 문서
│   ├── command-reference.md       # 매크로 전체 레퍼런스
│   ├── troubleshooting.md         # 진단 / 복구 / selector 점수표
│   ├── cdp-setup.md               # Electron CDP 활성화 가이드
│   └── audit-ps5-pitfalls.ps1     # PowerShell 5.x 함정 진단
├── scripts/
│   ├── cucp.ps1                   # 메인 wrapper (~6000줄)
│   └── cucp-native-helper.ps1     # Win32+UIA+OCR+CDP P/Invoke (~2400줄)
└── tests/
    └── cucp.Tests.ps1             # Pester 회귀 테스트 (109건)
```

## 검증 상태

- Pester: **109/109 통과** (~178초)
- self-test: 6/6 passed
- quick_validate: Skill is valid!

## 한계

- DirectX/게임 표면: anti-cheat / exclusive fullscreen 시 capture 실패 가능
- DRM 보호 화면 (Netflix 등): 검은 화면 캡처
- ProseMirror/TipTap 같은 contenteditable 에디터: CDP 의 단순 execCommand 거부 — `Input.insertText` 추후 sprint에서 처리
- 매우 작은 폰트 (<8pt): OCR 정확도 떨어짐
- Windows 10/11 전용 (Windows.Media.Ocr 의존)

## 라이선스

상용 제품 — 라이선스는 별도 협의.
