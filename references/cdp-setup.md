# CDP (Chrome DevTools Protocol) 활성화 가이드

CUCP v1.3.0 부터 Electron 앱 (Kiro / VS Code / Slack / Discord 등) 의 DOM 직접
제어가 가능합니다. 좌표/SendInput/UIA 우회 — Electron contenteditable 같은
"UIA tree에 안 보이지만 DOM에는 있는" element 도 안정적으로 focus + value set.

## 왜 필요한가

좌표 기반 클릭의 본질적 한계:

| 문제 | 좌표 클릭 | CDP |
|---|---|---|
| 윈도우 크기/위치 변화 | 좌표 의미 잃음 | 좌표 안 씀 |
| 다른 창이 위에 떠있음 | 가려진 좌표 클릭 | DOM 은 layout 무관 |
| Electron contenteditable | UIA tree 미노출 | DOM 직접 접근 |
| Korean IME / focus race | SendInput Unicode 변환 함정 | element.value 직접 set |
| 클릭 후 검증 | screenshot diff (false positive) | DOM 이벤트 직접 |

## Kiro 활성화 방법

Kiro 는 기본적으로 `--remote-debugging-port` 가 꺼진 상태로 실행됩니다.
다음 두 가지 방법 중 하나 사용:

### 방법 1 — 단축키 / 바탕화면 아이콘 수정 (권장)

1. Kiro 바로가기 (예: 시작메뉴, 작업표시줄) 우클릭 → **속성**
2. **대상(Target)** 필드 끝에 ` --remote-debugging-port=9222` 추가
   ```
   "C:\Users\<사용자>\AppData\Local\Programs\Kiro\Kiro.exe" --remote-debugging-port=9222
   ```
3. 적용 → Kiro 다음 실행부터 9222 포트로 CDP 가능

### 방법 2 — 일회성 실행

PowerShell:
```powershell
# 기존 Kiro 종료 후
& "C:\Users\$env:USERNAME\AppData\Local\Programs\Kiro\Kiro.exe" --remote-debugging-port=9222
```

### 검증

활성화 후 CUCP 매크로로 확인:
```powershell
& <wrapper> macro cdp-detect
# ok cdp-detect port=9222 pages=N browser=...
```

또는 직접 브라우저로:
```
http://127.0.0.1:9222/json/list
```
JSON 으로 페이지 목록이 나오면 OK.

## 보안 주의

`--remote-debugging-port=9222` 를 켜면 **localhost (127.0.0.1) 의 모든 프로세스가
Kiro 의 DOM 에 접근 가능**합니다. 즉:

- 같은 PC 의 다른 사용자/프로세스가 Kiro 채팅 내용 읽기 가능
- 같은 PC 의 다른 사용자/프로세스가 Kiro 에 명령 입력 가능

권장:
- 외부 노출 안 됨 (127.0.0.1 만 listen, 외부 NIC 안 들음)
- 그래도 신뢰할 수 없는 사용자가 같은 PC를 쓰는 환경에선 비활성 권장
- 일반적인 개인 PC / 개발 머신 에선 안전

## 다른 Electron 앱

같은 방법으로 활성화 가능:

| 앱 | 실행 파일 |
|---|---|
| VS Code | `Code.exe --remote-debugging-port=9223` |
| Slack | `slack.exe --remote-debugging-port=9224` |
| Discord | `Discord.exe --remote-debugging-port=9225` |
| Postman | `Postman.exe --remote-debugging-port=9226` |
| Notion | `Notion.exe --remote-debugging-port=9227` |

각 앱 별로 다른 포트 권장 (충돌 방지). CUCP 매크로의 `--port N` 옵션으로 선택.

## 사용 예시

```powershell
# 페이지 목록 확인
& <wrapper> macro cdp-detect

# Kiro 페이지에서 임의 JS 실행
& <wrapper> macro cdp-eval --expr "document.title" --page-match Kiro

# Kiro 채팅 입력란에 텍스트 + Enter (좌표 무관)
& <wrapper> -AllowLiveControl macro cdp-type \
   --selector "textarea[placeholder*='Questions or describe']" \
   --text "Hello from CUCP" \
   --press-enter \
   --page-match Kiro

# 보내기 버튼 클릭
& <wrapper> -AllowLiveControl macro cdp-click \
   --selector "button[aria-label='Send']" \
   --page-match Kiro
```

## smart-click 통합

`smart-click` 매크로의 cascade 에 **Stage 0 (CDP if available)** 추가됨:
1. **Stage 0**: CDP `cdp-type` / `cdp-click` (Electron 앱 + 9222 포트 열려있을 때)
2. Stage 1~6: UIA Pattern → UIA 좌표 → icon-find → fusion → OCR → vision (기존)

CDP 가 가능한 환경에선 자동으로 Stage 0 부터 시도 — 빠르고 안정적.
실패 시 Stage 1~6 정상 cascade.

## 한계

- Electron 아닌 앱 (메모장, XG5000 같은 native Win32) 은 CDP 적용 불가 → Stage 1~6 fallback
- 일부 Electron 앱은 보안 정책으로 CDP 비활성화 (예: Microsoft Teams 의 일부 빌드)
- CDP 포트 활성 후 Electron 앱 재시작 필요 (런타임 토글 안 됨)
