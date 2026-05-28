# =============================================================================
# CUCP Live Cassette Runner (v2.1.0)
# =============================================================================
# 사용자가 라이브 환경 (Notepad / Kiro / Chrome / XG5000) 에서 직접 실행해서
# cassette 를 보존하기 위한 helper. Pester 회귀로는 검증 못 하는 라이브 동작
# (mouse drift / CDP / IME paste / task-card) 을 한 번에 4환경에서 측정.
#
# 사용법:
#   # 4환경 모두 (각 환경 prompt 표시)
#   .\references\live-cassette-runner.ps1 -All
#
#   # 개별 환경
#   .\references\live-cassette-runner.ps1 -Env notepad
#   .\references\live-cassette-runner.ps1 -Env kiro
#   .\references\live-cassette-runner.ps1 -Env chrome
#   .\references\live-cassette-runner.ps1 -Env xg5000
#
# 결과 cassette 위치: live-verify\<env>\*.json
# 모든 cassette 는 cucp.live-verify/v1 schema.
# =============================================================================
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet('notepad', 'kiro', 'chrome', 'xg5000', 'all')]
    [string]$Env = 'all',
    [switch]$All,
    [switch]$DryRun
)

if ($All) { $Env = 'all' }

$repoRoot = Split-Path -Parent $PSScriptRoot
$wrapper = Join-Path $repoRoot 'scripts\cucp.ps1'
$cassetteRoot = Join-Path $repoRoot 'live-verify'

if (-not (Test-Path -LiteralPath $cassetteRoot)) {
    New-Item -ItemType Directory -Path $cassetteRoot -Force | Out-Null
}

function _Run-Macro {
    param([string[]]$Args, [switch]$Live)
    $invokeArgs = @()
    if ($Live) { $invokeArgs += '-AllowLiveControl' }
    $invokeArgs += $Args
    if ($DryRun) {
        Write-Host ("DRY RUN: cucp.ps1 " + ($invokeArgs -join ' '))
        return $null
    }
    Write-Host ("RUN    : cucp.ps1 " + ($invokeArgs -join ' '))
    $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $wrapper @invokeArgs 2>&1 | Out-String
    return $raw
}

function _Save-Cassette {
    param([string]$EnvName, [string]$Name, [string]$Content)
    $dir = Join-Path $cassetteRoot $EnvName
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir ($Name + '-' + (Get-Date).ToString("yyyyMMdd-HHmmss") + '.json')
    Set-Content -LiteralPath $path -Value $Content -Encoding UTF8
    Write-Host ('saved cassette: ' + $path)
    return $path
}

function _Cassette-Notepad {
    Write-Host ''
    Write-Host '=== Notepad cassette ==='
    Write-Host '준비: 메모장(notepad.exe) 을 미리 켜놓으세요. 한국어 IME 를 한번이라도 활성화한 상태가 좋습니다.'
    Write-Host '진행 시 Enter, 건너뛰기 N:'
    $go = Read-Host '진행 (Y/N)'
    if ($go -ne 'Y' -and $go -ne 'y') { return }
    # 1. windows enum (read-only)
    $r1 = _Run-Macro -Args @('macro', 'windows', '--match', 'Notepad', '--json-only')
    if ($r1) { _Save-Cassette -EnvName 'notepad' -Name 'windows-enum' -Content $r1 | Out-Null }
    # 2. mouse-verify dry-run (live, gate)
    Write-Host '메모장 본체 영역 좌표를 알려주세요. 화면 좌상단 기준 픽셀.'
    $x = Read-Host 'x 좌표 (기본 600)'
    $y = Read-Host 'y 좌표 (기본 400)'
    if (-not $x) { $x = '600' }
    if (-not $y) { $y = '400' }
    $r2 = _Run-Macro -Live -Args @('macro', 'mouse-verify', '--x', $x, '--y', $y, '--target-match', 'Notepad', '--samples', '5', '--json-only')
    if ($r2) { _Save-Cassette -EnvName 'notepad' -Name 'mouse-verify' -Content $r2 | Out-Null }
    # 3. safe-type-ime 한글 입력
    $r3 = _Run-Macro -Live -Args @('macro', 'safe-type-ime', '--text', '안녕하세요 cucp', '--target-match', 'Notepad', '--json-only')
    if ($r3) { _Save-Cassette -EnvName 'notepad' -Name 'safe-type-ime' -Content $r3 | Out-Null }
}

function _Cassette-Kiro {
    Write-Host ''
    Write-Host '=== Kiro (Electron) cassette ==='
    Write-Host '준비: Kiro 를 --remote-debugging-port=9222 로 실행하세요.'
    Write-Host '       (예: ' + '"' + 'C:\Program Files\Kiro\Kiro.exe' + '"' + ' --remote-debugging-port=9222)'
    $go = Read-Host '진행 (Y/N)'
    if ($go -ne 'Y' -and $go -ne 'y') { return }
    # 1. cdp-detect
    $r1 = _Run-Macro -Args @('macro', 'cdp-detect', '--port', '9222', '--json-only')
    if ($r1) { _Save-Cassette -EnvName 'kiro' -Name 'cdp-detect' -Content $r1 | Out-Null }
    # 2. cdp-deep-find (read-only Shadow DOM/iframe report)
    $r2 = _Run-Macro -Args @('macro', 'cdp-deep-find', '--text', 'Send', '--page-match', 'Kiro', '--port', '9222', '--json-only')
    if ($r2) { _Save-Cassette -EnvName 'kiro' -Name 'cdp-deep-find' -Content $r2 | Out-Null }
    # 3. cdp-prosemirror-insert (live)
    Write-Host 'ProseMirror 입력 selector (예: div[contenteditable=true], 비우면 activeElement 사용)'
    $sel = Read-Host 'selector (Enter=skip)'
    if ($sel) {
        $r3 = _Run-Macro -Live -Args @('macro', 'cdp-prosemirror-insert', '--selector', $sel, '--text', 'cucp prosemirror test', '--page-match', 'Kiro', '--port', '9222', '--json-only')
        if ($r3) { _Save-Cassette -EnvName 'kiro' -Name 'cdp-prosemirror-insert' -Content $r3 | Out-Null }
    }
}

function _Cassette-Chrome {
    Write-Host ''
    Write-Host '=== Chrome cassette ==='
    Write-Host '준비: Chrome 을 --remote-debugging-port=9222 로 실행하세요.'
    $go = Read-Host '진행 (Y/N)'
    if ($go -ne 'Y' -and $go -ne 'y') { return }
    $r1 = _Run-Macro -Args @('macro', 'cdp-detect', '--port', '9222', '--json-only')
    if ($r1) { _Save-Cassette -EnvName 'chrome' -Name 'cdp-detect' -Content $r1 | Out-Null }
    Write-Host '클릭 텍스트 (예: 검색)'
    $text = Read-Host 'text (Enter=검색)'
    if (-not $text) { $text = '검색' }
    $r2 = _Run-Macro -Live -Args @('macro', 'cdp-smart-click', '--text', $text, '--port', '9222', '--json-only')
    if ($r2) { _Save-Cassette -EnvName 'chrome' -Name 'cdp-smart-click' -Content $r2 | Out-Null }
}

function _Cassette-XG5000 {
    Write-Host ''
    Write-Host '=== XG5000 cassette ==='
    Write-Host '준비: XG5000 또는 XP-Builder 를 켜둔 상태가 좋습니다 (없어도 task-card 자체는 동작).'
    $go = Read-Host '진행 (Y/N)'
    if ($go -ne 'Y' -and $go -ne 'y') { return }
    # task-card open + show
    $r1 = _Run-Macro -Args @('macro', 'task-card', 'show', '--json-only')
    if ($r1) { _Save-Cassette -EnvName 'xg5000' -Name 'task-card-show' -Content $r1 | Out-Null }
    $r2 = _Run-Macro -Args @('macro', 'app-profile', '--match', 'XG5000', '--json-only')
    if ($r2) { _Save-Cassette -EnvName 'xg5000' -Name 'app-profile' -Content $r2 | Out-Null }
}

switch ($Env) {
    'notepad' { _Cassette-Notepad }
    'kiro'    { _Cassette-Kiro }
    'chrome'  { _Cassette-Chrome }
    'xg5000'  { _Cassette-XG5000 }
    'all' {
        _Cassette-Notepad
        _Cassette-Kiro
        _Cassette-Chrome
        _Cassette-XG5000
    }
}

Write-Host ''
Write-Host ('=== cassette 보존 끝. 위치: ' + $cassetteRoot + ' ===')
