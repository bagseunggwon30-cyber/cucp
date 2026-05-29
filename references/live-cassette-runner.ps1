# CUCP Live Cassette Runner (v2.1.0)
# Interactive runner for live verification cassettes.
# Saves cassette JSONs under live-verify/<env>/.
#
# Usage examples (run from repo root):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\references\live-cassette-runner.ps1 -Env all
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\references\live-cassette-runner.ps1 -Env notepad
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\references\live-cassette-runner.ps1 -Env kiro
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\references\live-cassette-runner.ps1 -Env chrome
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\references\live-cassette-runner.ps1 -Env xg5000
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\references\live-cassette-runner.ps1 -Env xg5000 -DryRun
[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet('notepad', 'kiro', 'chrome', 'xg5000', 'all')]
    [string]$Env = 'all',
    [switch]$All,
    [switch]$DryRun
)

if ($All) { $Env = 'all' }

try {
    [System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$repoRoot = Split-Path -Parent $PSScriptRoot
$wrapper = Join-Path $repoRoot 'scripts\cucp.ps1'
$cassetteRoot = Join-Path $repoRoot 'live-verify'

if (-not (Test-Path -LiteralPath $cassetteRoot)) {
    New-Item -ItemType Directory -Path $cassetteRoot -Force | Out-Null
}

function _Run-Macro {
    param([string[]]$WrapperArgs, [switch]$Live)
    $invokeArgs = @()
    if ($Live) { $invokeArgs += '-AllowLiveControl' }
    $invokeArgs += $WrapperArgs
    $cmdLine = "cucp.ps1 " + ($invokeArgs -join ' ')
    if ($DryRun) {
        Write-Host ("DRY RUN: " + $cmdLine)
        return $null
    }
    Write-Host ("RUN    : " + $cmdLine)
    $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $wrapper @invokeArgs 2>&1 | Out-String
    return $raw
}

function _Save-Cassette {
    param([string]$EnvName, [string]$Name, [string]$Content)
    if (-not $Content) { return $null }
    $dir = Join-Path $cassetteRoot $EnvName
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $path = Join-Path $dir ($Name + '-' + $stamp + '.json')
    # BOM 없는 UTF-8 로 저장. PowerShell 5.x 의 `Set-Content -Encoding UTF8` 는 BOM 을
    # 붙여서 xg5000-evidence 의 no_utf8_bom 계약 검사를 깨뜨린다 (회귀 방지).
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $Content, $utf8NoBom)
    Write-Host ('saved cassette: ' + $path)
    return $path
}

function _Ask-YesNo {
    param([string]$Prompt)
    if ($DryRun) { return $true }
    $r = Read-Host ($Prompt + ' (Y/N)')
    return ($r -eq 'Y' -or $r -eq 'y')
}

function _Cassette-Notepad {
    Write-Host ''
    Write-Host '=== Notepad cassette ==='
    Write-Host 'Prep: Make sure notepad.exe is running (open it first).'
    Write-Host '      Korean IME helps if you want to test safe-type-ime.'
    if (-not (_Ask-YesNo 'Continue with Notepad?')) { return }
    $r1 = _Run-Macro -WrapperArgs @('macro', 'windows', '--match', 'Notepad', '--json-only')
    _Save-Cassette -EnvName 'notepad' -Name 'windows-enum' -Content $r1 | Out-Null
    Write-Host 'Notepad client area pixel coordinates (screen-absolute, top-left = 0,0).'
    if ($DryRun) {
        $x = '600'; $y = '400'
    } else {
        $x = Read-Host 'x (default 600)'
        $y = Read-Host 'y (default 400)'
        if (-not $x) { $x = '600' }
        if (-not $y) { $y = '400' }
    }
    $r2 = _Run-Macro -Live -WrapperArgs @('macro', 'mouse-verify', '--x', $x, '--y', $y, '--target-match', 'Notepad', '--samples', '5', '--json-only')
    _Save-Cassette -EnvName 'notepad' -Name 'mouse-verify' -Content $r2 | Out-Null
    $r3 = _Run-Macro -Live -WrapperArgs @('macro', 'safe-type-ime', '--text', 'hello cucp', '--target-match', 'Notepad', '--json-only')
    _Save-Cassette -EnvName 'notepad' -Name 'safe-type-ime' -Content $r3 | Out-Null
}

function _Cassette-Kiro {
    Write-Host ''
    Write-Host '=== Kiro (Electron) cassette ==='
    Write-Host 'Prep: Start Kiro with --remote-debugging-port=9222.'
    Write-Host '      Example: Kiro.exe --remote-debugging-port=9222'
    if (-not (_Ask-YesNo 'Continue with Kiro?')) { return }
    $r1 = _Run-Macro -WrapperArgs @('macro', 'cdp-detect', '--port', '9222', '--json-only')
    _Save-Cassette -EnvName 'kiro' -Name 'cdp-detect' -Content $r1 | Out-Null
    $r2 = _Run-Macro -WrapperArgs @('macro', 'cdp-deep-find', '--text', 'Send', '--page-match', 'Kiro', '--port', '9222', '--json-only')
    _Save-Cassette -EnvName 'kiro' -Name 'cdp-deep-find' -Content $r2 | Out-Null
    Write-Host 'ProseMirror selector (e.g. div[contenteditable=true]). Empty = use document.activeElement.'
    if ($DryRun) {
        $sel = 'div[contenteditable=true]'
    } else {
        $sel = Read-Host 'selector (Enter to skip insert step)'
    }
    if ($sel) {
        $r3 = _Run-Macro -Live -WrapperArgs @('macro', 'cdp-prosemirror-insert', '--selector', $sel, '--text', 'cucp prosemirror test', '--page-match', 'Kiro', '--port', '9222', '--json-only')
        _Save-Cassette -EnvName 'kiro' -Name 'cdp-prosemirror-insert' -Content $r3 | Out-Null
    }
}

function _Cassette-Chrome {
    Write-Host ''
    Write-Host '=== Chrome cassette ==='
    Write-Host 'Prep: Start Chrome with --remote-debugging-port=9222.'
    if (-not (_Ask-YesNo 'Continue with Chrome?')) { return }
    $r1 = _Run-Macro -WrapperArgs @('macro', 'cdp-detect', '--port', '9222', '--json-only')
    _Save-Cassette -EnvName 'chrome' -Name 'cdp-detect' -Content $r1 | Out-Null
    Write-Host 'Click target text on the visible Chrome page (e.g. Search button label).'
    if ($DryRun) {
        $text = 'Search'
    } else {
        $text = Read-Host 'text (Enter for: Search)'
        if (-not $text) { $text = 'Search' }
    }
    $r2 = _Run-Macro -Live -WrapperArgs @('macro', 'cdp-smart-click', '--text', $text, '--port', '9222', '--json-only')
    _Save-Cassette -EnvName 'chrome' -Name 'cdp-smart-click' -Content $r2 | Out-Null
}

function _Cassette-XG5000 {
    Write-Host ''
    Write-Host '=== XG5000 cassette ==='
    Write-Host 'Prep: Best with XG5000 or XP-Builder running. task-card itself works without it.'
    if (-not (_Ask-YesNo 'Continue with XG5000?')) { return }
    $r1 = _Run-Macro -WrapperArgs @('macro', 'task-card', 'show', '--json-only')
    _Save-Cassette -EnvName 'xg5000' -Name 'task-card-show' -Content $r1 | Out-Null
    $r2 = _Run-Macro -WrapperArgs @('macro', 'app-profile', '--match', 'XG5000', '--json-only')
    _Save-Cassette -EnvName 'xg5000' -Name 'app-profile' -Content $r2 | Out-Null
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
Write-Host ('=== cassette runner finished. cassette root: ' + $cassetteRoot + ' ===')
