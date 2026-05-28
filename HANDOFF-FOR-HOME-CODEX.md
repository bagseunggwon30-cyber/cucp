# Home Codex Handoff: Apply CUCP v1.5.1 XG5000 Task Card Update

이 문서는 `cucp-main-v1.5.1-xg5000-task-card.zip`을 집의 메인 Codex에게 전달했을 때, 기존 CUCP 원본 저장소에 이번 업데이트를 안전하게 병합하도록 안내하기 위한 작업 지시서입니다.

## 목표

기존 `bagseunggwon30-cyber/cucp` 원본에 다음 업데이트를 반영한다.

- XG5000 / XP-Builder 작업 카드 UI 추가
- 작업 카드 JSON 저장/읽기 추가
- CUCP `app-profile`이 PLC/SCADA 계열 창에서 `task_card` context를 자동으로 함께 쓰도록 연결
- XG5000 전용 Codex skill 추가
- README / CHANGELOG / command reference / remaining-work 문서 정리

## ZIP 안의 주요 파일

원본 CUCP 저장소에 아래 파일을 추가 또는 병합한다.

- `scripts/cucp-task-card.ps1`
- `scripts/cucp-xg5000-bridge.ps1`
- `references/xg5000-task-card.md`
- `skills/xg5000-cucp-assistant/SKILL.md`
- `UPLOAD-NOTES.md`
- `README.md`
- `CHANGELOG.md`
- `SKILL.md`
- `references/command-reference.md`
- `references/remaining-work.md`
- `scripts/cucp.ps1`

## 매우 중요한 주의사항

`scripts/cucp.ps1`은 원본의 최신 상태와 충돌할 수 있으므로 무조건 덮어쓰지 말고 병합한다.

반드시 확인할 병합 포인트:

- 상단 path 영역에 `TaskCardScriptPath`, `TaskCardDir`, `TaskCardPath` 추가
- `macro task-card` dispatch 추가
- `_Read-Switch` 근처에 다음 함수들 추가
  - `Invoke-TaskCardScript`
  - `Get-TaskCardContext`
  - `Get-TaskCardSaveArgs`
  - `Invoke-MacroTaskCard`
- `Invoke-MacroAppProfile`에서 PLC/SCADA 계열 앱일 때 `Get-TaskCardContext -Ensure` 호출
- `app-profile` JSON 출력에 `task_card` 필드 추가
- `macro session info` 출력에 `task_card_path`, `task_card_exists` 추가
- help 출력에 `macro task-card open|show|ensure|save|path|clear` 추가

만약 `scripts/cucp.ps1` 병합이 부담되면, 우선 `scripts/cucp-xg5000-bridge.ps1`을 사용한다. 이 bridge는 기존 wrapper를 크게 바꾸기 전에도 `task-card`와 `app-profile + task_card` 흐름을 쓸 수 있게 만든 임시 연결 스크립트다.

## 권장 작업 순서

1. 기존 CUCP 원본 저장소를 백업하거나 새 브랜치를 만든다.

   ```powershell
   git checkout -b codex/xg5000-task-card-20260527
   ```

2. ZIP을 임시 폴더에 푼다.

3. 새 파일은 그대로 복사한다.

   ```powershell
   Copy-Item .\scripts\cucp-task-card.ps1 <원본>\scripts\ -Force
   Copy-Item .\scripts\cucp-xg5000-bridge.ps1 <원본>\scripts\ -Force
   Copy-Item .\references\xg5000-task-card.md <원본>\references\ -Force
   Copy-Item .\skills\xg5000-cucp-assistant <원본>\skills\ -Recurse -Force
   ```

4. 문서 파일은 최신 원본과 비교 후 병합한다.

   - `README.md`
   - `CHANGELOG.md`
   - `SKILL.md`
   - `references/command-reference.md`
   - `references/remaining-work.md`

5. `scripts/cucp.ps1`은 위의 "병합 포인트"만 적용한다.

6. PowerShell 문법 검사를 실행한다.

   ```powershell
   $files = @(
     "<원본>\scripts\cucp.ps1",
     "<원본>\scripts\cucp-task-card.ps1",
     "<원본>\scripts\cucp-xg5000-bridge.ps1"
   )
   foreach ($file in $files) {
     $errs = $null
     $tokens = $null
     [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errs) | Out-Null
     if ($errs) { $errs | Format-List *; throw "AST parse failed: $file" }
     "AST OK: $file"
   }
   ```

7. 동작 검증을 실행한다.

   ```powershell
   $w = "<원본>\scripts\cucp.ps1"
   & $w -Quiet -Brief macro task-card clear
   & $w -Quiet -Brief macro task-card ensure
   & $w -Quiet macro task-card save --tool XG5000 --project "packing-sim" --plc "XGB/XGI" --communication "XGT/P2P" --devices "X0,Y20,M10,D100" --ranges "X0-X7,Y20-Y27,D100-D120" --requirements "check ladder interlocks before live edits" --constraints "download forbidden; online write forbidden"
   & $w -Quiet macro task-card show
   & $w -Quiet macro session info
   ```

8. XG5000이 열려 있으면 자동 로드도 확인한다.

   ```powershell
   & $w -Quiet macro app-profile --match XG5000 --json-only
   ```

   출력 JSON 안에 `task_card`가 있어야 한다.

9. 검증 후 커밋하고 푸시한다.

   ```powershell
   git add .
   git commit -m "Add XG5000 task-card context bridge"
   git push origin codex/xg5000-task-card-20260527
   ```

## 이번 ZIP의 범위

이 ZIP은 `XG5000 / XP-Builder task-card` 업데이트 중심이다.

OCR 반응속도 개선, persistent daemon, native scroll, native batch, foreground OCR crop 같은 작업은 별도 CUCP 작업분이 있을 수 있다. 원본 저장소에 그 내용까지 모두 반영하려면 다음 키워드를 추가로 비교한다.

- `native-daemon`
- `native-scroll`
- `native-batch`
- `coord-info`
- `ocr-screen --foreground`
- `--auto-region foreground`
- `foreground crop`

이 ZIP에 들어 있는 `scripts/cucp-xg5000-bridge.ps1`는 XG5000 task-card 연결을 빠르게 쓰기 위한 보조 bridge이며, 위 OCR/daemon 전체 업데이트를 대체하지 않는다.

## 완료 기준

- `macro task-card open|show|ensure|save|path|clear`가 동작한다.
- `%TEMP%\computer-use-control-plane\task-card\current-task-card.json`이 생성된다.
- `app-profile --match XG5000 --json-only` 출력에 `task_card`가 포함된다.
- `skills/xg5000-cucp-assistant/SKILL.md`가 원본 저장소에 존재한다.
- README에 XG5000 / XP-Builder task-card 사용법이 보인다.
