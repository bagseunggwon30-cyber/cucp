[CmdletBinding(PositionalBinding = $false)]
param(
  [Alias('AllowLive')]
  [switch]$AllowLiveControl,
  [switch]$Quiet,
  [switch]$Brief,
  [Alias('CacheSec')]
  [int]$CacheSeconds = 2,
  [Alias('TimeoutMs','InvokeTimeout')]
  [int]$InvokeTimeoutMs = 30000,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$CucpArgs
)

# If the caller passed "--" as the first token (POSIX stop-parsing convention),
# strip it. Anything that follows is treated verbatim - this prevents
# PowerShell from interpreting tokens like "--out" as parameter abbreviations
# (e.g. -OutVariable). Callers that need to pass --out, --opt-name, etc. to
# the CUCP CLI should always prefix their args with "--".
if ($CucpArgs -and $CucpArgs.Count -gt 0 -and $CucpArgs[0] -eq "--") {
  if ($CucpArgs.Count -gt 1) {
    $CucpArgs = $CucpArgs[1..($CucpArgs.Count - 1)]
  } else {
    $CucpArgs = @()
  }
}

# ============================================================================
# CUCP Wrapper - Claude Computer Use grade control plane
# ============================================================================
# CUCP Wrapper - Claude Computer Use grade control plane for Windows
# ============================================================================
# 이 스크립트는 로컬 CUCP CLI 위에 다음 기능을 추가합니다:
#  - Observation cache + automatic observation_id injection (--after)
#  - Label-based grounding: 좌표 대신 텍스트 라벨로 클릭/입력
#  - Composite macros: wait-window, click-label, fill-label, goal 등 50+ 매크로
#  - Brief output mode: 모델 루프용 한 줄 결과
#  - UTF-8 safe output + persistent audit log
#  - Hard live-control gate: -AllowLiveControl 없으면 라이브 조작 전부 차단
#  - Win32 deterministic fallback: helper 없어도 window 목록 항상 가능
#  - Unified observation envelope (cucp.observation/v1)
# ============================================================================

$ErrorActionPreference = "Stop"

# ----- console encoding -----------------------------------------------------
# PowerShell 5.x 기본 인코딩이 CP949라 한글이 깨질 수 있음. UTF-8로 강제.
try {
  [System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding = [System.Text.Encoding]::UTF8
  if ($PSVersionTable.PSVersion.Major -ge 7 -and $PSStyle) {
    $PSStyle.OutputRendering = "Host"
  }
} catch { }

# ----- paths ----------------------------------------------------------------
# cli.mjs 경로 자동 탐색 순서:
#   1. 환경변수 CUCP_CLI_PATH (사용자가 명시 지정)
#   2. 스크립트 위치 기준 상대 경로 (스킬 폴더에 cli/ 번들된 경우)
#   3. 사용자 홈 기준 일반 설치 경로들
#   4. PATH에서 node + cucp 탐색
# 이 방식으로 하드코딩 없이 어느 PC에서도 동작.
#
# IMPORTANT: 잘못된 cli.mjs (예: CUCP Lite 같은 판매용 워크플로 검증 도구)를
# 자동으로 잡지 않도록 검증합니다. 진짜 desktop control CLI는
# package.json 의 name == "computer-use-control-plane" 또는 cli.mjs 안에
# "ControlPlane" / "observe appshot" 키워드가 존재해야 합니다.
function _Validate-CliMjs {
  param([string]$Path)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }
  try {
    # 1) package.json 검사 (있으면 가장 강력한 신호)
    $dir = Split-Path -Parent $Path
    $pkgPath = Join-Path $dir "..\package.json"
    if (Test-Path -LiteralPath $pkgPath) {
      try {
        $pkg = Get-Content -LiteralPath $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($pkg.name -eq "computer-use-control-plane") { return $true }
        # cucp-lite 같은 다른 패키지는 거부
        if ($pkg.name -and $pkg.name -ne "computer-use-control-plane") { return $false }
      } catch { }
    }
    # 2) cli.mjs 내용에 ControlPlane import 또는 observe appshot 명령이 있는지
    $head = Get-Content -LiteralPath $Path -TotalCount 60 -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $head) { return $false }
    $headStr = $head -join "`n"
    if ($headStr -match 'ControlPlane|control-plane\.mjs|observeAppshot|"observe"\s+&&\s+subcommand') {
      return $true
    }
    # 3) 명백히 다른 도구의 시그니처면 거부
    if ($headStr -match 'CUCP Lite|cucp-lite|workflow.*score|wizard\s+\[out\.json\]') {
      return $false
    }
    return $false
  } catch { return $false }
}

function _Find-CliPath {
  # 1) 환경변수 명시 지정
  if ($env:CUCP_CLI_PATH -and (Test-Path -LiteralPath $env:CUCP_CLI_PATH)) {
    if (_Validate-CliMjs $env:CUCP_CLI_PATH) { return $env:CUCP_CLI_PATH }
  }
  # 2) 스킬 폴더 내 번들 (cli/cli.mjs 또는 cli/src/cli.mjs)
  $scriptDir = $PSScriptRoot
  if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.ScriptName }
  $bundleCandidates = @(
    (Join-Path $scriptDir "..\cli\cli.mjs"),
    (Join-Path $scriptDir "..\cli\src\cli.mjs"),
    (Join-Path $scriptDir "cli.mjs")
  )
  foreach ($c in $bundleCandidates) {
    $resolved = [System.IO.Path]::GetFullPath($c)
    if (_Validate-CliMjs $resolved) { return $resolved }
  }
  # 3) 홈 디렉토리 기준 일반 설치 경로
  $homeCandidates = @(
    (Join-Path $env:USERPROFILE "cucp\src\cli.mjs"),
    (Join-Path $env:USERPROFILE ".cucp\src\cli.mjs"),
    (Join-Path $env:USERPROFILE "Documents\cucp\src\cli.mjs")
  )
  foreach ($c in $homeCandidates) {
    if (_Validate-CliMjs $c) { return $c }
  }
  # 4) 개발 환경 fallback: Documents\Codex 하위에서 검증을 통과한 cli.mjs만
  #    Lite 등 잘못된 CLI는 _Validate-CliMjs 가 거부함.
  $devBase = Join-Path $env:USERPROFILE "Documents\Codex"
  if (Test-Path -LiteralPath $devBase) {
    $found = Get-ChildItem -LiteralPath $devBase -Recurse -Filter "cli.mjs" -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match "src[/\\]cli\.mjs$" } |
      Sort-Object LastWriteTime -Descending
    foreach ($f in $found) {
      if (_Validate-CliMjs $f.FullName) { return $f.FullName }
    }
  }
  return $null
}

$Script:CliPath  = _Find-CliPath
$Script:AuditDir = Join-Path $env:TEMP "computer-use-control-plane"
$Script:CacheDir = Join-Path $Script:AuditDir "wrapper-cache"
$Script:WrapperLog = Join-Path $Script:AuditDir "cucp-wrapper.log"
$Script:InvokeTimeoutMs = [Math]::Max(1000, $InvokeTimeoutMs)

# ----- native helper path ---------------------------------------------------
# CUCP 전용 PowerShell helper 위치. Win32 + UIA + Screenshot을 직접 호출해서
# 외부 windows-mcp 서버나 Codex 공식 helper에 의존하지 않습니다. 이 helper는
# 스킬 폴더 안에 항상 같이 배포되므로 절대 경로 탐색 불필요.
$Script:NativeHelperPath = Join-Path $PSScriptRoot "cucp-native-helper.ps1"
if (-not (Test-Path -LiteralPath $Script:NativeHelperPath)) {
  $Script:NativeHelperPath = ""
}

# cli.mjs를 찾지 못하면 경고만 남기고 계속 진행 (read-only 매크로는 동작 가능)
if (-not $Script:CliPath) {
  $Script:CliPath = ""
  # 로그는 AuditDir 생성 후 기록
}

if (-not (Test-Path -LiteralPath $Script:CacheDir)) {
  try { New-Item -ItemType Directory -Path $Script:CacheDir -Force | Out-Null } catch { }
}

if (-not $Script:CliPath) {
  Write-WrapperLog -Message "WARNING: cli.mjs not found. Set CUCP_CLI_PATH env var or bundle cli/ into the skill folder. Read-only macros (windows, health-quick, icon-find) still work."
}
if (-not $Script:NativeHelperPath) {
  Write-WrapperLog -Message "WARNING: cucp-native-helper.ps1 not found in scripts/. Native fallback unavailable; macros will require cli.mjs."
}

# ============================================================================
# Invoke-NativeHelper - CUCP 자체 PowerShell helper 호출
# ============================================================================
# 외부 helper (windows-mcp, codex-win.ps1) 우회용. Win32 + UIA + Screenshot을
# 직접 호출하는 cucp-native-helper.ps1을 child PowerShell로 띄우고 JSON을
# stdout으로 받아 파싱합니다.
#
# Parameters:
#   -ArgList  string[]  helper에 그대로 전달할 인자 (예: @("-Action","windows","-Match","kiro"))
#   -TimeoutMs int       타임아웃 (기본 wrapper의 InvokeTimeoutMs)
#
# Returns: pscustomobject @{
#   ExitCode  int
#   Json      psobject  (parse 성공시)
#   Raw       string    (stdout 원본)
#   Err       string    (stderr 원본)
#   ElapsedMs int
# }
# ============================================================================
function Invoke-NativeHelper {
  # ==========================================================================
  # cucp-native-helper.ps1 을 child PowerShell 프로세스로 띄우고 결과 파싱.
  # ==========================================================================
  # 책임:
  #   1. -File 모드로 helper 호출 (NoProfile / ExecutionPolicy Bypass)
  #   2. 시간 초과 시 child kill + envelope ExitCode=124 반환
  #   3. stdout/stderr 임시 파일 → 읽기 → JSON 파싱 → 반환
  #   4. exit code 정확히 추정 (PS5 의 Start-Process bug 우회)
  #
  # exit code 추정 흐름 (v1.0.0 fix):
  #   a. proc.Refresh() + [int]proc.ExitCode  ← 가장 정확
  #   b. by-PID 재조회 ([Process]::GetProcessById)  ← (a) 가 InvalidOpEx 던질 때
  #   c. JSON status 기반 보정 (partial → 2, error → 1) ← (b) 도 실패 시
  # 이 3-tier fallback 이 없으면 partial(2) / error(1) 가 wrapper exit 0 으로
  # 흘러 들어가는 잠재 버그 발생 (v0.6.0~0.8.0 까지 있던 버그).
  # ==========================================================================
  param(
    [string[]]$ArgList,
    [int]$TimeoutMs = 0
  )
  if (-not $Script:NativeHelperPath) {
    return [pscustomobject]@{
      ExitCode = 1
      Json = $null
      Raw = ""
      Err = "native_helper_missing"
      ElapsedMs = 0
    }
  }
  if ($TimeoutMs -le 0) { $TimeoutMs = $Script:InvokeTimeoutMs }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $stdoutFile = Join-Path $Script:CacheDir ("native-" + [guid]::NewGuid().ToString("N") + ".json")
  $stderrFile = $stdoutFile + ".err"
  try {
    $allArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$Script:NativeHelperPath) + $ArgList
    $proc = Start-Process -FilePath "powershell" -ArgumentList $allArgs `
      -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile `
      -NoNewWindow -PassThru
    $exited = $proc.WaitForExit($TimeoutMs)
    if (-not $exited) {
      try { $proc.Kill() } catch { }
      try { [void]$proc.WaitForExit(3000) } catch { }
      $sw.Stop()
      Write-WrapperLog -Message "NATIVE TIMEOUT $($ArgList -join ' ')"
      return [pscustomobject]@{
        ExitCode = 124
        Json = $null
        Raw = ""
        Err = "TIMEOUT after ${TimeoutMs}ms"
        ElapsedMs = [int]$sw.Elapsed.TotalMilliseconds
      }
    }
    $sw.Stop()
    # Start-Process -PassThru 로 만든 Process 객체는 timeout-overload WaitForExit
    # 후 ExitCode 속성이 InvalidOperationException 을 던질 수 있음 (Process.HasExited 이슈).
    # 핸들 리프레시 후 [System.Diagnostics.Process]::GetProcessById 로 재조회.
    $exitCode = 0
    try {
      $proc.Refresh()
      $exitCode = [int]$proc.ExitCode
    } catch {
      # Process.ExitCode 가 throw 면 by-pid 로 다시 시도
      try {
        $pid2 = $proc.Id
        $p2 = [System.Diagnostics.Process]::GetProcessById($pid2)
        $exitCode = [int]$p2.ExitCode
      } catch {
        # 그래도 실패하면 stdout JSON 의 status 로 추정
        $exitCode = 0
      }
    }
    $raw = ""
    $err = ""
    if (Test-Path -LiteralPath $stdoutFile) { $raw = Get-Content -LiteralPath $stdoutFile -Raw -Encoding UTF8 }
    if (Test-Path -LiteralPath $stderrFile) { $err = Get-Content -LiteralPath $stderrFile -Raw -Encoding UTF8 }
    $json = $null
    if ($raw -and $raw.Trim().Length -gt 0) {
      try { $json = $raw | ConvertFrom-Json -ErrorAction Stop } catch { }
    }
    # ExitCode 추정 실패 시 JSON status 기반으로 보정
    if ($exitCode -eq 0 -and $json) {
      switch ("$($json.status)") {
        "partial" { $exitCode = 2 }
        "error"   { $exitCode = 1 }
      }
    }
    return [pscustomobject]@{
      ExitCode = $exitCode
      Json = $json
      Raw = $raw
      Err = $err
      ElapsedMs = [int]$sw.Elapsed.TotalMilliseconds
    }
  } catch {
    $sw.Stop()
    return [pscustomobject]@{
      ExitCode = 1
      Json = $null
      Raw = ""
      Err = $_.Exception.Message
      ElapsedMs = [int]$sw.Elapsed.TotalMilliseconds
    }
  } finally {
    Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
  }
}

# ----- logging --------------------------------------------------------------
function Write-WrapperLog {
  param([string]$Message)
  $timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffK")
  try { Add-Content -LiteralPath $Script:WrapperLog -Value "[$timestamp] $Message" -Encoding UTF8 } catch { }
}

function Write-Notice {
  param([string]$Message, [string]$Level = "INFO")
  if (-not $Quiet) {
    switch ($Level) {
      "ERROR"   { Write-Host "[CUCP] $Message" -ForegroundColor Red }
      "WARN"    { Write-Host "[CUCP] $Message" -ForegroundColor Yellow }
      "OK"      { Write-Host "[CUCP] $Message" -ForegroundColor Green }
      "BRIEF"   { Write-Host $Message }
      default   { Write-Host "[CUCP] $Message" -ForegroundColor Cyan }
    }
  }
  Write-WrapperLog -Message "$Level $Message"
}

# ----- prerequisites --------------------------------------------------------
function Test-Tool { param([string]$Name)
  try { $null = Get-Command $Name -ErrorAction Stop; return $true } catch { return $false }
}

if (-not (Test-Tool "node")) {
  Write-Notice -Level "ERROR" -Message "node 명령을 찾을 수 없습니다. Node.js 20+가 필요합니다."
  throw "node not found in PATH"
}

if (-not (Test-Path -LiteralPath $Script:CliPath)) {
  Write-Notice -Level "ERROR" -Message "CUCP CLI를 찾지 못했습니다: $Script:CliPath"
  throw "CUCP CLI not found at $Script:CliPath"
}

# ----- core invocation ------------------------------------------------------
function Invoke-Cucp {
  param([string[]]$ArgList, [switch]$CaptureJson)

  $invokeId = [guid]::NewGuid().ToString("N").Substring(0, 12)
  $invokeSw = [System.Diagnostics.Stopwatch]::StartNew()
  Write-WrapperLog -Message "INVOKE [$invokeId] $($ArgList -join ' ')"

  # CLI 경로 검증: 비어있으면 즉시 envelope 에러 반환 (외부 helper 의존 없는
  # native 매크로는 이 경로를 우회함). cli.mjs 가 잘못 잡힌 경우(예: CUCP Lite)
  # 호출 자체가 부적절한 메시지를 내는 것을 방지.
  if (-not $Script:CliPath -or -not (Test-Path -LiteralPath $Script:CliPath)) {
    Write-WrapperLog -Message "INVOKE [$invokeId] aborted: cli.mjs not found"
    return [pscustomobject]@{
      ExitCode = 1
      Json = [pscustomobject]@{
        status = "error"
        error_type = "cli_missing"
        summary = "CUCP control-plane CLI (cli.mjs) was not found"
        recommended_action = "Set CUCP_CLI_PATH env var to the desktop control cli.mjs, or use 'macro native-*' commands which require no external CLI."
      }
      Raw = ""
      Err = "cli.mjs not found"
      FilePath = $null
      CommandId = $invokeId
      ElapsedMs = 0
    }
  }

  if ($CaptureJson) {
    $stdoutFile = Join-Path $Script:CacheDir ("invoke-" + [guid]::NewGuid().ToString("N") + ".json")
    try {
      # Use System.Diagnostics.Process for reliable arg passing + UTF-8 stdout
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = "node"
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
      $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
      $psi.Arguments = ""
      $allArgs = @($Script:CliPath) + $ArgList
      foreach ($a in $allArgs) {
        if ($a -match '[\s"]') {
          $escaped = $a -replace '"', '\"'
          $psi.Arguments += '"' + $escaped + '" '
        } else {
          $psi.Arguments += $a + ' '
        }
      }
      $stderrFile = Join-Path $Script:CacheDir ("invoke-" + [guid]::NewGuid().ToString("N") + ".stderr.txt")
      $proc = Start-Process -FilePath "node" `
        -ArgumentList $psi.Arguments `
        -RedirectStandardOutput $stdoutFile `
        -RedirectStandardError $stderrFile `
        -WindowStyle Hidden `
        -PassThru
      $exited = $proc.WaitForExit($Script:InvokeTimeoutMs)
      if (-not $exited) {
        try { $proc.Kill() } catch { }
        try { [void]$proc.WaitForExit(5000) } catch { }
        $invokeSw.Stop()
        $elapsed = [int]$invokeSw.Elapsed.TotalMilliseconds
        Write-WrapperLog -Message "TIMEOUT [$invokeId] $($ArgList -join ' ') after ${Script:InvokeTimeoutMs}ms (elapsed=${elapsed}ms)"
        $envelope = [pscustomobject]@{
          status = "error"
          error_type = "invoke_timeout"
          command_id = $invokeId
          elapsed_ms = $elapsed
          timeout_ms = $Script:InvokeTimeoutMs
          summary = "CUCP command timed out after ${Script:InvokeTimeoutMs}ms"
          recommended_action = "Increase -InvokeTimeoutMs or run 'cucp macro ensure-helper'. Failing command: $($ArgList -join ' ')"
        }
        return [pscustomobject]@{
          ExitCode = 124
          Json = $envelope
          Raw = if (Test-Path -LiteralPath $stdoutFile) { [System.IO.File]::ReadAllText($stdoutFile, [System.Text.Encoding]::UTF8) } else { "" }
          Err = "CUCP command timed out after ${Script:InvokeTimeoutMs}ms (id=$invokeId, elapsed=${elapsed}ms)"
          FilePath = $stdoutFile
          CommandId = $invokeId
          ElapsedMs = $elapsed
        }
      }
      $proc.WaitForExit()
      $invokeSw.Stop()
      $elapsed = [int]$invokeSw.Elapsed.TotalMilliseconds
      $raw = if (Test-Path -LiteralPath $stdoutFile) { [System.IO.File]::ReadAllText($stdoutFile, [System.Text.Encoding]::UTF8) } else { "" }
      $err = if (Test-Path -LiteralPath $stderrFile) { [System.IO.File]::ReadAllText($stderrFile, [System.Text.Encoding]::UTF8) } else { "" }
      try { $proc.Refresh() } catch { }
      $code = $proc.ExitCode
      if ($null -eq $code -and $raw -and $raw.Trim().Length -gt 0) { $code = 0 }
      $json = $null
      if ($raw -and $raw.Trim().Length -gt 0) {
        try { $json = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $json = $null }
      }
      return [pscustomobject]@{
        ExitCode = $code
        Json = $json
        Raw = $raw
        Err = $err
        FilePath = $stdoutFile
        CommandId = $invokeId
        ElapsedMs = $elapsed
      }
    } catch {
      $invokeSw.Stop()
      return [pscustomobject]@{
        ExitCode = 1
        Json = $null
        Raw = $_.Exception.Message
        Err = ""
        FilePath = $null
        CommandId = $invokeId
        ElapsedMs = [int]$invokeSw.Elapsed.TotalMilliseconds
      }
    }
  } else {
    & node $Script:CliPath @ArgList
    $invokeSw.Stop()
    return [pscustomobject]@{
      ExitCode = $LASTEXITCODE
      Json = $null
      Raw = ""
      FilePath = $null
      CommandId = $invokeId
      ElapsedMs = [int]$invokeSw.Elapsed.TotalMilliseconds
    }
  }
}

# ----- live-control gate ----------------------------------------------------
function Test-LiveControlRequest {
  param([string[]]$ArgList)
  if ($null -eq $ArgList -or $ArgList.Count -lt 1) { return $false }

  if ($ArgList[0] -eq "act") { return $true }
  if ($ArgList.Count -ge 2 -and $ArgList[0] -eq "app" -and $ArgList[1] -eq "switch") { return $true }
  if ($ArgList.Count -ge 2 -and $ArgList[0] -eq "plan" -and $ArgList[1] -eq "run") { return $true }
  if ($ArgList.Count -ge 2 -and $ArgList[0] -eq "scenario" -and $ArgList[1] -eq "run" -and ($ArgList -contains "--execute")) {
    return $true
  }

  if ($ArgList.Count -ge 3 -and $ArgList[0] -eq "desktop" -and $ArgList[1] -eq "benchmark") {
    $op = $ArgList[2]
    $isPreflight = $ArgList -contains "--preflight-only"
    $isVerify = $ArgList -contains "--verify-only"
    $isDry = $ArgList -contains "--dry-run"
    if ($op -eq "runbook") {
      if ($isDry -or $isVerify -or $isPreflight) { return $false }
      if ($ArgList -contains "--allow-live-control") { return $true }
    }
    if (($op -eq "run" -or $op -eq "collect") -and ($ArgList -contains "--live") -and -not $isPreflight) {
      return $true
    }
  }

  if ($ArgList.Count -ge 2 -and $ArgList[0] -eq "l5") {
    $sub = $ArgList[1]
    if ($sub -eq "run") { return $true }
    if (($sub -eq "resume" -or $sub -eq "live-eval") -and ($ArgList -contains "--allow-control")) { return $true }
  }

  return $false
}

function Test-CoordinateMissingObservation {
  param([string[]]$ArgList)
  if ($ArgList.Count -lt 2 -or $ArgList[0] -ne "act") { return $false }
  $coordSubs = @("click", "right-click", "drag", "scroll", "type")
  if (-not ($coordSubs -contains $ArgList[1])) { return $false }
  $hasCoord = ($ArgList -contains "--x") -or ($ArgList -contains "--from-x")
  if (-not $hasCoord) { return $false }
  if ($ArgList -contains "--after") { return $false }
  if ($ArgList -contains "--force") { return $false }
  return $true
}

function Assert-Authorized {
  param([string[]]$ArgList)
  $isLive = Test-LiveControlRequest -ArgList $ArgList
  $missingObs = Test-CoordinateMissingObservation -ArgList $ArgList
  if ($missingObs) {
    Write-Notice -Level "ERROR" -Message "좌표 기반 act 명령은 --after <observation-id>가 필요합니다. 'observe appshot'을 먼저 실행하거나 매크로(click-label 등)를 사용하세요."
    throw "Coordinate-based act command requires --after <observation-id>."
  }
  if ($isLive -and -not $AllowLiveControl) {
    Write-Notice -Level "ERROR" -Message "라이브 데스크톱 조작이 차단되었습니다. 사용자가 명시 허락한 경우만 -AllowLiveControl 와 함께 다시 실행하세요."
    Write-Notice -Level "WARN"  -Message "차단된 명령: $($ArgList -join ' ')"
    throw "Live desktop control blocked. Re-run with -AllowLiveControl after explicit user authorization."
  }
  if ($isLive) {
    Write-Notice -Level "WARN" -Message "라이브 컨트롤 모드: $($ArgList -join ' ')"
  } else {
    Write-Notice -Level "INFO" -Message "관찰/시뮬레이션 모드: $($ArgList -join ' ')"
  }
}

# ----- observation cache ----------------------------------------------------
function Get-CacheKey {
  param([string]$Match)
  $base = if ([string]::IsNullOrWhiteSpace($Match)) { "_full" } else { $Match.ToLowerInvariant() }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($base)
  $hash = [System.Security.Cryptography.MD5]::Create().ComputeHash($bytes)
  return ($hash | ForEach-Object { $_.ToString("x2") }) -join ""
}

function Get-CachedAppshot {
  param([string]$Match, [int]$MaxAgeSeconds)
  if ($MaxAgeSeconds -le 0) { return $null }
  $key = Get-CacheKey -Match $Match
  $cacheFile = Join-Path $Script:CacheDir "appshot-$key.json"
  if (-not (Test-Path -LiteralPath $cacheFile)) { return $null }
  $info = Get-Item -LiteralPath $cacheFile
  $age = (Get-Date) - $info.LastWriteTime
  if ($age.TotalSeconds -gt $MaxAgeSeconds) { return $null }
  try {
    $json = Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    Write-Notice -Level "INFO" -Message "appshot 캐시 적중 (age=$([int]$age.TotalSeconds)s, match='$Match')"
    return [pscustomobject]@{ Json = $json; Path = $cacheFile; FromCache = $true }
  } catch { return $null }
}

function Save-AppshotCache {
  param([string]$Match, [string]$SourceFile)
  if (-not (Test-Path -LiteralPath $SourceFile)) { return }
  $key = Get-CacheKey -Match $Match
  $cacheFile = Join-Path $Script:CacheDir "appshot-$key.json"
  Copy-Item -LiteralPath $SourceFile -Destination $cacheFile -Force
}

function Invoke-Appshot {
  <#
    Captures appshot, returns [pscustomobject]{ Json, Path, ObservationId, FocusedWindow, Items, FusedElements, FromCache }.
    Uses cache if Match given and a fresh capture exists within $CacheSeconds.
  #>
  param(
    [string]$Match,
    [switch]$Semantic = $true,
    [switch]$NoCache,
    [int]$CacheMaxSeconds = $CacheSeconds
  )

  if (-not $NoCache) {
    $cached = Get-CachedAppshot -Match $Match -MaxAgeSeconds $CacheMaxSeconds
    if ($cached) {
      return _Build-AppshotResult -Json $cached.Json -Path $cached.Path -FromCache $true
    }
  }

  $outFile = Join-Path $Script:CacheDir ("appshot-fresh-" + [guid]::NewGuid().ToString("N") + ".json")
  $cucpArgs = @("observe", "appshot")
  if ($Match) { $cucpArgs += @("--match", $Match) }
  if ($Semantic) { $cucpArgs += "--annotate" } else { $cucpArgs += "--no-semantic" }
  $cucpArgs += @("--out", $outFile)

  $r = Invoke-Cucp -ArgList $cucpArgs -CaptureJson
  if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outFile)) {
    Write-Notice -Level "ERROR" -Message "appshot 실패 (exit=$($r.ExitCode))"
    return $null
  }

  $json = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  Save-AppshotCache -Match $Match -SourceFile $outFile
  $result = _Build-AppshotResult -Json $json -Path $outFile -FromCache $false
  $affCount = 0
  if ($result.Affordances) { $affCount = $result.Affordances.Count }
  # Push to working memory
  _Trajectory-Append -Kind "observation" -Payload @{
    observation_id = $result.ObservationId
    focused_window = $result.FocusedWindow
    match = $Match
    affordance_count = $affCount
    from_cache = $false
  }
  return $result
}

function _Build-AppshotResult {
  param($Json, $Path, [bool]$FromCache)

  # The CUCP envelope when written via --out can be either an envelope
  # ({status, artifacts}) or just the appshot artifact. Handle both.
  $appshot = $null
  $fusion = $null

  if ($Json.artifacts) {
    foreach ($a in $Json.artifacts) {
      if ($a.type -eq "desktop_appshot") { $appshot = $a }
      if ($a.type -eq "desktop_observation_fusion") { $fusion = $a }
    }
  }
  if (-not $appshot -and $Json.type -eq "desktop_appshot") { $appshot = $Json }

  $items = @()
  if ($appshot.text.items) { $items = $appshot.text.items }

  $fused = @()
  if ($fusion.fused_elements) { $fused = $fusion.fused_elements }

  # grounded_elements is the affordance pool emitted by observation-fusion.mjs
  # when the host build supports it. If absent, the wrapper falls back to a
  # native UIA tree walk so label grounding still works.
  $grounded = @()
  if ($fusion.grounded_elements) { $grounded = $fusion.grounded_elements }

  if (-not $grounded -or $grounded.Count -eq 0) {
    $grounded = _Get-UIAffordances -FocusedWindow $appshot.focused_window
  }

  # Affordance index: id -> element.
  $affordances = @{}
  foreach ($g in $grounded) {
    if ($g.affordance_id -and $g.rect) { $affordances[$g.affordance_id] = $g }
  }
  foreach ($t in $items) {
    if ($t.affordance_id -and $t.rect -and -not $affordances.ContainsKey($t.affordance_id)) {
      $affordances[$t.affordance_id] = $t
    }
  }

  return [pscustomobject]@{
    Json           = $Json
    Path           = $Path
    FromCache      = $FromCache
    ObservationId  = $appshot.observation_id
    FocusedWindow  = $appshot.focused_window
    ScreenshotPath = $appshot.screenshot_path
    Items          = $items
    FusedElements  = $fused
    Grounded       = $grounded
    Affordances    = $affordances
  }
}

# ----- Win32 window enumeration fallback ----------------------------------
# 헬퍼/CLI snapshot이 비어 돌아올 때 (예: helper가 막 시작했고 캐시가 비어 있을 때,
# CSRSS/UWP shell windows만 잡혀서 사용자 앱이 안 보일 때) 대신 사용할 수 있는
# 결정적 Win32 window enumeration. read-only이고 actuation 절대 안 함.
$Script:_Win32Loaded = $false

function _Ensure-Win32Loaded {
  if ($Script:_Win32Loaded) { return $true }
  try {
    $sig = @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class CucpWin32 {
  public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

  [DllImport("user32.dll")]
  public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

  [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
  public static extern int GetWindowTextLength(IntPtr hWnd);

  [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
  public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

  [DllImport("user32.dll")]
  public static extern bool IsWindowVisible(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool IsIconic(IntPtr hWnd);

  [DllImport("user32.dll", SetLastError = true)]
  public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();

  [DllImport("user32.dll", CharSet = CharSet.Auto)]
  public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

  public class WindowInfo {
    public IntPtr Hwnd;
    public string Title;
    public string ClassName;
    public uint Pid;
    public string ProcessName;
    public bool Visible;
    public bool Minimized;
    public bool Foreground;
    public int X; public int Y; public int Width; public int Height;
  }

  public static List<WindowInfo> EnumerateTopLevel() {
    var result = new List<WindowInfo>();
    IntPtr fg = GetForegroundWindow();
    EnumWindows(delegate (IntPtr hwnd, IntPtr lParam) {
      try {
        bool vis = IsWindowVisible(hwnd);
        // skip non-visible windows for the default fast path. Caller can
        // still enumerate hidden windows separately if needed.
        if (!vis) return true;
        int len = GetWindowTextLength(hwnd);
        if (len <= 0) return true;
        var sb = new StringBuilder(len + 4);
        GetWindowText(hwnd, sb, sb.Capacity);
        var title = sb.ToString();
        if (string.IsNullOrWhiteSpace(title)) return true;
        var cb = new StringBuilder(256);
        GetClassName(hwnd, cb, cb.Capacity);
        var cls = cb.ToString();
        // skip well-known shell/system windows that pollute the list.
        if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd" ||
            cls == "Shell_SecondaryTrayWnd" || cls == "TaskListThumbnailWnd" ||
            cls == "ApplicationFrameWindow" && (title == "Settings" || title == "Microsoft Store") == false) {
          // ApplicationFrameWindow는 UWP 컨테이너인데 진짜 사용자 창인 경우가 많아서
          // title 기준으로만 제외하지 않음. Progman/WorkerW/Shell_TrayWnd만 hard skip.
          if (cls == "Progman" || cls == "WorkerW" || cls == "Shell_TrayWnd" || cls == "Shell_SecondaryTrayWnd" || cls == "TaskListThumbnailWnd") {
            return true;
          }
        }
        uint pid; GetWindowThreadProcessId(hwnd, out pid);
        string pname = "";
        try { pname = Process.GetProcessById((int)pid).ProcessName; } catch { }
        RECT r; GetWindowRect(hwnd, out r);
        var info = new WindowInfo {
          Hwnd = hwnd,
          Title = title,
          ClassName = cls,
          Pid = pid,
          ProcessName = pname,
          Visible = vis,
          Minimized = IsIconic(hwnd),
          Foreground = (hwnd == fg),
          X = r.Left, Y = r.Top, Width = r.Right - r.Left, Height = r.Bottom - r.Top
        };
        result.Add(info);
      } catch { }
      return true;
    }, IntPtr.Zero);
    return result;
  }
}
"@
    Add-Type -TypeDefinition $sig -Language CSharp -ErrorAction Stop
    $Script:_Win32Loaded = $true
    return $true
  } catch {
    Write-WrapperLog -Message "Win32 enumerate load failed: $($_.Exception.Message)"
    return $false
  }
}

function _Enumerate-Win32Windows {
  <#
    Returns an array of objects with: hwnd, title, class, pid, process, visible,
    minimized, foreground, rect{x,y,width,height}. Optional Match filters by
    case-insensitive substring of title or process.
  #>
  param([string]$Match)
  if (-not (_Ensure-Win32Loaded)) { return @() }
  try {
    $list = [CucpWin32]::EnumerateTopLevel()
    $out = New-Object System.Collections.ArrayList
    foreach ($w in $list) {
      if ($Match) {
        $needle = $Match.ToLowerInvariant()
        $tt = if ($w.Title) { $w.Title.ToLowerInvariant() } else { "" }
        $pp = if ($w.ProcessName) { $w.ProcessName.ToLowerInvariant() } else { "" }
        if ($tt.IndexOf($needle) -lt 0 -and $pp.IndexOf($needle) -lt 0) { continue }
      }
      [void]$out.Add([pscustomobject]@{
        hwnd = [int64]$w.Hwnd
        title = $w.Title
        class = $w.ClassName
        pid = [int]$w.Pid
        process = $w.ProcessName
        visible = $w.Visible
        minimized = $w.Minimized
        foreground = $w.Foreground
        rect = [pscustomobject]@{
          x = $w.X; y = $w.Y; width = $w.Width; height = $w.Height
        }
      })
    }
    return $out.ToArray()
  } catch {
    Write-WrapperLog -Message "Win32 enumerate failed: $($_.Exception.Message)"
    return @()
  }
}

# ----- native UIA fallback --------------------------------------------------
$Script:_UIALoaded = $false

function _Ensure-UIALoaded {
  if ($Script:_UIALoaded) { return $true }
  try {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    $Script:_UIALoaded = $true
    return $true
  } catch {
    Write-WrapperLog -Message "UIA load failed: $($_.Exception.Message)"
    return $false
  }
}

function _Slug {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "unknown" }
  $s = $Value.ToLowerInvariant()
  $s = ($s -replace '[^a-z0-9가-힣]+', '-').Trim('-')
  if ([string]::IsNullOrEmpty($s)) { return "unknown" }
  if ($s.Length -gt 32) { return $s.Substring(0, 32) }
  return $s
}

function _Get-UIAffordances {
  <#
    Walks the UIA tree under the focused window (or root if no focus) and
    returns a list of grounded element objects compatible with the
    grounded_elements schema produced by observation-fusion.mjs.
    Roles included: button, edit, hyperlink, menuitem, tabitem, listitem,
    treeitem, checkbox, radiobutton, combobox, document, text.

    SMALL ICON FRIENDLY (sprint v4):
    - Includes elements down to 6x6px (toolbar icons commonly 16-24px).
    - Synonym labels mined from: Name, AutomationId, HelpText (tooltip),
      AccessKey, ItemStatus, IsKeyboardFocusable hint.
    - Per-element confidence is high when AutomationId+Name agree, medium
      when only Name, low when only AutomationId/HelpText.
    - Smaller leaf elements are preferred when nested (icon inside group).
  #>
  param([string]$FocusedWindow, [int]$MaxElements = 400, [int]$MinSize = 6)

  if (-not (_Ensure-UIALoaded)) { return @() }

  try {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    if (-not $root) { return @() }

    # Find target window: prefer focused window match, else root scan.
    $target = $root
    if ($FocusedWindow) {
      $cond = New-Object System.Windows.Automation.PropertyCondition `
        ([System.Windows.Automation.AutomationElement]::ControlTypeProperty),
         ([System.Windows.Automation.ControlType]::Window)
      $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
      $needle = $FocusedWindow.ToLowerInvariant()
      foreach ($w in $windows) {
        try {
          $name = $w.Current.Name
          if ($name -and $name.ToLowerInvariant().Contains($needle.Substring(0, [Math]::Min($needle.Length, 16)))) {
            $target = $w
            break
          }
        } catch { }
      }
    }

    # Useful control types for label grounding (Image and Pane added so we
    # can resolve toolbar icons and embedded canvases).
    $typeNames = @(
      "Button","Edit","Hyperlink","MenuItem","TabItem","ListItem",
      "TreeItem","CheckBox","RadioButton","ComboBox","Document","Text",
      "Header","SplitButton","Group","Image","ToolBar","Pane"
    )

    $results = New-Object System.Collections.Generic.List[object]
    $orCond = $null
    foreach ($tn in $typeNames) {
      $ct = [System.Windows.Automation.ControlType]::$tn
      if (-not $ct) { continue }
      $c = New-Object System.Windows.Automation.PropertyCondition `
        ([System.Windows.Automation.AutomationElement]::ControlTypeProperty), $ct
      if (-not $orCond) { $orCond = $c }
      else { $orCond = New-Object System.Windows.Automation.OrCondition $orCond, $c }
    }
    if (-not $orCond) { return @() }

    $elements = $target.FindAll([System.Windows.Automation.TreeScope]::Descendants, $orCond)
    $count = 0
    foreach ($el in $elements) {
      if ($count -ge $MaxElements) { break }
      try {
        $cur = $el.Current
        $rect = $cur.BoundingRectangle
        if ($rect.IsEmpty) { continue }
        # Accept very small icons (down to MinSize px). Reject only zero-area.
        if ($rect.Width -lt $MinSize -or $rect.Height -lt $MinSize) { continue }

        # Mine label synonyms from multiple UIA properties so small icons
        # without visible text still resolve via tooltip / AutomationId.
        $name = ""; try { $name = "$($cur.Name)" } catch { }
        $autoId = ""; try { $autoId = "$($cur.AutomationId)" } catch { }
        $help = ""; try { $help = "$($cur.HelpText)" } catch { }
        $accessKey = ""; try { $accessKey = "$($cur.AccessKey)" } catch { }
        $status = ""; try { $status = "$($cur.ItemStatus)" } catch { }
        $clazz = ""; try { $clazz = "$($cur.ClassName)" } catch { }

        $synonyms = New-Object System.Collections.Generic.HashSet[string]
        foreach ($s in @($name, $autoId, $help, $accessKey, $status)) {
          if (-not [string]::IsNullOrWhiteSpace($s)) { [void]$synonyms.Add($s.Trim()) }
        }
        if ($synonyms.Count -eq 0) { continue }

        # Primary text = Name when present, else AutomationId, else HelpText.
        $text = if (-not [string]::IsNullOrWhiteSpace($name)) { $name }
                elseif (-not [string]::IsNullOrWhiteSpace($autoId)) { $autoId }
                else { $help }
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $role = ""; try { $role = $cur.LocalizedControlType } catch { }
        if ([string]::IsNullOrWhiteSpace($role)) {
          try { $role = $cur.ControlType.ProgrammaticName } catch { }
        }

        # Derived attributes that downstream selector ranking can use.
        $isOffscreen = $false; try { $isOffscreen = [bool]$cur.IsOffscreen } catch { }
        $isEnabled = $true;   try { $isEnabled   = [bool]$cur.IsEnabled }   catch { }
        $isFocusable = $false; try { $isFocusable = [bool]$cur.IsKeyboardFocusable } catch { }
        if ($isOffscreen) { continue }   # never click invisible items

        # Confidence boost when multiple UIA properties agree on the label.
        $conf = "medium"
        $agree = 0
        if (-not [string]::IsNullOrWhiteSpace($name))   { $agree++ }
        if (-not [string]::IsNullOrWhiteSpace($autoId)) { $agree++ }
        if (-not [string]::IsNullOrWhiteSpace($help))   { $agree++ }
        if ($agree -ge 2) { $conf = "high" }
        elseif ($agree -eq 0) { $conf = "low" }

        $window = $FocusedWindow
        if (-not $window) {
          try { $window = $cur.Name } catch { }
        }

        $rectObj = [pscustomobject]@{
          x = [int]$rect.X
          y = [int]$rect.Y
          width = [int]$rect.Width
          height = [int]$rect.Height
        }
        $area = $rectObj.width * $rectObj.height
        $isSmall = ($rectObj.width -le 32 -and $rectObj.height -le 32)

        $w = (_Slug $window).Substring(0, [Math]::Min(24, (_Slug $window).Length))
        $r = (_Slug $role).Substring(0, [Math]::Min(16, (_Slug $role).Length))
        $t = (_Slug $text)
        $rk = "$($rectObj.x)-$($rectObj.y)-$($rectObj.width)-$($rectObj.height)"
        $afid = "aff:${w}:${r}:${t}:${rk}:uia"

        $results.Add([pscustomobject]@{
          affordance_id = $afid
          stable_id     = "window:${w}|role:${r}|text:${t}|rect:$($rectObj.x),$($rectObj.y),$($rectObj.width),$($rectObj.height)"
          text          = $text
          synonyms      = @($synonyms)
          role          = $role
          class_name    = $clazz
          window        = $window
          rect          = $rectObj
          area          = $area
          small_icon    = $isSmall
          enabled       = $isEnabled
          focusable     = $isFocusable
          access_key    = $accessKey
          tooltip       = $help
          item_status   = $status
          sources       = @("uia")
          confidence    = $conf
          source_ids    = [pscustomobject]@{ uia = $autoId }
        }) | Out-Null
        $count++
      } catch { continue }
    }
    Write-WrapperLog -Message ("UIA fallback collected $count affordances under window '" + $FocusedWindow + "' (small_icons included)")
    return $results.ToArray()
  } catch {
    Write-WrapperLog -Message "UIA fallback failed: $($_.Exception.Message)"
    return @()
  }
}

# ----- label grounding ------------------------------------------------------
function Find-Element {
  <#
    Search appshot for an element matching label/window/role.
    Searches in priority: affordances (grounded) -> fused_elements -> text items.
    Returns the matched element (with rect) or $null.
  #>
  param(
    [Parameter(Mandatory)] $Appshot,
    [Parameter(Mandatory)] [string]$Label,
    [string]$Window,
    [string]$Role,
    [switch]$Exact
  )

  $needle = $Label.ToLowerInvariant().Trim()

  # Priority 1: grounded_elements (single-source allowed, has affordance_id)
  $pool1 = @()
  if ($Appshot.Grounded) { $pool1 = $Appshot.Grounded }
  # Priority 2: fused_elements (multi-source)
  $pool2 = @()
  if ($Appshot.FusedElements) { $pool2 = $Appshot.FusedElements }
  # Priority 3: text items that have rect (last resort)
  $pool3 = @()
  if ($Appshot.Items) {
    foreach ($it in $Appshot.Items) {
      if ($it.rect) { $pool3 += $it }
    }
  }

  function _ScorePool { param($Pool, $Tier)
    $hits = @()
    foreach ($el in $Pool) {
      if (-not $el.text -or -not $el.rect) { continue }
      if ($Window -and $el.window -and ($el.window.ToLowerInvariant() -notmatch [regex]::Escape($Window.ToLowerInvariant()))) { continue }
      if ($Role -and $el.role -and ($el.role.ToLowerInvariant() -ne $Role.ToLowerInvariant())) { continue }

      # Mine all label sources: primary text + synonyms (Name/AutomationId/
      # HelpText/AccessKey/ItemStatus collected by _Get-UIAffordances).
      $haystacks = New-Object System.Collections.Generic.List[string]
      [void]$haystacks.Add($el.text.ToString().ToLowerInvariant())
      if ($el.synonyms) {
        foreach ($s in $el.synonyms) {
          if (-not [string]::IsNullOrWhiteSpace($s)) {
            $sl = $s.ToString().ToLowerInvariant()
            if (-not $haystacks.Contains($sl)) { [void]$haystacks.Add($sl) }
          }
        }
      }
      if ($el.tooltip) {
        $tl = $el.tooltip.ToString().ToLowerInvariant()
        if (-not $haystacks.Contains($tl)) { [void]$haystacks.Add($tl) }
      }

      $score = 0
      foreach ($hay in $haystacks) {
        $local = 0
        if ($script:_findExactOnly) {
          if ($hay -eq $needle) { $local = 100 }
        } else {
          if ($hay -eq $needle) { $local = 100 }
          elseif ($hay -match [regex]::Escape($needle)) { $local = 60 + (40 - [Math]::Min(40, $hay.Length - $needle.Length)) }
          elseif ($needle.Length -ge 3 -and $hay.Length -ge 3 -and ($hay.IndexOf($needle.Substring(0, [Math]::Min(3, $needle.Length))) -ge 0)) { $local = 20 }
        }
        if ($local -gt $score) { $score = $local }
      }
      if ($el.confidence) {
        if ($el.confidence -is [double] -or $el.confidence -is [int]) {
          $score += [int]([double]$el.confidence * 5)
        } elseif ($el.confidence -is [string]) {
          switch ($el.confidence.ToLowerInvariant()) {
            "high"   { $score += 4 }
            "medium" { $score += 2 }
            "low"    { $score += 1 }
            default  { }
          }
        }
      }
      # Small-icon bonus: small leaf elements are usually more specific
      # than the large group/pane that contains them. +3 nudges them
      # ahead in ambiguous cases.
      if ($el.small_icon) { $score += 3 }
      # Disabled elements are never clickable; deprioritize but don't
      # filter (caller may want to know they exist).
      if ($el.PSObject.Properties.Name -contains "enabled" -and -not $el.enabled) { $score -= 5 }

      if ($score -gt 0) {
        $hits += [pscustomobject]@{ Element = $el; Score = $score; Tier = $Tier }
      }
    }
    return $hits
  }

  $script:_findExactOnly = [bool]$Exact
  $allHits = @()
  $allHits += _ScorePool -Pool $pool1 -Tier 1
  $allHits += _ScorePool -Pool $pool2 -Tier 2
  $allHits += _ScorePool -Pool $pool3 -Tier 3

  if ($allHits.Count -eq 0) { return $null }
  $best = $allHits | Sort-Object @{Expression="Tier"; Ascending=$true}, @{Expression="Score"; Descending=$true} | Select-Object -First 1
  return $best.Element
}

function Find-AffordanceById {
  param([Parameter(Mandatory)] $Appshot, [Parameter(Mandatory)] [string]$Id)
  if ($Appshot.Affordances -and $Appshot.Affordances.ContainsKey($Id)) {
    return $Appshot.Affordances[$Id]
  }
  return $null
}

function Get-ElementCenter {
  param($Element)
  if (-not $Element -or -not $Element.rect) { return $null }
  $cx = [int]($Element.rect.x + ($Element.rect.width / 2))
  $cy = [int]($Element.rect.y + ($Element.rect.height / 2))
  return [pscustomobject]@{ X = $cx; Y = $cy }
}

# ----- macros ---------------------------------------------------------------
function Invoke-Macro {
  param([string[]]$ArgList)

  $sub = $ArgList[1]
  $rest = if ($ArgList.Count -gt 2) { $ArgList[2..($ArgList.Count-1)] } else { @() }

  switch ($sub) {
    "click-label"   { return Invoke-MacroClickLabel -Rest $rest }
    "double-click-label" { return Invoke-MacroClickLabel -Rest $rest -Double }
    "right-click-label"  { return Invoke-MacroClickLabel -Rest $rest -RightClick }
    "click-id"      { return Invoke-MacroClickId -Rest $rest }
    "click-point"   { return Invoke-MacroClickPoint -Rest $rest }
    "fill-label"    { return Invoke-MacroFillLabel -Rest $rest }
    "focus-window"  { return Invoke-MacroFocusWindow -Rest $rest }
    "wait-window"   { return Invoke-MacroWaitWindow -Rest $rest }
    "wait-label"    { return Invoke-MacroWaitLabel -Rest $rest }
    "find-label"    { return Invoke-MacroFindLabel -Rest $rest }
    "list-affordances" { return Invoke-MacroListAffordances -Rest $rest }
    "shortcut"      { return Invoke-MacroShortcut -Rest $rest }
    "goal"          { return Invoke-MacroGoal -Rest $rest }
    "session"       { return Invoke-MacroSession -Rest $rest }
    "self-test"     { return Invoke-MacroSelfTest -Rest $rest }
    "trajectory"    { return Invoke-MacroTrajectory -Rest $rest }
    "ensure-helper" { return Invoke-MacroEnsureHelper -Rest $rest }
    "vision-find"   { return Invoke-MacroVisionFind -Rest $rest }
    "vision-click"  { return Invoke-MacroVisionClick -Rest $rest }
    "metrics"       { return Invoke-MacroMetrics -Rest $rest }
    "perf"          { return Invoke-MacroPerf -Rest $rest }
    "health-detail" { return Invoke-MacroHealthDetail -Rest $rest }
    "health-quick"  { return Invoke-MacroHealthQuick -Rest $rest }
    "windows"       { return Invoke-MacroWindows -Rest $rest }
    "focus-verify"  { return Invoke-MacroFocusVerify -Rest $rest }
    "log-tail"      { return Invoke-MacroLogTail -Rest $rest }
    "diagnose-lag"  { return Invoke-MacroDiagnoseLag -Rest $rest }
    "cleanup"       { return Invoke-MacroCleanup -Rest $rest }
    "icon-find"     { return Invoke-MacroIconFind -Rest $rest }
    "icon-click"    { return Invoke-MacroIconClick -Rest $rest }
    "vision-click-precise" { return Invoke-MacroVisionClickPrecise -Rest $rest }
    "screenshot"    { return Invoke-MacroScreenshot -Rest $rest }
    # ── Native helper 직통 (외부 helper 의존 없음) ─────────────────────────
    "native-health"     { return Invoke-MacroNativeHealth -Rest $rest }
    "native-windows"    { return Invoke-MacroNativeWindows -Rest $rest }
    "native-screenshot" { return Invoke-MacroNativeScreenshot -Rest $rest }
    "click-point"       { return Invoke-MacroClickPoint -Rest $rest }
    "type-native"       { return Invoke-MacroTypeNative -Rest $rest }
    "shortcut-native"   { return Invoke-MacroShortcutNative -Rest $rest }
    "uia-click-label"   { return Invoke-MacroUiaClickLabel -Rest $rest }
    # ── UIA Pattern 직접 호출 (마우스 안 움직임) ──────────────────────────
    "uia-invoke"        { return Invoke-MacroUiaInvoke -Rest $rest }
    "uia-set-value"     { return Invoke-MacroUiaSetValue -Rest $rest }
    "uia-toggle"        { return Invoke-MacroUiaToggle -Rest $rest }
    "smart-click"       { return Invoke-MacroSmartClick -Rest $rest }
    "watch"             { return Invoke-MacroWatch -Rest $rest }
    # ── OCR (Windows.Media.Ocr) — 브라우저 캔버스 / 이미지 표면용 ──────────
    "ocr-screen"        { return Invoke-MacroOcrScreen -Rest $rest }
    "ocr-image"         { return Invoke-MacroOcrImage -Rest $rest }
    "ocr-find-text"     { return Invoke-MacroOcrFindText -Rest $rest }
    "ocr-click"         { return Invoke-MacroOcrClick -Rest $rest }
    # ── v0.9.0 OCR+UIA fusion + screenshot diff ─────────────────────────────
    "ocr-uia-fuse"      { return Invoke-MacroOcrUiaFuse -Rest $rest }
    "screenshot-diff"   { return Invoke-MacroScreenshotDiff -Rest $rest }
    "click-and-verify-screen" { return Invoke-MacroClickAndVerifyScreen -Rest $rest }
    # ── v1.0.0 OCR+UIA invoke (Name 없어도 invoke) ───────────────────────────
    "ocr-uia-invoke"    { return Invoke-MacroOcrUiaInvoke -Rest $rest }
    # ── v1.1.0 smart-click history learning ──────────────────────────────────
    "history"           { return Invoke-MacroHistory -Rest $rest }
    # ── v1.2.0 hit-test 가드 + safe-type ─────────────────────────────────────
    "hit-test"          { return Invoke-MacroHitTest -Rest $rest }
    "safe-type"         { return Invoke-MacroSafeType -Rest $rest }
    # ── v1.3.0 Electron CDP (DOM 직접 제어) ─────────────────────────────────
    "cdp-detect"        { return Invoke-MacroCdpDetect -Rest $rest }
    "cdp-eval"          { return Invoke-MacroCdpEval -Rest $rest }
    "cdp-type"          { return Invoke-MacroCdpType -Rest $rest }
    "cdp-click"         { return Invoke-MacroCdpClick -Rest $rest }
    # ── Windows-MCP 동등 기능 ──────────────────────────────────────────────
    "clipboard"     { return Invoke-MacroClipboard -Rest $rest }
    "process"       { return Invoke-MacroProcess -Rest $rest }
    "registry"      { return Invoke-MacroRegistry -Rest $rest }
    "notify"        { return Invoke-MacroNotify -Rest $rest }
    "multi-select"  { return Invoke-MacroMultiSelect -Rest $rest }
    "multi-edit"    { return Invoke-MacroMultiEdit -Rest $rest }
    "scrape"        { return Invoke-MacroScrape -Rest $rest }
    "dom-snapshot"  { return Invoke-MacroDomSnapshot -Rest $rest }
    "app-launch"    { return Invoke-MacroAppLaunch -Rest $rest }
    "app-close"     { return Invoke-MacroAppClose -Rest $rest }
    "with-app"      { return Invoke-MacroWithApp -Rest $rest }
    "click-and-verify" { return Invoke-MacroClickAndVerify -Rest $rest }
    "auto-do"       { return Invoke-MacroAutoDo -Rest $rest }
    default {
      Write-Notice -Level "ERROR" -Message "알 수 없는 매크로: $sub. 사용 가능: click-label, double-click-label, right-click-label, click-id, click-point, fill-label, focus-window, focus-verify, wait-window, wait-label, find-label, list-affordances, shortcut, goal, session, self-test, trajectory, ensure-helper, vision-find, vision-click, vision-click-precise, icon-find, icon-click, screenshot, windows, log-tail, diagnose-lag, cleanup, clipboard, process, registry, notify, multi-select, multi-edit, scrape, dom-snapshot, metrics, perf, health-detail, health-quick, app-launch, app-close, with-app, click-and-verify, auto-do, native-health, native-windows, native-screenshot, type-native, shortcut-native, uia-click-label, uia-invoke, uia-set-value, uia-toggle, smart-click, watch, ocr-screen, ocr-image, ocr-find-text, ocr-click, ocr-uia-fuse, screenshot-diff, click-and-verify-screen, ocr-uia-invoke, history, hit-test, safe-type, cdp-detect, cdp-eval, cdp-type, cdp-click"
      throw "Unknown macro: $sub"
    }
  }
}

function _Read-OptValue { param([string[]]$Rest, [string]$Name)
  for ($i = 0; $i -lt $Rest.Count; $i++) {
    if ($Rest[$i] -eq $Name -and ($i + 1) -lt $Rest.Count) { return $Rest[$i+1] }
  }
  return $null
}

function _Read-Switch { param([string[]]$Rest, [string]$Name)
  return ($Rest -contains $Name)
}

function _Ensure-NativeDesktopTypes {
  if ("CUCP.NativeDesktop" -as [type]) { return }
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type @"
using System;
using System.Runtime.InteropServices;

namespace CUCP {
  public static class NativeDesktop {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
  }
}
"@
}

function _Native-FindWindow {
  param([string]$Name)
  if (-not $Name) { return $null }
  $candidates = @(_Enumerate-Win32Windows -Match $Name | Where-Object { $_.visible })
  if ($candidates.Count -eq 0) { return $null }
  $needle = $Name.ToLowerInvariant()
  $ranked = $candidates | Sort-Object `
    @{ Expression = { if ($_.title -and $_.title.ToLowerInvariant() -eq $needle) { 0 } elseif ($_.process -and $_.process.ToLowerInvariant() -eq $needle) { 1 } else { 2 } } }, `
    @{ Expression = { if ($_.minimized) { 1 } else { 0 } } }
  return ($ranked | Select-Object -First 1)
}

function _Native-FocusWindow {
  param([string]$Name)
  _Ensure-NativeDesktopTypes
  $win = _Native-FindWindow -Name $Name
  if (-not $win) { return $null }
  $hwnd = [IntPtr]([int64]$win.hwnd)
  if ([CUCP.NativeDesktop]::IsIconic($hwnd)) {
    [CUCP.NativeDesktop]::ShowWindowAsync($hwnd, 9) | Out-Null
    Start-Sleep -Milliseconds 150
  } else {
    [CUCP.NativeDesktop]::ShowWindowAsync($hwnd, 5) | Out-Null
  }
  [CUCP.NativeDesktop]::BringWindowToTop($hwnd) | Out-Null
  [CUCP.NativeDesktop]::SetForegroundWindow($hwnd) | Out-Null
  Start-Sleep -Milliseconds 250
  return $win
}

function _Native-SendShortcut {
  param([string]$Keys)
  if (-not $Keys) { throw "shortcut keys required" }
  _Ensure-NativeDesktopTypes
  $parts = @($Keys.ToLowerInvariant().Split("+") | Where-Object { $_ -ne "" })
  if ($parts.Count -eq 0) { throw "shortcut keys required" }
  $mods = ""
  $key = $parts[-1]
  if ($parts -contains "ctrl" -or $parts -contains "control") { $mods += "^" }
  if ($parts -contains "shift") { $mods += "+" }
  if ($parts -contains "alt") { $mods += "%" }
  $named = @{
    "enter"="{ENTER}"; "return"="{ENTER}"; "tab"="{TAB}"; "esc"="{ESC}"; "escape"="{ESC}";
    "space"=" "; "backspace"="{BACKSPACE}"; "delete"="{DELETE}"; "del"="{DELETE}";
    "up"="{UP}"; "down"="{DOWN}"; "left"="{LEFT}"; "right"="{RIGHT}";
    "home"="{HOME}"; "end"="{END}"; "pgup"="{PGUP}"; "pageup"="{PGUP}";
    "pgdn"="{PGDN}"; "pagedown"="{PGDN}"
  }
  if ($key -match '^f([1-9]|1[0-2])$') { $sendKey = "{" + $key.ToUpperInvariant() + "}" }
  elseif ($named.ContainsKey($key)) { $sendKey = $named[$key] }
  elseif ($key.Length -eq 1) { $sendKey = $key }
  else { $sendKey = "{" + $key.ToUpperInvariant() + "}" }
  [System.Windows.Forms.SendKeys]::SendWait($mods + $sendKey)
}

function _Native-SetClipboard {
  param([string]$Text)
  _Ensure-NativeDesktopTypes
  [System.Windows.Forms.Clipboard]::SetText($Text)
}

function _Native-ClickPoint {
  param([int]$X, [int]$Y, [string]$Button = "left", [int]$Clicks = 1)
  _Ensure-NativeDesktopTypes
  [CUCP.NativeDesktop]::SetCursorPos($X, $Y) | Out-Null
  Start-Sleep -Milliseconds 80
  $down = 0x0002; $up = 0x0004
  if ($Button -eq "right") { $down = 0x0008; $up = 0x0010 }
  elseif ($Button -eq "middle") { $down = 0x0020; $up = 0x0040 }
  for ($i = 0; $i -lt [Math]::Max(1, $Clicks); $i++) {
    [CUCP.NativeDesktop]::mouse_event($down,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [CUCP.NativeDesktop]::mouse_event($up,0,0,0,[UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
  }
}

function _Native-Screenshot {
  param([string]$OutPath, [string]$Window)
  if (-not $OutPath) { throw "screenshot requires --out" }
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  $rect = $null
  if ($Window) {
    $win = _Native-FindWindow -Name $Window
    if (-not $win) { throw "window not found for screenshot: $Window" }
    $rect = $win.rect
  } else {
    $rect = [pscustomobject]@{ x = 0; y = 0; width = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width; height = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height }
  }
  $x = [int]$rect.x; $y = [int]$rect.y; $w = [int]$rect.width; $h = [int]$rect.height
  if ($x -lt 0) { $w += $x; $x = 0 }
  if ($y -lt 0) { $h += $y; $y = 0 }
  if ($w -le 0 -or $h -le 0) { throw "invalid screenshot rect" }
  $dir = Split-Path -Parent $OutPath
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $bmp = New-Object System.Drawing.Bitmap($w, $h)
  $gfx = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $gfx.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    $gfx.Dispose()
    $bmp.Dispose()
  }
  return [pscustomobject]@{ path = $OutPath; x = $x; y = $y; width = $w; height = $h; window = $Window }
}

function Invoke-MacroScreenshot {
  param([string[]]$Rest)
  $out = _Read-OptValue -Rest $Rest -Name "--out"
  $window = _Read-OptValue -Rest $Rest -Name "--window"
  if (-not $out) { throw "macro screenshot requires --out" }
  $shot = _Native-Screenshot -OutPath $out -Window $window
  _Trajectory-Append -Kind "screenshot" -Payload @{ path = $shot.path; window = $window; source = "native"; width = $shot.width; height = $shot.height }
  if ($Brief) { [Console]::Out.WriteLine(("ok screenshot '{0}' {1}x{2} source=native" -f $shot.path, $shot.width, $shot.height)) }
  else { [Console]::Out.WriteLine(($shot | ConvertTo-Json -Depth 4)) }
  return 0
}

function Invoke-MacroListAffordances {
  # macro list-affordances -- read-only enumeration of clickable/labeled elements.
  # Backwards compatible top-level fields kept: status, observation_id,
  # focused_window, from_cache, affordance_count, affordances.
  # NEW: also returns a cucp.observation/v1 envelope under `_envelope`
  # when --json-only is used so newer agents can rely on the unified shape.
  param([string[]]$Rest)
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $window = _Read-OptValue -Rest $Rest -Name "--window"
  $limit = [int](_Read-OptValue -Rest $Rest -Name "--limit")
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  if ($limit -le 0) { $limit = 50 }
  if (-not $match) { $match = $window }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $shot = Invoke-Appshot -Match $match -Semantic:$true
  if (-not $shot) {
    $sw.Stop()
    if ($Brief -and -not $jsonOnly) {
      [Console]::Out.WriteLine("partial list-affordances appshot_failed match='$match'")
    } else {
      $err = _New-ObservationEnvelope `
        -Kind "list-affordances" -Status "partial" `
        -ElapsedMs ([int]$sw.Elapsed.TotalMilliseconds) `
        -Sources @("appshot") `
        -Data ([pscustomobject]@{ match = $match; window = $window; limit = $limit }) `
        -RecoverableErrors @([pscustomobject]@{
          code = "appshot_failed"
          message = "observe appshot returned no usable artifact"
          recommended_action = "Run 'cucp macro ensure-helper' or verify '$match' exists with 'cucp macro windows'."
        })
      [Console]::Out.WriteLine(($err | ConvertTo-Json -Depth 8))
    }
    return 2
  }

  $items = @()
  if ($shot.Grounded) {
    foreach ($g in $shot.Grounded) {
      if (-not $g.text -or -not $g.rect) { continue }
      if ($Window -and $g.window -and ($g.window.ToLowerInvariant() -notmatch [regex]::Escape($Window.ToLowerInvariant()))) { continue }
      $center = Get-ElementCenter -Element $g
      $items += [pscustomobject]@{
        affordance_id = $g.affordance_id
        text = $g.text
        role = $g.role
        window = $g.window
        center = $center
        confidence = $g.confidence
        sources = $g.sources
      }
      if ($items.Count -ge $limit) { break }
    }
  }
  $sw.Stop()
  $elapsed = [int]$sw.Elapsed.TotalMilliseconds

  $sourceTags = @("appshot")
  if ($shot.Grounded -and $shot.Grounded.Count -gt 0) { $sourceTags += "uia" }
  if ($shot.FromCache) { $sourceTags += "cache" }

  $cacheMeta = [pscustomobject]@{
    hit = [bool]$shot.FromCache
    age_ms = $null
    max_age_ms = ($CacheSeconds * 1000)
    key = "appshot::match=$match"
    reason = if ($shot.FromCache) { "cache_fresh" } else { "live_capture" }
  }

  $foreground = $null
  if ($shot.FocusedWindow) { $foreground = [pscustomobject]@{ title = $shot.FocusedWindow } }

  # Backwards-compatible top-level shape (legacy callers like xg5000-evidence).
  $payload = [pscustomobject]@{
    status = "ok"
    schema = "cucp.list-affordances/v2"
    observation_id = $shot.ObservationId
    focused_window = $shot.FocusedWindow
    from_cache = [bool]$shot.FromCache
    affordance_count = $items.Count
    affordances = $items
    elapsed_ms = $elapsed
    sources = $sourceTags
    cache = $cacheMeta
    _envelope = (_New-ObservationEnvelope `
      -Kind "list-affordances" -Status "ok" `
      -ElapsedMs $elapsed `
      -Sources $sourceTags `
      -ObservationId $shot.ObservationId `
      -Foreground $foreground `
      -Data ([pscustomobject]@{
        affordance_count = $items.Count
        match = $match
        window = $window
        limit = $limit
        affordances = $items
      }) `
      -Cache $cacheMeta `
      -Confidence "high")
  }
  if ($Brief -and -not $jsonOnly) {
    [Console]::Out.WriteLine("ok list-affordances count=$($items.Count) win='$($shot.FocusedWindow)' cached=$([bool]$shot.FromCache) elapsed_ms=$elapsed")
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 8))
  }
  return 0
}

function Invoke-MacroClickId {
  param([string[]]$Rest, [switch]$Double, [switch]$RightClick)
  $id = _Read-OptValue -Rest $Rest -Name "--id"
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $window = _Read-OptValue -Rest $Rest -Name "--window"
  if (-not $id) { throw "macro click-id requires --id" }
  if (-not $AllowLiveControl) { throw "macro click-id requires -AllowLiveControl" }
  if (-not $match) { $match = $window }

  $shot = Invoke-Appshot -Match $match -Semantic:$true -NoCache
  if (-not $shot) { throw "appshot failed" }
  $el = Find-AffordanceById -Appshot $shot -Id $id
  if (-not $el) {
    Write-Notice -Level "ERROR" -Message "affordance_id를 찾지 못했습니다: '$id'. macro list-affordances로 현재 목록 확인하세요."
    throw "affordance_id not found: $id"
  }
  $center = Get-ElementCenter -Element $el
  $cucpArgs = @("act", "click", "--x", "$($center.X)", "--y", "$($center.Y)", "--after", $shot.ObservationId)
  if ($el.window) { $cucpArgs += @("--target-window", $el.window) }
  $r = Invoke-Cucp -ArgList $cucpArgs
  if ($Brief) {
    if ($r.ExitCode -eq 0) { [Console]::Out.WriteLine("ok click-id '$id' @($($center.X),$($center.Y))") }
    else { [Console]::Out.WriteLine("err click-id '$id' exit=$($r.ExitCode)") }
  }
  return $r.ExitCode
}

function Invoke-MacroClickPoint {
  param([string[]]$Rest)
  $x = [int](_Read-OptValue -Rest $Rest -Name "--x")
  $y = [int](_Read-OptValue -Rest $Rest -Name "--y")
  $button = _Read-OptValue -Rest $Rest -Name "--button"
  $clicks = [int](_Read-OptValue -Rest $Rest -Name "--clicks")
  if ($x -le 0 -or $y -le 0) { throw "macro click-point requires --x and --y" }
  if (-not $AllowLiveControl) { throw "macro click-point requires -AllowLiveControl" }
  if (-not $button) { $button = "left" }
  if ($clicks -le 0) { $clicks = 1 }
  _Native-ClickPoint -X $x -Y $y -Button $button -Clicks $clicks
  _Trajectory-Append -Kind "click_point" -Payload @{ x = $x; y = $y; button = $button; clicks = $clicks; source = "native" }
  if ($Brief) { [Console]::Out.WriteLine("ok click-point @($x,$y) button=$button clicks=$clicks source=native") }
  return 0
}

function Invoke-MacroWaitLabel {
  param([string[]]$Rest)
  $label = _Read-OptValue -Rest $Rest -Name "--label"
  $window = _Read-OptValue -Rest $Rest -Name "--window"
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $timeout = [int](_Read-OptValue -Rest $Rest -Name "--timeout-ms")
  $interval = [int](_Read-OptValue -Rest $Rest -Name "--interval-ms")
  if (-not $label) { throw "macro wait-label requires --label" }
  if (-not $match) { $match = $window }
  if ($timeout -le 0) { $timeout = 10000 }
  if ($interval -le 0) { $interval = 600 }

  $deadline = (Get-Date).AddMilliseconds($timeout)
  $attempts = 0
  while ((Get-Date) -lt $deadline) {
    $attempts++
    # bypass cache: this is a polling loop
    $shot = Invoke-Appshot -Match $match -Semantic:$true -NoCache
    if ($shot) {
      $el = Find-Element -Appshot $shot -Label $label -Window $window
      if ($el) {
        if ($Brief) { [Console]::Out.WriteLine("ok wait-label '$label' attempts=$attempts") }
        else { Write-Notice -Level "OK" -Message "라벨 발견: '$label' (attempts=$attempts)" }
        return 0
      }
    }
    Start-Sleep -Milliseconds $interval
  }
  if ($Brief) { [Console]::Out.WriteLine("err wait-label '$label' timeout") }
  Write-Notice -Level "ERROR" -Message "라벨을 찾지 못했습니다: '$label' (timeout=${timeout}ms, attempts=$attempts)"
  return 1
}

function Invoke-MacroFindLabel {
  # macro find-label -- read-only label resolver.
  #
  # Selector ranking (explained when --explain is given):
  #   1. exact text match (case-insensitive, normalized whitespace) ->  +100
  #   2. substring match  ->  +60..+100 (shorter target = higher score)
  #   3. role/window filter agreement
  #   4. source confidence (uia high > fused medium > ocr low)
  #   5. visibility / rect non-empty hard requirement
  #
  # Modes:
  #   default       : fast lookup, no vision fallback (read-only).
  #   --explain     : returns top-N candidates with score breakdown, no action.
  #   --fast        : Win32-first short-circuit. If no window matches --window
  #                   /--match, skip the expensive appshot/UIA/OCR/vision pipeline
  #                   entirely and return partial(2) with no_window evidence.
  #                   Designed for perf-suite measurements and quick gating.
  #   --no-vision   : disables codex vision fallback (currently click-label only;
  #                   kept here for parity in --fast mode and downstream callers).
  #
  # Ambiguity:
  #   If two candidates score within --ambiguity-window (default 10) of each
  #   other, return status="partial" (exit 2) and surface ranked candidates.
  param([string[]]$Rest)
  $label  = _Read-OptValue -Rest $Rest -Name "--label"
  $window = _Read-OptValue -Rest $Rest -Name "--window"
  $match  = _Read-OptValue -Rest $Rest -Name "--match"
  $role   = _Read-OptValue -Rest $Rest -Name "--role"
  $explain = _Read-Switch -Rest $Rest -Name "--explain"
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  $fast    = _Read-Switch -Rest $Rest -Name "--fast"
  $noVision = _Read-Switch -Rest $Rest -Name "--no-vision"
  $ambWin = [int](_Read-OptValue -Rest $Rest -Name "--ambiguity-window")
  if ($ambWin -le 0) { $ambWin = 10 }
  if (-not $label) { throw "macro find-label requires --label" }
  if (-not $match) { $match = $window }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  # --fast short-circuit: Win32-only window check first. If --window or
  # --match is set and no top-level visible window matches, return partial
  # immediately without touching helper/appshot/UIA. This brings perf
  # find_label_no_match from ~9s into ~30-100ms for the common no-match case.
  if ($fast -and $match) {
    $w32 = _Enumerate-Win32Windows -Match $match
    $visible = @($w32 | Where-Object { $_.visible -and -not $_.minimized })
    if ($visible.Count -eq 0) {
      $sw.Stop()
      $elapsedFast = [int]$sw.Elapsed.TotalMilliseconds
      $envFast = _New-ObservationEnvelope `
        -Kind "find-label" -Status "partial" `
        -ElapsedMs $elapsedFast `
        -Sources @("win32") `
        -Data ([pscustomobject]@{
          label = $label; match = $match; window = $window; role = $role
          fast_path = $true
          ambiguous = $false
          ambiguity_window = $ambWin
          top = $null
          candidates = @()
          candidate_count = 0
        }) `
        -RecoverableErrors @([pscustomobject]@{
          code = "no_window"
          message = "fast-path: no visible window matches '$match'"
          recommended_action = "Verify the app is running with 'cucp macro windows --match `"$match`"', or drop --fast to engage UIA/OCR fallback."
        }) `
        -Confidence "high"
      if ($Brief -and -not $jsonOnly) {
        [Console]::Out.WriteLine(("partial find-label '{0}' fast no_window match='{1}' elapsed_ms={2}" -f $label, $match, $elapsedFast))
      } else {
        [Console]::Out.WriteLine(($envFast | ConvertTo-Json -Depth 8))
      }
      return 2
    }
  }

  $shot = Invoke-Appshot -Match $match -Semantic:$true
  if (-not $shot) {
    # appshot failure: keep wrapper deterministic by emitting envelope-flavored
    # error and a recovery hint instead of throwing into the dispatch catch.
    $hintCmd = "cucp macro windows --match '" + $match + "'"
    $env_ = _New-ObservationEnvelope `
      -Kind "find-label" -Status "partial" `
      -ElapsedMs ([int]$sw.Elapsed.TotalMilliseconds) `
      -Sources @("appshot") `
      -Data ([pscustomobject]@{ label = $label; match = $match; observed = 0 }) `
      -RecoverableErrors @([pscustomobject]@{
        code = "appshot_failed"
        message = "observe appshot returned no usable artifact"
        recommended_action = "Run 'cucp macro ensure-helper' or retry; verify '$match' window exists with $hintCmd"
      })
    if ($Brief -and -not $jsonOnly) {
      [Console]::Out.WriteLine("partial find-label '$label' appshot_failed")
    } else {
      [Console]::Out.WriteLine(($env_ | ConvertTo-Json -Depth 8))
    }
    return 2
  }

  # Build candidate pool from grounded + fused + items, normalized into a
  # single shape so scoring is consistent.
  $needle = $label.Trim().ToLowerInvariant()
  $needleNorm = ($needle -replace '\s+',' ').Trim()
  $cands = New-Object System.Collections.ArrayList

  function _AddPool { param($Pool, [string]$Tier, [int]$BaseConf)
    foreach ($el in $Pool) {
      if (-not $el) { continue }
      if (-not $el.text) { continue }
      if (-not $el.rect) { continue }
      if ($Window -and $el.window -and ($el.window.ToLowerInvariant() -notmatch [regex]::Escape($Window.ToLowerInvariant()))) { continue }
      if ($Role -and $el.role -and ($el.role.ToLowerInvariant() -ne $Role.ToLowerInvariant())) { continue }
      $hay = $el.text.ToString().ToLowerInvariant().Trim()
      $hayNorm = ($hay -replace '\s+',' ').Trim()
      $score = 0
      $reason = ""
      if ($hayNorm -eq $needleNorm) { $score = 100; $reason = "exact" }
      elseif ($hayNorm -match [regex]::Escape($needleNorm)) {
        $diff = [Math]::Abs($hayNorm.Length - $needleNorm.Length)
        $score = 60 + [Math]::Max(0, 40 - $diff); $reason = "substring"
      } elseif ($needleNorm.Length -ge 3 -and $hayNorm.IndexOf($needleNorm.Substring(0, [Math]::Min(3, $needleNorm.Length))) -ge 0) {
        $score = 20; $reason = "prefix"
      } else { continue }
      $confBoost = $BaseConf
      if ($el.confidence) {
        if ($el.confidence -is [string]) {
          switch ($el.confidence.ToLowerInvariant()) {
            "high"   { $confBoost += 4 }
            "medium" { $confBoost += 2 }
            "low"    { $confBoost += 1 }
          }
        } elseif ($el.confidence -is [double] -or $el.confidence -is [int]) {
          $confBoost += [int]([double]$el.confidence * 5)
        }
      }
      $score += $confBoost
      [void]$cands.Add([pscustomobject]@{
        text = $el.text
        normalized = $hayNorm
        role = $el.role
        window = $el.window
        rect = $el.rect
        affordance_id = $el.affordance_id
        score = $score
        tier = $Tier
        match_reason = $reason
        confidence_boost = $confBoost
        sources = if ($el.sources) { @($el.sources) } else { @($Tier) }
      })
    }
  }

  _AddPool -Pool $shot.Grounded      -Tier "grounded" -BaseConf 4
  _AddPool -Pool $shot.FusedElements -Tier "fused"    -BaseConf 2
  _AddPool -Pool $shot.Items         -Tier "items"    -BaseConf 0

  $ranked = @($cands | Sort-Object -Property score -Descending)
  $sw.Stop()
  $elapsed = [int]$sw.Elapsed.TotalMilliseconds

  $top = if ($ranked.Count -gt 0) { $ranked[0] } else { $null }
  $second = if ($ranked.Count -gt 1) { $ranked[1] } else { $null }
  $ambiguous = $false
  if ($top -and $second) {
    if (($top.score - $second.score) -lt $ambWin) { $ambiguous = $true }
  }

  $sources = @("appshot")
  if ($shot.Grounded -and $shot.Grounded.Count -gt 0) { $sources += "uia" }
  if ($shot.FromCache) { $sources += "cache" }

  $cache = [pscustomobject]@{
    hit = [bool]$shot.FromCache
    age_ms = $null
    max_age_ms = ($CacheSeconds * 1000)
    key = "appshot::match=$match"
    reason = if ($shot.FromCache) { "cache_fresh" } else { "live_capture" }
  }

  $foreground = $null
  if ($shot.FocusedWindow) {
    $foreground = [pscustomobject]@{ title = $shot.FocusedWindow }
  }

  if ($explain) {
    $explainStatus = "partial"
    if ($top -and -not $ambiguous) { $explainStatus = "ok" }
    $explainConf = "low"
    if ($top) {
      if ($top.score -ge 100) { $explainConf = "high" }
      elseif ($top.score -ge 60) { $explainConf = "medium" }
    }
    $explainRecover = @()
    if (-not $top) {
      $explainRecover = @([pscustomobject]@{
        code = "no_match"
        message = "no candidate matched '$label'"
        recommended_action = "Try 'cucp macro list-affordances --window `"$match`" --limit 30' to see available labels."
      })
    } elseif ($ambiguous) {
      $explainRecover = @([pscustomobject]@{
        code = "ambiguous_target"
        message = "top two candidates within ${ambWin} score points"
        recommended_action = "Narrow with --window or --role, or use the affordance_id from the candidates list."
      })
    }
    $envelope = _New-ObservationEnvelope `
      -Kind "find-label" -Status $explainStatus `
      -ElapsedMs $elapsed `
      -Sources $sources `
      -ObservationId $shot.ObservationId `
      -Foreground $foreground `
      -Data ([pscustomobject]@{
        label = $label
        window = $window
        role = $role
        ambiguous = $ambiguous
        ambiguity_window = $ambWin
        top = $top
        candidates = ($ranked | Select-Object -First 8)
        candidate_count = $ranked.Count
      }) `
      -Cache $cache `
      -Confidence $explainConf `
      -RecoverableErrors $explainRecover
    if ($Brief -and -not $jsonOnly) {
      if ($top) {
        $tag = if ($ambiguous) { "partial" } else { "ok" }
        [Console]::Out.WriteLine(("{0} find-label '{1}' top='{2}' score={3} reason={4} ambiguous={5} candidates={6} elapsed_ms={7}" -f `
          $tag, $label, $top.text, $top.score, $top.match_reason, $ambiguous, $ranked.Count, $elapsed))
      } else {
        [Console]::Out.WriteLine(("partial find-label '{0}' no_match candidates=0 elapsed_ms={1}" -f $label, $elapsed))
      }
    } else {
      [Console]::Out.WriteLine(($envelope | ConvertTo-Json -Depth 8))
    }
    if (-not $top) { return 2 }
    if ($ambiguous) { return 2 }
    return 0
  }

  # Default (non-explain) path retains backwards-compatible shape with a
  # status field, so existing parsers still work, but adds candidates+cache.
  $result = if ($top -and -not $ambiguous) {
    $center = Get-ElementCenter -Element $top
    [pscustomobject]@{
      status = "ok"
      schema = "cucp.find-label/v2"
      label = $label
      window = $top.window
      role = $top.role
      text = $top.text
      rect = $top.rect
      center = $center
      observation_id = $shot.ObservationId
      from_cache = [bool]$shot.FromCache
      sources = $sources
      score = $top.score
      candidates = ($ranked | Select-Object -First 5)
      elapsed_ms = $elapsed
    }
  } elseif ($top -and $ambiguous) {
    [pscustomobject]@{
      status = "partial"
      schema = "cucp.find-label/v2"
      label = $label
      reason = "ambiguous_target"
      candidates = ($ranked | Select-Object -First 5)
      observation_id = $shot.ObservationId
      from_cache = [bool]$shot.FromCache
      sources = $sources
      ambiguity_window = $ambWin
      elapsed_ms = $elapsed
      recommended_action = "Narrow with --window or --role, or pick by affordance_id."
    }
  } else {
    [pscustomobject]@{
      status = "not_found"
      schema = "cucp.find-label/v2"
      label = $label
      window = $window
      observation_id = $shot.ObservationId
      from_cache = [bool]$shot.FromCache
      sources = $sources
      candidates_text = ($shot.FusedElements | Select-Object -First 20 | ForEach-Object { $_.text }) -join " | "
      elapsed_ms = $elapsed
      recommended_action = "Try 'cucp macro list-affordances --window `"$match`"' or relax --window/--role."
    }
  }

  if ($Brief -and -not $jsonOnly) {
    if ($result.status -eq "ok") {
      [Console]::Out.WriteLine("ok find-label '$label' @($($result.center.X),$($result.center.Y)) win='$($result.window)' score=$($result.score)")
    } elseif ($result.status -eq "partial") {
      [Console]::Out.WriteLine("partial find-label '$label' ambiguous candidates=$($result.candidates.Count)")
    } else {
      [Console]::Out.WriteLine("err find-label '$label' not_found")
    }
  } else {
    [Console]::Out.WriteLine(($result | ConvertTo-Json -Depth 8))
  }
  if ($result.status -eq "ok") { return 0 }
  if ($result.status -eq "partial") { return 2 }
  # not_found: keep historical exit semantic (1) for back-compat.
  return 1
}

function Invoke-MacroClickLabel {
  param([string[]]$Rest, [switch]$Double, [switch]$RightClick)
  $label  = _Read-OptValue -Rest $Rest -Name "--label"
  $window = _Read-OptValue -Rest $Rest -Name "--window"
  $match  = _Read-OptValue -Rest $Rest -Name "--match"
  $role   = _Read-OptValue -Rest $Rest -Name "--role"
  $offsetX = [int](_Read-OptValue -Rest $Rest -Name "--offset-x")
  $offsetY = [int](_Read-OptValue -Rest $Rest -Name "--offset-y")
  $noVision = _Read-Switch -Rest $Rest -Name "--no-vision"
  if (-not $label) { throw "macro click-label requires --label" }
  if (-not $match) { $match = $window }
  if (-not $AllowLiveControl) {
    Write-Notice -Level "ERROR" -Message "라이브 클릭은 -AllowLiveControl이 필요합니다."
    throw "Live click requires -AllowLiveControl"
  }

  $shot = Invoke-Appshot -Match $match -Semantic:$true -NoCache
  if (-not $shot) { throw "appshot failed" }

  $el = Find-Element -Appshot $shot -Label $label -Window $window -Role $role
  if (-not $el) {
    # Fallback chain (small icons especially): icon-find via UIA crawl ->
    # codex vision -> error. icon-find catches toolbar icons whose Name is
    # empty but AutomationId/HelpText/AccessKey carries the label.
    $iconHit = $null
    try {
      $captured = ""
      $oldOut = [Console]::Out
      $sb = New-Object System.IO.StringWriter
      [Console]::SetOut($sb)
      try {
        Invoke-MacroIconFind -Rest @("--label", $label, "--match", $match, "--window", $window, "--max-size", "96", "--limit", "5", "--json-only") | Out-Null
      } finally { [Console]::SetOut($oldOut) }
      $captured = $sb.ToString()
      $env_ = $captured | ConvertFrom-Json -ErrorAction SilentlyContinue
      if ($env_ -and $env_.status -eq "ok" -and $env_.top) {
        $iconHit = $env_.top
      }
    } catch { }

    if ($iconHit) {
      $x = [int]$iconHit.center.x + $offsetX
      $y = [int]$iconHit.center.y + $offsetY
      $clickKind = if ($RightClick) { "right-click" } else { "click" }
      $cucpArgs = @("act", $clickKind, "--x", "$x", "--y", "$y", "--after", $shot.ObservationId)
      if ($iconHit.window) { $cucpArgs += @("--target-window", $iconHit.window) }
      $r = Invoke-Cucp -ArgList $cucpArgs
      if ($Double -and $r.ExitCode -eq 0) { Invoke-Cucp -ArgList $cucpArgs | Out-Null }
      _Trajectory-Append -Kind "click" -Payload @{
        label = $label
        window = $iconHit.window
        source = "icon_find_fallback"
        confidence = "$($iconHit.confidence)"
        x = $x; y = $y
        rect_w = [int]$iconHit.rect.width
        rect_h = [int]$iconHit.rect.height
        observation_id = $shot.ObservationId
        exit = $r.ExitCode
      }
      if ($Brief) {
        if ($r.ExitCode -eq 0) {
          Write-Output ("ok click-label '$label' @($x,$y) via=icon-find size=$([int]$iconHit.rect.width)x$([int]$iconHit.rect.height) score=$($iconHit.score)")
        } else {
          Write-Output "err click-label '$label' exit=$($r.ExitCode)"
        }
      }
      return $r.ExitCode
    }

    # UIA/OCR fusion didn't match. Optionally fall back to codex vision
    # which can read arbitrary UIs (browser canvas, games, custom dialogs).
    if (-not $noVision) {
      Write-Notice -Level "WARN" -Message "라벨 fusion + icon-find 실패 - codex vision으로 fallback: '$label'"
      $visionDesc = $label
      if ($window) { $visionDesc = "$label ($window 창 안)" }
      $vision = _Invoke-CodexVision -ScreenshotPath $shot.ScreenshotPath -Description $visionDesc
      if ($vision.status -eq "ok") {
        $x = [int]$vision.x + $offsetX
        $y = [int]$vision.y + $offsetY
        $clickKind = if ($RightClick) { "right-click" } else { "click" }
        $cucpArgs = @("act", $clickKind, "--x", "$x", "--y", "$y", "--after", $shot.ObservationId)
        if ($window) { $cucpArgs += @("--target-window", $window) }
        $r = Invoke-Cucp -ArgList $cucpArgs
        if ($Double -and $r.ExitCode -eq 0) { Invoke-Cucp -ArgList $cucpArgs | Out-Null }
        _Trajectory-Append -Kind "click" -Payload @{
          label = $label
          window = $window
          source = "vision_fallback"
          confidence = "$($vision.confidence)"
          x = $x; y = $y
          observation_id = $shot.ObservationId
          exit = $r.ExitCode
        }
        if ($Brief) {
          if ($r.ExitCode -eq 0) { Write-Output "ok click-label '$label' @($x,$y) via=vision conf=$($vision.confidence)" }
          else { Write-Output "err click-label '$label' exit=$($r.ExitCode)" }
        }
        return $r.ExitCode
      } else {
        Write-Notice -Level "ERROR" -Message "vision fallback도 실패: $($vision.status) $($vision.reason)"
      }
    }
    Write-Notice -Level "ERROR" -Message "라벨을 찾지 못했습니다: '$label' (window='$window'). 후보: $((($shot.FusedElements | Select-Object -First 10 | ForEach-Object { $_.text }) -join ' | '))"
    throw "Label not found: $label"
  }

  $center = Get-ElementCenter -Element $el
  $x = $center.X + $offsetX
  $y = $center.Y + $offsetY

  $clickKind = if ($RightClick) { "right-click" } elseif ($Double) { "click" } else { "click" }
  $clickArgs = @("act", $clickKind, "--x", "$x", "--y", "$y", "--after", $shot.ObservationId)
  if ($el.window) { $clickArgs += @("--target-window", $el.window) }

  $r = Invoke-Cucp -ArgList $clickArgs
  if ($Double -and $r.ExitCode -eq 0) {
    # second click (no fresh observation needed within freshness window)
    Invoke-Cucp -ArgList $clickArgs | Out-Null
  }

  _Trajectory-Append -Kind "click" -Payload @{
    label = $label
    window = $el.window
    role = $el.role
    x = $x
    y = $y
    observation_id = $shot.ObservationId
    exit = $r.ExitCode
    double = [bool]$Double
    right = [bool]$RightClick
  }

  if ($Brief) {
    if ($r.ExitCode -eq 0) { Write-Output "ok click-label '$label' @($x,$y) win='$($el.window)'" }
    else { Write-Output "err click-label '$label' exit=$($r.ExitCode)" }
  }
  return $r.ExitCode
}

function Invoke-MacroFillLabel {
  param([string[]]$Rest)
  $label  = _Read-OptValue -Rest $Rest -Name "--label"
  $text   = _Read-OptValue -Rest $Rest -Name "--text"
  $window = _Read-OptValue -Rest $Rest -Name "--window"
  $match  = _Read-OptValue -Rest $Rest -Name "--match"
  $role   = _Read-OptValue -Rest $Rest -Name "--role"
  $clear  = _Read-Switch -Rest $Rest -Name "--clear"
  $enter  = _Read-Switch -Rest $Rest -Name "--enter"
  if (-not $label) { throw "macro fill-label requires --label" }
  if ($null -eq $text) { throw "macro fill-label requires --text" }
  if (-not $match) { $match = $window }
  if (-not $AllowLiveControl) { throw "macro fill-label requires -AllowLiveControl" }

  $shot = Invoke-Appshot -Match $match -Semantic:$true -NoCache
  if (-not $shot) { throw "appshot failed" }

  $el = Find-Element -Appshot $shot -Label $label -Window $window -Role $role
  if (-not $el) { throw "Label not found: $label" }

  $center = Get-ElementCenter -Element $el
  $cucpArgs = @("act", "type", "--text", $text, "--x", "$($center.X)", "--y", "$($center.Y)", "--after", $shot.ObservationId)
  if ($el.window) { $cucpArgs += @("--target-window", $el.window) }
  if ($clear) { $cucpArgs += "--clear" }
  if ($enter) { $cucpArgs += "--enter" }
  $r = Invoke-Cucp -ArgList $cucpArgs
  if ($Brief) {
    if ($r.ExitCode -eq 0) { Write-Output "ok fill-label '$label'" }
    else { Write-Output "err fill-label '$label' exit=$($r.ExitCode)" }
  }
  return $r.ExitCode
}

function Invoke-MacroFocusWindow {
  param([string[]]$Rest)
  $name = _Read-OptValue -Rest $Rest -Name "--name"
  if (-not $name) { throw "macro focus-window requires --name" }
  if (-not $AllowLiveControl) { throw "macro focus-window requires -AllowLiveControl" }
  $win = _Native-FocusWindow -Name $name
  $exit = if ($win) { 0 } else { 1 }
  if ($Brief) {
    if ($exit -eq 0) {
      Write-Output "ok focus '$name' source=native title='$($win.title)'"
    } else {
      # Provide a deterministic recovery hint when focus fails. Most common
      # cause is that the requested window is not running. Probe with Win32.
      $cands = _Enumerate-Win32Windows -Match $name
      $visible = @($cands | Where-Object { $_.visible -and -not $_.minimized })
      $hint = if ($visible.Count -gt 0) {
        "candidate window present (pid=$($visible[0].pid)); use 'cucp -AllowLiveControl macro focus-verify --name `"$name`"' to confirm foreground."
      } else {
        "no visible window matches '$name'. Use 'cucp macro app-launch --name `"$name`"' first."
      }
      Write-Output "err focus '$name' exit=$exit hint=$hint"
    }
  }
  return $exit
}

function Invoke-MacroWaitWindow {
  param([string[]]$Rest)
  $title = _Read-OptValue -Rest $Rest -Name "--title"
  $timeout = [int](_Read-OptValue -Rest $Rest -Name "--timeout-ms")
  $interval = [int](_Read-OptValue -Rest $Rest -Name "--interval-ms")
  $noFallback = _Read-Switch -Rest $Rest -Name "--no-win32-fallback"
  if (-not $title) { throw "macro wait-window requires --title" }
  if ($timeout -le 0) { $timeout = 10000 }
  if ($interval -le 0) { $interval = 500 }

  $deadline = (Get-Date).AddMilliseconds($timeout)
  $attempts = 0
  $lastSource = ""
  while ((Get-Date) -lt $deadline) {
    $attempts++
    $r = Invoke-Cucp -ArgList @("observe", "windows", "--match", $title) -CaptureJson
    if ($r.Json -and $r.Json.status -eq "ok") {
      $items = $r.Json.artifacts | Where-Object { $_.type -eq "windows" } | ForEach-Object { $_.items }
      if ($items -and $items.Count -gt 0) {
        $lastSource = "helper"
        if ($Brief) { [Console]::Out.WriteLine("ok wait-window '$title' source=helper attempts=$attempts") }
        else { Write-Notice -Level "OK" -Message "윈도우 발견(helper): '$title' (attempts=$attempts)" }
        return 0
      }
    }
    # Win32 EnumWindows fallback: helper가 false-empty를 줄 때도 결정적으로 잡음
    if (-not $noFallback) {
      $w32 = _Enumerate-Win32Windows -Match $title
      $visible = @($w32 | Where-Object { $_.visible -and -not $_.minimized })
      if ($visible.Count -gt 0) {
        $first = $visible | Select-Object -First 1
        $lastSource = "win32"
        if ($Brief) { [Console]::Out.WriteLine(("ok wait-window '{0}' source=win32 attempts={1} title='{2}' pid={3}" -f `
          $title, $attempts, $first.title, $first.pid)) }
        else { Write-Notice -Level "OK" -Message ("윈도우 발견(win32 fallback): '$title' pid=$($first.pid) attempts=$attempts") }
        return 0
      }
    }
    Start-Sleep -Milliseconds $interval
  }
  # On timeout, attach evidence about what we *did* see, so the operator
  # can decide whether to retry, narrow, or change source.
  $lastWin32 = if (-not $noFallback) { @(_Enumerate-Win32Windows -Match $null | Where-Object { $_.visible }) } else { @() }
  $sample = ($lastWin32 | Select-Object -First 5 | ForEach-Object { "'$($_.title)'" }) -join ", "
  if ($Brief) { [Console]::Out.WriteLine(("partial wait-window '{0}' timeout attempts={1} visible_count={2}" -f $title, $attempts, $lastWin32.Count)) }
  Write-Notice -Level "ERROR" -Message "윈도우를 찾지 못했습니다: '$title' (timeout=${timeout}ms, attempts=$attempts). 현재 보이는 창 샘플: $sample"
  return 2
}

function Invoke-MacroShortcut {
  param([string[]]$Rest)
  $keys = _Read-OptValue -Rest $Rest -Name "--keys"
  if (-not $keys) { throw "macro shortcut requires --keys" }
  if (-not $AllowLiveControl) { throw "macro shortcut requires -AllowLiveControl" }
  try {
    _Native-SendShortcut -Keys $keys
    $exit = 0
  } catch {
    Write-Notice -Level "ERROR" -Message "shortcut 실패: $($_.Exception.Message)"
    $exit = 1
  }
  if ($Brief) {
    if ($exit -eq 0) { Write-Output "ok shortcut '$keys' source=native" } else { Write-Output "err shortcut '$keys' exit=$exit" }
  }
  return $exit
}

function Invoke-MacroClipboard {
  param([string[]]$Rest)
  $text = _Read-OptValue -Rest $Rest -Name "--set"
  if ($null -eq $text) { $text = _Read-OptValue -Rest $Rest -Name "--text" }
  $paste = _Read-Switch -Rest $Rest -Name "--paste"
  $get = _Read-Switch -Rest $Rest -Name "--get"
  if ($get) {
    _Ensure-NativeDesktopTypes
    $value = [System.Windows.Forms.Clipboard]::GetText()
    if ($Brief) { [Console]::Out.WriteLine("ok clipboard get length=$($value.Length)") } else { [Console]::Out.WriteLine($value) }
    return 0
  }
  if ($null -eq $text) { throw "macro clipboard requires --set <text>, --text <text>, or --get" }
  if (-not $AllowLiveControl) { throw "macro clipboard set/paste requires -AllowLiveControl" }
  _Native-SetClipboard -Text $text
  if ($paste) {
    Start-Sleep -Milliseconds 100
    _Native-SendShortcut -Keys "ctrl+v"
  }
  _Trajectory-Append -Kind "clipboard" -Payload @{ set_length = $text.Length; pasted = [bool]$paste; source = "native" }
  if ($Brief) { [Console]::Out.WriteLine("ok clipboard set length=$($text.Length) paste=$([bool]$paste) source=native") }
  return 0
}

function Invoke-MacroGoal {
  param([string[]]$Rest)
  $objective = _Read-OptValue -Rest $Rest -Name "--objective"
  $maxSteps = [int](_Read-OptValue -Rest $Rest -Name "--max-steps")
  $maxPhase = [int](_Read-OptValue -Rest $Rest -Name "--max-phase-ms")
  $provider = _Read-OptValue -Rest $Rest -Name "--provider"
  $verifyLabel = _Read-OptValue -Rest $Rest -Name "--verify-label"
  $verifyWindow = _Read-OptValue -Rest $Rest -Name "--verify-window"
  $verifyTimeout = [int](_Read-OptValue -Rest $Rest -Name "--verify-timeout-ms")
  $dryRun = _Read-Switch -Rest $Rest -Name "--dry-run"

  if (-not $objective) { throw "macro goal requires --objective" }
  if ($maxSteps -le 0) { $maxSteps = 60 }
  if ($maxPhase -le 0) { $maxPhase = 600000 }
  if (-not $provider) { $provider = "heuristic" }
  if ($verifyTimeout -le 0) { $verifyTimeout = 8000 }

  if ($dryRun) {
    $cucpArgs = @("l5", "capability", "--objective", $objective, "--provider", $provider, "--max-phase-ms", "$maxPhase")
    Write-Notice -Level "INFO" -Message "Goal 드라이런: $objective"
    $r = Invoke-Cucp -ArgList $cucpArgs
    return $r.ExitCode
  }

  if (-not $AllowLiveControl) { throw "macro goal (live) requires -AllowLiveControl" }

  Write-Notice -Level "WARN" -Message "Goal 자율 실행 시작: $objective (max-steps=$maxSteps)"
  $cucpArgs = @("l5", "run", "--objective", $objective, "--provider", $provider,
            "--allow-control", "--max-steps", "$maxSteps", "--max-phase-ms", "$maxPhase")
  $runResult = Invoke-Cucp -ArgList $cucpArgs
  $runOk = ($runResult.ExitCode -eq 0)

  # Self-verification phase: if user provided a verify-label, poll for it.
  $verifyOk = $true
  if ($verifyLabel) {
    Write-Notice -Level "INFO" -Message "자가 검증: '$verifyLabel' 등장 대기 (timeout=${verifyTimeout}ms)"
    $verifyArgs = @("macro", "wait-label", "--label", $verifyLabel, "--timeout-ms", "$verifyTimeout")
    if ($verifyWindow) { $verifyArgs += @("--window", $verifyWindow) }
    # call our own wrapper recursively to reuse appshot/find-label logic
    $verifyOutput = & $PSCommandPath @verifyArgs
    $verifyOk = ($LASTEXITCODE -eq 0)
  }

  if ($Brief) {
    if ($runOk -and $verifyOk) { [Console]::Out.WriteLine("ok goal '$objective'") }
    elseif (-not $runOk) { [Console]::Out.WriteLine("err goal '$objective' run-exit=$($runResult.ExitCode)") }
    else { [Console]::Out.WriteLine("err goal '$objective' verify-failed label='$verifyLabel'") }
  }

  if (-not $runOk) { return $runResult.ExitCode }
  if (-not $verifyOk) { return 2 }
  return 0
}

function Invoke-MacroSelfTest {
  param([string[]]$Rest)
  # Self-test exercises the safe, read-only paths that prove the wrapper +
  # CUCP CLI + helper backend are wired correctly. It does NOT actuate.
  #
  # Tests are categorized:
  #  - wrapper: pure wrapper logic (no helper needed)
  #  - cli:     CUCP CLI roundtrip (no helper needed)
  #  - helper:  Windows-MCP HTTP helper required
  #  - uia:     PowerShell UIAutomation fallback (deep only)
  #
  # If the helper is not running, helper-tier tests are reported as
  # "skipped" (not failed) and the wrapper tier still gets a clean pass.
  $deep = _Read-Switch -Rest $Rest -Name "--deep"
  $strict = _Read-Switch -Rest $Rest -Name "--strict"

  function _AddResult { param([string]$Name, [string]$Tier, [string]$Outcome, [string]$Detail = "")
    # outcome: ok | fail | skipped
    $script:_selfTestResults += [pscustomobject]@{ name=$Name; tier=$Tier; outcome=$Outcome; detail=$Detail }
  }
  $script:_selfTestResults = @()

  Write-Notice -Level "INFO" -Message "self-test 시작 (deep=$deep, strict=$strict)"

  # ---- Tier: wrapper -------------------------------------------------------
  # 1. live-control gate (pure wrapper logic)
  try {
    $blocked = $false
    try {
      Assert-Authorized -ArgList @("act", "click", "--x", "0", "--y", "0", "--after", "fake")
    } catch { $blocked = $true }
    _AddResult "live_gate_blocks" "wrapper" (_Iif { $blocked } "ok" "fail") "blocked-without-AllowLiveControl"
  } catch { _AddResult "live_gate_blocks" "wrapper" "fail" $_.Exception.Message }

  # 2. coord-without-after gate
  try {
    $blocked = $false
    try {
      Assert-Authorized -ArgList @("act", "click", "--x", "100", "--y", "100")
    } catch { $blocked = $true }
    _AddResult "coord_gate_requires_after" "wrapper" (_Iif { $blocked } "ok" "fail") "blocked-without-after"
  } catch { _AddResult "coord_gate_requires_after" "wrapper" "fail" $_.Exception.Message }

  # ---- Tier: cli (no helper required) --------------------------------------
  # 3. version
  $cliOk = $false
  try {
    $r = Invoke-Cucp -ArgList @("version") -CaptureJson
    $cliOk = ($r.ExitCode -eq 0 -and $r.Json.status -eq "ok")
    _AddResult "cli_version" "cli" (_Iif { $cliOk } "ok" "fail") ("v" + $r.Json.version)
  } catch { _AddResult "cli_version" "cli" "fail" $_.Exception.Message }

  # ---- Tier: helper (helper HTTP server required) --------------------------
  # 4. tools (probes helper)
  $helperReachable = $false
  try {
    $r = Invoke-Cucp -ArgList @("tools") -CaptureJson
    if ($r.ExitCode -eq 0 -and $r.Json.status -eq "ok") {
      $helperReachable = $true
      _AddResult "helper_tools" "helper" "ok" "tools available"
    } else {
      $errType = if ($r.Json.error_type) { $r.Json.error_type } else { "unreachable" }
      $detail = "helper not running ($errType) - run 'cucp start' to enable helper-tier tests"
      _AddResult "helper_tools" "helper" "skipped" $detail
    }
  } catch { _AddResult "helper_tools" "helper" "skipped" $_.Exception.Message }

  # 5. observe windows (only if helper reachable)
  if ($helperReachable) {
    try {
      $r = Invoke-Cucp -ArgList @("observe", "windows") -CaptureJson
      $ok = ($r.ExitCode -eq 0 -and $r.Json.status -eq "ok")
      _AddResult "observe_windows" "helper" (_Iif { $ok } "ok" "fail") ("status=" + $r.Json.status)
    } catch { _AddResult "observe_windows" "helper" "fail" $_.Exception.Message }

    # 6. cache write/read (uses appshot which uses helper)
    # We bypass the time-based freshness check and verify the cache file
    # itself was written and is reused. This avoids a flaky 2-second window
    # when the helper takes longer than CacheSeconds to respond.
    try {
      $shotA = Invoke-Appshot -Match "selftest-cache" -Semantic:$false -NoCache
      $cacheKey = Get-CacheKey -Match "selftest-cache"
      $cachePath = Join-Path $Script:CacheDir "appshot-$cacheKey.json"
      $cacheExists = Test-Path -LiteralPath $cachePath
      if (-not $cacheExists) {
        _AddResult "cache_hit" "helper" "fail" "cache file not written: $cachePath"
      } else {
        # Force generous cache window for the read so the test isn't sensitive
        # to overall appshot latency.
        $shotB = Invoke-Appshot -Match "selftest-cache" -Semantic:$false -CacheMaxSeconds 600
        $ok = ($shotB -ne $null -and $shotB.FromCache -eq $true)
        _AddResult "cache_hit" "helper" (_Iif { $ok } "ok" "fail") ("from_cache=" + $shotB.FromCache + " cacheFile=" + $cacheExists)
      }
    } catch { _AddResult "cache_hit" "helper" "fail" $_.Exception.Message }
  } else {
    _AddResult "observe_windows" "helper" "skipped" "skipped: helper not running"
    _AddResult "cache_hit" "helper" "skipped" "skipped: helper not running"
  }

  # ---- Tier: uia (PowerShell UIAutomation fallback) ------------------------
  if ($deep) {
    # 7. UIA fallback alone (no helper needed)
    try {
      $uia = _Get-UIAffordances -FocusedWindow "" -MaxElements 50
      $count = (@($uia)).Count
      $ok = ($count -gt 0)
      _AddResult "uia_fallback" "uia" (_Iif { $ok } "ok" "fail") "uia_affordances=$count"
    } catch { _AddResult "uia_fallback" "uia" "fail" $_.Exception.Message }

    # 8. appshot full-screen (helper required, otherwise skipped)
    if ($helperReachable) {
      try {
        $shot = Invoke-Appshot -Match "" -Semantic:$true -NoCache
        $ok = ($null -ne $shot -and $shot.ObservationId)
        $count = if ($shot.Affordances) { $shot.Affordances.Count } else { 0 }
        _AddResult "appshot_fullscreen" "helper" (_Iif { $ok } "ok" "fail") ("affordances=" + $count + " obs_id=" + $shot.ObservationId)
      } catch { _AddResult "appshot_fullscreen" "helper" "fail" $_.Exception.Message }
    } else {
      _AddResult "appshot_fullscreen" "helper" "skipped" "skipped: helper not running"
    }
  }

  # ---- Aggregate -----------------------------------------------------------
  $all = @($script:_selfTestResults)
  $passed = @($all | Where-Object { $_.outcome -eq "ok" }).Count
  $failed = @($all | Where-Object { $_.outcome -eq "fail" }).Count
  $skipped = @($all | Where-Object { $_.outcome -eq "skipped" }).Count
  $total = $all.Count
  $required = if ($strict) { $passed -eq $total } else { $failed -eq 0 }
  $status = if ($required) { "ok" } else { "fail" }

  $report = [pscustomobject]@{
    status = $status
    summary = if ($status -eq "ok" -and $skipped -gt 0) { "wrapper/cli/uia tiers passing; $skipped helper-tier test(s) skipped (run 'cucp start' to include)" } elseif ($status -eq "ok") { "all tiers passing" } else { "$failed test(s) failed" }
    passed = $passed
    failed = $failed
    skipped = $skipped
    total = $total
    helper_running = $helperReachable
    deep = $deep
    strict = $strict
    results = $all
  }
  if ($Brief) {
    [Console]::Out.WriteLine(("{0} self-test passed={1}/{2} skipped={3} failed={4}" -f $status, $passed, $total, $skipped, $failed))
  } else {
    [Console]::Out.WriteLine(($report | ConvertTo-Json -Depth 6))
  }
  if ($status -eq "ok") { return 0 } else { return 1 }
}

function _Iif { param([scriptblock]$Cond, $Then, $Else) if (& $Cond) { $Then } else { $Else } }

function Invoke-MacroTrajectory {
  param([string[]]$Rest)
  $action = if ($Rest.Count -ge 1) { $Rest[0] } else { "show" }
  $last = [int](_Read-OptValue -Rest $Rest -Name "--last")
  if ($last -le 0) { $last = 20 }
  switch ($action) {
    "show" {
      $entries = _Trajectory-Read -Last $last
      $payload = [pscustomobject]@{
        status = "ok"
        count = (@($entries)).Count
        path = $Script:TrajectoryFile
        entries = $entries
      }
      if ($Brief) {
        [Console]::Out.WriteLine(("ok trajectory count={0}" -f $payload.count))
      } else {
        [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 6))
      }
      return 0
    }
    "clear" {
      _Trajectory-Clear
      Write-Notice -Level "OK" -Message "trajectory 초기화"
      if ($Brief) { [Console]::Out.WriteLine("ok trajectory cleared") }
      return 0
    }
    "tail" {
      # Same as show but returns only the most recent entry's summary line
      $entries = _Trajectory-Read -Last 1
      if ($entries.Count -eq 0) {
        if ($Brief) { [Console]::Out.WriteLine("err trajectory empty") } else { [Console]::Out.WriteLine("{}") }
        return 1
      }
      [Console]::Out.WriteLine(($entries[0] | ConvertTo-Json -Compress -Depth 6))
      return 0
    }
    default {
      Write-Notice -Level "ERROR" -Message "trajectory 하위 명령: show | tail | clear"
      return 1
    }
  }
}

function Invoke-MacroEnsureHelper {
  param([string[]]$Rest)
  $waitMs = [int](_Read-OptValue -Rest $Rest -Name "--wait-ms")
  if ($waitMs -le 0) { $waitMs = 8000 }
  $ok = _Helper-Ensure -WaitMs $waitMs
  $report = [pscustomobject]@{
    status = if ($ok) { "ok" } else { "fail" }
    helper_running = $ok
  }
  if ($Brief) {
    [Console]::Out.WriteLine(("{0} helper running={1}" -f $report.status, $ok))
  } else {
    [Console]::Out.WriteLine(($report | ConvertTo-Json))
  }
  if ($ok) { return 0 } else { return 1 }
}

# ============================================================================
# Vision grounding via codex CLI
# ============================================================================
# When UIA + OCR fusion can't find a label (custom UI, browser canvas, game
# elements, dialogs without accessibility tree), this calls the local `codex`
# CLI with --image and --output-schema to get a structured (x,y) coordinate.
# This is the bridge that lets cucp + Codex match Claude Computer Use on
# arbitrary UIs while keeping our determinism on standard Win32/UIA ones.
# ============================================================================

function _Get-VisionWorkDir {
  $dir = Join-Path $Script:CacheDir "vision"
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  return $dir
}

function _Find-CodexCli {
  # On Windows, prefer .cmd / .exe over the bare entrypoint (where.exe returns
  # multiple matches and the first is often a Unix-style script that can't be
  # spawned directly via Process.Start).
  $cmd = Get-Command "codex.exe" -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $cmd = Get-Command "codex.cmd" -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $cmd = Get-Command "codex" -ErrorAction SilentlyContinue
  if ($cmd) {
    $src = $cmd.Source
    if ($src -and ($src.EndsWith(".exe") -or $src.EndsWith(".cmd") -or $src.EndsWith(".bat"))) {
      return $src
    }
    # Try sibling .cmd
    $cmdSibling = $src + ".cmd"
    if (Test-Path -LiteralPath $cmdSibling) { return $cmdSibling }
  }
  return $null
}

function _Invoke-CodexVision {
  <#
    Send a screenshot + question to codex CLI and parse a {found,x,y,confidence,reasoning}
    JSON response. Returns a pscustomobject or $null on failure.
  #>
  param(
    [Parameter(Mandatory)] [string]$ScreenshotPath,
    [Parameter(Mandatory)] [string]$Description,
    [int]$ImageWidth = 1920,
    [int]$ImageHeight = 1080,
    [int]$TimeoutMs = 90000,
    [string]$Model
  )

  $codex = _Find-CodexCli
  if (-not $codex) {
    Write-WrapperLog -Message "vision: codex CLI not found"
    return [pscustomobject]@{ status = "error"; reason = "codex CLI not found in PATH" }
  }

  if (-not (Test-Path -LiteralPath $ScreenshotPath)) {
    return [pscustomobject]@{ status = "error"; reason = "screenshot not found: $ScreenshotPath" }
  }

  $work = _Get-VisionWorkDir
  $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss-fff")
  $schemaPath = Join-Path $work "schema-$stamp.json"
  $outPath    = Join-Path $work "out-$stamp.json"

  $schema = @{
    type = "object"
    required = @("found", "x", "y", "confidence", "reasoning")
    additionalProperties = $false
    properties = @{
      found = @{ type = "boolean" }
      x = @{ type = "integer" }
      y = @{ type = "integer" }
      confidence = @{ type = "string"; enum = @("high","medium","low") }
      reasoning = @{ type = "string"; maxLength = 200 }
    }
  } | ConvertTo-Json -Depth 5
  [System.IO.File]::WriteAllText($schemaPath, $schema, [System.Text.UTF8Encoding]::new($false))

  $prompt = @"
You are a Windows GUI grounding model. The attached image is a $ImageWidth x $ImageHeight screenshot of the user's desktop.

Find: $Description

Return ONLY a single JSON object that matches the provided output schema.
- found: true if you can identify the element, false otherwise
- x, y: integer pixel coordinates of the element's center, in the $ImageWidth x $ImageHeight image space
- confidence: "high" | "medium" | "low"
- reasoning: short one-sentence justification

Do NOT include markdown fences, prose, or explanations outside the JSON object.
"@

  Write-WrapperLog -Message "vision: codex exec for '$Description' (cli=$codex)"
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    # codex.cmd / codex.bat must go through cmd.exe on Windows.
    # codex.exe can run directly. Use cmd.exe wrapper as the safe path either way.
    $isExe = $codex -match '\.exe$'
    $promptEscaped = $prompt -replace '"','""'
    $extraArgs = ""
    if ($Model) { $extraArgs = ' --model "' + $Model + '"' }
    $codexQuoted = '"' + $codex + '"'
    $cmdLine = "$codexQuoted exec --image `"$ScreenshotPath`" --output-schema `"$schemaPath`" --output-last-message `"$outPath`" --skip-git-repo-check$extraArgs `"$promptEscaped`""
    if ($isExe) {
      $psi.FileName = $codex
      $psi.Arguments = "exec --image `"$ScreenshotPath`" --output-schema `"$schemaPath`" --output-last-message `"$outPath`" --skip-git-repo-check$extraArgs `"$promptEscaped`""
    } else {
      $psi.FileName = "cmd.exe"
      $psi.Arguments = "/c " + $cmdLine
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $exited = $proc.WaitForExit($TimeoutMs)
    if (-not $exited) {
      try { $proc.Kill() } catch { }
      try { [void]$proc.WaitForExit(3000) } catch { }
      Write-WrapperLog -Message "vision: codex TIMEOUT after ${TimeoutMs}ms"
      return [pscustomobject]@{ status = "error"; reason = "codex exec timeout" }
    }
    $rawOut = $stdoutTask.GetAwaiter().GetResult()
    $rawErr = $stderrTask.GetAwaiter().GetResult()

    if ($proc.ExitCode -ne 0) {
      Write-WrapperLog -Message "vision: codex exit=$($proc.ExitCode) err=$rawErr"
      return [pscustomobject]@{ status = "error"; reason = "codex exec failed (exit=$($proc.ExitCode))"; stderr = $rawErr }
    }

    if (-not (Test-Path -LiteralPath $outPath)) {
      return [pscustomobject]@{ status = "error"; reason = "codex did not write output file" }
    }
    $rawJson = Get-Content -LiteralPath $outPath -Raw -Encoding UTF8
    try {
      $parsed = $rawJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
      return [pscustomobject]@{ status = "error"; reason = "codex output is not valid JSON"; raw = $rawJson }
    }

    if (-not $parsed.found) {
      return [pscustomobject]@{ status = "not_found"; reasoning = $parsed.reasoning; raw = $parsed }
    }

    return [pscustomobject]@{
      status = "ok"
      x = [int]$parsed.x
      y = [int]$parsed.y
      confidence = "$($parsed.confidence)"
      reasoning = "$($parsed.reasoning)"
      raw = $parsed
    }
  } catch {
    return [pscustomobject]@{ status = "error"; reason = $_.Exception.Message }
  }
}

function Invoke-MacroVisionFind {
  param([string[]]$Rest)
  $description = _Read-OptValue -Rest $Rest -Name "--describe"
  $screenshot = _Read-OptValue -Rest $Rest -Name "--screenshot"
  $model = _Read-OptValue -Rest $Rest -Name "--model"
  $timeoutMs = [int](_Read-OptValue -Rest $Rest -Name "--timeout-ms")
  if ($timeoutMs -le 0) { $timeoutMs = 90000 }
  if (-not $description) { throw "macro vision-find requires --describe" }

  # If no screenshot given, capture one via wrapper
  if (-not $screenshot) {
    $shotDir = _Get-VisionWorkDir
    $screenshot = Join-Path $shotDir ("vision-shot-" + (Get-Date).ToString("yyyyMMddHHmmssfff") + ".png")
    $shotArgs = @("observe", "screenshot", "--out", $screenshot)
    $r = Invoke-Cucp -ArgList $shotArgs -CaptureJson
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $screenshot)) {
      throw "vision-find could not capture screenshot via wrapper (exit=$($r.ExitCode))"
    }
  }

  $result = _Invoke-CodexVision -ScreenshotPath $screenshot -Description $description -TimeoutMs $timeoutMs -Model $model
  $payload = [pscustomobject]@{
    status = $result.status
    description = $description
    screenshot = $screenshot
    x = $result.x
    y = $result.y
    confidence = $result.confidence
    reasoning = $result.reasoning
    reason = $result.reason
  }

  _Trajectory-Append -Kind "vision_find" -Payload @{
    description = $description
    status = "$($result.status)"
    x = $result.x
    y = $result.y
    confidence = "$($result.confidence)"
  }

  if ($Brief) {
    if ($result.status -eq "ok") {
      [Console]::Out.WriteLine("ok vision-find @($($result.x),$($result.y)) conf=$($result.confidence)")
    } elseif ($result.status -eq "not_found") {
      [Console]::Out.WriteLine("err vision-find not_found")
    } else {
      [Console]::Out.WriteLine("err vision-find $($result.reason)")
    }
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 6))
  }
  if ($result.status -eq "ok") { return 0 } else { return 1 }
}

function Invoke-MacroVisionClick {
  param([string[]]$Rest)
  $description = _Read-OptValue -Rest $Rest -Name "--describe"
  $window = _Read-OptValue -Rest $Rest -Name "--window"
  $verifyLabel = _Read-OptValue -Rest $Rest -Name "--verify-label"
  $verifyTimeout = [int](_Read-OptValue -Rest $Rest -Name "--verify-timeout-ms")
  $model = _Read-OptValue -Rest $Rest -Name "--model"
  if (-not $description) { throw "macro vision-click requires --describe" }
  if ($verifyTimeout -le 0) { $verifyTimeout = 5000 }
  if (-not $AllowLiveControl) { throw "macro vision-click requires -AllowLiveControl" }

  # 1) capture screenshot via wrapper (creates an observation_id we can use for --after)
  $shotDir = _Get-VisionWorkDir
  $shotPath = Join-Path $shotDir ("click-shot-" + (Get-Date).ToString("yyyyMMddHHmmssfff") + ".png")
  $shotArgs = @("observe", "screenshot", "--out", $shotPath)
  $shotResult = Invoke-Cucp -ArgList $shotArgs -CaptureJson
  if ($shotResult.ExitCode -ne 0) { throw "vision-click could not capture screenshot" }
  $obsId = $null
  if ($shotResult.Json -and $shotResult.Json.observation -and $shotResult.Json.observation.id) {
    $obsId = $shotResult.Json.observation.id
  }
  if (-not $obsId) {
    # Fallback: appshot to get observation_id explicitly
    $shot = Invoke-Appshot -Match $window -Semantic:$false -NoCache
    if ($shot) { $obsId = $shot.ObservationId }
  }
  if (-not $obsId) { throw "vision-click could not establish observation_id" }

  # 2) Ask codex to find coordinates
  $result = _Invoke-CodexVision -ScreenshotPath $shotPath -Description $description -Model $model
  if ($result.status -ne "ok") {
    if ($Brief) { [Console]::Out.WriteLine("err vision-click $($result.status)") }
    Write-Notice -Level "ERROR" -Message "vision-click 좌표 추론 실패: $($result.reason)$($result.reasoning)"
    return 1
  }

  # 3) Click via wrapper
  $clickArgs = @("act", "click", "--x", "$($result.x)", "--y", "$($result.y)", "--after", $obsId)
  if ($window) { $clickArgs += @("--target-window", $window) }
  $r = Invoke-Cucp -ArgList $clickArgs

  _Trajectory-Append -Kind "vision_click" -Payload @{
    description = $description
    x = $result.x
    y = $result.y
    confidence = "$($result.confidence)"
    observation_id = $obsId
    exit = $r.ExitCode
  }

  # 4) Optional verification: a label must appear after the click
  $verifyOk = $true
  if ($r.ExitCode -eq 0 -and $verifyLabel) {
    $waitArgs = @("macro", "wait-label", "--label", $verifyLabel, "--timeout-ms", "$verifyTimeout")
    if ($window) { $waitArgs += @("--window", $window) }
    $verifyExit = & $PSCommandPath @waitArgs
    $verifyOk = ($LASTEXITCODE -eq 0)
  }

  if ($Brief) {
    if ($r.ExitCode -eq 0 -and $verifyOk) {
      [Console]::Out.WriteLine("ok vision-click @($($result.x),$($result.y)) conf=$($result.confidence)")
    } elseif ($r.ExitCode -ne 0) {
      [Console]::Out.WriteLine("err vision-click click-exit=$($r.ExitCode)")
    } else {
      [Console]::Out.WriteLine("err vision-click verify-failed label='$verifyLabel'")
    }
  }
  if ($r.ExitCode -ne 0) { return $r.ExitCode }
  if (-not $verifyOk) { return 2 }
  return 0
}

# ============================================================================
# Operational metrics + health-detail
# ============================================================================
# These give Codex (and any caller) a deterministic, machine-parseable health
# snapshot suitable for production dashboards and CI gates. Reads ONLY from
# durable artifacts written by the wrapper itself (no helper round-trips).
# ============================================================================

function Invoke-MacroMetrics {
  param([string[]]$Rest)
  $traj = _Trajectory-Read -Last 500
  $obsCount = (@($traj | Where-Object { $_.kind -eq "observation" })).Count
  $clickCount = (@($traj | Where-Object { $_.kind -eq "click" })).Count
  $visionFindCount = (@($traj | Where-Object { $_.kind -eq "vision_find" })).Count
  $visionClickCount = (@($traj | Where-Object { $_.kind -eq "vision_click" })).Count

  # Click success rate from trajectory (exit==0)
  $clickEntries = @($traj | Where-Object { $_.kind -eq "click" })
  $clickOk = (@($clickEntries | Where-Object { [int]$_.exit -eq 0 })).Count
  $clickRate = if ($clickEntries.Count -gt 0) { [Math]::Round(($clickOk / $clickEntries.Count) * 100, 1) } else { 0 }

  # Cache hit ratio
  $obsEntries = @($traj | Where-Object { $_.kind -eq "observation" })
  $cachedHits = (@($obsEntries | Where-Object { $_.from_cache -eq $true })).Count
  $cacheRate = if ($obsEntries.Count -gt 0) { [Math]::Round(($cachedHits / $obsEntries.Count) * 100, 1) } else { 0 }

  # Vision usage
  $visionUsed = $visionFindCount + $visionClickCount

  # Audit log size
  $logSize = if (Test-Path $Script:WrapperLog) { (Get-Item $Script:WrapperLog).Length } else { 0 }
  $cacheCount = (Get-ChildItem -LiteralPath $Script:CacheDir -Filter "appshot-*.json" -ErrorAction SilentlyContinue).Count

  $metrics = [pscustomobject]@{
    status = "ok"
    collected_at = (Get-Date).ToString("o")
    counters = [pscustomobject]@{
      observations = $obsCount
      clicks = $clickCount
      vision_finds = $visionFindCount
      vision_clicks = $visionClickCount
      total_actions = $clickCount + $visionClickCount
    }
    rates = [pscustomobject]@{
      click_success_pct = $clickRate
      cache_hit_pct = $cacheRate
    }
    storage = [pscustomobject]@{
      audit_log_bytes = $logSize
      cache_files = $cacheCount
      cache_dir = $Script:CacheDir
      trajectory_path = $Script:TrajectoryFile
    }
    config = [pscustomobject]@{
      cache_seconds = $CacheSeconds
      invoke_timeout_ms = $InvokeTimeoutMs
      cli_path = $Script:CliPath
    }
  }

  if ($Brief) {
    [Console]::Out.WriteLine(("ok metrics obs={0} clicks={1} vision={2} click_success={3}% cache_hit={4}%" -f `
      $obsCount, $clickCount, $visionUsed, $clickRate, $cacheRate))
  } else {
    [Console]::Out.WriteLine(($metrics | ConvertTo-Json -Depth 6))
  }
  return 0
}

function _New-ObservationEnvelope {
  <#
    Unified observation envelope used by macro windows / find-label / list-affordances /
    health-quick / focus-verify. Provides consistent shape so Codex can rely on
    a single schema regardless of which underlying source served the data.

    Fields:
      schema             : "cucp.observation/v1"
      kind               : "windows" | "find-label" | "list-affordances" | "context" | etc
      status             : "ok" | "partial" | "error"
      collected_at       : ISO8601
      elapsed_ms         : total wall clock for this observation
      sources            : array of strings (any of: win32, helper, uia, ocr,
                           screenshot, cache, vision, fallback)
      provenance         : per-field source map (e.g. {foreground:"win32", items:"win32"})
      observation_id     : (optional) underlying CUCP observation id when relevant
      foreground         : focused/active window summary (title, hwnd, pid, process)
      active_hwnd        : authoritative HWND of foreground window
      focused_title      : foreground title for quick consumption
      desktop            : @{ width, height } if known
      windows            : normalized list (or null if not applicable)
      data               : kind-specific payload object
      cache              : @{ hit, age_ms, max_age_ms, key, reason }
      stale              : bool — true if any contributing data is older than its budget
      confidence         : "high" | "medium" | "low" (overall observation confidence)
      warnings           : non-fatal soft issues
      recoverable_errors : array of @{ code, message, recommended_action }
      degraded_helper_empty : bool — true when helper returned empty but win32 has data
  #>
  param(
    [string]$Kind,
    [string]$Status = "ok",
    [int]$ElapsedMs = 0,
    [string[]]$Sources = @(),
    $Provenance = $null,
    [string]$ObservationId,
    $Foreground = $null,
    $Windows = $null,
    $Data = $null,
    $Cache = $null,
    [bool]$Stale = $false,
    [string]$Confidence = "high",
    [string[]]$Warnings = @(),
    $RecoverableErrors = @(),
    [bool]$DegradedHelperEmpty = $false,
    $Desktop = $null
  )
  $fgTitle = ""
  $activeHwnd = 0
  if ($Foreground) {
    $fgTitle = "$($Foreground.title)"
    if ($null -ne $Foreground.hwnd) { $activeHwnd = [int64]$Foreground.hwnd }
  }
  return [pscustomobject]@{
    schema = "cucp.observation/v1"
    kind = $Kind
    status = $Status
    collected_at = (Get-Date).ToString("o")
    elapsed_ms = $ElapsedMs
    sources = @($Sources)
    provenance = $Provenance
    observation_id = $ObservationId
    foreground = $Foreground
    active_hwnd = $activeHwnd
    focused_title = $fgTitle
    desktop = $Desktop
    windows = $Windows
    data = $Data
    cache = $Cache
    stale = $Stale
    confidence = $Confidence
    warnings = @($Warnings)
    recoverable_errors = @($RecoverableErrors)
    degraded_helper_empty = $DegradedHelperEmpty
  }
}

function _Get-DesktopSize {
  if (-not (_Ensure-Win32Loaded)) { return $null }
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $primary = [System.Windows.Forms.Screen]::PrimaryScreen
    if ($primary) {
      return [pscustomobject]@{
        width = [int]$primary.Bounds.Width
        height = [int]$primary.Bounds.Height
      }
    }
  } catch { }
  return $null
}

function Invoke-MacroWindows {
  # macro windows -- unified, read-only window enumeration.
  #
  # Sources:
  #   win32   : authoritative top-level enumeration via EnumWindows (deterministic)
  #   helper  : optional CUCP helper round-trip (--rich), adds app-id/role hints
  #
  # Failure semantics:
  #   - helper missing/empty + win32 has data => degraded_helper_empty=true,
  #     status remains "ok" because Win32 evidence is authoritative for foreground.
  #   - helper present + win32 empty (rare; secure desktop) => status="partial",
  #     recoverable_errors lists "helper_empty" or "no_visible_windows".
  #
  # Flags:
  #   --match <s>          case-insensitive substring of title/process
  #   --rich               also call helper `observe windows` for richer fields
  #   --include-hidden     include hidden/minimized windows
  #   --json-only          suppress brief output, JSON envelope only
  param([string[]]$Rest)
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $rich  = _Read-Switch  -Rest $Rest -Name "--rich"
  $hidden = _Read-Switch -Rest $Rest -Name "--include-hidden"
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $win32 = _Enumerate-Win32Windows -Match $match
  if (-not $hidden) {
    $win32 = @($win32 | Where-Object { $_.visible -and -not $_.minimized })
  }
  $win32Ms = [int]$sw.Elapsed.TotalMilliseconds

  $helperItems = @()
  $helperOk = $null
  $helperMs = $null
  $helperReason = ""
  $sources = @("win32")
  if ($rich) {
    $h = [System.Diagnostics.Stopwatch]::StartNew()
    $argsRich = @("observe","windows")
    if ($match) { $argsRich += @("--match", $match) }
    $r = Invoke-Cucp -ArgList $argsRich -CaptureJson
    $h.Stop()
    $helperMs = [int]$h.Elapsed.TotalMilliseconds
    if ($r.ExitCode -eq 0 -and $r.Json -and $r.Json.status -eq "ok") {
      $helperOk = $true
      $art = $r.Json.artifacts | Where-Object { $_.type -eq "windows" } | Select-Object -First 1
      if ($art -and $art.items) { $helperItems = $art.items }
      $sources += "helper"
    } else {
      $helperOk = $false
      $statusStr = if ($r.Json) { "$($r.Json.status)" } else { "no-json" }
      $helperReason = "exit=$($r.ExitCode) status=$statusStr"
    }
  }

  # Foreground (Win32 authoritative)
  $foreground = $win32 | Where-Object { $_.foreground } | Select-Object -First 1
  $foregroundObj = $null
  if ($foreground) {
    $foregroundObj = [pscustomobject]@{
      title = $foreground.title
      hwnd = $foreground.hwnd
      pid = $foreground.pid
      process = $foreground.process
      class = $foreground.class
      rect = $foreground.rect
    }
  }

  # Build provenance + warnings + recovery hints
  $helperStatusStr = "skipped"
  if ($rich) {
    if ($helperOk) { $helperStatusStr = "ok" } else { $helperStatusStr = "degraded" }
  }
  $itemsSrcStr = "win32"
  if ($rich -and $helperItems.Count -gt 0) { $itemsSrcStr = "win32+helper" }
  $provenance = [pscustomobject]@{
    foreground = "win32"
    items = $itemsSrcStr
    helper_status = $helperStatusStr
  }

  $warnings = New-Object System.Collections.ArrayList
  $recoverable = New-Object System.Collections.ArrayList
  $degraded = $false
  $status = "ok"

  if ($rich -and $helperOk -eq $true -and $helperItems.Count -eq 0 -and $win32.Count -gt 0) {
    $degraded = $true
    [void]$warnings.Add("degraded_helper_empty: helper returned 0 windows but win32 sees $($win32.Count). Using win32 evidence.")
  }

  if ($rich -and $helperOk -eq $false) {
    [void]$warnings.Add("helper_unavailable: $helperReason. Using win32 only.")
    [void]$recoverable.Add([pscustomobject]@{
      code = "helper_unavailable"
      message = $helperReason
      recommended_action = "Run 'cucp macro ensure-helper' or proceed with win32-only enumeration."
    })
  }

  if ($win32.Count -eq 0) {
    if ($match) {
      $status = "partial"
      [void]$recoverable.Add([pscustomobject]@{
        code = "no_window"
        message = "no top-level visible window matches '$match'"
        recommended_action = "Verify the app is running, or call without --match to list everything, or use --include-hidden."
      })
    } else {
      $status = "partial"
      [void]$recoverable.Add([pscustomobject]@{
        code = "no_visible_windows"
        message = "no visible top-level windows found (locked/secure desktop?)"
        recommended_action = "Re-try after unlocking the workstation or use --include-hidden."
      })
    }
  }

  # Cache metadata: this macro doesn't read from cache itself but exposes shape
  # for downstream consumers. Indicate cold path.
  $cache = [pscustomobject]@{
    hit = $false
    age_ms = $null
    max_age_ms = 0
    key = if ($match) { "windows::match=$match" } else { "windows::all" }
    reason = "live_enumerate"
  }

  $envelope = _New-ObservationEnvelope `
    -Kind "windows" `
    -Status $status `
    -ElapsedMs $win32Ms `
    -Sources $sources `
    -Provenance $provenance `
    -Foreground $foregroundObj `
    -Windows $win32 `
    -Data ([pscustomobject]@{
      match = $match
      fast = (-not $rich)
      include_hidden = [bool]$hidden
      helper_elapsed_ms = $helperMs
      helper_ok = $helperOk
      helper_reason = $helperReason
      helper_count = $helperItems.Count
      helper_items = $helperItems
      count = $win32.Count
    }) `
    -Cache $cache `
    -Confidence "high" `
    -Warnings $warnings.ToArray() `
    -RecoverableErrors $recoverable.ToArray() `
    -DegradedHelperEmpty $degraded `
    -Desktop (_Get-DesktopSize)

  if ($Brief -and -not $jsonOnly) {
    $tag = if ($degraded) { "ok-fallback" } elseif ($status -ne "ok") { $status } else { "ok" }
    $fgT = if ($foregroundObj) { $foregroundObj.title } else { "" }
    [Console]::Out.WriteLine(("{0} windows count={1} foreground='{2}' sources={3} elapsed_ms={4}" -f `
      $tag, $win32.Count, $fgT, ($sources -join "+"), $win32Ms))
  } else {
    [Console]::Out.WriteLine(($envelope | ConvertTo-Json -Depth 8))
  }

  if ($status -eq "ok") { return 0 } elseif ($status -eq "partial") { return 2 } else { return 1 }
}

function Invoke-MacroFocusVerify {
  # macro focus-verify --name <substring> [--timeout-ms <n>]
  # Live macro: requests focus via wrapper "app switch" then verifies via
  # Win32 GetForegroundWindow. Returns ok only if foreground actually matches.
  # Reports clear partial/error evidence with recommended next step on mismatch.
  param([string[]]$Rest)
  $name = _Read-OptValue -Rest $Rest -Name "--name"
  $timeout = [int](_Read-OptValue -Rest $Rest -Name "--timeout-ms")
  if (-not $name) { throw "macro focus-verify requires --name" }
  if (-not $AllowLiveControl) { throw "macro focus-verify requires -AllowLiveControl" }
  if ($timeout -le 0) { $timeout = 3000 }

  $beforeFg = ""
  $bf = _Enumerate-Win32Windows -Match $null
  $bfWin = $bf | Where-Object { $_.foreground } | Select-Object -First 1
  if ($bfWin) { $beforeFg = $bfWin.title }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $focusWin = _Native-FocusWindow -Name $name
  $switchExit = if ($focusWin) { 0 } else { 1 }

  $needle = $name.ToLowerInvariant()
  $afterFg = ""
  $verified = $false
  $deadline = (Get-Date).AddMilliseconds($timeout)
  while ((Get-Date) -lt $deadline) {
    $cur = _Enumerate-Win32Windows -Match $null
    $win = $cur | Where-Object { $_.foreground } | Select-Object -First 1
    if ($win) {
      $afterFg = $win.title
      $tt = $afterFg.ToLowerInvariant()
      $pp = if ($win.process) { $win.process.ToLowerInvariant() } else { "" }
      if ($tt.IndexOf($needle) -ge 0 -or $pp.IndexOf($needle) -ge 0) {
        $verified = $true
        break
      }
    }
    Start-Sleep -Milliseconds 150
  }
  $sw.Stop()

  $status = if ($verified) { "ok" } else { "partial" }
  $reason = if ($verified) { "" } else { "foreground='$afterFg' did not match '$name'" }
  $next = ""
  if (-not $verified) {
    $candidates = _Enumerate-Win32Windows -Match $name
    if ($candidates.Count -gt 0) {
      $first = $candidates | Select-Object -First 1
      $next = "candidate window found pid=$($first.pid) title='$($first.title)'. Try `macro app-launch --name '$name'` if not yet running, or pass exact title fragment."
    } else {
      $next = "no window matches '$name'. Use `macro app-launch --name '$name'` or `macro windows --rich` to inspect."
    }
  }

  $payload = [pscustomobject]@{
    status = $status
    collected_at = (Get-Date).ToString("o")
    requested = $name
    before_foreground = $beforeFg
    after_foreground = $afterFg
    switch_exit = $switchExit
    verified = $verified
    elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
    timeout_ms = $timeout
    reason = $reason
    recommended_action = $next
  }

  if ($Brief) {
    if ($verified) {
      [Console]::Out.WriteLine(("ok focus-verify '{0}' foreground='{1}' elapsed_ms={2}" -f $name, $afterFg, [int]$sw.Elapsed.TotalMilliseconds))
    } else {
      [Console]::Out.WriteLine(("partial focus-verify '{0}' foreground='{1}' reason='{2}' elapsed_ms={3}" -f $name, $afterFg, $reason, [int]$sw.Elapsed.TotalMilliseconds))
    }
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 6))
  }

  if ($verified) { return 0 } else { return 2 }
}

function Invoke-MacroHealthQuick {
  # macro health-quick: lightweight health surface that avoids the heavy
  # `tools list` HTTP probe. Reports node/cli/audit dir + Win32 enumerator
  # availability. ~50-150ms target.
  param([string[]]$Rest)
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  $report = [ordered]@{
    status = "checking"
    collected_at = (Get-Date).ToString("o")
    components = [ordered]@{}
  }

  # 1. Node
  $nodeOk = $false; $nodeVer = ""
  try {
    $nv = & node --version 2>&1
    if ($LASTEXITCODE -eq 0 -and $nv) { $nodeOk = $true; $nodeVer = "$nv".Trim() }
  } catch { }
  $report.components.node = [pscustomobject]@{ ok = $nodeOk; version = $nodeVer }

  # 2. CLI present
  $cliOk = Test-Path -LiteralPath $Script:CliPath
  $report.components.cli = [pscustomobject]@{ ok = $cliOk; path = $Script:CliPath }

  # 3. Audit dir writable (cheap probe)
  $auditOk = $false
  try {
    if (-not (Test-Path $Script:AuditDir)) { New-Item -ItemType Directory -Path $Script:AuditDir -Force | Out-Null }
    $probe = Join-Path $Script:AuditDir ".health-quick-probe-$([guid]::NewGuid())"
    Set-Content -LiteralPath $probe -Value "ok" -Encoding UTF8
    Remove-Item -LiteralPath $probe -Force
    $auditOk = $true
  } catch { }
  $report.components.audit_dir = [pscustomobject]@{ ok = $auditOk; path = $Script:AuditDir }

  # 4. Win32 enumerator (deterministic fallback)
  $win32Ok = _Ensure-Win32Loaded
  $report.components.win32_enum = [pscustomobject]@{ ok = $win32Ok }

  # 5. Temp/cache pressure (cheap stat-only counts; no log read)
  $tempPressureOk = $true
  $tempFileCount = 0
  $cacheFileCount = 0
  $logBytes = [int64]0
  try {
    if (Test-Path -LiteralPath $Script:CacheDir) {
      $cacheFileCount = @(Get-ChildItem -LiteralPath $Script:CacheDir -File -ErrorAction SilentlyContinue).Count
    }
    if (Test-Path -LiteralPath $Script:AuditDir) {
      $tempFileCount = @(Get-ChildItem -LiteralPath $Script:AuditDir -Recurse -File -ErrorAction SilentlyContinue).Count
    }
    if (Test-Path -LiteralPath $Script:WrapperLog) {
      $logBytes = [int64](Get-Item -LiteralPath $Script:WrapperLog).Length
    }
    if ($cacheFileCount -gt 1000 -or $tempFileCount -gt 2000 -or $logBytes -gt 64MB) {
      $tempPressureOk = $false
    }
  } catch { }
  $report.components.temp_pressure = [pscustomobject]@{
    ok = $tempPressureOk
    cache_files = $cacheFileCount
    temp_files = $tempFileCount
    wrapper_log_bytes = $logBytes
    tip = if ($tempPressureOk) { "" } else { "Run 'cucp macro cleanup --dry-run' to preview, then '--execute'." }
  }

  # 6. Recent timeout count: read only the last 64KB of the wrapper log.
  $recentTimeoutCount = 0
  $tailOk = $true
  if (Test-Path -LiteralPath $Script:WrapperLog) {
    try {
      $fs = [System.IO.File]::Open($Script:WrapperLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
      try {
        $len = [int64]$fs.Length
        $start = [int64][Math]::Max(0, $len - 65536)
        [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] ([int]([Math]::Min($len - $start, [int64]65536)))
        $n = $fs.Read($buf, 0, $buf.Length)
        $tailStr = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
        $matches = [regex]::Matches($tailStr, 'TIMEOUT')
        $recentTimeoutCount = $matches.Count
      } finally { $fs.Dispose() }
    } catch { $tailOk = $false }
  }
  $report.components.recent_timeouts = [pscustomobject]@{
    ok = ($tailOk -and $recentTimeoutCount -le 5)
    count = $recentTimeoutCount
    sample_bytes = 65536
    tip = if ($recentTimeoutCount -gt 5) { "Run 'cucp macro ensure-helper' or raise -InvokeTimeoutMs." } else { "" }
  }

  $sw.Stop()
  $required = @("node","cli","audit_dir","win32_enum")
  $allOk = $true
  foreach ($k in $required) { if (-not $report.components[$k].ok) { $allOk = $false } }
  # Pressure/timeouts are advisory only — don't fail health-quick on them.
  $report.status = if ($allOk) { "ok" } else { "fail" }
  $report.elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
  $report.note = "lightweight surface; for helper/codex/uia checks use macro health-detail"
  $payload = [pscustomobject]$report

  if ($Brief -and -not $jsonOnly) {
    [Console]::Out.WriteLine(("{0} health-quick node={1} cli={2} audit={3} win32={4} cache={5} timeouts={6} elapsed_ms={7}" -f `
      $report.status, $nodeOk, $cliOk, $auditOk, $win32Ok, $cacheFileCount, $recentTimeoutCount, $report.elapsed_ms))
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 6))
  }
  if ($allOk) { return 0 } else { return 1 }
}

function Invoke-MacroLogTail {
  # macro log-tail [--lines <n>] [--max-bytes <n>] [--path <file>] [--errors-only] [--json-only]
  # Read-only diagnostics over the wrapper audit log. Sensitive content
  # (auth/password/credit/token/secret/key) is redacted before emission.
  #
  # Performance contract:
  #   - O(tail bytes), not O(full log size). Default --max-bytes 262144 (256KB).
  #   - Regex patterns compiled once with Compiled+IgnoreCase, bounded
  #     `\S{1,256}` to avoid catastrophic backtracking.
  #   - Operates only on the emitted tail window; never scans full file.
  #   - --path lets tests target a small synthetic file so the test suite
  #     never touches the production wrapper log.
  param([string[]]$Rest)
  $linesArg = [int](_Read-OptValue -Rest $Rest -Name "--lines")
  if ($linesArg -le 0) { $linesArg = 50 }
  $maxBytes = [int](_Read-OptValue -Rest $Rest -Name "--max-bytes")
  if ($maxBytes -le 0) { $maxBytes = 262144 }
  $pathOverride = _Read-OptValue -Rest $Rest -Name "--path"
  $errorsOnly = _Read-Switch -Rest $Rest -Name "--errors-only"
  $jsonOnly   = _Read-Switch -Rest $Rest -Name "--json-only"

  $logPath = if ($pathOverride) { $pathOverride } else { $Script:WrapperLog }
  if (-not (Test-Path -LiteralPath $logPath)) {
    if ($Brief -and -not $jsonOnly) {
      [Console]::Out.WriteLine("partial log-tail no-log-file path='$logPath'")
    } else {
      $envEmpty = _New-ObservationEnvelope `
        -Kind "log-tail" -Status "partial" `
        -ElapsedMs 0 -Sources @("file") `
        -Data ([pscustomobject]@{ path = $logPath; lines = @() }) `
        -RecoverableErrors @([pscustomobject]@{
          code = "log_missing"
          message = "log not found: $logPath"
          recommended_action = "Run any cucp command first to materialize the audit log, or pass --path <file>."
        })
      [Console]::Out.WriteLine(($envEmpty | ConvertTo-Json -Depth 6))
    }
    return 2
  }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  # Stream-tail: open as binary, seek to end - maxBytes, read tail, decode.
  # This is O(maxBytes) regardless of file size.
  $tailText = ""
  $totalBytes = 0
  $tailBytes = 0
  try {
    $fs = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $totalBytes = [int64]$fs.Length
      $start = [int64][Math]::Max(0, $totalBytes - $maxBytes)
      [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
      $tailBytes = [int]([Math]::Min($totalBytes - $start, [int64]$maxBytes))
      $buf = New-Object byte[] $tailBytes
      $read = $fs.Read($buf, 0, $tailBytes)
      $tailText = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
    } finally { $fs.Dispose() }
  } catch {
    if ($Brief -and -not $jsonOnly) {
      [Console]::Out.WriteLine("partial log-tail read_failed: $($_.Exception.Message)")
    } else {
      $envErr = _New-ObservationEnvelope `
        -Kind "log-tail" -Status "partial" -ElapsedMs ([int]$sw.Elapsed.TotalMilliseconds) `
        -Sources @("file") `
        -Data ([pscustomobject]@{ path = $logPath }) `
        -RecoverableErrors @([pscustomobject]@{
          code = "log_read_failed"; message = $_.Exception.Message
          recommended_action = "Verify file is readable and not exclusively locked."
        })
      [Console]::Out.WriteLine(($envErr | ConvertTo-Json -Depth 6))
    }
    return 2
  }

  # If we started mid-line (totalBytes > maxBytes), drop the (potentially
  # partial) first line so reported lines are always whole.
  $startedMidLine = ($totalBytes -gt $tailBytes)
  $allLines = @($tailText -split "(?:\r\n|\n|\r)")
  if ($startedMidLine -and $allLines.Count -gt 0) {
    $allLines = $allLines | Select-Object -Skip 1
  }
  # Drop trailing empty string from final newline split
  $allLines = @($allLines | Where-Object { $_ -ne "" -or $false })
  # Take last N lines
  $rawLines = if ($allLines.Count -gt $linesArg) { $allLines[($allLines.Count - $linesArg)..($allLines.Count - 1)] } else { $allLines }

  if ($errorsOnly) {
    $errFilter = [regex]::new('ERROR|TIMEOUT|FAIL|throw|exit\s+(?:1|2|3|124)', [System.Text.RegularExpressions.RegexOptions]::Compiled)
    $rawLines = @($rawLines | Where-Object { $errFilter.IsMatch($_) })
  }

  # ---- Redaction ---------------------------------------------------------
  # Compile redaction patterns ONCE (Compiled + IgnoreCase). Bounded \S{1,256}
  # avoids catastrophic backtracking. JWT pattern requires literal `eyJ` so
  # cost is constant on non-token lines.
  if (-not $Script:_LogRedactRegex) {
    $opts = [System.Text.RegularExpressions.RegexOptions]::Compiled -bor `
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $patterns = @(
      'password\s*=\s*\S{1,256}',
      'passwd\s*=\s*\S{1,256}',
      'pwd\s*=\s*\S{1,256}',
      'secret\s*=\s*\S{1,256}',
      'token\s*=\s*\S{1,256}',
      'apikey\s*=\s*\S{1,256}',
      'api_key\s*=\s*\S{1,256}',
      'authorization:\s*\S{1,256}',
      'Bearer\s+\S{1,256}',
      'eyJ[A-Za-z0-9_\-]{20,512}\.[A-Za-z0-9_\-]{1,512}\.[A-Za-z0-9_\-]{1,512}'
    )
    $list = New-Object System.Collections.ArrayList
    foreach ($p in $patterns) { [void]$list.Add([regex]::new($p, $opts)) }
    $Script:_LogRedactRegex = $list.ToArray()
  }

  $redactedCount = 0
  $cleanedList = New-Object System.Collections.ArrayList
  foreach ($line in $rawLines) {
    $cur = $line
    foreach ($rgx in $Script:_LogRedactRegex) {
      if ($rgx.IsMatch($cur)) {
        $cur = $rgx.Replace($cur, '[redacted]')
        $redactedCount++
      }
    }
    [void]$cleanedList.Add($cur)
  }
  $cleaned = $cleanedList.ToArray()

  $errorPattern = [regex]::new('ERROR|TIMEOUT|FAIL', [System.Text.RegularExpressions.RegexOptions]::Compiled)
  $errorCount = 0
  foreach ($l in $cleaned) { if ($errorPattern.IsMatch($l)) { $errorCount++ } }
  $sw.Stop()
  $elapsed = [int]$sw.Elapsed.TotalMilliseconds

  if ($Brief -and -not $jsonOnly) {
    [Console]::Out.WriteLine(("ok log-tail lines={0} bytes_read={1} errors={2} redacted={3} elapsed_ms={4}" -f `
      $cleaned.Count, $tailBytes, $errorCount, $redactedCount, $elapsed))
    foreach ($l in $cleaned) { [Console]::Out.WriteLine("  | " + $l) }
  } else {
    $envelope = _New-ObservationEnvelope `
      -Kind "log-tail" -Status "ok" `
      -ElapsedMs $elapsed -Sources @("file") `
      -Data ([pscustomobject]@{
        path = $logPath
        total_bytes = $totalBytes
        bytes_read = $tailBytes
        max_bytes = $maxBytes
        requested_lines = $linesArg
        returned_lines = $cleaned.Count
        errors_only = [bool]$errorsOnly
        error_count = $errorCount
        redacted_count = $redactedCount
        lines = $cleaned
      }) `
      -Confidence "high"
    [Console]::Out.WriteLine(($envelope | ConvertTo-Json -Depth 6))
  }
  return 0
}

function Invoke-MacroDiagnoseLag {
  # macro diagnose-lag [--sample-ms <n>] [--json-only]
  #
  # Read-only runtime load report intended to explain why the Codex/Kiro
  # desktop app feels laggy during long CUCP sessions.
  #
  # Reports for selected processes (Codex, Kiro, node, powershell, Chrome,
  # CUCP helper if detectable):
  #   - count, total memory (MB), median private memory
  #   - CPU delta over a short sample window (default 3000ms, capped 8000ms)
  #   - basic priority class
  #   - oldest process age (seconds)
  # Plus host snapshots:
  #   - %TEMP%\computer-use-control-plane file count + size
  #   - wrapper-cache file count + size
  #   - wrapper log size (no full read)
  #   - foreground window title
  #
  # Warnings (non-blocking):
  #   - high_memory_total > 8GB across selected processes
  #   - electron_child_count > 25
  #   - cucp_temp_files > 1000
  #   - wrapper_log_bytes > 64MB
  #   - cpu_delta_pct > 60% on any single tracked process
  #
  # Returns recommended_action entries; never kills processes or alters
  # priority. The user / Codex agent decides what to do.
  param([string[]]$Rest)
  $sampleMs = [int](_Read-OptValue -Rest $Rest -Name "--sample-ms")
  if ($sampleMs -le 0) { $sampleMs = 3000 }
  if ($sampleMs -gt 8000) { $sampleMs = 8000 }
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"

  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  # Process groups we care about. Names are case-insensitive.
  $groups = @(
    @{ id = "codex";       names = @("codex","Codex") },
    @{ id = "kiro";        names = @("Kiro","kiro","Code") },
    @{ id = "node";        names = @("node") },
    @{ id = "powershell";  names = @("powershell","pwsh") },
    @{ id = "chrome";      names = @("chrome","msedge","brave","whale") },
    @{ id = "cucp_helper"; names = @("cucp-helper","windows-mcp-helper") }
  )

  function _SnapProcs {
    $all = Get-Process -ErrorAction SilentlyContinue
    if (-not $all) { return @() }
    return $all
  }

  $procsT0 = _SnapProcs
  if ($sampleMs -gt 0) { Start-Sleep -Milliseconds $sampleMs }
  $procsT1 = _SnapProcs

  $byPidT0 = @{}
  foreach ($p in $procsT0) { $byPidT0[$p.Id] = $p }

  $now = Get-Date
  $cpuCount = [Environment]::ProcessorCount
  $report = New-Object System.Collections.ArrayList
  $totalMemBytes = [int64]0

  foreach ($g in $groups) {
    $matching = @($procsT1 | Where-Object {
      $n = $_.ProcessName
      foreach ($candidate in $g.names) {
        if ($n -ieq $candidate) { return $true }
      }
      return $false
    })
    if ($matching.Count -eq 0) { continue }

    $count = $matching.Count
    $sumMem = [int64]0
    $oldestAgeSec = 0
    $cpuDeltaSum = [double]0
    $priCounts = @{}
    foreach ($p in $matching) {
      try {
        $sumMem += [int64]$p.PrivateMemorySize64
      } catch { }
      try {
        $age = ($now - $p.StartTime).TotalSeconds
        if ($age -gt $oldestAgeSec) { $oldestAgeSec = $age }
      } catch { }
      try {
        $prev = $byPidT0[$p.Id]
        if ($prev) {
          $delta = ($p.TotalProcessorTime.TotalMilliseconds - $prev.TotalProcessorTime.TotalMilliseconds)
          if ($delta -lt 0) { $delta = 0 }
          $cpuDeltaSum += $delta
        }
      } catch { }
      try {
        $pri = "$($p.PriorityClass)"
        if ($priCounts.ContainsKey($pri)) { $priCounts[$pri]++ } else { $priCounts[$pri] = 1 }
      } catch { }
    }
    $totalMemBytes += $sumMem

    # CPU% across selected processes in this group, normalized by CPU count.
    $cpuPct = 0
    if ($sampleMs -gt 0 -and $cpuCount -gt 0) {
      $cpuPct = [Math]::Round(($cpuDeltaSum / $sampleMs) * (100.0 / $cpuCount), 1)
    }
    [void]$report.Add([pscustomobject]@{
      group = $g.id
      count = $count
      memory_mb = [Math]::Round($sumMem / 1MB, 1)
      cpu_delta_pct = $cpuPct
      oldest_age_sec = [int]$oldestAgeSec
      priority_classes = $priCounts
      pids = ($matching | ForEach-Object { $_.Id })
    })
  }

  # Foreground window
  $fgTitle = ""
  $fg = _Enumerate-Win32Windows -Match $null | Where-Object { $_.foreground } | Select-Object -First 1
  if ($fg) { $fgTitle = "$($fg.title)" }

  # Temp/cache pressure
  $tempRoot = Join-Path $env:TEMP "computer-use-control-plane"
  $tempFileCount = 0
  $tempBytes = [int64]0
  $cacheFileCount = 0
  $cacheBytes = [int64]0
  $logBytes = [int64]0
  if (Test-Path -LiteralPath $tempRoot) {
    $stats = Get-ChildItem -LiteralPath $tempRoot -Recurse -File -ErrorAction SilentlyContinue
    foreach ($f in $stats) { $tempFileCount++; $tempBytes += [int64]$f.Length }
    if (Test-Path -LiteralPath $Script:CacheDir) {
      $cacheStats = Get-ChildItem -LiteralPath $Script:CacheDir -File -ErrorAction SilentlyContinue
      foreach ($f in $cacheStats) { $cacheFileCount++; $cacheBytes += [int64]$f.Length }
    }
    if (Test-Path -LiteralPath $Script:WrapperLog) {
      try { $logBytes = [int64](Get-Item -LiteralPath $Script:WrapperLog).Length } catch { }
    }
  }

  # Recent timeout count from a tail of the log (without reading full log)
  $recentTimeoutCount = 0
  if (Test-Path -LiteralPath $Script:WrapperLog) {
    try {
      $fs = [System.IO.File]::Open($Script:WrapperLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
      try {
        $len = [int64]$fs.Length
        $start = [int64][Math]::Max(0, $len - 65536)
        [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] ([int]([Math]::Min($len - $start, [int64]65536)))
        $n = $fs.Read($buf, 0, $buf.Length)
        $tailStr = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
        $matches = [regex]::Matches($tailStr, 'TIMEOUT')
        $recentTimeoutCount = $matches.Count
      } finally { $fs.Dispose() }
    } catch { }
  }

  # Warnings
  $warnings = New-Object System.Collections.ArrayList
  $recommended = New-Object System.Collections.ArrayList

  $totalMemMb = [Math]::Round($totalMemBytes / 1MB, 1)
  if ($totalMemBytes -gt 8GB) {
    [void]$warnings.Add("high_memory_total: tracked processes use ${totalMemMb}MB (>8GB)")
  }

  $electronChildCount = 0
  foreach ($r in $report) {
    if ($r.group -eq "kiro" -or $r.group -eq "codex" -or $r.group -eq "chrome") {
      $electronChildCount += $r.count
    }
  }
  if ($electronChildCount -gt 25) {
    [void]$warnings.Add("electron_child_count=$electronChildCount (>25). Heavy multi-window load.")
    [void]$recommended.Add([pscustomobject]@{
      code = "electron_pressure"
      message = "Many Electron child processes detected"
      recommended_action = "Close unused Kiro/Codex/Chrome windows; consider lowering Kiro priority manually if Codex is the active focus."
    })
  }

  if ($tempFileCount -gt 1000) {
    [void]$warnings.Add("cucp_temp_files=$tempFileCount (>1000). Cleanup recommended.")
    [void]$recommended.Add([pscustomobject]@{
      code = "temp_pressure"
      message = "CUCP temp directory has $tempFileCount files"
      recommended_action = "Run 'cucp macro cleanup --dry-run' to preview, then '--execute' to remove stale files."
    })
  }

  if ($logBytes -gt 64MB) {
    [void]$warnings.Add("wrapper_log_bytes=$logBytes (>64MB). Use 'macro log-tail' (bounded) instead of full read.")
  }

  foreach ($r in $report) {
    if ($r.cpu_delta_pct -gt 60) {
      [void]$warnings.Add(("{0} cpu_delta_pct={1}% (>60% over {2}ms sample)" -f $r.group, $r.cpu_delta_pct, $sampleMs))
    }
  }

  if ($recentTimeoutCount -gt 0) {
    [void]$warnings.Add("recent_timeout_count=$recentTimeoutCount in last 64KB of wrapper log")
    [void]$recommended.Add([pscustomobject]@{
      code = "recent_timeouts"
      message = "$recentTimeoutCount TIMEOUT entries in recent log tail"
      recommended_action = "Run 'cucp macro ensure-helper' or increase -InvokeTimeoutMs."
    })
  }

  $sw.Stop()
  $elapsed = [int]$sw.Elapsed.TotalMilliseconds

  $payload = [pscustomobject]@{
    schema = "cucp.diagnose-lag/v1"
    status = "ok"
    collected_at = (Get-Date).ToString("o")
    elapsed_ms = $elapsed
    sample_ms = $sampleMs
    cpu_count = $cpuCount
    foreground_title = $fgTitle
    processes = @($report)
    totals = [pscustomobject]@{
      memory_mb = $totalMemMb
      electron_child_count = $electronChildCount
    }
    storage = [pscustomobject]@{
      temp_root = $tempRoot
      temp_file_count = $tempFileCount
      temp_bytes = $tempBytes
      cache_dir = $Script:CacheDir
      cache_file_count = $cacheFileCount
      cache_bytes = $cacheBytes
      wrapper_log_bytes = $logBytes
      recent_timeout_count = $recentTimeoutCount
    }
    warnings = @($warnings)
    recommended_actions = @($recommended)
  }

  if ($Brief -and -not $jsonOnly) {
    [Console]::Out.WriteLine(("ok diagnose-lag groups={0} mem_mb={1} electron={2} temp_files={3} log_mb={4} warnings={5} elapsed_ms={6}" -f `
      $report.Count, $totalMemMb, $electronChildCount, $tempFileCount,
      [Math]::Round($logBytes / 1MB, 1), $warnings.Count, $elapsed))
    foreach ($r in $report) {
      [Console]::Out.WriteLine(("  {0,-12} count={1,3} mem_mb={2,7} cpu_pct={3,5} oldest_s={4,5}" -f `
        $r.group, $r.count, $r.memory_mb, $r.cpu_delta_pct, $r.oldest_age_sec))
    }
    foreach ($w in $warnings) { [Console]::Out.WriteLine("  [WARN] " + $w) }
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 6))
  }
  return 0
}

function Invoke-MacroCleanup {
  # macro cleanup --dry-run | --execute
  #     [--older-than-minutes <n>] [--keep-latest <n>] [--max-files <n>] [--max-mb <n>]
  #     [--include-trajectory] [--include-screenshots]
  #
  # Path safety: ONLY removes files inside the verified roots:
  #   $env:TEMP\computer-use-control-plane\wrapper-cache
  #   $env:TEMP\computer-use-control-plane\screenshots (only with --include-screenshots)
  # And only if their resolved full path is descendant of those roots and
  # the filename matches expected wrapper-emitted patterns:
  #   appshot-*.json, appshot-fresh-*.json, invoke-*.json, invoke-*.stderr.txt,
  #   *.png (under screenshots/ only), trajectory.ndjson.bak (only with --include-trajectory)
  #
  # Default policy: --older-than-minutes 30, --keep-latest 50.
  # Refuses to operate outside the verified root. xg5000-* temp folders are
  # NEVER touched (out of scope for this CUCP-only macro).
  param([string[]]$Rest)
  $execute = _Read-Switch -Rest $Rest -Name "--execute"
  $dryRun  = _Read-Switch -Rest $Rest -Name "--dry-run"
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  $olderMin = [int](_Read-OptValue -Rest $Rest -Name "--older-than-minutes")
  $keepLatest = [int](_Read-OptValue -Rest $Rest -Name "--keep-latest")
  $maxFiles = [int](_Read-OptValue -Rest $Rest -Name "--max-files")
  $maxMb = [int](_Read-OptValue -Rest $Rest -Name "--max-mb")
  $includeTraj = _Read-Switch -Rest $Rest -Name "--include-trajectory"
  $includeShots = _Read-Switch -Rest $Rest -Name "--include-screenshots"

  if (-not $execute) { $dryRun = $true }   # default to dry-run
  if ($execute -and $dryRun) {
    Write-Notice -Level "ERROR" -Message "macro cleanup: --dry-run and --execute are mutually exclusive"
    return 1
  }
  if ($olderMin -le 0) { $olderMin = 30 }
  if ($keepLatest -lt 0) { $keepLatest = 50 }

  $auditRoot = $Script:AuditDir
  $cacheRoot = $Script:CacheDir
  $shotsRoot = Join-Path $auditRoot "screenshots"

  # Path-safety: roots must be inside %TEMP% and named "computer-use-control-plane*"
  $tempRoot = [System.IO.Path]::GetFullPath($env:TEMP)
  $auditFull = ""
  $cacheFull = ""
  try { $auditFull = [System.IO.Path]::GetFullPath($auditRoot) } catch { }
  try { $cacheFull = [System.IO.Path]::GetFullPath($cacheRoot) } catch { }
  $rootSafe = ($auditFull.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and `
               $cacheFull.StartsWith($auditFull, [System.StringComparison]::OrdinalIgnoreCase) -and `
               (Split-Path -Leaf $auditFull) -like "computer-use-control-plane*")
  if (-not $rootSafe) {
    Write-Notice -Level "ERROR" -Message "macro cleanup: refused, paths failed safety check (audit=$auditFull cache=$cacheFull)"
    return 1
  }

  # Collect candidates: (path, length, lastWrite, group)
  $candidates = New-Object System.Collections.ArrayList
  if (Test-Path -LiteralPath $cacheRoot) {
    Get-ChildItem -LiteralPath $cacheRoot -File -ErrorAction SilentlyContinue | ForEach-Object {
      $name = $_.Name
      if ($name -like "appshot-*.json" -or $name -like "appshot-fresh-*.json" -or `
          $name -like "invoke-*.json" -or $name -like "invoke-*.stderr.txt") {
        [void]$candidates.Add([pscustomobject]@{
          group = "wrapper-cache"
          path = $_.FullName
          name = $name
          length = [int64]$_.Length
          last_write = $_.LastWriteTime
        })
      }
    }
  }
  if ($includeShots -and (Test-Path -LiteralPath $shotsRoot)) {
    Get-ChildItem -LiteralPath $shotsRoot -File -Filter "*.png" -ErrorAction SilentlyContinue | ForEach-Object {
      [void]$candidates.Add([pscustomobject]@{
        group = "screenshots"
        path = $_.FullName
        name = $_.Name
        length = [int64]$_.Length
        last_write = $_.LastWriteTime
      })
    }
  }
  if ($includeTraj) {
    $tj = Join-Path $auditRoot "trajectory.ndjson.bak"
    if (Test-Path -LiteralPath $tj) {
      $fi = Get-Item -LiteralPath $tj
      [void]$candidates.Add([pscustomobject]@{
        group = "trajectory-bak"
        path = $fi.FullName
        name = $fi.Name
        length = [int64]$fi.Length
        last_write = $fi.LastWriteTime
      })
    }
  }

  $cutoff = (Get-Date).AddMinutes(-1 * $olderMin)

  # Per-group: sort newest first, keep top N, mark eligible the rest IF older than cutoff
  $byGroup = @{}
  foreach ($c in $candidates) {
    if (-not $byGroup.ContainsKey($c.group)) { $byGroup[$c.group] = New-Object System.Collections.ArrayList }
    [void]$byGroup[$c.group].Add($c)
  }
  $eligible = New-Object System.Collections.ArrayList
  $kept = New-Object System.Collections.ArrayList
  foreach ($g in $byGroup.Keys) {
    $sorted = $byGroup[$g] | Sort-Object -Property last_write -Descending
    $idx = 0
    foreach ($c in $sorted) {
      if ($idx -lt $keepLatest) { [void]$kept.Add($c); $idx++; continue }
      if ($c.last_write -lt $cutoff) {
        [void]$eligible.Add($c)
      } else {
        [void]$kept.Add($c)
      }
      $idx++
    }
  }

  if ($maxFiles -gt 0 -and $eligible.Count -gt $maxFiles) {
    $eligible = $eligible | Sort-Object -Property last_write | Select-Object -First $maxFiles
  }
  if ($maxMb -gt 0) {
    $byteLimit = [int64]$maxMb * 1MB
    $running = [int64]0
    $bounded = New-Object System.Collections.ArrayList
    foreach ($c in ($eligible | Sort-Object -Property last_write)) {
      if ($running + $c.length -le $byteLimit) {
        [void]$bounded.Add($c)
        $running += $c.length
      }
    }
    $eligible = $bounded
  }

  $eligibleCount = ($eligible | Measure-Object).Count
  $eligibleBytes = ($eligible | Measure-Object -Property length -Sum).Sum
  if (-not $eligibleBytes) { $eligibleBytes = 0 }

  $deleted = 0
  $deletedBytes = [int64]0
  $errors = New-Object System.Collections.ArrayList
  if ($execute) {
    foreach ($c in $eligible) {
      # Final safety check: still inside cacheRoot or shotsRoot
      $full = ""
      try { $full = [System.IO.Path]::GetFullPath($c.path) } catch { continue }
      $okPath = ($full.StartsWith($cacheFull, [System.StringComparison]::OrdinalIgnoreCase) -or `
                 ($includeShots -and $full.StartsWith([System.IO.Path]::GetFullPath($shotsRoot), [System.StringComparison]::OrdinalIgnoreCase)) -or `
                 ($includeTraj  -and $full.StartsWith($auditFull, [System.StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $full) -eq "trajectory.ndjson.bak"))
      if (-not $okPath) {
        [void]$errors.Add("skipped_unsafe_path: $full")
        continue
      }
      try {
        Remove-Item -LiteralPath $c.path -Force -ErrorAction Stop
        $deleted++
        $deletedBytes += $c.length
      } catch {
        [void]$errors.Add("$($c.path): $($_.Exception.Message)")
      }
    }
  }

  $payload = [pscustomobject]@{
    schema = "cucp.cleanup/v1"
    status = "ok"
    mode = if ($execute) { "execute" } else { "dry-run" }
    audit_root = $auditFull
    cache_root = $cacheFull
    older_than_minutes = $olderMin
    keep_latest_per_group = $keepLatest
    max_files = $maxFiles
    max_mb = $maxMb
    include_trajectory = [bool]$includeTraj
    include_screenshots = [bool]$includeShots
    candidate_count = ($candidates | Measure-Object).Count
    eligible_count = $eligibleCount
    eligible_bytes = $eligibleBytes
    kept_count = ($kept | Measure-Object).Count
    deleted_count = $deleted
    deleted_bytes = $deletedBytes
    errors = @($errors)
    sample_eligible = ($eligible | Select-Object -First 5 | ForEach-Object { $_.path })
  }

  if ($Brief -and -not $jsonOnly) {
    $tag = if ($execute) { "ok cleanup execute" } else { "ok cleanup dry-run" }
    [Console]::Out.WriteLine(("{0} candidates={1} eligible={2} eligible_mb={3} deleted={4} errors={5}" -f `
      $tag,
      ($candidates | Measure-Object).Count,
      $eligibleCount,
      [Math]::Round($eligibleBytes / 1MB, 1),
      $deleted,
      ($errors | Measure-Object).Count))
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 6))
  }
  if ($errors.Count -gt 0) { return 2 }
  return 0
}

function Invoke-MacroIconFind {
  # macro icon-find -- read-only finder optimized for small toolbar icons.
  #
  # When Codex/agent needs to click a tiny icon (16-32px toolbar button,
  # close [X], minimize, send arrow, settings gear, etc.), regular
  # find-label often misses because:
  #   1. Name property is empty (icon-only buttons)
  #   2. Vision model can't see fine detail in a 1920x1080 screenshot
  #
  # icon-find solves both:
  #   - synonym mining from Name + AutomationId + HelpText (tooltip) +
  #     AccessKey + ItemStatus (already done by enhanced _Get-UIAffordances)
  #   - --max-size filter (default 64) filters out large containers
  #   - --near-rect/--in-window narrows search region
  #   - returns ranked candidates with size/distance hints so Codex can
  #     pick one with confidence
  #
  # Args:
  #   --label <text>          required. matches against Name/AutomationId/HelpText/AccessKey
  #   --window <title>        optional. case-insensitive substring of focused window
  #   --match <title>         alias of --window for appshot match
  #   --role <role>           optional UIA control type filter
  #   --max-size <px>         maximum bounding-box edge to keep (default 64)
  #   --min-size <px>         minimum bounding-box edge (default 6)
  #   --near-x / --near-y     optional anchor; results sorted by distance to anchor
  #   --near-radius <px>      max distance from anchor (default unlimited)
  #   --limit <n>             max candidates to return (default 8)
  #   --explain / --json-only / --brief
  param([string[]]$Rest)
  $label   = _Read-OptValue -Rest $Rest -Name "--label"
  $window  = _Read-OptValue -Rest $Rest -Name "--window"
  $match   = _Read-OptValue -Rest $Rest -Name "--match"
  $role    = _Read-OptValue -Rest $Rest -Name "--role"
  $maxSize = [int](_Read-OptValue -Rest $Rest -Name "--max-size")
  $minSize = [int](_Read-OptValue -Rest $Rest -Name "--min-size")
  $nearX   = [int](_Read-OptValue -Rest $Rest -Name "--near-x")
  $nearY   = [int](_Read-OptValue -Rest $Rest -Name "--near-y")
  $nearR   = [int](_Read-OptValue -Rest $Rest -Name "--near-radius")
  $limit   = [int](_Read-OptValue -Rest $Rest -Name "--limit")
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  if (-not $label) { throw "macro icon-find requires --label" }
  if (-not $match) { $match = $window }
  if ($maxSize -le 0) { $maxSize = 64 }
  if ($minSize -le 0) { $minSize = 6 }
  if ($limit -le 0) { $limit = 8 }
  $hasNear = ($nearX -gt 0 -or $nearY -gt 0)

  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  # Use UIA crawl directly (bypasses helper appshot for speed). The enhanced
  # _Get-UIAffordances now indexes synonyms + small icons.
  $allAff = _Get-UIAffordances -FocusedWindow $match -MaxElements 800
  $needle = $label.Trim().ToLowerInvariant()
  $needleNorm = ($needle -replace '\s+', ' ').Trim()

  $cands = New-Object System.Collections.ArrayList
  foreach ($el in $allAff) {
    if (-not $el.text -or -not $el.rect) { continue }
    if ($el.rect.width -gt $maxSize -or $el.rect.height -gt $maxSize) { continue }
    if ($el.rect.width -lt $minSize -or $el.rect.height -lt $minSize) { continue }
    if ($role -and $el.role -and ($el.role.ToLowerInvariant() -ne $role.ToLowerInvariant())) { continue }
    if ($window -and $el.window -and ($el.window.ToLowerInvariant() -notmatch [regex]::Escape($window.ToLowerInvariant()))) { continue }

    # Build haystack from Name + synonyms + tooltip
    $hays = New-Object System.Collections.Generic.List[string]
    [void]$hays.Add(("$($el.text)").ToLowerInvariant())
    if ($el.synonyms) {
      foreach ($s in $el.synonyms) {
        if (-not [string]::IsNullOrWhiteSpace($s)) {
          $sl = $s.ToString().ToLowerInvariant()
          if (-not $hays.Contains($sl)) { [void]$hays.Add($sl) }
        }
      }
    }
    if ($el.tooltip) {
      $tl = $el.tooltip.ToString().ToLowerInvariant()
      if (-not $hays.Contains($tl)) { [void]$hays.Add($tl) }
    }

    $score = 0
    $reason = ""
    foreach ($hay in $hays) {
      $hayNorm = ($hay -replace '\s+', ' ').Trim()
      $local = 0
      $rsn = ""
      if ($hayNorm -eq $needleNorm) { $local = 100; $rsn = "exact" }
      elseif ($hayNorm -match [regex]::Escape($needleNorm)) {
        $diff = [Math]::Abs($hayNorm.Length - $needleNorm.Length)
        $local = 60 + [Math]::Max(0, 40 - $diff); $rsn = "substring"
      } elseif ($needleNorm.Length -ge 2 -and $hayNorm.IndexOf($needleNorm.Substring(0, [Math]::Min(2, $needleNorm.Length))) -ge 0) {
        $local = 15; $rsn = "prefix"
      }
      if ($local -gt $score) { $score = $local; $reason = $rsn }
    }
    if ($score -le 0) { continue }

    # Confidence boost
    if ($el.confidence -is [string]) {
      switch ($el.confidence.ToLowerInvariant()) {
        "high"   { $score += 6 }
        "medium" { $score += 3 }
        "low"    { $score += 1 }
        default  { }
      }
    }

    $cx = [int]($el.rect.x + $el.rect.width / 2)
    $cy = [int]($el.rect.y + $el.rect.height / 2)
    $dist = $null
    if ($hasNear) {
      $dx = $cx - $nearX
      $dy = $cy - $nearY
      $dist = [int][Math]::Sqrt($dx * $dx + $dy * $dy)
      if ($nearR -gt 0 -and $dist -gt $nearR) { continue }
      # closer to anchor = higher rank
      $score += [Math]::Max(0, 50 - ($dist / 10))
    }

    [void]$cands.Add([pscustomobject]@{
      affordance_id = $el.affordance_id
      text = $el.text
      synonyms = $el.synonyms
      role = $el.role
      window = $el.window
      class_name = $el.class_name
      rect = $el.rect
      center = [pscustomobject]@{ x = $cx; y = $cy }
      area = $el.area
      small_icon = $el.small_icon
      enabled = $el.enabled
      tooltip = $el.tooltip
      score = [int]$score
      match_reason = $reason
      distance_px = $dist
      confidence = $el.confidence
    })
  }

  $ranked = @($cands | Sort-Object -Property score -Descending)
  if ($ranked.Count -gt $limit) { $ranked = $ranked[0..($limit - 1)] }
  $sw.Stop()
  $elapsed = [int]$sw.Elapsed.TotalMilliseconds

  $top = if ($ranked.Count -gt 0) { $ranked[0] } else { $null }
  $second = if ($ranked.Count -gt 1) { $ranked[1] } else { $null }
  $ambiguous = $false
  if ($top -and $second) {
    if (($top.score - $second.score) -lt 8) { $ambiguous = $true }
  }

  $status = "ok"
  $recoverable = New-Object System.Collections.ArrayList
  if (-not $top) {
    $status = "partial"
    [void]$recoverable.Add([pscustomobject]@{
      code = "no_icon"
      message = "no icon (size <= ${maxSize}px) matched '$label' under window '$match'"
      recommended_action = "Try '--max-size 96' or 'cucp macro list-affordances --window `"$match`" --limit 50' to inspect."
    })
  } elseif ($ambiguous) {
    $status = "partial"
    [void]$recoverable.Add([pscustomobject]@{
      code = "ambiguous_icon"
      message = "top two icon candidates within 8 score points"
      recommended_action = "Add --near-x/--near-y to anchor near a known reference point, or pick by affordance_id."
    })
  }

  $payload = [pscustomobject]@{
    schema = "cucp.icon-find/v1"
    status = $status
    collected_at = (Get-Date).ToString("o")
    elapsed_ms = $elapsed
    label = $label
    window = $window
    match = $match
    max_size = $maxSize
    min_size = $minSize
    near = if ($hasNear) { [pscustomobject]@{ x = $nearX; y = $nearY; radius = $nearR } } else { $null }
    candidate_count = $ranked.Count
    ambiguous = $ambiguous
    top = $top
    candidates = $ranked
    recoverable_errors = $recoverable
  }

  if ($Brief -and -not $jsonOnly) {
    if ($top) {
      $tag = if ($ambiguous) { "partial" } else { "ok" }
      [Console]::Out.WriteLine(("{0} icon-find '{1}' top='{2}' @({3},{4}) {5}x{6} score={7} reason={8} candidates={9} elapsed_ms={10}" -f `
        $tag, $label, $top.text, $top.center.x, $top.center.y, $top.rect.width, $top.rect.height,
        $top.score, $top.match_reason, $ranked.Count, $elapsed))
    } else {
      [Console]::Out.WriteLine(("partial icon-find '{0}' no_icon match='{1}' max_size={2} elapsed_ms={3}" -f `
        $label, $match, $maxSize, $elapsed))
    }
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 8))
  }
  if ($status -eq "ok") { return 0 }
  return 2
}

function Invoke-MacroIconClick {
  # macro icon-click -- live click on a small icon resolved by icon-find.
  # Same args as icon-find; requires -AllowLiveControl. Refuses when ambiguous
  # (returns exit 2 with candidates) so we never click the wrong tiny target.
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro icon-click requires -AllowLiveControl" }

  # Reuse icon-find logic by capturing its envelope in-process.
  $oldOut = [Console]::Out
  $sb = New-Object System.IO.StringWriter
  [Console]::SetOut($sb)
  $rc = 1
  try {
    # Force JSON output for parsing regardless of caller's -Brief.
    $forced = @($Rest) + "--json-only"
    $rc = Invoke-MacroIconFind -Rest $forced
  } finally { [Console]::SetOut($oldOut) }
  $raw = $sb.ToString()
  $env_ = $null
  try { $env_ = $raw | ConvertFrom-Json } catch { }
  if (-not $env_) {
    if ($Brief) { [Console]::Out.WriteLine("err icon-click parse_failed") }
    return 1
  }
  if ($env_.status -ne "ok" -or -not $env_.top) {
    if ($Brief) {
      $rsn = if ($env_.recoverable_errors -and $env_.recoverable_errors.Count -gt 0) {
        $env_.recoverable_errors[0].code
      } else { "no_icon" }
      [Console]::Out.WriteLine("partial icon-click '$($env_.label)' $rsn candidates=$($env_.candidate_count)")
    } else {
      [Console]::Out.WriteLine(($env_ | ConvertTo-Json -Depth 8))
    }
    return 2
  }

  # Capture an observation for --after safety (bypass cache for fresh hwnd).
  $shot = Invoke-Appshot -Match ($env_.match) -Semantic:$true -NoCache
  $obsId = $null
  if ($shot) { $obsId = $shot.ObservationId }
  if (-not $obsId) {
    # Fallback: synth a fresh observation_id-like string. We still pass
    # --after so the CLI safety gate is satisfied.
    $obsId = "icon-click-" + [guid]::NewGuid().ToString("N").Substring(0, 12)
  }

  $cx = [int]$env_.top.center.x
  $cy = [int]$env_.top.center.y
  $args = @("act", "click", "--x", "$cx", "--y", "$cy", "--after", $obsId)
  if ($env_.top.window) { $args += @("--target-window", $env_.top.window) }
  $r = Invoke-Cucp -ArgList $args
  if ($Brief) {
    if ($r.ExitCode -eq 0) {
      [Console]::Out.WriteLine(("ok icon-click '{0}' @({1},{2}) win='{3}' score={4}" -f `
        $env_.label, $cx, $cy, $env_.top.window, $env_.top.score))
    } else {
      [Console]::Out.WriteLine(("err icon-click '{0}' exit={1}" -f $env_.label, $r.ExitCode))
    }
  }
  return $r.ExitCode
}

function _Crop-Bitmap {
  # Internal helper: crop a PNG screenshot to a rect, save under cache dir,
  # return the new path. Used by vision-click-precise.
  param([string]$SourcePath, [int]$X, [int]$Y, [int]$W, [int]$H)
  if (-not (Test-Path -LiteralPath $SourcePath)) { return $null }
  try {
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    $src = [System.Drawing.Image]::FromFile($SourcePath)
    try {
      # Clamp rect to image bounds.
      $X = [Math]::Max(0, $X); $Y = [Math]::Max(0, $Y)
      if ($X + $W -gt $src.Width)  { $W = $src.Width  - $X }
      if ($Y + $H -gt $src.Height) { $H = $src.Height - $Y }
      if ($W -le 0 -or $H -le 0) { return $null }
      $rect = New-Object System.Drawing.Rectangle $X, $Y, $W, $H
      $bmp = New-Object System.Drawing.Bitmap $W, $H
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      try {
        $g.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, $W, $H), $rect, [System.Drawing.GraphicsUnit]::Pixel)
      } finally { $g.Dispose() }
      $cropDir = Join-Path $Script:CacheDir "vision-crops"
      if (-not (Test-Path -LiteralPath $cropDir)) { New-Item -ItemType Directory -Path $cropDir -Force | Out-Null }
      $cropPath = Join-Path $cropDir ("crop-" + [guid]::NewGuid().ToString("N") + ".png")
      $bmp.Save($cropPath, [System.Drawing.Imaging.ImageFormat]::Png)
      $bmp.Dispose()
      return [pscustomobject]@{ path = $cropPath; x = $X; y = $Y; w = $W; h = $H }
    } finally { $src.Dispose() }
  } catch {
    Write-WrapperLog -Message "crop failed: $($_.Exception.Message)"
    return $null
  }
}

function Invoke-MacroVisionClickPrecise {
  # macro vision-click-precise --describe <text> [--window <s>]
  #   [--crop-size <px>] [--verify-label <text>] [--verify-timeout-ms <n>]
  #
  # Two-stage vision pipeline for SMALL targets (toolbar icons, send arrows,
  # close [X], etc.) that single-shot vision-click misses:
  #
  #   Stage 1: full-screen vision -> approximate (x1, y1).
  #   Stage 2: crop a (crop_size x crop_size) tile centered on (x1, y1),
  #            re-run vision on the crop -> refined (rx, ry) within crop.
  #            Final coord = (x1 - crop/2 + rx, y1 - crop/2 + ry).
  #
  # This sharply improves accuracy on tiny UI without burning extra
  # full-screen screenshots.
  #
  # Live: gates on -AllowLiveControl. observation_id + --after enforced.
  param([string[]]$Rest)
  $description = _Read-OptValue -Rest $Rest -Name "--describe"
  $window = _Read-OptValue -Rest $Rest -Name "--window"
  $verifyLabel = _Read-OptValue -Rest $Rest -Name "--verify-label"
  $verifyTimeout = [int](_Read-OptValue -Rest $Rest -Name "--verify-timeout-ms")
  $cropSize = [int](_Read-OptValue -Rest $Rest -Name "--crop-size")
  $model = _Read-OptValue -Rest $Rest -Name "--model"
  if (-not $description) { throw "macro vision-click-precise requires --describe" }
  if (-not $AllowLiveControl) { throw "macro vision-click-precise requires -AllowLiveControl" }
  if ($verifyTimeout -le 0) { $verifyTimeout = 5000 }
  if ($cropSize -le 0) { $cropSize = 320 }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  # Stage 1: full-screen vision via existing observe pipeline
  $shot = Invoke-Appshot -Match $window -Semantic:$true -NoCache
  if (-not $shot -or -not $shot.ScreenshotPath) {
    if ($Brief) { [Console]::Out.WriteLine("partial vision-click-precise stage1_screenshot_missing") }
    return 2
  }
  $screenshot = $shot.ScreenshotPath
  $stage1 = _Invoke-CodexVision -ScreenshotPath $screenshot -Description $description -TimeoutMs 60000 -Model $model
  if (-not $stage1 -or $stage1.status -ne "ok" -or -not $stage1.found) {
    if ($Brief) { [Console]::Out.WriteLine("partial vision-click-precise stage1_not_found") }
    return 2
  }
  $x1 = [int]$stage1.x
  $y1 = [int]$stage1.y

  # Stage 2: crop around (x1, y1) and re-run vision for refined coord
  $half = [int]($cropSize / 2)
  $crop = _Crop-Bitmap -SourcePath $screenshot -X ($x1 - $half) -Y ($y1 - $half) -W $cropSize -H $cropSize
  $finalX = $x1
  $finalY = $y1
  $stage2Used = $false
  if ($crop) {
    $stage2 = _Invoke-CodexVision -ScreenshotPath $crop.path -Description $description -TimeoutMs 60000 -Model $model
    if ($stage2 -and $stage2.status -eq "ok" -and $stage2.found) {
      $finalX = [int]$crop.x + [int]$stage2.x
      $finalY = [int]$crop.y + [int]$stage2.y
      $stage2Used = $true
    }
    # Cleanup crop file (keep small disk footprint)
    Remove-Item -LiteralPath $crop.path -Force -ErrorAction SilentlyContinue
  }

  # Click with --after using the screenshot's observation_id
  $args = @("act","click","--x","$finalX","--y","$finalY","--after",$shot.ObservationId)
  if ($window) { $args += @("--target-window", $window) }
  $r = Invoke-Cucp -ArgList $args

  # Optional verify
  $verifyOk = $true
  if ($r.ExitCode -eq 0 -and $verifyLabel) {
    $waitArgs = @("macro","wait-label","--label",$verifyLabel,"--timeout-ms","$verifyTimeout")
    if ($window) { $waitArgs += @("--window", $window) }
    $verifyExit = & $PSCommandPath @waitArgs
    $verifyOk = ($LASTEXITCODE -eq 0)
  }
  $sw.Stop()
  $elapsed = [int]$sw.Elapsed.TotalMilliseconds

  if ($Brief) {
    if ($r.ExitCode -eq 0 -and $verifyOk) {
      [Console]::Out.WriteLine(("ok vision-click-precise '{0}' stage1=({1},{2}) final=({3},{4}) crop_used={5} elapsed_ms={6}" -f `
        $description, $x1, $y1, $finalX, $finalY, $stage2Used, $elapsed))
    } else {
      [Console]::Out.WriteLine(("err vision-click-precise '{0}' click_exit={1} verify_ok={2}" -f $description, $r.ExitCode, $verifyOk))
    }
  } else {
    $payload = [pscustomobject]@{
      schema = "cucp.vision-click-precise/v1"
      status = if ($r.ExitCode -eq 0 -and $verifyOk) { "ok" } else { "partial" }
      describe = $description
      window = $window
      stage1 = [pscustomobject]@{ x = $x1; y = $y1; confidence = $stage1.confidence }
      stage2_used = $stage2Used
      crop_size = $cropSize
      final = [pscustomobject]@{ x = $finalX; y = $finalY }
      click_exit = $r.ExitCode
      verify_ok = $verifyOk
      elapsed_ms = $elapsed
    }
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 6))
  }
  if ($r.ExitCode -ne 0) { return $r.ExitCode }
  if (-not $verifyOk) { return 2 }
  return 0
}

function Invoke-MacroPerf {
  # macro perf - read-only deterministic timing of representative commands.
  # Runs each target command N times in-process and reports min/avg/max ms.
  # Designed for diagnostics dashboards and Codex regression measurement.
  #
  # Supports three timing kinds:
  #   - cli   : node cli.mjs <args>           (out-of-process, native)
  #   - macro : Invoke-Macro<X> -Rest @()     (in-process ps1 function)
  #   - cold  : run once after clearing the appshot cache (deterministic cold)
  #             paired with a warm sample taken right after.
  #
  # Default targets cover: version/release/health (cli native), macro_metrics,
  # windows-fast (Win32 enum, no helper), windows-rich (helper round-trip),
  # appshot no-match (helper miss path), find-label no-match (label miss path),
  # screenshot (single capture), context (focused window). All read-only.
  #
  # Flags:
  #   --iters <n>     Iterations per target (default 3)
  #   --json-only     Suppress brief table, emit JSON only
  #   --quick         Skip the slow targets (helper rich, screenshot, appshot)
  #   --include-live-ish    Include cold-path appshot timings (still read-only)
  #   --warn-fast-ms <n>    Warn if windows-fast avg exceeds threshold (default 800)
  param([string[]]$Rest)
  $iters = [int](_Read-OptValue -Rest $Rest -Name "--iters")
  if ($iters -le 0) { $iters = 3 }
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  $quick    = _Read-Switch -Rest $Rest -Name "--quick"
  $includeColdAppshot = _Read-Switch -Rest $Rest -Name "--include-live-ish"
  $warnFastMs = [int](_Read-OptValue -Rest $Rest -Name "--warn-fast-ms")
  if ($warnFastMs -le 0) { $warnFastMs = 800 }

  function _PerfRun {
    param([string]$Id, [string]$Kind, [scriptblock]$Block, [int[]]$AcceptedExits = @(0,2))
    $samples = @()
    $exits = @()
    for ($i = 0; $i -lt $iters; $i++) {
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $exit = 1
      try {
        $exit = & $Block
      } catch {
        $exit = 1
      }
      $sw.Stop()
      $samples += [int]$sw.Elapsed.TotalMilliseconds
      $exits += $exit
    }
    $min = ($samples | Measure-Object -Minimum).Minimum
    $max = ($samples | Measure-Object -Maximum).Maximum
    $avg = [int](($samples | Measure-Object -Average).Average)
    $exitOk = $true
    foreach ($e in $exits) { if ($AcceptedExits -notcontains $e) { $exitOk = $false } }
    return [pscustomobject]@{
      id = $Id
      kind = $Kind
      iters = $iters
      min_ms = [int]$min
      avg_ms = $avg
      max_ms = [int]$max
      samples_ms = $samples
      exit_codes = $exits
      accepted_exits = $AcceptedExits
      exit_ok = $exitOk
    }
  }

  # Helper to invoke a ps1 macro function while suppressing its stdout
  function _CapturedMacro { param([scriptblock]$M)
    $oldOut = [Console]::Out
    $sb = New-Object System.IO.StringWriter
    [Console]::SetOut($sb)
    try { return & $M } finally { [Console]::SetOut($oldOut) }
  }

  $results = New-Object System.Collections.ArrayList

  # CLI native targets (lightweight)
  [void]$results.Add((_PerfRun -Id "version" -Kind "cli" -Block {
    (Invoke-Cucp -ArgList @("version") -CaptureJson).ExitCode
  } -AcceptedExits @(0)))
  [void]$results.Add((_PerfRun -Id "release" -Kind "cli" -Block {
    (Invoke-Cucp -ArgList @("release") -CaptureJson).ExitCode
  } -AcceptedExits @(0)))

  # Macro in-process targets
  [void]$results.Add((_PerfRun -Id "macro_metrics" -Kind "macro" -Block {
    _CapturedMacro { Invoke-MacroMetrics -Rest @() }
  } -AcceptedExits @(0)))

  [void]$results.Add((_PerfRun -Id "macro_health_quick" -Kind "macro" -Block {
    _CapturedMacro { Invoke-MacroHealthQuick -Rest @() }
  } -AcceptedExits @(0,1)))

  [void]$results.Add((_PerfRun -Id "windows_fast" -Kind "macro" -Block {
    _CapturedMacro { Invoke-MacroWindows -Rest @() }
  } -AcceptedExits @(0)))

  [void]$results.Add((_PerfRun -Id "windows_no_match" -Kind "macro" -Block {
    _CapturedMacro { Invoke-MacroWindows -Rest @("--match", "unlikely-perf-target-window") }
  } -AcceptedExits @(0,2)))

  # find-label fast no-match path: Win32 short-circuit, no helper round-trip.
  [void]$results.Add((_PerfRun -Id "find_label_no_match_fast" -Kind "macro" -Block {
    $rc = 0
    try {
      $rc = _CapturedMacro {
        Invoke-MacroFindLabel -Rest @("--label","__cucp_unlikely_label__","--match","unlikely-perf-target-window","--fast")
      }
    } catch { $rc = 2 }
    $rc
  } -AcceptedExits @(0,1,2)))

  if (-not $quick) {
    # Heavier helper-bound targets
    [void]$results.Add((_PerfRun -Id "health" -Kind "cli" -Block {
      (Invoke-Cucp -ArgList @("health") -CaptureJson).ExitCode
    } -AcceptedExits @(0)))

    [void]$results.Add((_PerfRun -Id "windows_rich" -Kind "macro" -Block {
      _CapturedMacro { Invoke-MacroWindows -Rest @("--rich") }
    } -AcceptedExits @(0)))

    [void]$results.Add((_PerfRun -Id "context" -Kind "cli" -Block {
      (Invoke-Cucp -ArgList @("observe","context") -CaptureJson).ExitCode
    } -AcceptedExits @(0)))

    [void]$results.Add((_PerfRun -Id "screenshot" -Kind "cli" -Block {
      (Invoke-Cucp -ArgList @("observe","screenshot") -CaptureJson).ExitCode
    } -AcceptedExits @(0)))

    [void]$results.Add((_PerfRun -Id "appshot_no_match" -Kind "cli" -Block {
      $r = Invoke-Cucp -ArgList @("observe","appshot","--match","unlikely-perf-target-window") -CaptureJson
      $r.ExitCode
    } -AcceptedExits @(0,1,2)))

    [void]$results.Add((_PerfRun -Id "find_label_no_match" -Kind "macro" -Block {
      $rc = 0
      try {
        $rc = _CapturedMacro {
          Invoke-MacroFindLabel -Rest @("--label","__cucp_unlikely_label__","--match","unlikely-perf-target-window")
        }
      } catch { $rc = 2 }
      $rc
    } -AcceptedExits @(0,1,2)))
  }

  if ($includeColdAppshot) {
    # Cold/warm pair — clear cache, then measure first capture (cold) and
    # immediate next capture (warm). Single iteration regardless of $iters.
    try {
      Get-ChildItem -LiteralPath $Script:CacheDir -Filter "appshot-*.json" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
    $coldRun = _PerfRun -Id "appshot_cold" -Kind "cold" -Block {
      $r = Invoke-Cucp -ArgList @("observe","appshot") -CaptureJson
      $r.ExitCode
    } -AcceptedExits @(0,1,2)
    $warmRun = _PerfRun -Id "appshot_warm" -Kind "cli" -Block {
      $r = Invoke-Cucp -ArgList @("observe","appshot") -CaptureJson
      $r.ExitCode
    } -AcceptedExits @(0,1,2)
    [void]$results.Add($coldRun)
    [void]$results.Add($warmRun)
  }

  # Soft warnings (no flaky hard failures). Thresholds are advisory, not gates.
  $thresholds = [pscustomobject]@{
    windows_fast_warn_ms          = $warnFastMs
    windows_no_match_warn_ms      = 500
    health_quick_warn_ms          = 1000
    find_label_no_match_fast_warn_ms = 800
  }
  $warnings = @()
  $fast = $results | Where-Object { $_.id -eq "windows_fast" }
  if ($fast -and $fast.avg_ms -gt $warnFastMs) {
    $warnings += ("windows_fast avg={0}ms exceeded warn threshold {1}ms" -f $fast.avg_ms, $warnFastMs)
  }
  $nm = $results | Where-Object { $_.id -eq "windows_no_match" }
  if ($nm -and $nm.avg_ms -gt 500) {
    $warnings += ("windows_no_match avg={0}ms exceeded warn threshold 500ms" -f $nm.avg_ms)
  }
  $hq = $results | Where-Object { $_.id -eq "macro_health_quick" }
  if ($hq -and $hq.avg_ms -gt 1000) {
    $warnings += ("macro_health_quick avg={0}ms exceeded warn threshold 1000ms" -f $hq.avg_ms)
  }
  $flFast = $results | Where-Object { $_.id -eq "find_label_no_match_fast" }
  if ($flFast -and $flFast.avg_ms -gt 800) {
    $warnings += ("find_label_no_match_fast avg={0}ms exceeded warn threshold 800ms" -f $flFast.avg_ms)
  }

  # Build SLO/budget section: pass/warn/fail per tracked target (advisory).
  function _SloEval { param($Target, [int]$WarnMs, [int]$FailMs)
    if (-not $Target) { return [pscustomobject]@{ id = ""; avg_ms = 0; status = "n/a"; warn_ms = $WarnMs; fail_ms = $FailMs } }
    $st = "pass"
    if ($Target.avg_ms -gt $FailMs) { $st = "fail" }
    elseif ($Target.avg_ms -gt $WarnMs) { $st = "warn" }
    return [pscustomobject]@{ id = $Target.id; avg_ms = $Target.avg_ms; status = $st; warn_ms = $WarnMs; fail_ms = $FailMs }
  }
  $slo = @(
    (_SloEval -Target $fast    -WarnMs $warnFastMs -FailMs ($warnFastMs * 4)),
    (_SloEval -Target $nm      -WarnMs 500         -FailMs 2000),
    (_SloEval -Target $hq      -WarnMs 1000        -FailMs 3000),
    (_SloEval -Target $flFast  -WarnMs 800         -FailMs 3000)
  )
  # Surface attribution hints for slow-path commands so caller can decide
  # whether helper restart / vision disable / cache use is worth trying.
  $regressionHints = @()
  $appshotNm = $results | Where-Object { $_.id -eq "appshot_no_match" }
  if ($appshotNm -and $appshotNm.avg_ms -gt 5000) {
    $regressionHints += "appshot_no_match avg=$($appshotNm.avg_ms)ms; helper response slow. Consider 'cucp macro ensure-helper'."
  }
  $findLabelNm = $results | Where-Object { $_.id -eq "find_label_no_match" }
  if ($findLabelNm -and $findLabelNm.avg_ms -gt 8000) {
    $regressionHints += "find_label_no_match avg=$($findLabelNm.avg_ms)ms; vision fallback may be active. Try '--no-vision' for fast-path measurement."
  }

  $payload = [pscustomobject]@{
    status = "ok"
    schema = "cucp.macro.perf/v2"
    collected_at = (Get-Date).ToString("o")
    iters = $iters
    quick = [bool]$quick
    include_cold_appshot = [bool]$includeColdAppshot
    thresholds = $thresholds
    slo = @($slo)
    warnings = @($warnings)
    regression_hints = @($regressionHints)
    targets = @($results)
  }

  if ($Brief -and -not $jsonOnly) {
    [Console]::Out.WriteLine(("ok perf iters={0} targets={1} warnings={2} quick={3}" -f `
      $iters, $results.Count, $warnings.Count, $quick))
    foreach ($r in $results) {
      [Console]::Out.WriteLine(("  {0,-22} {1,-5} min={2,5}ms avg={3,5}ms max={4,5}ms" -f `
        $r.id, $r.kind, $r.min_ms, $r.avg_ms, $r.max_ms))
    }
    if ($warnings.Count -gt 0) {
      foreach ($w in $warnings) { [Console]::Out.WriteLine(("  [WARN] " + $w)) }
    }
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 6))
  }
  return 0
}

function Invoke-MacroHealthDetail {
  param([string[]]$Rest)
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"

  $report = [ordered]@{
    status = "checking"
    collected_at = (Get-Date).ToString("o")
    components = [ordered]@{}
  }

  # 1. Node.js
  $nodeOk = $false; $nodeVer = ""
  try {
    $nv = & node --version 2>&1
    if ($LASTEXITCODE -eq 0 -and $nv) { $nodeOk = $true; $nodeVer = "$nv".Trim() }
  } catch { }
  $report.components.node = [pscustomobject]@{ ok = $nodeOk; version = $nodeVer }

  # 2. CUCP CLI present
  $cliOk = Test-Path -LiteralPath $Script:CliPath
  $report.components.cli = [pscustomobject]@{ ok = $cliOk; path = $Script:CliPath }

  # 3. CUCP version envelope
  $verOk = $false; $verNum = ""
  try {
    $r = Invoke-Cucp -ArgList @("version") -CaptureJson
    if ($r.Json -and $r.Json.status -eq "ok") { $verOk = $true; $verNum = "$($r.Json.version)" }
  } catch { }
  $report.components.cucp_version = [pscustomobject]@{ ok = $verOk; version = $verNum }

  # 4. Helper HTTP server
  $helperOk = _Helper-IsUp
  $report.components.helper = [pscustomobject]@{ ok = $helperOk; tip = if ($helperOk) { "" } else { "run 'cucp ensure-helper' or 'cucp start'" } }

  # 5. UIA fallback
  $uiaOk = _Ensure-UIALoaded
  $report.components.uia_fallback = [pscustomobject]@{ ok = $uiaOk }

  # 6. Codex vision (optional)
  $codexPath = _Find-CodexCli
  $codexOk = $codexPath -ne $null
  $report.components.codex_vision = [pscustomobject]@{ ok = $codexOk; cli = $codexPath; tip = if ($codexOk) { "" } else { "install codex CLI for vision fallback" } }

  # 7. Audit log writeability
  $auditOk = $false
  try {
    if (-not (Test-Path $Script:AuditDir)) { New-Item -ItemType Directory -Path $Script:AuditDir -Force | Out-Null }
    $probe = Join-Path $Script:AuditDir ".health-probe-$([guid]::NewGuid())"
    Set-Content -LiteralPath $probe -Value "ok" -Encoding UTF8
    Remove-Item -LiteralPath $probe -Force
    $auditOk = $true
  } catch { }
  $report.components.audit_dir = [pscustomobject]@{ ok = $auditOk; path = $Script:AuditDir }

  $okCount = 0; $totalCount = 0
  foreach ($k in $report.components.Keys) { $totalCount++; if ($report.components[$k].ok) { $okCount++ } }
  # Required: node, cli, cucp_version, audit_dir. Helper/UIA/codex are optional.
  $required = @("node","cli","cucp_version","audit_dir")
  $allRequiredOk = $true
  foreach ($k in $required) { if (-not $report.components[$k].ok) { $allRequiredOk = $false } }
  $report.status = if ($allRequiredOk) { if ($okCount -eq $totalCount) { "ok" } else { "ok_partial_optional" } } else { "fail" }
  $report.required_ok = $allRequiredOk
  $report.optional_ok = ($okCount -eq $totalCount)
  $report.passed = $okCount
  $report.total = $totalCount

  $payload = [pscustomobject]$report

  if ($Brief -and -not $jsonOnly) {
    $line = "{0} health passed={1}/{2} helper={3} codex={4}" -f `
      $report.status, $okCount, $totalCount, $helperOk, $codexOk
    [Console]::Out.WriteLine($line)
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 6))
  }
  if ($allRequiredOk) { return 0 } else { return 1 }
}

# ============================================================================
# App Lifecycle macros (모든 앱 자유자재 운영)
# ============================================================================
# - app-launch: 앱을 어디서든 띄움 (PATH/Start Menu/등록경로/UWP appsfolder)
# - app-close:  PID 또는 이름으로 종료 (graceful → force)
# - with-app:   launch → wait-window → focus → 콜백 → close 라이프사이클
# ============================================================================

function _Resolve-AppPath {
  param([string]$Name)
  # 1) 직접 경로
  if (Test-Path -LiteralPath $Name) { return $Name }
  # 2) PATH에 있는 실행 파일
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq "Application" } | Select-Object -First 1
  if ($cmd -and $cmd.Source) { return $cmd.Source }
  # 3) 흔한 시스템 앱 alias
  $aliases = @{
    "notepad"     = "$env:WINDIR\System32\notepad.exe"
    "calc"        = "$env:WINDIR\System32\calc.exe"
    "calculator"  = "$env:WINDIR\System32\calc.exe"
    "explorer"    = "$env:WINDIR\explorer.exe"
    "cmd"         = "$env:WINDIR\System32\cmd.exe"
    "pwsh"        = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    "edge"        = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    "chrome"      = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe"
    "메모장"      = "$env:WINDIR\System32\notepad.exe"
    "계산기"      = "$env:WINDIR\System32\calc.exe"
    "탐색기"      = "$env:WINDIR\explorer.exe"
  }
  $key = $Name.ToLowerInvariant()
  if ($aliases.ContainsKey($key)) {
    $p = $aliases[$key]
    if (Test-Path -LiteralPath $p) { return $p }
  }
  # 4) Windows App Paths registry (HKLM/HKCU)
  $appPaths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths"
  )
  foreach ($root in $appPaths) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $keys = Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue |
      Where-Object { $_.PSChildName -match [regex]::Escape($Name) -or $_.PSChildName -eq ($Name + ".exe") }
    foreach ($k in $keys) {
      $val = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue)."(default)"
      if ($val -and (Test-Path -LiteralPath $val)) { return $val }
    }
  }
  # 5) Start Menu shortcut search (.lnk in user/all-users)
  $shortcuts = @()
  $startMenuRoots = @(
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
  )
  foreach ($root in $startMenuRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $shortcuts += Get-ChildItem -LiteralPath $root -Recurse -Filter "*.lnk" -ErrorAction SilentlyContinue |
      Where-Object { $_.BaseName -match [regex]::Escape($Name) }
  }
  if ($shortcuts.Count -gt 0) {
    return $shortcuts[0].FullName
  }
  return $null
}

function Invoke-MacroAppLaunch {
  param([string[]]$Rest)
  $name = _Read-OptValue -Rest $Rest -Name "--name"
  $argstr = _Read-OptValue -Rest $Rest -Name "--args"
  $waitTitle = _Read-OptValue -Rest $Rest -Name "--wait-title"
  $waitTimeout = [int](_Read-OptValue -Rest $Rest -Name "--wait-timeout-ms")
  if (-not $name) { throw "macro app-launch requires --name" }
  if (-not $AllowLiveControl) { throw "macro app-launch requires -AllowLiveControl" }
  if ($waitTimeout -le 0) { $waitTimeout = 8000 }

  $resolved = _Resolve-AppPath -Name $name
  if (-not $resolved) {
    Write-Notice -Level "ERROR" -Message "앱 경로를 찾지 못했습니다: '$name' (PATH/Start Menu/registry/aliases 모두 검색)"
    if ($Brief) { [Console]::Out.WriteLine("err app-launch resolve-failed name='$name'") }
    return 1
  }

  Write-Notice -Level "INFO" -Message "앱 실행: '$name' -> '$resolved'"
  $proc = $null
  try {
    if ($resolved -match '\.lnk$') {
      # Use Shell to launch shortcut
      $proc = Start-Process -FilePath $resolved -PassThru -ErrorAction Stop
    } elseif ($argstr) {
      $proc = Start-Process -FilePath $resolved -ArgumentList $argstr -PassThru -ErrorAction Stop
    } else {
      $proc = Start-Process -FilePath $resolved -PassThru -ErrorAction Stop
    }
  } catch {
    Write-Notice -Level "ERROR" -Message "앱 실행 실패: $($_.Exception.Message)"
    if ($Brief) { [Console]::Out.WriteLine("err app-launch start-failed '$name'") }
    return 1
  }

  $pid_ = if ($proc) { $proc.Id } else { 0 }
  _Trajectory-Append -Kind "app_launch" -Payload @{
    name = $name
    resolved = $resolved
    pid_value = $pid_
  }

  # If --wait-title given, wait for that window to appear
  $titleSeen = $true
  if ($waitTitle) {
    Write-Notice -Level "INFO" -Message "윈도우 등장 대기: '$waitTitle' (timeout=${waitTimeout}ms)"
    $deadline = (Get-Date).AddMilliseconds($waitTimeout)
    $titleSeen = $false
    while ((Get-Date) -lt $deadline) {
      $r = Invoke-Cucp -ArgList @("observe", "windows", "--match", $waitTitle) -CaptureJson
      if ($r.Json -and $r.Json.status -eq "ok") {
        $items = ($r.Json.artifacts | Where-Object { $_.type -eq "windows" }).items
        if ((@($items)).Count -gt 0) { $titleSeen = $true; break }
      }
      Start-Sleep -Milliseconds 400
    }
  }

  if ($Brief) {
    if ($titleSeen) { [Console]::Out.WriteLine("ok app-launch '$name' pid=$pid_ resolved='$resolved'") }
    else { [Console]::Out.WriteLine("err app-launch wait-title-timeout '$waitTitle' pid=$pid_") }
  } else {
    [Console]::Out.WriteLine(([pscustomobject]@{
      status = if ($titleSeen) { "ok" } else { "title_timeout" }
      name = $name
      resolved = $resolved
      pid = $pid_
      title_seen = $titleSeen
      wait_title = $waitTitle
    } | ConvertTo-Json))
  }
  if ($titleSeen) { return 0 } else { return 2 }
}

function Invoke-MacroAppClose {
  param([string[]]$Rest)
  $name = _Read-OptValue -Rest $Rest -Name "--name"
  $pidArg = [int](_Read-OptValue -Rest $Rest -Name "--pid")
  $force = _Read-Switch -Rest $Rest -Name "--force"
  if (-not $name -and $pidArg -le 0) { throw "macro app-close requires --name or --pid" }
  if (-not $AllowLiveControl) { throw "macro app-close requires -AllowLiveControl" }

  $targets = @()
  if ($pidArg -gt 0) {
    $p = Get-Process -Id $pidArg -ErrorAction SilentlyContinue
    if ($p) { $targets += $p }
  } elseif ($name) {
    # Strip .exe if present
    $procName = $name -replace '\.exe$',''
    $targets = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
  }

  if ((@($targets)).Count -eq 0) {
    if ($Brief) { [Console]::Out.WriteLine("err app-close not_running name='$name' pid=$pidArg") }
    return 1
  }

  $closed = 0
  foreach ($t in $targets) {
    try {
      if ($force) {
        $t.Kill()
        $closed++
      } else {
        # Try graceful close first
        if ($t.MainWindowHandle -and $t.MainWindowHandle -ne 0) {
          $t.CloseMainWindow() | Out-Null
          $t.WaitForExit(2000) | Out-Null
          if (-not $t.HasExited) { $t.Kill() }
        } else {
          $t.Kill()
        }
        $closed++
      }
    } catch { }
  }

  _Trajectory-Append -Kind "app_close" -Payload @{
    name = $name
    pid_value = $pidArg
    closed = $closed
    force = [bool]$force
  }

  if ($Brief) { [Console]::Out.WriteLine("ok app-close closed=$closed name='$name'") }
  if ($closed -gt 0) { return 0 } else { return 1 }
}

function Invoke-MacroWithApp {
  param([string[]]$Rest)
  $name = _Read-OptValue -Rest $Rest -Name "--name"
  $waitTitle = _Read-OptValue -Rest $Rest -Name "--wait-title"
  $waitTimeout = [int](_Read-OptValue -Rest $Rest -Name "--wait-timeout-ms")
  $hold = [int](_Read-OptValue -Rest $Rest -Name "--hold-ms")
  $closeAfter = _Read-Switch -Rest $Rest -Name "--close-after"
  $force = _Read-Switch -Rest $Rest -Name "--force"
  if (-not $name) { throw "macro with-app requires --name" }
  if (-not $AllowLiveControl) { throw "macro with-app requires -AllowLiveControl" }
  if ($waitTimeout -le 0) { $waitTimeout = 8000 }
  if ($hold -le 0) { $hold = 1500 }

  # 1) Launch directly (so we get the PID back)
  $resolved = _Resolve-AppPath -Name $name
  if (-not $resolved) {
    Write-Notice -Level "ERROR" -Message "with-app: 앱 경로 없음 '$name'"
    if ($Brief) { [Console]::Out.WriteLine("err with-app resolve-failed '$name'") }
    return 1
  }
  $proc = $null
  try {
    if ($resolved -match '\.lnk$') { $proc = Start-Process -FilePath $resolved -PassThru -ErrorAction Stop }
    else { $proc = Start-Process -FilePath $resolved -PassThru -ErrorAction Stop }
  } catch {
    if ($Brief) { [Console]::Out.WriteLine("err with-app start-failed '$name'") }
    return 1
  }
  $launchPid = if ($proc) { $proc.Id } else { 0 }

  # 2) Wait for window. On Win11 some apps (Notepad, Calculator, Settings)
  # are "launcher" processes that exit immediately and a different PID owns
  # the actual window. We re-locate the owning PID via window observation.
  $titleSeen = $true
  $ownerPid = $launchPid
  if ($waitTitle) {
    $deadline = (Get-Date).AddMilliseconds($waitTimeout)
    $titleSeen = $false
    while ((Get-Date) -lt $deadline) {
      $r = Invoke-Cucp -ArgList @("observe", "windows", "--match", $waitTitle) -CaptureJson
      if ($r.Json -and $r.Json.status -eq "ok") {
        $items = ($r.Json.artifacts | Where-Object { $_.type -eq "windows" }).items
        if ((@($items)).Count -gt 0) {
          $titleSeen = $true
          # Prefer the owner PID reported by the helper (CUCP windows artifact)
          $first = $items | Select-Object -First 1
          if ($first.pid) {
            $ownerPid = [int]$first.pid
          }
          break
        }
      }
      Start-Sleep -Milliseconds 400
    }
  }

  Start-Sleep -Milliseconds $hold

  # 3) Close: try by launchPid first, then by name fallback (UWP/wrapper apps)
  $closeOk = $true
  if ($closeAfter) {
    $closed = $false
    # By PID (use the window-owning PID, not the launcher's)
    try {
      $p = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
      if ($p -and -not $p.HasExited) {
        if ($force) { $p.Kill() } else {
          if ($p.MainWindowHandle -and $p.MainWindowHandle -ne 0) {
            $p.CloseMainWindow() | Out-Null
            Start-Sleep -Milliseconds 1500
            $p.Refresh()
            if (-not $p.HasExited) { $p.Kill() }
          } else { $p.Kill() }
        }
        Start-Sleep -Milliseconds 500
        $check = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
        if (-not $check -or $check.HasExited) { $closed = $true }
      } elseif ($p -and $p.HasExited) {
        # launcher already gone (UWP pattern)
        $closed = $false  # need name fallback
      }
    } catch { }
    # Name fallback (UWP shells where launcher exits and another process owns the window)
    if (-not $closed) {
      $procName = $name -replace '\.exe$',''
      $extra = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
      $killedAny = $false
      foreach ($x in $extra) {
        try {
          if ($force -or -not $x.MainWindowHandle -or $x.MainWindowHandle -eq 0) {
            $x.Kill()
          } else {
            $x.CloseMainWindow() | Out-Null
            Start-Sleep -Milliseconds 1500
            $x.Refresh()
            if (-not $x.HasExited) { $x.Kill() }
          }
          Start-Sleep -Milliseconds 300
          $check = Get-Process -Id $x.Id -ErrorAction SilentlyContinue
          if (-not $check -or $check.HasExited) { $killedAny = $true }
        } catch { }
      }
      if ($killedAny) { $closed = $true }
    }
    $closeOk = $closed
  }

  _Trajectory-Append -Kind "with_app" -Payload @{
    name = $name
    launch_pid = $launchPid
    owner_pid = $ownerPid
    title_seen = $titleSeen
    close_after = [bool]$closeAfter
    closed = $closeOk
  }

  if ($Brief) {
    if ($titleSeen -and $closeOk) { [Console]::Out.WriteLine("ok with-app '$name' launch_pid=$launchPid owner_pid=$ownerPid title_seen=$titleSeen close=$closeOk") }
    elseif (-not $titleSeen) { [Console]::Out.WriteLine("err with-app title-timeout '$waitTitle' pid=$launchPid") }
    else { [Console]::Out.WriteLine("err with-app close-failed launch_pid=$launchPid owner_pid=$ownerPid") }
  }
  if ($titleSeen -and $closeOk) { return 0 } else { return 2 }
}

# ============================================================================
# Click + verify (변화 감지 자가 검증)
# ============================================================================

function _Compute-ImageHash {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    $hash = $hasher.ComputeHash($bytes)
    return ($hash | ForEach-Object { $_.ToString("x2") }) -join ""
  } catch { return $null }
}

function Invoke-MacroClickAndVerify {
  param([string[]]$Rest)
  $label = _Read-OptValue -Rest $Rest -Name "--label"
  $window = _Read-OptValue -Rest $Rest -Name "--window"
  $verifyLabel = _Read-OptValue -Rest $Rest -Name "--verify-label"
  $verifyTimeout = [int](_Read-OptValue -Rest $Rest -Name "--verify-timeout-ms")
  $waitChangeMs = [int](_Read-OptValue -Rest $Rest -Name "--wait-change-ms")
  if (-not $label) { throw "macro click-and-verify requires --label" }
  if (-not $AllowLiveControl) { throw "macro click-and-verify requires -AllowLiveControl" }
  if ($verifyTimeout -le 0) { $verifyTimeout = 5000 }
  if ($waitChangeMs -le 0) { $waitChangeMs = 1500 }

  # 1) Pre-click screenshot for change detection
  $preDir = _Get-VisionWorkDir
  $prePath = Join-Path $preDir ("pre-" + (Get-Date).ToString("yyyyMMddHHmmssfff") + ".png")
  $preArgs = @("observe", "screenshot", "--out", $prePath)
  Invoke-Cucp -ArgList $preArgs -CaptureJson | Out-Null
  $preHash = _Compute-ImageHash -Path $prePath

  # 2) Click via existing click-label macro
  $clickArgs = @("macro", "click-label", "--label", $label)
  if ($window) { $clickArgs += @("--window", $window) }
  $r = Invoke-Cucp -ArgList $clickArgs
  if ($r.ExitCode -ne 0) {
    if ($Brief) { [Console]::Out.WriteLine("err click-and-verify click-failed exit=$($r.ExitCode)") }
    return $r.ExitCode
  }

  # 3) Post-click screenshot - wait for visual change
  Start-Sleep -Milliseconds $waitChangeMs
  $postPath = Join-Path $preDir ("post-" + (Get-Date).ToString("yyyyMMddHHmmssfff") + ".png")
  $postArgs = @("observe", "screenshot", "--out", $postPath)
  Invoke-Cucp -ArgList $postArgs -CaptureJson | Out-Null
  $postHash = _Compute-ImageHash -Path $postPath

  $screenChanged = ($preHash -ne $null -and $postHash -ne $null -and $preHash -ne $postHash)

  # 4) Optional label verification
  $labelVerified = $true
  if ($verifyLabel) {
    $waitArgs = @("macro", "wait-label", "--label", $verifyLabel, "--timeout-ms", "$verifyTimeout")
    if ($window) { $waitArgs += @("--window", $window) }
    $vr = Invoke-Cucp -ArgList $waitArgs
    $labelVerified = ($vr.ExitCode -eq 0)
  }

  _Trajectory-Append -Kind "click_verify" -Payload @{
    label = $label
    window = $window
    screen_changed = $screenChanged
    label_verified = $labelVerified
    pre_hash = $preHash
    post_hash = $postHash
  }

  if ($Brief) {
    if ($screenChanged -and $labelVerified) {
      [Console]::Out.WriteLine("ok click-and-verify '$label' changed=true verified=true")
    } elseif (-not $screenChanged) {
      [Console]::Out.WriteLine("err click-and-verify '$label' no-screen-change")
    } else {
      [Console]::Out.WriteLine("err click-and-verify '$label' label-not-found '$verifyLabel'")
    }
  }
  if ($screenChanged -and $labelVerified) { return 0 } else { return 2 }
}

# ============================================================================
# Native helper 직통 매크로 — 외부 helper / cli.mjs 없이 동작
# ============================================================================
# 이 그룹은 cucp-native-helper.ps1 (Win32 + UIA + Screenshot 직접 호출)을
# child PowerShell로 띄워 결과 JSON을 그대로 stdout으로 토해냅니다.
# windows-mcp / Codex helper / cli.mjs 모두 없어도 동작하는 기본 표면입니다.
#
# - native-health      : helper 자체 health
# - native-windows     : 윈도우 enum (-Match 옵션)
# - native-screenshot  : 전체/영역 PNG 캡처
# - click-point        : 좌표 기반 클릭 (-AllowLiveControl 필요)
# - type-native        : 유니코드 텍스트 입력 (-AllowLiveControl 필요)
# - shortcut-native    : 단축키 (예: ctrl+s)
# - uia-click-label    : UIA tree에서 라벨 찾아 클릭 (-AllowLiveControl 필요)
#
# 모든 actuation 매크로는 -AllowLiveControl 게이트 통과해야 함.
# ============================================================================

function Invoke-MacroNativeHealth {
  param([string[]]$Rest)
  $r = Invoke-NativeHelper -ArgList @("-Action","health")
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      $ocrLangs = ""
      if ($r.Json.ocr_languages) { $ocrLangs = ($r.Json.ocr_languages -join ',') }
      [Console]::Out.WriteLine("ok native-health win32=$($r.Json.win32) uia=$($r.Json.uia) ocr=$($r.Json.ocr) ocr_languages=$ocrLangs elapsed_ms=$($r.ElapsedMs)")
    } else {
      [Console]::Out.WriteLine("err native-health helper_unavailable raw=" + $r.Err)
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  if ($r.Json -and $r.Json.status -eq "ok") { return 0 }
  return 1
}

function Invoke-MacroNativeWindows {
  param([string[]]$Rest)
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $args = @("-Action","windows")
  if ($match) { $args += @("-Match", $match) }
  $r = Invoke-NativeHelper -ArgList $args
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok native-windows count=$($r.Json.count) elapsed_ms=$($r.ElapsedMs)")
    } else {
      [Console]::Out.WriteLine("err native-windows helper_failed")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $r.ExitCode
}

function Invoke-MacroNativeScreenshot {
  param([string[]]$Rest)
  # --out-path / --out 둘 다 지원 (PowerShell의 -Out partial match 회피)
  $out = _Read-OptValue -Rest $Rest -Name "--out-path"
  if (-not $out) { $out = _Read-OptValue -Rest $Rest -Name "--out" }
  if (-not $out) {
    $out = Join-Path $Script:CacheDir ("native-shot-" + (Get-Date).ToString("yyyyMMdd-HHmmss-fff") + ".png")
  }
  $args = @("-Action","screenshot","-OutPath",$out)
  $regionX = _Read-OptValue -Rest $Rest -Name "--x"
  $regionY = _Read-OptValue -Rest $Rest -Name "--y"
  $regionW = _Read-OptValue -Rest $Rest -Name "--width"
  $regionH = _Read-OptValue -Rest $Rest -Name "--height"
  if ($regionX) { $args += @("-ScreenshotX", $regionX) }
  if ($regionY) { $args += @("-ScreenshotY", $regionY) }
  if ($regionW) { $args += @("-ScreenshotW", $regionW) }
  if ($regionH) { $args += @("-ScreenshotH", $regionH) }
  $r = Invoke-NativeHelper -ArgList $args
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok native-screenshot path='$($r.Json.out_path)' bytes=$($r.Json.bytes) elapsed_ms=$($r.ElapsedMs)")
    } else {
      [Console]::Out.WriteLine("err native-screenshot")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $r.ExitCode
}

function Invoke-MacroClickPoint {
  # macro click-point --x <n> --y <n> [--button left|right|middle|double]
  # 좌표 기반 클릭 (UIA / vision 우회). -AllowLiveControl 필수.
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro click-point requires -AllowLiveControl" }
  $x = [int](_Read-OptValue -Rest $Rest -Name "--x")
  $y = [int](_Read-OptValue -Rest $Rest -Name "--y")
  $btn = _Read-OptValue -Rest $Rest -Name "--button"
  if (-not $btn) { $btn = "left" }
  if ($x -le 0 -or $y -le 0) { throw "macro click-point requires --x and --y" }
  $r = Invoke-NativeHelper -ArgList @("-Action","click","-X","$x","-Y","$y","-Button",$btn)
  _Trajectory-Append -Kind "click" -Payload @{
    source = "native_click_point"
    x = $x; y = $y; button = $btn
    exit = $r.ExitCode
  }
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok click-point @($x,$y) button=$btn elapsed_ms=$($r.ElapsedMs)")
    } else {
      [Console]::Out.WriteLine("err click-point exit=$($r.ExitCode)")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $r.ExitCode
}

function Invoke-MacroTypeNative {
  # macro type-native --text <s> [--clear] [--enter]
  # 유니코드 텍스트 입력 (한글/이모지 OK). -AllowLiveControl 필수.
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro type-native requires -AllowLiveControl" }
  $text = _Read-OptValue -Rest $Rest -Name "--text"
  $clear = _Read-Switch -Rest $Rest -Name "--clear"
  $enter = _Read-Switch -Rest $Rest -Name "--enter"
  if (-not $text -and -not $clear -and -not $enter) { throw "macro type-native requires --text or --clear or --enter" }
  $args = @("-Action","type")
  if ($text)  { $args += @("-Text", $text) }
  if ($clear) { $args += "-ClearFirst" }
  if ($enter) { $args += "-PressEnter" }
  $r = Invoke-NativeHelper -ArgList $args
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok type-native length=$($text.Length) clear=$clear enter=$enter elapsed_ms=$($r.ElapsedMs)")
    } else {
      [Console]::Out.WriteLine("err type-native exit=$($r.ExitCode)")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $r.ExitCode
}

function Invoke-MacroShortcutNative {
  # macro shortcut-native --keys "ctrl+s"
  # 단축키 (외부 helper 없이). -AllowLiveControl 필수.
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro shortcut-native requires -AllowLiveControl" }
  $keys = _Read-OptValue -Rest $Rest -Name "--keys"
  if (-not $keys) { throw "macro shortcut-native requires --keys" }
  $r = Invoke-NativeHelper -ArgList @("-Action","shortcut","-Keys",$keys)
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok shortcut-native keys='$keys' elapsed_ms=$($r.ElapsedMs)")
    } else {
      [Console]::Out.WriteLine("err shortcut-native exit=$($r.ExitCode)")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $r.ExitCode
}

function Invoke-MacroUiaClickLabel {
  # macro uia-click-label --label <text> [--match <window>] [--role <role>] [--button left|right|double]
  # UIA BoundingRectangle 기반 결정론적 클릭. 외부 helper 의존 없음.
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro uia-click-label requires -AllowLiveControl" }
  $label = _Read-OptValue -Rest $Rest -Name "--label"
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $role  = _Read-OptValue -Rest $Rest -Name "--role"
  $btn   = _Read-OptValue -Rest $Rest -Name "--button"
  if (-not $btn) { $btn = "left" }
  if (-not $label) { throw "macro uia-click-label requires --label" }

  $args = @("-Action","uia-click","-Label",$label,"-Button",$btn)
  if ($match) { $args += @("-Match", $match) }
  if ($role)  { $args += @("-Role", $role) }
  $r = Invoke-NativeHelper -ArgList $args
  _Trajectory-Append -Kind "click" -Payload @{
    label = $label
    source = "native_uia_click_label"
    button = $btn
    exit = $r.ExitCode
  }
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok uia-click-label '$label' @($($r.Json.x),$($r.Json.y)) matched='$($r.Json.matched_text)' elapsed_ms=$($r.ElapsedMs)")
    } else {
      $reason = ""
      if ($r.Json -and $r.Json.reason) { $reason = $r.Json.reason }
      [Console]::Out.WriteLine("err uia-click-label '$label' exit=$($r.ExitCode) reason=$reason")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $r.ExitCode
}

# ============================================================================
# UIA Pattern 직접 호출 매크로 — 마우스 안 움직이는 클릭
# ============================================================================
# `uia-invoke`: InvokePattern으로 버튼 누름 (마우스 이동 없음, 화면 가려져도 OK)
# `uia-set-value`: ValuePattern으로 Edit/ComboBox에 값 즉시 설정 (IME 안 거침)
# `uia-toggle`: TogglePattern으로 체크박스/라디오 상태 전환
#
# 모두 -AllowLiveControl 필수. UIA Pattern 미지원 시 partial(2) 반환
# (좌표 fallback 자동 안 함 — 명시적으로 click-point 사용해야 함).
# ============================================================================

function Invoke-MacroUiaInvoke {
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro uia-invoke requires -AllowLiveControl" }
  $label = _Read-OptValue -Rest $Rest -Name "--label"
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $role  = _Read-OptValue -Rest $Rest -Name "--role"
  if (-not $label) { throw "macro uia-invoke requires --label" }

  $args = @("-Action","uia-invoke","-Label",$label)
  if ($match) { $args += @("-Match", $match) }
  if ($role)  { $args += @("-Role", $role) }
  $r = Invoke-NativeHelper -ArgList $args
  _Trajectory-Append -Kind "click" -Payload @{
    label = $label
    source = "native_uia_invoke"
    method = if ($r.Json) { "$($r.Json.method)" } else { "" }
    mouse_moved = if ($r.Json) { [bool]$r.Json.mouse_moved } else { $true }
    exit = $r.ExitCode
  }
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok uia-invoke '$label' method=$($r.Json.method) mouse_moved=$($r.Json.mouse_moved) elapsed_ms=$($r.ElapsedMs)")
    } else {
      $reason = if ($r.Json -and $r.Json.reason) { $r.Json.reason } else { "" }
      [Console]::Out.WriteLine("partial uia-invoke '$label' reason=$reason exit=$($r.ExitCode)")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $r.ExitCode
}

function Invoke-MacroUiaSetValue {
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro uia-set-value requires -AllowLiveControl" }
  $label = _Read-OptValue -Rest $Rest -Name "--label"
  $value = _Read-OptValue -Rest $Rest -Name "--value"
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $role  = _Read-OptValue -Rest $Rest -Name "--role"
  if (-not $label) { throw "macro uia-set-value requires --label" }
  if ($null -eq $value) { throw "macro uia-set-value requires --value" }

  $args = @("-Action","uia-set-value","-Label",$label,"-Value",$value)
  if ($match) { $args += @("-Match", $match) }
  if ($role)  { $args += @("-Role", $role) }
  $r = Invoke-NativeHelper -ArgList $args
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok uia-set-value '$label' length=$($r.Json.value_length) keyboard_used=$($r.Json.keyboard_used) elapsed_ms=$($r.ElapsedMs)")
    } else {
      $reason = if ($r.Json -and $r.Json.reason) { $r.Json.reason } else { "" }
      [Console]::Out.WriteLine("partial uia-set-value '$label' reason=$reason exit=$($r.ExitCode)")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $r.ExitCode
}

function Invoke-MacroUiaToggle {
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro uia-toggle requires -AllowLiveControl" }
  $label = _Read-OptValue -Rest $Rest -Name "--label"
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $role  = _Read-OptValue -Rest $Rest -Name "--role"
  if (-not $label) { throw "macro uia-toggle requires --label" }

  $args = @("-Action","uia-toggle","-Label",$label)
  if ($match) { $args += @("-Match", $match) }
  if ($role)  { $args += @("-Role", $role) }
  $r = Invoke-NativeHelper -ArgList $args
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok uia-toggle '$label' previous=$($r.Json.previous_state) elapsed_ms=$($r.ElapsedMs)")
    } else {
      $reason = if ($r.Json -and $r.Json.reason) { $r.Json.reason } else { "" }
      [Console]::Out.WriteLine("partial uia-toggle '$label' reason=$reason exit=$($r.ExitCode)")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $r.ExitCode
}

# ============================================================================
# v1.2.0 — hit-test 가드 + safe-type
# ============================================================================
# 라이브 검증에서 발견된 두 사고 ((a) 코드 에디터 의도치 않은 입력, (b) Kiro 전체화면
# → 창모드 변경) 의 본질은 "좌표 클릭 직전 검증 부재". v1.2.0 은 좌표가 의도한
# 윈도우 안인지 Win32 WindowFromPoint 로 검증 + 입력 후 OCR probe 로 진짜 들어갔는지
# 확인하는 안전망 추가.
# ============================================================================

# macro hit-test --x N --y N [--target-match Kiro | --target-hwnd N]
# 좌표가 어떤 윈도우 안인지 확인 (read-only, 클릭 안 함)
function Invoke-MacroHitTest {
  param([string[]]$Rest)
  $x = [int](_Read-OptValue -Rest $Rest -Name "--x")
  $y = [int](_Read-OptValue -Rest $Rest -Name "--y")
  $tm = _Read-OptValue -Rest $Rest -Name "--target-match"
  $th = [int](_Read-OptValue -Rest $Rest -Name "--target-hwnd")
  if ($x -le 0 -or $y -le 0) { throw "macro hit-test requires --x and --y" }

  $argList = @("-Action","hit-test","-X","$x","-Y","$y")
  if ($tm) { $argList += @("-TargetMatch", $tm) }
  if ($th -gt 0) { $argList += @("-TargetHwnd", "$th") }
  $r = Invoke-NativeHelper -ArgList $argList
  $exitCode = [int]$r.ExitCode

  if ($Brief) {
    if ($r.Json) {
      $tag = "ok"
      if ($r.Json.status -eq "partial") { $tag = "partial" }
      [Console]::Out.WriteLine("$tag hit-test @($x,$y) hwnd=$($r.Json.root_hwnd) title='$($r.Json.root_title)' process=$($r.Json.process_name) matched=$($r.Json.matched) reason=$($r.Json.match_reason)")
    } else {
      [Console]::Out.WriteLine("err hit-test @($x,$y) helper_failed exit=$exitCode")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $exitCode
}

# macro safe-type --text "..." --target-match <window>
#                 [--click-x N --click-y N]    (입력란 클릭 좌표 — 비어있으면 현재 focus 유지)
#                 [--probe N]                  (verify probe 길이, 기본 8)
#                 [--enter | --ctrl-enter]     (전송 단축키)
#                 [--max-attempts N]           (재시도 — 클릭 좌표 빗나갔으면 helper 가 자동 abort)
# 안전 흐름:
#   1. (옵션) target window 가 foreground 인지 확인 + focus
#   2. (옵션) 입력란 클릭 — hit-test 가드 통과해야 함 (다른 윈도우면 abort)
#   3. probe 짧은 텍스트 type (target match focus 가드 통과해야 함)
#   4. OCR 으로 probe 가 target window 안에 있는지 검증
#   5. 매칭이면 본 텍스트 추가 type + (옵션) 전송 단축키
#   6. 매칭 안 되면 즉시 abort + Ctrl+Z 자동 복구
#
# -AllowLiveControl 필수.
function Invoke-MacroSafeType {
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro safe-type requires -AllowLiveControl" }

  $text = _Read-OptValue -Rest $Rest -Name "--text"
  $tm = _Read-OptValue -Rest $Rest -Name "--target-match"
  $clickX = [int](_Read-OptValue -Rest $Rest -Name "--click-x")
  $clickY = [int](_Read-OptValue -Rest $Rest -Name "--click-y")
  $probeLen = [int](_Read-OptValue -Rest $Rest -Name "--probe")
  $sendEnter = _Read-Switch -Rest $Rest -Name "--enter"
  $sendCtrlEnter = _Read-Switch -Rest $Rest -Name "--ctrl-enter"
  $maxAttempts = [int](_Read-OptValue -Rest $Rest -Name "--max-attempts")
  # v1.2.1: probe 검증 비활성화 옵션 — OCR이 작은 폰트의 입력란 안 텍스트를
  # 못 찾는 false-negative 방지. hit-test 가드 + focus 가드만으로 충분.
  $skipProbe = _Read-Switch -Rest $Rest -Name "--skip-probe"

  if (-not $text) { throw "macro safe-type requires --text" }
  if (-not $tm) { throw "macro safe-type requires --target-match (window title substring)" }
  if ($probeLen -le 0) { $probeLen = 8 }
  if ($maxAttempts -le 0) { $maxAttempts = 1 }

  # probe — 안전한 ASCII 8글자
  $probe = "CUCP" + ([string]([char]([int][char]'A' + (Get-Random -Min 0 -Max 26)))) + ([string]([char]([int][char]'A' + (Get-Random -Min 0 -Max 26)))) + ([string]([char]([int][char]'A' + (Get-Random -Min 0 -Max 26)))) + ([string]([char]([int][char]'A' + (Get-Random -Min 0 -Max 26))))
  if ($probe.Length -gt $probeLen) { $probe = $probe.Substring(0, $probeLen) }

  # Step 1: target focus
  $rFocus = Invoke-NativeHelper -ArgList @("-Action","focus","-WindowTitle",$tm)
  if (-not ($rFocus.Json -and $rFocus.Json.verified)) {
    if ($Brief) { [Console]::Out.WriteLine("err safe-type focus_failed target='$tm'") }
    return 1
  }
  $targetHwnd = [int64]$rFocus.Json.target_hwnd
  Start-Sleep -Milliseconds 200

  $attempt = 0
  $success = $false
  $lastReason = ""

  while ($attempt -lt $maxAttempts -and -not $success) {
    $attempt++

    # Step 2: 입력란 클릭 (hit-test 가드)
    if ($clickX -gt 0 -and $clickY -gt 0) {
      $rClick = Invoke-NativeHelper -ArgList @(
        "-Action","click","-X","$clickX","-Y","$clickY",
        "-TargetHwnd","$targetHwnd"
      )
      if (-not ($rClick.Json -and $rClick.Json.status -eq "ok")) {
        $lastReason = "click_blocked_or_failed"
        if ($Brief) {
          [Console]::Out.WriteLine("partial safe-type attempt=$attempt click_blocked actual='$($rClick.Json.actual_title)' reason=$($rClick.Json.reason)")
        }
        continue
      }
      Start-Sleep -Milliseconds 600
    }

    # Step 3-4: probe type + OCR 검증 (--skip-probe 옵션 시 우회)
    # OCR 이 작은 폰트의 입력란 안 텍스트를 못 찾는 false-negative 가 있음.
    # hit-test 가드가 click 단계에서 이미 확인했으므로 probe 검증은 옵션.
    if (-not $skipProbe) {
      # Step 3: probe type (focus 가드)
      $rProbe = Invoke-NativeHelper -ArgList @(
        "-Action","type","-Text",$probe,
        "-TargetHwnd","$targetHwnd"
      )
      if (-not ($rProbe.Json -and $rProbe.Json.status -eq "ok")) {
        $lastReason = "probe_blocked_focus_lost"
        if ($Brief) { [Console]::Out.WriteLine("partial safe-type attempt=$attempt probe_blocked focus_lost") }
        continue
      }
      Start-Sleep -Milliseconds 600

      # Step 4: probe OCR 검증
      $rWin = Invoke-NativeHelper -ArgList @("-Action","windows","-Match",$tm)
      $winRect = $null
      if ($rWin.Json -and $rWin.Json.windows -and $rWin.Json.windows.Count -gt 0) {
        $matchWin = $rWin.Json.windows | Where-Object { [int64]$_.hwnd -eq $targetHwnd } | Select-Object -First 1
        if ($matchWin) { $winRect = $matchWin.rect }
      }

      $rOcr = Invoke-NativeHelper -ArgList @(
        "-Action","ocr-find-text","-OcrText",$probe,"-OcrMatch","contains"
      )
      $probeInTarget = $false
      if ($rOcr.Json -and $rOcr.Json.status -eq "ok" -and $rOcr.Json.top) {
        $cx = [int]$rOcr.Json.top.cx
        $cy = [int]$rOcr.Json.top.cy
        if ($winRect) {
          if ($cx -ge [int]$winRect.x -and $cx -le ([int]$winRect.x + [int]$winRect.width) -and
              $cy -ge [int]$winRect.y -and $cy -le ([int]$winRect.y + [int]$winRect.height)) {
            $probeInTarget = $true
          }
        } else {
          $probeInTarget = $true
        }
      }

      if (-not $probeInTarget) {
        $lastReason = "probe_outside_target"
        if ($Brief) {
          [Console]::Out.WriteLine("partial safe-type attempt=$attempt probe_outside_target probe='$probe'")
        }
        # Ctrl+Z 로 probe 입력 복구
        for ($i = 0; $i -lt 3; $i++) {
          Invoke-NativeHelper -ArgList @("-Action","shortcut","-Keys","ctrl+z") | Out-Null
        }
        Start-Sleep -Milliseconds 200
        continue
      }
    }

    # Step 5: 본 텍스트 추가
    # v1.2.1: TargetHwnd 가드 제거 — focus 가드가 race condition 으로 false 차단.
    # hit-test 는 click 단계에서 이미 통과 → 추가 가드 불필요.
    $rType = Invoke-NativeHelper -ArgList @(
      "-Action","type","-Text",$text
    )
    if (-not ($rType.Json -and $rType.Json.status -eq "ok")) {
      $lastReason = "main_type_blocked"
      if ($Brief) { [Console]::Out.WriteLine("partial safe-type attempt=$attempt main_type_blocked") }
      continue
    }
    Start-Sleep -Milliseconds 400

    # Step 6: 전송 단축키 (옵션)
    if ($sendCtrlEnter) {
      Invoke-NativeHelper -ArgList @("-Action","shortcut","-Keys","ctrl+enter") | Out-Null
    } elseif ($sendEnter) {
      Invoke-NativeHelper -ArgList @("-Action","shortcut","-Keys","enter") | Out-Null
    }

    $success = $true
  }

  if (-not $success) {
    if ($Brief) {
      [Console]::Out.WriteLine("partial safe-type failed attempts=$attempt last_reason=$lastReason")
    }
    return 2
  }

  if ($Brief) {
    $sendInfo = "no_send"
    if ($sendCtrlEnter) { $sendInfo = "ctrl+enter" } elseif ($sendEnter) { $sendInfo = "enter" }
    [Console]::Out.WriteLine("ok safe-type target='$tm' attempts=$attempt probe='$probe' send=$sendInfo")
  } else {
    [Console]::Out.WriteLine(([pscustomobject]@{
      schema = "cucp.safe-type/v1"
      status = "ok"
      target_match = $tm
      target_hwnd = $targetHwnd
      attempts = $attempt
      probe = $probe
      send = if ($sendCtrlEnter) { "ctrl+enter" } elseif ($sendEnter) { "enter" } else { "none" }
    } | ConvertTo-Json -Depth 4))
  }
  return 0
}

# ============================================================================
# v1.3.0 — Electron CDP wrapper macros
# ============================================================================
# DOM 직접 제어로 Kiro / VS Code / Slack 같은 Electron 앱의 좌표 무관 actuation.
# 활성화 가이드: references/cdp-setup.md
# ============================================================================

# macro cdp-detect [--port N]
# 9222 포트 + 페이지 목록 (read-only)
function Invoke-MacroCdpDetect {
  param([string[]]$Rest)
  $port = [int](_Read-OptValue -Rest $Rest -Name "--port")
  if ($port -le 0) { $port = 9222 }
  $argList = @("-Action","cdp-detect","-CdpPort","$port")
  $r = Invoke-NativeHelper -ArgList $argList
  $exitCode = [int]$r.ExitCode
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok cdp-detect port=$($r.Json.port) pages=$($r.Json.page_count) browser='$($r.Json.browser)' protocol=$($r.Json.protocol_version)")
    } else {
      $reason = if ($r.Json) { $r.Json.reason } else { "helper_failed" }
      [Console]::Out.WriteLine("partial cdp-detect port=$port reason=$reason")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $exitCode
}

# macro cdp-eval --expr "<javascript>" [--page-match Kiro] [--port 9222]
# 임의 JS 실행 (read-only — 사용자가 무엇을 실행하는지 알아서 책임)
function Invoke-MacroCdpEval {
  param([string[]]$Rest)
  $expr = _Read-OptValue -Rest $Rest -Name "--expr"
  $pm = _Read-OptValue -Rest $Rest -Name "--page-match"
  $port = [int](_Read-OptValue -Rest $Rest -Name "--port")
  if (-not $expr) { throw "macro cdp-eval requires --expr" }
  if ($port -le 0) { $port = 9222 }
  $argList = @("-Action","cdp-eval","-CdpExpr",$expr,"-CdpPort","$port")
  if ($pm) { $argList += @("-CdpPageMatch", $pm) }
  $r = Invoke-NativeHelper -ArgList $argList
  $exitCode = [int]$r.ExitCode
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      $val = "$($r.Json.result_value)"
      if ($val.Length -gt 80) { $val = $val.Substring(0, 77) + "..." }
      [Console]::Out.WriteLine("ok cdp-eval result_type=$($r.Json.result_type) value='$val' page='$($r.Json.page_title)'")
    } else {
      $reason = if ($r.Json) { $r.Json.reason } else { "helper_failed" }
      [Console]::Out.WriteLine("partial cdp-eval reason=$reason")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $exitCode
}

# macro cdp-type --selector "<css>" --text "<msg>" [--page-match Kiro] [--port 9222]
#                [--press-enter] [--clear-first]
# DOM selector 의 element 에 focus + value set + dispatchEvent.
# -AllowLiveControl 필수 (실제 actuation).
function Invoke-MacroCdpType {
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro cdp-type requires -AllowLiveControl" }
  $selector = _Read-OptValue -Rest $Rest -Name "--selector"
  $text = _Read-OptValue -Rest $Rest -Name "--text"
  $pm = _Read-OptValue -Rest $Rest -Name "--page-match"
  $port = [int](_Read-OptValue -Rest $Rest -Name "--port")
  $pressEnter = _Read-Switch -Rest $Rest -Name "--press-enter"
  $clearFirst = _Read-Switch -Rest $Rest -Name "--clear-first"
  if (-not $selector) { throw "macro cdp-type requires --selector" }
  if ($port -le 0) { $port = 9222 }
  $argList = @("-Action","cdp-type","-CdpSelector",$selector,"-CdpPort","$port")
  if ($text) { $argList += @("-Text", $text) }
  if ($pm) { $argList += @("-CdpPageMatch", $pm) }
  if ($pressEnter) { $argList += "-PressEnter" }
  if ($clearFirst) { $argList += "-ClearFirst" }
  $r = Invoke-NativeHelper -ArgList $argList
  $exitCode = [int]$r.ExitCode
  _Trajectory-Append -Kind "click" -Payload @{
    source = "cdp_type"
    selector = $selector
    text_length = if ($text) { $text.Length } else { 0 }
    sent_enter = [bool]$pressEnter
    page_id = "$($r.Json.page_id)"
    exit = $exitCode
  }
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok cdp-type selector='$selector' tag=$($r.Json.tag_name) ce=$($r.Json.is_content_editable) input=$($r.Json.is_input) value_len=$($r.Json.current_value_length) sent_enter=$($r.Json.sent_enter) page='$($r.Json.page_title)'")
    } else {
      $reason = if ($r.Json) { $r.Json.reason } else { "helper_failed" }
      [Console]::Out.WriteLine("partial cdp-type selector='$selector' reason=$reason")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $exitCode
}

# macro cdp-click --selector "<css>" [--page-match Kiro] [--port 9222]
# DOM selector 의 element.click(). 마우스 좌표 안 씀.
# -AllowLiveControl 필수.
function Invoke-MacroCdpClick {
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro cdp-click requires -AllowLiveControl" }
  $selector = _Read-OptValue -Rest $Rest -Name "--selector"
  $pm = _Read-OptValue -Rest $Rest -Name "--page-match"
  $port = [int](_Read-OptValue -Rest $Rest -Name "--port")
  if (-not $selector) { throw "macro cdp-click requires --selector" }
  if ($port -le 0) { $port = 9222 }
  $argList = @("-Action","cdp-click","-CdpSelector",$selector,"-CdpPort","$port")
  if ($pm) { $argList += @("-CdpPageMatch", $pm) }
  $r = Invoke-NativeHelper -ArgList $argList
  $exitCode = [int]$r.ExitCode
  _Trajectory-Append -Kind "click" -Payload @{
    source = "cdp_click"
    selector = $selector
    page_id = "$($r.Json.page_id)"
    exit = $exitCode
  }
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok cdp-click selector='$selector' tag=$($r.Json.tag_name) page='$($r.Json.page_title)'")
    } else {
      $reason = if ($r.Json) { $r.Json.reason } else { "helper_failed" }
      [Console]::Out.WriteLine("partial cdp-click selector='$selector' reason=$reason")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $exitCode
}

# ============================================================================
# v1.1.0 — macro history: smart-click 학습 데이터 조회/관리
# ============================================================================
# 사용법:
#   macro history show [--label X] [--last N]    — 최근 N건 (또는 특정 라벨)
#   macro history stats                          — 전체 통계 (성공률, strategy 분포)
#   macro history clear                          — 학습 데이터 삭제
# ============================================================================
function Invoke-MacroHistory {
  param([string[]]$Rest)
  $action = "show"
  if ($Rest.Count -ge 1) { $action = $Rest[0] }
  switch ($action) {
    "show" {
      $label = _Read-OptValue -Rest $Rest -Name "--label"
      $lastN = [int](_Read-OptValue -Rest $Rest -Name "--last")
      if ($lastN -le 0) { $lastN = 20 }
      if (-not (Test-Path -LiteralPath $Script:HistoryFile)) {
        if ($Brief) { [Console]::Out.WriteLine("ok history empty file=none") }
        else { [Console]::Out.WriteLine('{"status":"ok","records":[]}') }
        return 0
      }
      $all = @(Get-Content -LiteralPath $Script:HistoryFile -Encoding UTF8)
      if (-not $all) { $all = @() }
      $records = @()
      for ($i = $all.Count - 1; $i -ge 0 -and $records.Count -lt $lastN; $i--) {
        try {
          $rec = $all[$i] | ConvertFrom-Json -ErrorAction Stop
          if ($label -and "$($rec.label)" -ne $label) { continue }
          $records += $rec
        } catch { continue }
      }
      if ($Brief) {
        [Console]::Out.WriteLine("ok history count=$($records.Count) label='$label' last=$lastN")
        foreach ($r in $records) {
          $okStr = if ($r.success) { "ok" } else { "fail" }
          [Console]::Out.WriteLine("  $okStr label='$($r.label)' match='$($r.match)' strategy=$($r.strategy) elapsed=$($r.elapsed_ms)ms")
        }
      } else {
        [Console]::Out.WriteLine(([pscustomobject]@{
          status = "ok"
          schema = "cucp.history/v1"
          records = @($records)
          count = $records.Count
        } | ConvertTo-Json -Depth 5))
      }
      return 0
    }
    "stats" {
      $stats = _History-Stats
      if ($Brief) {
        $strList = ($stats.strategies.Keys | Sort-Object | ForEach-Object {
          "$_=$($stats.strategies[$_])"
        }) -join ", "
        [Console]::Out.WriteLine("ok history stats total=$($stats.total) success=$($stats.success) rate=$($stats.success_rate)% strategies=[$strList]")
      } else {
        [Console]::Out.WriteLine(($stats | ConvertTo-Json -Depth 4))
      }
      return 0
    }
    "clear" {
      if (Test-Path -LiteralPath $Script:HistoryFile) {
        Remove-Item -LiteralPath $Script:HistoryFile -Force -ErrorAction SilentlyContinue
      }
      if ($Brief) { [Console]::Out.WriteLine("ok history cleared") }
      else { [Console]::Out.WriteLine('{"status":"ok","cleared":true}') }
      return 0
    }
    default {
      throw "macro history requires 'show' / 'stats' / 'clear' subcommand"
    }
  }
}

# ============================================================================
# macro smart-click ─ Cascade 전략 + ambiguity 거부 + 클릭 검증
# ============================================================================
# 사용자가 한 번만 호출해도 가장 안정적인 방법으로 클릭.
#
# Cascade 우선순위 (정확도 / 안전도 높은 순):
#   ┌─ Stage 1: UIA Pattern (uia-invoke)
#   │    InvokePattern.Invoke() 직접 호출. 마우스 안 움직임. BoundingRectangle만으로 동작.
#   │    가장 안전. 화면 가려져도 동작. UIA Name 매칭 score >= 60 만 허용.
#   ├─ Stage 2: UIA 좌표 클릭 (uia-click)        [--allow-mouse-fallback]
#   │    UIA 가 알려준 좌표로 SendInput 마우스 클릭.
#   ├─ Stage 3: icon-find synonym 매칭             [--allow-mouse-fallback]
#   │    tooltip / AutomationId / AccessKey 기반 시각 요소 매칭 (작은 toolbar 아이콘).
#   ├─ Stage 4: OCR+UIA fusion (ocr-uia-invoke)  [--allow-mouse-fallback default ON / --no-ocr]
#   │    OCR 좌표 위 UIA element 발견 시 한 프로세스 안에서 InvokePattern.Invoke().
#   │    UIA Name 비어있어도 AutomationId / ClassName 으로 invoke 가능 (v1.0.0).
#   │    Name 도 없으면 fallback_coord 좌표 클릭 (--allow-mouse-fallback 필요).
#   ├─ Stage 5: OCR text 좌표                     [--allow-mouse-fallback default ON]
#   │    UIA element 없는 순수 캔버스/이미지 표면. OCR 텍스트 cx/cy 좌표 클릭.
#   └─ Stage 6: vision-click-precise              [--allow-vision]
#        crop-and-refine 2단계 vision 매칭. 마지막 fallback. 비싸고 느림.
#
# 안전 정책:
#   - score < 60 (낮은 신뢰도) → partial(2) 거부, 후보 반환
#   - 두 후보 점수 차이 < 8 → ambiguous_target partial(2)
#   - --no-ocr 로 Stage 4/5 동시 비활성화 가능
#   - --verify-label <text> 로 클릭 후 라벨 등장 검증
#   - --verify-screen-changed 로 클릭 후 픽셀 변화 검증 (v0.9.0)
#   - --retry-on-no-change N 으로 변화 없을 시 cascade 재시도 (v1.0.0)
#
# History learning (v1.1.0):
#   - 같은 (label, match) 의 과거 5건 중 가장 자주 성공한 strategy 자동 추천
#   - cascade 의 앞 stages skip → 평균 응답 시간 단축
#   - 그 stage 가 실패하면 전체 cascade 자동 재시도 (안전망)
#   - --no-history 로 비활성화. macro history show / stats / clear 로 관리.
# ============================================================================

function Invoke-MacroSmartClick {
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro smart-click requires -AllowLiveControl" }
  $label = _Read-OptValue -Rest $Rest -Name "--label"
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $role  = _Read-OptValue -Rest $Rest -Name "--role"
  $verifyLabel = _Read-OptValue -Rest $Rest -Name "--verify-label"
  $verifyTimeout = [int](_Read-OptValue -Rest $Rest -Name "--verify-timeout-ms")
  $allowVision = _Read-Switch -Rest $Rest -Name "--allow-vision"
  $allowMouseFallback = _Read-Switch -Rest $Rest -Name "--allow-mouse-fallback"
  # OCR Stage는 default ON. 명시 비활성화는 --no-ocr.
  $disableOcr = _Read-Switch -Rest $Rest -Name "--no-ocr"
  $ocrLang = _Read-OptValue -Rest $Rest -Name "--ocr-language"
  # v0.9.0: 클릭 후 화면 변화 검증
  $verifyScreen = _Read-Switch -Rest $Rest -Name "--verify-screen-changed"
  $verifyWaitMs = [int](_Read-OptValue -Rest $Rest -Name "--verify-wait-ms")
  # v1.0.0: 화면 변화 없으면 cascade 한 번 더 (retry-on-no-change). 기본 0 (off).
  # verify-screen 활성화 시에만 의미가 있음.
  $retryOnNoChange = [int](_Read-OptValue -Rest $Rest -Name "--retry-on-no-change")
  # v1.1.0: history learning. default ON. --no-history 로 비활성.
  $disableHistory = _Read-Switch -Rest $Rest -Name "--no-history"
  if (-not $label) { throw "macro smart-click requires --label" }
  if ($verifyTimeout -le 0) { $verifyTimeout = 3000 }
  if ($verifyWaitMs -le 0) { $verifyWaitMs = 500 }
  if ($retryOnNoChange -lt 0) { $retryOnNoChange = 0 }

  # v1.1.0: 과거 같은 (label, match) 시도에서 가장 자주 성공한 strategy 조회
  # null 이면 기본 cascade. string 이면 그 strategy 부터 시도.
  $hintedStrategy = $null
  if (-not $disableHistory) {
    try { $hintedStrategy = _History-PickBestStrategy -Label $label -Match $match -LookbackN 5 } catch { }
  }

  # cascade stage gates — hint 가 있으면 그 stage 만 활성화, 없으면 모든 stage 활성.
  # 미스매치/실패 시 모든 stage 활성으로 폴백 (안전).
  $tryStage1 = $true   # uia_pattern
  $tryStage2 = $true   # uia_coord
  $tryStage3 = $true   # icon_find
  $tryStage4 = $true   # fusion_uia_invoke / fusion_coord
  $tryStage5 = $true   # ocr_text
  $tryStage6 = $true   # vision_precise
  if ($hintedStrategy) {
    # hint 매핑 — 그 stage 만 활성화. 실패하면 cascade 전체 활성으로 fallback.
    $tryStage1 = ($hintedStrategy -eq "uia_pattern")
    $tryStage2 = ($hintedStrategy -eq "uia_coord")
    $tryStage3 = ($hintedStrategy -eq "icon_find")
    $tryStage4 = ($hintedStrategy -eq "fusion_uia_invoke" -or $hintedStrategy -eq "fusion_coord")
    $tryStage5 = ($hintedStrategy -eq "ocr_text")
    $tryStage6 = ($hintedStrategy -eq "vision_precise")
  }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $strategy = ""
  $rc = 1
  $resultLine = ""

  # v0.9.0: --verify-screen-changed 옵션 시 cascade 시작 전 before 스크린샷 캡처
  $verifyBeforePng = $null
  $verifyAfterPng = $null
  $verifyDiffRegion = $null   # foreground 윈도우 region
  if ($verifyScreen) {
    try {
      $rFg = Invoke-NativeHelper -ArgList @("-Action","focused")
      if ($rFg.Json -and $rFg.Json.foreground) {
        $fgr = $rFg.Json.foreground.rect
        $verifyDiffRegion = [ordered]@{
          x = [int]$fgr.x; y = [int]$fgr.y
          width = [int]$fgr.width; height = [int]$fgr.height
        }
      }
    } catch { }
    if (-not $verifyDiffRegion) {
      # foreground 못 찾으면 가상 데스크톱 전체 (느림 — 일단 비활성화)
      $verifyScreen = $false
    } else {
      $tag = (Get-Date).ToString("HHmmss-fff")
      $verifyBeforePng = Join-Path $Script:CacheDir ("smartclick-before-$tag.png")
      $vrA = Invoke-NativeHelper -ArgList @("-Action","screenshot","-OutPath",$verifyBeforePng,
              "-ScreenshotX","$($verifyDiffRegion.x)","-ScreenshotY","$($verifyDiffRegion.y)",
              "-ScreenshotW","$($verifyDiffRegion.width)","-ScreenshotH","$($verifyDiffRegion.height)")
      if (-not ($vrA.Json -and $vrA.Json.status -eq "ok")) {
        # 캡처 실패 — verify-screen 비활성화하고 진행
        $verifyScreen = $false
        if (Test-Path -LiteralPath $verifyBeforePng) { Remove-Item -LiteralPath $verifyBeforePng -Force -ErrorAction SilentlyContinue }
        $verifyBeforePng = $null
      }
    }
  }

  # Stage 1: UIA Pattern 직통 (가장 안정적)
  if ($tryStage1) {
    $args = @("-Action","uia-invoke","-Label",$label)
    if ($match) { $args += @("-Match", $match) }
    if ($role)  { $args += @("-Role", $role) }
    $r1 = Invoke-NativeHelper -ArgList $args
    if ($r1.Json -and $r1.Json.status -eq "ok") {
      $strategy = "uia_pattern"
      $rc = 0
      $resultLine = "ok smart-click '$label' strategy=uia_pattern method=$($r1.Json.method) mouse_moved=False"
    } elseif ($r1.Json -and $r1.Json.reason -eq "low_confidence_match") {
      # 신뢰도 낮음 — vision 시도하지 말고 즉시 거부 (안전).
      # v1.1.0: hint 가 있는 케이스에선 low-confidence 도 cascade 폴백 허용 (학습된 strategy 재시도용).
      if (-not $hintedStrategy) {
        [Console]::Out.WriteLine("partial smart-click '$label' low_confidence score=$($r1.Json.score) strategy=stopped")
        if (-not $disableHistory) { _History-Append -Label $label -Match $match -Strategy "uia_pattern" -Success $false -ElapsedMs ([int]$sw.Elapsed.TotalMilliseconds) }
        return 2
      }
    }
  }

  # Stage 2: UIA 좌표 클릭 (mouse_moved=True 허용)
  if ($rc -ne 0 -and $tryStage2 -and $allowMouseFallback) {
    $args2 = @("-Action","uia-click","-Label",$label)
    if ($match) { $args2 += @("-Match", $match) }
    if ($role)  { $args2 += @("-Role", $role) }
    $r2 = Invoke-NativeHelper -ArgList $args2
    if ($r2.Json -and $r2.Json.status -eq "ok") {
      $strategy = "uia_coord"
      $rc = 0
      $resultLine = "ok smart-click '$label' strategy=uia_coord @($($r2.Json.x),$($r2.Json.y)) mouse_moved=True"
    }
  }

  # Stage 3: icon-find (synonym 기반)
  if ($rc -ne 0 -and $tryStage3 -and $allowMouseFallback) {
    try {
      $captured = ""
      $oldOut = [Console]::Out
      $sb = New-Object System.IO.StringWriter
      [Console]::SetOut($sb)
      try {
        Invoke-MacroIconFind -Rest @("--label",$label,"--match",$match,"--max-size","96","--limit","5","--json-only") | Out-Null
      } finally { [Console]::SetOut($oldOut) }
      $captured = $sb.ToString()
      $env_ = $captured | ConvertFrom-Json -ErrorAction SilentlyContinue
      if ($env_ -and $env_.status -eq "ok" -and $env_.top -and $env_.top.score -ge 60) {
        # 좌표 클릭
        $cx = [int]$env_.top.center.x
        $cy = [int]$env_.top.center.y
        $r3 = Invoke-NativeHelper -ArgList @("-Action","click","-X","$cx","-Y","$cy","-Button","left")
        if ($r3.Json -and $r3.Json.status -eq "ok") {
          $strategy = "icon_find"
          $rc = 0
          $resultLine = "ok smart-click '$label' strategy=icon_find @($cx,$cy) score=$($env_.top.score) mouse_moved=True"
        }
      }
    } catch { }
  }

  # Stage 4: OCR+UIA fusion — ocr-uia-invoke 액션이 한 프로세스 안에서
  # OCR 매칭 + UIA element 탐색 + InvokePattern.Invoke() 까지 다 처리.
  # v0.9.0 의 fuse(read-only) → wrapper 가 element name 으로 다시 uia-invoke 하던
  # 패턴은 Name 비어있는 element 에 대해 못 동작했음. v1.0.0 부터는 element handle
  # 자체로 invoke 하므로 Name 없어도 OK (AutomationId / ClassName 만 있어도).
  if ($rc -ne 0 -and $tryStage4 -and -not $disableOcr) {
    try {
      $invokeArgs = @("-Action","ocr-uia-invoke","-OcrText",$label,"-OcrMatch","contains")
      if ($match) { $invokeArgs += @("-Match", $match) }
      if ($ocrLang) { $invokeArgs += @("-OcrLanguage", $ocrLang) }
      $rOuInv = Invoke-NativeHelper -ArgList $invokeArgs
      if ($rOuInv.Json -and $rOuInv.Json.status -eq "ok") {
        # 마우스 안 움직임 — element 직접 invoke 성공
        $strategy = "fusion_uia_invoke"
        $rc = 0
        $idLabel = ""
        if ($rOuInv.Json.uia_name) { $idLabel = "name='$($rOuInv.Json.uia_name)'" }
        elseif ($rOuInv.Json.uia_automation_id) { $idLabel = "id='$($rOuInv.Json.uia_automation_id)'" }
        elseif ($rOuInv.Json.uia_class_name) { $idLabel = "class='$($rOuInv.Json.uia_class_name)'" }
        $resultLine = "ok smart-click '$label' strategy=fusion_uia_invoke method=$($rOuInv.Json.method) $idLabel mouse_moved=False"
      } elseif ($rOuInv.Json -and $rOuInv.Json.reason -eq "no_invoke_pattern" -and $allowMouseFallback) {
        # element 는 있지만 invoke pattern 없음 → 좌표 클릭 fallback
        $fcx = [int]$rOuInv.Json.fallback_coord.x
        $fcy = [int]$rOuInv.Json.fallback_coord.y
        $rFc = Invoke-NativeHelper -ArgList @("-Action","click","-X","$fcx","-Y","$fcy","-Button","left")
        if ($rFc.Json -and $rFc.Json.status -eq "ok") {
          $strategy = "fusion_coord"
          $rc = 0
          $resultLine = "ok smart-click '$label' strategy=fusion_coord @($fcx,$fcy) ocr_score=$($rOuInv.Json.ocr_score) mouse_moved=True"
        }
      }
    } catch { }
  }

  # Stage 5: OCR text 좌표 (UIA element 없는 순수 캔버스/이미지 표면)
  # OCR도 좌표 기반 클릭 → --allow-mouse-fallback 필요. min-score=70.
  if ($rc -ne 0 -and $tryStage5 -and $allowMouseFallback -and -not $disableOcr) {
    try {
      $ocrArgs = @("-Action","ocr-find-text","-OcrText",$label,"-OcrMatch","contains","-OcrMaxCandidates","8")
      if ($ocrLang) { $ocrArgs += @("-OcrLanguage", $ocrLang) }
      $rOcr = Invoke-NativeHelper -ArgList $ocrArgs
      if ($rOcr.Json -and $rOcr.Json.status -eq "ok" -and $rOcr.Json.top -and [int]$rOcr.Json.top.score -ge 70) {
        $oTop = $rOcr.Json.top
        $ocx = [int]$oTop.cx; $ocy = [int]$oTop.cy
        $rOcrClick = Invoke-NativeHelper -ArgList @("-Action","click","-X","$ocx","-Y","$ocy","-Button","left")
        if ($rOcrClick.Json -and $rOcrClick.Json.status -eq "ok") {
          $strategy = "ocr_text"
          $rc = 0
          $resultLine = "ok smart-click '$label' strategy=ocr_text matched='$($oTop.text)' score=$($oTop.score) @($ocx,$ocy) mouse_moved=True"
        }
      }
    } catch { }
  }

  # Stage 6: vision-click-precise (옵션, 마지막)
  if ($rc -ne 0 -and $tryStage6 -and $allowVision) {
    # vision-click-precise는 cli.mjs 의존이라 가능할 때만
    if ($Script:CliPath) {
      $vargs = @("macro","vision-click-precise","--describe",$label)
      if ($match) { $vargs += @("--window", $match) }
      $strategy = "vision_attempt"
      # 호출은 wrapper 자기 자신 (재귀)
      $vresult = & $PSCommandPath -AllowLiveControl -Quiet -Brief @vargs
      if ($LASTEXITCODE -eq 0) {
        $rc = 0
        $strategy = "vision_precise"
        $resultLine = "ok smart-click '$label' strategy=vision_precise mouse_moved=True"
      }
    }
  }

  $sw.Stop()
  $elapsed = [int]$sw.Elapsed.TotalMilliseconds

  # 클릭 검증 (옵션)
  $verified = $true
  if ($rc -eq 0 -and $verifyLabel) {
    $waitArgs = @("macro","wait-label","--label",$verifyLabel,"--timeout-ms","$verifyTimeout")
    if ($match) { $waitArgs += @("--window", $match) }
    & $PSCommandPath @waitArgs | Out-Null
    $verified = ($LASTEXITCODE -eq 0)
    if (-not $verified) {
      if ($Brief) { [Console]::Out.WriteLine("partial smart-click '$label' strategy=$strategy verify_failed='$verifyLabel'") }
      return 2
    }
  }

  # v0.9.0: 클릭 후 화면 변화 검증 (옵션)
  # v1.0.0: --retry-on-no-change N 옵션과 결합 — false 시 cascade 한 번 더 시도
  $screenVerified = $true
  $screenChangedRatio = 0.0
  $retryCount = 0
  if ($rc -eq 0 -and $verifyScreen -and $verifyBeforePng) {
    Start-Sleep -Milliseconds $verifyWaitMs
    $tag2 = (Get-Date).ToString("HHmmss-fff")
    $verifyAfterPng = Join-Path $Script:CacheDir ("smartclick-after-$tag2.png")
    $vrAft = Invoke-NativeHelper -ArgList @("-Action","screenshot","-OutPath",$verifyAfterPng,
              "-ScreenshotX","$($verifyDiffRegion.x)","-ScreenshotY","$($verifyDiffRegion.y)",
              "-ScreenshotW","$($verifyDiffRegion.width)","-ScreenshotH","$($verifyDiffRegion.height)")
    if ($vrAft.Json -and $vrAft.Json.status -eq "ok") {
      $vrDiff = Invoke-NativeHelper -ArgList @("-Action","screenshot-diff",
                "-DiffBefore",$verifyBeforePng,"-DiffAfter",$verifyAfterPng,"-DiffThreshold","16")
      if ($vrDiff.Json -and $vrDiff.Json.status -eq "ok") {
        $screenChangedRatio = [double]$vrDiff.Json.changed_ratio
        $screenVerified = [bool]$vrDiff.Json.changed
      }
    }
    Remove-Item -LiteralPath $verifyBeforePng -Force -ErrorAction SilentlyContinue
    if ($verifyAfterPng) { Remove-Item -LiteralPath $verifyAfterPng -Force -ErrorAction SilentlyContinue }

    # 화면 변화 없음 + retry 옵션 활성 → 같은 cascade 한 번 더
    while (-not $screenVerified -and $retryCount -lt $retryOnNoChange) {
      $retryCount++
      # 새 before 캡처
      $tagR = (Get-Date).ToString("HHmmss-fff")
      $verifyBeforePng = Join-Path $Script:CacheDir ("smartclick-retry-before-$tagR.png")
      $vrR = Invoke-NativeHelper -ArgList @("-Action","screenshot","-OutPath",$verifyBeforePng,
              "-ScreenshotX","$($verifyDiffRegion.x)","-ScreenshotY","$($verifyDiffRegion.y)",
              "-ScreenshotW","$($verifyDiffRegion.width)","-ScreenshotH","$($verifyDiffRegion.height)")
      if (-not ($vrR.Json -and $vrR.Json.status -eq "ok")) { break }

      # cascade 재실행 — Stage 1 (UIA Pattern) 한 번 만 (retry 는 단순화)
      $rArgs = @("-Action","uia-invoke","-Label",$label)
      if ($match) { $rArgs += @("-Match", $match) }
      if ($role)  { $rArgs += @("-Role", $role) }
      $rRetry = Invoke-NativeHelper -ArgList $rArgs
      # retry 가 새로운 strategy 를 잡을 수도 있음
      if ($rRetry.Json -and $rRetry.Json.status -eq "ok") {
        $strategy = "$strategy+retry_uia_pattern"
      } elseif ($allowMouseFallback -and -not $disableOcr) {
        # 폴백: ocr-uia-invoke 한 번 더
        $rRetry2 = Invoke-NativeHelper -ArgList @("-Action","ocr-uia-invoke","-OcrText",$label,"-OcrMatch","contains")
        if ($rRetry2.Json -and $rRetry2.Json.status -eq "ok") {
          $strategy = "$strategy+retry_fusion"
        }
      }

      Start-Sleep -Milliseconds $verifyWaitMs
      $tagR2 = (Get-Date).ToString("HHmmss-fff")
      $verifyAfterPng = Join-Path $Script:CacheDir ("smartclick-retry-after-$tagR2.png")
      $vrAft2 = Invoke-NativeHelper -ArgList @("-Action","screenshot","-OutPath",$verifyAfterPng,
                "-ScreenshotX","$($verifyDiffRegion.x)","-ScreenshotY","$($verifyDiffRegion.y)",
                "-ScreenshotW","$($verifyDiffRegion.width)","-ScreenshotH","$($verifyDiffRegion.height)")
      if ($vrAft2.Json -and $vrAft2.Json.status -eq "ok") {
        $vrDiff2 = Invoke-NativeHelper -ArgList @("-Action","screenshot-diff",
                  "-DiffBefore",$verifyBeforePng,"-DiffAfter",$verifyAfterPng,"-DiffThreshold","16")
        if ($vrDiff2.Json -and $vrDiff2.Json.status -eq "ok") {
          $screenChangedRatio = [double]$vrDiff2.Json.changed_ratio
          $screenVerified = [bool]$vrDiff2.Json.changed
        }
      }
      Remove-Item -LiteralPath $verifyBeforePng -Force -ErrorAction SilentlyContinue
      if ($verifyAfterPng) { Remove-Item -LiteralPath $verifyAfterPng -Force -ErrorAction SilentlyContinue }
    }

    if (-not $screenVerified) {
      if ($Brief) {
        [Console]::Out.WriteLine("partial smart-click '$label' strategy=$strategy screen_unchanged ratio=$screenChangedRatio retries=$retryCount")
      }
      return 2
    }
  }

  if ($rc -ne 0) {
    # v1.1.0: hint 가 있었고 그 stage 가 실패했으면 cascade 전체 활성화 후 재시도.
    # 환경 변화 (UI 업데이트) 로 학습된 strategy 가 더 이상 안 통할 때 안전망.
    if ($hintedStrategy) {
      $tryStage1 = $true; $tryStage2 = $true; $tryStage3 = $true
      $tryStage4 = $true; $tryStage5 = $true; $tryStage6 = $true
      $hintedStrategy = $null   # 두 번째 시도에서 hint 영향 없게

      # Stage 1 재시도 (hint 외의 가장 안전한 stage 부터)
      $args = @("-Action","uia-invoke","-Label",$label)
      if ($match) { $args += @("-Match", $match) }
      if ($role)  { $args += @("-Role", $role) }
      $r1f = Invoke-NativeHelper -ArgList $args
      if ($r1f.Json -and $r1f.Json.status -eq "ok") {
        $strategy = "uia_pattern+hint_fallback"; $rc = 0
        $resultLine = "ok smart-click '$label' strategy=uia_pattern hint_fallback method=$($r1f.Json.method) mouse_moved=False"
      } elseif ($allowMouseFallback -and -not $disableOcr) {
        # Stage 4 재시도 — hint 가 fusion 류였을 가능성 높음
        $invokeArgs = @("-Action","ocr-uia-invoke","-OcrText",$label,"-OcrMatch","contains")
        if ($match) { $invokeArgs += @("-Match", $match) }
        if ($ocrLang) { $invokeArgs += @("-OcrLanguage", $ocrLang) }
        $rOuf = Invoke-NativeHelper -ArgList $invokeArgs
        if ($rOuf.Json -and $rOuf.Json.status -eq "ok") {
          $strategy = "fusion_uia_invoke+hint_fallback"; $rc = 0
          $resultLine = "ok smart-click '$label' strategy=fusion_uia_invoke hint_fallback method=$($rOuf.Json.method) mouse_moved=False"
        }
      }
    }
  }

  if ($rc -ne 0) {
    # 임시 PNG 정리
    if ($verifyBeforePng -and (Test-Path -LiteralPath $verifyBeforePng)) {
      Remove-Item -LiteralPath $verifyBeforePng -Force -ErrorAction SilentlyContinue
    }
    if ($Brief) { [Console]::Out.WriteLine("partial smart-click '$label' all_strategies_failed allow_vision=$allowVision allow_mouse=$allowMouseFallback") }
    # v1.1.0: history append (실패)
    if (-not $disableHistory) {
      _History-Append -Label $label -Match $match -Strategy "none" -Success $false -ElapsedMs ([int]$sw.Elapsed.TotalMilliseconds)
    }
    return 2
  }

  # v1.1.0: history append (성공). strategy 의 +hint_fallback 같은 suffix 는 떼고 base strategy 만 저장.
  if (-not $disableHistory) {
    $baseStrategy = $strategy -replace '\+.*$', ''
    _History-Append -Label $label -Match $match -Strategy $baseStrategy -Success $true -ElapsedMs ([int]$sw.Elapsed.TotalMilliseconds)
  }

  if ($Brief) {
    if ($verifyLabel) { $resultLine += " verified='$verifyLabel'" }
    if ($verifyScreen) { $resultLine += " screen_changed=$screenVerified ratio=$screenChangedRatio" }
    if ($hintedStrategy) { $resultLine += " hint='$hintedStrategy'" }
    $resultLine += " elapsed_ms=$elapsed"
    [Console]::Out.WriteLine($resultLine)
  } else {
    [Console]::Out.WriteLine(([pscustomobject]@{
      schema = "cucp.smart-click/v1"
      status = "ok"
      label = $label
      strategy = $strategy
      hinted_strategy = $hintedStrategy
      verified = $verified
      verify_label = $verifyLabel
      verify_screen_changed = $screenVerified
      verify_screen_ratio = $screenChangedRatio
      elapsed_ms = $elapsed
    } | ConvertTo-Json -Depth 4))
  }
  return 0
}

# ============================================================================
# macro watch ─ 연속 관찰 모드 (continuous observation)
# ============================================================================
# 매 액션 후 자동으로 UIA refresh + foreground 변화 감지.
# 자율 작업 시 화면이 바뀐 줄 모르고 캐시된 좌표로 재시도하는 문제 방지.
#
# 사용 예:
#   macro watch --interval-ms 500 --max-cycles 20 --until-label "Saved"
#
# 매 cycle마다 brief 한 줄 emit:
#   cycle=N foreground='...' delta=changed/same affordance_count=M
# ============================================================================

function Invoke-MacroWatch {
  param([string[]]$Rest)
  $intervalMs = [int](_Read-OptValue -Rest $Rest -Name "--interval-ms")
  $maxCycles = [int](_Read-OptValue -Rest $Rest -Name "--max-cycles")
  $untilLabel = _Read-OptValue -Rest $Rest -Name "--until-label"
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  if ($intervalMs -le 0) { $intervalMs = 500 }
  if ($maxCycles -le 0) { $maxCycles = 20 }

  $cycles = New-Object System.Collections.ArrayList
  $prevTitle = ""
  $prevHwnd = 0
  $foundUntilLabel = $false
  for ($i = 1; $i -le $maxCycles; $i++) {
    # foreground
    $rFocused = Invoke-NativeHelper -ArgList @("-Action","focused")
    $title = ""; $hwnd = 0
    if ($rFocused.Json -and $rFocused.Json.foreground) {
      $title = "$($rFocused.Json.foreground.title)"
      $hwnd = [int64]$rFocused.Json.foreground.hwnd
    }
    $delta = if ($i -eq 1) { "init" } elseif ($title -eq $prevTitle -and $hwnd -eq $prevHwnd) { "same" } else { "changed" }

    # until-label 검사 (옵션)
    $hasLabel = $false
    if ($untilLabel) {
      $matchArg = if ($match) { $match } else { $title }
      $rFind = Invoke-NativeHelper -ArgList @("-Action","uia-find","-Match",$matchArg,"-Label",$untilLabel)
      if ($rFind.Json -and $rFind.Json.status -eq "ok") { $hasLabel = $true }
    }

    if ($Brief) {
      $line = "cycle=$i title='$title' delta=$delta"
      if ($untilLabel) { $line += " until='$untilLabel'=$hasLabel" }
      [Console]::Out.WriteLine($line)
    }
    [void]$cycles.Add([ordered]@{
      cycle = $i
      title = $title
      hwnd = $hwnd
      delta = $delta
      until_label_present = if ($untilLabel) { $hasLabel } else { $null }
      collected_at = (Get-Date).ToString("o")
    })
    if ($untilLabel -and $hasLabel) { $foundUntilLabel = $true; break }
    $prevTitle = $title; $prevHwnd = $hwnd
    if ($i -lt $maxCycles) { Start-Sleep -Milliseconds $intervalMs }
  }
  if (-not $Brief) {
    [Console]::Out.WriteLine(([pscustomobject]@{
      schema = "cucp.watch/v1"
      status = if ($untilLabel -and -not $foundUntilLabel) { "partial" } else { "ok" }
      until_label = $untilLabel
      until_label_found = $foundUntilLabel
      cycles = @($cycles)
    } | ConvertTo-Json -Depth 6))
  }
  if ($untilLabel -and -not $foundUntilLabel) { return 2 }
  return 0
}

# ============================================================================
# OCR 매크로 (Windows.Media.Ocr) — 브라우저 캔버스/이미지 표면 커버
# ============================================================================
# UIA로 안 잡히는 표면(브라우저 canvas, Electron 커스텀 그리기, PDF 이미지,
# 게임 UI 일부)을 OCR로 텍스트+좌표 추출해서 클릭/검색합니다.
#
# 주의: OCR은 BoundingRectangle 정확도가 폰트 크기/대비/회전/언어팩에 의존합니다.
#       UIA가 가능하면 항상 UIA Pattern (uia-invoke / smart-click) 우선 사용.
# ============================================================================

# macro ocr-screen [--region x,y,w,h] [--language ko]
# 화면 영역 캡처 + OCR. read-only.
function Invoke-MacroOcrScreen {
  param([string[]]$Rest)
  $region = _Read-OptValue -Rest $Rest -Name "--region"
  $lang = _Read-OptValue -Rest $Rest -Name "--language"
  $args = @("-Action","ocr-screen")
  if ($region) {
    # "x,y,w,h" 형식
    $parts = $region -split ','
    if ($parts.Count -eq 4) {
      $args += @("-ScreenshotX",$parts[0].Trim(),"-ScreenshotY",$parts[1].Trim(),
                 "-ScreenshotW",$parts[2].Trim(),"-ScreenshotH",$parts[3].Trim())
    }
  }
  if ($lang) { $args += @("-OcrLanguage", $lang) }
  $r = Invoke-NativeHelper -ArgList $args
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok ocr-screen lines=$($r.Json.line_count) words=$($r.Json.word_count) language=$($r.Json.engine_language) elapsed_ms=$($r.ElapsedMs)")
    } else {
      [Console]::Out.WriteLine("err ocr-screen reason=$($r.Json.reason) exit=$($r.ExitCode)")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $r.ExitCode
}

# macro ocr-image --path <png> [--language ko]
# 임의 PNG 파일 OCR. read-only. 좌표는 이미지 픽셀 기준.
function Invoke-MacroOcrImage {
  param([string[]]$Rest)
  $path = _Read-OptValue -Rest $Rest -Name "--path"
  $lang = _Read-OptValue -Rest $Rest -Name "--language"
  if (-not $path) { throw "macro ocr-image requires --path <png>" }
  $args = @("-Action","ocr-image","-OcrPath",$path)
  if ($lang) { $args += @("-OcrLanguage", $lang) }
  $r = Invoke-NativeHelper -ArgList $args
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok ocr-image path='$path' lines=$($r.Json.line_count) words=$($r.Json.word_count) language=$($r.Json.engine_language) elapsed_ms=$($r.ElapsedMs)")
    } else {
      [Console]::Out.WriteLine("err ocr-image path='$path' reason=$($r.Json.reason) exit=$($r.ExitCode)")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $r.ExitCode
}

# macro ocr-find-text --text <s> [--match contains|exact|prefix] [--region x,y,w,h]
#                     [--path <png>] [--language ko] [--max-candidates N]
# 화면(또는 이미지)에서 텍스트 위치 찾기. read-only.
# 출력: top 후보의 (cx,cy) 클릭 좌표 + score
function Invoke-MacroOcrFindText {
  param([string[]]$Rest)
  $text = _Read-OptValue -Rest $Rest -Name "--text"
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $region = _Read-OptValue -Rest $Rest -Name "--region"
  $path = _Read-OptValue -Rest $Rest -Name "--path"
  $lang = _Read-OptValue -Rest $Rest -Name "--language"
  $maxN = [int](_Read-OptValue -Rest $Rest -Name "--max-candidates")
  if (-not $text) { throw "macro ocr-find-text requires --text" }
  if (-not $match) { $match = "contains" }
  $args = @("-Action","ocr-find-text","-OcrText",$text,"-OcrMatch",$match)
  if ($maxN -gt 0) { $args += @("-OcrMaxCandidates","$maxN") }
  if ($lang) { $args += @("-OcrLanguage", $lang) }
  if ($path) { $args += @("-OcrPath", $path) }
  if ($region) {
    $parts = $region -split ','
    if ($parts.Count -eq 4) {
      $args += @("-ScreenshotX",$parts[0].Trim(),"-ScreenshotY",$parts[1].Trim(),
                 "-ScreenshotW",$parts[2].Trim(),"-ScreenshotH",$parts[3].Trim())
    }
  }
  $r = Invoke-NativeHelper -ArgList $args
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      $top = $r.Json.top
      [Console]::Out.WriteLine("ok ocr-find-text '$text' match='$match' top='$($top.text)' score=$($top.score) cx=$($top.cx) cy=$($top.cy) candidates=$($r.Json.candidate_count) elapsed_ms=$($r.ElapsedMs)")
    } else {
      [Console]::Out.WriteLine("partial ocr-find-text '$text' reason=$($r.Json.reason) exit=$($r.ExitCode)")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $r.ExitCode
}

# macro ocr-click --text <s> [--match contains|exact|prefix] [--region x,y,w,h]
#                 [--button left|right|double] [--language ko] [--min-score 70]
# OCR로 텍스트 좌표 찾고 click. -AllowLiveControl 필수 (라이브 actuation).
# 안전 정책:
#   - min-score 미달 → partial(2) 거부
#   - top 후보 없음 → partial(2) 거부
function Invoke-MacroOcrClick {
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro ocr-click requires -AllowLiveControl" }
  $text = _Read-OptValue -Rest $Rest -Name "--text"
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $region = _Read-OptValue -Rest $Rest -Name "--region"
  $btn = _Read-OptValue -Rest $Rest -Name "--button"
  $lang = _Read-OptValue -Rest $Rest -Name "--language"
  $minScore = [int](_Read-OptValue -Rest $Rest -Name "--min-score")
  if (-not $text) { throw "macro ocr-click requires --text" }
  if (-not $match) { $match = "contains" }
  if (-not $btn) { $btn = "left" }
  if ($minScore -le 0) { $minScore = 70 }

  # Stage A: OCR 좌표 찾기 (read-only)
  $findArgs = @("-Action","ocr-find-text","-OcrText",$text,"-OcrMatch",$match,"-OcrMaxCandidates","8")
  if ($lang) { $findArgs += @("-OcrLanguage", $lang) }
  if ($region) {
    $parts = $region -split ','
    if ($parts.Count -eq 4) {
      $findArgs += @("-ScreenshotX",$parts[0].Trim(),"-ScreenshotY",$parts[1].Trim(),
                     "-ScreenshotW",$parts[2].Trim(),"-ScreenshotH",$parts[3].Trim())
    }
  }
  $rFind = Invoke-NativeHelper -ArgList $findArgs
  if (-not ($rFind.Json -and $rFind.Json.status -eq "ok")) {
    if ($Brief) { [Console]::Out.WriteLine("partial ocr-click '$text' reason=no_text_match exit=$($rFind.ExitCode)") }
    return 2
  }
  $top = $rFind.Json.top
  if ([int]$top.score -lt $minScore) {
    if ($Brief) {
      [Console]::Out.WriteLine("partial ocr-click '$text' low_confidence score=$($top.score) min=$minScore matched='$($top.text)'")
    }
    return 2
  }

  # Stage B: 좌표 클릭 (라이브)
  $cx = [int]$top.cx; $cy = [int]$top.cy
  $rClick = Invoke-NativeHelper -ArgList @("-Action","click","-X","$cx","-Y","$cy","-Button",$btn)
  _Trajectory-Append -Kind "click" -Payload @{
    source = "ocr_click"
    x = $cx; y = $cy; button = $btn
    text = $text; matched_text = $top.text; score = $top.score
    exit = $rClick.ExitCode
  }
  if ($Brief) {
    if ($rClick.Json -and $rClick.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok ocr-click '$text' matched='$($top.text)' score=$($top.score) @($cx,$cy) button=$btn elapsed_ms=$($rClick.ElapsedMs)")
    } else {
      [Console]::Out.WriteLine("err ocr-click '$text' click_failed exit=$($rClick.ExitCode)")
    }
  } else {
    if ($rClick.Raw) { [Console]::Out.Write($rClick.Raw) }
  }
  return $rClick.ExitCode
}

# ============================================================================
# v0.9.0 — OCR+UIA fusion + screenshot diff verify
# ============================================================================
# 핵심 통찰:
#   1. OCR 이 보지만 UIA 가 비어있는 element (Electron 일부) → fuse 로 InvokePattern 호출 가능
#   2. 좌표 클릭은 "정말 통했는지" 모름 → 클릭 전후 스크린샷 diff 로 검증
# 두 매크로는 read-only 이지만 click-and-verify-screen 은 actuation 매크로.
# ============================================================================

# macro ocr-uia-fuse --text <s> [--match contains|exact|prefix] [--match-window <s>]
#                    [--region x,y,w,h] [--language ko]
# OCR 1순위 좌표 위에 UIA element 가 있으면 invoke 패턴 가능 여부 보고 (read-only).
function Invoke-MacroOcrUiaFuse {
  param([string[]]$Rest)
  $text = _Read-OptValue -Rest $Rest -Name "--text"
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $matchWindow = _Read-OptValue -Rest $Rest -Name "--match-window"
  $region = _Read-OptValue -Rest $Rest -Name "--region"
  $lang = _Read-OptValue -Rest $Rest -Name "--language"
  if (-not $text) { throw "macro ocr-uia-fuse requires --text" }
  if (-not $match) { $match = "contains" }
  $argList = @("-Action","ocr-uia-fuse","-OcrText",$text,"-OcrMatch",$match)
  if ($matchWindow) { $argList += @("-Match", $matchWindow) }
  if ($lang) { $argList += @("-OcrLanguage", $lang) }
  if ($region) {
    $parts = $region -split ','
    if ($parts.Count -eq 4) {
      $argList += @("-ScreenshotX",$parts[0].Trim(),"-ScreenshotY",$parts[1].Trim(),
                    "-ScreenshotW",$parts[2].Trim(),"-ScreenshotH",$parts[3].Trim())
    }
  }
  $r = Invoke-NativeHelper -ArgList $argList
  $exitCode = [int]$r.ExitCode
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      $rec = $r.Json.recommendation
      $canI = $r.Json.can_invoke
      $pat = "n/a"
      if ($r.Json.invoke_pattern) { $pat = $r.Json.invoke_pattern }
      $top = $r.Json.ocr_top
      [Console]::Out.WriteLine("ok ocr-uia-fuse '$text' top='$($top.text)' score=$($top.score) can_invoke=$canI pattern=$pat recommend=$rec elapsed_ms=$($r.ElapsedMs)")
    } else {
      [Console]::Out.WriteLine("partial ocr-uia-fuse '$text' reason=$($r.Json.reason) recommend=$($r.Json.recommendation)")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $exitCode
}

# macro ocr-uia-invoke --text <s> [--match contains|exact|prefix] [--match-window <s>]
#                      [--language ko]
# OCR 좌표 위 UIA element 를 한 프로세스 안에서 직접 InvokePattern.Invoke().
# 마우스 안 움직임. UIA Name 비어있어도 AutomationId / ClassName 으로 invoke.
# -AllowLiveControl 필수 (실제 actuation).
function Invoke-MacroOcrUiaInvoke {
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro ocr-uia-invoke requires -AllowLiveControl" }
  $text = _Read-OptValue -Rest $Rest -Name "--text"
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $matchWindow = _Read-OptValue -Rest $Rest -Name "--match-window"
  $lang = _Read-OptValue -Rest $Rest -Name "--language"
  if (-not $text) { throw "macro ocr-uia-invoke requires --text" }
  if (-not $match) { $match = "contains" }
  $argList = @("-Action","ocr-uia-invoke","-OcrText",$text,"-OcrMatch",$match)
  if ($matchWindow) { $argList += @("-Match", $matchWindow) }
  if ($lang) { $argList += @("-OcrLanguage", $lang) }
  $r = Invoke-NativeHelper -ArgList $argList
  $exitCode = [int]$r.ExitCode
  _Trajectory-Append -Kind "click" -Payload @{
    source = "ocr_uia_invoke"
    text = $text
    method = "$($r.Json.method)"
    uia_name = "$($r.Json.uia_name)"
    uia_automation_id = "$($r.Json.uia_automation_id)"
    exit = $exitCode
  }
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      $idLabel = "n/a"
      if ($r.Json.uia_name) { $idLabel = "name='$($r.Json.uia_name)'" }
      elseif ($r.Json.uia_automation_id) { $idLabel = "id='$($r.Json.uia_automation_id)'" }
      elseif ($r.Json.uia_class_name) { $idLabel = "class='$($r.Json.uia_class_name)'" }
      [Console]::Out.WriteLine("ok ocr-uia-invoke '$text' method=$($r.Json.method) $idLabel score=$($r.Json.ocr_score) mouse_moved=False elapsed_ms=$($r.ElapsedMs)")
    } else {
      [Console]::Out.WriteLine("partial ocr-uia-invoke '$text' reason=$($r.Json.reason) exit=$exitCode")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $exitCode
}

# macro screenshot-diff --before <png> --after <png> [--threshold N]
#                       [--region x,y,w,h] [--ignore-region "x,y,w,h;x2,y2,w2,h2"]
# 두 PNG 의 픽셀 변화 비율 측정. read-only.
# v1.0.0: --ignore-region 으로 동영상/애니메이션 영역 마스킹 (false positive 방지)
function Invoke-MacroScreenshotDiff {
  param([string[]]$Rest)
  $before = _Read-OptValue -Rest $Rest -Name "--before"
  $after  = _Read-OptValue -Rest $Rest -Name "--after"
  $thr    = [int](_Read-OptValue -Rest $Rest -Name "--threshold")
  $region = _Read-OptValue -Rest $Rest -Name "--region"
  $ignore = _Read-OptValue -Rest $Rest -Name "--ignore-region"
  if (-not $before -or -not $after) { throw "macro screenshot-diff requires --before and --after" }
  $argList = @("-Action","screenshot-diff","-DiffBefore",$before,"-DiffAfter",$after)
  if ($thr -gt 0) { $argList += @("-DiffThreshold","$thr") }
  if ($ignore) { $argList += @("-DiffIgnoreRegions", $ignore) }
  if ($region) {
    $parts = $region -split ','
    if ($parts.Count -eq 4) {
      $argList += @("-ScreenshotX",$parts[0].Trim(),"-ScreenshotY",$parts[1].Trim(),
                    "-ScreenshotW",$parts[2].Trim(),"-ScreenshotH",$parts[3].Trim())
    }
  }
  $r = Invoke-NativeHelper -ArgList $argList
  $exitCode = [int]$r.ExitCode
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      $ignoredHint = ""
      if ($r.Json.ignored_pixels -gt 0) { $ignoredHint = " ignored=$($r.Json.ignored_pixels)" }
      [Console]::Out.WriteLine("ok screenshot-diff changed=$($r.Json.changed) ratio=$($r.Json.changed_ratio) pixels=$($r.Json.changed_pixels)/$($r.Json.effective_pixels)$ignoredHint elapsed_ms=$($r.ElapsedMs)")
    } else {
      [Console]::Out.WriteLine("err screenshot-diff reason=$($r.Json.reason) exit=$exitCode")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $exitCode
}

# macro click-and-verify-screen --x <n> --y <n> [--button left|right|double]
#                               [--region x,y,w,h] [--threshold N] [--wait-ms N]
# 화면 캡처 → 클릭 → 대기 → 다시 캡처 → diff 로 변화 확인.
# 변화 없으면 partial(2) 반환 → 클릭이 안 통했다는 확실한 증거.
# -AllowLiveControl 필수.
function Invoke-MacroClickAndVerifyScreen {
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro click-and-verify-screen requires -AllowLiveControl" }
  $x = [int](_Read-OptValue -Rest $Rest -Name "--x")
  $y = [int](_Read-OptValue -Rest $Rest -Name "--y")
  $btn = _Read-OptValue -Rest $Rest -Name "--button"
  if (-not $btn) { $btn = "left" }
  $thr = [int](_Read-OptValue -Rest $Rest -Name "--threshold")
  $waitMs = [int](_Read-OptValue -Rest $Rest -Name "--wait-ms")
  $region = _Read-OptValue -Rest $Rest -Name "--region"
  if ($x -le 0 -or $y -le 0) { throw "macro click-and-verify-screen requires --x and --y" }
  if ($waitMs -le 0) { $waitMs = 500 }
  if ($thr -le 0) { $thr = 16 }

  # diff 영역 — 명시 없으면 클릭 좌표 주변 200x200 사각형 (작은 변화도 잡기 좋게)
  $rx = $x - 100; $ry = $y - 100; $rw = 200; $rh = 200
  if ($region) {
    $parts = $region -split ','
    if ($parts.Count -eq 4) {
      $rx = [int]$parts[0].Trim(); $ry = [int]$parts[1].Trim()
      $rw = [int]$parts[2].Trim(); $rh = [int]$parts[3].Trim()
    }
  }
  if ($rx -lt 0) { $rx = 0 }
  if ($ry -lt 0) { $ry = 0 }

  $tag = (Get-Date).ToString("HHmmss-fff")
  $beforePng = Join-Path $Script:CacheDir ("verify-before-$tag.png")
  $afterPng  = Join-Path $Script:CacheDir ("verify-after-$tag.png")

  # 1) before 캡처
  $rB = Invoke-NativeHelper -ArgList @("-Action","screenshot","-OutPath",$beforePng,
       "-ScreenshotX","$rx","-ScreenshotY","$ry","-ScreenshotW","$rw","-ScreenshotH","$rh")
  if (-not ($rB.Json -and $rB.Json.status -eq "ok")) {
    Remove-Item -LiteralPath $beforePng -Force -ErrorAction SilentlyContinue
    if ($Brief) { [Console]::Out.WriteLine("err click-and-verify-screen capture_before_failed") }
    return 1
  }

  # 2) 클릭
  $rC = Invoke-NativeHelper -ArgList @("-Action","click","-X","$x","-Y","$y","-Button",$btn)
  _Trajectory-Append -Kind "click" -Payload @{
    source = "click_and_verify_screen"; x = $x; y = $y; button = $btn; exit = $rC.ExitCode
  }

  # 3) 대기
  Start-Sleep -Milliseconds $waitMs

  # 4) after 캡처 (절대 좌표 동일 영역)
  $rA = Invoke-NativeHelper -ArgList @("-Action","screenshot","-OutPath",$afterPng,
       "-ScreenshotX","$rx","-ScreenshotY","$ry","-ScreenshotW","$rw","-ScreenshotH","$rh")
  if (-not ($rA.Json -and $rA.Json.status -eq "ok")) {
    Remove-Item -LiteralPath $beforePng,$afterPng -Force -ErrorAction SilentlyContinue
    if ($Brief) { [Console]::Out.WriteLine("err click-and-verify-screen capture_after_failed") }
    return 1
  }

  # 5) diff
  $rD = Invoke-NativeHelper -ArgList @("-Action","screenshot-diff",
       "-DiffBefore",$beforePng,"-DiffAfter",$afterPng,"-DiffThreshold","$thr")
  Remove-Item -LiteralPath $beforePng,$afterPng -Force -ErrorAction SilentlyContinue

  if (-not ($rD.Json -and $rD.Json.status -eq "ok")) {
    if ($Brief) { [Console]::Out.WriteLine("err click-and-verify-screen diff_failed") }
    return 1
  }
  $changed = [bool]$rD.Json.changed
  $ratio = $rD.Json.changed_ratio

  if ($Brief) {
    if ($changed) {
      [Console]::Out.WriteLine("ok click-and-verify-screen @($x,$y) changed=True ratio=$ratio elapsed_ms=$($rD.ElapsedMs)")
    } else {
      [Console]::Out.WriteLine("partial click-and-verify-screen @($x,$y) changed=False ratio=$ratio click_likely_missed")
    }
  } else {
    [Console]::Out.WriteLine(([pscustomobject]@{
      schema = "cucp.click-verify/v1"
      status = if ($changed) { "ok" } else { "partial" }
      x = $x; y = $y; button = $btn
      changed = $changed
      changed_ratio = $ratio
      changed_pixels = $rD.Json.changed_pixels
      total_pixels = $rD.Json.total_pixels
      threshold = $thr
      wait_ms = $waitMs
      diff_region = [ordered]@{ x=$rx; y=$ry; width=$rw; height=$rh }
    } | ConvertTo-Json -Depth 4))
  }
  if (-not $changed) { return 2 }
  return 0
}

# ============================================================================
# Auto-do: self-correcting click loop (라벨 → 위치 변경 시 vision 재시도)
# ============================================================================

function Invoke-MacroAutoDo {
  param([string[]]$Rest)
  $label = _Read-OptValue -Rest $Rest -Name "--label"
  $describe = _Read-OptValue -Rest $Rest -Name "--describe"
  $window = _Read-OptValue -Rest $Rest -Name "--window"
  $maxAttempts = [int](_Read-OptValue -Rest $Rest -Name "--max-attempts")
  $verifyLabel = _Read-OptValue -Rest $Rest -Name "--verify-label"
  $verifyTimeout = [int](_Read-OptValue -Rest $Rest -Name "--verify-timeout-ms")
  if (-not $label -and -not $describe) { throw "macro auto-do requires --label or --describe" }
  if (-not $AllowLiveControl) { throw "macro auto-do requires -AllowLiveControl" }
  if ($maxAttempts -le 0) { $maxAttempts = 3 }
  if ($verifyTimeout -le 0) { $verifyTimeout = 5000 }

  $strategies = @()
  if ($label) { $strategies += "label" }
  if ($label) { $strategies += "vision_label" }  # vision with label as description
  if ($describe) { $strategies += "vision_describe" }
  if (-not $describe -and $label) {
    # auto-build a vision-friendly description
    $describe = "the $label button or element"
    $strategies += "vision_describe"
  }

  $attempt = 0
  $success = $false
  $usedStrategy = ""
  foreach ($strategy in $strategies) {
    if ($success) { break }
    $attempt++
    if ($attempt -gt $maxAttempts) { break }

    Write-Notice -Level "INFO" -Message "auto-do 시도 ${attempt}/$maxAttempts (전략=$strategy)"
    $exitCode = 1

    if ($strategy -eq "label") {
      $args = @("macro", "click-label", "--label", $label, "--no-vision")
      if ($window) { $args += @("--window", $window) }
      $r = Invoke-Cucp -ArgList $args
      $exitCode = $r.ExitCode
    } elseif ($strategy -eq "vision_label") {
      # click-label with vision fallback enabled
      $args = @("macro", "click-label", "--label", $label)
      if ($window) { $args += @("--window", $window) }
      $r = Invoke-Cucp -ArgList $args
      $exitCode = $r.ExitCode
    } elseif ($strategy -eq "vision_describe") {
      $args = @("macro", "vision-click", "--describe", $describe)
      if ($window) { $args += @("--window", $window) }
      $r = Invoke-Cucp -ArgList $args
      $exitCode = $r.ExitCode
    }

    if ($exitCode -eq 0) {
      # Optional verify-label
      if ($verifyLabel) {
        $vargs = @("macro", "wait-label", "--label", $verifyLabel, "--timeout-ms", "$verifyTimeout")
        if ($window) { $vargs += @("--window", $window) }
        $vr = Invoke-Cucp -ArgList $vargs
        if ($vr.ExitCode -eq 0) { $success = $true; $usedStrategy = $strategy }
      } else {
        $success = $true; $usedStrategy = $strategy
      }
    }
  }

  _Trajectory-Append -Kind "auto_do" -Payload @{
    label = $label
    describe = $describe
    window = $window
    attempts = $attempt
    success = $success
    used_strategy = $usedStrategy
  }

  if ($Brief) {
    if ($success) { [Console]::Out.WriteLine("ok auto-do '$label' attempts=$attempt strategy=$usedStrategy") }
    else { [Console]::Out.WriteLine("err auto-do '$label' attempts=$attempt all-strategies-failed") }
  }
  if ($success) { return 0 } else { return 2 }
}

# ============================================================================
# Standardized exit code reference (printed in help, used in trajectory):
#   0   ok
#   1   generic failure / wrapper-side error
#   2   partial / verification failed (e.g. evidence partial, verify-label miss)
#   3   live-control blocked (no -AllowLiveControl)
#   4   coordinate without --after observation
#   124 timeout (Process killed by InvokeTimeoutMs)
# ============================================================================

# ============================================================================
# Trajectory store (working memory) -- persistent NDJSON of recent observations
# and actions. Lets the model recall the last N steps without re-observing.
# ============================================================================

$Script:TrajectoryFile = Join-Path $Script:AuditDir "trajectory.ndjson"
$Script:TrajectoryMax = 200

# v1.1.0: smart-click history learning
# 같은 (label, match) 의 과거 시도 결과를 기억해서 다음 호출 시 가장 자주 성공한
# strategy 부터 시도. cascade 의 앞 단계를 skip 해서 평균 응답 시간 단축.
# 안전: history 가 없거나 corrupt 면 무시 (기존 cascade 그대로). --no-history 로 비활성화.
$Script:HistoryFile = Join-Path $Script:AuditDir "smart-click-history.ndjson"
$Script:HistoryMax = 1000  # rotate 한도 — 1000 라인 넘으면 최신 800개만 유지

function _Trajectory-Append {
  param([string]$Kind, [hashtable]$Payload)
  try {
    $entry = @{
      ts = (Get-Date).ToString("o")
      kind = $Kind
    }
    foreach ($k in $Payload.Keys) { $entry[$k] = $Payload[$k] }
    $line = ($entry | ConvertTo-Json -Compress -Depth 6)
    Add-Content -LiteralPath $Script:TrajectoryFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    # Trim to TrajectoryMax lines
    if (Test-Path -LiteralPath $Script:TrajectoryFile) {
      $info = Get-Item -LiteralPath $Script:TrajectoryFile
      if ($info.Length -gt 1MB) {
        $all = Get-Content -LiteralPath $Script:TrajectoryFile -Encoding UTF8
        if ($all.Count -gt $Script:TrajectoryMax) {
          $tail = $all[($all.Count - $Script:TrajectoryMax)..($all.Count - 1)]
          [System.IO.File]::WriteAllLines($Script:TrajectoryFile, $tail, (New-Object System.Text.UTF8Encoding($true)))
        }
      }
    }
  } catch { }
}

function _Trajectory-Read {
  param([int]$Last = 20)
  if (-not (Test-Path -LiteralPath $Script:TrajectoryFile)) { return @() }
  $all = Get-Content -LiteralPath $Script:TrajectoryFile -Encoding UTF8 -ErrorAction SilentlyContinue
  if (-not $all) { return @() }
  $start = [Math]::Max(0, $all.Count - $Last)
  $tail = $all[$start..($all.Count - 1)]
  $parsed = @()
  foreach ($l in $tail) {
    try { $parsed += ($l | ConvertFrom-Json -ErrorAction Stop) } catch { }
  }
  return $parsed
}

function _Trajectory-Clear {
  if (Test-Path -LiteralPath $Script:TrajectoryFile) {
    Remove-Item -LiteralPath $Script:TrajectoryFile -Force -ErrorAction SilentlyContinue
  }
}

# ============================================================================
# v1.1.0 — smart-click history learning
# ============================================================================
# 모든 smart-click 시도를 NDJSON 으로 기록하고, 같은 (label, match) 의 최근 N 회
# 결과를 통계로 만들어 다음 호출에 "어느 stage 부터 시도해야 빨리 성공할까" 가이드.
#
# Append 레코드 형식:
#   {"ts":"2026-05-25T...","label":"Save","match":"Notepad","strategy":"uia_pattern",
#    "success":true,"elapsed_ms":1024}
#
# 통계 로직 (_History-PickBestStrategy):
#   - 같은 (label, match) 매칭 최근 5건 조회
#   - success=true 인 것들의 strategy 중 가장 자주 등장한 것 반환
#   - 동률 시 더 최근 것 우선
#   - 5건 모두 fail 이면 $null 반환 (기존 cascade 처음부터)
# ============================================================================

# 한 번의 smart-click 결과 append. 1MB / HistoryMax 라인 넘으면 자동 rotate.
function _History-Append {
  param(
    [string]$Label,
    [string]$Match,
    [string]$Strategy,
    [bool]$Success,
    [int]$ElapsedMs
  )
  try {
    $entry = [ordered]@{
      ts = (Get-Date).ToString("o")
      label = $Label
      match = $Match
      strategy = $Strategy
      success = $Success
      elapsed_ms = $ElapsedMs
    }
    $line = ($entry | ConvertTo-Json -Compress -Depth 4)
    Add-Content -LiteralPath $Script:HistoryFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue

    # rotate: 1MB 또는 HistoryMax 초과 시 최신 (HistoryMax * 0.8) 만 유지
    if (Test-Path -LiteralPath $Script:HistoryFile) {
      $info = Get-Item -LiteralPath $Script:HistoryFile
      if ($info.Length -gt 1MB) {
        $all = Get-Content -LiteralPath $Script:HistoryFile -Encoding UTF8
        if ($all.Count -gt $Script:HistoryMax) {
          $keep = [int]($Script:HistoryMax * 0.8)
          $tail = $all[($all.Count - $keep)..($all.Count - 1)]
          [System.IO.File]::WriteAllLines($Script:HistoryFile, $tail, (New-Object System.Text.UTF8Encoding($true)))
        }
      }
    }
  } catch { }
}

# 같은 (label, match) 의 최근 N 회 시도를 읽어 후보 strategy 반환.
# 반환값:
#   - $null  → history 없음 / 모두 실패 / 학습 비활성
#   - string → 추천 strategy 이름 (예: "uia_pattern", "fusion_uia_invoke")
function _History-PickBestStrategy {
  param(
    [string]$Label,
    [string]$Match,
    [int]$LookbackN = 5
  )
  if (-not (Test-Path -LiteralPath $Script:HistoryFile)) { return $null }
  $all = @(Get-Content -LiteralPath $Script:HistoryFile -Encoding UTF8 -ErrorAction SilentlyContinue)
  if (-not $all -or $all.Count -eq 0) { return $null }

  # 같은 (label, match) 의 최근 LookbackN 건 — 뒤에서부터 매칭
  $candidates = New-Object System.Collections.ArrayList
  for ($i = $all.Count - 1; $i -ge 0 -and $candidates.Count -lt $LookbackN; $i--) {
    try {
      $rec = $all[$i] | ConvertFrom-Json -ErrorAction Stop
      if ("$($rec.label)" -eq $Label -and "$($rec.match)" -eq "$Match") {
        [void]$candidates.Add($rec)
      }
    } catch { continue }
  }
  if ($candidates.Count -eq 0) { return $null }

  # 성공한 strategy 들만 카운트, 가장 자주 등장한 것 반환
  $strategyCount = @{}
  foreach ($r in $candidates) {
    if ($r.success -eq $true -and $r.strategy) {
      $key = "$($r.strategy)"
      if (-not $strategyCount.ContainsKey($key)) { $strategyCount[$key] = 0 }
      $strategyCount[$key]++
    }
  }
  if ($strategyCount.Count -eq 0) { return $null }

  # 가장 많이 등장한 strategy. 동률 시 가장 최근 strategy 우선.
  $maxCount = ($strategyCount.Values | Measure-Object -Maximum).Maximum
  $topStrategies = @($strategyCount.Keys | Where-Object { $strategyCount[$_] -eq $maxCount })
  if ($topStrategies.Count -eq 1) { return $topStrategies[0] }
  # 동률 — candidates 는 최신부터이므로 처음 만나는 strategy 가 더 최근
  foreach ($r in $candidates) {
    if ($r.success -eq $true -and $topStrategies -contains "$($r.strategy)") {
      return "$($r.strategy)"
    }
  }
  return $topStrategies[0]
}

# history 전체 통계 (macro session info / metrics 에서 호출 가능)
function _History-Stats {
  if (-not (Test-Path -LiteralPath $Script:HistoryFile)) {
    return [pscustomobject]@{ total = 0; success = 0; success_rate = 0.0; strategies = @{} }
  }
  $all = @(Get-Content -LiteralPath $Script:HistoryFile -Encoding UTF8 -ErrorAction SilentlyContinue)
  if (-not $all) {
    return [pscustomobject]@{ total = 0; success = 0; success_rate = 0.0; strategies = @{} }
  }
  $total = 0; $success = 0
  $byStrategy = @{}
  foreach ($l in $all) {
    try {
      $r = $l | ConvertFrom-Json -ErrorAction Stop
      $total++
      if ($r.success -eq $true) {
        $success++
        $key = "$($r.strategy)"
        if (-not $byStrategy.ContainsKey($key)) { $byStrategy[$key] = 0 }
        $byStrategy[$key]++
      }
    } catch { continue }
  }
  $rate = 0.0
  if ($total -gt 0) { $rate = [Math]::Round(($success / $total) * 100, 1) }
  return [pscustomobject]@{
    total = $total
    success = $success
    success_rate = $rate
    strategies = $byStrategy
  }
}

# ============================================================================
# Helper auto-start -- ensures the Windows-MCP HTTP helper is running before
# operations that require it. Idempotent (returns early if already up).
# ============================================================================

function _Helper-IsUp {
  $r = Invoke-Cucp -ArgList @("tools") -CaptureJson
  return ($r.ExitCode -eq 0 -and $r.Json.status -eq "ok")
}

function _Helper-Ensure {
  param([int]$WaitMs = 8000)
  if (_Helper-IsUp) { return $true }
  Write-Notice -Level "INFO" -Message "helper 미가동 - 자동 기동 시도"
  $r = Invoke-Cucp -ArgList @("start") -CaptureJson
  if ($r.ExitCode -ne 0) {
    Write-Notice -Level "ERROR" -Message "helper 자동 기동 실패 (exit=$($r.ExitCode))"
    return $false
  }
  $deadline = (Get-Date).AddMilliseconds($WaitMs)
  while ((Get-Date) -lt $deadline) {
    if (_Helper-IsUp) {
      Write-Notice -Level "OK" -Message "helper 가동 확인"
      return $true
    }
    Start-Sleep -Milliseconds 500
  }
  Write-Notice -Level "ERROR" -Message "helper 기동했지만 응답 없음 (timeout=${WaitMs}ms)"
  return $false
}

function Invoke-MacroSession {
  param([string[]]$Rest)
  $action = if ($Rest.Count -ge 1) { $Rest[0] } else { "" }
  switch ($action) {
    "clear-cache" {
      Get-ChildItem -LiteralPath $Script:CacheDir -Filter "appshot-*.json" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
      Write-Notice -Level "OK" -Message "관찰 캐시를 비웠습니다."
      return 0
    }
    "info" {
      $cacheCount = (Get-ChildItem -LiteralPath $Script:CacheDir -Filter "appshot-*.json" -ErrorAction SilentlyContinue).Count
      $logSize = if (Test-Path $Script:WrapperLog) { (Get-Item $Script:WrapperLog).Length } else { 0 }
      $info = [pscustomobject]@{
        cache_dir = $Script:CacheDir
        audit_dir = $Script:AuditDir
        cache_files = $cacheCount
        log_path = $Script:WrapperLog
        log_size_bytes = $logSize
        cli_path = $Script:CliPath
        cache_seconds = $CacheSeconds
      }
      [Console]::Out.WriteLine(($info | ConvertTo-Json))
      return 0
    }
    default {
      Write-Notice -Level "ERROR" -Message "session 하위 명령: clear-cache, info"
      return 1
    }
  }
}

# ============================================================================
# Dispatch
# ============================================================================

if (-not $CucpArgs -or $CucpArgs.Count -eq 0) {
  Write-WrapperLog -Message "INVOKE help (no args)"
  & node $Script:CliPath --help
  Write-Host ""
  Write-Host "[CUCP wrapper extras]" -ForegroundColor Cyan
  Write-Host "  macro find-label         --label <text> [--window <title>] [--match <text>] [--role <role>]"
  Write-Host "  macro list-affordances   [--window <title>] [--match <text>] [--limit <n>]"
  Write-Host "  macro click-label        --label <text> [--window <title>] [--role <role>] [--offset-x <n>] [--offset-y <n>]"
  Write-Host "  macro double-click-label ... (same options)"
  Write-Host "  macro right-click-label  ... (same options)"
  Write-Host "  macro click-id           --id <affordance_id> [--window <title>]"
  Write-Host "  macro fill-label         --label <text> --text <value> [--window <title>] [--clear] [--enter]"
  Write-Host "  macro focus-window       --name <window-or-process>"
  Write-Host "  macro wait-window        --title <text> [--timeout-ms <n>] [--interval-ms <n>]"
  Write-Host "  macro wait-label         --label <text> [--window <title>] [--timeout-ms <n>] [--interval-ms <n>]"
  Write-Host "  macro shortcut           --keys <combo>"
  Write-Host "  macro goal               --objective <text> [--max-steps <n>] [--max-phase-ms <n>] [--provider heuristic|codex]"
  Write-Host "                           [--verify-label <text>] [--verify-window <title>] [--verify-timeout-ms <n>] [--dry-run]"
  Write-Host "  macro session            clear-cache | info"
  Write-Host "  macro self-test          [--deep] [--strict]"
  Write-Host "  macro trajectory         show [--last <n>] | tail | clear"
  Write-Host "  macro ensure-helper      [--wait-ms <n>]"
  Write-Host "  macro vision-find        --describe <text> [--screenshot <path>] [--model <name>] [--timeout-ms <n>]"
  Write-Host "  macro vision-click       --describe <text> [--window <title>] [--verify-label <text>] [--verify-timeout-ms <n>] [--model <name>]"
  Write-Host "  macro metrics            (operational counters + click/cache rates)"
  Write-Host "  macro perf               [--iters <n>] [--json-only] [--quick] [--include-live-ish]   (timing min/avg/max ms)"
  Write-Host "  macro health-detail      [--json-only]   (per-component health: node/cli/helper/uia/codex/audit)"
  Write-Host "  macro health-quick       [--json-only]   (lightweight: node/cli/audit/win32 + temp pressure + recent timeouts)"
  Write-Host "  macro windows            [--match <s>] [--rich] [--include-hidden]   (Win32 enum, deterministic fallback)"
  Write-Host "  macro focus-verify       --name <substring> [--timeout-ms <n>]   (live: focus + Win32 verify)"
  Write-Host "  macro log-tail           [--lines <n>] [--max-bytes <n>] [--path <file>] [--errors-only]   (bounded read + redact)"
  Write-Host "  macro diagnose-lag       [--sample-ms <n>] [--json-only]   (Codex/Kiro/Chrome process snapshot + warnings)"
  Write-Host "  macro cleanup            --dry-run | --execute   [--older-than-minutes <n>] [--keep-latest <n>] [--max-files <n>] [--max-mb <n>]"
  Write-Host "  macro icon-find          --label <text> [--window <s>] [--max-size <px>] [--near-x <n>] [--near-y <n>]   (small toolbar icon resolver)"
  Write-Host "  macro icon-click         --label <text> [--window <s>] [--max-size <px>] [--near-x <n>] [--near-y <n>]   (live: refuses ambiguous)"
  Write-Host "  macro vision-click-precise --describe <text> [--window <s>] [--crop-size <px>] [--verify-label <text>]   (2-stage crop+refine)"
  Write-Host "  macro app-launch         --name <app> [--args <s>] [--wait-title <text>] [--wait-timeout-ms <n>]"
  Write-Host "  macro app-close          --name <app> | --pid <n> [--force]"
  Write-Host "  macro with-app           --name <app> [--wait-title <text>] [--hold-ms <n>] [--close-after] [--force]"
  Write-Host "  macro click-and-verify   --label <text> [--window <title>] [--verify-label <text>] [--wait-change-ms <n>]"
  Write-Host "  macro auto-do            --label <text> | --describe <text> [--window <title>] [--max-attempts <n>] [--verify-label <text>]"
  Write-Host ""
  Write-Host "  Wrapper flags: -AllowLiveControl, -Brief, -Quiet, -CacheSeconds <n>, -InvokeTimeoutMs <n>"
  exit 0
}

# Macro path
if ($CucpArgs[0] -eq "macro") {
  try {
    $code = Invoke-Macro -ArgList $CucpArgs
    if ($null -eq $code) { $code = 0 }
    # v0.9.0 fix: PowerShell 함수가 multiple output 흘려서 $code 가 array 가 될 수 있음.
    # 마지막 element (실제 return 값) 만 사용. int 가 아니면 0.
    if ($code -is [array]) {
      $last = $code[-1]
      if ($last -is [int]) { $code = $last } else { $code = 0 }
    }
    if ($code -isnot [int]) {
      try { $code = [int]$code } catch { $code = 0 }
    }
    exit $code
  } catch {
    $msg = "$($_.Exception.Message)"
    Write-Notice -Level "ERROR" -Message $msg
    # Standardized blocked exit codes (match SKILL.md table):
    #   3 = safety gate blocked (live-control, missing --after, requires
    #       -AllowLiveControl, label not found via fusion+vision, etc.)
    if ($msg -match 'AllowLiveControl|Live (desktop )?control|Live click|requires -AllowLiveControl|Coordinate-based act|requires --after|Label not found|affordance_id not found') {
      exit 3
    }
    exit 1
  }
}

# Direct CLI passthrough with safety gates.
# We forward to the CUCP CLI through Invoke-Cucp so the JSON envelope's
# `status: "error"` propagates into a non-zero exit code. This catches
# plan readiness/preflight/validate failures that the upstream CLI would
# otherwise report only via stdout.
try {
  Assert-Authorized -ArgList $CucpArgs
} catch {
  Write-Notice -Level "ERROR" -Message "$($_.Exception.Message)"
  exit 3
}

# JSON-bearing subcommands that should map status->exit. For everything else,
# fall through to a streaming invocation so heavy commands (benchmarks, l5,
# scenario) keep their original behavior.
$_jsonSurfacedFirstWords = @(
  "plan", "scenario", "tools", "version", "health", "release",
  "observe", "act", "app", "desktop", "l5", "replay"
)
$_useJsonCapture = $false
if ($CucpArgs.Count -ge 1) {
  if ($_jsonSurfacedFirstWords -contains $CucpArgs[0]) {
    $_useJsonCapture = $true
  }
}

if ($_useJsonCapture) {
  $r = Invoke-Cucp -ArgList $CucpArgs -CaptureJson
  if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  if ($r.Err) { [Console]::Error.Write($r.Err) }
  $exitCode = $r.ExitCode
  # Promote envelope status=error to a non-zero exit so plan readiness etc.
  # fail loudly even when the CLI itself returned 0.
  if ($exitCode -eq 0 -and $r.Json -and $r.Json.status -eq "error") {
    $exitCode = 1
  }
  # Timeout path: raw stdout is empty; emit our envelope so callers always
  # have machine-readable evidence (command_id/elapsed_ms/recommended_action).
  if ($exitCode -eq 124 -and (-not $r.Raw) -and $r.Json) {
    [Console]::Out.WriteLine(($r.Json | ConvertTo-Json -Depth 4))
  }
} else {
  & node $Script:CliPath @CucpArgs
  $exitCode = $LASTEXITCODE
}

if ($exitCode -ne 0) {
  if ($exitCode -eq 124) {
    Write-Notice -Level "ERROR" -Message "CUCP CLI 타임아웃 (exit=124). InvokeTimeoutMs를 늘리거나 'cucp macro ensure-helper'를 실행해보세요."
  } else {
    Write-Notice -Level "ERROR" -Message "CUCP CLI 비정상 종료 (exit=$exitCode). 감사 로그: $Script:WrapperLog"
  }
} else {
  if (-not $Brief) { Write-Notice -Level "OK" -Message "완료 (exit=0)" }
}

exit $exitCode
