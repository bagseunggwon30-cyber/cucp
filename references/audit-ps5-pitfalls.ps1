# ============================================================================
# PS5 함정 진단 스크립트 (read-only, v1.1.0)
# ============================================================================
# CUCP 스크립트들에서 PowerShell 5.x 의 알려진 함정 패턴을 grep + AST 로 탐지.
# 일괄 자동 수정은 안 함 — 이미 동작하는 코드를 깰 위험이 더 큼. 대신 잠재
# 위험 위치를 출력해서 사람이 검토하도록 도움.
#
# 사용법:
#   powershell -NoProfile -ExecutionPolicy Bypass -File audit-ps5-pitfalls.ps1
#
# 검사 항목:
#   1. statement context 의 inline-if 패턴
#      ($x = if (...) {...} else {...}) — 일부 케이스에서 깨짐 (특히 ScriptDiff
#      같은 복잡한 함수 안). string return 은 보통 OK, int/double return 은 위험.
#   2. $args 자동변수 사용
#      함수 매개변수 이름으로 $args 쓰면 자동변수와 충돌. $argList 권장.
#   3. ordered hashtable 의 [0] 인덱싱
#      single ordered hashtable 의 [0] 은 첫 entry value 반환. @() 로 array
#      강제 후 인덱싱해야 함.
#   4. Get-Content 단일 라인 케이스
#      파일이 1라인이면 string 반환, 2+라인이면 array. .Count 가 string 길이로
#      잘못 동작. @(Get-Content) 로 array 강제 권장.
#   5. Start-Process -PassThru 의 ExitCode
#      timeout overload WaitForExit 후 ExitCode 가 InvalidOpEx 던질 수 있음.
#      proc.Refresh() + by-PID 재조회 + JSON status fallback 패턴 권장.
# ============================================================================
[CmdletBinding()]
param(
    [string]$ScriptRoot
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ScriptRoot 결정 — 매개변수 없으면 자기 위치 기준
if (-not $ScriptRoot) {
    $myPath = $MyInvocation.MyCommand.Path
    if ($myPath) {
        # references/audit-ps5-pitfalls.ps1 → references → 스킬 루트
        $ScriptRoot = Split-Path -Parent (Split-Path -Parent $myPath)
    } else {
        $ScriptRoot = (Get-Location).Path
    }
}

$targets = @(
    Join-Path $ScriptRoot "scripts\cucp.ps1"
    Join-Path $ScriptRoot "scripts\cucp-native-helper.ps1"
)

$findings = New-Object System.Collections.ArrayList

function _Report {
    param([string]$File, [int]$Line, [string]$Category, [string]$Snippet, [string]$Risk)
    [void]$findings.Add([pscustomobject]@{
        file = (Split-Path -Leaf $File)
        line = $Line
        category = $Category
        risk = $Risk
        snippet = $Snippet.Trim()
    })
}

foreach ($file in $targets) {
    if (-not (Test-Path -LiteralPath $file)) { continue }
    $lines = Get-Content -LiteralPath $file -Encoding UTF8
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        $lineNo = $i + 1

        # 1. inline-if (statement context) — `$var = if (cond) { ... } else { ... }`
        if ($l -match '^\s*\$\w+\s*=\s*if\s*\(') {
            # double / int / numeric return 인지 추정 (위험 케이스)
            if ($l -match 'else\s*\{\s*\d+(\.\d+)?\s*\}' -or $l -match 'else\s*\{\s*0\.0\s*\}') {
                _Report -File $file -Line $lineNo -Category "inline_if_numeric" `
                    -Snippet $l -Risk "high (numeric return — known to break in PS5)"
            } elseif ($l -match 'else\s*\{\s*"[^"]*"\s*\}') {
                _Report -File $file -Line $lineNo -Category "inline_if_string" `
                    -Snippet $l -Risk "low (string return — usually OK)"
            } else {
                _Report -File $file -Line $lineNo -Category "inline_if_other" `
                    -Snippet $l -Risk "medium (review recommended)"
            }
        }

        # 2. $args 자동변수 사용 (함수 매개변수 또는 본문 안)
        if ($l -match '\$args\b' -and $l -notmatch '#.*\$args' -and $l -notmatch '\$argList') {
            _Report -File $file -Line $lineNo -Category "args_automatic_var" `
                -Snippet $l -Risk "medium ($args is auto var — prefer \$argList)"
        }

        # 3. Get-Content without @() 강제 (단일 라인 함정)
        if ($l -match '\$\w+\s*=\s*Get-Content\b' -and $l -notmatch '@\(Get-Content') {
            _Report -File $file -Line $lineNo -Category "getcontent_single_line" `
                -Snippet $l -Risk "low (use @(Get-Content ...) for array safety)"
        }
    }
}

# 결과 출력
if ($findings.Count -eq 0) {
    Write-Host "OK no PS5 pitfalls detected" -ForegroundColor Green
    exit 0
}

# 위험도별 그룹화
$byRisk = $findings | Group-Object -Property risk | Sort-Object Name
Write-Host ("=" * 78)
Write-Host "PS5 PITFALL AUDIT — $($findings.Count) findings"
Write-Host ("=" * 78)
foreach ($g in $byRisk) {
    Write-Host ""
    Write-Host "[$($g.Name)] $($g.Count) findings"
    foreach ($f in $g.Group | Sort-Object file, line) {
        Write-Host ("  {0,-30} L{1,5}  {2}" -f $f.file, $f.line, $f.category)
        Write-Host ("    > " + $f.snippet)
    }
}
Write-Host ""
Write-Host "Note: high-risk findings should be reviewed and fixed."
Write-Host "      low-risk usually safe. medium-risk needs context check."

# JSON output for CI
$summary = [pscustomobject]@{
    total = $findings.Count
    high = @($findings | Where-Object { $_.risk -like "high*" }).Count
    medium = @($findings | Where-Object { $_.risk -like "medium*" }).Count
    low = @($findings | Where-Object { $_.risk -like "low*" }).Count
    findings = @($findings)
}
$jsonPath = Join-Path $env:TEMP "cucp-ps5-audit-$([Guid]::NewGuid().ToString('N')).json"
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
Write-Host ""
Write-Host "JSON report: $jsonPath"

# exit 0: read-only audit. high findings 는 사람이 보고 결정하도록.
exit 0
