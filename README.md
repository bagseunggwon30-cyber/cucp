<div align="center">

# 🖥️ CUCP

### Computer Use Control Plane

**AI 에이전트가 Windows 데스크톱을 안전하게 관찰하고 조작하기 위한 control plane**

[![Version](https://img.shields.io/badge/version-v1.7.0-blue.svg)](https://github.com/bagseunggwon30-cyber/cucp/releases/tag/v1.7.0)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D4.svg?logo=windows)](https://learn.microsoft.com/windows/)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg?logo=powershell)](https://learn.microsoft.com/powershell/)
[![Tests](https://img.shields.io/badge/Pester-190%2F190%20passing-brightgreen.svg)](#-검증-상태)
[![Progress](https://img.shields.io/badge/progress-100%25-success.svg)](references/remaining-work.md)
[![Security](https://img.shields.io/badge/security-secret%20redaction-lightgrey.svg)](#-안전--보안-정책)

[빠른 시작](#-빠른-시작) ·
[기능](#-주요-기능) ·
[매크로](#-핵심-매크로) ·
[안전 정책](#-안전--보안-정책) ·
[문서](#-문서)

</div>

---

## 📖 소개

CUCP는 **Codex / Kiro / Claude Computer Use** 같은 AI 에이전트가 Windows 데스크톱을
**Observe → Think → Act → Verify** 루프로 자동 조작하기 위한 control plane.

다섯 가지 기술을 한 번에 다룬다:

```
Win32 API   +   UIA   +   System.Drawing   +   Windows.Media.Ocr   +   Chrome DevTools Protocol
   ↓             ↓               ↓                     ↓                          ↓
window enum   accessible      screenshot /          한/영/일/중              Electron 앱
& hit-test     tree &        pixel-diff            텍스트 인식            (Kiro / VS Code /
              patterns                                                    Slack / Discord)
```

표준 Win32 앱부터 Electron / Chromium 앱까지 모두 다룬다.

> **v1.6.0 한 줄 요약**: helper-persistent-server 통합 + CLI cache (single-shot 45% 감소)
> + 마우스 actuation race 제거. AI agent (Codex / Claude / Kiro / 일반 LLM) 어디든 단일
> entry point (`cucp.ps1`) 로 사용. 학원본 v1.5.1 task-card / helper-server skeleton 보존.

---

## ✨ 주요 기능

| 영역 | 기능 |
|:--|:--|
| 👁️ **관찰** | window enum, foreground 추출, UIA tree, OCR (ko / en-US / ja / zh-CN) |
| 🖱️ **조작** | UIA Pattern.Invoke (마우스 안 움직임), Win32 SendInput, OCR+UIA fusion, IME-safe paste |
| ✅ **검증** | screenshot diff (픽셀 단위), hit-test guard, click-and-verify-screen, precision-validate |
| 🧠 **학습** | smart-click history learning (5회 lookback), anchor reuse 점수 |
| 🌐 **Electron** | CDP 통합 (DOM 직접 접근, **Shadow DOM / iframe deep traversal**, 좌표 무관) |
| 🚑 **복구** | modal-detect / recovery-plan / recovery-run (UI failure recovery loop) |
| 📊 **벤치마크** | read-only benchmark (p50 / p95 / avg + per-target SLO, **PII 미수집**) |
| 📦 **패키징** | release-notes (CHANGELOG 자동 split + **secret redaction**) |
| 🏭 **PLC 실습 보조** | XG5000 / XP-Builder task-card, 디바이스·주소·요구조건 JSON 자동 로드 |

---

## ⚡ 빠른 시작

### 1. 설치

```powershell
# Codex 사용자
git clone https://github.com/bagseunggwon30-cyber/cucp.git "$env:USERPROFILE\.codex\skills\cucp-computer-use"

# 또는 Kiro / 기타 호환 환경의 skills 폴더에 복사
```

### 2. 헬스체크

```powershell
$wrapper = "$env:USERPROFILE\.codex\skills\cucp-computer-use\scripts\cucp.ps1"
& $wrapper -Brief macro health-quick
```

### 3. 첫 매크로 실행

```powershell
# 현재 윈도우 목록 (read-only)
& $wrapper macro windows

# 'Save' 라벨 후보 + 점수 (read-only, --explain)
& $wrapper macro find-label --label "Save" --explain

# XG5000 / XP-Builder 작업 카드 열기 (read-only context 저장)
& $wrapper macro task-card open

# 클릭 (live, -AllowLiveControl 필수)
& $wrapper -AllowLiveControl macro smart-click --label "Save" --match "Notepad"
```

---

## 🎯 핵심 매크로

### 관찰 (read-only)

```powershell
& $w macro windows                                            # Win32 enum, deterministic
& $w macro find-label --label "Save" --explain                # 후보 + 점수
& $w macro ocr-find-text --text "Send" --match contains       # OCR (Windows.Media.Ocr)
& $w macro coord-profile --x 1200 --y 720 --target-match Kiro # DPI/모니터 프로파일
& $w macro app-profile --match Chrome --auto-probe            # 앱 자동화 전략 점수
& $w macro task-card show                                     # XG5000/XP-Builder context JSON
```

### XG5000 / XP-Builder 실습 context

```powershell
# 작은 작업 카드 창을 띄워 디바이스, 주소 범위, 요구조건, 주의사항 저장
& $w macro task-card open

# CLI에서 바로 저장
& $w macro task-card save --tool XG5000 --project "packing-sim" --plc "XGB/XGI" `
  --communication "XGT/P2P" --devices "X0,Y20,M10,D100" `
  --ranges "X0-X7,Y20-Y27,D100-D120" `
  --requirements "check ladder interlocks before live edits" `
  --constraints "download forbidden; online write forbidden"

# XG5000 창 프로파일링 시 task_card가 자동 포함됨
& $w macro app-profile --match XG5000 --probe-uia --include-affordances --json-only
```

전용 Codex 스킬은 `skills/xg5000-cucp-assistant/SKILL.md`에 따로 제공된다. 이 스킬은 CUCP `task-card`를 먼저 읽고, XG5000/XP-Builder 작업에서 read-only 분석 → dry-run → 명시 승인된 live control 순서를 강제한다.
기존 v1.5.0 wrapper에 바로 붙여 쓸 때는 `scripts/cucp-xg5000-bridge.ps1`로 `task-card`와 `app-profile` 자동 로드를 사용할 수 있다.

### 조작 (live, `-AllowLiveControl` 필수)

```powershell
& $w -AllowLiveControl macro click-label --label "Save"
& $w -AllowLiveControl macro smart-click --label "Save" --match Kiro --precision-points
&    # cascade: UIA Pattern → UIA 좌표 → icon-find → fusion → OCR → vision
& $w -AllowLiveControl macro fill-label --label "Name" --text "Alice" --enter
& $w -AllowLiveControl macro shortcut --keys "ctrl+s"
```

### Electron 앱 — CDP/DOM (좌표 무관, Shadow DOM 통과)

```powershell
# 1. 앱을 --remote-debugging-port=9222 옵션으로 시작 (references/cdp-setup.md)
# 2. 그 후:
& $w macro cdp-detect                                         # 포트 + 페이지 탐지
& $w macro cdp-deep-find --text "Send" --page-match Kiro      # 🆕 Shadow DOM/iframe report
& $w -AllowLiveControl macro cdp-smart-click --text "Send"    # DOM 직접 클릭
& $w -AllowLiveControl macro cdp-smart-type --label "Message" --text "msg" --press-enter
```

### 🆕 v1.4.0 신규 매크로

```powershell
# 한국어 IME-safe paste (clipboard route, 마우스 안 움직임)
& $w -AllowLiveControl macro safe-type-ime --text "안녕하세요" --target-match Notepad

# UI recovery loop
& $w macro modal-detect                                       # 모달/대화상자 감지
& $w macro recovery-plan --failed-step "macro click-label --label Save"
& $w macro recovery-run --dry-run                             # plan only
& $w -AllowLiveControl macro recovery-run --confirm-sensitive # actuate (sensitive gate)

# Coordinate precision validation (read-only, 라이브 클릭 없이 검증)
& $w macro precision-validate --x 1200 --y 720 --target-match Kiro --samples 5

# Benchmark (PII 미수집)
& $w macro benchmark --iters 3

# Release notes (CHANGELOG 자동 split + secret redaction)
& $w macro release-notes --version 1.4.0
```

---

## 🛡️ 안전 & 보안 정책

CUCP는 모든 라이브 동작에 대해 **다층 게이트**를 적용한다:

| 레이어 | 동작 |
|:--|:--|
| 🔐 **AllowLiveControl** | 모든 actuation 매크로는 `-AllowLiveControl` 게이트 통과 필수 |
| 🎯 **Hit-test guard** | 좌표 클릭은 `--target-match` / `--target-hwnd` 로 의도한 윈도우 검증 |
| 🔢 **Confidence floor** | low-confidence 매칭 (score < 60) 자동 거부 |
| 🚫 **Sensitive gate** | UAC / 비밀번호 / 결제 / 자격증명 화면 자동 거부 |
| ⚠️ **Recovery sensitive** | `recovery-run` 의 live action 은 `--confirm-sensitive` 강제 |
| 📝 **Audit trail** | 모든 라이브 동작은 trajectory NDJSON 에 기록 |
| 🧹 **Secret redaction** | `release-notes` 가 출력 직전 PAT/sk-/AKIA/Bearer/JWT/PEM **6종 패턴** 자동 redact |

### Secret Redaction 패턴

| 패턴 | 예시 → 치환 |
|:--|:--|
| GitHub PAT | `ghp_xxx...` → `[REDACTED:github_pat]` |
| OpenAI API key | `sk-xxx...` → `[REDACTED:openai_key]` |
| AWS access key | `AKIAIOSFODNN7EXAMPLE` → `[REDACTED:aws_key]` |
| Bearer token | `Bearer xxx...` → `[REDACTED:bearer]` |
| JWT | `eyJ...xxx...xxx` → `[REDACTED:jwt]` |
| PEM private key | `-----BEGIN ... PRIVATE KEY-----` → `[REDACTED:pem_block]` |

---

## 📊 표준 exit code

| code | 의미 | 대응 |
|:-:|:--|:--|
| `0` | ok | 정상 |
| `1` | generic failure / not_found / 입력 누락 | 입력 점검 |
| `2` | partial / ambiguous / no_match (회복 가능) | `recovery-plan` 추천 |
| `3` | safety blocked (`AllowLiveControl` 누락, hit-test 가드, low-confidence 등) | 사용자 명시 승인 후 재시도 |
| `124` | timeout | helper 재시작 + `-InvokeTimeoutMs` 늘리기 |

---

## 📁 폴더 구조

```
cucp-computer-use/
├── 📄 SKILL.md                           # 스킬 표면 문서 (130 라인 이내)
├── 📄 CHANGELOG.md                       # 버전별 변경사항 (v0.1.0 ~ v1.5.1)
├── 📄 README.md                          # 이 문서
├── 📁 agents/
│   └── openai.yaml                       # Codex agent 설정
├── 📁 plans/
│   ├── notepad-hello-world.json          # 샘플 plan
│   └── xg5000-program-check.json
├── 📁 references/                        # 상세 문서
│   ├── command-reference.md              # 매크로 전체 레퍼런스
│   ├── troubleshooting.md                # 진단 / 복구 / selector 점수표
│   ├── cdp-setup.md                      # Electron CDP 활성화 가이드
│   ├── remaining-work.md                 # 진행률 100% / v1.5+ 후보
│   ├── xg5000-task-card.md               # XG5000/XP-Builder task-card bridge
│   └── audit-ps5-pitfalls.ps1            # PowerShell 5.x 함정 진단
├── 📁 scripts/
│   ├── cucp.ps1                          # 메인 wrapper (~12,000줄)
│   ├── cucp-native-helper.ps1            # Win32+UIA+OCR+CDP P/Invoke (~4,000줄)
│   ├── cucp-task-card.ps1                # XG5000/XP-Builder 작업 카드 UI + JSON 저장
│   └── cucp-xg5000-bridge.ps1            # wrapper patch 전용 task-card/app-profile bridge
├── 📁 skills/
│   └── xg5000-cucp-assistant/
│       └── SKILL.md                      # XG5000/XP-Builder 전용 Codex skill
└── 📁 tests/
    └── cucp.Tests.ps1                    # Pester 회귀 테스트 (~190건)
```

---

## ✅ 검증 상태

| 항목 | 결과 |
|:--|:--|
| Pester 회귀 | **190 / 190** (2026-05-27 설치 repo 실측) |
| self-test | 6 / 6 passed |
| AST parse | 3 / 3 OK (`cucp.ps1`, `cucp-native-helper.ps1`, `cucp.Tests.ps1`) |
| Sanity check | 9 / 9 신규 매크로 동작 + 의도된 envelope schema |
| Secret redaction | 합성 CHANGELOG 4종 secret 모두 `[REDACTED:*]` 치환 검증 |

```powershell
# 회귀 테스트 직접 실행
Invoke-Pester C:\<path>\cucp-computer-use\tests\cucp.Tests.ps1
```

---

## 🚦 운영 패턴

긴 세션에서 Codex / Kiro 데스크톱이 느려질 수 있어 다음 패턴 권장:

```powershell
# ① 자주 쓰는 read-only (helper 안 부름)
& $w macro windows
& $w macro health-quick

# ② 반복 screenshot/vision-click 피하기
& $w -AllowLiveControl macro smart-click --label "Save" --no-vision

# ③ 세션 시작 전 cache 정리
& $w macro cleanup --dry-run
& $w macro cleanup --execute --older-than-minutes 30

# ④ 라이브 후 검증 + recovery
& $w macro modal-detect
& $w macro recovery-plan --failed-step "<last command>"

# ⑤ 정기 벤치마크 (PII 미수집)
& $w macro benchmark --iters 3
```

---

## 📚 문서

| 문서 | 설명 |
|:--|:--|
| [`SKILL.md`](SKILL.md) | 스킬 표면 (Codex skill 등록 메타) |
| [`CHANGELOG.md`](CHANGELOG.md) | 버전별 변경사항 (v0.1.0 ~ v1.5.1) |
| [`references/command-reference.md`](references/command-reference.md) | 매크로 전체 레퍼런스 |
| [`references/troubleshooting.md`](references/troubleshooting.md) | 진단 / 복구 / selector 점수표 |
| [`references/cdp-setup.md`](references/cdp-setup.md) | Electron CDP 활성화 가이드 |
| [`references/remaining-work.md`](references/remaining-work.md) | 진행률 / v1.5+ 후보 |
| [`references/xg5000-task-card.md`](references/xg5000-task-card.md) | XG5000/XP-Builder task-card bridge |
| [`skills/xg5000-cucp-assistant/SKILL.md`](skills/xg5000-cucp-assistant/SKILL.md) | XG5000/XP-Builder 전용 Codex skill |

---

## 🚧 한계

- **DirectX / 게임 표면**: anti-cheat / exclusive fullscreen 시 capture 실패 가능
- **DRM 보호 화면** (Netflix 등): 검은 화면 캡처
- **ProseMirror / TipTap**: contenteditable 에디터의 단순 `execCommand` 거부 — `Input.insertText` 추후 sprint
- **매우 작은 폰트 (<8pt)**: OCR 정확도 떨어짐
- **Cross-origin iframe**: 보안상 traversal 차단 (`iframes_blocked` 카운트로 보고)
- **Windows 10/11 전용**: `Windows.Media.Ocr` 의존, macOS / Linux 미지원

---

## 🗺️ 로드맵 (v1.5+ 후보)

- 🎮 **DXGI capture** — 게임 / 풀스크린 영역 capture 우회
- 🎭 **Auto-mask region** — `screenshot-diff` 가 노이즈 영역 (시계/배지/캐럿) 자동 식별
- 🖥️ **Multi-monitor coord-anchor** — display layout 변화 시 anchor 자동 재 anchor
- 🍎 **macOS / Linux 포팅** — 현재 Windows 10/11 전용
- 💰 **Vision LLM token budget** — vision-click fallback의 비용 측정 + budget gate
- ✏️ **CDP `Input.insertText`** — ProseMirror/TipTap 라이브 입력

---

## 📜 라이선스

상용 제품 — 라이선스는 별도 협의.

---

<div align="center">

**Made with 🖱️ + ⌨️ for AI agents that respect your desktop**

[⬆ 위로](#-cucp)

</div>
