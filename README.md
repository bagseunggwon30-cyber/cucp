<div align="center">

# 🖥️ CUCP — Computer Use Control Plane

**Let any AI agent operate your Windows desktop — safely, precisely, and with receipts.**

AI 에이전트(Codex · Claude · Kiro · 기타 LLM)가 Windows 앱을
**관찰 → 판단 → 조작 → 검증** 루프로 자동 제어하는 단일 control plane.
좌표 추측 대신 **UIA 트리 · DOM · OCR · 라벨 그라운딩**으로 정확하게,
모든 라이브 동작은 **명시적 안전 게이트**를 통과해야만 실행된다.

[![Version](https://img.shields.io/badge/version-v2.3.1-blue.svg)](https://github.com/bagseunggwon30-cyber/cucp/releases)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D4.svg?logo=windows)](https://learn.microsoft.com/windows/)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg?logo=powershell)](https://learn.microsoft.com/powershell/)
[![Tests](https://img.shields.io/badge/Pester-190%2F190-brightgreen.svg)](#-검증-상태)
[![Macros](https://img.shields.io/badge/macros-109-success.svg)](references/command-reference.md)

[설치](#-설치-30초) · [첫 실행](#-첫-실행-1분) · [핵심 매크로](#-핵심-매크로) · [안전 정책](#-안전--보안) · [어디에 쓰나](#-어디에-쓰나) · [문서](#-문서)

</div>

---

## 30초 요약

```powershell
git clone https://github.com/bagseunggwon30-cyber/cucp.git
cd cucp
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

cucp macro windows        # 열린 창 목록 (read-only)
```

- **단일 진입점** `cucp` — 어떤 AI 에이전트든 이 한 명령으로 데스크톱을 제어
- **109개 매크로** — 관찰 / 조작 / 검증 / CDP / OCR / UIA / 복구 / PLC 보조
- **안전 우선** — 모든 라이브 동작은 `-AllowLiveControl` + hit-test 가드 + sensitive 차단
- **검증됨** — Pester 190/190, 코드 실행 취약점(`Invoke-Expression`) 0건

---

## ⚡ 설치 (30초)

```powershell
# 1. 클론
git clone https://github.com/bagseunggwon30-cyber/cucp.git
cd cucp

# 2. 원클릭 설치 (관리자 권한 불필요)
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

`install.ps1` 이 하는 일:
- PowerShell 5.1+ / Windows 환경 확인
- `cucp` 명령을 PATH 에 등록 (사용자 범위 shim, UAC 불필요)
- `health-quick` 으로 동작 검증

> 설치를 건너뛰고 바로 쓰려면: `scripts\cucp.ps1` 을 직접 실행해도 됩니다.
> 되돌리려면 `%LOCALAPPDATA%\Microsoft\WindowsApps\cucp.cmd` 만 삭제하면 끝.

---

## 🚀 첫 실행 (1분)

```powershell
# 관찰 — 열린 창 목록 (read-only, 안전)
cucp macro windows

# 관찰 — 'Save' 라벨 후보 + 점수 근거
cucp macro find-label --label "Save" --explain

# 버전 — skill / cli / helper-server 통합 표시
cucp version

# 조작 — 실제 클릭 (라이브: -AllowLiveControl 필수)
cucp -AllowLiveControl macro smart-click --label "Save" --match "Notepad"
```

read-only 매크로는 게이트 없이 바로 동작하고, **실제로 클릭/입력하는 매크로는 `-AllowLiveControl` 을 붙여야만** 실행됩니다. 이게 CUCP 의 1번 안전 원칙입니다.

---

## 🤔 왜 CUCP 인가

대부분의 computer-use 도구는 **스크린샷을 보고 좌표를 추정해서** 클릭합니다. 작은 버튼, 밀집한 그리드, 창이 움직이면 빗나가기 쉽습니다.

CUCP 는 **네 가지 인식 스택을 함께** 써서 좌표 추측을 최소화합니다:

```
Win32 API        UIA               OCR                    Chrome DevTools Protocol
   │              │                 │                          │
 window enum   accessible        ko/en/ja/zh              Electron / Chromium 앱
 & hit-test    tree + patterns   텍스트 인식              (Kiro / VS Code / Slack / Chrome)
```

- **라벨로 클릭** — "Save" 버튼을 좌표가 아니라 이름/역할로 찾음
- **UIA Pattern.Invoke** — 마우스를 안 움직이고 접근성 API 로 직접 실행
- **CDP/DOM** — Electron 앱은 DOM 에 직접 접근 (Shadow DOM / iframe 관통)
- **hit-test 가드** — 클릭 전에 "이 좌표가 정말 의도한 창인가" 검증

그리고 모든 라이브 동작은 다층 안전 게이트를 통과해야 합니다 ([아래](#-안전--보안)).

---

## ✨ 주요 기능

| 영역 | 기능 |
|:--|:--|
| 👁️ **관찰** | window enum, foreground 추출, UIA tree, OCR (ko/en/ja/zh) |
| 🖱️ **조작** | UIA Pattern.Invoke, Win32 SendInput, OCR+UIA fusion, IME-safe paste |
| ✅ **검증** | screenshot diff (픽셀 단위), hit-test guard, click-and-verify, precision-validate |
| 🧠 **학습** | smart-click history (최근 lookback), anchor reuse 점수 |
| 🌐 **Electron/Chrome** | CDP 통합 — DOM 직접 접근, Shadow DOM / iframe 관통, 좌표 무관 |
| 🚑 **복구** | modal-detect → recovery-plan → recovery-run (UI 실패 복구 루프) |
| ⚡ **속도** | daemon serve — 상주 모드에서 호출당 ~31ms (single-shot ~2s 대비) |
| 📊 **벤치마크** | read-only benchmark (p50/p95/avg + SLO, PII 미수집) |
| 🏭 **PLC 보조** | XG5000 / XP-Builder task-card · spec-board · ladder 진단 |
| 🛡️ **거버넌스** | audit-summary, policy-check, vision token budget, multi-user 격리 |

---

## 🎯 핵심 매크로

```powershell
# ── 관찰 (read-only) ──────────────────────────────────────────
cucp macro windows                                  # Win32 창 enum (결정론적)
cucp macro find-label --label "Save" --explain      # 라벨 후보 + 점수 근거
cucp macro ocr-find-text --text "Send"              # OCR (Windows.Media.Ocr)
cucp macro app-profile --match Chrome --auto-probe  # 앱 자동화 전략 점수

# ── 조작 (live, -AllowLiveControl 필수) ───────────────────────
cucp -AllowLiveControl macro click-label --label "Save"
cucp -AllowLiveControl macro smart-click --label "Save" --match Kiro
#     └ cascade: UIA Pattern → UIA 좌표 → icon → fusion → OCR → vision
cucp -AllowLiveControl macro fill-label --label "Name" --text "Alice" --enter
cucp -AllowLiveControl macro shortcut --keys "ctrl+s"

# ── Electron/Chrome — CDP/DOM (좌표 무관) ─────────────────────
# 앱을 --remote-debugging-port=9222 로 시작 후 (references/cdp-setup.md)
cucp macro cdp-detect
cucp macro cdp-deep-find --text "Send" --page-match Kiro   # Shadow DOM/iframe 관통
cucp -AllowLiveControl macro cdp-smart-click --text "Send"

# ── 복구 루프 ─────────────────────────────────────────────────
cucp macro modal-detect
cucp macro recovery-plan --failed-step "macro click-label --label Save"

# ── 속도: 상주 daemon (호출당 ~31ms) ─────────────────────────
cucp macro daemon serve            # stdin JSON-line 명령을 받는 상주 모드
```

전체 109개 매크로는 [`references/command-reference.md`](references/command-reference.md) 참고.

---

## 🛡️ 안전 & 보안

모든 라이브 동작은 다층 게이트를 통과해야 실행됩니다:

| 게이트 | 동작 |
|:--|:--|
| 🔐 **AllowLiveControl** | 모든 조작 매크로는 `-AllowLiveControl` 없으면 차단 (exit 3) |
| 🎯 **Hit-test guard** | 좌표 클릭은 `--target-match` / `--target-hwnd` 로 의도한 창 검증 |
| 🔢 **Confidence floor** | low-confidence 매칭(score < 60) 자동 거부 |
| 🚫 **Sensitive gate** | UAC / 비밀번호 / 결제 / 자격증명 화면 자동 거부 |
| 📝 **Audit trail** | 모든 라이브 동작을 trajectory NDJSON 에 기록 |
| 🧹 **Secret redaction** | 출력 직전 PAT / sk- / AKIA / Bearer / JWT / PEM 6종 자동 마스킹 |
| 🔒 **Multi-user 격리** | helper-server pipe owner-only ACL + lock owner 검사 |

설계 원칙: `Invoke-Expression`/`iex` 사용 0건, 외부 프로세스 인자는 배열/escape 전달, 입력 길이 cap.

### 표준 exit code

| code | 의미 |
|:-:|:--|
| `0` | ok |
| `1` | generic failure / not_found / 입력 누락 |
| `2` | partial / ambiguous / no_match (회복 가능) |
| `3` | safety blocked (게이트 미통과) |
| `124` | timeout |

---

## 🏭 어디에 쓰나

- **AI 에이전트 데스크톱 자동화** — Codex / Claude / Kiro 가 Windows 앱을 라벨 기반으로 안전하게 조작
- **Electron 앱 제어** — Kiro / VS Code / Slack / Discord 를 CDP 로 DOM 직접 제어
- **반복 GUI 워크플로** — 폼 입력, 파일 작업, 설정 변경을 검증 루프와 함께
- **PLC 엔지니어링 보조 (LS XG5000 / XP-Builder)** — task-card · spec-board 로 디바이스/주소/요구조건 context 관리, ladder 1차 진단(STOP NC / 자기유지 / 중복 코일 / SET-RST / word-as-bit), download/RUN 전 안전 검증. 산업용 안전 게이트가 내장된 점이 범용 도구와 다른 부분.

---

## ✅ 검증 상태

| 항목 | 결과 |
|:--|:--|
| Pester 회귀 | **190 / 190** |
| contract-verify | **8 / 8** |
| AST parse | 6 / 6 OK |
| 코드 실행 취약점 | `Invoke-Expression` **0건** |

```powershell
# 회귀 테스트 직접 실행 (Pester 필요)
Invoke-Pester .\tests\cucp.Tests.ps1
```

---

## 📁 구조

```
cucp/
├── install.ps1              # 원클릭 설치
├── README.md · CHANGELOG.md · SKILL.md
├── scripts/
│   ├── cucp.ps1             # 메인 wrapper (단일 진입점)
│   ├── cucp-native-helper.ps1   # Win32 + UIA + OCR + CDP (P/Invoke)
│   ├── cucp-helper-server.ps1   # 상주 helper (named pipe IPC)
│   ├── cucp-task-card.ps1       # XG5000 작업 카드
│   └── cucp-spec-board.ps1      # XG5000 spec / 체크리스트 보드
├── references/             # 상세 문서 (command-reference, cdp-setup, troubleshooting ...)
├── skills/                 # XG5000 전용 Codex 스킬 (assistant · ladder-diagnostician)
└── tests/                  # Pester 회귀 테스트
```

---

## 🚧 한계 (정직하게)

- **Windows 10/11 전용** — `Windows.Media.Ocr` · UIA · Win32 의존. macOS/Linux 는 honest-stub 만.
- **single-shot 호출은 ~2초** — PowerShell + wrapper cold-start 비용. 빠른 경로는 `daemon serve` (호출당 ~31ms).
- **DirectX/게임 풀스크린, DRM 화면** — 캡처 실패 가능.
- **매우 작은 폰트(<8pt)** — OCR 정확도 저하.
- **Cross-origin iframe** — 보안상 traversal 차단(개수만 보고).

---

## 🗺️ 로드맵

- daemon serve 를 기본 호출 경로로 자동화 (single-shot 약점 제거)
- macOS / Linux 포팅
- DXGI capture (게임/풀스크린)
- multi-monitor coord-anchor 자동 재anchor

자세한 변경 이력은 [`CHANGELOG.md`](CHANGELOG.md).

---

## 📚 문서

| 문서 | 설명 |
|:--|:--|
| [`CHANGELOG.md`](CHANGELOG.md) | 버전별 변경사항 |
| [`references/command-reference.md`](references/command-reference.md) | 매크로 전체 레퍼런스 |
| [`references/troubleshooting.md`](references/troubleshooting.md) | 진단 / 복구 / selector 점수표 |
| [`references/cdp-setup.md`](references/cdp-setup.md) | Electron CDP 활성화 가이드 |
| [`SKILL.md`](SKILL.md) | AI 에이전트 스킬 등록 메타 |

---

## 📜 라이선스

별도 명시 전까지 All rights reserved. 사용/배포 문의는 저장소 이슈로.

---

<div align="center">

**Made with 🖱️ + ⌨️ for AI agents that respect your desktop**

⭐ 도움이 됐다면 Star 를 눌러주세요.

</div>
