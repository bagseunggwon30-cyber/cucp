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

# Some hosts inject both `Path` and `PATH` into the process environment. Windows
# treats them as the same variable, but Windows PowerShell 5 can throw
# "item has already been added" when launching child processes. Keep canonical
# `Path` and remove only the duplicate uppercase spelling from this process.
try {
  $processEnv = [System.Environment]::GetEnvironmentVariables("Process")
  if ($processEnv.Contains("Path") -and $processEnv.Contains("PATH")) {
    [System.Environment]::SetEnvironmentVariable("PATH", $null, "Process")
  }
} catch { }

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
  # v1.6.0 perf: 재귀 walking 결과 캐시. 캐시 파일 없거나 stale 시에만 스캔.
  $devBase = Join-Path $env:USERPROFILE "Documents\Codex"
  if (Test-Path -LiteralPath $devBase) {
    # 캐시 우선 — wrapper-cache 디렉터리에 cli-path.txt 가 있으면 그 경로 검증만
    $cacheDir = Join-Path $env:TEMP "computer-use-control-plane\wrapper-cache"
    $cliCacheFile = Join-Path $cacheDir "cli-path.txt"
    if (Test-Path -LiteralPath $cliCacheFile) {
      try {
        $cached = (Get-Content -LiteralPath $cliCacheFile -Raw -Encoding UTF8).Trim()
        if ($cached -and (_Validate-CliMjs $cached)) { return $cached }
      } catch { }
    }
    # cache miss → 1회 재귀 스캔 후 결과를 캐시 파일에 저장
    $found = Get-ChildItem -LiteralPath $devBase -Recurse -Filter "cli.mjs" -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match "src[/\\]cli\.mjs$" } |
      Sort-Object LastWriteTime -Descending
    foreach ($f in $found) {
      if (_Validate-CliMjs $f.FullName) {
        try {
          if (-not (Test-Path -LiteralPath $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
          }
          Set-Content -LiteralPath $cliCacheFile -Value $f.FullName -Encoding UTF8 -NoNewline -ErrorAction SilentlyContinue
        } catch { }
        return $f.FullName
      }
    }
  }
  return $null
}

$Script:CliPath  = _Find-CliPath
$Script:AuditDir = Join-Path $env:TEMP "computer-use-control-plane"
$Script:CacheDir = Join-Path $Script:AuditDir "wrapper-cache"
$Script:WrapperLog = Join-Path $Script:AuditDir "cucp-wrapper.log"
$Script:InvokeTimeoutMs = [Math]::Max(1000, $InvokeTimeoutMs)

# ----- logging --------------------------------------------------------------
function Write-WrapperLog {
  param([string]$Message)
  $timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffK")
  try { Add-Content -LiteralPath $Script:WrapperLog -Value "[$timestamp] $Message" -Encoding UTF8 } catch { }
}

# ----- native helper path ---------------------------------------------------
# CUCP 전용 PowerShell helper 위치. Win32 + UIA + Screenshot을 직접 호출해서
# 외부 windows-mcp 서버나 Codex 공식 helper에 의존하지 않습니다. 이 helper는
# 스킬 폴더 안에 항상 같이 배포되므로 절대 경로 탐색 불필요.
$Script:NativeHelperPath = Join-Path $PSScriptRoot "cucp-native-helper.ps1"
if (-not (Test-Path -LiteralPath $Script:NativeHelperPath)) {
  $Script:NativeHelperPath = ""
}
$Script:TaskCardScriptPath = Join-Path $PSScriptRoot "cucp-task-card.ps1"
$Script:TaskCardDir = Join-Path $Script:AuditDir "task-card"
$Script:TaskCardPath = Join-Path $Script:TaskCardDir "current-task-card.json"
if (-not (Test-Path -LiteralPath $Script:TaskCardScriptPath)) {
  $Script:TaskCardScriptPath = ""
}

# cli.mjs를 찾지 못하면 경고만 남기고 계속 진행 (read-only 매크로는 동작 가능)
if (-not $Script:CliPath) {
  $Script:CliPath = ""
  # 로그는 AuditDir 생성 후 기록
}

if (-not (Test-Path -LiteralPath $Script:CacheDir)) {
  try { New-Item -ItemType Directory -Path $Script:CacheDir -Force | Out-Null } catch { }
}
if (-not (Test-Path -LiteralPath $Script:TaskCardDir)) {
  try { New-Item -ItemType Directory -Path $Script:TaskCardDir -Force | Out-Null } catch { }
}

if (-not $Script:CliPath) {
  Write-WrapperLog -Message "WARNING: cli.mjs not found. Set CUCP_CLI_PATH env var or bundle cli/ into the skill folder. Read-only macros (windows, health-quick, icon-find) still work."
}
if (-not $Script:NativeHelperPath) {
  Write-WrapperLog -Message "WARNING: cucp-native-helper.ps1 not found in scripts/. Native fallback unavailable; macros will require cli.mjs."
}

# ============================================================================
# v1.6.0 — Helper Persistent Server IPC
# ============================================================================
# cucp-helper-server.ps1 (named pipe server) 와의 JSON-line IPC 헬퍼.
# wrapper 가 첫 호출 시 lock 파일 (helper.pid) 검사 → server 살아있으면 pipe,
# 없거나 stale 이면 child PowerShell fallback. 같은 wrapper invocation 안에서
# 여러 매크로가 helper 를 N회 호출할 때 cold-start 비용 (~500ms × N) 회피.
#
# 사용 흐름:
#   1. _Read-LockSafely → lock JSON 안전 read (없으면 null)
#   2. _Is-StaleLock → PID alive / mtime / pipe_name / SemVer 검사
#   3. Invoke-HelperPipe → JSON-line request 전송 + response 수신
#   4. Invoke-NativeHelper 가 위 헬퍼를 server-first 분기에서 사용
# ============================================================================

$Script:HelperLockPath = Join-Path $Script:AuditDir "helper.pid"
$Script:HelperServerScript = Join-Path $PSScriptRoot "cucp-helper-server.ps1"
$Script:_HelperPipeReqId = 0
# server 가 직접 처리 가능한 action 화이트리스트 (cucp-helper-server.ps1 v1.6.0 의 _Dispatch 와 일치)
$Script:HelperServerSupported = @("windows", "health", "focused", "modal-detect")

function _Read-LockSafely {
  # 결과: hashtable {pid, pipe_name, started_at, helper_version} 또는 $null
  if (-not (Test-Path -LiteralPath $Script:HelperLockPath)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $Script:HelperLockPath -Raw -Encoding UTF8
    if (-not $raw) { return $null }
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    return $obj
  } catch {
    return $null
  }
}

function _Is-StaleLock {
  param($Lock)
  if (-not $Lock) { return $true }
  # 1. PID alive 검증
  try {
    $proc = Get-Process -Id ([int]$Lock.pid) -ErrorAction SilentlyContinue
    if (-not $proc) { return $true }
  } catch { return $true }
  # 2. mtime 검증 (24h margin)
  try {
    $started = [DateTime]::Parse("$($Lock.started_at)")
    $age = (Get-Date).ToUniversalTime() - $started.ToUniversalTime()
    if ($age.TotalHours -gt 24) { return $true }
  } catch { return $true }
  # 3. pipe_name 형식 검증
  $expectedPipe = "cucp-helper-$($Lock.pid)"
  if ("$($Lock.pipe_name)" -ne $expectedPipe) { return $true }
  # 4. helper_version SemVer 검증
  if ("$($Lock.helper_version)" -notmatch '^\d+\.\d+\.\d+$') { return $true }
  return $false
}

function _Try-Delete-Lock {
  if (Test-Path -LiteralPath $Script:HelperLockPath) {
    try { Remove-Item -LiteralPath $Script:HelperLockPath -Force -ErrorAction SilentlyContinue } catch { }
  }
}

function Get-HelperServerStatus {
  # macro session helper-status 용. server up/down 둘 다 일관 envelope 반환.
  $lock = _Read-LockSafely
  if (-not $lock -or (_Is-StaleLock -Lock $lock)) {
    return [pscustomobject]@{
      schema = "cucp.helper-status/v1"
      alive = $false
      pid = $null
      pipe_name = $null
      started_at = $null
      uptime_s = 0
      request_count = 0
      helper_version = $null
    }
  }
  # server 살아있으면 health action 으로 추가 정보 가져옴
  $extra = $null
  try {
    $resp = Invoke-HelperPipe -Action "health" -ArgsHash @{} -TimeoutMs 1500
    if ($resp -and $resp.exit_code -eq 0) { $extra = $resp.result }
  } catch { $extra = $null }
  $upS = 0; $reqC = 0
  if ($extra) {
    if ($extra.uptime_s) { $upS = [int]$extra.uptime_s }
    if ($extra.request_count) { $reqC = [int]$extra.request_count }
  }
  return [pscustomobject]@{
    schema = "cucp.helper-status/v1"
    alive = $true
    pid = [int]$lock.pid
    pipe_name = "$($lock.pipe_name)"
    started_at = "$($lock.started_at)"
    uptime_s = $upS
    request_count = $reqC
    helper_version = "$($lock.helper_version)"
  }
}

function Invoke-HelperPipe {
  # JSON-line client. server 가 살아있다고 가정 (호출자가 lock 검증 후 사용).
  # request: {id, action, args, timeout_ms?, trace_id?}
  # response: {id, exit_code, result, error, ...}
  # 실패 시 throw — 호출자가 catch 후 child fallback 으로 처리.
  param(
    [Parameter(Mandatory=$true)][string]$Action,
    [hashtable]$ArgsHash = @{},
    [int]$TimeoutMs = 30000
  )
  $lock = _Read-LockSafely
  if (-not $lock) { throw "helper_lock_missing" }
  $pipeName = "$($lock.pipe_name)"
  if (-not $pipeName) { throw "helper_pipe_name_missing" }
  $client = New-Object System.IO.Pipes.NamedPipeClientStream(
    ".", $pipeName,
    [System.IO.Pipes.PipeDirection]::InOut,
    [System.IO.Pipes.PipeOptions]::Asynchronous
  )
  $reader = $null
  $writer = $null
  try {
    $connectTimeout = [Math]::Min(2000, $TimeoutMs)
    $client.Connect($connectTimeout)
    if (-not $client.IsConnected) { throw "pipe_connect_failed" }
    $reader = New-Object System.IO.StreamReader($client, [System.Text.Encoding]::UTF8)
    $writer = New-Object System.IO.StreamWriter($client, [System.Text.Encoding]::UTF8)
    $writer.AutoFlush = $true
    $Script:_HelperPipeReqId++
    $reqId = $Script:_HelperPipeReqId
    $req = [ordered]@{
      id = $reqId
      action = $Action
      args = $ArgsHash
      timeout_ms = $TimeoutMs
    }
    $line = $req | ConvertTo-Json -Compress -Depth 8
    $writer.WriteLine($line)
    # async ReadLine 으로 timeout 통제
    $task = [System.Threading.Tasks.Task]::Run([System.Func[string]] { $reader.ReadLine() })
    $waited = $task.Wait($TimeoutMs)
    if (-not $waited) { throw "pipe_read_timeout" }
    $respLine = $task.Result
    if (-not $respLine) { throw "pipe_empty_response" }
    $resp = $respLine | ConvertFrom-Json -ErrorAction Stop
    if ($resp.id -ne $reqId) { throw "pipe_id_mismatch (req=$reqId, resp=$($resp.id))" }
    return $resp
  } finally {
    try { if ($reader) { $reader.Close() } } catch { }
    try { if ($writer) { $writer.Close() } } catch { }
    try { $client.Close() } catch { }
    try { $client.Dispose() } catch { }
  }
}

function Start-HelperServer {
  # idempotent — 이미 살아있는 server 가 있으면 그대로 reuse
  param(
    [int]$IdleTimeoutMs = 60000
  )
  $lock = _Read-LockSafely
  if ($lock -and -not (_Is-StaleLock -Lock $lock)) {
    return [pscustomobject]@{
      status = "ok"
      reused = $true
      pid = [int]$lock.pid
      pipe_name = "$($lock.pipe_name)"
      started_at = "$($lock.started_at)"
    }
  }
  if ($lock) { _Try-Delete-Lock }  # stale 정리
  if (-not (Test-Path -LiteralPath $Script:HelperServerScript)) {
    return [pscustomobject]@{
      status = "error"
      reason = "helper_server_script_missing"
      path = $Script:HelperServerScript
    }
  }
  $argList = @(
    "-NoProfile", "-NoLogo", "-NonInteractive",
    "-ExecutionPolicy", "Bypass",
    "-File", $Script:HelperServerScript,
    "-IdleTimeoutMs", "$IdleTimeoutMs"
  )
  $proc = Start-Process powershell.exe -ArgumentList $argList `
    -WindowStyle Hidden -PassThru -ErrorAction Stop
  # lock 등장 대기 (3s deadline, 50ms tick)
  $deadline = (Get-Date).AddMilliseconds(3000)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 50
    $lock = _Read-LockSafely
    if ($lock -and [int]$lock.pid -eq [int]$proc.Id -and -not (_Is-StaleLock -Lock $lock)) {
      return [pscustomobject]@{
        status = "ok"
        reused = $false
        pid = [int]$lock.pid
        pipe_name = "$($lock.pipe_name)"
        started_at = "$($lock.started_at)"
      }
    }
  }
  # 실패 → spawn 된 proc 정리
  try { $proc.Kill() } catch { }
  _Try-Delete-Lock
  return [pscustomobject]@{
    status = "error"
    reason = "server_start_timeout"
  }
}

function Stop-HelperServer {
  param([switch]$Force)
  $lock = _Read-LockSafely
  if (-not $lock) {
    return [pscustomobject]@{ status = "ok"; reason = "no_helper_running" }
  }
  $oldPid = [int]$lock.pid
  if (-not (_Is-StaleLock -Lock $lock)) {
    # graceful shutdown via pipe
    try {
      $resp = Invoke-HelperPipe -Action "shutdown" -ArgsHash @{} -TimeoutMs 1500
    } catch { }
    Start-Sleep -Milliseconds 200
  }
  if ($Force -or (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
    try { Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue } catch { }
  }
  _Try-Delete-Lock
  return [pscustomobject]@{
    status = "ok"
    stopped_pid = $oldPid
    forced = [bool]$Force
  }
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
    [int]$TimeoutMs = 0,
    [switch]$ForceChild
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
  # ==========================================================================
  # v1.6.0 — Helper Persistent Server server-first 라우팅
  # ==========================================================================
  # ForceChild=true 또는 lock 없음/stale → 즉시 child 경로 (기존 동작 보존).
  # lock valid + action 이 server whitelist 안 → pipe IPC 시도. 실패시 child fallback.
  # 결과 envelope 에 route="pipe"|"child" 표기, 외부 ExitCode 는 99 (fallback) 노출 안 함.
  # ==========================================================================
  $ipcSw = [System.Diagnostics.Stopwatch]::StartNew()
  $serverRouteAttempted = $false
  if (-not $ForceChild -and -not $env:CUCP_FORCE_CHILD) {
    $lock = _Read-LockSafely
    if ($lock -and -not (_Is-StaleLock -Lock $lock)) {
      # action 추출
      $hAction = $null
      for ($k = 0; $k -lt $ArgList.Count - 1; $k++) {
        if ($ArgList[$k] -eq "-Action") { $hAction = "$($ArgList[$k+1])"; break }
      }
      if ($hAction -and ($Script:HelperServerSupported -contains $hAction)) {
        $serverRouteAttempted = $true
        # 옵션 → hashtable
        $hArgs = @{}
        $optKeys = @("Match","TargetMatch","TargetHwnd")
        foreach ($oK in $optKeys) {
          for ($k = 0; $k -lt $ArgList.Count - 1; $k++) {
            if ($ArgList[$k] -eq "-$oK") { $hArgs[$oK] = "$($ArgList[$k+1])"; break }
          }
        }
        $tm = $TimeoutMs
        if ($tm -le 0) { $tm = $Script:InvokeTimeoutMs }
        try {
          $resp = Invoke-HelperPipe -Action $hAction -ArgsHash $hArgs -TimeoutMs $tm
          $ipcSw.Stop()
          if ($resp -and $resp.exit_code -ne 99) {
            # 정상 응답 — pipe 경로로 envelope 구성
            $exitMapped = [int]$resp.exit_code
            $jsonObj = $resp.result
            $rawJson = $jsonObj | ConvertTo-Json -Compress -Depth 12
            return [pscustomobject]@{
              ExitCode = $exitMapped
              Json = $jsonObj
              Raw = $rawJson
              Err = if ($resp.error) { "$($resp.error)" } else { "" }
              ElapsedMs = [int]$ipcSw.Elapsed.TotalMilliseconds
              FromHotCache = $false
              Route = "pipe"
            }
          }
          # exit_code=99 → fallback_required, child 경로로 빠짐
        } catch {
          # pipe broken / timeout / id mismatch → child fallback
          # stale 검사 한 번 더 (server 가 죽었을 수 있음)
          $lock2 = _Read-LockSafely
          if ($lock2 -and (_Is-StaleLock -Lock $lock2)) { _Try-Delete-Lock }
          Write-WrapperLog -Message "PIPE FAILED ($($_.Exception.Message)) → child fallback for action=$hAction"
        }
      }
    }
  }
  # ==========================================================================
  # v1.5.0 Phase 1: in-memory hot cache (TTL 500ms)
  # 같은 read-only action 을 짧은 시간 내 반복 호출 시 child process spawn 우회.
  # 적용 대상: -Action windows / health / focused / modal-detect 만.
  # 키: action + 주요 옵션 (Match, TargetMatch, TargetHwnd) 정규화.
  # `-CacheSeconds 0` 또는 환경 변수 `CUCP_HOT_CACHE_DISABLE=1` 시 비활성.
  # ==========================================================================
  $hotKey = $null
  $hotEligible = $false
  if (-not $env:CUCP_HOT_CACHE_DISABLE -and $Script:CacheSeconds -gt 0) {
    $hotAction = $null
    for ($i = 0; $i -lt $ArgList.Count - 1; $i++) {
      if ($ArgList[$i] -eq "-Action") { $hotAction = $ArgList[$i+1]; break }
    }
    $hotEligibleActions = @("windows","health","focused","modal-detect")
    if ($hotAction -and ($hotEligibleActions -contains $hotAction)) {
      $hotEligible = $true
      $hotKey = "$hotAction|"
      foreach ($optName in @("-Match","-TargetMatch","-TargetHwnd")) {
        for ($j = 0; $j -lt $ArgList.Count - 1; $j++) {
          if ($ArgList[$j] -eq $optName) { $hotKey += "$optName=$($ArgList[$j+1])|"; break }
        }
      }
    }
  }
  if (-not $Script:HotCache) { $Script:HotCache = @{} }
  if (-not $Script:HotCacheStats) { $Script:HotCacheStats = @{ hits = 0; misses = 0; evictions = 0 } }
  if ($hotEligible -and $hotKey -and $Script:HotCache.ContainsKey($hotKey)) {
    $entry = $Script:HotCache[$hotKey]
    $nowTicks = [DateTime]::UtcNow.Ticks
    if ($entry.expires_ticks -gt $nowTicks) {
      $Script:HotCacheStats.hits++
      return [pscustomobject]@{
        ExitCode = $entry.exit_code
        Json = $entry.json
        Raw = $entry.raw
        Err = $null
        ElapsedMs = 0
        FromHotCache = $true
        Route = "hot-cache"
      }
    } else {
      $Script:HotCacheStats.evictions++
      [void]$Script:HotCache.Remove($hotKey)
    }
  }
  if ($hotEligible) { $Script:HotCacheStats.misses++ }
  if ($TimeoutMs -le 0) { $TimeoutMs = $Script:InvokeTimeoutMs }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $stdoutFile = Join-Path $Script:CacheDir ("native-" + [guid]::NewGuid().ToString("N") + ".json")
  $stderrFile = $stdoutFile + ".err"
  try {
    $allArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$Script:NativeHelperPath) + $ArgList
    $procArgs = ConvertTo-ProcessArgumentString -ArgList $allArgs
    $proc = Start-Process -FilePath "powershell" -ArgumentList $procArgs `
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
    # v1.5.0 Phase 1: hot cache write (정상 응답만, ok+JSON 있을 때, eligible action 만)
    if ($hotEligible -and $hotKey -and $exitCode -eq 0 -and $json) {
      try {
        $ttlMs = 500
        $expiresTicks = [DateTime]::UtcNow.AddMilliseconds($ttlMs).Ticks
        $Script:HotCache[$hotKey] = @{
          exit_code = [int]$exitCode
          json = $json
          raw = $raw
          expires_ticks = $expiresTicks
        }
        # 메모리 보호: 캐시 항목 16개 초과 시 가장 오래된 것 evict
        if ($Script:HotCache.Count -gt 16) {
          $oldest = $Script:HotCache.GetEnumerator() | Sort-Object { $_.Value.expires_ticks } | Select-Object -First 1
          [void]$Script:HotCache.Remove($oldest.Key)
          $Script:HotCacheStats.evictions++
        }
      } catch { }
    }
    return [pscustomobject]@{
      ExitCode = $exitCode
      Json = $json
      Raw = $raw
      Err = $err
      ElapsedMs = [int]$sw.Elapsed.TotalMilliseconds
      FromHotCache = $false
      Route = "child"
    }
  } catch {
    $sw.Stop()
    return [pscustomobject]@{
      ExitCode = 1
      Json = $null
      Raw = ""
      Err = $_.Exception.Message
      ElapsedMs = [int]$sw.Elapsed.TotalMilliseconds
      Route = "child-error"
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

function ConvertTo-ProcessArgumentString {
  param([string[]]$ArgList)
  $quoted = @()
  foreach ($arg in $ArgList) {
    if ($null -eq $arg) {
      $quoted += '""'
    } elseif ($arg -match '[\s"]') {
      $escaped = $arg -replace '"', '\"'
      $quoted += '"' + $escaped + '"'
    } else {
      $quoted += $arg
    }
  }
  return ($quoted -join " ")
}

# ----- prerequisites --------------------------------------------------------
function Test-Tool { param([string]$Name)
  try { $null = Get-Command $Name -ErrorAction Stop; return $true } catch { return $false }
}

if (-not (Test-Tool "node")) {
  Write-Notice -Level "ERROR" -Message "node 명령을 찾을 수 없습니다. Node.js 20+가 필요합니다."
  throw "node not found in PATH"
}

if (-not $Script:CliPath -or -not (Test-Path -LiteralPath $Script:CliPath)) {
  Write-Notice -Level "WARN" -Message "CUCP CLI를 찾지 못했습니다. native/read-only 매크로만 사용할 수 있습니다."
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

  public const uint GA_ROOT = 2;

  [StructLayout(LayoutKind.Sequential)]
  public struct POINT { public int X; public int Y; }

  [DllImport("user32.dll")]
  public static extern IntPtr WindowFromPoint(POINT point);

  [DllImport("user32.dll")]
  public static extern IntPtr GetAncestor(IntPtr hwnd, uint gaFlags);

  [DllImport("user32.dll", CharSet = CharSet.Auto)]
  public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

  public class WindowInfo {
    public IntPtr Hwnd;
    public IntPtr ChildHwnd;
    public string Title;
    public string ClassName;
    public uint Pid;
    public string ProcessName;
    public bool Visible;
    public bool Minimized;
    public bool Foreground;
    public int X; public int Y; public int Width; public int Height;
  }

  public class MonitorInfo {
    public string DeviceName;
    public bool Primary;
    public int X; public int Y; public int Width; public int Height;
    public int WorkX; public int WorkY; public int WorkWidth; public int WorkHeight;
    public uint DpiX; public uint DpiY;
    public double ScaleX; public double ScaleY;
  }

  public class VirtualScreenInfo {
    public int X; public int Y; public int Width; public int Height;
    public int MonitorCount;
    public bool SameDisplayFormat;
  }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
  public struct MONITORINFOEX {
    public int cbSize;
    public RECT rcMonitor;
    public RECT rcWork;
    public uint dwFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
    public string szDevice;
  }

  public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData);

  [DllImport("user32.dll")]
  public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);

  [DllImport("user32.dll", CharSet = CharSet.Auto)]
  public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX lpmi);

  [DllImport("user32.dll")]
  public static extern IntPtr MonitorFromPoint(POINT pt, uint dwFlags);

  [DllImport("user32.dll")]
  public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint dwFlags);

  [DllImport("user32.dll")]
  public static extern int GetSystemMetrics(int nIndex);

  [DllImport("shcore.dll")]
  public static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);

  [DllImport("user32.dll")]
  public static extern uint GetDpiForWindow(IntPtr hwnd);

  public static MonitorInfo BuildMonitorInfo(IntPtr hMonitor) {
    var mi = new MONITORINFOEX();
    mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
    if (!GetMonitorInfo(hMonitor, ref mi)) return null;
    uint dx = 96, dy = 96;
    try { GetDpiForMonitor(hMonitor, 0, out dx, out dy); } catch { dx = 96; dy = 96; }
    return new MonitorInfo {
      DeviceName = mi.szDevice,
      Primary = ((mi.dwFlags & 1) == 1),
      X = mi.rcMonitor.Left,
      Y = mi.rcMonitor.Top,
      Width = mi.rcMonitor.Right - mi.rcMonitor.Left,
      Height = mi.rcMonitor.Bottom - mi.rcMonitor.Top,
      WorkX = mi.rcWork.Left,
      WorkY = mi.rcWork.Top,
      WorkWidth = mi.rcWork.Right - mi.rcWork.Left,
      WorkHeight = mi.rcWork.Bottom - mi.rcWork.Top,
      DpiX = dx,
      DpiY = dy,
      ScaleX = Math.Round(dx / 96.0, 4),
      ScaleY = Math.Round(dy / 96.0, 4)
    };
  }

  public static List<MonitorInfo> EnumerateMonitors() {
    var result = new List<MonitorInfo>();
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate (IntPtr hMonitor, IntPtr hdc, ref RECT rc, IntPtr data) {
      try {
        var info = BuildMonitorInfo(hMonitor);
        if (info != null) result.Add(info);
      } catch { }
      return true;
    }, IntPtr.Zero);
    return result;
  }

  public static MonitorInfo MonitorFromScreenPointInfo(int x, int y) {
    POINT pt = new POINT { X = x, Y = y };
    IntPtr h = MonitorFromPoint(pt, 2);
    if (h == IntPtr.Zero) return null;
    return BuildMonitorInfo(h);
  }

  public static MonitorInfo MonitorFromWindowInfo(IntPtr hwnd) {
    IntPtr h = MonitorFromWindow(hwnd, 2);
    if (h == IntPtr.Zero) return null;
    return BuildMonitorInfo(h);
  }

  public static uint GetWindowDpiValue(IntPtr hwnd) {
    try { return GetDpiForWindow(hwnd); } catch { return 0; }
  }

  public static VirtualScreenInfo GetVirtualScreenInfo() {
    return new VirtualScreenInfo {
      X = GetSystemMetrics(76),
      Y = GetSystemMetrics(77),
      Width = GetSystemMetrics(78),
      Height = GetSystemMetrics(79),
      MonitorCount = GetSystemMetrics(80),
      SameDisplayFormat = (GetSystemMetrics(81) != 0)
    };
  }

  public static WindowInfo GetWindowInfo(IntPtr root, IntPtr child) {
    if (root == IntPtr.Zero) return null;
    int len = GetWindowTextLength(root);
    var sb = new StringBuilder(Math.Max(256, len + 4));
    GetWindowText(root, sb, sb.Capacity);
    var title = sb.ToString();
    var cb = new StringBuilder(256);
    GetClassName(root, cb, cb.Capacity);
    var cls = cb.ToString();
    uint pid; GetWindowThreadProcessId(root, out pid);
    string pname = "";
    try { pname = Process.GetProcessById((int)pid).ProcessName; } catch { }
    RECT r; GetWindowRect(root, out r);
    return new WindowInfo {
      Hwnd = root,
      ChildHwnd = child,
      Title = title,
      ClassName = cls,
      Pid = pid,
      ProcessName = pname,
      Visible = IsWindowVisible(root),
      Minimized = IsIconic(root),
      Foreground = (root == GetForegroundWindow()),
      X = r.Left, Y = r.Top, Width = r.Right - r.Left, Height = r.Bottom - r.Top
    };
  }

  public static WindowInfo WindowFromScreenPoint(int x, int y) {
    POINT pt = new POINT { X = x, Y = y };
    IntPtr child = WindowFromPoint(pt);
    if (child == IntPtr.Zero) return null;
    IntPtr root = GetAncestor(child, GA_ROOT);
    if (root == IntPtr.Zero) root = child;
    return GetWindowInfo(root, child);
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
          ChildHwnd = hwnd,
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
  param([string]$FocusedWindow, [int]$MaxElements = 400, [int]$MinSize = 6, [int64]$Hwnd = 0)

  if (-not (_Ensure-UIALoaded)) { return @() }

  try {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    if (-not $root) { return @() }

    # Find target window: prefer exact HWND, then focused window match, else root scan.
    $target = $root
    if ($Hwnd -gt 0) {
      try {
        $byHandle = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Hwnd)
        if ($byHandle) { $target = $byHandle }
      } catch { }
    }
    if ($target -eq $root -and $FocusedWindow) {
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

  $directSafetyLiveMacros = @(
    "app-launch","app-close","with-app","focus-window","focus-verify",
    "click-label","double-click-label","right-click-label","click-id","click-point",
    "fill-label","shortcut","shortcut-native","type-native","uia-click-label",
    "uia-invoke","uia-set-value","uia-toggle","safe-type","smart-click","form-run",
    "icon-click","vision-click","vision-click-precise","click-and-verify",
    "click-and-verify-screen","ocr-click","ocr-uia-invoke","cdp-type","cdp-click",
    "cdp-smart-click","cdp-smart-type","auto-do","goal","notify","multi-select",
    "multi-edit","clipboard","process","registry"
  )
  if ($AllowLiveControl -and ($directSafetyLiveMacros -contains $sub) -and -not (_Read-Switch -Rest $rest -Name "--confirm-sensitive")) {
    $directSafety = _Classify-SafetyFromText -Text ((@($sub) + @($rest)) -join " ") -MacroName $sub
    if ($directSafety.requires_explicit_confirmation) {
      $payload = [pscustomobject]@{
        schema = "cucp.safety-block/v1"
        status = "blocked"
        reason = "sensitive_action_requires_confirmation"
        macro = $sub
        confirmation_flag = "--confirm-sensitive"
        safety = $directSafety
        next_action = "Re-run with --confirm-sensitive only if the user explicitly approved this exact sensitive live action."
      }
      if ($Brief) { [Console]::Out.WriteLine("blocked $sub reason=sensitive_action_requires_confirmation risk=$($directSafety.risk_level)") }
      else { [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 10)) }
      return 3
    }
  }

  switch ($sub) {
    "safety-classify" { return Invoke-MacroSafetyClassify -Rest $rest }
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
    "task-card"         { return Invoke-MacroTaskCard -Rest $rest }
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
    "workflow-plan"     { return Invoke-MacroWorkflowPlan -Rest $rest }
    "workflow-run"      { return Invoke-MacroWorkflowRun -Rest $rest }
    "smart-click"       { return Invoke-MacroSmartClick -Rest $rest }
    "smart-plan"        { return Invoke-MacroSmartPlan -Rest $rest }
    "app-profile"       { return Invoke-MacroAppProfile -Rest $rest }
    "task-preset"       { return Invoke-MacroTaskPreset -Rest $rest }
    "task-plan"         { return Invoke-MacroTaskPlan -Rest $rest }
    "task-run"          { return Invoke-MacroTaskRun -Rest $rest }
    "form-plan"         { return Invoke-MacroFormPlan -Rest $rest }
    "form-run"          { return Invoke-MacroFormRun -Rest $rest }
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
    "coord-profile"     { return Invoke-MacroCoordProfile -Rest $rest }
    "coord-map"         { return Invoke-MacroCoordMap -Rest $rest }
    "coord-anchor"      { return Invoke-MacroCoordAnchor -Rest $rest }
    "hit-test"          { return Invoke-MacroHitTest -Rest $rest }
    "hit-test-batch"    { return Invoke-MacroHitTestBatch -Rest $rest }
    "hit-scan"          { return Invoke-MacroHitScan -Rest $rest }
    "point-plan"        { return Invoke-MacroPointPlan -Rest $rest }
    "target-validate"   { return Invoke-MacroTargetValidate -Rest $rest }
    "safe-type"         { return Invoke-MacroSafeType -Rest $rest }
    # ── v1.3.0 Electron CDP (DOM 직접 제어) ─────────────────────────────────
    "cdp-detect"        { return Invoke-MacroCdpDetect -Rest $rest }
    "cdp-eval"          { return Invoke-MacroCdpEval -Rest $rest }
    "cdp-type"          { return Invoke-MacroCdpType -Rest $rest }
    "cdp-click"         { return Invoke-MacroCdpClick -Rest $rest }
    "cdp-smart-find"    { return Invoke-MacroCdpSmartFind -Rest $rest }
    "cdp-smart-type-find" { return Invoke-MacroCdpSmartTypeFind -Rest $rest }
    "cdp-smart-click"   { return Invoke-MacroCdpSmartClick -Rest $rest }
    "cdp-smart-type"    { return Invoke-MacroCdpSmartType -Rest $rest }
    # ── v1.4.0 6 missing items ──────────────────────────────────────────────
    "cdp-deep-find"     { return Invoke-MacroCdpDeepFind -Rest $rest }
    "ime-paste"         { return Invoke-MacroImePaste -Rest $rest }
    "safe-type-ime"     { return Invoke-MacroSafeTypeIme -Rest $rest }
    "modal-detect"      { return Invoke-MacroModalDetect -Rest $rest }
    "recovery-plan"     { return Invoke-MacroRecoveryPlan -Rest $rest }
    "recovery-run"      { return Invoke-MacroRecoveryRun -Rest $rest }
    "precision-validate" { return Invoke-MacroPrecisionValidate -Rest $rest }
    "benchmark"         { return Invoke-MacroBenchmark -Rest $rest }
    "release-notes"     { return Invoke-MacroReleaseNotes -Rest $rest }
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
      Write-Notice -Level "ERROR" -Message "알 수 없는 매크로: $sub. 사용 가능: safety-classify, click-label, double-click-label, right-click-label, click-id, click-point, fill-label, focus-window, focus-verify, wait-window, wait-label, find-label, list-affordances, shortcut, goal, session, self-test, trajectory, ensure-helper, vision-find, vision-click, vision-click-precise, icon-find, icon-click, screenshot, windows, log-tail, diagnose-lag, cleanup, clipboard, process, registry, notify, multi-select, multi-edit, scrape, dom-snapshot, metrics, perf, health-detail, health-quick, app-launch, app-close, with-app, click-and-verify, auto-do, native-health, task-card, native-windows, native-screenshot, type-native, shortcut-native, uia-click-label, uia-invoke, uia-set-value, uia-toggle, workflow-plan, workflow-run, smart-plan, app-profile, task-preset, task-plan, task-run, form-plan, form-run, smart-click, watch, ocr-screen, ocr-image, ocr-find-text, ocr-click, ocr-uia-fuse, screenshot-diff, click-and-verify-screen, ocr-uia-invoke, history, coord-profile, coord-map, coord-anchor, hit-test, hit-test-batch, hit-scan, point-plan, target-validate, safe-type, cdp-detect, cdp-eval, cdp-type, cdp-click, cdp-smart-find, cdp-smart-type-find, cdp-smart-click, cdp-smart-type, cdp-deep-find, ime-paste, safe-type-ime, modal-detect, recovery-plan, recovery-run, precision-validate, benchmark, release-notes"
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

function _Read-AllOptValues { param([string[]]$Rest, [string]$Name)
  $values = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $Rest.Count; $i++) {
    if ($Rest[$i] -eq $Name -and ($i + 1) -lt $Rest.Count) {
      [void]$values.Add($Rest[$i+1])
      $i++
    }
  }
  return @($values)
}

function _Read-Switch { param([string[]]$Rest, [string]$Name)
  return ($Rest -contains $Name)
}

function Invoke-TaskCardScript {
  param(
    [Parameter(Mandatory)] [string]$Mode,
    [string[]]$ExtraArgs = @()
  )
  if (-not $Script:TaskCardScriptPath -or -not (Test-Path -LiteralPath $Script:TaskCardScriptPath)) {
    throw "CUCP task-card script is missing: $($Script:TaskCardScriptPath)"
  }
  $args = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $Script:TaskCardScriptPath,
    "-Mode", $Mode,
    "-Path", $Script:TaskCardPath
  )
  foreach ($arg in @($ExtraArgs)) {
    if ($null -ne $arg) { $args += "$arg" }
  }
  return @(& powershell.exe @args)
}

function Get-TaskCardContext {
  param([switch]$Ensure)
  if (-not $Script:TaskCardScriptPath -or -not (Test-Path -LiteralPath $Script:TaskCardScriptPath)) {
    return $null
  }
  try {
    if ($Ensure -or -not (Test-Path -LiteralPath $Script:TaskCardPath)) {
      Invoke-TaskCardScript -Mode "ensure" | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Script:TaskCardPath)) { return $null }
    $raw = Get-Content -LiteralPath $Script:TaskCardPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
  } catch {
    return [pscustomobject]@{
      schema = "cucp.task-card/v1"
      status = "invalid"
      path = $Script:TaskCardPath
      error = $_.Exception.Message
    }
  }
}

function Get-TaskCardSaveArgs {
  param([string[]]$Rest)
  $extra = New-Object System.Collections.ArrayList
  $pairs = @(
    @{ Opt = "--tool"; Param = "-Tool" },
    @{ Opt = "--project"; Param = "-ProjectName" },
    @{ Opt = "--project-name"; Param = "-ProjectName" },
    @{ Opt = "--plc"; Param = "-PlcModel" },
    @{ Opt = "--plc-model"; Param = "-PlcModel" },
    @{ Opt = "--communication"; Param = "-Communication" },
    @{ Opt = "--comm"; Param = "-Communication" },
    @{ Opt = "--devices"; Param = "-Devices" },
    @{ Opt = "--address-ranges"; Param = "-AddressRanges" },
    @{ Opt = "--ranges"; Param = "-AddressRanges" },
    @{ Opt = "--requirements"; Param = "-Requirements" },
    @{ Opt = "--constraints"; Param = "-Constraints" },
    @{ Opt = "--notes"; Param = "-Notes" }
  )
  foreach ($pair in $pairs) {
    $value = _Read-OptValue -Rest $Rest -Name $pair.Opt
    if ($null -ne $value) {
      [void]$extra.Add($pair.Param)
      [void]$extra.Add("$value")
    }
  }
  return @($extra)
}

function Invoke-MacroTaskCard {
  param([string[]]$Rest)
  $action = if ($Rest -and $Rest.Count -gt 0) { "$($Rest[0])".ToLowerInvariant() } else { "open" }
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"

  switch ($action) {
    "open" {
      $saveArgs = Get-TaskCardSaveArgs -Rest $Rest
      if ($saveArgs.Count -gt 0) { Invoke-TaskCardScript -Mode "save" -ExtraArgs $saveArgs | Out-Null }
      else { Invoke-TaskCardScript -Mode "ensure" | Out-Null }

      $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $Script:TaskCardScriptPath,
        "-Mode", "open",
        "-Path", $Script:TaskCardPath
      )
      Start-Process -FilePath "powershell.exe" -ArgumentList (ConvertTo-ProcessArgumentString -ArgList $args) -WindowStyle Normal | Out-Null
      $payload = [pscustomobject]@{
        schema = "cucp.task-card/macro/v1"
        status = "ok"
        action = "open"
        path = $Script:TaskCardPath
        next_action = "Fill or edit the visible CUCP task card, then run macro task-card show or macro app-profile --match XG5000."
      }
      if ($Brief -and -not $jsonOnly) { [Console]::Out.WriteLine("ok task-card action=open path=$($Script:TaskCardPath)") }
      else { [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 8)) }
      return 0
    }
    "show" {
      $raw = Invoke-TaskCardScript -Mode "show"
      [Console]::Out.WriteLine(($raw -join "`n"))
      return 0
    }
    "ensure" {
      $raw = Invoke-TaskCardScript -Mode "ensure"
      if ($Brief -and -not $jsonOnly) { [Console]::Out.WriteLine("ok task-card action=ensure path=$($Script:TaskCardPath)") }
      else { [Console]::Out.WriteLine(($raw -join "`n")) }
      return 0
    }
    "save" {
      $saveArgs = Get-TaskCardSaveArgs -Rest $Rest
      $raw = Invoke-TaskCardScript -Mode "save" -ExtraArgs $saveArgs
      [Console]::Out.WriteLine(($raw -join "`n"))
      return 0
    }
    "path" {
      [Console]::Out.WriteLine($Script:TaskCardPath)
      return 0
    }
    "clear" {
      if (Test-Path -LiteralPath $Script:TaskCardPath) {
        Remove-Item -LiteralPath $Script:TaskCardPath -Force
      }
      $payload = [pscustomobject]@{
        schema = "cucp.task-card/macro/v1"
        status = "ok"
        action = "clear"
        path = $Script:TaskCardPath
      }
      if ($Brief -and -not $jsonOnly) { [Console]::Out.WriteLine("ok task-card action=clear") }
      else { [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 6)) }
      return 0
    }
    default {
      [Console]::Out.WriteLine("Usage: macro task-card open|show|ensure|save|path|clear [--tool XG5000] [--project <name>] [--plc <model>] [--devices <list>] [--requirements <text>]")
      return 2
    }
  }
}

function _Safety-Truncate {
  param([string]$Value, [int]$Max = 180)
  if ($null -eq $Value) { return "" }
  $s = "$Value"
  if ($s.Length -le $Max) { return $s }
  return $s.Substring(0, $Max) + "..."
}

function _Classify-SafetyFromText {
  param([string]$Text, [string]$MacroName)

  $raw = if ($Text) { "$Text" } else { "" }
  $hay = ("$MacroName $raw").ToLowerInvariant()
  $categories = New-Object System.Collections.ArrayList
  $evidenceMatches = New-Object System.Collections.ArrayList
  $score = 0

  function _SafetyAdd {
    param([string]$Category, [int]$Weight, [string]$Pattern, [string]$Reason)
    if (-not $Category) { return }
    $exists = $false
    foreach ($c in @($categories)) {
      if ("$($c.category)" -eq $Category) { $exists = $true; break }
    }
    if (-not $exists) {
      [void]$categories.Add([pscustomobject]@{
        category = $Category
        weight = [int]$Weight
        reason = $Reason
      })
    }
    [void]$evidenceMatches.Add([pscustomobject]@{
      category = $Category
      pattern = $Pattern
      reason = $Reason
    })
    $script:__cucpSafetyScore = [Math]::Max([int]$script:__cucpSafetyScore, [int]$Weight)
  }

  $script:__cucpSafetyScore = 0
  $rules = @(
    @{ category="credentials"; weight=85; pattern="password|passcode|otp|2fa|mfa|api[-_ ]?key|secret|token|private key|비밀번호|암호|인증번호|일회용|토큰|시크릿|api키|api 키"; reason="credential_or_secret_entry" },
    @{ category="payment"; weight=80; pattern="payment|pay now|checkout|purchase|buy|subscribe|billing|credit card|card number|결제|구매|구독|카드|청구|계좌|입금|출금"; reason="payment_or_billing_action" },
    @{ category="destructive"; weight=85; pattern="delete|remove|uninstall|format|wipe|factory reset|reset account|close account|deactivate|cancel subscription|drop database|삭제|제거|초기화|포맷|탈퇴|해지|폐기|영구|복구 불가"; reason="destructive_or_irreversible_action" },
    @{ category="external_send"; weight=55; pattern="send|submit|post|publish|email|mail|telegram|slack|discord|dm|upload|share|발송|전송|제출|게시|공개|업로드|공유|메일|문자|카톡|텔레그램"; reason="external_send_or_publish_action" },
    @{ category="identity_or_privacy"; weight=80; pattern="ssn|social security|passport|driver.?license|id card|resident registration|주민등록|여권|운전면허|신분증|개인정보|민감정보"; reason="identity_or_private_data" },
    @{ category="system_change"; weight=70; pattern="registry|regedit|firewall|permission|admin|administrator|environment variable|system settings|레지스트리|방화벽|권한|관리자|환경변수"; reason="system_or_permission_change" },
    @{ category="app_settings"; weight=50; pattern="settings|preferences|configuration|설정|환경설정|구성"; reason="application_settings_change" }
  )
  foreach ($rule in $rules) {
    if ($hay -match $rule.pattern) {
      _SafetyAdd -Category $rule.category -Weight ([int]$rule.weight) -Pattern "$($rule.pattern)" -Reason "$($rule.reason)"
    }
  }

  switch ($MacroName) {
    "registry" { _SafetyAdd -Category "system_change" -Weight 80 -Pattern "macro:registry" -Reason "registry_macro" }
    "process" { _SafetyAdd -Category "system_change" -Weight 65 -Pattern "macro:process" -Reason "process_control_macro" }
    "app-close" {
      if ($hay -match "--force|force") { _SafetyAdd -Category "destructive" -Weight 70 -Pattern "macro:app-close --force" -Reason "forced_app_close" }
    }
    "notify" { _SafetyAdd -Category "external_send" -Weight 45 -Pattern "macro:notify" -Reason "notification_macro" }
  }

  foreach ($c in @($categories)) {
    $score += [int]$c.weight
  }
  if ($score -gt 100) { $score = 100 }
  if ($script:__cucpSafetyScore -gt $score) { $score = [int]$script:__cucpSafetyScore }
  Remove-Variable -Name __cucpSafetyScore -Scope Script -ErrorAction SilentlyContinue

  $risk = "none"
  if ($score -ge 80) { $risk = "critical" }
  elseif ($score -ge 65) { $risk = "high" }
  elseif ($score -ge 45) { $risk = "medium" }
  elseif ($score -gt 0) { $risk = "low" }

  $requires = ($score -ge 45)
  return [pscustomobject]@{
    schema = "cucp.safety-classify/v1"
    status = "ok"
    macro = $MacroName
    risk_level = $risk
    risk_score = [int]$score
    requires_explicit_confirmation = [bool]$requires
    blocked_by_default = [bool]$requires
    confirmation_flag = "--confirm-sensitive"
    categories = @($categories)
    matches = @($evidenceMatches)
    input_preview = (_Safety-Truncate -Value $raw -Max 180)
    recommended_action = if ($requires) { "Require explicit user confirmation before live control; prefer --dry-run/read-only planning first." } else { "No sensitive-action confirmation required by the local classifier." }
  }
}

function Invoke-MacroSafetyClassify {
  param([string[]]$Rest)
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  $macro = _Read-OptValue -Rest $Rest -Name "--macro"
  $parts = New-Object System.Collections.ArrayList
  foreach ($v in @(_Read-AllOptValues -Rest $Rest -Name "--text")) { if ($null -ne $v) { [void]$parts.Add("$v") } }
  foreach ($v in @(_Read-AllOptValues -Rest $Rest -Name "--step")) { if ($null -ne $v) { [void]$parts.Add("$v") } }
  foreach ($v in @(_Read-AllOptValues -Rest $Rest -Name "--command")) { if ($null -ne $v) { [void]$parts.Add("$v") } }
  if ($parts.Count -eq 0) {
    $skipValue = @{"--text"=$true; "--step"=$true; "--command"=$true; "--macro"=$true}
    $skip = @{"--json-only"=$true}
    $skipNext = $false
    foreach ($a in @($Rest)) {
      if ($skipNext) { $skipNext = $false; continue }
      if ($skip.ContainsKey($a)) { continue }
      if ($skipValue.ContainsKey($a)) { $skipNext = $true; continue }
      [void]$parts.Add("$a")
    }
  }
  $text = (@($parts) -join " ")
  if (-not $macro) {
    $parsed = _Parse-WorkflowStepTokens -Step $text
    if ($parsed.ok -and $parsed.tokens.Count -ge 2 -and $parsed.tokens[0] -eq "macro") { $macro = "$($parsed.tokens[1])" }
  }
  $payload = _Classify-SafetyFromText -Text $text -MacroName $macro
  if ($Brief -and -not $jsonOnly) {
    [Console]::Out.WriteLine("ok safety-classify risk=$($payload.risk_level) score=$($payload.risk_score) confirm=$($payload.requires_explicit_confirmation)")
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 10))
  }
  return 0
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

function _Native-HitTestPoint {
  param(
    [int]$X,
    [int]$Y,
    [int]$TargetHwnd,
    [string]$TargetMatch
  )
  if (-not (_Ensure-Win32Loaded)) { throw "Win32 load failed" }
  $win = [CucpWin32]::WindowFromScreenPoint($X, $Y)
  if (-not $win) {
    return [pscustomobject]@{
      status = "partial"
      reason = "no_window_at_coords"
      x = $X
      y = $Y
      child_hwnd = 0
      root_hwnd = 0
      root_title = ""
      child_title = ""
      root_class = ""
      process_id = 0
      process_name = ""
      target_hwnd = $TargetHwnd
      target_match = $TargetMatch
      matched = $false
      match_reason = "no_window_at_coords"
      uia_skipped = $true
      source = "wrapper_win32_fast"
    }
  }

  $matched = $true
  $matchReason = "no_target_specified"
  if ($TargetHwnd -gt 0) {
    $matched = ([int64]$win.Hwnd -eq [int64]$TargetHwnd)
    $matchReason = if ($matched) { "hwnd_match" } else { "hwnd_mismatch" }
  } elseif ($TargetMatch) {
    $needle = $TargetMatch.ToLowerInvariant()
    $title = if ($win.Title) { "$($win.Title)".ToLowerInvariant() } else { "" }
    $proc = if ($win.ProcessName) { "$($win.ProcessName)".ToLowerInvariant() } else { "" }
    $matched = ($title.Contains($needle) -or $proc.Contains($needle))
    $matchReason = if ($matched) { "title_or_process_match" } else { "title_mismatch" }
  }
  $status = "ok"
  if ((($TargetHwnd -gt 0) -or $TargetMatch) -and -not $matched) { $status = "partial" }

  return [pscustomobject]@{
    status = $status
    x = $X
    y = $Y
    child_hwnd = [int64]$win.ChildHwnd
    root_hwnd = [int64]$win.Hwnd
    root_title = "$($win.Title)"
    child_title = ""
    root_class = "$($win.ClassName)"
    process_id = [int]$win.Pid
    process_name = "$($win.ProcessName)"
    target_hwnd = $TargetHwnd
    target_match = $TargetMatch
    matched = [bool]$matched
    match_reason = $matchReason
    uia_skipped = $true
    source = "wrapper_win32_fast"
  }
}

function _CoordProfile-MonitorObject {
  param($Monitor)
  if (-not $Monitor) { return $null }
  return [pscustomobject]@{
    device = "$($Monitor.DeviceName)"
    primary = [bool]$Monitor.Primary
    rect = [pscustomobject]@{
      x = [int]$Monitor.X
      y = [int]$Monitor.Y
      width = [int]$Monitor.Width
      height = [int]$Monitor.Height
    }
    work_rect = [pscustomobject]@{
      x = [int]$Monitor.WorkX
      y = [int]$Monitor.WorkY
      width = [int]$Monitor.WorkWidth
      height = [int]$Monitor.WorkHeight
    }
    dpi = [pscustomobject]@{
      x = [int]$Monitor.DpiX
      y = [int]$Monitor.DpiY
      scale_x = [double]$Monitor.ScaleX
      scale_y = [double]$Monitor.ScaleY
    }
  }
}

function _CoordProfile-WindowFromPrecheck {
  param($Precheck)
  if (-not $Precheck -or -not $Precheck.root_hwnd -or [int64]$Precheck.root_hwnd -le 0) { return $null }
  $wins = @(_Enumerate-Win32Windows)
  foreach ($w in $wins) {
    if ([int64]$w.hwnd -eq [int64]$Precheck.root_hwnd) { return $w }
  }
  return [pscustomobject]@{
    hwnd = [int64]$Precheck.root_hwnd
    title = "$($Precheck.root_title)"
    class = "$($Precheck.root_class)"
    pid = [int]$Precheck.process_id
    process = "$($Precheck.process_name)"
    visible = $true
    minimized = $false
    foreground = $false
    rect = $null
  }
}

function _Build-CoordProfile {
  param(
    [bool]$HasPoint,
    [int]$X,
    [int]$Y,
    [int64]$TargetHwnd,
    [string]$TargetMatch
  )
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  if (-not (_Ensure-Win32Loaded)) {
    $sw.Stop()
    return [pscustomobject]@{
      schema = "cucp.coord-profile/v1"
      status = "partial"
      reason = "win32_load_failed"
      elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
    }
  }

  $virtualRaw = [CucpWin32]::GetVirtualScreenInfo()
  $virtual = [pscustomobject]@{
    x = [int]$virtualRaw.X
    y = [int]$virtualRaw.Y
    width = [int]$virtualRaw.Width
    height = [int]$virtualRaw.Height
    right = [int]($virtualRaw.X + $virtualRaw.Width)
    bottom = [int]($virtualRaw.Y + $virtualRaw.Height)
    monitor_count = [int]$virtualRaw.MonitorCount
    same_display_format = [bool]$virtualRaw.SameDisplayFormat
  }
  $monitors = @([CucpWin32]::EnumerateMonitors() | ForEach-Object { _CoordProfile-MonitorObject -Monitor $_ })
  $point = if ($HasPoint) { [pscustomobject]@{ x = $X; y = $Y } } else { $null }
  $insideVirtual = $null
  $pointMonitor = $null
  $pointHit = $null
  if ($HasPoint) {
    $insideVirtual = ($X -ge $virtual.x -and $X -lt $virtual.right -and $Y -ge $virtual.y -and $Y -lt $virtual.bottom)
    try { $pointMonitor = _CoordProfile-MonitorObject -Monitor ([CucpWin32]::MonitorFromScreenPointInfo($X,$Y)) } catch { }
    try { $pointHit = _Native-HitTestPoint -X $X -Y $Y -TargetHwnd ([int]$TargetHwnd) -TargetMatch $TargetMatch } catch { }
  }

  $targetWindow = $null
  if ($TargetHwnd -gt 0) {
    foreach ($w in @(_Enumerate-Win32Windows)) {
      if ([int64]$w.hwnd -eq [int64]$TargetHwnd) { $targetWindow = $w; break }
    }
  }
  if (-not $targetWindow -and $TargetMatch) { $targetWindow = _Native-FindWindow -Name $TargetMatch }
  if (-not $targetWindow -and $pointHit) { $targetWindow = _CoordProfile-WindowFromPrecheck -Precheck $pointHit }

  $targetRect = $null
  $targetMonitor = $null
  $windowDpi = $null
  if ($targetWindow) {
    $targetRect = $targetWindow.rect
    try { $targetMonitor = _CoordProfile-MonitorObject -Monitor ([CucpWin32]::MonitorFromWindowInfo([IntPtr]([int64]$targetWindow.hwnd))) } catch { }
    try {
      $dpiValue = [CucpWin32]::GetWindowDpiValue([IntPtr]([int64]$targetWindow.hwnd))
      if ([int]$dpiValue -gt 0) {
        $windowDpi = [pscustomobject]@{
          dpi = [int]$dpiValue
          scale = [Math]::Round(([double]$dpiValue / 96.0), 4)
        }
      }
    } catch { }
  }

  $pointInTarget = $null
  $pointWindowRelative = $null
  $edgeDistance = $null
  if ($HasPoint -and $targetRect) {
    $right = [int]$targetRect.x + [int]$targetRect.width
    $bottom = [int]$targetRect.y + [int]$targetRect.height
    $pointInTarget = ($X -ge [int]$targetRect.x -and $X -lt $right -and $Y -ge [int]$targetRect.y -and $Y -lt $bottom)
    $relX = $X - [int]$targetRect.x
    $relY = $Y - [int]$targetRect.y
    $pointWindowRelative = [pscustomobject]@{
      x = [int]$relX
      y = [int]$relY
      norm_x = if ([int]$targetRect.width -gt 0) { [Math]::Round(([double]$relX / [double]$targetRect.width), 6) } else { $null }
      norm_y = if ([int]$targetRect.height -gt 0) { [Math]::Round(([double]$relY / [double]$targetRect.height), 6) } else { $null }
    }
    $edgeDistance = [pscustomobject]@{
      left = [int]($X - [int]$targetRect.x)
      top = [int]($Y - [int]$targetRect.y)
      right = [int]($right - $X - 1)
      bottom = [int]($bottom - $Y - 1)
      min = [int]([Math]::Min([Math]::Min($X - [int]$targetRect.x, $Y - [int]$targetRect.y), [Math]::Min($right - $X - 1, $bottom - $Y - 1)))
    }
  }

  $warnings = New-Object System.Collections.ArrayList
  $risk = "low"
  if ($HasPoint -and -not $insideVirtual) {
    $risk = "high"
    [void]$warnings.Add("point_outside_virtual_screen")
  }
  if ($HasPoint -and $targetRect -and -not $pointInTarget) {
    $risk = "high"
    [void]$warnings.Add("point_outside_target_window")
  }
  if ($HasPoint -and $edgeDistance -and [int]$edgeDistance.min -ge 0 -and [int]$edgeDistance.min -lt 4 -and $risk -ne "high") {
    $risk = "medium"
    [void]$warnings.Add("point_near_target_window_edge")
  }
  if ($targetMonitor -and ($targetMonitor.dpi.scale_x -ne 1.0 -or $targetMonitor.dpi.scale_y -ne 1.0)) {
    if ($risk -eq "low") { $risk = "medium" }
    [void]$warnings.Add("non_100_percent_dpi_scale")
  }
  if ([int]$virtual.monitor_count -gt 1) {
    if ($risk -eq "low") { $risk = "medium" }
    [void]$warnings.Add("multi_monitor_coordinates")
  }
  if ($HasPoint -and $pointMonitor -and $targetMonitor -and $pointMonitor.device -and $targetMonitor.device -and $pointMonitor.device -ne $targetMonitor.device) {
    $risk = "high"
    [void]$warnings.Add("point_monitor_differs_from_target_window_monitor")
  }
  if ($pointHit -and (($TargetMatch) -or ($TargetHwnd -gt 0)) -and -not [bool]$pointHit.matched) {
    $risk = "high"
    [void]$warnings.Add("win32_hit_test_target_mismatch")
  }

  $signatureParts = New-Object System.Collections.ArrayList
  [void]$signatureParts.Add("vs=$($virtual.x),$($virtual.y),$($virtual.width),$($virtual.height)")
  foreach ($m in @($monitors)) {
    [void]$signatureParts.Add("m=$($m.device):$($m.rect.x),$($m.rect.y),$($m.rect.width),$($m.rect.height):$($m.dpi.x)x$($m.dpi.y)")
  }
  if ($targetWindow) { [void]$signatureParts.Add("target=$([int64]$targetWindow.hwnd)") }
  $signature = (($signatureParts | ForEach-Object { "$_" }) -join "|")

  $sw.Stop()
  return [pscustomobject]@{
    schema = "cucp.coord-profile/v1"
    status = "ok"
    point = $point
    has_point = [bool]$HasPoint
    coordinate_risk = $risk
    warnings = @($warnings)
    virtual_screen = $virtual
    monitors = @($monitors)
    point_inside_virtual_screen = $insideVirtual
    point_monitor = $pointMonitor
    target_window = if ($targetWindow) {
      [pscustomobject]@{
        hwnd = [int64]$targetWindow.hwnd
        title = "$($targetWindow.title)"
        process = "$($targetWindow.process)"
        class = "$($targetWindow.class)"
        foreground = [bool]$targetWindow.foreground
        rect = $targetRect
      }
    } else { $null }
    target_monitor = $targetMonitor
    target_window_dpi = $windowDpi
    point_inside_target_window = $pointInTarget
    point_window_relative = $pointWindowRelative
    edge_distance_to_target = $edgeDistance
    hit_test = $pointHit
    coord_signature = $signature
    elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
    next_step = if ($HasPoint) { "Use point-plan for micro-refined click planning; if coordinate_risk is high, re-ground with app-profile or smart-plan before live control." } else { "Use this profile to understand DPI/monitor layout before planning coordinate clicks." }
  }
}

function Invoke-MacroCoordProfile {
  param([string[]]$Rest)
  $xRaw = _Read-OptValue -Rest $Rest -Name "--x"
  $yRaw = _Read-OptValue -Rest $Rest -Name "--y"
  $hasPoint = ($null -ne $xRaw -and $null -ne $yRaw)
  $x = 0
  $y = 0
  if ($hasPoint) { $x = [int]$xRaw; $y = [int]$yRaw }
  $tm = _Read-OptValue -Rest $Rest -Name "--target-match"
  if (-not $tm) { $tm = _Read-OptValue -Rest $Rest -Name "--match" }
  if (-not $tm) { $tm = _Read-OptValue -Rest $Rest -Name "--window" }
  $th = [int64](_Read-OptValue -Rest $Rest -Name "--target-hwnd")
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  $profile = _Build-CoordProfile -HasPoint $hasPoint -X $x -Y $y -TargetHwnd $th -TargetMatch $tm
  if ($Brief -and -not $jsonOnly) {
    [Console]::Out.WriteLine("$($profile.status) coord-profile risk=$($profile.coordinate_risk) monitors=$($profile.virtual_screen.monitor_count) warnings=$(@($profile.warnings).Count) elapsed_ms=$($profile.elapsed_ms)")
  } else {
    [Console]::Out.WriteLine(($profile | ConvertTo-Json -Depth 12))
  }
  if ($profile.status -eq "ok") { return 0 }
  return 2
}

function _CoordMap-ResolveWindow {
  param([int64]$TargetHwnd, [string]$TargetMatch)
  if ($TargetHwnd -gt 0) {
    foreach ($w in @(_Enumerate-Win32Windows)) {
      if ([int64]$w.hwnd -eq [int64]$TargetHwnd) { return $w }
    }
  }
  if ($TargetMatch) { return (_Native-FindWindow -Name $TargetMatch) }
  return $null
}

function _CoordMap-Rect {
  param([int]$X, [int]$Y, [int]$Width, [int]$Height)
  return [pscustomobject]@{ x=$X; y=$Y; width=$Width; height=$Height }
}

function _CoordMap-ClipRect {
  param($Rect, $Virtual)
  if (-not $Rect -or -not $Virtual) { return $null }
  $left = [Math]::Max([int]$Rect.x, [int]$Virtual.x)
  $top = [Math]::Max([int]$Rect.y, [int]$Virtual.y)
  $right = [Math]::Min(([int]$Rect.x + [int]$Rect.width), [int]$Virtual.right)
  $bottom = [Math]::Min(([int]$Rect.y + [int]$Rect.height), [int]$Virtual.bottom)
  $width = [Math]::Max(0, $right - $left)
  $height = [Math]::Max(0, $bottom - $top)
  return (_CoordMap-Rect -X $left -Y $top -Width $width -Height $height)
}

function _CoordMap-MakePoint {
  param([double]$X, [double]$Y)
  return [pscustomobject]@{ x=[int][Math]::Round($X); y=[int][Math]::Round($Y) }
}

function _Build-CoordMap {
  param(
    [string]$From,
    [double]$X,
    [double]$Y,
    [double]$NormX,
    [double]$NormY,
    [bool]$HasNorm,
    [int64]$TargetHwnd,
    [string]$TargetMatch
  )
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  if (-not (_Ensure-Win32Loaded)) {
    $sw.Stop()
    return [pscustomobject]@{ schema="cucp.coord-map/v1"; status="partial"; reason="win32_load_failed"; elapsed_ms=[int]$sw.Elapsed.TotalMilliseconds }
  }
  if (-not $From) { $From = "screen" }
  $From = "$From".ToLowerInvariant()
  $virtualRaw = [CucpWin32]::GetVirtualScreenInfo()
  $virtual = [pscustomobject]@{
    x = [int]$virtualRaw.X
    y = [int]$virtualRaw.Y
    width = [int]$virtualRaw.Width
    height = [int]$virtualRaw.Height
    right = [int]($virtualRaw.X + $virtualRaw.Width)
    bottom = [int]($virtualRaw.Y + $virtualRaw.Height)
    monitor_count = [int]$virtualRaw.MonitorCount
  }

  $win = _CoordMap-ResolveWindow -TargetHwnd $TargetHwnd -TargetMatch $TargetMatch
  if (-not $win -and $From -eq "screen") {
    try {
      $hit = _Native-HitTestPoint -X ([int][Math]::Round($X)) -Y ([int][Math]::Round($Y)) -TargetHwnd 0 -TargetMatch $null
      if ($hit -and [int64]$hit.root_hwnd -gt 0) { $win = _CoordProfile-WindowFromPrecheck -Precheck $hit }
    } catch { }
  }
  if (-not $win) {
    $sw.Stop()
    return [pscustomobject]@{
      schema = "cucp.coord-map/v1"
      status = "partial"
      reason = "target_window_not_found"
      from = $From
      target_hwnd = $TargetHwnd
      target_match = $TargetMatch
      virtual_screen = $virtual
      elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
      next_step = "Provide --target-match or --target-hwnd, or use --from screen with a point inside the target window."
    }
  }

  $rect = $win.rect
  $visible = _CoordMap-ClipRect -Rect $rect -Virtual $virtual
  $screenPoint = $null
  $windowPoint = $null
  $visibleWindowPoint = $null
  $normalizedPoint = $null
  $insideWindow = $false
  $insideVisibleClip = $false
  $roundingWarning = $false

  switch ($From) {
    "screen" {
      $screenPoint = _CoordMap-MakePoint -X $X -Y $Y
      $windowPoint = _CoordMap-MakePoint -X ($screenPoint.x - [int]$rect.x) -Y ($screenPoint.y - [int]$rect.y)
      $visibleWindowPoint = if ($visible) { _CoordMap-MakePoint -X ($screenPoint.x - [int]$visible.x) -Y ($screenPoint.y - [int]$visible.y) } else { $null }
    }
    "window" {
      $windowPoint = _CoordMap-MakePoint -X $X -Y $Y
      $screenPoint = _CoordMap-MakePoint -X ([int]$rect.x + $windowPoint.x) -Y ([int]$rect.y + $windowPoint.y)
      $visibleWindowPoint = if ($visible) { _CoordMap-MakePoint -X ($screenPoint.x - [int]$visible.x) -Y ($screenPoint.y - [int]$visible.y) } else { $null }
    }
    "visible-window" {
      $visibleWindowPoint = _CoordMap-MakePoint -X $X -Y $Y
      if (-not $visible -or [int]$visible.width -le 0 -or [int]$visible.height -le 0) {
        $sw.Stop()
        return [pscustomobject]@{ schema="cucp.coord-map/v1"; status="partial"; reason="window_not_visible_in_virtual_screen"; from=$From; selected_window=$win; virtual_screen=$virtual; elapsed_ms=[int]$sw.Elapsed.TotalMilliseconds }
      }
      $screenPoint = _CoordMap-MakePoint -X ([int]$visible.x + $visibleWindowPoint.x) -Y ([int]$visible.y + $visibleWindowPoint.y)
      $windowPoint = _CoordMap-MakePoint -X ($screenPoint.x - [int]$rect.x) -Y ($screenPoint.y - [int]$rect.y)
    }
    "normalized" {
      if (-not $HasNorm) { $NormX = $X; $NormY = $Y }
      $normalizedPoint = [pscustomobject]@{ x=[Math]::Round($NormX, 6); y=[Math]::Round($NormY, 6) }
      $screenPoint = _CoordMap-MakePoint -X ([int]$rect.x + ($NormX * [int]$rect.width)) -Y ([int]$rect.y + ($NormY * [int]$rect.height))
      $windowPoint = _CoordMap-MakePoint -X ($screenPoint.x - [int]$rect.x) -Y ($screenPoint.y - [int]$rect.y)
      $visibleWindowPoint = if ($visible) { _CoordMap-MakePoint -X ($screenPoint.x - [int]$visible.x) -Y ($screenPoint.y - [int]$visible.y) } else { $null }
      $roundingWarning = $true
    }
    "visible-normalized" {
      if (-not $HasNorm) { $NormX = $X; $NormY = $Y }
      if (-not $visible -or [int]$visible.width -le 0 -or [int]$visible.height -le 0) {
        $sw.Stop()
        return [pscustomobject]@{ schema="cucp.coord-map/v1"; status="partial"; reason="window_not_visible_in_virtual_screen"; from=$From; selected_window=$win; virtual_screen=$virtual; elapsed_ms=[int]$sw.Elapsed.TotalMilliseconds }
      }
      $normalizedPoint = [pscustomobject]@{ x=[Math]::Round($NormX, 6); y=[Math]::Round($NormY, 6) }
      $screenPoint = _CoordMap-MakePoint -X ([int]$visible.x + ($NormX * [int]$visible.width)) -Y ([int]$visible.y + ($NormY * [int]$visible.height))
      $visibleWindowPoint = _CoordMap-MakePoint -X ($screenPoint.x - [int]$visible.x) -Y ($screenPoint.y - [int]$visible.y)
      $windowPoint = _CoordMap-MakePoint -X ($screenPoint.x - [int]$rect.x) -Y ($screenPoint.y - [int]$rect.y)
      $roundingWarning = $true
    }
    default {
      $sw.Stop()
      return [pscustomobject]@{ schema="cucp.coord-map/v1"; status="partial"; reason="unsupported_from"; from=$From; supported_from=@("screen","window","visible-window","normalized","visible-normalized"); elapsed_ms=[int]$sw.Elapsed.TotalMilliseconds }
    }
  }

  if (-not $normalizedPoint -and $windowPoint -and [int]$rect.width -gt 0 -and [int]$rect.height -gt 0) {
    $normalizedPoint = [pscustomobject]@{
      x = [Math]::Round(([double]$windowPoint.x / [double]$rect.width), 6)
      y = [Math]::Round(([double]$windowPoint.y / [double]$rect.height), 6)
    }
  }
  if ($screenPoint) {
    $insideWindow = ($screenPoint.x -ge [int]$rect.x -and $screenPoint.x -lt ([int]$rect.x + [int]$rect.width) -and $screenPoint.y -ge [int]$rect.y -and $screenPoint.y -lt ([int]$rect.y + [int]$rect.height))
    if ($visible) {
      $insideVisibleClip = ($screenPoint.x -ge [int]$visible.x -and $screenPoint.x -lt ([int]$visible.x + [int]$visible.width) -and $screenPoint.y -ge [int]$visible.y -and $screenPoint.y -lt ([int]$visible.y + [int]$visible.height))
    }
  }
  $profile = if ($screenPoint) { _Build-CoordProfile -HasPoint $true -X $screenPoint.x -Y $screenPoint.y -TargetHwnd ([int64]$win.hwnd) -TargetMatch $null } else { $null }
  $warnings = New-Object System.Collections.ArrayList
  if (-not $insideWindow) { [void]$warnings.Add("mapped_point_outside_window") }
  if (-not $insideVisibleClip) { [void]$warnings.Add("mapped_point_outside_visible_clip") }
  if ($roundingWarning) { [void]$warnings.Add("normalized_point_rounded_to_integer_screen_pixel") }
  if ($profile -and $profile.coordinate_risk -eq "high") {
    [void]$warnings.Add("coordinate_profile_high_risk")
    foreach ($pw in @($profile.warnings)) {
      if ($pw) { [void]$warnings.Add("$pw") }
    }
  }
  $sw.Stop()
  return [pscustomobject]@{
    schema = "cucp.coord-map/v1"
    status = "ok"
    from = $From
    input = [pscustomobject]@{ x=$X; y=$Y; norm_x=if ($HasNorm) { $NormX } else { $null }; norm_y=if ($HasNorm) { $NormY } else { $null } }
    selected_window = [pscustomobject]@{ hwnd=[int64]$win.hwnd; title="$($win.title)"; process="$($win.process)"; class="$($win.class)"; rect=$rect }
    virtual_screen = $virtual
    visible_window_clip = $visible
    screen_point = $screenPoint
    window_point = $windowPoint
    visible_window_point = $visibleWindowPoint
    normalized_window_point = $normalizedPoint
    inside_window = [bool]$insideWindow
    inside_visible_clip = [bool]$insideVisibleClip
    coordinate_profile = $profile
    warnings = @($warnings)
    elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
    next_step = "Use screen_point with point-plan or click-point after read-only verification; use normalized_window_point to persist a layout-relative target."
  }
}

function Invoke-MacroCoordMap {
  param([string[]]$Rest)
  $from = _Read-OptValue -Rest $Rest -Name "--from"
  if (-not $from) { $from = _Read-OptValue -Rest $Rest -Name "--mode" }
  if (-not $from) { $from = "screen" }
  $xRaw = _Read-OptValue -Rest $Rest -Name "--x"
  $yRaw = _Read-OptValue -Rest $Rest -Name "--y"
  $normXRaw = _Read-OptValue -Rest $Rest -Name "--norm-x"
  $normYRaw = _Read-OptValue -Rest $Rest -Name "--norm-y"
  $hasNorm = ($null -ne $normXRaw -and $null -ne $normYRaw)
  if ((-not $hasNorm) -and ($null -eq $xRaw -or $null -eq $yRaw)) { throw "macro coord-map requires --x/--y or --norm-x/--norm-y" }
  $x = if ($null -ne $xRaw) { [double]$xRaw } else { 0.0 }
  $y = if ($null -ne $yRaw) { [double]$yRaw } else { 0.0 }
  $normX = if ($hasNorm) { [double]$normXRaw } else { 0.0 }
  $normY = if ($hasNorm) { [double]$normYRaw } else { 0.0 }
  $tm = _Read-OptValue -Rest $Rest -Name "--target-match"
  if (-not $tm) { $tm = _Read-OptValue -Rest $Rest -Name "--match" }
  if (-not $tm) { $tm = _Read-OptValue -Rest $Rest -Name "--window" }
  $th = [int64](_Read-OptValue -Rest $Rest -Name "--target-hwnd")
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  $payload = _Build-CoordMap -From $from -X $x -Y $y -NormX $normX -NormY $normY -HasNorm $hasNorm -TargetHwnd $th -TargetMatch $tm
  if ($Brief -and -not $jsonOnly) {
    $sp = if ($payload.screen_point) { "$($payload.screen_point.x),$($payload.screen_point.y)" } else { "none" }
    [Console]::Out.WriteLine("$($payload.status) coord-map from=$from screen=$sp inside=$($payload.inside_window) warnings=$(@($payload.warnings).Count) elapsed_ms=$($payload.elapsed_ms)")
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 12))
  }
  if ($payload.status -eq "ok") { return 0 }
  return 2
}

function _AnchorHistory-Read {
  param([int]$Last = 500)
  if ($Last -le 0) { $Last = 500 }
  if (-not $Script:AnchorHistoryFile -or -not (Test-Path -LiteralPath $Script:AnchorHistoryFile)) { return @() }
  $lines = @(Get-Content -LiteralPath $Script:AnchorHistoryFile -Encoding UTF8 -ErrorAction SilentlyContinue)
  if (-not $lines -or $lines.Count -eq 0) { return @() }
  $start = [Math]::Max(0, $lines.Count - $Last)
  $records = New-Object System.Collections.ArrayList
  foreach ($line in @($lines | Select-Object -Skip $start)) {
    if (-not "$line".Trim()) { continue }
    try { [void]$records.Add(($line | ConvertFrom-Json -ErrorAction Stop)) } catch { }
  }
  return @($records)
}

function _AnchorHistory-NormDistance {
  param($A, $B)
  if (-not $A -or -not $B) { return [double]::MaxValue }
  try {
    $dx = [double]$A.x - [double]$B.x
    $dy = [double]$A.y - [double]$B.y
    return [Math]::Sqrt(($dx * $dx) + ($dy * $dy))
  } catch { return [double]::MaxValue }
}

function _AnchorHistory-Append {
  param($Record)
  if (-not $Record) { return $false }
  try {
    $dir = Split-Path -Parent $Script:AnchorHistoryFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $line = ($Record | ConvertTo-Json -Compress -Depth 10)
    Add-Content -LiteralPath $Script:AnchorHistoryFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Script:AnchorHistoryFile) {
      $all = @(Get-Content -LiteralPath $Script:AnchorHistoryFile -Encoding UTF8 -ErrorAction SilentlyContinue)
      $max = if ($Script:AnchorHistoryMax -gt 0) { [int]$Script:AnchorHistoryMax } else { 500 }
      if ($all.Count -gt $max) {
        $keep = [Math]::Max(50, [int]($max * 0.8))
        $tail = $all[($all.Count - $keep)..($all.Count - 1)]
        [System.IO.File]::WriteAllLines($Script:AnchorHistoryFile, $tail, (New-Object System.Text.UTF8Encoding($true)))
      }
    }
    return $true
  } catch { return $false }
}

function _AnchorHistory-Score {
  param(
    $Record,
    [double]$Tolerance = 0.012
  )
  if (-not $Record) {
    return [pscustomobject]@{
      schema = "cucp.anchor-reuse-score/v1"
      enabled = $true
      status = "partial"
      reason = "missing_anchor_record"
      score = 0
      confidence = "none"
      recorded = $false
    }
  }
  if ($Tolerance -le 0) { $Tolerance = 0.012 }
  if ($Tolerance -gt 0.1) { $Tolerance = 0.1 }
  $records = @(_AnchorHistory-Read -Last 500)
  $exact = New-Object System.Collections.ArrayList
  $near = New-Object System.Collections.ArrayList
  $recordTarget = "$($Record.target_match)"
  $recordProcess = "$($Record.process)"
  $recordClass = "$($Record.class)"
  foreach ($r in @($records)) {
    $isExact = ($r.anchor_id -and "$($r.anchor_id)" -eq "$($Record.anchor_id)")
    if ($isExact) { [void]$exact.Add($r) }
    $sameSurface = $false
    if ($recordTarget -and "$($r.target_match)" -eq $recordTarget) { $sameSurface = $true }
    elseif ($recordProcess -and $recordClass -and "$($r.process)" -eq $recordProcess -and "$($r.class)" -eq $recordClass) { $sameSurface = $true }
    if ($sameSurface) {
      $dist = _AnchorHistory-NormDistance -A $r.normalized_window_point -B $Record.normalized_window_point
      if ($dist -le $Tolerance) { [void]$near.Add($r) }
    }
  }

  $matches = @($exact)
  foreach ($n in @($near)) {
    $seen = $false
    foreach ($e in @($matches)) {
      if ($e.anchor_id -and $n.anchor_id -and "$($e.anchor_id)" -eq "$($n.anchor_id)") { $seen = $true; break }
    }
    if (-not $seen) { $matches += $n }
  }

  $last = if ($matches.Count -gt 0) { $matches[$matches.Count - 1] } else { $null }
  $safeMatches = @($matches | Where-Object { $_.safe_to_reuse -eq $true })
  $safeRate = 0
  if ($matches.Count -gt 0) { $safeRate = [Math]::Round(([double]$safeMatches.Count / [double]$matches.Count), 3) }
  $signatureMatch = $false
  if ($last -and $last.coord_signature -and $Record.coord_signature) {
    $signatureMatch = ("$($last.coord_signature)" -eq "$($Record.coord_signature)")
  }

  $score = if ($Record.safe_to_reuse -eq $true) { 30 } else { 5 }
  switch ("$($Record.coordinate_risk)") {
    "low" { $score += 15 }
    "medium" { $score += 5 }
    "high" { $score -= 25 }
    default { }
  }
  $score += [Math]::Min(25, ($exact.Count * 7))
  $score += [Math]::Min(15, ($near.Count * 3))
  if ($matches.Count -gt 0) { $score += [int][Math]::Round($safeRate * 10) }
  if ($matches.Count -gt 0 -and $signatureMatch) { $score += 10 }
  elseif ($matches.Count -gt 0 -and -not $signatureMatch) { $score -= 8 }
  if ($score -lt 0) { $score = 0 }
  if ($score -gt 100) { $score = 100 }

  $confidence = "none"
  if ($score -ge 80) { $confidence = "high" }
  elseif ($score -ge 60) { $confidence = "medium" }
  elseif ($score -ge 35) { $confidence = "low" }

  $warnings = New-Object System.Collections.ArrayList
  if ($records.Count -eq 0) { [void]$warnings.Add("no_anchor_history") }
  elseif ($matches.Count -eq 0) { [void]$warnings.Add("no_matching_anchor_history") }
  if ($matches.Count -gt 0 -and -not $signatureMatch) { [void]$warnings.Add("coord_signature_changed_since_last_match") }
  if ($Record.safe_to_reuse -ne $true) { [void]$warnings.Add("current_anchor_not_safe_to_reuse") }
  if ("$($Record.coordinate_risk)" -eq "high") { [void]$warnings.Add("coordinate_risk_high") }

  return [pscustomobject]@{
    schema = "cucp.anchor-reuse-score/v1"
    enabled = $true
    status = "ok"
    history_file = $Script:AnchorHistoryFile
    score = [int]$score
    confidence = $confidence
    recorded = $false
    total_records = [int]$records.Count
    exact_match_count = [int]$exact.Count
    near_match_count = [int]$near.Count
    matched_record_count = [int]$matches.Count
    safe_match_count = [int]$safeMatches.Count
    safe_match_rate = [double]$safeRate
    tolerance_norm = [double]$Tolerance
    signature_match = [bool]$signatureMatch
    last_seen = if ($last) { "$($last.ts)" } else { "" }
    last_screen_point = if ($last) { $last.screen_point } else { $null }
    last_coord_signature = if ($last) { "$($last.coord_signature)" } else { "" }
    warnings = @($warnings)
    recommendation = if ($score -ge 80 -and $Record.safe_to_reuse -eq $true) { "reuse_ok_after_target_validate" } elseif ($score -ge 45) { "verify_with_target_validate_before_live_click" } else { "re_ground_before_reuse" }
  }
}

function Invoke-MacroCoordAnchor {
  param([string[]]$Rest)
  $x = [int](_Read-OptValue -Rest $Rest -Name "--x")
  $y = [int](_Read-OptValue -Rest $Rest -Name "--y")
  $tm = _Read-OptValue -Rest $Rest -Name "--target-match"
  if (-not $tm) { $tm = _Read-OptValue -Rest $Rest -Name "--match" }
  if (-not $tm) { $tm = _Read-OptValue -Rest $Rest -Name "--window" }
  $th = [int64](_Read-OptValue -Rest $Rest -Name "--target-hwnd")
  $radiusRaw = _Read-OptValue -Rest $Rest -Name "--radius"
  $stepRaw = _Read-OptValue -Rest $Rest -Name "--step"
  $recordHistory = (_Read-Switch -Rest $Rest -Name "--record-history") -or (_Read-Switch -Rest $Rest -Name "--learn-history")
  $noHistory = _Read-Switch -Rest $Rest -Name "--no-history"
  $historyToleranceRaw = _Read-OptValue -Rest $Rest -Name "--history-tolerance"
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  $radius = 6
  $step = 2
  $historyTolerance = 0.012
  if ($null -ne $radiusRaw -and "$radiusRaw" -ne "") { $radius = [int]$radiusRaw }
  if ($null -ne $stepRaw -and "$stepRaw" -ne "") { $step = [int]$stepRaw }
  if ($null -ne $historyToleranceRaw -and "$historyToleranceRaw" -ne "") { $historyTolerance = [double]$historyToleranceRaw }
  if ($x -le 0 -or $y -le 0) { throw "macro coord-anchor requires --x and --y" }
  if ($radius -lt 0) { $radius = 0 }
  if ($step -le 0) { $step = 2 }
  if ($historyTolerance -le 0) { $historyTolerance = 0.012 }
  if ($historyTolerance -gt 0.1) { $historyTolerance = 0.1 }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $map = _Build-CoordMap -From "screen" -X $x -Y $y -NormX 0 -NormY 0 -HasNorm $false -TargetHwnd $th -TargetMatch $tm
  if (-not $map -or $map.status -ne "ok") {
    $sw.Stop()
    $payload = [pscustomobject]@{
      schema = "cucp.coord-anchor/v1"
      status = "partial"
      reason = if ($map -and $map.reason) { "$($map.reason)" } else { "coord_map_failed" }
      source_point = [pscustomobject]@{ x=$x; y=$y }
      coord_map = $map
      elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
      next_step = "Run coord-map with a target window or first re-ground the target via app-profile/windows."
    }
    if ($Brief -and -not $jsonOnly) { [Console]::Out.WriteLine("partial coord-anchor reason=$($payload.reason) elapsed_ms=$($payload.elapsed_ms)") }
    else { [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 12)) }
    return 2
  }

  $selected = $map.selected_window
  $targetMatch = if ($tm) { $tm } elseif ($selected.title) { "$($selected.title)" } elseif ($selected.process) { "$($selected.process)" } else { "" }
  $norm = $map.normalized_window_point
  $visibleNorm = $null
  if ($map.visible_window_clip -and $map.visible_window_point -and [int]$map.visible_window_clip.width -gt 0 -and [int]$map.visible_window_clip.height -gt 0) {
    $visibleNorm = [pscustomobject]@{
      x = [Math]::Round(([double]$map.visible_window_point.x / [double]$map.visible_window_clip.width), 6)
      y = [Math]::Round(([double]$map.visible_window_point.y / [double]$map.visible_window_clip.height), 6)
    }
  }

  $restoreByMatch = @("macro","coord-map","--from","normalized","--norm-x","$($norm.x)","--norm-y","$($norm.y)")
  if ($targetMatch) { $restoreByMatch += @("--target-match",$targetMatch) }
  $restoreByHwnd = @("macro","coord-map","--from","normalized","--norm-x","$($norm.x)","--norm-y","$($norm.y)","--target-hwnd","$([int64]$selected.hwnd)")
  $pointPlan = @("macro","point-plan","--x","$($map.screen_point.x)","--y","$($map.screen_point.y)","--radius","$radius","--step","$step")
  if ($targetMatch) { $pointPlan += @("--target-match",$targetMatch) }
  $immediatePointPlanByHwnd = @("macro","point-plan","--x","$($map.screen_point.x)","--y","$($map.screen_point.y)","--target-hwnd","$([int64]$selected.hwnd)","--radius","$radius","--step","$step")

  $risk = if ($map.coordinate_profile) { "$($map.coordinate_profile.coordinate_risk)" } else { "unknown" }
  $safeToReuse = ($map.inside_window -and $map.inside_visible_clip -and $risk -ne "high")
  $anchorIdSource = "$($selected.process)|$($selected.class)|$targetMatch|$($norm.x),$($norm.y)"
  $anchorId = Get-CacheKey -Match $anchorIdSource
  $anchorRecord = [pscustomobject]@{
    ts = (Get-Date).ToString("o")
    anchor_id = $anchorId
    anchor_type = "window_normalized_point"
    target_match = $targetMatch
    target_hwnd_current = [int64]$selected.hwnd
    process = "$($selected.process)"
    class = "$($selected.class)"
    title = "$($selected.title)"
    source_point = [pscustomobject]@{ x=$x; y=$y }
    screen_point = $map.screen_point
    normalized_window_point = $norm
    visible_normalized_point = $visibleNorm
    safe_to_reuse = [bool]$safeToReuse
    coordinate_risk = $risk
    coord_signature = if ($map.coordinate_profile) { "$($map.coordinate_profile.coord_signature)" } else { "" }
    window_rect = $selected.rect
  }
  $reuseHistory = if ($noHistory) {
    [pscustomobject]@{
      schema = "cucp.anchor-reuse-score/v1"
      enabled = $false
      status = "skipped"
      reason = "disabled_by_no_history"
      score = 0
      confidence = "none"
      recorded = $false
    }
  } else {
    _AnchorHistory-Score -Record $anchorRecord -Tolerance $historyTolerance
  }
  if ($recordHistory -and -not $noHistory) {
    $recorded = _AnchorHistory-Append -Record $anchorRecord
    try { $reuseHistory | Add-Member -NotePropertyName recorded -NotePropertyValue ([bool]$recorded) -Force } catch { }
  }
  $sw.Stop()
  $payload = [pscustomobject]@{
    schema = "cucp.coord-anchor/v1"
    status = "ok"
    anchor_id = $anchorId
    anchor_type = "window_normalized_point"
    source_point = [pscustomobject]@{ x=$x; y=$y }
    safe_to_reuse = [bool]$safeToReuse
    coordinate_risk = $risk
    selected_window = $selected
    anchor = [pscustomobject]@{
      target_match = $targetMatch
      target_hwnd_current = [int64]$selected.hwnd
      process = "$($selected.process)"
      class = "$($selected.class)"
      normalized_window_point = $norm
      visible_normalized_point = $visibleNorm
      coord_signature = if ($map.coordinate_profile) { "$($map.coordinate_profile.coord_signature)" } else { "" }
    }
    restore_coord_map_command = @($restoreByMatch)
    restore_coord_map_command_line = _TaskPlan-StepString -Command $restoreByMatch
    immediate_restore_by_hwnd_command = @($restoreByHwnd)
    immediate_point_plan_command = @($pointPlan)
    immediate_point_plan_command_line = _TaskPlan-StepString -Command $pointPlan
    immediate_point_plan_by_hwnd_command = @($immediatePointPlanByHwnd)
    reuse_history = $reuseHistory
    anchor_history_record = if ($recordHistory -and -not $noHistory) { $anchorRecord } else { $null }
    coord_map = $map
    warnings = @($map.warnings)
    elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
    next_step = "Persist anchor.normalized_window_point with target_match; later run restore_coord_map_command, then target-validate or point-plan on its screen_point before live control. Use --record-history after verified reuse to improve reuse_history.score."
  }
  if ($Brief -and -not $jsonOnly) {
    [Console]::Out.WriteLine("ok coord-anchor id=$anchorId risk=$risk safe_to_reuse=$safeToReuse reuse_score=$($reuseHistory.score) reuse_confidence=$($reuseHistory.confidence) norm=($($norm.x),$($norm.y)) elapsed_ms=$($payload.elapsed_ms)")
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 14))
  }
  return 0
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
  $cliOk = $Script:CliPath -and (Test-Path -LiteralPath $Script:CliPath)
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
        if ([string]::IsNullOrWhiteSpace($pri)) { $pri = "unknown" }
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
  $cliOk = $Script:CliPath -and (Test-Path -LiteralPath $Script:CliPath)
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
  #                   [--target-match <s>|--target-hwnd <n>] [--refine uia-safe]
  # 좌표 기반 클릭 (UIA / vision 우회). -AllowLiveControl 필수.
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro click-point requires -AllowLiveControl" }
  $x = [int](_Read-OptValue -Rest $Rest -Name "--x")
  $y = [int](_Read-OptValue -Rest $Rest -Name "--y")
  $btn = _Read-OptValue -Rest $Rest -Name "--button"
  $targetMatch = _Read-OptValue -Rest $Rest -Name "--target-match"
  if (-not $targetMatch) { $targetMatch = _Read-OptValue -Rest $Rest -Name "--match" }
  if (-not $targetMatch) { $targetMatch = _Read-OptValue -Rest $Rest -Name "--window" }
  $targetHwnd = [int](_Read-OptValue -Rest $Rest -Name "--target-hwnd")
  $refine = _Read-OptValue -Rest $Rest -Name "--refine"
  if (-not $refine) { $refine = _Read-OptValue -Rest $Rest -Name "--click-refine" }
  if (_Read-Switch -Rest $Rest -Name "--uia-safe") { $refine = "uia-safe" }
  $clickInset = [int](_Read-OptValue -Rest $Rest -Name "--click-inset")
  $noFastGuard = _Read-Switch -Rest $Rest -Name "--no-fast-guard"
  $noMicroRefine = _Read-Switch -Rest $Rest -Name "--no-micro-refine"
  $noAnchorHistory = _Read-Switch -Rest $Rest -Name "--no-anchor-history"
  $microRefine = (_Read-Switch -Rest $Rest -Name "--micro-refine") -or (_Read-Switch -Rest $Rest -Name "--precision")
  $allowUnrefined = _Read-Switch -Rest $Rest -Name "--allow-unrefined"
  $precisionRadiusRaw = _Read-OptValue -Rest $Rest -Name "--precision-radius"
  if (-not $precisionRadiusRaw) { $precisionRadiusRaw = _Read-OptValue -Rest $Rest -Name "--micro-radius" }
  $precisionStepRaw = _Read-OptValue -Rest $Rest -Name "--precision-step"
  if (-not $precisionStepRaw) { $precisionStepRaw = _Read-OptValue -Rest $Rest -Name "--micro-step" }
  $pointCacheTtlRaw = _Read-OptValue -Rest $Rest -Name "--cache-ttl"
  $pointNoCache = _Read-Switch -Rest $Rest -Name "--no-cache"
  $precisionRadius = 6
  $precisionStep = 2
  $pointCacheTtl = $CacheSeconds
  if ($null -ne $precisionRadiusRaw -and "$precisionRadiusRaw" -ne "") { $precisionRadius = [int]$precisionRadiusRaw }
  if ($null -ne $precisionStepRaw -and "$precisionStepRaw" -ne "") { $precisionStep = [int]$precisionStepRaw }
  if ($null -ne $pointCacheTtlRaw -and "$pointCacheTtlRaw" -ne "") { $pointCacheTtl = [int]$pointCacheTtlRaw }
  if (-not $btn) { $btn = "left" }
  if ($x -le 0 -or $y -le 0) { throw "macro click-point requires --x and --y" }
  if ($clickInset -le 0) { $clickInset = 3 }
  if ($precisionRadius -lt 0) { $precisionRadius = 0 }
  if ($precisionRadius -gt 64) { $precisionRadius = 64 }
  if ($precisionStep -le 0) { $precisionStep = 2 }
  if ($precisionStep -gt 16) { $precisionStep = 16 }
  if ($pointCacheTtl -lt 0) { $pointCacheTtl = 0 }
  if ($pointNoCache) { $pointCacheTtl = 0 }
  $targetGuardSpecified = (($targetHwnd -gt 0) -or $targetMatch)
  $autoMicroRefine = $false
  if (-not $microRefine -and -not $noMicroRefine -and $targetGuardSpecified) {
    $microRefine = $true
    $autoMicroRefine = $true
  }

  $precheck = $null
  $originalX = $x
  $originalY = $y
  $microRefineEvidence = $null
  $anchorReuseEvidence = $null
  if ($targetGuardSpecified -and -not $noFastGuard) {
    $preSw = [System.Diagnostics.Stopwatch]::StartNew()
    $precheck = _Native-HitTestPoint -X $x -Y $y -TargetHwnd $targetHwnd -TargetMatch $targetMatch
    $preSw.Stop()
    $precheck | Add-Member -NotePropertyName elapsed_ms -NotePropertyValue ([int]$preSw.Elapsed.TotalMilliseconds) -Force
    if (-not [bool]$precheck.matched) {
      $payload = [pscustomobject]@{
        schema = "cucp.click-point/v1"
        status = "blocked"
        reason = "fast_guard_mismatch"
        x = $x
        y = $y
        button = $btn
        target_hwnd = $targetHwnd
        target_match = $targetMatch
        precheck = $precheck
      }
      _Trajectory-Append -Kind "click" -Payload @{
        source = "native_click_point"
        x = $x; y = $y; button = $btn
        target_match = $targetMatch
        target_hwnd = $targetHwnd
        exit = 3
        reason = "fast_guard_mismatch"
      }
      if ($Brief) {
        [Console]::Out.WriteLine("blocked click-point @($x,$y) target_mismatch actual='$($precheck.root_title)' process=$($precheck.process_name) reason=$($precheck.match_reason)")
      } else {
        [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 8))
      }
      return 3
    }
  }

  if ($microRefine) {
    $scan = $null
    $microFromCache = $false
    $microCacheAgeMs = 0
    $microCacheKey = $null
    $microPointPayload = $null
    if ($precheck -and $pointCacheTtl -gt 0) {
      $microCacheKey = _PointPlan-CacheKey -X $x -Y $y -Radius $precisionRadius -Step $precisionStep -ClickInset $clickInset -TargetHwnd $targetHwnd -TargetMatch $targetMatch -Precheck $precheck
      $cacheHit = _PointPlan-ReadCache -Key $microCacheKey -MaxAgeSeconds $pointCacheTtl
      if ($cacheHit -and $cacheHit.Json -and $cacheHit.Json.status -eq "ok" -and $cacheHit.Json.recommended_point) {
        $microPointPayload = $cacheHit.Json
        $microFromCache = $true
        $microCacheAgeMs = [int]$cacheHit.AgeMs
      }
    }
    if (-not $microPointPayload) {
      $scanArgs = @("-Action","hit-scan","-X","$x","-Y","$y","-ClickInset","$clickInset","-ScanRadius","$precisionRadius","-ScanStep","$precisionStep")
      if ($targetMatch) { $scanArgs += @("-TargetMatch", $targetMatch) }
      if ($targetHwnd -gt 0) { $scanArgs += @("-TargetHwnd", "$targetHwnd") }
      $scan = Invoke-NativeHelper -ArgList $scanArgs
      if ($scan.Json -and $scan.Json.status -eq "ok" -and $scan.Json.recommended_point) {
        $microPointPayload = [pscustomobject]@{
          schema = "cucp.point-plan/v1"
          status = "ok"
          mode = "coordinate_click"
          source = "click_point_micro_refine"
          x = $x
          y = $y
          radius = $precisionRadius
          step = $precisionStep
          click_inset = $clickInset
          target_hwnd = $targetHwnd
          target_match = $targetMatch
          from_cache = $false
          cache_ttl_seconds = $pointCacheTtl
          cache_key = $microCacheKey
          confidence = "$($scan.Json.recommended_point.confidence)"
          safe_to_act = $true
          mouse_moved = $true
          reason = ""
          precheck = $precheck
          best = $scan.Json.best
          recommended_point = $scan.Json.recommended_point
          recommended_command = $null
          checks = @(
            [pscustomobject]@{ source="win32_fast_guard"; status=$precheck.status; matched=[bool]$precheck.matched; reason="$($precheck.match_reason)"; evidence=$precheck },
            [pscustomobject]@{ source="hit_scan"; status="ok"; reason=""; exit=[int]$scan.ExitCode; elapsed_ms=[int]$scan.ElapsedMs }
          )
          scan = $scan.Json
        }
        if ($microCacheKey -and $pointCacheTtl -gt 0) { _PointPlan-WriteCache -Key $microCacheKey -Payload $microPointPayload }
      }
    }
    if ($microPointPayload -and $microPointPayload.status -eq "ok" -and $microPointPayload.recommended_point) {
      $rp = $microPointPayload.recommended_point
      $rx = [int]$rp.x
      $ry = [int]$rp.y
      $microRefineEvidence = [pscustomobject]@{
        status = "ok"
        original_x = $originalX
        original_y = $originalY
        refined_x = $rx
        refined_y = $ry
        confidence = "$($rp.confidence)"
        point_source = "$($rp.point_source)"
        native_clickable = [bool]$rp.native_clickable
        sample_count = if ($microPointPayload.scan) { [int]$microPointPayload.scan.sample_count } else { 0 }
        candidate_count = if ($microPointPayload.scan) { [int]$microPointPayload.scan.candidate_count } else { 0 }
        from_cache = [bool]$microFromCache
        cache_age_ms = $microCacheAgeMs
        cache_key = $microCacheKey
        elapsed_ms = if ($scan) { [int]$scan.ElapsedMs } else { 0 }
      }
      $x = $rx
      $y = $ry
    } elseif (-not $allowUnrefined) {
      $reason = if ($scan.Json -and $scan.Json.reason) { "$($scan.Json.reason)" } else { "micro_refine_failed" }
      $payload = [pscustomobject]@{
        schema = "cucp.click-point/v1"
        status = "blocked"
        reason = "micro_refine_failed"
        detail = $reason
        x = $originalX
        y = $originalY
        button = $btn
        target_hwnd = $targetHwnd
        target_match = $targetMatch
        precheck = $precheck
        scan = if ($scan.Json) { $scan.Json } else { $null }
      }
      _Trajectory-Append -Kind "click" -Payload @{
        source = "native_click_point"
        x = $originalX; y = $originalY; button = $btn
        target_match = $targetMatch
        target_hwnd = $targetHwnd
        refine = "micro"
        exit = 3
        reason = "micro_refine_failed"
      }
      if ($Brief) {
        [Console]::Out.WriteLine("blocked click-point @($originalX,$originalY) micro_refine_failed reason=$reason")
      } else {
        [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 10))
      }
      return 3
    } else {
      $microRefineEvidence = [pscustomobject]@{
        status = "partial"
        reason = if ($scan.Json -and $scan.Json.reason) { "$($scan.Json.reason)" } else { "micro_refine_failed" }
        allowed_unrefined = $true
      }
    }
  }

  if ($targetGuardSpecified -and -not $noAnchorHistory) {
    try {
      $coordProfile = _Build-CoordProfile -HasPoint $true -X $x -Y $y -TargetHwnd ([int64]$targetHwnd) -TargetMatch $targetMatch
      if ($coordProfile -and $coordProfile.status -eq "ok" -and $coordProfile.target_window -and $coordProfile.point_window_relative) {
        $norm = [pscustomobject]@{
          x = [double]$coordProfile.point_window_relative.norm_x
          y = [double]$coordProfile.point_window_relative.norm_y
        }
        $targetWin = $coordProfile.target_window
        $risk = "$($coordProfile.coordinate_risk)"
        $safeToReuse = ([bool]$coordProfile.point_inside_target_window -and $risk -ne "high")
        $anchorIdSource = "$($targetWin.process)|$($targetWin.class)|$targetMatch|$([Math]::Round($norm.x,4)),$([Math]::Round($norm.y,4))"
        $anchorRecord = [pscustomobject]@{
          ts = (Get-Date).ToString("o")
          anchor_id = Get-CacheKey -Match $anchorIdSource
          anchor_type = "click_point_live_route"
          target_match = $targetMatch
          target_hwnd_current = [int64]$targetWin.hwnd
          process = "$($targetWin.process)"
          class = "$($targetWin.class)"
          title = "$($targetWin.title)"
          source_point = [pscustomobject]@{ x=$originalX; y=$originalY }
          screen_point = [pscustomobject]@{ x=$x; y=$y }
          normalized_window_point = $norm
          visible_normalized_point = $norm
          safe_to_reuse = [bool]$safeToReuse
          coordinate_risk = $risk
          coord_signature = "$($coordProfile.coord_signature)"
          window_rect = $targetWin.rect
        }
        $reuse = _AnchorHistory-Score -Record $anchorRecord
        $anchorReuseEvidence = [pscustomobject]@{
          status = "ok"
          auto_record_after_success = $true
          record = $anchorRecord
          reuse_history = $reuse
          coordinate_profile = $coordProfile
        }
      }
    } catch {
      $anchorReuseEvidence = [pscustomobject]@{
        status = "partial"
        reason = "anchor_reuse_score_failed"
        detail = $_.Exception.Message
      }
    }
  } elseif ($targetGuardSpecified -and $noAnchorHistory) {
    $anchorReuseEvidence = [pscustomobject]@{
      status = "skipped"
      reason = "disabled_by_no_anchor_history"
    }
  }

  $argList = @("-Action","click","-X","$x","-Y","$y","-Button",$btn)
  if ($targetMatch) { $argList += @("-TargetMatch", $targetMatch) }
  if ($targetHwnd -gt 0) { $argList += @("-TargetHwnd", "$targetHwnd") }
  if ($refine) { $argList += @("-ClickRefine", $refine) }
  if ($clickInset -gt 0) { $argList += @("-ClickInset", "$clickInset") }
  $r = Invoke-NativeHelper -ArgList $argList
  if ($r.Json -and $r.Json.status -eq "ok" -and $anchorReuseEvidence -and $anchorReuseEvidence.status -eq "ok" -and $anchorReuseEvidence.record) {
    $recorded = _AnchorHistory-Append -Record $anchorReuseEvidence.record
    try { $anchorReuseEvidence.reuse_history | Add-Member -NotePropertyName recorded -NotePropertyValue ([bool]$recorded) -Force } catch { }
  }
  _Trajectory-Append -Kind "click" -Payload @{
    source = "native_click_point"
    x = $x; y = $y; button = $btn
    target_match = $targetMatch
    target_hwnd = $targetHwnd
    refine = $refine
    micro_refine = $microRefineEvidence
    auto_micro_refine = [bool]$autoMicroRefine
    anchor_reuse = if ($anchorReuseEvidence) { $anchorReuseEvidence.reuse_history } else { $null }
    exit = $r.ExitCode
  }
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      $guardSuffix = ""
      if ($precheck) { $guardSuffix = " fast_guard=$($precheck.match_reason)" }
      $refineSuffix = ""
      if ($r.Json.refined_by) { $refineSuffix = " refined=($($r.Json.x),$($r.Json.y)) source=$($r.Json.refined_point_source)" }
      $microSuffix = ""
      if ($microRefineEvidence -and $microRefineEvidence.status -eq "ok") { $microSuffix = " micro_refine=($originalX,$originalY)->($($microRefineEvidence.refined_x),$($microRefineEvidence.refined_y)) confidence=$($microRefineEvidence.confidence)" }
      [Console]::Out.WriteLine("ok click-point @($x,$y) button=$btn elapsed_ms=$($r.ElapsedMs)$guardSuffix$microSuffix$refineSuffix")
    } else {
      [Console]::Out.WriteLine("err click-point exit=$($r.ExitCode)")
    }
  } else {
    if ($r.Json) {
      $out = $r.Json
      try { $out | Add-Member -NotePropertyName schema -NotePropertyValue "cucp.click-point/v1" -Force } catch { }
      try { $out | Add-Member -NotePropertyName wrapper_action -NotePropertyValue "click-point" -Force } catch { }
      try { $out | Add-Member -NotePropertyName original_point -NotePropertyValue ([pscustomobject]@{ x=$originalX; y=$originalY }) -Force } catch { }
      try { $out | Add-Member -NotePropertyName precheck -NotePropertyValue $precheck -Force } catch { }
      try { $out | Add-Member -NotePropertyName micro_refine -NotePropertyValue $microRefineEvidence -Force } catch { }
      try { $out | Add-Member -NotePropertyName auto_micro_refine -NotePropertyValue ([bool]$autoMicroRefine) -Force } catch { }
      try { $out | Add-Member -NotePropertyName anchor_reuse -NotePropertyValue $anchorReuseEvidence -Force } catch { }
      [Console]::Out.WriteLine(($out | ConvertTo-Json -Depth 12))
    } elseif ($r.Raw) { [Console]::Out.Write($r.Raw) }
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
  $clickInset = [int](_Read-OptValue -Rest $Rest -Name "--click-inset")
  $fast = _Read-Switch -Rest $Rest -Name "--fast"
  $noUia = _Read-Switch -Rest $Rest -Name "--no-uia"
  if ($x -le 0 -or $y -le 0) { throw "macro hit-test requires --x and --y" }
  if ($clickInset -le 0) { $clickInset = 3 }

  if ($fast) {
    $swFast = [System.Diagnostics.Stopwatch]::StartNew()
    $fastPayload = _Native-HitTestPoint -X $x -Y $y -TargetHwnd $th -TargetMatch $tm
    $swFast.Stop()
    $fastPayload | Add-Member -NotePropertyName elapsed_ms -NotePropertyValue ([int]$swFast.Elapsed.TotalMilliseconds) -Force
    $exitCode = 0
    if ($fastPayload.status -eq "partial") { $exitCode = 2 }
    if ($Brief) {
      $tag = "ok"
      if ($fastPayload.status -eq "partial") { $tag = "partial" }
      [Console]::Out.WriteLine("$tag hit-test @($x,$y) hwnd=$($fastPayload.root_hwnd) title='$($fastPayload.root_title)' process=$($fastPayload.process_name) matched=$($fastPayload.matched) reason=$($fastPayload.match_reason) uia=skipped source=wrapper_fast elapsed_ms=$($fastPayload.elapsed_ms)")
    } else {
      [Console]::Out.WriteLine(($fastPayload | ConvertTo-Json -Depth 8))
    }
    return $exitCode
  }

  $argList = @("-Action","hit-test","-X","$x","-Y","$y")
  if ($tm) { $argList += @("-TargetMatch", $tm) }
  if ($th -gt 0) { $argList += @("-TargetHwnd", "$th") }
  $argList += @("-ClickInset", "$clickInset")
  if ($fast -or $noUia) { $argList += "-SkipUia" }
  $r = Invoke-NativeHelper -ArgList $argList
  $exitCode = [int]$r.ExitCode

  if ($Brief) {
    if ($r.Json) {
      $tag = "ok"
      if ($r.Json.status -eq "partial") { $tag = "partial" }
      $uiaSuffix = ""
      if ($r.Json.uia_point) {
        $uiaSuffix = " uia_refine=($($r.Json.uia_point.refined_x),$($r.Json.uia_point.refined_y)) role='$($r.Json.uia_point.role)' score=$($r.Json.uia_point.score) source=$($r.Json.uia_point.point_source)"
      } elseif ($r.Json.uia_skipped) {
        $uiaSuffix = " uia=skipped"
      }
      [Console]::Out.WriteLine("$tag hit-test @($x,$y) hwnd=$($r.Json.root_hwnd) title='$($r.Json.root_title)' process=$($r.Json.process_name) matched=$($r.Json.matched) reason=$($r.Json.match_reason)$uiaSuffix")
    } else {
      [Console]::Out.WriteLine("err hit-test @($x,$y) helper_failed exit=$exitCode")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $exitCode
}

function Invoke-MacroHitTestBatch {
  param([string[]]$Rest)
  $pointSpecs = New-Object System.Collections.ArrayList
  $pointsRaw = _Read-OptValue -Rest $Rest -Name "--points"
  foreach ($p in @(_Read-AllOptValues -Rest $Rest -Name "--point")) { [void]$pointSpecs.Add($p) }
  if ($pointsRaw) {
    foreach ($p in @($pointsRaw -split ';')) {
      if ("$p".Trim()) { [void]$pointSpecs.Add($p) }
    }
  }
  $tm = _Read-OptValue -Rest $Rest -Name "--target-match"
  $th = [int](_Read-OptValue -Rest $Rest -Name "--target-hwnd")
  $maxPoints = [int](_Read-OptValue -Rest $Rest -Name "--max-points")
  if ($maxPoints -le 0) { $maxPoints = 200 }
  if ($pointSpecs.Count -eq 0) { throw "macro hit-test-batch requires --point `"x,y`" or --points `"x,y;x,y`"" }
  if ($pointSpecs.Count -gt $maxPoints) { throw "macro hit-test-batch point count exceeds --max-points ($maxPoints)" }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $results = New-Object System.Collections.ArrayList
  $errors = New-Object System.Collections.ArrayList
  $index = 0
  foreach ($spec in @($pointSpecs)) {
    $index++
    $rawSpec = "$spec"
    if ($rawSpec -notmatch '^\s*(-?\d+)\s*,\s*(-?\d+)\s*$') {
      [void]$errors.Add([pscustomobject]@{
        index = $index
        point = $rawSpec
        code = "bad_point_spec"
        message = "point must be x,y"
      })
      continue
    }
    $x = [int]$Matches[1]
    $y = [int]$Matches[2]
    if ($x -le 0 -or $y -le 0) {
      [void]$errors.Add([pscustomobject]@{
        index = $index
        point = $rawSpec
        code = "invalid_coords"
        message = "x and y must be positive"
      })
      continue
    }
    $hit = _Native-HitTestPoint -X $x -Y $y -TargetHwnd $th -TargetMatch $tm
    $hit | Add-Member -NotePropertyName index -NotePropertyValue $index -Force
    [void]$results.Add($hit)
  }
  $sw.Stop()

  $matchedCount = @($results | Where-Object { $_.matched }).Count
  $partialCount = @($results | Where-Object { $_.status -ne "ok" }).Count
  $safeToAct = ($results.Count -gt 0 -and $errors.Count -eq 0 -and $partialCount -eq 0)
  $status = "ok"
  if (-not $safeToAct) { $status = "partial" }
  $payload = [pscustomobject]@{
    schema = "cucp.hit-test-batch/v1"
    status = $status
    source = "wrapper_win32_fast"
    uia_skipped = $true
    target_hwnd = $th
    target_match = $tm
    point_count = $pointSpecs.Count
    result_count = $results.Count
    matched_count = $matchedCount
    partial_count = $partialCount
    error_count = $errors.Count
    safe_to_act = [bool]$safeToAct
    elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
    results = @($results)
    errors = @($errors)
  }

  if ($Brief) {
    [Console]::Out.WriteLine("$status hit-test-batch points=$($pointSpecs.Count) matched=$matchedCount partial=$partialCount errors=$($errors.Count) elapsed_ms=$($payload.elapsed_ms)")
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 10))
  }
  if ($status -eq "ok") { return 0 }
  return 2
}

function Invoke-MacroHitScan {
  param([string[]]$Rest)
  $x = [int](_Read-OptValue -Rest $Rest -Name "--x")
  $y = [int](_Read-OptValue -Rest $Rest -Name "--y")
  $tm = _Read-OptValue -Rest $Rest -Name "--target-match"
  $th = [int](_Read-OptValue -Rest $Rest -Name "--target-hwnd")
  $clickInset = [int](_Read-OptValue -Rest $Rest -Name "--click-inset")
  $radiusRaw = _Read-OptValue -Rest $Rest -Name "--radius"
  $stepRaw = _Read-OptValue -Rest $Rest -Name "--step"
  $radius = 0
  $step = 6
  if ($null -ne $radiusRaw -and "$radiusRaw" -ne "") { $radius = [int]$radiusRaw }
  if ($null -ne $stepRaw -and "$stepRaw" -ne "") { $step = [int]$stepRaw }
  if ($x -le 0 -or $y -le 0) { throw "macro hit-scan requires --x and --y" }
  if ($clickInset -le 0) { $clickInset = 3 }
  if ($radius -lt 0) { $radius = 0 }
  if ($step -le 0) { $step = 6 }

  $argList = @("-Action","hit-scan","-X","$x","-Y","$y","-ClickInset","$clickInset","-ScanRadius","$radius","-ScanStep","$step")
  if ($tm) { $argList += @("-TargetMatch", $tm) }
  if ($th -gt 0) { $argList += @("-TargetHwnd", "$th") }
  $r = Invoke-NativeHelper -ArgList $argList
  $exitCode = [int]$r.ExitCode

  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      $best = $r.Json.best
      $pt = $r.Json.recommended_point
      [Console]::Out.WriteLine("ok hit-scan @($x,$y) best=($($pt.x),$($pt.y)) confidence=$($pt.confidence) role='$($best.role)' score=$($best.final_score) support=$($best.support) source=$($pt.point_source) samples=$($r.Json.sample_count)")
    } elseif ($r.Json) {
      $reason = if ($r.Json.reason) { "$($r.Json.reason)" } else { "no_candidate" }
      [Console]::Out.WriteLine("partial hit-scan @($x,$y) reason=$reason samples=$($r.Json.sample_count) matched=$($r.Json.target_matched_samples)")
    } else {
      [Console]::Out.WriteLine("err hit-scan @($x,$y) helper_failed exit=$exitCode")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $exitCode
}

function _Set-ObjectProperty {
  param($Object, [string]$Name, $Value)
  if (-not $Object) { return }
  if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
  else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function _PointPlan-CacheKey {
  param(
    [int]$X,
    [int]$Y,
    [int]$Radius,
    [int]$Step,
    [int]$ClickInset,
    [int]$TargetHwnd,
    [string]$TargetMatch,
    $Precheck,
    [string]$CoordSignature
  )
  $rootHwnd = if ($Precheck) { [int64]$Precheck.root_hwnd } else { 0 }
  $rootTitle = if ($Precheck) { "$($Precheck.root_title)" } else { "" }
  $proc = if ($Precheck) { "$($Precheck.process_name)" } else { "" }
  $base = "point-plan|x=$X|y=$Y|r=$Radius|s=$Step|inset=$ClickInset|th=$TargetHwnd|tm=$TargetMatch|root=$rootHwnd|title=$rootTitle|proc=$proc|coord=$CoordSignature"
  return (Get-CacheKey -Match $base)
}

function _PointPlan-CachePath {
  param([string]$Key)
  return (Join-Path $Script:CacheDir "point-plan-$Key.json")
}

function _PointPlan-ReadCache {
  param([string]$Key, [int]$MaxAgeSeconds)
  if (-not $Key -or $MaxAgeSeconds -le 0) { return $null }
  $path = _PointPlan-CachePath -Key $Key
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  $info = Get-Item -LiteralPath $path
  $age = (Get-Date) - $info.LastWriteTime
  if ($age.TotalSeconds -gt $MaxAgeSeconds) { return $null }
  try {
    $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    return [pscustomobject]@{
      Json = $json
      Path = $path
      AgeMs = [int]$age.TotalMilliseconds
    }
  } catch { return $null }
}

function _PointPlan-WriteCache {
  param([string]$Key, $Payload)
  if (-not $Key -or -not $Payload) { return }
  $path = _PointPlan-CachePath -Key $Key
  try {
    ($Payload | ConvertTo-Json -Depth 14) | Set-Content -LiteralPath $path -Encoding UTF8
  } catch { }
}

function Invoke-MacroPointPlan {
  param([string[]]$Rest)
  $x = [int](_Read-OptValue -Rest $Rest -Name "--x")
  $y = [int](_Read-OptValue -Rest $Rest -Name "--y")
  $tm = _Read-OptValue -Rest $Rest -Name "--target-match"
  if (-not $tm) { $tm = _Read-OptValue -Rest $Rest -Name "--match" }
  if (-not $tm) { $tm = _Read-OptValue -Rest $Rest -Name "--window" }
  $th = [int](_Read-OptValue -Rest $Rest -Name "--target-hwnd")
  $clickInset = [int](_Read-OptValue -Rest $Rest -Name "--click-inset")
  $radiusRaw = _Read-OptValue -Rest $Rest -Name "--radius"
  $stepRaw = _Read-OptValue -Rest $Rest -Name "--step"
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  $noCache = _Read-Switch -Rest $Rest -Name "--no-cache"
  $cacheTtlRaw = _Read-OptValue -Rest $Rest -Name "--cache-ttl"
  $radius = 6
  $step = 2
  $cacheTtl = $CacheSeconds
  if ($null -ne $radiusRaw -and "$radiusRaw" -ne "") { $radius = [int]$radiusRaw }
  if ($null -ne $stepRaw -and "$stepRaw" -ne "") { $step = [int]$stepRaw }
  if ($null -ne $cacheTtlRaw -and "$cacheTtlRaw" -ne "") { $cacheTtl = [int]$cacheTtlRaw }
  if ($x -le 0 -or $y -le 0) { throw "macro point-plan requires --x and --y" }
  if ($clickInset -le 0) { $clickInset = 2 }
  if ($radius -lt 0) { $radius = 0 }
  if ($radius -gt 64) { $radius = 64 }
  if ($step -le 0) { $step = 2 }
  if ($step -gt 16) { $step = 16 }
  if ($cacheTtl -lt 0) { $cacheTtl = 0 }
  if ($noCache) { $cacheTtl = 0 }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $checks = New-Object System.Collections.ArrayList
  $precheck = $null
  $coordProfile = $null
  try {
    $precheck = _Native-HitTestPoint -X $x -Y $y -TargetHwnd $th -TargetMatch $tm
    [void]$checks.Add([pscustomobject]@{
      source = "win32_fast_guard"
      status = $precheck.status
      matched = [bool]$precheck.matched
      reason = "$($precheck.match_reason)"
      evidence = $precheck
    })
  } catch {
    [void]$checks.Add([pscustomobject]@{
      source = "win32_fast_guard"
      status = "error"
      matched = $false
      reason = "$($_.Exception.Message)"
    })
  }
  try {
    $coordProfile = _Build-CoordProfile -HasPoint $true -X $x -Y $y -TargetHwnd ([int64]$th) -TargetMatch $tm
    [void]$checks.Add([pscustomobject]@{
      source = "coord_profile"
      status = $coordProfile.status
      risk = $coordProfile.coordinate_risk
      warnings = @($coordProfile.warnings)
      elapsed_ms = [int]$coordProfile.elapsed_ms
    })
  } catch {
    [void]$checks.Add([pscustomobject]@{
      source = "coord_profile"
      status = "error"
      reason = "$($_.Exception.Message)"
    })
  }

  $targetSpecified = (($th -gt 0) -or $tm)
  $guardMatched = ($precheck -and [bool]$precheck.matched)
  $cacheKey = $null
  if ($precheck -and (-not $targetSpecified -or $guardMatched)) {
    $coordSignature = if ($coordProfile -and $coordProfile.coord_signature) { "$($coordProfile.coord_signature)" } else { "" }
    $cacheKey = _PointPlan-CacheKey -X $x -Y $y -Radius $radius -Step $step -ClickInset $clickInset -TargetHwnd $th -TargetMatch $tm -Precheck $precheck -CoordSignature $coordSignature
    $cacheHit = _PointPlan-ReadCache -Key $cacheKey -MaxAgeSeconds $cacheTtl
    if ($cacheHit -and $cacheHit.Json) {
      $sw.Stop()
      $payload = $cacheHit.Json
      $cacheChecks = New-Object System.Collections.ArrayList
      foreach ($c in @($checks)) { [void]$cacheChecks.Add($c) }
      [void]$cacheChecks.Add([pscustomobject]@{
        source = "point_plan_cache"
        status = "hit"
        age_ms = [int]$cacheHit.AgeMs
        path = "$($cacheHit.Path)"
      })
      _Set-ObjectProperty -Object $payload -Name "from_cache" -Value $true
      _Set-ObjectProperty -Object $payload -Name "cache_age_ms" -Value ([int]$cacheHit.AgeMs)
      _Set-ObjectProperty -Object $payload -Name "cache_ttl_seconds" -Value $cacheTtl
      _Set-ObjectProperty -Object $payload -Name "cache_key" -Value $cacheKey
      _Set-ObjectProperty -Object $payload -Name "elapsed_ms" -Value ([int]$sw.Elapsed.TotalMilliseconds)
      _Set-ObjectProperty -Object $payload -Name "precheck" -Value $precheck
      _Set-ObjectProperty -Object $payload -Name "coordinate_profile" -Value $coordProfile
      _Set-ObjectProperty -Object $payload -Name "checks" -Value @($cacheChecks)
      if ($Brief -and -not $jsonOnly) {
        if ($payload.status -eq "ok" -and $payload.recommended_point) {
          [Console]::Out.WriteLine("ok point-plan @($x,$y) cached recommended=($($payload.recommended_point.x),$($payload.recommended_point.y)) confidence=$($payload.confidence) age_ms=$($cacheHit.AgeMs) elapsed_ms=$($payload.elapsed_ms)")
        } else {
          [Console]::Out.WriteLine("partial point-plan @($x,$y) cached reason=$($payload.reason) age_ms=$($cacheHit.AgeMs) elapsed_ms=$($payload.elapsed_ms)")
        }
      } else {
        [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 12))
      }
      if ($payload.status -eq "ok") { return 0 }
      return 2
    }
  }
  $scan = $null
  if (-not $targetSpecified -or $guardMatched) {
    $scanArgs = @("-Action","hit-scan","-X","$x","-Y","$y","-ClickInset","$clickInset","-ScanRadius","$radius","-ScanStep","$step")
    if ($tm) { $scanArgs += @("-TargetMatch", $tm) }
    if ($th -gt 0) { $scanArgs += @("-TargetHwnd", "$th") }
    $scan = Invoke-NativeHelper -ArgList $scanArgs
    $scanStatus = if ($scan.Json) { "$($scan.Json.status)" } else { "error" }
    $scanReason = if ($scan.Json -and $scan.Json.reason) { "$($scan.Json.reason)" } else { "" }
    [void]$checks.Add([pscustomobject]@{
      source = "hit_scan"
      status = $scanStatus
      reason = $scanReason
      exit = [int]$scan.ExitCode
      elapsed_ms = [int]$scan.ElapsedMs
    })
  }

  $best = $null
  $recommendedPoint = $null
  $recommendedCommand = $null
  $confidence = "low"
  $status = "partial"
  $reason = ""

  if ($targetSpecified -and -not $guardMatched) {
    $reason = "fast_guard_mismatch"
  } elseif ($scan -and $scan.Json -and $scan.Json.status -eq "ok" -and $scan.Json.recommended_point) {
    $best = $scan.Json.best
    $rp = $scan.Json.recommended_point
    $confidence = "$($rp.confidence)"
    $recommendedPoint = [pscustomobject]@{
      x = [int]$rp.x
      y = [int]$rp.y
      confidence = $confidence
      point_source = "$($rp.point_source)"
      native_clickable = [bool]$rp.native_clickable
    }
    $cmd = @(
      "macro","click-point",
      "--x","$($recommendedPoint.x)",
      "--y","$($recommendedPoint.y)",
      "--refine","uia-safe",
      "--click-inset","$clickInset",
      "--micro-refine",
      "--precision-radius","$radius",
      "--precision-step","$step"
    )
    if ($tm) { $cmd += @("--target-match",$tm) }
    if ($th -gt 0) { $cmd += @("--target-hwnd","$th") }
    $recommendedCommand = [object[]]@($cmd)
    $status = "ok"
  } else {
    $reason = if ($scan -and $scan.Json -and $scan.Json.reason) { "$($scan.Json.reason)" } else { "no_scan_candidate" }
  }

  $sw.Stop()
  $payload = [pscustomobject]@{
    schema = "cucp.point-plan/v1"
    status = $status
    mode = "coordinate_click"
    source = "win32_fast_guard+hit_scan"
    x = $x
    y = $y
    radius = $radius
    step = $step
    click_inset = $clickInset
    target_hwnd = $th
    target_match = $tm
    elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
    from_cache = $false
    cache_ttl_seconds = $cacheTtl
    cache_key = $cacheKey
    confidence = $confidence
    safe_to_act = ($status -eq "ok")
    mouse_moved = $false
    reason = $reason
    precheck = $precheck
    coordinate_profile = $coordProfile
    best = $best
    recommended_point = $recommendedPoint
    recommended_command = $recommendedCommand
    checks = @($checks)
    scan = if ($scan -and $scan.Json) { $scan.Json } else { $null }
    next_step = if ($status -eq "ok") { "Run recommended_command with -AllowLiveControl only after user authorization; it will re-run micro-refine before the live click." } else { "Try a narrower --target-match/--target-hwnd, a slightly larger --radius, or prefer smart-plan/CDP for web UI." }
  }
  if ($cacheKey -and $cacheTtl -gt 0 -and (-not $targetSpecified -or $guardMatched)) {
    _PointPlan-WriteCache -Key $cacheKey -Payload $payload
  }

  if ($Brief -and -not $jsonOnly) {
    if ($status -eq "ok") {
      [Console]::Out.WriteLine("ok point-plan @($x,$y) recommended=($($recommendedPoint.x),$($recommendedPoint.y)) confidence=$confidence source=$($recommendedPoint.point_source) samples=$($scan.Json.sample_count) elapsed_ms=$($payload.elapsed_ms)")
    } else {
      [Console]::Out.WriteLine("partial point-plan @($x,$y) reason=$reason elapsed_ms=$($payload.elapsed_ms)")
    }
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 12))
  }
  if ($status -eq "ok") { return 0 }
  return 2
}

function _TargetValidate-ConfidenceRank {
  param([string]$Confidence)
  switch ("$Confidence".ToLowerInvariant()) {
    "high" { return 3 }
    "medium" { return 2 }
    "low" { return 1 }
    default { return 0 }
  }
}

function _TargetValidate-SizeClass {
  param($Rect, [int]$Area)
  $width = 0
  $height = 0
  if ($Rect) {
    try { $width = [int]$Rect.width } catch { $width = 0 }
    try { $height = [int]$Rect.height } catch { $height = 0 }
  }
  if ($Area -le 0 -and $width -gt 0 -and $height -gt 0) { $Area = $width * $height }
  if ($width -le 0 -or $height -le 0 -or $Area -le 0) { return "unknown" }
  if ($width -le 20 -or $height -le 20 -or $Area -le 900) { return "tiny" }
  if ($width -le 44 -or $height -le 32 -or $Area -le 2200) { return "small" }
  if ($width -le 140 -and $height -le 100) { return "medium" }
  return "large"
}

function _TargetValidate-PointEdgeDistance {
  param($Point, $Rect)
  if (-not $Point -or -not $Rect) { return $null }
  $x = [int]$Point.x
  $y = [int]$Point.y
  $rx = [int]$Rect.x
  $ry = [int]$Rect.y
  $rw = [int]$Rect.width
  $rh = [int]$Rect.height
  if ($rw -le 0 -or $rh -le 0) { return $null }
  $right = $rx + $rw
  $bottom = $ry + $rh
  return [pscustomobject]@{
    left = [int]($x - $rx)
    top = [int]($y - $ry)
    right = [int]($right - $x - 1)
    bottom = [int]($bottom - $y - 1)
    min = [int]([Math]::Min([Math]::Min($x - $rx, $y - $ry), [Math]::Min($right - $x - 1, $bottom - $y - 1)))
  }
}

function _TargetValidate-InvokePointPlanJson {
  param([string[]]$PointPlanArgs)
  $args = @("-Quiet","macro","point-plan") + @($PointPlanArgs) + @("--json-only")
  $rawLines = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args 2>&1
  $exitCode = $LASTEXITCODE
  $raw = (($rawLines | ForEach-Object { $_.ToString() }) -join "`n")
  $obj = $null
  try { $obj = $raw | ConvertFrom-Json -ErrorAction Stop } catch { }
  return [pscustomobject]@{ exit=[int]$exitCode; raw=$raw; json=$obj }
}

function Invoke-MacroTargetValidate {
  param([string[]]$Rest)
  $x = [int](_Read-OptValue -Rest $Rest -Name "--x")
  $y = [int](_Read-OptValue -Rest $Rest -Name "--y")
  $tm = _Read-OptValue -Rest $Rest -Name "--target-match"
  if (-not $tm) { $tm = _Read-OptValue -Rest $Rest -Name "--match" }
  if (-not $tm) { $tm = _Read-OptValue -Rest $Rest -Name "--window" }
  $th = [int](_Read-OptValue -Rest $Rest -Name "--target-hwnd")
  $clickInset = [int](_Read-OptValue -Rest $Rest -Name "--click-inset")
  $radiusRaw = _Read-OptValue -Rest $Rest -Name "--radius"
  $stepRaw = _Read-OptValue -Rest $Rest -Name "--step"
  $cacheTtlRaw = _Read-OptValue -Rest $Rest -Name "--cache-ttl"
  $minConfidence = _Read-OptValue -Rest $Rest -Name "--min-confidence"
  $allowLargeSurface = _Read-Switch -Rest $Rest -Name "--allow-large-surface"
  $noCache = _Read-Switch -Rest $Rest -Name "--no-cache"
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  $radius = 6
  $step = 2
  $cacheTtl = $CacheSeconds
  if ($null -ne $radiusRaw -and "$radiusRaw" -ne "") { $radius = [int]$radiusRaw }
  if ($null -ne $stepRaw -and "$stepRaw" -ne "") { $step = [int]$stepRaw }
  if ($null -ne $cacheTtlRaw -and "$cacheTtlRaw" -ne "") { $cacheTtl = [int]$cacheTtlRaw }
  if (-not $minConfidence) { $minConfidence = "medium" }
  $minConfidence = "$minConfidence".ToLowerInvariant()
  if (@("low","medium","high") -notcontains $minConfidence) { throw "macro target-validate --min-confidence must be low, medium, or high" }
  if ($x -le 0 -or $y -le 0) { throw "macro target-validate requires --x and --y" }
  if ($clickInset -le 0) { $clickInset = 2 }
  if ($radius -lt 0) { $radius = 0 }
  if ($radius -gt 64) { $radius = 64 }
  if ($step -le 0) { $step = 2 }
  if ($step -gt 16) { $step = 16 }
  if ($cacheTtl -lt 0) { $cacheTtl = 0 }
  if ($noCache) { $cacheTtl = 0 }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $planArgs = @("--x","$x","--y","$y","--radius","$radius","--step","$step","--click-inset","$clickInset","--cache-ttl","$cacheTtl")
  if ($tm) { $planArgs += @("--target-match",$tm) }
  if ($th -gt 0) { $planArgs += @("--target-hwnd","$th") }
  if ($noCache) { $planArgs += "--no-cache" }
  $planResult = _TargetValidate-InvokePointPlanJson -PointPlanArgs $planArgs
  $plan = $planResult.json

  $warnings = New-Object System.Collections.ArrayList
  $errors = New-Object System.Collections.ArrayList
  if (-not $plan) {
    $sw.Stop()
    $payload = [pscustomobject]@{
      schema = "cucp.target-validate/v1"
      status = "error"
      reason = "point_plan_unparseable"
      x = $x
      y = $y
      safe_to_click = $false
      point_plan_exit = [int]$planResult.exit
      point_plan_raw = $planResult.raw
      elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
      next_step = "Re-run point-plan directly, then re-ground the target window before live control."
    }
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 8))
    return 1
  }

  $targetSpecified = (($th -gt 0) -or $tm)
  if (-not $targetSpecified) { [void]$warnings.Add("no_target_guard_specified") }
  $pointPlanOk = ($plan.status -eq "ok" -and [bool]$plan.safe_to_act -and $plan.recommended_point -and $plan.recommended_command)
  $guardMatched = $false
  try { $guardMatched = [bool]$plan.precheck.matched } catch { $guardMatched = $false }
  if (-not $guardMatched) { [void]$warnings.Add("target_guard_not_matched") }
  $coordinateRisk = "unknown"
  try { if ($plan.coordinate_profile.coordinate_risk) { $coordinateRisk = "$($plan.coordinate_profile.coordinate_risk)" } } catch { }
  if ($coordinateRisk -eq "high") { [void]$warnings.Add("coordinate_profile_high_risk") }
  foreach ($cw in @($plan.coordinate_profile.warnings)) {
    if ($cw -and (@($warnings) -notcontains "$cw")) { [void]$warnings.Add("$cw") }
  }

  $confidence = if ($plan.confidence) { "$($plan.confidence)".ToLowerInvariant() } else { "low" }
  $confidenceOk = ((_TargetValidate-ConfidenceRank -Confidence $confidence) -ge (_TargetValidate-ConfidenceRank -Confidence $minConfidence))
  if (-not $confidenceOk) { [void]$warnings.Add("confidence_below_minimum") }

  $best = $plan.best
  $match = if ($best -and $best.match) { $best.match } else { $null }
  $rect = if ($match -and $match.rect) { $match.rect } else { $null }
  $area = 0
  try { $area = [int]$best.area } catch { $area = 0 }
  if ($area -le 0) { try { $area = [int]$match.area } catch { $area = 0 } }
  $targetSizeClass = _TargetValidate-SizeClass -Rect $rect -Area $area
  $targetWidth = 0
  $targetHeight = 0
  if ($rect) {
    try { $targetWidth = [int]$rect.width } catch { $targetWidth = 0 }
    try { $targetHeight = [int]$rect.height } catch { $targetHeight = 0 }
  }
  $support = 0
  try { $support = [int]$best.support } catch { $support = 0 }
  $nativeClickable = $false
  try { $nativeClickable = [bool]$plan.recommended_point.native_clickable } catch { $nativeClickable = $false }
  $pointSource = ""
  try { $pointSource = "$($plan.recommended_point.point_source)" } catch { }
  $role = ""
  try { $role = "$($best.role)" } catch { }
  $pattern = ""
  try { $pattern = "$($best.pattern)" } catch { }
  $edgeDistance = _TargetValidate-PointEdgeDistance -Point $plan.recommended_point -Rect $rect
  $nearElementEdge = $false
  if ($edgeDistance -and [int]$edgeDistance.min -ge 0 -and [int]$edgeDistance.min -lt $clickInset) {
    $nearElementEdge = $true
    [void]$warnings.Add("recommended_point_near_element_edge")
  }
  $recommendedInsideRect = $true
  if ($edgeDistance -and [int]$edgeDistance.min -lt 0) {
    $recommendedInsideRect = $false
    [void]$warnings.Add("recommended_point_outside_element_rect")
  }

  $tinyTarget = ($targetSizeClass -eq "tiny")
  $smallTarget = ($targetSizeClass -eq "tiny" -or $targetSizeClass -eq "small")
  $tinyTargetOk = $true
  if ($tinyTarget) {
    $tinyTargetOk = ($nativeClickable -or $support -ge 2 -or ((_TargetValidate-ConfidenceRank -Confidence $confidence) -ge 3))
    if (-not $tinyTargetOk) { [void]$warnings.Add("tiny_target_needs_more_support_or_native_clickable_point") }
  }
  $largeSurface = ($targetSizeClass -eq "large")
  $largeSurfaceOk = (-not $largeSurface -or $allowLargeSurface -or $nativeClickable -or $pattern)
  if (-not $largeSurfaceOk) { [void]$warnings.Add("large_surface_without_pattern_or_native_clickable_point") }
  if ($targetSizeClass -eq "unknown") { [void]$warnings.Add("target_size_unknown") }

  $safeToClick = (
    $pointPlanOk -and
    $targetSpecified -and
    $guardMatched -and
    $coordinateRisk -ne "high" -and
    $confidenceOk -and
    $tinyTargetOk -and
    $largeSurfaceOk -and
    $recommendedInsideRect
  )
  if (-not $pointPlanOk) { [void]$errors.Add([pscustomobject]@{ code="point_plan_not_safe"; message="point-plan did not produce a safe recommended point"; reason="$($plan.reason)" }) }
  if (-not $targetSpecified) { [void]$errors.Add([pscustomobject]@{ code="missing_target_guard"; message="target-validate requires --target-match or --target-hwnd for safe_to_click=true" }) }
  if ($coordinateRisk -eq "high") { [void]$errors.Add([pscustomobject]@{ code="high_coordinate_risk"; message="coordinate profile reports high risk" }) }

  $sw.Stop()
  $recommendedCommand = if ($safeToClick) { $plan.recommended_command } else { $null }
  $payload = [pscustomobject]@{
    schema = "cucp.target-validate/v1"
    status = if ($safeToClick) { "ok" } else { "partial" }
    mode = "pre_click_validation"
    x = $x
    y = $y
    radius = $radius
    step = $step
    click_inset = $clickInset
    target_hwnd = $th
    target_match = $tm
    guard_level = if ($targetSpecified) { "target_guarded" } else { "unguarded" }
    safe_to_click = [bool]$safeToClick
    confidence = $confidence
    min_confidence = $minConfidence
    coordinate_risk = $coordinateRisk
    target_size_class = $targetSizeClass
    tiny_target = [bool]$tinyTarget
    small_target = [bool]$smallTarget
    elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
    point_plan_exit = [int]$planResult.exit
    point_plan = $plan
    validation = [pscustomobject]@{
      point_plan_ok = [bool]$pointPlanOk
      target_guard_specified = [bool]$targetSpecified
      guard_matched = [bool]$guardMatched
      coordinate_ok = [bool]($coordinateRisk -ne "high")
      confidence_ok = [bool]$confidenceOk
      tiny_target_ok = [bool]$tinyTargetOk
      large_surface_ok = [bool]$largeSurfaceOk
      has_recommended_point = [bool]($plan.recommended_point)
      has_recommended_command = [bool]($plan.recommended_command)
      target_size_class = $targetSizeClass
      target_width = [int]$targetWidth
      target_height = [int]$targetHeight
      target_area = [int]$area
      support = [int]$support
      native_clickable = [bool]$nativeClickable
      point_source = $pointSource
      role = $role
      pattern = $pattern
      recommended_point_inside_rect = [bool]$recommendedInsideRect
      near_element_edge = [bool]$nearElementEdge
      edge_distance = $edgeDistance
    }
    recommended_command = $recommendedCommand
    recommended_command_line = if ($safeToClick -and $recommendedCommand) { _TaskPlan-StepString -Command @($recommendedCommand) } else { "" }
    warnings = @($warnings | Sort-Object -Unique)
    errors = @($errors)
    next_step = if ($safeToClick) { "Run recommended_command with -AllowLiveControl only after user authorization, then verify with wait-label/windows/screenshot-diff." } else { "Do not live-click yet. Re-ground with app-profile/smart-plan, add --target-match or --target-hwnd, increase --radius, or prefer DOM/UIA pattern routes." }
  }
  if ($Brief -and -not $jsonOnly) {
    if ($safeToClick) {
      [Console]::Out.WriteLine("ok target-validate @($x,$y) size=$targetSizeClass confidence=$confidence support=$support native=$nativeClickable elapsed_ms=$($payload.elapsed_ms)")
    } else {
      [Console]::Out.WriteLine("partial target-validate @($x,$y) safe=false size=$targetSizeClass confidence=$confidence warnings=$(@($payload.warnings).Count) errors=$(@($payload.errors).Count) elapsed_ms=$($payload.elapsed_ms)")
    }
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 18))
  }
  if ($safeToClick) { return 0 }
  return 2
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

function Test-CdpPortQuick {
  param([int]$Port = 9222, [int]$TimeoutMs = 120)
  # v1.5.0 Phase 4: in-memory TTL cache (1초)
  # 같은 wrapper invocation 안에서 cdp-detect 와 그 직후 cdp-* 매크로가
  # 같은 port 를 재확인할 때 TCP socket 생성 비용 (~30-120ms) 회피.
  if (-not $Script:CdpPortCache) { $Script:CdpPortCache = @{} }
  $now = [DateTime]::UtcNow.Ticks
  if ($Script:CdpPortCache.ContainsKey($Port)) {
    $entry = $Script:CdpPortCache[$Port]
    if ($entry.expires_ticks -gt $now) {
      return [bool]$entry.open
    } else {
      [void]$Script:CdpPortCache.Remove($Port)
    }
  }
  $client = New-Object System.Net.Sockets.TcpClient
  $handle = $null
  $isOpen = $false
  try {
    $iar = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
    $handle = $iar.AsyncWaitHandle
    if (-not $handle.WaitOne($TimeoutMs, $false)) { $isOpen = $false }
    else {
      $client.EndConnect($iar)
      $isOpen = [bool]$client.Connected
    }
  } catch {
    $isOpen = $false
  } finally {
    try { if ($handle) { $handle.Close() } } catch { }
    try { $client.Close() } catch { }
    try { $client.Dispose() } catch { }
  }
  $Script:CdpPortCache[$Port] = @{
    open = $isOpen
    expires_ticks = [DateTime]::UtcNow.AddMilliseconds(1000).Ticks
  }
  return $isOpen
}

function New-CdpDomBridgePlan {
  param(
    [ValidateSet("click", "type", "find")]
    [string]$DomAction,
    [string]$Query,
    [int]$Port = 9222,
    [string]$PageMatch,
    [string]$TextToType,
    [bool]$Clear,
    [bool]$Enter
  )
  $readOnlyAction = if ($DomAction -eq "type") { "cdp-smart-type-find" } else { "cdp-smart-find" }
  $liveAction = if ($DomAction -eq "type") { "cdp-smart-type" } else { "cdp-smart-click" }
  $readOnlyCommand = @("macro", $readOnlyAction)
  $liveCommand = @("macro", $liveAction)
  if ($DomAction -eq "type") {
    $readOnlyCommand += @("--label", $Query)
    $liveCommand += @("--label", $Query)
    if ($TextToType) { $liveCommand += @("--text", $TextToType) }
    if ($Clear) { $liveCommand += "--clear-first" }
    if ($Enter) { $liveCommand += "--press-enter" }
  } else {
    $readOnlyCommand += @("--text", $Query)
    $liveCommand += @("--text", $Query)
  }
  $readOnlyCommand += @("--port", "$Port")
  $liveCommand += @("--port", "$Port")
  if ($PageMatch) {
    $readOnlyCommand += @("--page-match", $PageMatch)
    $liveCommand += @("--page-match", $PageMatch)
  }
  return [ordered]@{
    schema = "cucp.cdp-dom-bridge-plan/v1"
    route = "cdp_dom"
    dom_action = $DomAction
    query = $Query
    port = $Port
    page_match = $PageMatch
    read_only_command = $readOnlyCommand
    live_command = $liveCommand
    selector_ranking = @(
      [ordered]@{ signal="test_id_or_data_attr"; priority=100 },
      [ordered]@{ signal="aria_label_or_label_control"; priority=94 },
      [ordered]@{ signal="role_plus_accessible_name"; priority=90 },
      [ordered]@{ signal="placeholder_or_name"; priority=82 },
      [ordered]@{ signal="visible_text"; priority=70 },
      [ordered]@{ signal="css_fallback"; priority=50 }
    )
    fallback_order = @("cdp_dom", "uia_pattern", "ocr_uia", "target_validate_precision_point", "vision")
  }
}

function Emit-CdpPortClosed {
  param([string]$Action, [int]$Port, [string]$BriefSubject, $DomBridgePlan = $null)
  if (-not $BriefSubject) { $BriefSubject = $Action }
  if ($Brief) {
    [Console]::Out.WriteLine("partial $BriefSubject reason=cdp_port_closed")
  } else {
    $payload = [ordered]@{
      action = $Action
      status = "partial"
      reason = "cdp_port_closed"
      port = $Port
      detail = "tcp_port_closed_or_timeout"
      source = "wrapper_preflight"
    }
    if ($DomBridgePlan) { $payload["dom_bridge_plan"] = $DomBridgePlan }
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 8))
  }
  return 2
}

# macro cdp-detect [--port N]
# 9222 포트 + 페이지 목록 (read-only)
function Invoke-MacroCdpDetect {
  param([string[]]$Rest)
  $port = [int](_Read-OptValue -Rest $Rest -Name "--port")
  if ($port -le 0) { $port = 9222 }
  if (-not (Test-CdpPortQuick -Port $port -TimeoutMs 120)) {
    return (Emit-CdpPortClosed -Action "cdp-detect" -Port $port -BriefSubject "cdp-detect port=$port")
  }
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

# macro cdp-eval --expr "<javascript>" [--expr-b64 <base64>] [--page-match Kiro] [--port 9222]
# 임의 JS 실행 (read-only — 사용자가 무엇을 실행하는지 알아서 책임)
function Invoke-MacroCdpEval {
  param([string[]]$Rest)
  $expr = _Read-OptValue -Rest $Rest -Name "--expr"
  $exprB64 = _Read-OptValue -Rest $Rest -Name "--expr-b64"
  $pm = _Read-OptValue -Rest $Rest -Name "--page-match"
  $port = [int](_Read-OptValue -Rest $Rest -Name "--port")
  if (-not $expr -and -not $exprB64) { throw "macro cdp-eval requires --expr or --expr-b64" }
  if ($port -le 0) { $port = 9222 }
  if (-not (Test-CdpPortQuick -Port $port -TimeoutMs 120)) {
    return (Emit-CdpPortClosed -Action "cdp-eval" -Port $port -BriefSubject "cdp-eval")
  }
  $argList = @("-Action","cdp-eval","-CdpPort","$port")
  if ($expr) { $argList += @("-CdpExpr", $expr) }
  else { $argList += @("-CdpExprB64", $exprB64) }
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
  if (-not (Test-CdpPortQuick -Port $port -TimeoutMs 120)) {
    _Trajectory-Append -Kind "type" -Payload @{
      source = "cdp_type"
      selector = $selector
      text_length = if ($text) { $text.Length } else { 0 }
      sent_enter = [bool]$pressEnter
      exit = 2
      reason = "cdp_port_closed"
    }
    return (Emit-CdpPortClosed -Action "cdp-type" -Port $port -BriefSubject "cdp-type selector='$selector'")
  }
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
  if (-not (Test-CdpPortQuick -Port $port -TimeoutMs 120)) {
    _Trajectory-Append -Kind "click" -Payload @{
      source = "cdp_click"
      selector = $selector
      exit = 2
      reason = "cdp_port_closed"
    }
    return (Emit-CdpPortClosed -Action "cdp-click" -Port $port -BriefSubject "cdp-click selector='$selector'")
  }
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

# macro cdp-smart-click --text "<visible label>" [--page-match Kiro] [--port 9222]
# DOM visible text / aria-label / title / placeholder 기반 element.click().
function Invoke-MacroCdpSmartFind {
  param([string[]]$Rest)
  $text = _Read-OptValue -Rest $Rest -Name "--text"
  $pm = _Read-OptValue -Rest $Rest -Name "--page-match"
  $port = [int](_Read-OptValue -Rest $Rest -Name "--port")
  if (-not $text) { throw "macro cdp-smart-find requires --text" }
  if ($port -le 0) { $port = 9222 }
  if (-not (Test-CdpPortQuick -Port $port -TimeoutMs 120)) {
    $plan = New-CdpDomBridgePlan -DomAction "click" -Query $text -Port $port -PageMatch $pm
    return (Emit-CdpPortClosed -Action "cdp-smart-find" -Port $port -BriefSubject "cdp-smart-find text='$text'" -DomBridgePlan $plan)
  }
  $argList = @("-Action","cdp-smart-find","-CdpText",$text,"-CdpPort","$port")
  if ($pm) { $argList += @("-CdpPageMatch", $pm) }
  $r = Invoke-NativeHelper -ArgList $argList
  $exitCode = [int]$r.ExitCode
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok cdp-smart-find text='$text' matched='$($r.Json.matched_text)' score=$($r.Json.score) tag=$($r.Json.tag_name) page='$($r.Json.page_title)'")
    } else {
      $reason = if ($r.Json) { $r.Json.reason } else { "helper_failed" }
      [Console]::Out.WriteLine("partial cdp-smart-find text='$text' reason=$reason")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $exitCode
}

function Invoke-MacroCdpSmartTypeFind {
  param([string[]]$Rest)
  $label = _Read-OptValue -Rest $Rest -Name "--label"
  $pm = _Read-OptValue -Rest $Rest -Name "--page-match"
  $port = [int](_Read-OptValue -Rest $Rest -Name "--port")
  if (-not $label) { throw "macro cdp-smart-type-find requires --label" }
  if ($port -le 0) { $port = 9222 }
  if (-not (Test-CdpPortQuick -Port $port -TimeoutMs 120)) {
    $plan = New-CdpDomBridgePlan -DomAction "type" -Query $label -Port $port -PageMatch $pm
    return (Emit-CdpPortClosed -Action "cdp-smart-type-find" -Port $port -BriefSubject "cdp-smart-type-find label='$label'" -DomBridgePlan $plan)
  }
  $argList = @("-Action","cdp-smart-type-find","-CdpText",$label,"-CdpPort","$port")
  if ($pm) { $argList += @("-CdpPageMatch", $pm) }
  $r = Invoke-NativeHelper -ArgList $argList
  $exitCode = [int]$r.ExitCode
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok cdp-smart-type-find label='$label' matched='$($r.Json.matched_text)' score=$($r.Json.score) tag=$($r.Json.tag_name) page='$($r.Json.page_title)'")
    } else {
      $reason = if ($r.Json) { $r.Json.reason } else { "helper_failed" }
      [Console]::Out.WriteLine("partial cdp-smart-type-find label='$label' reason=$reason")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $exitCode
}

function Invoke-MacroCdpSmartClick {
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro cdp-smart-click requires -AllowLiveControl" }
  $text = _Read-OptValue -Rest $Rest -Name "--text"
  $pm = _Read-OptValue -Rest $Rest -Name "--page-match"
  $port = [int](_Read-OptValue -Rest $Rest -Name "--port")
  if (-not $text) { throw "macro cdp-smart-click requires --text" }
  if ($port -le 0) { $port = 9222 }
  if (-not (Test-CdpPortQuick -Port $port -TimeoutMs 120)) {
    _Trajectory-Append -Kind "click" -Payload @{
      source = "cdp_smart_click"
      text = $text
      exit = 2
      reason = "cdp_port_closed"
    }
    $plan = New-CdpDomBridgePlan -DomAction "click" -Query $text -Port $port -PageMatch $pm
    return (Emit-CdpPortClosed -Action "cdp-smart-click" -Port $port -BriefSubject "cdp-smart-click text='$text'" -DomBridgePlan $plan)
  }
  $argList = @("-Action","cdp-smart-click","-CdpText",$text,"-CdpPort","$port")
  if ($pm) { $argList += @("-CdpPageMatch", $pm) }
  $r = Invoke-NativeHelper -ArgList $argList
  $exitCode = [int]$r.ExitCode
  _Trajectory-Append -Kind "click" -Payload @{
    source = "cdp_smart_click"
    text = $text
    matched_text = "$($r.Json.matched_text)"
    score = $r.Json.score
    page_id = "$($r.Json.page_id)"
    exit = $exitCode
  }
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok cdp-smart-click text='$text' matched='$($r.Json.matched_text)' score=$($r.Json.score) tag=$($r.Json.tag_name) page='$($r.Json.page_title)'")
    } else {
      $reason = if ($r.Json) { $r.Json.reason } else { "helper_failed" }
      [Console]::Out.WriteLine("partial cdp-smart-click text='$text' reason=$reason")
    }
  } else {
    if ($r.Raw) { [Console]::Out.Write($r.Raw) }
  }
  return $exitCode
}

# macro cdp-smart-type --label "<field label>" --text "<msg>" [--page-match Kiro] [--port 9222]
# DOM visible label / placeholder 기반 input/contenteditable 직접 입력.
function Invoke-MacroCdpSmartType {
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro cdp-smart-type requires -AllowLiveControl" }
  $label = _Read-OptValue -Rest $Rest -Name "--label"
  $text = _Read-OptValue -Rest $Rest -Name "--text"
  $pm = _Read-OptValue -Rest $Rest -Name "--page-match"
  $port = [int](_Read-OptValue -Rest $Rest -Name "--port")
  $pressEnter = _Read-Switch -Rest $Rest -Name "--press-enter"
  $clearFirst = _Read-Switch -Rest $Rest -Name "--clear-first"
  if (-not $label) { throw "macro cdp-smart-type requires --label" }
  if (-not $text -and -not $clearFirst -and -not $pressEnter) { throw "macro cdp-smart-type requires --text or --clear-first/--press-enter" }
  if ($port -le 0) { $port = 9222 }
  if (-not (Test-CdpPortQuick -Port $port -TimeoutMs 120)) {
    _Trajectory-Append -Kind "type" -Payload @{
      source = "cdp_smart_type"
      label = $label
      text_length = if ($text) { $text.Length } else { 0 }
      sent_enter = [bool]$pressEnter
      exit = 2
      reason = "cdp_port_closed"
    }
    $plan = New-CdpDomBridgePlan -DomAction "type" -Query $label -Port $port -PageMatch $pm -TextToType $text -Clear ([bool]$clearFirst) -Enter ([bool]$pressEnter)
    return (Emit-CdpPortClosed -Action "cdp-smart-type" -Port $port -BriefSubject "cdp-smart-type label='$label'" -DomBridgePlan $plan)
  }
  $argList = @("-Action","cdp-smart-type","-CdpText",$label,"-CdpPort","$port")
  if ($text) { $argList += @("-Text", $text) }
  if ($pm) { $argList += @("-CdpPageMatch", $pm) }
  if ($pressEnter) { $argList += "-PressEnter" }
  if ($clearFirst) { $argList += "-ClearFirst" }
  $r = Invoke-NativeHelper -ArgList $argList
  $exitCode = [int]$r.ExitCode
  _Trajectory-Append -Kind "type" -Payload @{
    source = "cdp_smart_type"
    label = $label
    matched_text = "$($r.Json.matched_text)"
    text_length = if ($text) { $text.Length } else { 0 }
    sent_enter = [bool]$pressEnter
    page_id = "$($r.Json.page_id)"
    exit = $exitCode
  }
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok cdp-smart-type label='$label' matched='$($r.Json.matched_text)' score=$($r.Json.score) tag=$($r.Json.tag_name) len=$($r.Json.text_length) sent_enter=$($r.Json.sent_enter) page='$($r.Json.page_title)'")
    } else {
      $reason = if ($r.Json) { $r.Json.reason } else { "helper_failed" }
      [Console]::Out.WriteLine("partial cdp-smart-type label='$label' reason=$reason")
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
#   ┌─ Stage 0: CDP/DOM smart click         [--allow-cdp / --cdp-page-match / --cdp-port]
#   │    Chrome/Electron 원격 디버깅 포트가 열려 있으면 DOM text/aria/label 기반 click().
#   │    포트 탐지 지연을 피하려고 기본 자동 실행은 꺼져 있음.
#   ├─ Stage 1: UIA Pattern (uia-invoke)
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

function Invoke-MacroSmartPlan {
  param([string[]]$Rest)
  $label = _Read-OptValue -Rest $Rest -Name "--label"
  $typeText = _Read-OptValue -Rest $Rest -Name "--type-text"
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $window = _Read-OptValue -Rest $Rest -Name "--window"
  $role = _Read-OptValue -Rest $Rest -Name "--role"
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  $includeOcr = _Read-Switch -Rest $Rest -Name "--include-ocr"
  $ocrMatch = _Read-OptValue -Rest $Rest -Name "--ocr-match"
  $ocrLang = _Read-OptValue -Rest $Rest -Name "--ocr-language"
  $disableCdp = _Read-Switch -Rest $Rest -Name "--no-cdp"
  $allowCdp = _Read-Switch -Rest $Rest -Name "--allow-cdp"
  $cdpPageMatch = _Read-OptValue -Rest $Rest -Name "--cdp-page-match"
  $cdpPortRaw = _Read-OptValue -Rest $Rest -Name "--cdp-port"
  $cdpPort = [int]$cdpPortRaw
  $pressEnter = _Read-Switch -Rest $Rest -Name "--press-enter"
  $clearFirst = _Read-Switch -Rest $Rest -Name "--clear-first"
  $precisionPoints = (_Read-Switch -Rest $Rest -Name "--precision-points") -or (_Read-Switch -Rest $Rest -Name "--point-plan")
  $precisionRadiusRaw = _Read-OptValue -Rest $Rest -Name "--precision-radius"
  if (-not $precisionRadiusRaw) { $precisionRadiusRaw = _Read-OptValue -Rest $Rest -Name "--point-radius" }
  $precisionStepRaw = _Read-OptValue -Rest $Rest -Name "--precision-step"
  if (-not $precisionStepRaw) { $precisionStepRaw = _Read-OptValue -Rest $Rest -Name "--point-step" }
  $pointCacheTtlRaw = _Read-OptValue -Rest $Rest -Name "--point-cache-ttl"
  if (-not $pointCacheTtlRaw) { $pointCacheTtlRaw = _Read-OptValue -Rest $Rest -Name "--cache-ttl" }
  $precisionRadius = 6
  $precisionStep = 2
  $pointCacheTtl = $CacheSeconds
  if (-not $label) { throw "macro smart-plan requires --label" }
  if (-not $match) { $match = $window }
  if (-not $ocrMatch) { $ocrMatch = "contains" }
  if ($cdpPort -le 0) { $cdpPort = 9222 }
  if ($null -ne $precisionRadiusRaw -and "$precisionRadiusRaw" -ne "") { $precisionRadius = [int]$precisionRadiusRaw }
  if ($null -ne $precisionStepRaw -and "$precisionStepRaw" -ne "") { $precisionStep = [int]$precisionStepRaw }
  if ($null -ne $pointCacheTtlRaw -and "$pointCacheTtlRaw" -ne "") { $pointCacheTtl = [int]$pointCacheTtlRaw }
  if ($precisionRadius -lt 0) { $precisionRadius = 0 }
  if ($precisionRadius -gt 64) { $precisionRadius = 64 }
  if ($precisionStep -le 0) { $precisionStep = 2 }
  if ($precisionStep -gt 16) { $precisionStep = 16 }
  if ($pointCacheTtl -lt 0) { $pointCacheTtl = 0 }
  $cdpStageEnabled = (-not $disableCdp) -and ($allowCdp -or $cdpPageMatch -or $cdpPortRaw)
  $typeMode = ($null -ne $typeText)
  $precisionPolicy = [pscustomobject]@{
    enabled = [bool]$precisionPoints
    live_click_default_micro_refine = $true
    live_click_anchor_history = $true
    target_validate_before_live_click = [bool]$precisionPoints
    disable_flags = @("--no-micro-refine", "--no-anchor-history")
    default_click_point_flags = @("--target-match/--target-hwnd", "--micro-refine", "--cache-ttl", "--precision-radius", "--precision-step")
  }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $candidates = New-Object System.Collections.ArrayList
  $checks = New-Object System.Collections.ArrayList
  $hintedStrategy = $null
  try { $hintedStrategy = _History-PickBestStrategy -Label $label -Match $match -LookbackN 5 } catch { }

  function _AddPlanCandidate {
    param(
      [string]$Route,
      [int]$Stage,
      [int]$Score,
      [bool]$SafeToAct,
      [bool]$MouseMoved,
      [string[]]$Command,
      $Evidence,
      [string]$Reason = ""
    )
    $rank = (1000 - ($Stage * 100)) + $Score
    [void]$candidates.Add([pscustomobject]@{
      route = $Route
      stage = $Stage
      score = $Score
      rank = $rank
      safe_to_act = $SafeToAct
      mouse_moved = $MouseMoved
      command = @($Command)
      reason = $Reason
      evidence = $Evidence
    })
  }

  function _AddPlanCheck {
    param([string]$Source, [string]$Status, [string]$Reason = "", [int]$ExitCode = 0, $Evidence = $null)
    [void]$checks.Add([pscustomobject]@{
      source = $Source
      status = $Status
      reason = $Reason
      exit = $ExitCode
      evidence = $Evidence
    })
  }

  if ($cdpStageEnabled) {
    if (Test-CdpPortQuick -Port $cdpPort -TimeoutMs 120) {
      $cdpAction = if ($typeMode) { "cdp-smart-type-find" } else { "cdp-smart-find" }
      $cdpArgs = @("-Action",$cdpAction,"-CdpText",$label,"-CdpPort","$cdpPort")
      if ($cdpPageMatch) { $cdpArgs += @("-CdpPageMatch", $cdpPageMatch) }
      elseif ($match) { $cdpArgs += @("-CdpPageMatch", $match) }
      $rCdp = Invoke-NativeHelper -ArgList $cdpArgs
      if ($rCdp.Json -and $rCdp.Json.status -eq "ok") {
        if ($typeMode) {
          $cmd = @("macro","cdp-smart-type","--label",$label,"--text",$typeText,"--port","$cdpPort")
          if ($pressEnter) { $cmd += "--press-enter" }
          if ($clearFirst) { $cmd += "--clear-first" }
        } else {
          $cmd = @("macro","cdp-smart-click","--text",$label,"--port","$cdpPort")
        }
        if ($cdpPageMatch) { $cmd += @("--page-match", $cdpPageMatch) }
        elseif ($match) { $cmd += @("--page-match", $match) }
        $cdpRoute = if ($typeMode) { "cdp_smart_type" } else { "cdp_smart_click" }
        $cdpReason = if ($typeMode) { "DOM input candidate matched for direct value/event typing" } else { "DOM text/aria candidate matched without coordinates" }
        _AddPlanCandidate -Route $cdpRoute -Stage 0 -Score ([int]$rCdp.Json.score) -SafeToAct $true -MouseMoved $false -Command $cmd -Evidence ([pscustomobject]@{
          matched_text = "$($rCdp.Json.matched_text)"
          tag_name = "$($rCdp.Json.tag_name)"
          role = "$($rCdp.Json.role)"
          page_title = "$($rCdp.Json.page_title)"
          rect = $rCdp.Json.rect
        }) -Reason $cdpReason
      } else {
        $reason = if ($rCdp.Json) { "$($rCdp.Json.reason)" } else { "helper_failed" }
        _AddPlanCheck -Source "cdp" -Status "partial" -Reason $reason -ExitCode ([int]$rCdp.ExitCode)
      }
    } else {
      _AddPlanCheck -Source "cdp" -Status "skipped" -Reason "cdp_port_closed"
    }
  } else {
    _AddPlanCheck -Source "cdp" -Status "skipped" -Reason "not_requested"
  }

  $uiaArgs = @("-Action","uia-find","-Label",$label)
  if ($match) { $uiaArgs += @("-Match", $match) }
  if ($role) { $uiaArgs += @("-Role", $role) }
  $rUia = Invoke-NativeHelper -ArgList $uiaArgs
  if ($rUia.Json -and $rUia.Json.top) {
    $top = $rUia.Json.top
    $ambiguous = [bool]$rUia.Json.ambiguous
    if ($rUia.Json.status -eq "ok" -and -not $ambiguous) {
      $score = [int]$top.score
      if ($typeMode) {
        $hasValuePattern = [bool]$top.value_pattern
        $valueReadonly = $false
        try { $valueReadonly = [bool]$top.value_readonly } catch { $valueReadonly = $false }
        if ($hasValuePattern -and -not $valueReadonly) {
          $cmd = @("macro","uia-set-value","--label",$label,"--value",$typeText)
          if ($match) { $cmd += @("--match",$match) }
          if ($role) { $cmd += @("--role",$role) }
          _AddPlanCandidate -Route "uia_set_value" -Stage 1 -Score ($score + 45) -SafeToAct $true -MouseMoved $false -Command $cmd -Evidence ([pscustomobject]@{
            matched_text = "$($top.text)"
            role = "$($top.role)"
            automation_id = "$($top.automation_id)"
            value_pattern = $top.value_pattern
            value_readonly = $top.value_readonly
            rect = $top.rect
          }) -Reason "UIA ValuePattern can set text without keyboard simulation"
        } elseif ($match -and $top.click_point) {
          $cmd = @("macro","safe-type","--target-match",$match,"--text",$typeText)
          if ($top.click_point.x -and $top.click_point.y) { $cmd += @("--click-x","$($top.click_point.x)","--click-y","$($top.click_point.y)") }
          if ($pressEnter) { $cmd += "--enter" }
          _AddPlanCandidate -Route "safe_type_guarded" -Stage 3 -Score $score -SafeToAct $true -MouseMoved $true -Command $cmd -Evidence ([pscustomobject]@{
            matched_text = "$($top.text)"
            role = "$($top.role)"
            automation_id = "$($top.automation_id)"
            click_point = $top.click_point
            rect = $top.rect
          }) -Reason "UIA field candidate exists; safe-type can focus target and use guarded click/type"
        } else {
          _AddPlanCheck -Source "uia_type" -Status "partial" -Reason "no_value_pattern_or_target_match" -ExitCode ([int]$rUia.ExitCode) -Evidence $top
        }
      } else {
        $pattern = "$($top.invoke_pattern)"
        $safePattern = -not [string]::IsNullOrWhiteSpace($pattern)
        if ($safePattern) {
          $cmd = @("macro","uia-invoke","--label",$label)
          if ($match) { $cmd += @("--match",$match) }
          if ($role) { $cmd += @("--role",$role) }
          _AddPlanCandidate -Route "uia_pattern" -Stage 1 -Score ($score + 40) -SafeToAct $true -MouseMoved $false -Command $cmd -Evidence ([pscustomobject]@{
            matched_text = "$($top.text)"
            role = "$($top.role)"
            automation_id = "$($top.automation_id)"
            invoke_pattern = $pattern
            rect = $top.rect
            click_point = $top.click_point
          }) -Reason "UIA pattern can invoke without mouse movement"
        } else {
          $precisionAdded = $false
          if ($precisionPoints -and $match -and $top.click_point -and $top.click_point.x -and $top.click_point.y) {
            $targetValidateCmd = @(
              "macro","target-validate",
              "--x","$($top.click_point.x)",
              "--y","$($top.click_point.y)",
              "--target-match",$match,
              "--radius","$precisionRadius",
              "--step","$precisionStep"
            )
            $pcmd = @(
              "macro","click-point",
              "--x","$($top.click_point.x)",
              "--y","$($top.click_point.y)",
              "--target-match",$match,
              "--refine","uia-safe",
              "--micro-refine",
              "--precision-radius","$precisionRadius",
              "--precision-step","$precisionStep",
              "--cache-ttl","$pointCacheTtl"
            )
            _AddPlanCandidate -Route "uia_precision_point" -Stage 2 -Score ($score + 25) -SafeToAct $true -MouseMoved $true -Command $pcmd -Evidence ([pscustomobject]@{
              matched_text = "$($top.text)"
              role = "$($top.role)"
              automation_id = "$($top.automation_id)"
              rect = $top.rect
              click_point = $top.click_point
              precision_radius = $precisionRadius
              precision_step = $precisionStep
              cache_ttl_seconds = $pointCacheTtl
              target_validate_command = @($targetValidateCmd)
              target_validate_command_line = _TaskPlan-StepString -Command $targetValidateCmd
              click_point_defaults = [pscustomobject]@{
                micro_refine = "enabled_by_default_when_target_guard_present"
                anchor_reuse_history = "scored_before_click_and_recorded_after_success"
              }
            }) -Reason "UIA label matched; validate target, then use guarded click-point with default micro-refine and short TTL point cache"
            _AddPlanCheck -Source "point_precision" -Status "ready" -Reason "recommended_micro_refine_click_point"
            $precisionAdded = $true
          } elseif ($precisionPoints) {
            _AddPlanCheck -Source "point_precision" -Status "skipped" -Reason "requires_target_match_and_click_point"
          }
          $cmd = @("macro","smart-click","--label",$label,"--allow-mouse-fallback")
          if ($match) { $cmd += @("--match",$match) }
          if ($role) { $cmd += @("--role",$role) }
          _AddPlanCandidate -Route "uia_coord" -Stage 2 -Score $(if ($precisionAdded) { $score - 10 } else { $score }) -SafeToAct $true -MouseMoved $true -Command $cmd -Evidence ([pscustomobject]@{
            matched_text = "$($top.text)"
            role = "$($top.role)"
            automation_id = "$($top.automation_id)"
            rect = $top.rect
            click_point = $top.click_point
          }) -Reason $(if ($precisionAdded) { "Fallback if precision point route is not desired" } else { "UIA label matched; use guarded coordinate fallback" })
        }
      }
    } else {
      _AddPlanCheck -Source "uia" -Status "partial" -Reason "ambiguous_or_partial" -ExitCode ([int]$rUia.ExitCode) -Evidence ([pscustomobject]@{
        top = $top
        ambiguous = $ambiguous
        candidates = $rUia.Json.candidates
      })
    }
  } else {
    $reason = if ($rUia.Json) { "$($rUia.Json.reason)" } else { "helper_failed" }
    _AddPlanCheck -Source "uia" -Status "partial" -Reason $reason -ExitCode ([int]$rUia.ExitCode)
  }

  if ($includeOcr -and -not $typeMode) {
    $ocrArgs = @("-Action","ocr-uia-fuse","-OcrText",$label,"-OcrMatch",$ocrMatch)
    if ($match) { $ocrArgs += @("-Match", $match) }
    if ($ocrLang) { $ocrArgs += @("-OcrLanguage", $ocrLang) }
    $rOcr = Invoke-NativeHelper -ArgList $ocrArgs
    if ($rOcr.Json -and $rOcr.Json.status -eq "ok") {
      $rec = "$($rOcr.Json.recommendation)"
      $ocrScore = 0
      try { $ocrScore = [int]$rOcr.Json.ocr_top.score } catch { }
      if ($rec -eq "uia_invoke") {
        $cmd = @("macro","ocr-uia-invoke","--text",$label,"--match",$ocrMatch)
        if ($match) { $cmd += @("--match-window",$match) }
        if ($ocrLang) { $cmd += @("--language",$ocrLang) }
        _AddPlanCandidate -Route "fusion_uia_invoke" -Stage 4 -Score ($ocrScore + 30) -SafeToAct $true -MouseMoved $false -Command $cmd -Evidence ([pscustomobject]@{
          ocr_top = $rOcr.Json.ocr_top
          uia_match = $rOcr.Json.uia_match
          invoke_pattern = "$($rOcr.Json.invoke_pattern)"
        }) -Reason "OCR text sits on invokable UIA element"
      } elseif ($rec -eq "ocr_click" -and $ocrScore -ge 70) {
        $cmd = @("macro","ocr-click","--text",$label,"--match",$ocrMatch)
        if ($match) { $cmd += @("--target-match",$match) }
        if ($ocrLang) { $cmd += @("--language",$ocrLang) }
        _AddPlanCandidate -Route "ocr_text" -Stage 5 -Score $ocrScore -SafeToAct $true -MouseMoved $true -Command $cmd -Evidence ([pscustomobject]@{
          ocr_top = $rOcr.Json.ocr_top
          region = $rOcr.Json.region
        }) -Reason "OCR candidate high enough for guarded text click"
      } else {
        _AddPlanCheck -Source "ocr" -Status "partial" -Reason $rec -ExitCode ([int]$rOcr.ExitCode) -Evidence $rOcr.Json
      }
    } else {
      $reason = if ($rOcr.Json) { "$($rOcr.Json.reason)" } else { "helper_failed" }
      _AddPlanCheck -Source "ocr" -Status "partial" -Reason $reason -ExitCode ([int]$rOcr.ExitCode)
    }
  } else {
    $ocrSkipReason = if ($typeMode) { "not_supported_for_type_plan" } else { "not_requested" }
    _AddPlanCheck -Source "ocr" -Status "skipped" -Reason $ocrSkipReason
  }

  $safeCandidates = @($candidates | Where-Object { $_.safe_to_act } | Sort-Object -Property rank -Descending)
  $best = if ($safeCandidates.Count -gt 0) { $safeCandidates[0] } else { $null }
  $sw.Stop()
  $elapsed = [int]$sw.Elapsed.TotalMilliseconds
  $status = if ($best) { "ok" } else { "partial" }
  $confidence = "low"
  if ($best) {
    if ($best.stage -le 1 -and $best.score -ge 100) { $confidence = "high" }
    elseif ($best.score -ge 70) { $confidence = "medium" }
  }
  $recommendedCommand = $null
  if ($best) { $recommendedCommand = [object[]]@($best.command) }
  $payload = [pscustomobject]@{
    schema = "cucp.smart-plan/v1"
    status = $status
    mode = if ($typeMode) { "type" } else { "click" }
    label = $label
    match = $match
    role = $role
    type_text_length = if ($typeMode) { $typeText.Length } else { 0 }
    elapsed_ms = $elapsed
    confidence = $confidence
    history_hint = $hintedStrategy
    best_route = if ($best) { $best.route } else { $null }
    safe_to_act = [bool]($null -ne $best)
    recommended_command = $recommendedCommand
    best = $best
    candidates = @($candidates | Sort-Object -Property rank -Descending)
    checks = @($checks)
    precision_policy = $precisionPolicy
    next_step = if ($best) { "Run recommended_command with -AllowLiveControl only after user authorization, then verify with wait-label/windows/screenshot-diff." } else { "No safe route. Narrow with --match/--role, enable --include-ocr, or inspect list-affordances." }
  }
  if ($Brief -and -not $jsonOnly) {
    if ($best) {
      [Console]::Out.WriteLine("ok smart-plan '$label' route=$($best.route) confidence=$confidence mouse_moved=$($best.mouse_moved) candidates=$($candidates.Count) elapsed_ms=$elapsed")
    } else {
      [Console]::Out.WriteLine("partial smart-plan '$label' no_safe_route checks=$($checks.Count) elapsed_ms=$elapsed")
    }
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 12))
  }
  if ($best) { return 0 }
  return 2
}

function _Parse-WorkflowStepTokens {
  param([string]$Step)
  $parseErrors = $null
  $tokens = [System.Management.Automation.PSParser]::Tokenize($Step, [ref]$parseErrors)
  if ($parseErrors -and $parseErrors.Count -gt 0) {
    return [pscustomobject]@{
      ok = $false
      error = "parse_error"
      detail = (($parseErrors | ForEach-Object { $_.Message }) -join "; ")
      tokens = @()
    }
  }
  $allowedTypes = @("Command","CommandArgument","String","Number")
  $items = New-Object System.Collections.ArrayList
  foreach ($t in @($tokens)) {
    $typeName = "$($t.Type)"
    if ($typeName -eq "NewLine" -or $typeName -eq "LineContinuation") { continue }
    if ($allowedTypes -notcontains $typeName) {
      return [pscustomobject]@{
        ok = $false
        error = "unsupported_token"
        detail = "unsupported token type '$typeName'"
        tokens = @()
      }
    }
    if ($null -ne $t.Content -and "$($t.Content)" -ne "") { [void]$items.Add("$($t.Content)") }
  }
  return [pscustomobject]@{
    ok = ($items.Count -gt 0)
    error = if ($items.Count -gt 0) { "" } else { "empty_step" }
    detail = ""
    tokens = @($items)
  }
}

function _Read-WorkflowStepSpecs {
  param([string[]]$Rest)
  $steps = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $Rest.Count; $i++) {
    if ($Rest[$i] -ne "--step") { continue }
    $parts = New-Object System.Collections.ArrayList
    $j = $i + 1
    while ($j -lt $Rest.Count -and $Rest[$j] -ne "--step") {
      [void]$parts.Add($Rest[$j])
      $j++
    }
    if ($parts.Count -gt 0) {
      [void]$steps.Add((@($parts) -join " "))
    } else {
      [void]$steps.Add("")
    }
    $i = $j - 1
  }
  return @($steps)
}

function _Build-WorkflowPlan {
  param([string[]]$Rest)
  $stepSpecs = @(_Read-WorkflowStepSpecs -Rest $Rest)
  $name = _Read-OptValue -Rest $Rest -Name "--name"
  if ($stepSpecs.Count -eq 0) { throw "macro workflow-plan/run requires --step `"macro <name> ...`"" }

  $readOnlyMacros = @(
    "windows","native-windows","wait-window","wait-label","find-label","list-affordances",
    "health-quick","health-detail","native-health","metrics","perf","log-tail","diagnose-lag",
    "session","trajectory","history","screenshot","native-screenshot",
    "safety-classify","coord-profile","coord-map","coord-anchor","hit-test","hit-test-batch","hit-scan","point-plan","target-validate","smart-plan","app-profile","task-preset","task-plan","form-plan",
    "cdp-detect","cdp-eval","cdp-smart-find","cdp-smart-type-find",
    "ocr-screen","ocr-image","ocr-find-text","ocr-uia-fuse","screenshot-diff",
    "cdp-deep-find","modal-detect","recovery-plan","precision-validate","benchmark","release-notes"
  )
  $liveMacros = @(
    "app-launch","app-close","with-app","focus-window","focus-verify",
    "click-label","double-click-label","right-click-label","click-id","click-point",
    "fill-label","shortcut","shortcut-native","type-native","uia-click-label",
    "uia-invoke","uia-set-value","uia-toggle","safe-type","smart-click","form-run",
    "icon-click","vision-click","vision-click-precise","click-and-verify",
    "click-and-verify-screen","ocr-click","ocr-uia-invoke","cdp-type","cdp-click",
    "cdp-smart-click","cdp-smart-type","auto-do","goal","notify","multi-select",
    "multi-edit","clipboard","process","registry",
    "ime-paste","safe-type-ime","recovery-run"
  )
  $blockedMacros = @("workflow-plan","workflow-run")
  $steps = New-Object System.Collections.ArrayList
  $errors = New-Object System.Collections.ArrayList
  $index = 0

  foreach ($raw in $stepSpecs) {
    $index++
    $parsed = _Parse-WorkflowStepTokens -Step "$raw"
    if (-not $parsed.ok) {
      [void]$errors.Add([pscustomobject]@{ index=$index; code=$parsed.error; message=$parsed.detail; step="$raw" })
      continue
    }
    $cmd = @($parsed.tokens)
    if ($cmd.Count -eq 0) {
      [void]$errors.Add([pscustomobject]@{ index=$index; code="empty_step"; message="empty workflow step"; step="$raw" })
      continue
    }
    if ($cmd[0] -ne "macro") { $cmd = @("macro") + $cmd }
    if ($cmd.Count -lt 2) {
      [void]$errors.Add([pscustomobject]@{ index=$index; code="missing_macro_name"; message="step must name a macro"; step="$raw" })
      continue
    }
    $macroName = "$($cmd[1])"
    $allowed = $false
    $liveRequired = $false
    $reason = ""
    if ($blockedMacros -contains $macroName) {
      $allowed = $false
      $reason = "recursive_workflow_blocked"
    } elseif ($readOnlyMacros -contains $macroName) {
      $allowed = $true
      $liveRequired = $false
      $reason = "read_only_macro"
    } elseif ($liveMacros -contains $macroName) {
      $allowed = $true
      $liveRequired = $true
      $reason = "live_macro"
    } else {
      $allowed = $false
      $reason = "macro_not_in_workflow_allowlist"
    }
    if (-not $allowed) {
      [void]$errors.Add([pscustomobject]@{ index=$index; code=$reason; message="workflow step macro is not allowed"; macro=$macroName; step="$raw" })
    }
    $safety = _Classify-SafetyFromText -Text ((@($cmd) -join " ")) -MacroName $macroName
    $requiresSensitiveConfirmation = ([bool]$liveRequired -and [bool]$safety.requires_explicit_confirmation)
    [void]$steps.Add([pscustomobject]@{
      index = $index
      raw = "$raw"
      macro = $macroName
      command = @($cmd)
      allowed = [bool]$allowed
      live_required = [bool]$liveRequired
      reason = $reason
      safety = $safety
      requires_sensitive_confirmation = [bool]$requiresSensitiveConfirmation
    })
  }

  $allowedCount = @($steps | Where-Object { $_.allowed }).Count
  $liveCount = @($steps | Where-Object { $_.live_required }).Count
  $sensitiveCount = @($steps | Where-Object { $_.requires_sensitive_confirmation }).Count
  $safeToRun = ($steps.Count -gt 0 -and $allowedCount -eq $steps.Count -and $errors.Count -eq 0)
  return [pscustomobject]@{
    schema = "cucp.workflow-plan/v1"
    status = if ($safeToRun) { "ok" } else { "partial" }
    name = $name
    step_count = $steps.Count
    allowed_count = $allowedCount
    live_step_count = $liveCount
    sensitive_step_count = $sensitiveCount
    requires_sensitive_confirmation = [bool]($sensitiveCount -gt 0)
    safe_to_run = [bool]$safeToRun
    safety_policy = [pscustomobject]@{
      schema = "cucp.safety-policy/v1"
      confirmation_flag = "--confirm-sensitive"
      levels_requiring_confirmation = @("medium","high","critical")
      categories_requiring_confirmation = @("credentials","payment","destructive","external_send","identity_or_privacy","system_change","app_settings")
    }
    steps = @($steps)
    errors = @($errors)
  }
}

function Invoke-MacroWorkflowPlan {
  param([string[]]$Rest)
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  $plan = _Build-WorkflowPlan -Rest $Rest
  if ($Brief -and -not $jsonOnly) {
    [Console]::Out.WriteLine("$($plan.status) workflow-plan steps=$($plan.step_count) live=$($plan.live_step_count) errors=$($plan.errors.Count)")
  } else {
    [Console]::Out.WriteLine(($plan | ConvertTo-Json -Depth 12))
  }
  if ($plan.status -eq "ok") { return 0 }
  return 2
}

function Invoke-MacroWorkflowRun {
  param([string[]]$Rest)
  $dryRun = _Read-Switch -Rest $Rest -Name "--dry-run"
  $continueOnError = _Read-Switch -Rest $Rest -Name "--continue-on-error"
  $includePlan = _Read-Switch -Rest $Rest -Name "--include-plan"
  $confirmSensitive = _Read-Switch -Rest $Rest -Name "--confirm-sensitive"
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  $settleMsRaw = _Read-OptValue -Rest $Rest -Name "--settle-ms"
  $observeAfterStep = _Read-Switch -Rest $Rest -Name "--observe-after-step"
  $verifyAfterStep = _Read-Switch -Rest $Rest -Name "--verify-after-step"
  $observeMatch = _Read-OptValue -Rest $Rest -Name "--observe-match"
  $verifyMatch = _Read-OptValue -Rest $Rest -Name "--verify-match"
  $verifyLabelAfterStep = _Read-OptValue -Rest $Rest -Name "--verify-label-after-step"
  if (-not $verifyLabelAfterStep) { $verifyLabelAfterStep = _Read-OptValue -Rest $Rest -Name "--verify-after-label" }
  $verifyLabelWindow = _Read-OptValue -Rest $Rest -Name "--verify-label-window"
  $verifyLabelTimeoutRaw = _Read-OptValue -Rest $Rest -Name "--verify-label-timeout-ms"
  $verifyLabelIntervalRaw = _Read-OptValue -Rest $Rest -Name "--verify-label-interval-ms"
  $retryFailedRaw = _Read-OptValue -Rest $Rest -Name "--retry-failed-step"
  $retryDelayRaw = _Read-OptValue -Rest $Rest -Name "--retry-delay-ms"
  $retryLiveSteps = _Read-Switch -Rest $Rest -Name "--retry-live-steps"
  if (-not $observeMatch -and $verifyMatch) { $observeMatch = $verifyMatch }
  if ($verifyAfterStep) { $observeAfterStep = $true }
  $settleMs = 0
  if ($settleMsRaw) { $settleMs = [int]$settleMsRaw }
  if ($settleMs -lt 0) { $settleMs = 0 }
  if ($settleMs -gt 10000) { $settleMs = 10000 }
  $retryFailedStep = 0
  $retryDelayMs = 0
  if ($retryFailedRaw) { $retryFailedStep = [int]$retryFailedRaw }
  if ($retryDelayRaw) { $retryDelayMs = [int]$retryDelayRaw }
  if ($retryFailedStep -lt 0) { $retryFailedStep = 0 }
  if ($retryFailedStep -gt 5) { $retryFailedStep = 5 }
  if ($retryDelayMs -lt 0) { $retryDelayMs = 0 }
  if ($retryDelayMs -gt 10000) { $retryDelayMs = 10000 }
  $verifyLabelTimeout = 1500
  $verifyLabelInterval = 250
  if ($verifyLabelTimeoutRaw) { $verifyLabelTimeout = [int]$verifyLabelTimeoutRaw }
  if ($verifyLabelIntervalRaw) { $verifyLabelInterval = [int]$verifyLabelIntervalRaw }
  if ($verifyLabelTimeout -lt 100) { $verifyLabelTimeout = 100 }
  if ($verifyLabelTimeout -gt 30000) { $verifyLabelTimeout = 30000 }
  if ($verifyLabelInterval -lt 50) { $verifyLabelInterval = 50 }
  if ($verifyLabelInterval -gt 5000) { $verifyLabelInterval = 5000 }

  function _WorkflowPlanArgs {
    param([string[]]$InputArgs)
    $skip = @{"--dry-run"=$true; "--continue-on-error"=$true; "--include-plan"=$true; "--json-only"=$true; "--observe-after-step"=$true; "--verify-after-step"=$true; "--retry-live-steps"=$true; "--confirm-sensitive"=$true}
    $skipValue = @{"--settle-ms"=$true; "--observe-match"=$true; "--verify-match"=$true; "--verify-label-after-step"=$true; "--verify-after-label"=$true; "--verify-label-window"=$true; "--verify-label-timeout-ms"=$true; "--verify-label-interval-ms"=$true; "--retry-failed-step"=$true; "--retry-delay-ms"=$true}
    $items = New-Object System.Collections.ArrayList
    $skipNext = $false
    foreach ($a in $InputArgs) {
      if ($skipNext) { $skipNext = $false; continue }
      if ($skip.ContainsKey($a)) { continue }
      if ($skipValue.ContainsKey($a)) { $skipNext = $true; continue }
      [void]$items.Add($a)
    }
    return @($items)
  }
  function _InvokeWorkflowChild {
    param([string[]]$ChildArgs)
    $rawLines = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @ChildArgs 2>&1
    $exitCode = $LASTEXITCODE
    $raw = (($rawLines | ForEach-Object { $_.ToString() }) -join "`n")
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json -ErrorAction Stop } catch { }
    return [pscustomobject]@{ exit=[int]$exitCode; raw=$raw; json=$obj }
  }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $plan = _Build-WorkflowPlan -Rest @(_WorkflowPlanArgs -InputArgs $Rest)
  if (-not $dryRun -and $plan.live_step_count -gt 0 -and -not $AllowLiveControl) {
    throw "macro workflow-run requires -AllowLiveControl when live steps are present"
  }
  $sensitiveSteps = @($plan.steps | Where-Object { $_.requires_sensitive_confirmation })
  if (-not $dryRun -and $sensitiveSteps.Count -gt 0 -and -not $confirmSensitive) {
    $sw.Stop()
    $issues = @($sensitiveSteps | ForEach-Object {
      [pscustomobject]@{
        index = $_.index
        macro = $_.macro
        command = $_.command
        risk_level = $_.safety.risk_level
        risk_score = [int]$_.safety.risk_score
        categories = @($_.safety.categories)
        recommended_action = $_.safety.recommended_action
      }
    })
    $payload = [pscustomobject]@{
      schema = "cucp.workflow-run/v1"
      status = "blocked"
      reason = "sensitive_action_requires_confirmation"
      dry_run = [bool]$dryRun
      confirm_sensitive = [bool]$confirmSensitive
      confirmation_flag = "--confirm-sensitive"
      executed_count = 0
      failed_count = 0
      verify_failed_count = 0
      retry_count = 0
      sensitive_step_count = [int]$sensitiveSteps.Count
      safety_issues = @($issues)
      elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
      plan = if ($includePlan) { $plan } else { $null }
      steps = @()
      next_action = "Re-run with --confirm-sensitive only if the user explicitly approved these exact sensitive live actions."
    }
    if ($Brief -and -not $jsonOnly) { [Console]::Out.WriteLine("blocked workflow-run reason=sensitive_action_requires_confirmation sensitive=$($sensitiveSteps.Count)") }
    else { [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 14)) }
    return 3
  }
  if (-not [bool]$plan.safe_to_run) {
    $sw.Stop()
    $payload = [pscustomobject]@{
      schema = "cucp.workflow-run/v1"
      status = "blocked"
      reason = "plan_not_safe"
      dry_run = [bool]$dryRun
      executed_count = 0
      failed_count = 0
      verify_failed_count = 0
      retry_count = 0
      retry_failed_step = [int]$retryFailedStep
      retry_delay_ms = [int]$retryDelayMs
      retry_live_steps = [bool]$retryLiveSteps
      confirm_sensitive = [bool]$confirmSensitive
      verify_label_after_step = $verifyLabelAfterStep
      verify_label_window = $verifyLabelWindow
      verify_label_timeout_ms = [int]$verifyLabelTimeout
      verify_label_interval_ms = [int]$verifyLabelInterval
      settle_ms = [int]$settleMs
      observe_after_step = [bool]$observeAfterStep
      verify_after_step = [bool]$verifyAfterStep
      observe_match = $observeMatch
      elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
      plan = if ($includePlan) { $plan } else { $null }
      errors = @($plan.errors)
      steps = @()
    }
    if ($Brief -and -not $jsonOnly) { [Console]::Out.WriteLine("blocked workflow-run reason=plan_not_safe errors=$($plan.errors.Count)") }
    else { [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 12)) }
    return 3
  }
  if ($dryRun) {
    $sw.Stop()
    $payload = [pscustomobject]@{
      schema = "cucp.workflow-run/v1"
      status = "ready"
      reason = "dry_run"
      dry_run = $true
      executed_count = 0
      failed_count = 0
      verify_failed_count = 0
      retry_count = 0
      retry_failed_step = [int]$retryFailedStep
      retry_delay_ms = [int]$retryDelayMs
      retry_live_steps = [bool]$retryLiveSteps
      confirm_sensitive = [bool]$confirmSensitive
      verify_label_after_step = $verifyLabelAfterStep
      verify_label_window = $verifyLabelWindow
      verify_label_timeout_ms = [int]$verifyLabelTimeout
      verify_label_interval_ms = [int]$verifyLabelInterval
      settle_ms = [int]$settleMs
      observe_after_step = [bool]$observeAfterStep
      verify_after_step = [bool]$verifyAfterStep
      observe_match = $observeMatch
      elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
      plan = $plan
      steps = @()
    }
    if ($Brief -and -not $jsonOnly) { [Console]::Out.WriteLine("ready workflow-run dry-run steps=$($plan.step_count) live=$($plan.live_step_count)") }
    else { [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 12)) }
    return 0
  }

  $results = New-Object System.Collections.ArrayList
  $executed = 0
  $failed = 0
  $verifyFailed = 0
  $retryCount = 0
  foreach ($step in @($plan.steps)) {
    $stepSw = [System.Diagnostics.Stopwatch]::StartNew()
    $attempts = New-Object System.Collections.ArrayList
    $attempt = 0
    $lastR = $null
    $lastPostObservation = $null
    $lastPostObservationRaw = $null
    $lastPostObservationExit = $null
    $lastVerificationStatus = "not_requested"
    $lastLabelVerificationStatus = "not_requested"
    $lastLabelVerificationExit = $null
    $lastLabelVerificationRaw = $null
    $stepFailed = $true
    $retrySkippedReason = ""

    while ($true) {
      $attempt++
      $attemptSw = [System.Diagnostics.Stopwatch]::StartNew()
      $childArgs = @("-Quiet")
      if ([bool]$step.live_required) { $childArgs += "-AllowLiveControl" }
      $childArgs += @($step.command)
      if ([bool]$step.live_required -and $confirmSensitive) { $childArgs += "--confirm-sensitive" }
      $r = _InvokeWorkflowChild -ChildArgs $childArgs
      if ($settleMs -gt 0) { Start-Sleep -Milliseconds $settleMs }
      $postObservation = $null
      $postObservationRaw = $null
      $postObservationExit = $null
      $verificationStatus = "not_requested"
      $labelVerificationStatus = "not_requested"
      $labelVerificationExit = $null
      $labelVerificationRaw = $null
      if ($observeAfterStep) {
        $obsArgs = @("-Quiet","macro","windows","--json-only")
        if ($observeMatch) { $obsArgs += @("--match",$observeMatch) }
        $obs = _InvokeWorkflowChild -ChildArgs $obsArgs
        $postObservationExit = [int]$obs.exit
        if ($obs.json) { $postObservation = $obs.json } else { $postObservationRaw = $obs.raw }
        if ($verifyAfterStep) {
          if ($obs.exit -eq 0) { $verificationStatus = "ok" }
          else { $verificationStatus = "partial" }
        } else {
          $verificationStatus = if ($obs.exit -eq 0) { "observed" } else { "observe_partial" }
        }
      }
      if ($verifyLabelAfterStep) {
        $labelArgs = @("-Quiet","-Brief","macro","wait-label","--label",$verifyLabelAfterStep,"--timeout-ms","$verifyLabelTimeout","--interval-ms","$verifyLabelInterval")
        if ($verifyLabelWindow) { $labelArgs += @("--window",$verifyLabelWindow) }
        elseif ($observeMatch) { $labelArgs += @("--window",$observeMatch) }
        $labelResult = _InvokeWorkflowChild -ChildArgs $labelArgs
        $labelVerificationExit = [int]$labelResult.exit
        $labelVerificationRaw = $labelResult.raw
        $labelVerificationStatus = if ($labelResult.exit -eq 0) { "ok" } else { "partial" }
      }
      $attemptSw.Stop()
      $attemptFailed = ($r.exit -ne 0 -or ($verifyAfterStep -and $postObservationExit -ne $null -and $postObservationExit -ne 0) -or ($verifyLabelAfterStep -and $labelVerificationExit -ne $null -and $labelVerificationExit -ne 0))
      [void]$attempts.Add([pscustomobject]@{
        attempt = $attempt
        status = if (-not $attemptFailed) { "ok" } else { "partial" }
        exit = $r.exit
        elapsed_ms = [int]$attemptSw.Elapsed.TotalMilliseconds
        result = $r.json
        raw = if ($r.json) { $null } else { $r.raw }
        verification_status = $verificationStatus
        post_observation_exit = $postObservationExit
        post_observation = $postObservation
        post_observation_raw = $postObservationRaw
        label_verification_status = $labelVerificationStatus
        label_verification_exit = $labelVerificationExit
        label_verification_raw = $labelVerificationRaw
      })

      $lastR = $r
      $lastPostObservation = $postObservation
      $lastPostObservationRaw = $postObservationRaw
      $lastPostObservationExit = $postObservationExit
      $lastVerificationStatus = $verificationStatus
      $lastLabelVerificationStatus = $labelVerificationStatus
      $lastLabelVerificationExit = $labelVerificationExit
      $lastLabelVerificationRaw = $labelVerificationRaw
      $stepFailed = $attemptFailed
      if (-not $stepFailed) { break }

      $retriesUsed = $attempt - 1
      if ($retryFailedStep -le 0 -or $retriesUsed -ge $retryFailedStep) { break }
      if ([bool]$step.live_required -and -not $retryLiveSteps) {
        $retrySkippedReason = "live_step_retry_requires_retry_live_steps"
        break
      }
      $retryCount++
      if ($retryDelayMs -gt 0) { Start-Sleep -Milliseconds $retryDelayMs }
    }

    $stepSw.Stop()
    $executed++
    if ($stepFailed) { $failed++ }
    if ($stepFailed -and (($verifyAfterStep -and $lastPostObservationExit -ne $null -and $lastPostObservationExit -ne 0) -or ($verifyLabelAfterStep -and $lastLabelVerificationExit -ne $null -and $lastLabelVerificationExit -ne 0))) { $verifyFailed++ }
    [void]$results.Add([pscustomobject]@{
      index = $step.index
      macro = $step.macro
      live_required = [bool]$step.live_required
      command = @($step.command)
      status = if (-not $stepFailed) { "ok" } else { "partial" }
      exit = $lastR.exit
      elapsed_ms = [int]$stepSw.Elapsed.TotalMilliseconds
      attempt_count = $attempt
      retry_count = [Math]::Max(0, $attempt - 1)
      retry_skipped_reason = $retrySkippedReason
      attempts = @($attempts)
      result = $lastR.json
      raw = if ($lastR.json) { $null } else { $lastR.raw }
      settle_ms = [int]$settleMs
      verification_status = $lastVerificationStatus
      post_observation_exit = $lastPostObservationExit
      post_observation = $lastPostObservation
      post_observation_raw = $lastPostObservationRaw
      label_verification_status = $lastLabelVerificationStatus
      label_verification_exit = $lastLabelVerificationExit
      label_verification_raw = $lastLabelVerificationRaw
    })
    if ($stepFailed -and -not $continueOnError) { break }
  }
  $sw.Stop()
  $status = if ($failed -eq 0 -and $executed -eq $plan.step_count) { "ok" } else { "partial" }
  $failureSummary = $null
  $nextAction = ""
  if ($status -ne "ok") {
    $failedStep = @($results | Where-Object { $_.status -ne "ok" } | Select-Object -First 1)
    if ($failedStep) {
      $failureKind = "command_failed"
      $evidence = ""
      $retryExhausted = $false
      if ($failedStep.label_verification_exit -ne $null -and [int]$failedStep.label_verification_exit -ne 0) {
        $failureKind = "label_verification_failed"
        $evidence = "$($failedStep.label_verification_raw)"
        $nextAction = "Run macro find-label --label '$verifyLabelAfterStep' with the right --match/--window, or increase --verify-label-timeout-ms after confirming the expected UI label should appear."
      } elseif ($failedStep.post_observation_exit -ne $null -and [int]$failedStep.post_observation_exit -ne 0) {
        $failureKind = "window_verification_failed"
        $evidence = "post_observation_exit=$($failedStep.post_observation_exit)"
        $target = if ($observeMatch) { $observeMatch } else { $verifyMatch }
        $nextAction = "Run macro windows --match '$target' to confirm the target window, or adjust --verify-match/--observe-match before retrying."
      } elseif ($failedStep.retry_skipped_reason) {
        $failureKind = "retry_skipped"
        $evidence = "$($failedStep.retry_skipped_reason)"
        $nextAction = "Live step retry was skipped. Use --retry-live-steps only if repeating this action is safe and idempotent."
      } else {
        $recommended = ""
        try {
          if ($failedStep.result -and $failedStep.result.recoverable_errors -and $failedStep.result.recoverable_errors.Count -gt 0) {
            $recommended = "$($failedStep.result.recoverable_errors[0].recommended_action)"
          }
        } catch { $recommended = "" }
        if ($recommended) { $nextAction = $recommended }
        else { $nextAction = "Inspect the failed step result, then run macro windows or list-affordances to re-ground before retrying the workflow." }
      }
      if ($retryFailedStep -gt 0 -and [int]$failedStep.retry_count -ge $retryFailedStep) { $retryExhausted = $true }
      $failureSummary = [pscustomobject]@{
        step_index = $failedStep.index
        macro = $failedStep.macro
        failure_kind = $failureKind
        exit = $failedStep.exit
        status = $failedStep.status
        attempt_count = $failedStep.attempt_count
        retry_count = $failedStep.retry_count
        retry_exhausted = [bool]$retryExhausted
        verification_status = $failedStep.verification_status
        label_verification_status = $failedStep.label_verification_status
        evidence = $evidence
        next_action = $nextAction
      }
    } else {
      $nextAction = "No failed step was captured. Re-run with --include-plan and inspect raw workflow output."
    }
  }
  $payload = [pscustomobject]@{
    schema = "cucp.workflow-run/v1"
    status = $status
    reason = if ($status -eq "ok") { "" } else { "step_failed_or_stopped" }
    next_action = $nextAction
    failure_summary = $failureSummary
    dry_run = $false
    executed_count = $executed
    failed_count = $failed
    verify_failed_count = $verifyFailed
    retry_count = $retryCount
    retry_failed_step = [int]$retryFailedStep
    retry_delay_ms = [int]$retryDelayMs
      retry_live_steps = [bool]$retryLiveSteps
      confirm_sensitive = [bool]$confirmSensitive
      sensitive_step_count = [int]$plan.sensitive_step_count
      verify_label_after_step = $verifyLabelAfterStep
    verify_label_window = $verifyLabelWindow
    verify_label_timeout_ms = [int]$verifyLabelTimeout
    verify_label_interval_ms = [int]$verifyLabelInterval
    total_steps = $plan.step_count
    settle_ms = [int]$settleMs
    observe_after_step = [bool]$observeAfterStep
    verify_after_step = [bool]$verifyAfterStep
    observe_match = $observeMatch
    elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
    plan = if ($includePlan) { $plan } else { $null }
    steps = @($results)
  }
  try { _Trajectory-Append -Kind "workflow-run" -Payload @{ status=$status; executed_count=$executed; failed_count=$failed; total_steps=$plan.step_count; elapsed_ms=[int]$sw.Elapsed.TotalMilliseconds } } catch { }
  if ($Brief -and -not $jsonOnly) { [Console]::Out.WriteLine("$status workflow-run executed=$executed failed=$failed total=$($plan.step_count) elapsed_ms=$($payload.elapsed_ms)") }
  else { [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 14)) }
  if ($status -eq "ok") { return 0 }
  return 2
}

function _TaskPlan-QuoteToken {
  param([string]$Value)
  if ($null -eq $Value) { return "''" }
  $s = "$Value"
  if ($s -match '^[A-Za-z0-9_\-\.\/\\:=@]+$') { return $s }
  return "'" + ($s -replace "'", "''") + "'"
}

function _TaskPlan-StepString {
  param([object[]]$Command)
  $tokens = New-Object System.Collections.ArrayList
  foreach ($item in @($Command)) {
    if ($null -eq $item) { continue }
    if (($item -is [array]) -or ($item -is [System.Collections.IEnumerable] -and -not ($item -is [string]))) {
      foreach ($sub in @($item)) {
        if ($null -ne $sub) { [void]$tokens.Add("$sub") }
      }
    } else {
      [void]$tokens.Add("$item")
    }
  }
  return ((@($tokens) | ForEach-Object { _TaskPlan-QuoteToken -Value "$_" }) -join " ")
}

function _TaskPlan-UnwrapCommand {
  param($Command)
  if ($null -eq $Command) { return @() }
  $items = @($Command)
  if ($items.Count -eq 1 -and $items[0] -is [array]) { return @($items[0]) }
  return @($items)
}

function _AppStrategy-NormalizeRoute {
  param([string]$Strategy)
  $s = "$Strategy"
  if (-not $s) { return "" }
  $s = ($s -replace '\+.*$', '').ToLowerInvariant()
  switch -Regex ($s) {
    '^cdp' { return "cdp_dom" }
    '^uia_set_value$' { return "uia_value_or_pattern" }
    '^uia_pattern$' { return "uia_pattern" }
    '^uia_precision_point$' { return "precision_point" }
    '^uia_coord$' { return "uia_click" }
    '^fusion_uia_invoke$' { return "fusion_uia_invoke" }
    '^fusion_coord$' { return "ocr" }
    '^ocr_text$' { return "ocr" }
    '^vision_precise$' { return "vision_precise" }
    default { return $s }
  }
}

function _AppStrategy-Key {
  param([string]$Process, [string]$Class, [string]$AppType)
  $parts = @($Process, $Class, $AppType) | ForEach-Object {
    "$_".Trim().ToLowerInvariant() -replace '[^a-z0-9_.-]+', '-'
  } | Where-Object { $_ }
  if (@($parts).Count -eq 0) { return "unknown-app" }
  return (@($parts | Select-Object -First 3) -join "|")
}

function _AppStrategy-Read {
  if (-not $Script:AppStrategyFile -or -not (Test-Path -LiteralPath $Script:AppStrategyFile)) { return @() }
  $records = New-Object System.Collections.ArrayList
  foreach ($line in @(Get-Content -LiteralPath $Script:AppStrategyFile -Encoding UTF8 -ErrorAction SilentlyContinue)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $obj = $line | ConvertFrom-Json -ErrorAction Stop
      if ($obj) { [void]$records.Add($obj) }
    } catch { }
  }
  return @($records)
}

function _AppStrategy-LastGood {
  param([string]$AppKey)
  if (-not $AppKey) { return $null }
  $records = @(_AppStrategy-Read | Where-Object {
    "$($_.app_key)" -eq $AppKey -and $_.success -eq $true -and $_.strategy
  })
  if ($records.Count -eq 0) { return $null }
  return @($records | Sort-Object ts -Descending | Select-Object -First 1)[0]
}

function _AppStrategy-Append {
  param(
    [string]$AppKey,
    [string]$AppType,
    [string]$Strategy,
    [string]$Confidence,
    [int]$Score,
    [string]$Process,
    [string]$Class,
    [string]$Title
  )
  if (-not $Script:AppStrategyFile -or -not $AppKey -or -not $Strategy) { return $null }
  try {
    $dir = Split-Path -Parent $Script:AppStrategyFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $record = [pscustomobject]@{
      ts = (Get-Date).ToString("o")
      app_key = $AppKey
      app_type = $AppType
      strategy = $Strategy
      normalized_strategy = (_AppStrategy-NormalizeRoute -Strategy $Strategy)
      confidence = $Confidence
      score = [int]$Score
      success = $true
      process = $Process
      class = $Class
      title = $Title
    }
    $line = $record | ConvertTo-Json -Compress -Depth 6
    Add-Content -LiteralPath $Script:AppStrategyFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Script:AppStrategyFile) {
      $all = @(Get-Content -LiteralPath $Script:AppStrategyFile -Encoding UTF8 -ErrorAction SilentlyContinue)
      if ($all.Count -gt 400) {
        $tail = @($all | Select-Object -Last 400)
        [System.IO.File]::WriteAllLines($Script:AppStrategyFile, $tail, (New-Object System.Text.UTF8Encoding($true)))
      }
    }
    return $record
  } catch {
    return [pscustomobject]@{ error = "$($_.Exception.Message)" }
  }
}

function _AppProfile-StrategyScore {
  param(
    [string]$AppType,
    [string[]]$RouteOrder,
    $CdpProbe,
    $UiaProbe,
    [string[]]$Labels,
    $PersistedStrategy,
    [bool]$BrowserLike,
    [bool]$IndustrialLike,
    [bool]$OfficeLike,
    [bool]$NoProbe
  )

  $scores = @{}
  $reasons = @{}
  function _ScoreAdd {
    param([string]$Route, [int]$Points, [string]$Reason)
    if (-not $Route) { return }
    $routeKey = _AppStrategy-NormalizeRoute -Strategy $Route
    if (-not $routeKey) { return }
    if (-not $scores.ContainsKey($routeKey)) { $scores[$routeKey] = 0; $reasons[$routeKey] = New-Object System.Collections.ArrayList }
    $scores[$routeKey] += [int]$Points
    if ($Reason) { [void]$reasons[$routeKey].Add($Reason) }
  }

  $rank = 0
  foreach ($route in @($RouteOrder)) {
    $rank++
    _ScoreAdd -Route $route -Points ([Math]::Max(4, 24 - ($rank * 3))) -Reason "base_route_rank_$rank"
  }

  if ($CdpProbe) {
    if ([bool]$CdpProbe.available) { _ScoreAdd -Route "cdp_dom" -Points 45 -Reason "cdp_probe_available" }
    else { _ScoreAdd -Route "cdp_dom" -Points -18 -Reason "cdp_probe_unavailable:$($CdpProbe.reason)" }
  } elseif ($BrowserLike -and $NoProbe) {
    _ScoreAdd -Route "cdp_dom" -Points 18 -Reason "browser_like_cdp_probe_skipped"
  }

  if ($UiaProbe) {
    if ([bool]$UiaProbe.available) {
      _ScoreAdd -Route "uia_pattern" -Points 28 -Reason "uia_affordances_available"
      _ScoreAdd -Route "uia_click" -Points 16 -Reason "uia_affordances_available"
      try {
        $labelHits = @($UiaProbe.label_hits | Where-Object { $_.found -eq $true }).Count
        if ($labelHits -gt 0) { _ScoreAdd -Route "uia_pattern" -Points ([Math]::Min(20, $labelHits * 6)) -Reason "uia_label_hits=$labelHits" }
      } catch { }
      try {
        if ([int]$UiaProbe.small_icon_count -gt 0) {
          _ScoreAdd -Route "precision_point" -Points 14 -Reason "uia_small_icon_targets=$($UiaProbe.small_icon_count)"
        }
      } catch { }
    } else {
      _ScoreAdd -Route "ocr" -Points 18 -Reason "uia_probe_unavailable"
      _ScoreAdd -Route "precision_point" -Points 8 -Reason "uia_probe_unavailable"
    }
  } else {
    _ScoreAdd -Route "uia_pattern" -Points 10 -Reason "uia_not_probed"
  }

  if ($IndustrialLike) {
    _ScoreAdd -Route "precision_point" -Points 20 -Reason "industrial_owner_drawn_surface"
    _ScoreAdd -Route "ocr" -Points 18 -Reason "industrial_canvas_or_dialog_text"
    _ScoreAdd -Route "vision_precise" -Points 8 -Reason "industrial_visual_fallback"
  } elseif ($OfficeLike) {
    _ScoreAdd -Route "uia_value_or_pattern" -Points 24 -Reason "document_or_mail_app"
    _ScoreAdd -Route "safe_type_guarded" -Points 16 -Reason "document_or_mail_app"
  } else {
    _ScoreAdd -Route "precision_point" -Points 10 -Reason "generic_window_coordinate_fallback"
    _ScoreAdd -Route "ocr" -Points 8 -Reason "generic_visual_text_fallback"
  }

  if ($PersistedStrategy) {
    $persistedRoute = _AppStrategy-NormalizeRoute -Strategy "$($PersistedStrategy.strategy)"
    if ($persistedRoute) {
      _ScoreAdd -Route $persistedRoute -Points 18 -Reason "persisted_last_good_strategy"
    }
  }

  $routeScores = New-Object System.Collections.ArrayList
  foreach ($k in $scores.Keys) {
    [void]$routeScores.Add([pscustomobject]@{
      route = "$k"
      score = [int]([Math]::Max(0, [Math]::Min(100, $scores[$k])))
      reasons = @($reasons[$k])
    })
  }
  $ordered = @($routeScores | Sort-Object @{ Expression = { -1 * [int]$_.score } }, route)
  $best = @($ordered | Select-Object -First 1)[0]
  $score = if ($best) { [int]$best.score } else { 0 }
  $confidence = if ($score -ge 75) { "high" } elseif ($score -ge 50) { "medium" } elseif ($score -ge 25) { "low" } else { "none" }
  return [pscustomobject]@{
    schema = "cucp.app-profile-strategy-score/v1"
    app_type = $AppType
    recommended_strategy = if ($best) { "$($best.route)" } else { "none" }
    confidence = $confidence
    total_score = $score
    route_order = @($ordered | ForEach-Object { "$($_.route)" })
    route_scores = @($ordered)
    evidence = [pscustomobject]@{
      cdp_probe = if ($CdpProbe) { [pscustomobject]@{ available = [bool]$CdpProbe.available; reason = "$($CdpProbe.reason)"; port = [int]$CdpProbe.port } } else { $null }
      uia_probe = if ($UiaProbe) { [pscustomobject]@{ available = [bool]$UiaProbe.available; affordance_count = [int]$UiaProbe.affordance_count; small_icon_count = [int]$UiaProbe.small_icon_count } } else { $null }
      label_count = [int](@($Labels | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | Select-Object -Unique).Count)
      persisted_strategy = $PersistedStrategy
    }
  }
}

function Invoke-MacroAppProfile {
  param([string[]]$Rest)
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  if (-not $match) { $match = _Read-OptValue -Rest $Rest -Name "--window" }
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  $includeAffordances = _Read-Switch -Rest $Rest -Name "--include-affordances"
  $autoProbe = (_Read-Switch -Rest $Rest -Name "--auto-probe") -or (_Read-Switch -Rest $Rest -Name "--probe")
  $probeCdpRequested = $autoProbe -or (_Read-Switch -Rest $Rest -Name "--probe-cdp")
  $probeUiaRequested = $autoProbe -or (_Read-Switch -Rest $Rest -Name "--probe-uia")
  $noProbe = _Read-Switch -Rest $Rest -Name "--no-probe"
  $recordStrategy = (_Read-Switch -Rest $Rest -Name "--record-strategy") -or (_Read-Switch -Rest $Rest -Name "--remember-strategy")
  $noStrategyHistory = _Read-Switch -Rest $Rest -Name "--no-strategy-history"
  $cdpPort = [int](_Read-OptValue -Rest $Rest -Name "--cdp-port")
  if ($cdpPort -le 0) { $cdpPort = [int](_Read-OptValue -Rest $Rest -Name "--port") }
  if ($cdpPort -le 0) { $cdpPort = 9222 }
  $uiaProbeLimit = [int](_Read-OptValue -Rest $Rest -Name "--probe-uia-limit")
  if ($uiaProbeLimit -le 0) { $uiaProbeLimit = 120 }
  $labels = @(_Read-AllOptValues -Rest $Rest -Name "--label")
  foreach ($clickLabel in @(_Read-AllOptValues -Rest $Rest -Name "--click-label")) { $labels += $clickLabel }
  foreach ($fieldSpec in @(_Read-AllOptValues -Rest $Rest -Name "--field")) {
    if ($fieldSpec -and "$fieldSpec".Contains("=")) {
      $fieldLabel = "$fieldSpec".Substring(0, "$fieldSpec".IndexOf("=")).Trim()
      if ($fieldLabel) { $labels += $fieldLabel }
    }
  }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $allWindows = @(_Enumerate-Win32Windows)
  $allVisible = @($allWindows | Where-Object { $_.visible })
  $candidates = if ($match) { @(_Enumerate-Win32Windows -Match $match | Where-Object { $_.visible }) } else { @($allVisible) }
  $eligible = @($candidates | Where-Object { -not $_.minimized })
  if ($eligible.Count -eq 0) { $eligible = @($candidates) }
  $target = $eligible | Sort-Object `
    @{ Expression = { if ($_.foreground) { 0 } else { 1 } } }, `
    @{ Expression = { if ($_.title) { 0 } else { 1 } } }, `
    @{ Expression = { -1 * [int]$_.rect.width * [int]$_.rect.height } } |
    Select-Object -First 1

  $sample = @($allVisible | Select-Object -First 10 | ForEach-Object {
    [pscustomobject]@{
      title = $_.title
      process = $_.process
      class = $_.class
      foreground = [bool]$_.foreground
      minimized = [bool]$_.minimized
      rect = $_.rect
    }
  })

  if (-not $target) {
    $sw.Stop()
    $taskCard = Get-TaskCardContext
    $payload = [pscustomobject]@{
      schema = "cucp.app-profile/v1"
      status = "partial"
      reason = if ($match) { "no_matching_window" } else { "no_visible_window" }
      match = $match
      window_count = [int]$allVisible.Count
      selected_window = $null
      recommended_strategy = "not_found"
      route_order = @()
      strategy_score = [pscustomobject]@{
        schema = "cucp.app-profile-strategy-score/v1"
        app_type = "unknown"
        recommended_strategy = "not_found"
        confidence = "none"
        total_score = 0
        route_order = @()
        route_scores = @()
        evidence = [pscustomobject]@{
          cdp_probe = $null
          uia_probe = $null
          label_count = [int](@($labels | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | Select-Object -Unique).Count)
          persisted_strategy = $null
        }
      }
      strategy_persistence = [pscustomobject]@{
        enabled = -not $noStrategyHistory
        app_key = "not_found"
        history_file = $Script:AppStrategyFile
        last_good_strategy = $null
        record_requested = [bool]$recordStrategy
        recorded = $false
        record = $null
        skipped_reason = if ($recordStrategy) { "no_matching_window" } else { "" }
      }
      recommended_task_options = @()
      probe_commands = @()
      task_card = $taskCard
      windows_sample = @($sample)
      elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
      next_action = if ($match) { "Run macro windows --json-only to inspect available windows, then retry app-profile with a narrower --match." } else { "Open or focus the target app, then run macro app-profile again." }
    }
    if ($Brief -and -not $jsonOnly) { [Console]::Out.WriteLine("partial app-profile reason=$($payload.reason) windows=$($payload.window_count)") }
    else { [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 12)) }
    return 2
  }

  $title = if ($target.title) { "$($target.title)" } else { "" }
  $process = if ($target.process) { "$($target.process)" } else { "" }
  $class = if ($target.class) { "$($target.class)" } else { "" }
  $titleLower = $title.ToLowerInvariant()
  $processLower = $process.ToLowerInvariant()
  $classLower = $class.ToLowerInvariant()
  $identity = (($titleLower + " " + $processLower + " " + $classLower).Trim())
  $targetMatch = if ($match) { $match } elseif ($title) { $title } elseif ($process) { $process } else { "$($target.hwnd)" }

  function _AppProfileProbeCdp {
    param([int]$Port)
    $pSw = [System.Diagnostics.Stopwatch]::StartNew()
    $available = $false
    $status = "partial"
    $reason = "cdp_port_closed"
    $browser = $null
    $protocol = $null
    $pageCount = 0
    if (Test-CdpPortQuick -Port $Port -TimeoutMs 120) {
      $r = Invoke-NativeHelper -ArgList @("-Action","cdp-detect","-CdpPort","$Port")
      if ($r.Json -and $r.Json.status -eq "ok") {
        $available = $true
        $status = "ok"
        $reason = ""
        $browser = $r.Json.browser
        $protocol = $r.Json.protocol_version
        try { $pageCount = [int]$r.Json.page_count } catch { $pageCount = 0 }
      } else {
        $reason = if ($r.Json -and $r.Json.reason) { "$($r.Json.reason)" } else { "cdp_detect_failed" }
      }
    }
    $pSw.Stop()
    return [pscustomobject]@{
      kind = "cdp"
      enabled = $true
      status = $status
      available = [bool]$available
      port = [int]$Port
      browser = $browser
      protocol_version = $protocol
      page_count = [int]$pageCount
      reason = $reason
      elapsed_ms = [int]$pSw.Elapsed.TotalMilliseconds
    }
  }

  function _AppProfileProbeUia {
    param([string]$FocusedWindow, [string[]]$WantedLabels, [int]$Limit, [int64]$Hwnd)
    $pSw = [System.Diagnostics.Stopwatch]::StartNew()
    $items = @(_Get-UIAffordances -FocusedWindow $FocusedWindow -MaxElements $Limit -MinSize 6 -Hwnd $Hwnd)
    $roles = @($items | Group-Object -Property role | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object {
      [pscustomobject]@{ role = "$($_.Name)"; count = [int]$_.Count }
    })
    $labelHits = New-Object System.Collections.ArrayList
    foreach ($label in @($WantedLabels | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | Select-Object -Unique)) {
      $needle = "$label".ToLowerInvariant()
      $hit = $false
      foreach ($it in $items) {
        $hay = New-Object System.Collections.ArrayList
        if ($it.text) { [void]$hay.Add("$($it.text)") }
        if ($it.synonyms) {
          foreach ($s in @($it.synonyms)) { if ($s) { [void]$hay.Add("$s") } }
        }
        foreach ($s in @($hay)) {
          $sl = "$s".ToLowerInvariant()
          if ($sl -eq $needle -or $sl.Contains($needle) -or $needle.Contains($sl)) { $hit = $true; break }
        }
        if ($hit) { break }
      }
      [void]$labelHits.Add([pscustomobject]@{ label = "$label"; found = [bool]$hit })
    }
    $pSw.Stop()
    return [pscustomobject]@{
      kind = "uia"
      enabled = $true
      status = if ($items.Count -gt 0) { "ok" } else { "partial" }
      available = [bool]($items.Count -gt 0)
      affordance_count = [int]$items.Count
      small_icon_count = [int](@($items | Where-Object { $_.small_icon }).Count)
      roles = @($roles)
      label_hits = @($labelHits)
      sample = @($items | Select-Object -First 8 -Property text,role,rect,small_icon,confidence)
      elapsed_ms = [int]$pSw.Elapsed.TotalMilliseconds
    }
  }

  $appType = "win32_desktop"
  $routeOrder = @("uia_pattern","uia_click","precision_point","ocr")
  $notes = New-Object System.Collections.ArrayList
  $taskOptions = New-Object System.Collections.ArrayList
  function _AppProfileAddOptions {
    param([string[]]$Items)
    foreach ($it in @($Items)) {
      if ($null -ne $it -and "$it" -ne "") { [void]$taskOptions.Add("$it") }
    }
  }

  _AppProfileAddOptions -Items @("--match",$targetMatch,"--precision-points","--settle-ms","150","--verify-after-step","--retry-failed-step","1")

  $browserLike = ($processLower -match '^(chrome|msedge|brave|firefox|kiro|cursor|code|windsurf|electron)$') -or ($classLower -like '*chrome_widgetwin*')
  $industrialLike = ($identity -match 'xg5000|xp-builder|xg-pm|cimon|scada|xgt|plc|modbus')
  $taskCard = Get-TaskCardContext -Ensure:([bool]$industrialLike)
  $officeLike = ($identity -match 'winword|excel|powerpnt|outlook|onenote|hwp|wordpad|notepad')
  $runCdpProbe = (-not $noProbe) -and ($probeCdpRequested -or $browserLike)
  $runUiaProbe = (-not $noProbe) -and $probeUiaRequested
  $cdpProbe = $null
  $uiaProbe = $null
  if ($runCdpProbe) { $cdpProbe = _AppProfileProbeCdp -Port $cdpPort }
  if ($runUiaProbe) { $uiaProbe = _AppProfileProbeUia -FocusedWindow $targetMatch -WantedLabels $labels -Limit $uiaProbeLimit -Hwnd ([int64]$target.hwnd) }
  $cdpAvailable = ($cdpProbe -and [bool]$cdpProbe.available)
  $useCdp = $false

  if ($browserLike) {
    $appType = "browser_or_electron"
    if ($cdpAvailable -or $noProbe) {
      $routeOrder = @("cdp_dom","uia_pattern","uia_click","ocr","precision_point")
      _AppProfileAddOptions -Items @("--allow-cdp")
      if ($cdpPort -ne 9222) { _AppProfileAddOptions -Items @("--cdp-port","$cdpPort") }
      $useCdp = $true
      if ($cdpAvailable) { [void]$notes.Add("CDP probe succeeded; prefer DOM actions because they avoid mouse movement and coordinate drift.") }
      else { [void]$notes.Add("CDP probing was skipped by --no-probe; keep CDP in the route as an opt-in assumption.") }
    } else {
      $routeOrder = @("uia_pattern","uia_click","precision_point","ocr")
      [void]$notes.Add("CDP probe did not confirm an available DevTools port, so the recommended route starts with UIA and precision points.")
    }
    [void]$notes.Add("For Chrome/Electron, enable remote debugging when DOM-grade control is required.")
  } elseif ($industrialLike) {
    $appType = "industrial_win32"
    $routeOrder = @("uia_pattern","win32_hit_test","precision_point","ocr","vision_precise")
    _AppProfileAddOptions -Items @("--include-ocr")
    [void]$notes.Add("PLC/SCADA tools often expose mixed Win32/UIA surfaces; prefer UIA pattern actions, then guarded hit-test and precision-point routes.")
    [void]$notes.Add("Use OCR as a fallback for canvas-like dialogs or owner-drawn controls.")
    if ($taskCard) {
      [void]$notes.Add("CUCP task-card context is loaded; use its devices, requirements, and safety flags before planning live actions.")
    } else {
      [void]$notes.Add("Run macro task-card open to capture devices, requirements, and safety constraints for this XG5000/XP-Builder session.")
    }
  } elseif ($officeLike) {
    $appType = "document_or_mail_app"
    $routeOrder = @("uia_value_or_pattern","safe_type_guarded","shortcut","precision_point","ocr")
    [void]$notes.Add("Document/mail apps usually benefit from direct UIA value/pattern actions, guarded typing, and verification after each step.")
  } else {
    [void]$notes.Add("Generic Win32 route: try UIA actions first, then guarded precision points, then OCR only when labels are not exposed.")
  }

  if ($uiaProbe -and -not [bool]$uiaProbe.available) {
    [void]$notes.Add("UIA probe found no exposed affordances; expect OCR or guarded coordinate routes to matter more for this app.")
  } elseif ($uiaProbe -and [int]$uiaProbe.small_icon_count -gt 0) {
    [void]$notes.Add("UIA probe found small icon affordances; precision-point routes are useful for tiny toolbar controls.")
  }

  $appKey = _AppStrategy-Key -Process $process -Class $class -AppType $appType
  $lastGoodStrategy = $null
  if (-not $noStrategyHistory) {
    try { $lastGoodStrategy = _AppStrategy-LastGood -AppKey $appKey } catch { $lastGoodStrategy = $null }
  }
  if ($lastGoodStrategy) {
    [void]$notes.Add("Last good app strategy found in app-strategy history: $($lastGoodStrategy.strategy).")
  }
  $strategyScore = _AppProfile-StrategyScore `
    -AppType $appType `
    -RouteOrder $routeOrder `
    -CdpProbe $cdpProbe `
    -UiaProbe $uiaProbe `
    -Labels $labels `
    -PersistedStrategy $lastGoodStrategy `
    -BrowserLike $browserLike `
    -IndustrialLike $industrialLike `
    -OfficeLike $officeLike `
    -NoProbe $noProbe
  $routeOrder = @($strategyScore.route_order)
  $recordedStrategy = $null
  $recordSkippedReason = ""
  if ($recordStrategy -and -not $noStrategyHistory) {
    if (@("medium","high") -contains "$($strategyScore.confidence)") {
      $recordedStrategy = _AppStrategy-Append `
        -AppKey $appKey `
        -AppType $appType `
        -Strategy "$($strategyScore.recommended_strategy)" `
        -Confidence "$($strategyScore.confidence)" `
        -Score ([int]$strategyScore.total_score) `
        -Process $process `
        -Class $class `
        -Title $title
    } else {
      $recordSkippedReason = "confidence_below_medium"
    }
  } elseif ($recordStrategy -and $noStrategyHistory) {
    $recordSkippedReason = "disabled_by_no_strategy_history"
  }

  $probeCommands = New-Object System.Collections.ArrayList
  foreach ($label in @($labels | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | Select-Object -Unique)) {
    $cmd = @("macro","smart-plan","--label","$label","--match",$targetMatch,"--precision-points")
    if ($useCdp) {
      $cmd += "--allow-cdp"
      if ($cdpPort -ne 9222) { $cmd += @("--cdp-port","$cdpPort") }
    }
    if ($industrialLike) { $cmd += "--include-ocr" }
    $cmd += "--json-only"
    [void]$probeCommands.Add([pscustomobject]@{
      label = "$label"
      command = @($cmd)
      command_line = _TaskPlan-StepString -Command $cmd
      purpose = "Read-only route probe for this label before any live control."
    })
  }

  $affordanceCommand = $null
  if ($includeAffordances) {
    $affCmd = @("macro","list-affordances","--window",$targetMatch,"--limit","40","--json-only")
    $affordanceCommand = [pscustomobject]@{
      command = @($affCmd)
      command_line = _TaskPlan-StepString -Command $affCmd
      purpose = "Optional read-only UIA affordance inventory for label discovery."
    }
  }

  $taskPrefix = @("macro","task-plan") + @($taskOptions)
  $sw.Stop()
  $payload = [pscustomobject]@{
    schema = "cucp.app-profile/v1"
    status = "ok"
    match = $match
    selected_window = [pscustomobject]@{
      title = $title
      process = $process
      class = $class
      hwnd = $target.hwnd
      pid = $target.pid
      foreground = [bool]$target.foreground
      minimized = [bool]$target.minimized
      rect = $target.rect
    }
    app_type = $appType
    recommended_strategy = $strategyScore.recommended_strategy
    route_order = @($routeOrder)
    strategy_score = $strategyScore
    strategy_persistence = [pscustomobject]@{
      enabled = -not $noStrategyHistory
      app_key = $appKey
      history_file = $Script:AppStrategyFile
      last_good_strategy = $lastGoodStrategy
      record_requested = [bool]$recordStrategy
      recorded = [bool]($recordedStrategy -and -not $recordedStrategy.error)
      record = $recordedStrategy
      skipped_reason = $recordSkippedReason
    }
    capability_probes = [pscustomobject]@{
      cdp = $cdpProbe
      uia = $uiaProbe
    }
    recommended_task_options = @($taskOptions)
    suggested_task_plan_prefix = @($taskPrefix)
    suggested_task_plan_prefix_line = _TaskPlan-StepString -Command $taskPrefix
    probe_commands = @($probeCommands)
    affordance_probe = $affordanceCommand
    task_card = $taskCard
    windows_sample = @($sample)
    notes = @($notes)
    elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
    next_action = "Append the task-specific fields/click labels/text to suggested_task_plan_prefix, run the returned plan or probe commands as read-only, then use task-run --dry-run before live control."
  }
  if ($Brief -and -not $jsonOnly) {
    [Console]::Out.WriteLine("ok app-profile type=$appType strategy=$($payload.recommended_strategy) labels=$($probeCommands.Count) elapsed_ms=$($payload.elapsed_ms)")
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 14))
  }
  return 0
}

function Invoke-MacroTaskPreset {
  param([string[]]$Rest)
  $kind = _Read-OptValue -Rest $Rest -Name "--kind"
  if (-not $kind) { $kind = _Read-OptValue -Rest $Rest -Name "--preset" }
  if (-not $kind) { $kind = _Read-OptValue -Rest $Rest -Name "--type" }
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  $kind = "$kind".ToLowerInvariant()
  if (-not $kind) { throw "macro task-preset requires --kind document|mail|form-submit|file-upload|file-download|settings" }

  $taskArgs = New-Object System.Collections.ArrayList
  [void]$taskArgs.Add("macro")
  [void]$taskArgs.Add("task-plan")
  $presetMode = "task"
  $workflowSteps = New-Object System.Collections.ArrayList
  $extraCommands = New-Object System.Collections.ArrayList

  function _PresetAdd {
    param([string[]]$Items)
    foreach ($it in @($Items)) {
      if ($null -ne $it -and "$it" -ne "") { [void]$taskArgs.Add("$it") }
    }
  }

  function _PresetForwardValue {
    param([string]$Name)
    $v = _Read-OptValue -Rest $Rest -Name $Name
    if ($v) { _PresetAdd -Items @($Name,$v) }
  }

  function _PresetForwardSwitch {
    param([string]$Name)
    if (_Read-Switch -Rest $Rest -Name $Name) { _PresetAdd -Items @($Name) }
  }

  function _PresetInvokeJson {
    param([string[]]$ChildArgs)
    $rawLines = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @ChildArgs 2>&1
    $exitCode = $LASTEXITCODE
    $raw = (($rawLines | ForEach-Object { $_.ToString() }) -join "`n")
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json -ErrorAction Stop } catch { }
    return [pscustomobject]@{ exit=[int]$exitCode; raw=$raw; json=$obj }
  }

  $app = _Read-OptValue -Rest $Rest -Name "--app"
  $waitTitle = _Read-OptValue -Rest $Rest -Name "--wait-title"
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $notes = New-Object System.Collections.ArrayList

  switch ($kind) {
    "document" {
      $text = _Read-OptValue -Rest $Rest -Name "--text"
      if (-not $text) { $text = _Read-OptValue -Rest $Rest -Name "--body" }
      if (-not $text) { throw "macro task-preset --kind document requires --text" }
      if (-not $app) { $app = "notepad" }
      if (-not $waitTitle) { $waitTitle = "Notepad" }
      if (-not $match) { $match = $waitTitle }
      _PresetAdd -Items @("--app",$app,"--wait-title",$waitTitle,"--match",$match,"--type-text",$text)
      if (_Read-Switch -Rest $Rest -Name "--replace") { _PresetAdd -Items @("--pre-shortcut","ctrl+a") }
      if (_Read-Switch -Rest $Rest -Name "--save") { _PresetAdd -Items @("--shortcut","ctrl+s") }
      foreach ($shortcut in @(_Read-AllOptValues -Rest $Rest -Name "--shortcut")) { _PresetAdd -Items @("--shortcut",$shortcut) }
      [void]$notes.Add("document preset maps to app launch/wait, optional replace, text input, optional save shortcut")
    }
    "mail" {
      $to = _Read-OptValue -Rest $Rest -Name "--to"
      $subject = _Read-OptValue -Rest $Rest -Name "--subject"
      $body = _Read-OptValue -Rest $Rest -Name "--body"
      $sendLabel = _Read-OptValue -Rest $Rest -Name "--send-label"
      if (-not $sendLabel -and (_Read-Switch -Rest $Rest -Name "--send")) { $sendLabel = "Send" }
      if (-not $to -and -not $subject -and -not $body -and -not $sendLabel) { throw "macro task-preset --kind mail requires --to/--subject/--body and optionally --send-label" }
      if ($app) { _PresetAdd -Items @("--app",$app) }
      if ($waitTitle) { _PresetAdd -Items @("--wait-title",$waitTitle) }
      if ($match) { _PresetAdd -Items @("--match",$match) }
      $toLabel = _Read-OptValue -Rest $Rest -Name "--to-label"; if (-not $toLabel) { $toLabel = "To" }
      $subjectLabel = _Read-OptValue -Rest $Rest -Name "--subject-label"; if (-not $subjectLabel) { $subjectLabel = "Subject" }
      $bodyLabel = _Read-OptValue -Rest $Rest -Name "--body-label"; if (-not $bodyLabel) { $bodyLabel = "Body" }
      if ($to) { _PresetAdd -Items @("--field",("$toLabel=$to")) }
      if ($subject) { _PresetAdd -Items @("--field",("$subjectLabel=$subject")) }
      if ($body) { _PresetAdd -Items @("--field",("$bodyLabel=$body")) }
      if ($sendLabel) { _PresetAdd -Items @("--send-label",$sendLabel) }
      if (-not (_Read-Switch -Rest $Rest -Name "--no-cdp")) { _PresetAdd -Items @("--allow-cdp") }
      [void]$notes.Add("mail preset maps to form fields and optional send label; --allow-cdp is enabled unless --no-cdp is set")
    }
    { $_ -eq "form" -or $_ -eq "form-submit" } {
      $presetMode = "workflow"
      $fieldSpecs = @(_Read-AllOptValues -Rest $Rest -Name "--field")
      $sendLabel = _Read-OptValue -Rest $Rest -Name "--send-label"
      if (-not $sendLabel) { $sendLabel = _Read-OptValue -Rest $Rest -Name "--submit-label" }
      if (-not $sendLabel -and (_Read-Switch -Rest $Rest -Name "--submit")) { $sendLabel = "Submit" }
      if ($fieldSpecs.Count -eq 0 -and -not $sendLabel) { throw "macro task-preset --kind form-submit requires --field and/or --send-label/--submit-label" }
      $cmd = @("macro","form-run")
      foreach ($f in $fieldSpecs) { $cmd += @("--field",$f) }
      if ($sendLabel) { $cmd += @("--send-label",$sendLabel) }
      if ($match) { $cmd += @("--match",$match) }
      if (-not (_Read-Switch -Rest $Rest -Name "--no-cdp")) { $cmd += "--allow-cdp" }
      $cdpPageMatch = _Read-OptValue -Rest $Rest -Name "--cdp-page-match"
      $cdpPort = _Read-OptValue -Rest $Rest -Name "--cdp-port"
      if ($cdpPageMatch) { $cmd += @("--cdp-page-match",$cdpPageMatch) }
      if ($cdpPort) { $cmd += @("--cdp-port",$cdpPort) }
      if (_Read-Switch -Rest $Rest -Name "--clear-first") { $cmd += "--clear-first" }
      if (_Read-Switch -Rest $Rest -Name "--include-ocr") { $cmd += "--include-ocr" }
      if ((_Read-Switch -Rest $Rest -Name "--precision-points") -or (_Read-Switch -Rest $Rest -Name "--point-plan")) { $cmd += "--precision-points" }
      [void]$workflowSteps.Add((_TaskPlan-StepString -Command $cmd))
      [void]$extraCommands.Add([pscustomobject]@{ kind="form_dry_run"; command=@($cmd + "--dry-run") })
      [void]$notes.Add("form-submit preset maps to one form-run workflow step; run the generated form dry-run command before live control")
    }
    { $_ -eq "file-upload" -or $_ -eq "upload" } {
      $presetMode = "workflow"
      $path = _Read-OptValue -Rest $Rest -Name "--path"
      if (-not $path) { $path = _Read-OptValue -Rest $Rest -Name "--file" }
      if (-not $path) { throw "macro task-preset --kind file-upload requires --path" }
      $uploadLabel = _Read-OptValue -Rest $Rest -Name "--upload-label"
      if (-not $uploadLabel) { $uploadLabel = _Read-OptValue -Rest $Rest -Name "--label" }
      if (-not $uploadLabel) { $uploadLabel = "Upload" }
      $dialogTitle = _Read-OptValue -Rest $Rest -Name "--dialog-title"
      if (-not $dialogTitle) { $dialogTitle = "Open" }
      $dialogTimeout = _Read-OptValue -Rest $Rest -Name "--dialog-timeout-ms"
      if (-not $dialogTimeout) { $dialogTimeout = "8000" }
      $clickCmd = @("macro","smart-click","--label",$uploadLabel,"--allow-mouse-fallback")
      if ($match) { $clickCmd += @("--match",$match) }
      if (-not (_Read-Switch -Rest $Rest -Name "--no-cdp")) { $clickCmd += "--allow-cdp" }
      if (_Read-Switch -Rest $Rest -Name "--precision-points") { $clickCmd += "--precision-points" }
      if (_Read-Switch -Rest $Rest -Name "--include-ocr") { $clickCmd += "--include-ocr" }
      [void]$workflowSteps.Add((_TaskPlan-StepString -Command $clickCmd))
      [void]$workflowSteps.Add((_TaskPlan-StepString -Command @("macro","wait-window","--title",$dialogTitle,"--timeout-ms",$dialogTimeout)))
      [void]$workflowSteps.Add((_TaskPlan-StepString -Command @("macro","safe-type","--target-match",$dialogTitle,"--text",$path,"--enter")))
      [void]$notes.Add("file-upload preset maps to upload button click, file dialog wait, guarded path entry, and Enter")
    }
    { $_ -eq "file-download" -or $_ -eq "download" } {
      $presetMode = "workflow"
      $downloadLabel = _Read-OptValue -Rest $Rest -Name "--download-label"
      if (-not $downloadLabel) { $downloadLabel = _Read-OptValue -Rest $Rest -Name "--label" }
      if (-not $downloadLabel) { $downloadLabel = "Download" }
      $clickCmd = @("macro","smart-click","--label",$downloadLabel,"--allow-mouse-fallback")
      if ($match) { $clickCmd += @("--match",$match) }
      if (-not (_Read-Switch -Rest $Rest -Name "--no-cdp")) { $clickCmd += "--allow-cdp" }
      if (_Read-Switch -Rest $Rest -Name "--precision-points") { $clickCmd += "--precision-points" }
      if (_Read-Switch -Rest $Rest -Name "--include-ocr") { $clickCmd += "--include-ocr" }
      [void]$workflowSteps.Add((_TaskPlan-StepString -Command $clickCmd))
      $verifyLabel = _Read-OptValue -Rest $Rest -Name "--verify-label"
      if ($verifyLabel) {
        $verifyTimeout = _Read-OptValue -Rest $Rest -Name "--verify-timeout-ms"
        if (-not $verifyTimeout) { $verifyTimeout = "5000" }
        $waitCmd = @("macro","wait-label","--label",$verifyLabel,"--timeout-ms",$verifyTimeout)
        if ($match) { $waitCmd += @("--window",$match) }
        [void]$workflowSteps.Add((_TaskPlan-StepString -Command $waitCmd))
      }
      [void]$notes.Add("file-download preset maps to a download button click plus optional verification label wait")
    }
    { $_ -eq "settings" -or $_ -eq "app-settings" } {
      $presetMode = "workflow"
      $settingsLabel = _Read-OptValue -Rest $Rest -Name "--settings-label"
      if (-not $settingsLabel) { $settingsLabel = "Settings" }
      $fieldSpecs = @(_Read-AllOptValues -Rest $Rest -Name "--field")
      $saveLabel = _Read-OptValue -Rest $Rest -Name "--save-label"
      if (-not $saveLabel) { $saveLabel = _Read-OptValue -Rest $Rest -Name "--apply-label" }
      if (-not $saveLabel -and (_Read-Switch -Rest $Rest -Name "--save")) { $saveLabel = "Save" }
      if (-not $saveLabel -and (_Read-Switch -Rest $Rest -Name "--apply")) { $saveLabel = "Apply" }
      $settingsCmd = @("macro","smart-click","--label",$settingsLabel,"--allow-mouse-fallback")
      if ($match) { $settingsCmd += @("--match",$match) }
      if (-not (_Read-Switch -Rest $Rest -Name "--no-cdp")) { $settingsCmd += "--allow-cdp" }
      [void]$workflowSteps.Add((_TaskPlan-StepString -Command $settingsCmd))
      foreach ($spec in $fieldSpecs) {
        $rawSpec = "$spec"
        $eq = $rawSpec.IndexOf("=")
        if ($eq -le 0) { throw "macro task-preset --kind settings field must be Label=Value" }
        $fieldLabel = $rawSpec.Substring(0, $eq).Trim()
        $fieldValue = $rawSpec.Substring($eq + 1)
        if (-not $fieldLabel) { throw "macro task-preset --kind settings field label is empty" }
        $fieldCmd = @("macro","smart-click","--label",$fieldLabel,"--allow-mouse-fallback")
        if ($match) { $fieldCmd += @("--match",$match) }
        if (-not (_Read-Switch -Rest $Rest -Name "--no-cdp")) { $fieldCmd += "--allow-cdp" }
        [void]$workflowSteps.Add((_TaskPlan-StepString -Command $fieldCmd))
        if ($match) { [void]$workflowSteps.Add((_TaskPlan-StepString -Command @("macro","safe-type","--target-match",$match,"--text",$fieldValue))) }
        else { [void]$workflowSteps.Add((_TaskPlan-StepString -Command @("macro","type-native","--text",$fieldValue))) }
      }
      foreach ($clickLabel in @(_Read-AllOptValues -Rest $Rest -Name "--click-label")) {
        $cmd = @("macro","smart-click","--label",$clickLabel,"--allow-mouse-fallback")
        if ($match) { $cmd += @("--match",$match) }
        if (-not (_Read-Switch -Rest $Rest -Name "--no-cdp")) { $cmd += "--allow-cdp" }
        [void]$workflowSteps.Add((_TaskPlan-StepString -Command $cmd))
      }
      if ($saveLabel) {
        $saveCmd = @("macro","smart-click","--label",$saveLabel,"--allow-mouse-fallback")
        if ($match) { $saveCmd += @("--match",$match) }
        if (-not (_Read-Switch -Rest $Rest -Name "--no-cdp")) { $saveCmd += "--allow-cdp" }
        [void]$workflowSteps.Add((_TaskPlan-StepString -Command $saveCmd))
      }
      [void]$notes.Add("settings preset maps to open settings, optional field edits, optional extra clicks, and optional save/apply")
    }
    default {
      throw "macro task-preset supports --kind document|mail|form-submit|file-upload|file-download|settings"
    }
  }

  if ($presetMode -eq "task") {
    foreach ($name in @("--name","--verify-label","--verify-timeout-ms","--settle-ms","--observe-match","--verify-match","--verify-label-after-step","--verify-label-window","--verify-label-timeout-ms","--verify-label-interval-ms","--retry-failed-step","--retry-delay-ms","--precision-radius","--precision-step","--point-cache-ttl")) {
      _PresetForwardValue -Name $name
    }
    foreach ($name in @("--allow-cdp","--no-cdp","--precision-points","--include-ocr","--verify-after-step","--observe-after-step","--retry-live-steps","--clear-first","--enter","--press-enter")) {
      _PresetForwardSwitch -Name $name
    }
  }

  if ($presetMode -eq "workflow") {
    $workflowName = _Read-OptValue -Rest $Rest -Name "--name"
    if (-not $workflowName) { $workflowName = $kind }
    $workflowPlanRest = @("--name",$workflowName)
    foreach ($s in @($workflowSteps)) { $workflowPlanRest += @("--step",$s) }
    $workflowPlan = if ($workflowSteps.Count -gt 0) { _Build-WorkflowPlan -Rest $workflowPlanRest } else { $null }
    $workflowPlanCommand = @("macro","workflow-plan") + $workflowPlanRest
    $workflowRunCommand = @("macro","workflow-run")
    $workflowDryRunCommand = @("macro","workflow-run","--dry-run")
    foreach ($name in @("--settle-ms","--observe-match","--verify-match","--verify-label-after-step","--verify-label-window","--verify-label-timeout-ms","--verify-label-interval-ms","--retry-failed-step","--retry-delay-ms")) {
      $v = _Read-OptValue -Rest $Rest -Name $name
      if ($v) {
        $workflowRunCommand += @($name,$v)
        $workflowDryRunCommand += @($name,$v)
      }
    }
    foreach ($name in @("--observe-after-step","--verify-after-step","--retry-live-steps")) {
      if (_Read-Switch -Rest $Rest -Name $name) {
        $workflowRunCommand += $name
        $workflowDryRunCommand += $name
      }
    }
    foreach ($s in @($workflowSteps)) {
      $workflowRunCommand += @("--step",$s)
      $workflowDryRunCommand += @("--step",$s)
    }
    $status = if ($workflowPlan -and [bool]$workflowPlan.safe_to_run) { "ok" } else { "partial" }
    $payload = [pscustomobject]@{
      schema = "cucp.task-preset/v1"
      status = $status
      kind = $kind
      mode = "workflow"
      elapsed_ms = 0
      generated_task_plan_command = $null
      generated_task_run_command = $null
      generated_workflow_plan_command = @($workflowPlanCommand)
      generated_workflow_run_command = @($workflowRunCommand)
      generated_workflow_dry_run_command = @($workflowDryRunCommand)
      extra_commands = @($extraCommands)
      task_plan_exit = $null
      task_plan = $null
      task_plan_raw = $null
      workflow_plan = $workflowPlan
      notes = @($notes)
      next_step = if ($status -eq "ok") { "Run generated_workflow_dry_run_command first. For live control, use generated_workflow_run_command with -AllowLiveControl; add --confirm-sensitive only after explicit approval when required." } else { "Inspect workflow_plan errors and narrow labels/window/app before running." }
    }
    if ($Brief -and -not $jsonOnly) {
      [Console]::Out.WriteLine("$status task-preset kind=$kind mode=workflow steps=$($workflowSteps.Count)")
    } else {
      [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 18))
    }
    if ($status -eq "ok") { return 0 }
    return 2
  }

  $taskRunArgs = New-Object System.Collections.ArrayList
  [void]$taskRunArgs.Add("macro")
  [void]$taskRunArgs.Add("task-run")
  for ($i = 2; $i -lt $taskArgs.Count; $i++) { [void]$taskRunArgs.Add($taskArgs[$i]) }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $planResult = _PresetInvokeJson -ChildArgs (@("-Quiet") + @($taskArgs) + @("--json-only"))
  $sw.Stop()
  $taskPlan = $planResult.json
  $status = if ($taskPlan -and [bool]$taskPlan.safe_to_run) { "ok" } else { "partial" }
  $payload = [pscustomobject]@{
    schema = "cucp.task-preset/v1"
    status = $status
    kind = $kind
    elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
    generated_task_plan_command = @($taskArgs)
    generated_task_run_command = @($taskRunArgs)
    task_plan_exit = [int]$planResult.exit
    task_plan = $taskPlan
    task_plan_raw = if ($taskPlan) { $null } else { $planResult.raw }
    notes = @($notes)
    next_step = if ($status -eq "ok") { "Run generated_task_run_command with --dry-run first, then with -AllowLiveControl only after user authorization." } else { "Inspect task_plan errors and narrow labels/window/app before running." }
  }
  if ($Brief -and -not $jsonOnly) {
    [Console]::Out.WriteLine("$status task-preset kind=$kind task_plan_exit=$($planResult.exit) elapsed_ms=$($payload.elapsed_ms)")
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 18))
  }
  if ($status -eq "ok") { return 0 }
  return 2
}

function Invoke-MacroTaskPlan {
  param([string[]]$Rest)
  $name = _Read-OptValue -Rest $Rest -Name "--name"
  $app = _Read-OptValue -Rest $Rest -Name "--app"
  if (-not $app) { $app = _Read-OptValue -Rest $Rest -Name "--open-app" }
  $appArgs = _Read-OptValue -Rest $Rest -Name "--app-args"
  $waitTitle = _Read-OptValue -Rest $Rest -Name "--wait-title"
  if (-not $waitTitle) { $waitTitle = _Read-OptValue -Rest $Rest -Name "--verify-window" }
  $waitTimeout = [int](_Read-OptValue -Rest $Rest -Name "--wait-timeout-ms")
  $verifyLabel = _Read-OptValue -Rest $Rest -Name "--verify-label"
  $verifyTimeout = [int](_Read-OptValue -Rest $Rest -Name "--verify-timeout-ms")
  $fieldSpecs = @(_Read-AllOptValues -Rest $Rest -Name "--field")
  $clickLabels = @(_Read-AllOptValues -Rest $Rest -Name "--click-label")
  $typeTexts = @(_Read-AllOptValues -Rest $Rest -Name "--type-text")
  if ($typeTexts.Count -eq 0) { $typeTexts = @(_Read-AllOptValues -Rest $Rest -Name "--text") }
  $preShortcuts = @(_Read-AllOptValues -Rest $Rest -Name "--pre-shortcut")
  $shortcuts = @(_Read-AllOptValues -Rest $Rest -Name "--shortcut")
  foreach ($k in @(_Read-AllOptValues -Rest $Rest -Name "--keys")) { $shortcuts += $k }
  $sendLabel = _Read-OptValue -Rest $Rest -Name "--send-label"
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $window = _Read-OptValue -Rest $Rest -Name "--window"
  $allowCdp = _Read-Switch -Rest $Rest -Name "--allow-cdp"
  $disableCdp = _Read-Switch -Rest $Rest -Name "--no-cdp"
  $cdpPageMatch = _Read-OptValue -Rest $Rest -Name "--cdp-page-match"
  $cdpPortRaw = _Read-OptValue -Rest $Rest -Name "--cdp-port"
  $clearFirst = _Read-Switch -Rest $Rest -Name "--clear-first"
  $pressEnter = (_Read-Switch -Rest $Rest -Name "--press-enter") -or (_Read-Switch -Rest $Rest -Name "--enter")
  $includeOcr = _Read-Switch -Rest $Rest -Name "--include-ocr"
  $precisionPoints = (_Read-Switch -Rest $Rest -Name "--precision-points") -or (_Read-Switch -Rest $Rest -Name "--point-plan")
  $precisionRadiusRaw = _Read-OptValue -Rest $Rest -Name "--precision-radius"
  $precisionStepRaw = _Read-OptValue -Rest $Rest -Name "--precision-step"
  $pointCacheTtlRaw = _Read-OptValue -Rest $Rest -Name "--point-cache-ttl"
  if (-not $pointCacheTtlRaw) { $pointCacheTtlRaw = _Read-OptValue -Rest $Rest -Name "--cache-ttl" }
  $settleMsRaw = _Read-OptValue -Rest $Rest -Name "--settle-ms"
  $observeAfterStep = _Read-Switch -Rest $Rest -Name "--observe-after-step"
  $verifyAfterStep = _Read-Switch -Rest $Rest -Name "--verify-after-step"
  $observeMatch = _Read-OptValue -Rest $Rest -Name "--observe-match"
  $verifyMatch = _Read-OptValue -Rest $Rest -Name "--verify-match"
  $verifyLabelAfterStep = _Read-OptValue -Rest $Rest -Name "--verify-label-after-step"
  if (-not $verifyLabelAfterStep) { $verifyLabelAfterStep = _Read-OptValue -Rest $Rest -Name "--verify-after-label" }
  $verifyLabelWindow = _Read-OptValue -Rest $Rest -Name "--verify-label-window"
  $verifyLabelTimeoutRaw = _Read-OptValue -Rest $Rest -Name "--verify-label-timeout-ms"
  $verifyLabelIntervalRaw = _Read-OptValue -Rest $Rest -Name "--verify-label-interval-ms"
  $retryFailedRaw = _Read-OptValue -Rest $Rest -Name "--retry-failed-step"
  $retryDelayRaw = _Read-OptValue -Rest $Rest -Name "--retry-delay-ms"
  $retryLiveSteps = _Read-Switch -Rest $Rest -Name "--retry-live-steps"
  if (-not $observeMatch -and $verifyMatch) { $observeMatch = $verifyMatch }
  if ($verifyAfterStep) { $observeAfterStep = $true }
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  if (-not $match) { $match = $window }
  if ($waitTimeout -le 0) { $waitTimeout = 8000 }
  if ($verifyTimeout -le 0) { $verifyTimeout = 3000 }

  if (-not $app -and -not $waitTitle -and $fieldSpecs.Count -eq 0 -and $clickLabels.Count -eq 0 -and $typeTexts.Count -eq 0 -and $preShortcuts.Count -eq 0 -and $shortcuts.Count -eq 0 -and -not $sendLabel -and -not $verifyLabel) {
    throw "macro task-plan requires --app/--wait-title/--field/--type-text/--shortcut/--click-label/--send-label/--verify-label"
  }

  function _InvokeTaskChildJson {
    param([string[]]$ChildArgs)
    $rawLines = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @ChildArgs 2>&1
    $exitCode = $LASTEXITCODE
    $raw = (($rawLines | ForEach-Object { $_.ToString() }) -join "`n")
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json -ErrorAction Stop } catch { }
    return [pscustomobject]@{ exit=[int]$exitCode; raw=$raw; json=$obj }
  }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $workflowSteps = New-Object System.Collections.ArrayList
  $items = New-Object System.Collections.ArrayList
  $errors = New-Object System.Collections.ArrayList

  if ($app) {
    $cmd = @("macro","app-launch","--name",$app)
    if ($appArgs) { $cmd += @("--args",$appArgs) }
    if ($waitTitle) { $cmd += @("--wait-title",$waitTitle,"--wait-timeout-ms","$waitTimeout") }
    $step = _TaskPlan-StepString -Command $cmd
    [void]$workflowSteps.Add($step)
    [void]$items.Add([pscustomobject]@{ kind="app_launch"; safe_to_act=$true; live_required=$true; command=@($cmd); step=$step })
  } elseif ($waitTitle) {
    $cmd = @("macro","wait-window","--title",$waitTitle,"--timeout-ms","$waitTimeout")
    $step = _TaskPlan-StepString -Command $cmd
    [void]$workflowSteps.Add($step)
    [void]$items.Add([pscustomobject]@{ kind="wait_window"; safe_to_act=$true; live_required=$false; command=@($cmd); step=$step })
  }

  foreach ($shortcut in $preShortcuts) {
    if ([string]::IsNullOrWhiteSpace("$shortcut")) { continue }
    $cmd = @("macro","shortcut","--keys","$shortcut")
    $step = _TaskPlan-StepString -Command $cmd
    [void]$workflowSteps.Add($step)
    [void]$items.Add([pscustomobject]@{ kind="shortcut"; phase="pre"; keys="$shortcut"; safe_to_act=$true; live_required=$true; command=@($cmd); step=$step })
  }

  $typeIndex = 0
  foreach ($typeText in $typeTexts) {
    if ($null -eq $typeText) { continue }
    $typeIndex++
    if ($match) {
      $cmd = @("macro","safe-type","--target-match",$match,"--text","$typeText")
      if ($pressEnter) { $cmd += "--enter" }
      $route = "safe_type_guarded"
    } else {
      $cmd = @("macro","type-native","--text","$typeText")
      if ($clearFirst -and $typeIndex -eq 1) { $cmd += "--clear" }
      if ($pressEnter) { $cmd += "--enter" }
      $route = "type_native"
    }
    $step = _TaskPlan-StepString -Command $cmd
    [void]$workflowSteps.Add($step)
    [void]$items.Add([pscustomobject]@{ kind="type_text"; route=$route; index=$typeIndex; safe_to_act=$true; live_required=$true; command=@($cmd); step=$step })
  }

  $formPlan = $null
  if ($fieldSpecs.Count -gt 0 -or $sendLabel) {
    $formArgs = @("-Quiet","macro","form-plan")
    foreach ($f in $fieldSpecs) { $formArgs += @("--field",$f) }
    if ($sendLabel) { $formArgs += @("--send-label",$sendLabel) }
    if ($match) { $formArgs += @("--match",$match) }
    if ($allowCdp) { $formArgs += "--allow-cdp" }
    if ($disableCdp) { $formArgs += "--no-cdp" }
    if ($cdpPageMatch) { $formArgs += @("--cdp-page-match",$cdpPageMatch) }
    if ($cdpPortRaw) { $formArgs += @("--cdp-port",$cdpPortRaw) }
    if ($clearFirst) { $formArgs += "--clear-first" }
    if ($includeOcr) { $formArgs += "--include-ocr" }
    if ($precisionPoints) { $formArgs += "--precision-points" }
    if ($precisionRadiusRaw) { $formArgs += @("--precision-radius",$precisionRadiusRaw) }
    if ($precisionStepRaw) { $formArgs += @("--precision-step",$precisionStepRaw) }
    if ($pointCacheTtlRaw) { $formArgs += @("--point-cache-ttl",$pointCacheTtlRaw) }
    $formArgs += "--json-only"
    $formResult = _InvokeTaskChildJson -ChildArgs $formArgs
    $formPlan = $formResult.json
    if (-not $formPlan) {
      [void]$errors.Add([pscustomobject]@{ code="form_plan_unparseable"; exit=$formResult.exit; raw=$formResult.raw })
    } elseif (-not [bool]$formPlan.safe_to_act) {
      [void]$errors.Add([pscustomobject]@{ code="form_plan_not_safe"; unsafe_steps=$formPlan.unsafe_steps; errors=$formPlan.errors })
    } else {
      foreach ($cp in @($formPlan.command_plan)) {
        $cmd = @(_TaskPlan-UnwrapCommand -Command $cp.command)
        if ($cmd.Count -eq 0) { continue }
        $step = _TaskPlan-StepString -Command $cmd
        [void]$workflowSteps.Add($step)
        [void]$items.Add([pscustomobject]@{ kind="form_step"; label=$cp.label; route=$cp.route; safe_to_act=$true; live_required=$true; command=@($cmd); step=$step })
      }
    }
  }

  foreach ($clickLabel in $clickLabels) {
    $planArgs = @("-Quiet","macro","smart-plan","--label",$clickLabel)
    if ($match) { $planArgs += @("--match",$match) }
    if ($allowCdp) { $planArgs += "--allow-cdp" }
    if ($disableCdp) { $planArgs += "--no-cdp" }
    if ($cdpPageMatch) { $planArgs += @("--cdp-page-match",$cdpPageMatch) }
    if ($cdpPortRaw) { $planArgs += @("--cdp-port",$cdpPortRaw) }
    if ($includeOcr) { $planArgs += "--include-ocr" }
    if ($precisionPoints) { $planArgs += "--precision-points" }
    if ($precisionRadiusRaw) { $planArgs += @("--precision-radius",$precisionRadiusRaw) }
    if ($precisionStepRaw) { $planArgs += @("--precision-step",$precisionStepRaw) }
    if ($pointCacheTtlRaw) { $planArgs += @("--point-cache-ttl",$pointCacheTtlRaw) }
    $planArgs += "--json-only"
    $clickPlan = _InvokeTaskChildJson -ChildArgs $planArgs
    if (-not $clickPlan.json -or -not [bool]$clickPlan.json.safe_to_act) {
      [void]$errors.Add([pscustomobject]@{ code="click_plan_not_safe"; label=$clickLabel; exit=$clickPlan.exit; plan=$clickPlan.json })
      continue
    }
    $cmd = @(_TaskPlan-UnwrapCommand -Command $clickPlan.json.recommended_command)
    $step = _TaskPlan-StepString -Command $cmd
    [void]$workflowSteps.Add($step)
    [void]$items.Add([pscustomobject]@{ kind="click"; label=$clickLabel; route=$clickPlan.json.best_route; safe_to_act=$true; live_required=$true; command=@($cmd); step=$step; plan=$clickPlan.json })
  }

  foreach ($shortcut in $shortcuts) {
    if ([string]::IsNullOrWhiteSpace("$shortcut")) { continue }
    $cmd = @("macro","shortcut","--keys","$shortcut")
    $step = _TaskPlan-StepString -Command $cmd
    [void]$workflowSteps.Add($step)
    [void]$items.Add([pscustomobject]@{ kind="shortcut"; phase="post"; keys="$shortcut"; safe_to_act=$true; live_required=$true; command=@($cmd); step=$step })
  }

  if ($verifyLabel) {
    $cmd = @("macro","wait-label","--label",$verifyLabel,"--timeout-ms","$verifyTimeout")
    if ($match) { $cmd += @("--window",$match) }
    $step = _TaskPlan-StepString -Command $cmd
    [void]$workflowSteps.Add($step)
    [void]$items.Add([pscustomobject]@{ kind="verify_label"; label=$verifyLabel; safe_to_act=$true; live_required=$false; command=@($cmd); step=$step })
  }

  $wfArgs = @("--name",$(if ($name) { $name } else { "task" }))
  foreach ($s in @($workflowSteps)) { $wfArgs += @("--step",$s) }
  $workflowPlan = $null
  if ($workflowSteps.Count -gt 0) { $workflowPlan = _Build-WorkflowPlan -Rest $wfArgs }
  $safeToRun = ($workflowPlan -and [bool]$workflowPlan.safe_to_run -and $errors.Count -eq 0)
  $workflowRun = @("macro","workflow-run")
  if ($settleMsRaw) { $workflowRun += @("--settle-ms",$settleMsRaw) }
  if ($observeAfterStep -and -not $verifyAfterStep) { $workflowRun += "--observe-after-step" }
  if ($verifyAfterStep) { $workflowRun += "--verify-after-step" }
  if ($observeMatch) { $workflowRun += @("--observe-match",$observeMatch) }
  if ($verifyLabelAfterStep) { $workflowRun += @("--verify-label-after-step",$verifyLabelAfterStep) }
  if ($verifyLabelWindow) { $workflowRun += @("--verify-label-window",$verifyLabelWindow) }
  if ($verifyLabelTimeoutRaw) { $workflowRun += @("--verify-label-timeout-ms",$verifyLabelTimeoutRaw) }
  if ($verifyLabelIntervalRaw) { $workflowRun += @("--verify-label-interval-ms",$verifyLabelIntervalRaw) }
  if ($retryFailedRaw) { $workflowRun += @("--retry-failed-step",$retryFailedRaw) }
  if ($retryDelayRaw) { $workflowRun += @("--retry-delay-ms",$retryDelayRaw) }
  if ($retryLiveSteps) { $workflowRun += "--retry-live-steps" }
  foreach ($s in @($workflowSteps)) { $workflowRun += @("--step",$s) }
  $workflowDryRun = @("macro","workflow-run","--dry-run")
  if ($settleMsRaw) { $workflowDryRun += @("--settle-ms",$settleMsRaw) }
  if ($observeAfterStep -and -not $verifyAfterStep) { $workflowDryRun += "--observe-after-step" }
  if ($verifyAfterStep) { $workflowDryRun += "--verify-after-step" }
  if ($observeMatch) { $workflowDryRun += @("--observe-match",$observeMatch) }
  if ($verifyLabelAfterStep) { $workflowDryRun += @("--verify-label-after-step",$verifyLabelAfterStep) }
  if ($verifyLabelWindow) { $workflowDryRun += @("--verify-label-window",$verifyLabelWindow) }
  if ($verifyLabelTimeoutRaw) { $workflowDryRun += @("--verify-label-timeout-ms",$verifyLabelTimeoutRaw) }
  if ($verifyLabelIntervalRaw) { $workflowDryRun += @("--verify-label-interval-ms",$verifyLabelIntervalRaw) }
  if ($retryFailedRaw) { $workflowDryRun += @("--retry-failed-step",$retryFailedRaw) }
  if ($retryDelayRaw) { $workflowDryRun += @("--retry-delay-ms",$retryDelayRaw) }
  if ($retryLiveSteps) { $workflowDryRun += "--retry-live-steps" }
  foreach ($s in @($workflowSteps)) { $workflowDryRun += @("--step",$s) }

  $sw.Stop()
  $payload = [pscustomobject]@{
    schema = "cucp.task-plan/v1"
    status = if ($safeToRun) { "ok" } else { "partial" }
    name = $name
    app = $app
    match = $match
    elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
    safe_to_run = [bool]$safeToRun
    live_step_count = if ($workflowPlan) { [int]$workflowPlan.live_step_count } else { 0 }
    sensitive_step_count = if ($workflowPlan) { [int]$workflowPlan.sensitive_step_count } else { 0 }
    requires_sensitive_confirmation = if ($workflowPlan) { [bool]$workflowPlan.requires_sensitive_confirmation } else { $false }
    step_count = if ($workflowPlan) { [int]$workflowPlan.step_count } else { 0 }
    recommended_command = if ($workflowSteps.Count -gt 0) { [object[]]@($workflowRun) } else { $null }
    dry_run_command = if ($workflowSteps.Count -gt 0) { [object[]]@($workflowDryRun) } else { $null }
    run_options = [pscustomobject]@{
      settle_ms = $settleMsRaw
      observe_after_step = [bool]$observeAfterStep
      verify_after_step = [bool]$verifyAfterStep
      observe_match = $observeMatch
      verify_label_after_step = $verifyLabelAfterStep
      verify_label_window = $verifyLabelWindow
      verify_label_timeout_ms = $verifyLabelTimeoutRaw
      verify_label_interval_ms = $verifyLabelIntervalRaw
      retry_failed_step = $retryFailedRaw
      retry_delay_ms = $retryDelayRaw
      retry_live_steps = [bool]$retryLiveSteps
    }
    workflow_plan = $workflowPlan
    items = @($items)
    form_plan = $formPlan
    errors = @($errors)
    next_step = if ($safeToRun) { "Run dry_run_command first; run recommended_command with -AllowLiveControl only after user authorization when live_step_count > 0. If requires_sensitive_confirmation is true, add --confirm-sensitive only after explicit approval of that exact action." } else { "Resolve errors or unsafe embedded plans, then re-run task-plan." }
  }

  if ($Brief -and -not $jsonOnly) {
    [Console]::Out.WriteLine("$($payload.status) task-plan steps=$($payload.step_count) live=$($payload.live_step_count) errors=$($errors.Count) elapsed_ms=$($payload.elapsed_ms)")
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 18))
  }
  if ($safeToRun) { return 0 }
  return 2
}

function Invoke-MacroTaskRun {
  param([string[]]$Rest)
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  $dryRun = _Read-Switch -Rest $Rest -Name "--dry-run"
  $continueOnError = _Read-Switch -Rest $Rest -Name "--continue-on-error"
  $includePlan = _Read-Switch -Rest $Rest -Name "--include-plan"
  $confirmSensitive = _Read-Switch -Rest $Rest -Name "--confirm-sensitive"

  function _TaskRunPlanArgs {
    param([string[]]$InputArgs)
    $skip = @{
      "--json-only" = $true
      "--dry-run" = $true
      "--continue-on-error" = $true
      "--include-plan" = $true
      "--confirm-sensitive" = $true
    }
    $items = New-Object System.Collections.ArrayList
    foreach ($a in $InputArgs) {
      if ($skip.ContainsKey($a)) { continue }
      [void]$items.Add($a)
    }
    return @($items)
  }

  function _InvokeTaskRunChildJson {
    param([string[]]$ChildArgs)
    $rawLines = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @ChildArgs 2>&1
    $exitCode = $LASTEXITCODE
    $raw = (($rawLines | ForEach-Object { $_.ToString() }) -join "`n")
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json -ErrorAction Stop } catch { }
    return [pscustomobject]@{ exit=[int]$exitCode; raw=$raw; json=$obj }
  }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $planArgs = @("-Quiet","macro","task-plan") + @(_TaskRunPlanArgs -InputArgs $Rest) + @("--json-only")
  $planResult = _InvokeTaskRunChildJson -ChildArgs $planArgs
  $plan = $planResult.json
  if (-not $plan) {
    $sw.Stop()
    $payload = [pscustomobject]@{
      schema = "cucp.task-run/v1"
      status = "error"
      reason = "task_plan_unparseable"
      dry_run = [bool]$dryRun
      confirm_sensitive = [bool]$confirmSensitive
      executed = $false
      elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
      plan_exit = $planResult.exit
      plan_raw = $planResult.raw
    }
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 8))
    return 1
  }

  if (-not [bool]$plan.safe_to_run) {
    $sw.Stop()
    $payload = [pscustomobject]@{
      schema = "cucp.task-run/v1"
      status = "blocked"
      reason = "task_plan_not_safe"
      dry_run = [bool]$dryRun
      confirm_sensitive = [bool]$confirmSensitive
      executed = $false
      elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
      plan = if ($includePlan) { $plan } else { $null }
      plan_errors = @($plan.errors)
    }
    if ($Brief -and -not $jsonOnly) { [Console]::Out.WriteLine("blocked task-run reason=task_plan_not_safe errors=$($plan.errors.Count)") }
    else { [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 16)) }
    return 3
  }

  if (-not $dryRun -and [int]$plan.live_step_count -gt 0 -and -not $AllowLiveControl) {
    throw "macro task-run requires -AllowLiveControl when live steps are present"
  }

  $command = if ($dryRun) { @($plan.dry_run_command) } else { @($plan.recommended_command) }
  if ($command.Count -eq 0) {
    $sw.Stop()
    $payload = [pscustomobject]@{
      schema = "cucp.task-run/v1"
      status = "blocked"
      reason = "missing_recommended_command"
      dry_run = [bool]$dryRun
      confirm_sensitive = [bool]$confirmSensitive
      executed = $false
      elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
      plan = if ($includePlan) { $plan } else { $null }
    }
    if ($Brief -and -not $jsonOnly) { [Console]::Out.WriteLine("blocked task-run reason=missing_recommended_command") }
    else { [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 12)) }
    return 3
  }

  $childArgs = @("-Quiet")
  if (-not $dryRun -and [int]$plan.live_step_count -gt 0) { $childArgs += "-AllowLiveControl" }
  $childArgs += @($command)
  if ($continueOnError -and -not $dryRun) { $childArgs += "--continue-on-error" }
  if ($confirmSensitive -and -not $dryRun) { $childArgs += "--confirm-sensitive" }
  if ($includePlan) { $childArgs += "--include-plan" }
  $childArgs += "--json-only"

  $runSw = [System.Diagnostics.Stopwatch]::StartNew()
  $runResult = _InvokeTaskRunChildJson -ChildArgs $childArgs
  $runSw.Stop()
  $sw.Stop()
  $runStatus = if ($runResult.json -and $runResult.json.status) { "$($runResult.json.status)" } elseif ($runResult.exit -eq 0) { "ok" } else { "partial" }
  $status = if ($dryRun) {
    if ($runResult.exit -eq 0) { "ready" } else { "blocked" }
  } else {
    if ($runResult.exit -eq 0 -and ($runStatus -eq "ok" -or $runStatus -eq "ready")) { "ok" } elseif ($runResult.exit -eq 3) { "blocked" } else { "partial" }
  }
  $payload = [pscustomobject]@{
    schema = "cucp.task-run/v1"
    status = $status
    reason = if ($status -eq "ok" -or $status -eq "ready") { "" } else { "workflow_failed_or_blocked" }
    dry_run = [bool]$dryRun
    confirm_sensitive = [bool]$confirmSensitive
    executed = (-not $dryRun -and $runResult.exit -ne 3)
    elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
    task_plan = if ($includePlan -or $dryRun) { $plan } else { $null }
    workflow_exit = [int]$runResult.exit
    workflow_elapsed_ms = [int]$runSw.Elapsed.TotalMilliseconds
    workflow_failure_summary = if ($runResult.json) { $runResult.json.failure_summary } else { $null }
    next_action = if ($runResult.json -and $runResult.json.next_action) { "$($runResult.json.next_action)" } elseif ($status -eq "partial" -or $status -eq "blocked") { "Inspect workflow_result and re-ground with macro windows/list-affordances before retrying." } else { "" }
    workflow_result = $runResult.json
    workflow_raw = if ($runResult.json) { $null } else { $runResult.raw }
  }
  try { _Trajectory-Append -Kind "task-run" -Payload @{ status=$status; dry_run=[bool]$dryRun; workflow_exit=[int]$runResult.exit; elapsed_ms=[int]$sw.Elapsed.TotalMilliseconds } } catch { }
  if ($Brief -and -not $jsonOnly) {
    [Console]::Out.WriteLine("$status task-run dry_run=$dryRun workflow_exit=$($runResult.exit) elapsed_ms=$($payload.elapsed_ms)")
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 18))
  }
  if ($status -eq "ok" -or $status -eq "ready") { return 0 }
  if ($status -eq "blocked") { return 3 }
  return 2
}

function Invoke-MacroFormPlan {
  param([string[]]$Rest)
  $fieldSpecs = @(_Read-AllOptValues -Rest $Rest -Name "--field")
  $sendLabel = _Read-OptValue -Rest $Rest -Name "--send-label"
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $window = _Read-OptValue -Rest $Rest -Name "--window"
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  $allowCdp = _Read-Switch -Rest $Rest -Name "--allow-cdp"
  $disableCdp = _Read-Switch -Rest $Rest -Name "--no-cdp"
  $cdpPageMatch = _Read-OptValue -Rest $Rest -Name "--cdp-page-match"
  $cdpPortRaw = _Read-OptValue -Rest $Rest -Name "--cdp-port"
  $clearFirst = _Read-Switch -Rest $Rest -Name "--clear-first"
  $includeOcr = _Read-Switch -Rest $Rest -Name "--include-ocr"
  $precisionPoints = (_Read-Switch -Rest $Rest -Name "--precision-points") -or (_Read-Switch -Rest $Rest -Name "--point-plan")
  $precisionRadiusRaw = _Read-OptValue -Rest $Rest -Name "--precision-radius"
  $precisionStepRaw = _Read-OptValue -Rest $Rest -Name "--precision-step"
  $pointCacheTtlRaw = _Read-OptValue -Rest $Rest -Name "--point-cache-ttl"
  if (-not $pointCacheTtlRaw) { $pointCacheTtlRaw = _Read-OptValue -Rest $Rest -Name "--cache-ttl" }
  if (-not $match) { $match = $window }
  if ($fieldSpecs.Count -eq 0 -and -not $sendLabel) { throw "macro form-plan requires --field `"Label=Value`" and/or --send-label" }

  function _InvokeChildSmartPlanJson {
    param([string[]]$PlanArgs)
    $args = @("-Quiet","macro","smart-plan") + $PlanArgs + @("--json-only")
    $rawLines = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args 2>&1
    $exitCode = $LASTEXITCODE
    $raw = (($rawLines | ForEach-Object { $_.ToString() }) -join "`n")
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json -ErrorAction Stop } catch { }
    return [pscustomobject]@{
      exit = [int]$exitCode
      raw = $raw
      json = $obj
    }
  }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $steps = New-Object System.Collections.ArrayList
  $errors = New-Object System.Collections.ArrayList
  $index = 0

  foreach ($spec in $fieldSpecs) {
    $index++
    $rawSpec = "$spec"
    $eq = $rawSpec.IndexOf("=")
    if ($eq -le 0) {
      [void]$errors.Add([pscustomobject]@{
        code = "bad_field_spec"
        message = "field spec must be Label=Value"
        field = $rawSpec
      })
      continue
    }
    $fieldLabel = $rawSpec.Substring(0, $eq).Trim()
    $fieldValue = $rawSpec.Substring($eq + 1)
    if (-not $fieldLabel) {
      [void]$errors.Add([pscustomobject]@{
        code = "empty_field_label"
        message = "field label is empty"
        field = $rawSpec
      })
      continue
    }

    $planArgs = @("--label",$fieldLabel,"--type-text",$fieldValue)
    if ($match) { $planArgs += @("--match",$match) }
    if ($allowCdp) { $planArgs += "--allow-cdp" }
    if ($disableCdp) { $planArgs += "--no-cdp" }
    if ($cdpPageMatch) { $planArgs += @("--cdp-page-match",$cdpPageMatch) }
    if ($cdpPortRaw) { $planArgs += @("--cdp-port",$cdpPortRaw) }
    if ($clearFirst) { $planArgs += "--clear-first" }

    $r = _InvokeChildSmartPlanJson -PlanArgs $planArgs
    $safe = $false
    if ($r.json) { $safe = [bool]$r.json.safe_to_act }
    [void]$steps.Add([pscustomobject]@{
      index = $index
      kind = "type"
      label = $fieldLabel
      value_length = $fieldValue.Length
      exit = $r.exit
      safe_to_act = $safe
      best_route = if ($r.json) { $r.json.best_route } else { $null }
      recommended_command = if ($r.json) { $r.json.recommended_command } else { $null }
      plan = $r.json
      raw = if ($r.json) { $null } else { $r.raw }
    })
  }

  if ($sendLabel) {
    $index++
    $planArgs = @("--label",$sendLabel)
    if ($match) { $planArgs += @("--match",$match) }
    if ($allowCdp) { $planArgs += "--allow-cdp" }
    if ($disableCdp) { $planArgs += "--no-cdp" }
    if ($cdpPageMatch) { $planArgs += @("--cdp-page-match",$cdpPageMatch) }
    if ($cdpPortRaw) { $planArgs += @("--cdp-port",$cdpPortRaw) }
    if ($includeOcr) { $planArgs += "--include-ocr" }
    if ($precisionPoints) { $planArgs += "--precision-points" }
    if ($precisionRadiusRaw) { $planArgs += @("--precision-radius",$precisionRadiusRaw) }
    if ($precisionStepRaw) { $planArgs += @("--precision-step",$precisionStepRaw) }
    if ($pointCacheTtlRaw) { $planArgs += @("--point-cache-ttl",$pointCacheTtlRaw) }

    $r = _InvokeChildSmartPlanJson -PlanArgs $planArgs
    $safe = $false
    if ($r.json) { $safe = [bool]$r.json.safe_to_act }
    [void]$steps.Add([pscustomobject]@{
      index = $index
      kind = "click"
      label = $sendLabel
      value_length = 0
      exit = $r.exit
      safe_to_act = $safe
      best_route = if ($r.json) { $r.json.best_route } else { $null }
      recommended_command = if ($r.json) { $r.json.recommended_command } else { $null }
      plan = $r.json
      raw = if ($r.json) { $null } else { $r.raw }
    })
  }

  $safeSteps = @($steps | Where-Object { $_.safe_to_act })
  $commandPlan = @($steps | ForEach-Object {
    [pscustomobject]@{
      index = $_.index
      kind = $_.kind
      label = $_.label
      safe_to_act = [bool]$_.safe_to_act
      route = $_.best_route
      command = $_.recommended_command
    }
  })
  $unsafeSteps = @($steps | Where-Object { -not $_.safe_to_act } | ForEach-Object {
    [pscustomobject]@{
      index = $_.index
      kind = $_.kind
      label = $_.label
      route = $_.best_route
      exit = $_.exit
    }
  })
  $allSafe = ($steps.Count -gt 0 -and $safeSteps.Count -eq $steps.Count -and $errors.Count -eq 0)
  $sw.Stop()
  $payload = [pscustomobject]@{
    schema = "cucp.form-plan/v1"
    status = if ($allSafe) { "ok" } else { "partial" }
    match = $match
    field_count = $fieldSpecs.Count
    send_label = $sendLabel
    safe_to_act = [bool]$allSafe
    step_count = $steps.Count
    safe_step_count = $safeSteps.Count
    elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
    command_plan = $commandPlan
    unsafe_steps = $unsafeSteps
    steps = @($steps)
    errors = @($errors)
    next_step = if ($allSafe) { "Run each recommended_command in order with -AllowLiveControl only after user authorization; verify after each step." } else { "Resolve unsafe steps by narrowing labels/window, enabling --allow-cdp, or inspecting each embedded smart-plan." }
  }

  if ($Brief -and -not $jsonOnly) {
    if ($allSafe) {
      [Console]::Out.WriteLine("ok form-plan steps=$($steps.Count) safe=$($safeSteps.Count) match='$match' elapsed_ms=$($payload.elapsed_ms)")
    } else {
      [Console]::Out.WriteLine("partial form-plan steps=$($steps.Count) safe=$($safeSteps.Count) errors=$($errors.Count) match='$match' elapsed_ms=$($payload.elapsed_ms)")
    }
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 16))
  }
  if ($allSafe) { return 0 }
  return 2
}

function Invoke-MacroFormRun {
  param([string[]]$Rest)
  $jsonOnly = _Read-Switch -Rest $Rest -Name "--json-only"
  $dryRun = _Read-Switch -Rest $Rest -Name "--dry-run"
  $continueOnError = _Read-Switch -Rest $Rest -Name "--continue-on-error"
  $includePlan = _Read-Switch -Rest $Rest -Name "--include-plan"
  $confirmSensitive = _Read-Switch -Rest $Rest -Name "--confirm-sensitive"
  if (-not $dryRun -and -not $AllowLiveControl) { throw "macro form-run requires -AllowLiveControl" }

  function _PlanArgsForFormRun {
    param([string[]]$InputArgs)
    $skip = @{
      "--json-only" = $true
      "--dry-run" = $true
      "--continue-on-error" = $true
      "--include-plan" = $true
      "--confirm-sensitive" = $true
    }
    $items = New-Object System.Collections.ArrayList
    foreach ($a in $InputArgs) {
      if ($skip.ContainsKey($a)) { continue }
      [void]$items.Add($a)
    }
    return @($items)
  }

  function _InvokeSelfJson {
    param([string[]]$ChildArgs)
    $rawLines = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @ChildArgs 2>&1
    $exitCode = $LASTEXITCODE
    $raw = (($rawLines | ForEach-Object { $_.ToString() }) -join "`n")
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json -ErrorAction Stop } catch { }
    return [pscustomobject]@{
      exit = [int]$exitCode
      raw = $raw
      json = $obj
    }
  }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $planArgs = @("-Quiet","macro","form-plan") + @(_PlanArgsForFormRun -InputArgs $Rest) + @("--json-only")
  $planResult = _InvokeSelfJson -ChildArgs $planArgs
  $plan = $planResult.json
  if (-not $plan) {
    $sw.Stop()
    $payload = [pscustomobject]@{
      schema = "cucp.form-run/v1"
      status = "error"
      reason = "plan_unparseable"
      dry_run = [bool]$dryRun
      confirm_sensitive = [bool]$confirmSensitive
      elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
      plan_exit = $planResult.exit
      plan_raw = $planResult.raw
      steps = @()
    }
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 8))
    return 1
  }

  if (-not [bool]$plan.safe_to_act) {
    $sw.Stop()
    $payload = [pscustomobject]@{
      schema = "cucp.form-run/v1"
      status = "blocked"
      reason = "plan_not_safe"
      dry_run = [bool]$dryRun
      confirm_sensitive = [bool]$confirmSensitive
      safe_to_act = $false
      executed_count = 0
      failed_count = 0
      elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
      plan_exit = $planResult.exit
      unsafe_steps = @($plan.unsafe_steps)
      plan_errors = @($plan.errors)
      plan = if ($includePlan) { $plan } else { $null }
      steps = @()
    }
    if ($Brief -and -not $jsonOnly) {
      [Console]::Out.WriteLine("blocked form-run reason=plan_not_safe safe=$($plan.safe_step_count)/$($plan.step_count) elapsed_ms=$($payload.elapsed_ms)")
    } else {
      [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 16))
    }
    return 3
  }

  if ($dryRun) {
    $sw.Stop()
    $payload = [pscustomobject]@{
      schema = "cucp.form-run/v1"
      status = "ready"
      reason = "dry_run"
      dry_run = $true
      confirm_sensitive = [bool]$confirmSensitive
      safe_to_act = $true
      executed_count = 0
      failed_count = 0
      elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
      command_plan = @($plan.command_plan)
      plan = if ($includePlan) { $plan } else { $null }
      steps = @()
    }
    if ($Brief -and -not $jsonOnly) {
      [Console]::Out.WriteLine("ready form-run dry-run steps=$($plan.step_count) elapsed_ms=$($payload.elapsed_ms)")
    } else {
      [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 16))
    }
    return 0
  }

  $sensitiveSteps = @($plan.command_plan | ForEach-Object {
    $cmd = @($_.command)
    $macroName = if ($cmd.Count -ge 2 -and $cmd[0] -eq "macro") { "$($cmd[1])" } else { "" }
    $safetyText = ((@($cmd) + @($_.kind, $_.label)) -join " ")
    $safety = _Classify-SafetyFromText -Text $safetyText -MacroName $macroName
    if ($safety.requires_explicit_confirmation) {
      [pscustomobject]@{
        index = $_.index
        kind = $_.kind
        label = $_.label
        macro = $macroName
        command = @($cmd)
        risk_level = $safety.risk_level
        risk_score = [int]$safety.risk_score
        categories = @($safety.categories)
        recommended_action = $safety.recommended_action
      }
    }
  })
  if ($sensitiveSteps.Count -gt 0 -and -not $confirmSensitive) {
    $sw.Stop()
    $payload = [pscustomobject]@{
      schema = "cucp.form-run/v1"
      status = "blocked"
      reason = "sensitive_action_requires_confirmation"
      dry_run = $false
      confirm_sensitive = [bool]$confirmSensitive
      safe_to_act = $false
      executed_count = 0
      failed_count = 0
      sensitive_step_count = [int]$sensitiveSteps.Count
      safety_issues = @($sensitiveSteps)
      confirmation_flag = "--confirm-sensitive"
      elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
      plan = if ($includePlan) { $plan } else { $null }
      steps = @()
      next_action = "Re-run with --confirm-sensitive only if the user explicitly approved these exact sensitive form actions."
    }
    if ($Brief -and -not $jsonOnly) {
      [Console]::Out.WriteLine("blocked form-run reason=sensitive_action_requires_confirmation sensitive=$($sensitiveSteps.Count)")
    } else {
      [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 16))
    }
    return 3
  }

  $results = New-Object System.Collections.ArrayList
  $executed = 0
  $failed = 0
  foreach ($step in @($plan.command_plan)) {
    $cmd = @($step.command)
    $stepSw = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not [bool]$step.safe_to_act -or $cmd.Count -eq 0 -or $cmd[0] -ne "macro") {
      $stepSw.Stop()
      $failed++
      [void]$results.Add([pscustomobject]@{
        index = $step.index
        kind = $step.kind
        label = $step.label
        route = $step.route
        status = "blocked"
        reason = "unsafe_or_invalid_command"
        exit = 3
        elapsed_ms = [int]$stepSw.Elapsed.TotalMilliseconds
        command = $cmd
        result = $null
        raw = $null
      })
      if (-not $continueOnError) { break }
      continue
    }

    $runArgs = @("-AllowLiveControl","-Quiet") + $cmd
    $r = _InvokeSelfJson -ChildArgs $runArgs
    $stepSw.Stop()
    $executed++
    if ($r.exit -ne 0) { $failed++ }
    [void]$results.Add([pscustomobject]@{
      index = $step.index
      kind = $step.kind
      label = $step.label
      route = $step.route
      status = if ($r.exit -eq 0) { "ok" } else { "partial" }
      reason = if ($r.json -and $r.json.reason) { "$($r.json.reason)" } elseif ($r.exit -eq 0) { "" } else { "command_failed" }
      exit = $r.exit
      elapsed_ms = [int]$stepSw.Elapsed.TotalMilliseconds
      command = $cmd
      result = $r.json
      raw = if ($r.json) { $null } else { $r.raw }
    })
    if ($r.exit -ne 0 -and -not $continueOnError) { break }
  }

  $sw.Stop()
  $status = if ($failed -eq 0 -and $executed -eq @($plan.command_plan).Count) { "ok" } else { "partial" }
  $payload = [pscustomobject]@{
    schema = "cucp.form-run/v1"
    status = $status
    reason = if ($status -eq "ok") { "" } else { "step_failed_or_stopped" }
    dry_run = $false
    confirm_sensitive = [bool]$confirmSensitive
    safe_to_act = $true
    executed_count = $executed
    failed_count = $failed
    total_steps = @($plan.command_plan).Count
    elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
    plan_elapsed_ms = [int]$plan.elapsed_ms
    command_plan = @($plan.command_plan)
    plan = if ($includePlan) { $plan } else { $null }
    steps = @($results)
  }
  try {
    _Trajectory-Append -Kind "form-run" -Payload @{
      status = $status
      executed_count = $executed
      failed_count = $failed
      total_steps = @($plan.command_plan).Count
      elapsed_ms = [int]$sw.Elapsed.TotalMilliseconds
    }
  } catch { }
  if ($Brief -and -not $jsonOnly) {
    [Console]::Out.WriteLine("$status form-run executed=$executed failed=$failed total=$($payload.total_steps) elapsed_ms=$($payload.elapsed_ms)")
  } else {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 16))
  }
  if ($status -eq "ok") { return 0 }
  return 2
}

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
  $ocrMatch = _Read-OptValue -Rest $Rest -Name "--ocr-match"
  if (-not $ocrMatch) { $ocrMatch = "contains" }
  # v0.9.0: 클릭 후 화면 변화 검증
  $verifyScreen = _Read-Switch -Rest $Rest -Name "--verify-screen-changed"
  $verifyWaitMs = [int](_Read-OptValue -Rest $Rest -Name "--verify-wait-ms")
  # v1.0.0: 화면 변화 없으면 cascade 한 번 더 (retry-on-no-change). 기본 0 (off).
  # verify-screen 활성화 시에만 의미가 있음.
  $retryOnNoChange = [int](_Read-OptValue -Rest $Rest -Name "--retry-on-no-change")
  # v1.1.0: history learning. default ON. --no-history 로 비활성.
  $disableHistory = _Read-Switch -Rest $Rest -Name "--no-history"
  $preferHistory = _Read-Switch -Rest $Rest -Name "--prefer-history"
  $ocrMaxCandidates = [int](_Read-OptValue -Rest $Rest -Name "--ocr-max-candidates")
  $disableCdp = _Read-Switch -Rest $Rest -Name "--no-cdp"
  $allowCdp = _Read-Switch -Rest $Rest -Name "--allow-cdp"
  $cdpPageMatch = _Read-OptValue -Rest $Rest -Name "--cdp-page-match"
  $cdpPortRaw = _Read-OptValue -Rest $Rest -Name "--cdp-port"
  $cdpPort = [int]$cdpPortRaw
  $precisionPoints = (_Read-Switch -Rest $Rest -Name "--precision-points") -or (_Read-Switch -Rest $Rest -Name "--point-plan")
  $precisionRadiusRaw = _Read-OptValue -Rest $Rest -Name "--precision-radius"
  if (-not $precisionRadiusRaw) { $precisionRadiusRaw = _Read-OptValue -Rest $Rest -Name "--point-radius" }
  $precisionStepRaw = _Read-OptValue -Rest $Rest -Name "--precision-step"
  if (-not $precisionStepRaw) { $precisionStepRaw = _Read-OptValue -Rest $Rest -Name "--point-step" }
  $pointCacheTtlRaw = _Read-OptValue -Rest $Rest -Name "--point-cache-ttl"
  if (-not $pointCacheTtlRaw) { $pointCacheTtlRaw = _Read-OptValue -Rest $Rest -Name "--cache-ttl" }
  $precisionRadius = 6
  $precisionStep = 2
  $pointCacheTtl = $CacheSeconds
  if (-not $label) { throw "macro smart-click requires --label" }
  if ($verifyTimeout -le 0) { $verifyTimeout = 3000 }
  if ($verifyWaitMs -le 0) { $verifyWaitMs = 500 }
  if ($retryOnNoChange -lt 0) { $retryOnNoChange = 0 }
  if ($ocrMaxCandidates -le 0) { $ocrMaxCandidates = 4 }
  if ($ocrMaxCandidates -gt 8) { $ocrMaxCandidates = 8 }
  if ($cdpPort -le 0) { $cdpPort = 9222 }
  if ($null -ne $precisionRadiusRaw -and "$precisionRadiusRaw" -ne "") { $precisionRadius = [int]$precisionRadiusRaw }
  if ($null -ne $precisionStepRaw -and "$precisionStepRaw" -ne "") { $precisionStep = [int]$precisionStepRaw }
  if ($null -ne $pointCacheTtlRaw -and "$pointCacheTtlRaw" -ne "") { $pointCacheTtl = [int]$pointCacheTtlRaw }
  if ($precisionRadius -lt 0) { $precisionRadius = 0 }
  if ($precisionRadius -gt 64) { $precisionRadius = 64 }
  if ($precisionStep -le 0) { $precisionStep = 2 }
  if ($precisionStep -gt 16) { $precisionStep = 16 }
  if ($pointCacheTtl -lt 0) { $pointCacheTtl = 0 }
  $cdpStageEnabled = (-not $disableCdp) -and ($allowCdp -or $cdpPageMatch -or $cdpPortRaw)

  # v1.1.0: 과거 같은 (label, match) 시도에서 가장 자주 성공한 strategy 조회
  # null 이면 기본 cascade. string 이면 그 strategy 부터 시도.
  $hintedStrategy = $null
  if (-not $disableHistory) {
    try { $hintedStrategy = _History-PickBestStrategy -Label $label -Match $match -LookbackN 5 } catch { }
  }
  if ($hintedStrategy -and -not $preferHistory) {
    # OCR/vision fallback 성공 이력이 fast UIA 경로를 건너뛰지 않게 기본값은 보수적으로 둔다.
    $slowHistoryHints = @("uia_precision_point","fusion_uia_invoke","fusion_coord","ocr_text","vision_precise")
    if ($slowHistoryHints -contains $hintedStrategy) { $hintedStrategy = $null }
  }

  # cascade stage gates — hint 가 있으면 그 stage 만 활성화, 없으면 모든 stage 활성.
  # 미스매치/실패 시 모든 stage 활성으로 폴백 (안전).
  $tryStage0 = $true   # cdp_smart_click
  $tryStage1 = $true   # uia_pattern
  $tryStage2 = $true   # uia_coord
  $tryStage3 = $true   # icon_find
  $tryStage4 = $true   # fusion_uia_invoke / fusion_coord
  $tryStage5 = $true   # ocr_text
  $tryStage6 = $true   # vision_precise
  if ($hintedStrategy) {
    # hint 매핑 — 그 stage 만 활성화. 실패하면 cascade 전체 활성으로 fallback.
    $tryStage0 = ($hintedStrategy -eq "cdp_smart_click")
    $tryStage1 = ($hintedStrategy -eq "uia_pattern")
    $tryStage2 = ($hintedStrategy -eq "uia_coord" -or $hintedStrategy -eq "uia_precision_point")
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

  # Stage 0: CDP/DOM 직접 클릭 (웹/Electron 앱에서 가장 빠르고 좌표 무관)
  if ($rc -ne 0 -and $tryStage0 -and $cdpStageEnabled) {
    try {
      if (Test-CdpPortQuick -Port $cdpPort -TimeoutMs 120) {
        $cdpArgs = @("-Action","cdp-smart-click","-CdpText",$label,"-CdpPort","$cdpPort")
        if ($cdpPageMatch) { $cdpArgs += @("-CdpPageMatch", $cdpPageMatch) }
        elseif ($match) { $cdpArgs += @("-CdpPageMatch", $match) }
        $r0 = Invoke-NativeHelper -ArgList $cdpArgs
        if ($r0.Json -and $r0.Json.status -eq "ok") {
          $strategy = "cdp_smart_click"
          $rc = 0
          $resultLine = "ok smart-click '$label' strategy=cdp_smart_click matched='$($r0.Json.matched_text)' score=$($r0.Json.score) tag=$($r0.Json.tag_name) mouse_moved=False"
        }
      }
    } catch { }
  }

  # Stage 1: UIA Pattern 직통 (가장 안정적)
  if ($rc -ne 0 -and $tryStage1) {
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
    $precisionAttempted = $false
    if ($precisionPoints) {
      try {
        $findArgs2 = @("-Action","uia-find","-Label",$label)
        if ($match) { $findArgs2 += @("-Match", $match) }
        if ($role)  { $findArgs2 += @("-Role", $role) }
        $r2Find = Invoke-NativeHelper -ArgList $findArgs2
        if ($r2Find.Json -and $r2Find.Json.status -eq "ok" -and -not [bool]$r2Find.Json.ambiguous -and $r2Find.Json.top -and $r2Find.Json.top.click_point) {
          $pt2 = $r2Find.Json.top.click_point
          if ($pt2.x -and $pt2.y) {
            $precisionAttempted = $true
            $cpRest = @(
              "--x","$($pt2.x)",
              "--y","$($pt2.y)",
              "--refine","uia-safe",
              "--micro-refine",
              "--precision-radius","$precisionRadius",
              "--precision-step","$precisionStep",
              "--cache-ttl","$pointCacheTtl"
            )
            if ($match) { $cpRest += @("--target-match",$match) }
            $oldOut2 = [Console]::Out
            $sb2 = New-Object System.IO.StringWriter
            [Console]::SetOut($sb2)
            $cpExit = 1
            try {
              $cpExit = Invoke-MacroClickPoint -Rest $cpRest
            } finally {
              [Console]::SetOut($oldOut2)
            }
            $cpRaw = $sb2.ToString().Trim()
            if ($cpExit -eq 0) {
              $strategy = "uia_precision_point"
              $rc = 0
              $resultLine = "ok smart-click '$label' strategy=uia_precision_point @($($pt2.x),$($pt2.y)) micro_refine=True cache_ttl=$pointCacheTtl mouse_moved=True"
            }
          }
        }
      } catch { }
    }
    if ($rc -ne 0 -and -not $precisionAttempted) {
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
        $iconClickArgs = @("-Action","click","-X","$cx","-Y","$cy","-Button","left","-ClickRefine","uia-safe")
        if ($match) { $iconClickArgs += @("-TargetMatch", $match) }
        $r3 = Invoke-NativeHelper -ArgList $iconClickArgs
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
      $invokeArgs = @("-Action","ocr-uia-invoke","-OcrText",$label,"-OcrMatch",$ocrMatch,"-OcrMaxCandidates","$ocrMaxCandidates")
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
        $clickArgs = @("-Action","click","-X","$fcx","-Y","$fcy","-Button","left","-ClickRefine","uia-safe")
        if ($match) { $clickArgs += @("-TargetMatch", $match) }
        $rFc = Invoke-NativeHelper -ArgList $clickArgs
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
      $ocrArgs = @("-Action","ocr-find-text","-OcrText",$label,"-OcrMatch",$ocrMatch,"-OcrMaxCandidates","$ocrMaxCandidates")
      if ($match) { $ocrArgs += @("-Match", $match) }
      if ($ocrLang) { $ocrArgs += @("-OcrLanguage", $ocrLang) }
      $rOcr = Invoke-NativeHelper -ArgList $ocrArgs
      if ($rOcr.Json -and $rOcr.Json.status -eq "ok" -and $rOcr.Json.top -and [int]$rOcr.Json.top.score -ge 70) {
        $oTop = $rOcr.Json.top
        $ocx = [int]$oTop.cx; $ocy = [int]$oTop.cy
        $clickArgs = @("-Action","click","-X","$ocx","-Y","$ocy","-Button","left","-ClickRefine","uia-safe")
        if ($match) { $clickArgs += @("-TargetMatch", $match) }
        $rOcrClick = Invoke-NativeHelper -ArgList $clickArgs
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
        $rRetryArgs = @("-Action","ocr-uia-invoke","-OcrText",$label,"-OcrMatch",$ocrMatch,"-OcrMaxCandidates","$ocrMaxCandidates")
        if ($match) { $rRetryArgs += @("-Match", $match) }
        if ($ocrLang) { $rRetryArgs += @("-OcrLanguage", $ocrLang) }
        $rRetry2 = Invoke-NativeHelper -ArgList $rRetryArgs
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
      $tryStage0 = $true; $tryStage1 = $true; $tryStage2 = $true; $tryStage3 = $true
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
        $invokeArgs = @("-Action","ocr-uia-invoke","-OcrText",$label,"-OcrMatch",$ocrMatch,"-OcrMaxCandidates","$ocrMaxCandidates")
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

# macro ocr-find-text --text <s> [--match contains|exact|prefix|fuzzy] [--region x,y,w,h]
#                     [--path <png>] [--target-match <window>] [--language ko] [--max-candidates N]
# 화면(또는 이미지)에서 텍스트 위치 찾기. read-only.
# 출력: top 후보의 (cx,cy) 클릭 좌표 + score
function Invoke-MacroOcrFindText {
  param([string[]]$Rest)
  $text = _Read-OptValue -Rest $Rest -Name "--text"
  $match = _Read-OptValue -Rest $Rest -Name "--match"
  $region = _Read-OptValue -Rest $Rest -Name "--region"
  $path = _Read-OptValue -Rest $Rest -Name "--path"
  $targetMatch = _Read-OptValue -Rest $Rest -Name "--target-match"
  $lang = _Read-OptValue -Rest $Rest -Name "--language"
  $maxN = [int](_Read-OptValue -Rest $Rest -Name "--max-candidates")
  if (-not $text) { throw "macro ocr-find-text requires --text" }
  if (-not $match) { $match = "contains" }
  $args = @("-Action","ocr-find-text","-OcrText",$text,"-OcrMatch",$match)
  if ($maxN -gt 0) { $args += @("-OcrMaxCandidates","$maxN") }
  if ($lang) { $args += @("-OcrLanguage", $lang) }
  if ($path) { $args += @("-OcrPath", $path) }
  elseif ($targetMatch) { $args += @("-Match", $targetMatch) }
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

# macro ocr-click --text <s> [--match contains|exact|prefix|fuzzy] [--region x,y,w,h]
#                 [--button left|right|double] [--language ko] [--min-score 70] [--target-match <window>]
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
  $targetMatch = _Read-OptValue -Rest $Rest -Name "--target-match"
  $minScore = [int](_Read-OptValue -Rest $Rest -Name "--min-score")
  if (-not $text) { throw "macro ocr-click requires --text" }
  if (-not $match) { $match = "contains" }
  if (-not $btn) { $btn = "left" }
  if ($minScore -le 0) { $minScore = 70 }

  # Stage A: OCR 좌표 찾기 (read-only)
  $findArgs = @("-Action","ocr-find-text","-OcrText",$text,"-OcrMatch",$match,"-OcrMaxCandidates","8")
  if ($lang) { $findArgs += @("-OcrLanguage", $lang) }
  if ($targetMatch) { $findArgs += @("-Match", $targetMatch) }
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
  $clickArgs = @("-Action","click","-X","$cx","-Y","$cy","-Button",$btn,"-ClickRefine","uia-safe")
  if ($targetMatch) { $clickArgs += @("-TargetMatch", $targetMatch) }
  $rClick = Invoke-NativeHelper -ArgList $clickArgs
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

# macro ocr-uia-fuse --text <s> [--match contains|exact|prefix|fuzzy] [--match-window <s>]
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

# macro ocr-uia-invoke --text <s> [--match contains|exact|prefix|fuzzy] [--match-window <s>]
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
$Script:AnchorHistoryFile = Join-Path $Script:AuditDir "coord-anchor-history.ndjson"
$Script:AnchorHistoryMax = 500
$Script:AppStrategyFile = Join-Path $Script:AuditDir "app-strategy-history.ndjson"

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
      Get-ChildItem -LiteralPath $Script:CacheDir -Filter "point-plan-*.json" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
      Write-Notice -Level "OK" -Message "관찰/포인트 캐시를 비웠습니다."
      return 0
    }
    "info" {
      $cacheCount = (Get-ChildItem -LiteralPath $Script:CacheDir -Filter "appshot-*.json" -ErrorAction SilentlyContinue).Count
      $pointPlanCacheCount = (Get-ChildItem -LiteralPath $Script:CacheDir -Filter "point-plan-*.json" -ErrorAction SilentlyContinue).Count
      $logSize = if (Test-Path $Script:WrapperLog) { (Get-Item $Script:WrapperLog).Length } else { 0 }
      $hsStatus = $null
      try { $hsStatus = Get-HelperServerStatus } catch { $hsStatus = $null }
      $info = [pscustomobject]@{
        cache_dir = $Script:CacheDir
        audit_dir = $Script:AuditDir
        cache_files = $cacheCount
        point_plan_cache_files = $pointPlanCacheCount
        log_path = $Script:WrapperLog
        log_size_bytes = $logSize
        cli_path = $Script:CliPath
        task_card_path = $Script:TaskCardPath
        task_card_exists = [bool](Test-Path -LiteralPath $Script:TaskCardPath)
        cache_seconds = $CacheSeconds
        helper_server = $hsStatus
      }
      [Console]::Out.WriteLine(($info | ConvertTo-Json -Depth 6))
      return 0
    }
    "start-helper" {
      # v1.6.0: helper persistent server spawn (idempotent)
      $idleStr = _Read-OptValue -Rest $Rest -Name "--idle-timeout-ms"
      $idleMs = 60000
      if ($idleStr) { try { $idleMs = [int]$idleStr } catch { $idleMs = 60000 } }
      $r = Start-HelperServer -IdleTimeoutMs $idleMs
      if ($Brief) {
        if ($r.status -eq "ok") {
          $reused = if ($r.reused) { "reused" } else { "spawned" }
          [Console]::Out.WriteLine("ok session start-helper $reused pid=$($r.pid) pipe=$($r.pipe_name)")
        } else {
          [Console]::Out.WriteLine("error session start-helper reason=$($r.reason)")
        }
      } else {
        $payload = [ordered]@{ schema = "cucp.helper-server-start/v1" }
        foreach ($p in $r.PSObject.Properties) { $payload[$p.Name] = $p.Value }
        [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 6))
      }
      if ($r.status -eq "ok") { return 0 } else { return 1 }
    }
    "stop-helper" {
      $force = _Read-Switch -Rest $Rest -Name "--force"
      $r = Stop-HelperServer -Force:$force
      if ($Brief) {
        [Console]::Out.WriteLine("ok session stop-helper stopped_pid=$($r.stopped_pid) forced=$($r.forced)")
      } else {
        $payload = [ordered]@{ schema = "cucp.helper-server-stop/v1" }
        foreach ($p in $r.PSObject.Properties) { $payload[$p.Name] = $p.Value }
        [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 6))
      }
      return 0
    }
    "helper-status" {
      $r = Get-HelperServerStatus
      if ($Brief) {
        if ($r.alive) {
          [Console]::Out.WriteLine("ok session helper-status alive pid=$($r.pid) uptime_s=$($r.uptime_s) requests=$($r.request_count)")
        } else {
          [Console]::Out.WriteLine("ok session helper-status not_running")
        }
      } else {
        [Console]::Out.WriteLine(($r | ConvertTo-Json -Depth 6))
      }
      return 0
    }
    default {
      Write-Notice -Level "ERROR" -Message "session 하위 명령: clear-cache, info, start-helper, stop-helper, helper-status"
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
  Write-Host "  macro task-card          open|show|ensure|save|path|clear   (XG5000/XP-Builder context card)"
  Write-Host "  macro vision-find        --describe <text> [--screenshot <path>] [--model <name>] [--timeout-ms <n>]"
  Write-Host "  macro vision-click       --describe <text> [--window <title>] [--verify-label <text>] [--verify-timeout-ms <n>] [--model <name>]"
  Write-Host "  macro metrics            (operational counters + click/cache rates)"
  Write-Host "  macro perf               [--iters <n>] [--json-only] [--quick] [--include-live-ish]   (timing min/avg/max ms)"
  Write-Host "  macro health-detail      [--json-only]   (per-component health: node/cli/helper/uia/codex/audit)"
  Write-Host "  macro health-quick       [--json-only]   (lightweight: node/cli/audit/win32 + temp pressure + recent timeouts)"
  Write-Host "  macro safety-classify    --text <text> | --step <macro command> [--macro <name>]   (read-only sensitive action classifier)"
  Write-Host "  macro windows            [--match <s>] [--rich] [--include-hidden]   (Win32 enum, deterministic fallback)"
  Write-Host "  macro coord-profile      [--x <n> --y <n>] [--target-match <s>]   (read-only DPI/monitor/window coordinate profile)"
  Write-Host "  macro coord-map          --from screen|window|normalized --x <n> --y <n> [--target-match <s>]   (read-only screen/window coordinate transform)"
  Write-Host "  macro coord-anchor       --x <n> --y <n> [--target-match <s>] [--record-history]   (read-only layout-relative coordinate anchor)"
  Write-Host "  macro hit-test           --x <n> --y <n> [--target-match <s>] [--click-inset <n>] [--fast]   (read-only point analysis)"
  Write-Host "  macro hit-test-batch     --point <x,y>... | --points <x,y;x,y> [--target-match <s>]   (read-only fast point batch)"
  Write-Host "  macro hit-scan           --x <n> --y <n> [--radius <n>] [--step <n>] [--target-match <s>]   (read-only micro point scan)"
  Write-Host "  macro point-plan         --x <n> --y <n> [--radius <n>] [--step <n>] [--target-match <s>]   (read-only precision click plan)"
  Write-Host "  macro target-validate    --x <n> --y <n> [--target-match <s>] [--min-confidence medium]   (read-only pre-click target validation)"
  Write-Host "  macro cdp-detect         [--port <n>]   (Chrome/Electron DevTools Protocol probe)"
  Write-Host "  macro cdp-eval           --expr <js> | --expr-b64 <base64> [--page-match <s>] [--port <n>]"
  Write-Host "  macro cdp-smart-find     --text <label> [--page-match <s>] [--port <n>]   (read-only DOM label resolver)"
  Write-Host "  macro cdp-smart-type-find --label <field> [--page-match <s>] [--port <n>]   (read-only DOM input resolver)"
  Write-Host "  macro cdp-smart-click    --text <label> [--page-match <s>] [--port <n>]   (live: DOM label click)"
  Write-Host "  macro cdp-smart-type     --label <field> --text <value> [--press-enter] [--page-match <s>] [--port <n>]"
  Write-Host "  macro workflow-plan      --step <macro command>...   (read-only macro sequence planner)"
  Write-Host "  macro workflow-run       --step <macro command>... [--dry-run] [--settle-ms <n>] [--observe-after-step|--verify-after-step] [--verify-label-after-step <text>] [--retry-failed-step <n>] [--confirm-sensitive]   (live: gated macro sequence runner)"
  Write-Host "  macro smart-plan         --label <text> [--type-text <value>] [--match <s>] [--allow-cdp] [--include-ocr] [--precision-points]   (read-only route planner)"
  Write-Host "  macro smart-click        --label <text> [--match <s>] [--allow-mouse-fallback] [--precision-points] [--allow-cdp] [--allow-vision]   (live: cascade click)"
  Write-Host "  macro app-profile        [--match <s>] [--label <text>...] [--auto-probe|--probe-cdp|--probe-uia]   (read-only app automation profile)"
  Write-Host "  macro task-preset        --kind document|mail|form-submit|file-upload|file-download|settings   (read-only task/workflow template)"
  Write-Host "  macro task-plan          [--app <name>] [--type-text <text>] [--shortcut <keys>] [--field <label=value>...] [--send-label <text>]   (read-only app/form workflow planner)"
  Write-Host "  macro task-run           [--dry-run] [--app <name>] [--type-text <text>] [--shortcut <keys>] [--field <label=value>...] [--confirm-sensitive]   (live: gated task-plan executor)"
  Write-Host "  macro form-plan          --field <label=value>... [--send-label <text>] [--allow-cdp]   (read-only multi-step planner)"
  Write-Host "  macro form-run           --field <label=value>... [--send-label <text>] [--allow-cdp] [--dry-run] [--confirm-sensitive]   (live: executes safe form-plan)"
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

# ============================================================================
# v1.4.0 — 6 missing items implementation + 보안 보완
# ============================================================================
# 9개 매크로:
#   1. cdp-deep-find        DOM bridge v2 traversal report (read-only)
#   2. ime-paste            한국어 IME-safe clipboard paste (live)
#   3. safe-type-ime        focus + ime-paste + verify (live)
#   4. modal-detect         모달/대화상자 감지 (read-only)
#   5. recovery-plan        실패 후 재관찰 + retry 추천 (read-only)
#   6. recovery-run         recovery-plan 실행 (live, sensitive gate)
#   7. precision-validate   coordinate precision 측정 (read-only)
#   8. benchmark            read-only 측정 + SLO 검증 (read-only)
#   9. release-notes        CHANGELOG -> release note + secret redact (read-only)
# ============================================================================

# 매크로 envelope schema 상수 ─ 일관된 cucp.<name>/v1 형식 유지
$Script:CucpV14Schema = @{
  CdpDeepFind       = "cucp.cdp-deep-find/v1"
  ImePaste          = "cucp.ime-paste/v1"
  SafeTypeIme       = "cucp.safe-type-ime/v1"
  ModalDetect       = "cucp.modal-detect/v1"
  RecoveryPlan      = "cucp.recovery-plan/v1"
  RecoveryRun       = "cucp.recovery-run/v1"
  PrecisionValidate = "cucp.precision-validate/v1"
  Benchmark         = "cucp.benchmark/v1"
  ReleaseNotes      = "cucp.release-notes/v1"
}

# ----------------------------------------------------------------------------
# 보안 보완: secret/PII redaction helper (release-notes 출력에 사용)
# 패턴: GitHub PAT (ghp_/gho_/ghs_/...), OpenAI sk-, AWS AKIA, Bearer/JWT, PEM
# ----------------------------------------------------------------------------
function _Cucp-RedactSecrets { param([string]$Text)
  if (-not $Text) { return $Text }
  $patterns = @(
    @{ rx = '\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}'; tag = '[REDACTED:github_pat]' },
    @{ rx = '\bsk-[A-Za-z0-9]{20,}';                      tag = '[REDACTED:openai_key]' },
    @{ rx = '\bAKIA[A-Z0-9]{16}\b';                       tag = '[REDACTED:aws_key]' },
    @{ rx = '(?i)bearer\s+[A-Za-z0-9_\-\.=]{20,}';        tag = '[REDACTED:bearer]' },
    @{ rx = 'eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}'; tag = '[REDACTED:jwt]' },
    @{ rx = '-----BEGIN [A-Z ]+PRIVATE KEY-----';         tag = '[REDACTED:pem_block]' }
  )
  $out = $Text
  foreach ($p in $patterns) {
    $out = [regex]::Replace($out, $p.rx, $p.tag)
  }
  return $out
}

# ----------------------------------------------------------------------------
# 1. cdp-deep-find ─ Shadow DOM/iframe 깊이 보고 (read-only)
# 입력: --text <label> [--page-match <s>] [--port <n>]
# 출력: cucp.cdp-deep-find/v1
# 동기: smart-find/type 가 deepCollect 로 traversal 하지만 그 메타정보가
#       외부에 안 보임. 디버깅/벤치마크용으로 노출.
# ----------------------------------------------------------------------------
function Invoke-MacroCdpDeepFind {
  param([string[]]$Rest)
  $text = _Read-OptValue -Rest $Rest -Name "--text"
  if (-not $text) { throw "macro cdp-deep-find requires --text" }
  $pm   = _Read-OptValue -Rest $Rest -Name "--page-match"
  $portStr = _Read-OptValue -Rest $Rest -Name "--port"
  $port = 9222
  if ($portStr) { try { $port = [int]$portStr } catch { $port = 9222 } }
  if ($port -le 0) { $port = 9222 }
  # CDP 포트 quick TCP preflight ─ 닫혀있으면 native helper 호출 안 함
  if (-not (Test-CdpPortQuick -Port $port -TimeoutMs 120)) {
    $payload = [ordered]@{
      schema = $Script:CucpV14Schema.CdpDeepFind
      status = "partial"
      reason = "cdp_port_closed"
      port   = $port
      recommended_action = "start the Electron app with --remote-debugging-port=$port"
    }
    if ($Brief) { [Console]::Out.WriteLine("partial cdp-deep-find port=$port closed") }
    else { [Console]::Out.WriteLine(($payload | ConvertTo-Json -Depth 8)) }
    return 2
  }
  $argList = @("-Action","cdp-deep-find","-CdpText",$text,"-CdpPort","$port")
  if ($pm) { $argList += @("-CdpPageMatch", $pm) }
  $r = Invoke-NativeHelper -ArgList $argList
  $out = [ordered]@{ schema = $Script:CucpV14Schema.CdpDeepFind }
  if ($r.Json) {
    foreach ($prop in $r.Json.PSObject.Properties) { $out[$prop.Name] = $prop.Value }
  } else {
    $out["status"] = "error"
    $out["reason"] = "helper_failed"
  }
  if ($Brief) {
    $cnt = 0; $sr = 0; $ifc = 0
    if ($r.Json -and $r.Json.found_count) { $cnt = [int]$r.Json.found_count }
    if ($r.Json -and $r.Json.traversal) {
      if ($r.Json.traversal.shadow_roots_seen) { $sr  = [int]$r.Json.traversal.shadow_roots_seen }
      if ($r.Json.traversal.iframes_seen)      { $ifc = [int]$r.Json.traversal.iframes_seen }
    }
    [Console]::Out.WriteLine("ok cdp-deep-find text='$text' found=$cnt shadow_roots=$sr iframes=$ifc")
  } else {
    [Console]::Out.WriteLine(($out | ConvertTo-Json -Depth 10))
  }
  if ($r.Json -and $r.Json.status -eq "ok") { return 0 }
  return 2
}

# ----------------------------------------------------------------------------
# 2. ime-paste ─ 한국어 IME-safe clipboard paste (live)
# 입력: --text <s> [--press-enter] [--target-match <s>] [--target-hwnd <n>]
# 출력: cucp.ime-paste/v1
# 보안: clipboard 백업/복구, hit-test 가드, 마우스 안 움직임
# ----------------------------------------------------------------------------
function Invoke-MacroImePaste {
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro ime-paste requires -AllowLiveControl" }
  $text = _Read-OptValue -Rest $Rest -Name "--text"
  if (-not $text) { throw "macro ime-paste requires --text" }
  $tm = _Read-OptValue -Rest $Rest -Name "--target-match"
  $thStr = _Read-OptValue -Rest $Rest -Name "--target-hwnd"
  $th = 0
  if ($thStr) { try { $th = [int]$thStr } catch { $th = 0 } }
  $pressEnter = _Read-Switch -Rest $Rest -Name "--press-enter"
  $argList = @("-Action","ime-paste","-Text",$text)
  if ($pressEnter) { $argList += "-PressEnter" }
  if ($tm) { $argList += @("-TargetMatch", $tm) }
  if ($th -gt 0) { $argList += @("-TargetHwnd", "$th") }
  $r = Invoke-NativeHelper -ArgList $argList
  $out = [ordered]@{ schema = $Script:CucpV14Schema.ImePaste }
  if ($r.Json) {
    foreach ($prop in $r.Json.PSObject.Properties) { $out[$prop.Name] = $prop.Value }
  } else {
    $out["status"] = "error"
    $out["reason"] = "helper_failed"
  }
  if ($Brief) {
    if ($r.Json -and $r.Json.status -eq "ok") {
      [Console]::Out.WriteLine("ok ime-paste len=$($r.Json.text_len) restored=$($r.Json.restored_clipboard)")
    } elseif ($r.Json -and $r.Json.status -eq "blocked") {
      [Console]::Out.WriteLine("blocked ime-paste reason=$($r.Json.reason)")
    } else {
      $reason = "helper_failed"
      if ($r.Json -and $r.Json.reason) { $reason = $r.Json.reason }
      [Console]::Out.WriteLine("partial ime-paste reason=$reason")
    }
  } else {
    [Console]::Out.WriteLine(($out | ConvertTo-Json -Depth 10))
  }
  if ($r.Json) {
    switch ($r.Json.status) {
      "ok"      { return 0 }
      "blocked" { return 3 }
      default   { return 2 }
    }
  }
  return 1
}

# ----------------------------------------------------------------------------
# 3. safe-type-ime ─ focus + ime-paste + 선택적 verify (live)
# 입력: --text <s> [--target-match <s>] [--target-hwnd <n>] [--press-enter]
#       [--verify-title <s>]
# 출력: cucp.safe-type-ime/v1
# 동기: safe-type 의 race condition 을 clipboard route 로 회피
# ----------------------------------------------------------------------------
function Invoke-MacroSafeTypeIme {
  param([string[]]$Rest)
  if (-not $AllowLiveControl) { throw "macro safe-type-ime requires -AllowLiveControl" }
  $text = _Read-OptValue -Rest $Rest -Name "--text"
  if (-not $text) { throw "macro safe-type-ime requires --text" }
  $tm = _Read-OptValue -Rest $Rest -Name "--target-match"
  $thStr = _Read-OptValue -Rest $Rest -Name "--target-hwnd"
  $th = 0
  if ($thStr) { try { $th = [int]$thStr } catch { $th = 0 } }
  $pressEnter  = _Read-Switch -Rest $Rest -Name "--press-enter"
  $verifyTitle = _Read-OptValue -Rest $Rest -Name "--verify-title"
  # Step A: focus (--target-match 있을 때만)
  $focusEvidence = $null
  if ($tm) {
    try {
      $fa = @("-Action","focus","-Match",$tm)
      $fr = Invoke-NativeHelper -ArgList $fa
      if ($fr.Json) { $focusEvidence = $fr.Json }
    } catch { $focusEvidence = $null }
  }
  Start-Sleep -Milliseconds 80
  # Step B: ime-paste (native helper 직접 호출)
  $pa = @("-Action","ime-paste","-Text",$text)
  if ($pressEnter) { $pa += "-PressEnter" }
  if ($tm) { $pa += @("-TargetMatch", $tm) }
  if ($th -gt 0) { $pa += @("-TargetHwnd", "$th") }
  $pr = Invoke-NativeHelper -ArgList $pa
  # Step C: 선택적 verify (window title 부분 일치)
  $verifyEvidence = $null
  if ($verifyTitle -and $pr.Json -and $pr.Json.status -eq "ok") {
    Start-Sleep -Milliseconds 120
    try {
      $wr = Invoke-NativeHelper -ArgList @("-Action","windows")
      $hit = $false
      if ($wr.Json -and $wr.Json.windows) {
        foreach ($w in $wr.Json.windows) {
          if ($w.title -and ($w.title -match [regex]::Escape($verifyTitle))) {
            $hit = $true; break
          }
        }
      }
      $verifyEvidence = [ordered]@{ verify_title=$verifyTitle; matched=$hit }
    } catch {
      $verifyEvidence = [ordered]@{ verify_title=$verifyTitle; matched=$false; error=$_.Exception.Message }
    }
  }
  # paste 단계 status 로 최종 status 결정
  $finalStatus = "ok"
  if (-not $pr.Json) { $finalStatus = "error" }
  elseif ($pr.Json.status -eq "blocked") { $finalStatus = "blocked" }
  elseif ($pr.Json.status -ne "ok")      { $finalStatus = "partial" }
  $out = [ordered]@{
    schema = $Script:CucpV14Schema.SafeTypeIme
    status = $finalStatus
    text_len = [int]$text.Length
    pressed_enter = [bool]$pressEnter
    focus  = $focusEvidence
    paste  = if ($pr.Json) { $pr.Json } else { $null }
    verify = $verifyEvidence
  }
  if ($Brief) {
    $vm = "n/a"
    if ($verifyEvidence) { $vm = "$($verifyEvidence.matched)" }
    [Console]::Out.WriteLine("$finalStatus safe-type-ime len=$($text.Length) verify_matched=$vm")
  } else {
    [Console]::Out.WriteLine(($out | ConvertTo-Json -Depth 10))
  }
  switch ($finalStatus) {
    "ok"      { return 0 }
    "blocked" { return 3 }
    "partial" { return 2 }
    default   { return 1 }
  }
}

# ----------------------------------------------------------------------------
# 4. modal-detect ─ 모달/대화상자 감지 (read-only)
# 입력: [--match <s>] [--target-hwnd <n>]
# 출력: cucp.modal-detect/v1 (native helper output + schema)
# ----------------------------------------------------------------------------
function Invoke-MacroModalDetect {
  param([string[]]$Rest)
  $tm = _Read-OptValue -Rest $Rest -Name "--match"
  $thStr = _Read-OptValue -Rest $Rest -Name "--target-hwnd"
  $th = 0
  if ($thStr) { try { $th = [int]$thStr } catch { $th = 0 } }
  $argList = @("-Action","modal-detect")
  if ($tm) { $argList += @("-Match", $tm) }
  if ($th -gt 0) { $argList += @("-TargetHwnd", "$th") }
  $r = Invoke-NativeHelper -ArgList $argList
  $out = [ordered]@{ schema = $Script:CucpV14Schema.ModalDetect }
  if ($r.Json) {
    foreach ($prop in $r.Json.PSObject.Properties) { $out[$prop.Name] = $prop.Value }
  } else {
    $out["status"] = "error"
    $out["reason"] = "helper_failed"
  }
  if ($Brief) {
    $cc = 0; $rec = "observe"
    if ($r.Json -and $r.Json.candidate_count)    { $cc  = [int]$r.Json.candidate_count }
    if ($r.Json -and $r.Json.recommended_action) { $rec = "$($r.Json.recommended_action)" }
    [Console]::Out.WriteLine("ok modal-detect candidates=$cc recommended=$rec")
  } else {
    [Console]::Out.WriteLine(($out | ConvertTo-Json -Depth 10))
  }
  return 0
}

# ----------------------------------------------------------------------------
# 5. recovery-plan ─ 실패 후 재관찰 + retry 추천 (read-only)
# 입력: [--match <s>] [--failed-step <s>] [--failed-reason <s>]
# 출력: cucp.recovery-plan/v1 { modal, foreground, recovery_candidates[], next_action }
# ----------------------------------------------------------------------------
function Invoke-MacroRecoveryPlan {
  param([string[]]$Rest)
  $tm           = _Read-OptValue -Rest $Rest -Name "--match"
  $failedStep   = _Read-OptValue -Rest $Rest -Name "--failed-step"
  $failedReason = _Read-OptValue -Rest $Rest -Name "--failed-reason"
  # Step A: modal-detect
  $modal = $null
  try {
    $ma = @("-Action","modal-detect")
    if ($tm) { $ma += @("-Match", $tm) }
    $mr = Invoke-NativeHelper -ArgList $ma
    if ($mr.Json) { $modal = $mr.Json }
  } catch { $modal = $null }
  # Step B: foreground info
  $fg = $null
  try {
    $fr = Invoke-NativeHelper -ArgList @("-Action","focused")
    if ($fr.Json) { $fg = $fr.Json }
  } catch { $fg = $null }
  # Step C: 추천 후보 생성
  $candidates = New-Object System.Collections.ArrayList
  $hasModal = ($modal -and $modal.candidate_count -and ($modal.candidate_count -gt 0))
  if ($hasModal) {
    $top = $modal.modal_candidates[0]
    $isModalFlag = $false
    if ($top.is_modal) { $isModalFlag = $true }
    $topScore = 0
    if ($top.score) { $topScore = [int]$top.score }
    if ($isModalFlag -or ($topScore -ge 100)) {
      [void]$candidates.Add([ordered]@{
        rank=1; action="dismiss_modal"; method="shortcut";
        command='macro shortcut --keys "escape"';
        live=$true; sensitive=$true;
        evidence="modal:$($top.title) score:$topScore"
      })
      [void]$candidates.Add([ordered]@{
        rank=2; action="confirm_modal"; method="shortcut";
        command='macro shortcut --keys "enter"';
        live=$true; sensitive=$true;
        evidence="modal:$($top.title)"
      })
    } elseif ($topScore -ge 60) {
      [void]$candidates.Add([ordered]@{
        rank=1; action="observe_dialog"; method="modal-detect";
        command="macro modal-detect";
        live=$false; sensitive=$false;
        evidence="dialog_class:$($top.class)"
      })
      [void]$candidates.Add([ordered]@{
        rank=2; action="find_dialog_button"; method="find-label";
        command='macro find-label --label "OK" --explain';
        live=$false; sensitive=$false;
        evidence="dialog_score:$topScore"
      })
    }
  }
  # 모달 없으면: 재관찰 + 사용자 제공 step retry 추천
  if ($candidates.Count -eq 0) {
    [void]$candidates.Add([ordered]@{
      rank=1; action="re_observe"; method="windows";
      command="macro windows";
      live=$false; sensitive=$false;
      evidence="no_modal_detected"
    })
    if ($failedStep) {
      [void]$candidates.Add([ordered]@{
        rank=2; action="retry_failed_step"; method="as_provided";
        command="$failedStep";
        live=$true; sensitive=$true;
        evidence="user_provided_step"
      })
    }
  }
  $rec = $null
  $next = "observe"
  if ($candidates.Count -gt 0) {
    $rec  = $candidates[0]
    $next = "$($candidates[0].action)"
  }
  $out = [ordered]@{
    schema              = $Script:CucpV14Schema.RecoveryPlan
    status              = "ok"
    modal               = $modal
    foreground          = $fg
    failed_step         = $failedStep
    failed_reason       = $failedReason
    recovery_candidates = @($candidates)
    candidate_count     = [int]$candidates.Count
    recommended         = $rec
    next_action         = $next
  }
  if ($Brief) {
    [Console]::Out.WriteLine("ok recovery-plan candidates=$($out.candidate_count) next=$next")
  } else {
    [Console]::Out.WriteLine(($out | ConvertTo-Json -Depth 10))
  }
  return 0
}

# ----------------------------------------------------------------------------
# 6. recovery-run ─ recovery-plan 실행 (live, sensitive gate)
# 입력: [--match <s>] [--failed-step <s>] [--dry-run] [--confirm-sensitive]
# 출력: cucp.recovery-run/v1
# 보안: live action 은 -AllowLiveControl + --confirm-sensitive 둘 다 필수
# ----------------------------------------------------------------------------
function Invoke-MacroRecoveryRun {
  param([string[]]$Rest)
  $dryRun  = _Read-Switch -Rest $Rest -Name "--dry-run"
  $confirm = _Read-Switch -Rest $Rest -Name "--confirm-sensitive"
  $tm = _Read-OptValue -Rest $Rest -Name "--match"
  if (-not $dryRun) {
    if (-not $AllowLiveControl) { throw "macro recovery-run requires -AllowLiveControl (or --dry-run)" }
  }
  # Build plan inline (recovery-plan 과 동일 로직)
  $modal = $null
  try {
    $ma = @("-Action","modal-detect")
    if ($tm) { $ma += @("-Match", $tm) }
    $mr = Invoke-NativeHelper -ArgList $ma
    if ($mr.Json) { $modal = $mr.Json }
  } catch { $modal = $null }
  $recAction = "observe"
  $recCmd    = "macro windows"
  $recLive   = $false
  $hasModal  = ($modal -and $modal.candidate_count -and ($modal.candidate_count -gt 0))
  if ($hasModal) {
    $top = $modal.modal_candidates[0]
    $isModalFlag = $false
    if ($top.is_modal) { $isModalFlag = $true }
    $topScore = 0
    if ($top.score) { $topScore = [int]$top.score }
    if ($isModalFlag -or ($topScore -ge 100)) {
      $recAction = "dismiss_modal"
      $recCmd    = "shortcut:escape"
      $recLive   = $true
    }
  }
  # Sensitive gate: live 필요한데 confirm 없으면 blocked (exit 3)
  if ($recLive -and (-not $confirm) -and (-not $dryRun)) {
    $blocked = [ordered]@{
      schema  = $Script:CucpV14Schema.RecoveryRun
      status  = "blocked"
      reason  = "sensitive_recovery_requires_confirmation"
      recommended_action  = $recAction
      recommended_command = $recCmd
      next_action = "Re-run with --confirm-sensitive only after explicit user approval."
    }
    if ($Brief) { [Console]::Out.WriteLine("blocked recovery-run reason=sensitive_recovery_requires_confirmation") }
    else { [Console]::Out.WriteLine(($blocked | ConvertTo-Json -Depth 10)) }
    return 3
  }
  # Dry-run: 실행 안 하고 plan 만 반환
  if ($dryRun) {
    $modalCount = 0
    if ($modal -and $modal.candidate_count) { $modalCount = [int]$modal.candidate_count }
    $out = [ordered]@{
      schema  = $Script:CucpV14Schema.RecoveryRun
      status  = "ready"
      dry_run = $true
      recommended_action  = $recAction
      recommended_command = $recCmd
      requires_live       = $recLive
      modal_candidate_count = $modalCount
    }
    if ($Brief) { [Console]::Out.WriteLine("ready recovery-run dry-run action=$recAction") }
    else { [Console]::Out.WriteLine(($out | ConvertTo-Json -Depth 10)) }
    return 0
  }
  # Live execution
  $execResult = $null
  if ($recAction -eq "dismiss_modal") {
    try {
      Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
      [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
      Start-Sleep -Milliseconds 80
      $execResult = [ordered]@{ method="sendkeys_esc"; status="ok" }
    } catch {
      $execResult = [ordered]@{ method="sendkeys_esc"; status="error"; detail=$_.Exception.Message }
    }
  } else {
    $execResult = [ordered]@{ method="observe_only"; status="ok" }
  }
  $finalStatus = "ok"
  if ($execResult.status -ne "ok") { $finalStatus = "partial" }
  $out = [ordered]@{
    schema = $Script:CucpV14Schema.RecoveryRun
    status = $finalStatus
    executed_action = $recAction
    execution = $execResult
    modal_before = $modal
  }
  if ($Brief) {
    [Console]::Out.WriteLine("$finalStatus recovery-run action=$recAction")
  } else {
    [Console]::Out.WriteLine(($out | ConvertTo-Json -Depth 10))
  }
  if ($finalStatus -eq "ok") { return 0 } else { return 2 }
}

# ----------------------------------------------------------------------------
# 7. precision-validate ─ coordinate precision 측정 (read-only)
# 입력: --x <n> --y <n> [--target-match <s>] [--samples <n>]
# 출력: cucp.precision-validate/v1 { drift_max, drift_avg, stable, recommendation }
# ----------------------------------------------------------------------------
function Invoke-MacroPrecisionValidate {
  param([string[]]$Rest)
  $xStr = _Read-OptValue -Rest $Rest -Name "--x"
  $yStr = _Read-OptValue -Rest $Rest -Name "--y"
  if (-not $xStr -or -not $yStr) { throw "macro precision-validate requires --x and --y" }
  $tm = _Read-OptValue -Rest $Rest -Name "--target-match"
  $samplesStr = _Read-OptValue -Rest $Rest -Name "--samples"
  $x = [int]$xStr
  $y = [int]$yStr
  $samples = 5
  if ($samplesStr) { try { $samples = [int]$samplesStr } catch { $samples = 5 } }
  if ($samples -lt 1)  { $samples = 1 }
  if ($samples -gt 20) { $samples = 20 }
  $points = New-Object System.Collections.ArrayList
  $totalMs = 0
  $errors  = 0
  for ($i = 0; $i -lt $samples; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
      $a = @("-Action","hit-scan","-X","$x","-Y","$y","-ScanRadius","6","-ScanStep","2")
      if ($tm) { $a += @("-TargetMatch", $tm) }
      $r = Invoke-NativeHelper -ArgList $a
      $sw.Stop()
      $elapsed = [int]$sw.ElapsedMilliseconds
      $totalMs += $elapsed
      $bestX = $null; $bestY = $null; $score = 0
      if ($r.Json -and $r.Json.best) {
        if ($r.Json.best.x)     { $bestX = [int]$r.Json.best.x }
        if ($r.Json.best.y)     { $bestY = [int]$r.Json.best.y }
        if ($r.Json.best.score) { $score = [int]$r.Json.best.score }
      }
      if ($null -ne $bestX -and $null -ne $bestY) {
        [void]$points.Add([ordered]@{ iteration=$i+1; x=$bestX; y=$bestY; elapsed_ms=$elapsed; score=$score })
      } else {
        $errors++
      }
    } catch {
      $sw.Stop()
      $errors++
    }
    Start-Sleep -Milliseconds 30
  }
  # Drift = mean point 으로부터 각 sample 의 거리. max/avg 계산
  $driftMax = 0.0
  $driftAvg = 0.0
  if ($points.Count -ge 2) {
    $xs = @($points | ForEach-Object { $_.x })
    $ys = @($points | ForEach-Object { $_.y })
    $mx = ($xs | Measure-Object -Average).Average
    $my = ($ys | Measure-Object -Average).Average
    $sumD = 0.0
    foreach ($p in $points) {
      $dx = $p.x - $mx
      $dy = $p.y - $my
      $d  = [Math]::Sqrt($dx*$dx + $dy*$dy)
      if ($d -gt $driftMax) { $driftMax = $d }
      $sumD += $d
    }
    $driftAvg = $sumD / $points.Count
  }
  $stable = ($driftMax -le 2.0)
  $rec = "use_uia_pattern_or_relabel"
  if ($stable) { $rec = "safe_to_use_anchor" }
  elseif ($driftMax -le 5.0) { $rec = "use_with_micro_refine" }
  $avgElapsed = 0
  if ($samples -gt 0) { $avgElapsed = [int]($totalMs / $samples) }
  $out = [ordered]@{
    schema = $Script:CucpV14Schema.PrecisionValidate
    status = "ok"
    input  = [ordered]@{ x=$x; y=$y; target_match=$tm; samples=$samples }
    sample_count = [int]$points.Count
    error_count  = [int]$errors
    avg_elapsed_ms = $avgElapsed
    points = @($points)
    drift_max = [Math]::Round($driftMax, 2)
    drift_avg = [Math]::Round($driftAvg, 2)
    stable    = $stable
    recommendation = $rec
  }
  if ($Brief) {
    [Console]::Out.WriteLine("ok precision-validate samples=$($out.sample_count) drift_max=$($out.drift_max)px stable=$stable rec=$rec")
  } else {
    [Console]::Out.WriteLine(($out | ConvertTo-Json -Depth 10))
  }
  return 0
}

# ----------------------------------------------------------------------------
# 8. benchmark ─ read-only 측정 + SLO 검증 (read-only, 라이브 클래스룸 안 씀)
# 입력: [--iters <n>]   기본 3, 최대 10
# 출력: cucp.benchmark/v1 { results[], slo_pass_rate_pct, recommendation }
# 보안: 텍스트/PII 미포함, 길이/타이밍만 측정
# ----------------------------------------------------------------------------
function Invoke-MacroBenchmark {
  param([string[]]$Rest)
  $itersStr = _Read-OptValue -Rest $Rest -Name "--iters"
  $baselinePath = _Read-OptValue -Rest $Rest -Name "--baseline"
  $iters = 3
  if ($itersStr) { try { $iters = [int]$itersStr } catch { $iters = 3 } }
  if ($iters -lt 1)  { $iters = 1 }
  if ($iters -gt 10) { $iters = 10 }
  # 측정 대상 (모두 read-only native helper actions, helper 외 의존성 없음)
  $targets = @(
    @{ name="windows";      args=@("-Action","windows");      slo_ms=600 },
    @{ name="health";       args=@("-Action","health");       slo_ms=400 },
    @{ name="focused";      args=@("-Action","focused");      slo_ms=500 },
    @{ name="modal-detect"; args=@("-Action","modal-detect"); slo_ms=800 }
  )
  $results = New-Object System.Collections.ArrayList
  foreach ($t in $targets) {
    $samples = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $iters; $i++) {
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $okFlag = $false
      $errMsg = $null
      try {
        $r = Invoke-NativeHelper -ArgList $t.args
        $sw.Stop()
        if ($r.Json) {
          if ($r.Json.status) {
            if ($r.Json.status -eq "ok") { $okFlag = $true }
          } else {
            $okFlag = $true
          }
        }
      } catch {
        $sw.Stop()
        $errMsg = $_.Exception.Message
      }
      $entry = [ordered]@{ iter=$i+1; ms=[int]$sw.ElapsedMilliseconds; ok=$okFlag }
      if ($errMsg) { $entry["error"] = $errMsg }
      [void]$samples.Add($entry)
    }
    $okMs = @($samples | Where-Object { $_.ok } | ForEach-Object { $_.ms })
    $p50 = 0; $p95 = 0; $avg = 0
    if ($okMs.Count -gt 0) {
      $sorted = @($okMs | Sort-Object)
      $i50 = [int]([Math]::Floor(($sorted.Count - 1) * 0.5))
      $i95 = [int]([Math]::Floor(($sorted.Count - 1) * 0.95))
      if ($i50 -lt 0) { $i50 = 0 }
      if ($i95 -lt 0) { $i95 = 0 }
      $p50 = $sorted[$i50]
      $p95 = $sorted[$i95]
      $avg = [int](($okMs | Measure-Object -Average).Average)
    }
    $sloOk = ($p95 -le $t.slo_ms)
    [void]$results.Add([ordered]@{
      name=$t.name; iters=$iters; ok_count=$okMs.Count;
      p50_ms=$p50; p95_ms=$p95; avg_ms=$avg;
      slo_ms=$t.slo_ms; slo_ok=$sloOk;
      samples=@($samples)
    })
  }
  $totalSlos = (@($results | Where-Object { $_.slo_ok })).Count
  $passRate = 0.0
  if ($targets.Count -gt 0) {
    $passRate = [Math]::Round(([double]$totalSlos / [double]$targets.Count) * 100.0, 1)
  }
  $rec = "investigate_helper_health"
  if ($passRate -ge 90.0)      { $rec = "all_within_slo" }
  elseif ($passRate -ge 60.0)  { $rec = "review_slow_targets" }
  # v1.5.0: --baseline 비교 모드 (read-only, regression detection)
  $baselineCompare = $null
  if ($baselinePath -and (Test-Path -LiteralPath $baselinePath)) {
    try {
      $baseRaw = @(Get-Content -LiteralPath $baselinePath -Raw)
      $base = $baseRaw -join "" | ConvertFrom-Json
      $cmpRows = New-Object System.Collections.ArrayList
      $regressed = 0
      $improved  = 0
      foreach ($cur in $results) {
        $b = $base.results | Where-Object { $_.name -eq $cur.name } | Select-Object -First 1
        if (-not $b) { continue }
        $deltaP50 = $cur.p50_ms - [int]$b.p50_ms
        $deltaP95 = $cur.p95_ms - [int]$b.p95_ms
        $pctP50 = 0
        if ([int]$b.p50_ms -gt 0) { $pctP50 = [Math]::Round((([double]$deltaP50) / [double]$b.p50_ms) * 100.0, 1) }
        $verdict = "neutral"
        if ($deltaP50 -le -10) { $verdict = "improved"; $improved++ }
        elseif ($deltaP50 -ge 30) { $verdict = "regressed"; $regressed++ }
        [void]$cmpRows.Add([ordered]@{
          name = $cur.name
          baseline_p50_ms = [int]$b.p50_ms
          current_p50_ms  = $cur.p50_ms
          delta_ms = $deltaP50
          delta_pct = $pctP50
          verdict = $verdict
        })
      }
      $baselineCompare = [ordered]@{
        baseline_path = $baselinePath
        compared_targets = $cmpRows.Count
        improved_count = $improved
        regressed_count = $regressed
        rows = @($cmpRows)
      }
    } catch {
      $baselineCompare = [ordered]@{
        baseline_path = $baselinePath
        error = "baseline_load_failed"
        detail = $_.Exception.Message
      }
    }
  }
  $out = [ordered]@{
    schema = $Script:CucpV14Schema.Benchmark
    status = "ok"
    iters  = $iters
    target_count = $targets.Count
    results      = @($results)
    slo_pass_count    = $totalSlos
    slo_pass_rate_pct = $passRate
    recommendation    = $rec
    baseline_compare  = $baselineCompare
  }
  if ($Brief) {
    if ($baselineCompare -and -not $baselineCompare.error) {
      [Console]::Out.WriteLine("ok benchmark targets=$($targets.Count) iters=$iters slo_pass=$totalSlos/$($targets.Count) ($passRate%) improved=$($baselineCompare.improved_count) regressed=$($baselineCompare.regressed_count)")
    } else {
      [Console]::Out.WriteLine("ok benchmark targets=$($targets.Count) iters=$iters slo_pass=$totalSlos/$($targets.Count) ($passRate%)")
    }
  } else {
    [Console]::Out.WriteLine(($out | ConvertTo-Json -Depth 10))
  }
  return 0
}

# ----------------------------------------------------------------------------
# 9. release-notes ─ CHANGELOG -> release notes (read-only, secret redact)
# 입력: [--version <x.y.z>] [--since <x.y.z>]   기본: 최신 1개
# 출력: cucp.release-notes/v1 { notes[], migration_notes, external_agent_usage }
# 보안: secret 패턴 자동 redact (PAT, sk-, AKIA, Bearer, JWT, PEM)
# ----------------------------------------------------------------------------
function Invoke-MacroReleaseNotes {
  param([string[]]$Rest)
  $version  = _Read-OptValue -Rest $Rest -Name "--version"
  $sinceStr = _Read-OptValue -Rest $Rest -Name "--since"
  # PS 5.x 함정: Get-Content 단일 라인 스칼라 반환 -> @() 강제
  $changelogPath = Join-Path $PSScriptRoot "..\CHANGELOG.md"
  $clResolved = Resolve-Path -LiteralPath $changelogPath -ErrorAction SilentlyContinue
  if (-not $clResolved) { throw "macro release-notes: CHANGELOG.md not found at $changelogPath" }
  $clRaw = @(Get-Content -LiteralPath $clResolved.Path)
  # 버전별 split (## v 또는 ## 0.1.0 형식)
  $sections = New-Object System.Collections.ArrayList
  $current = $null
  foreach ($line in $clRaw) {
    if ($line -match '^##\s+v?(\d+\.\d+\.\d+)') {
      if ($current) { [void]$sections.Add($current) }
      $current = [ordered]@{
        version = $Matches[1]
        header  = $line
        body    = New-Object System.Collections.ArrayList
      }
    } elseif ($current) {
      [void]$current.body.Add($line)
    }
  }
  if ($current) { [void]$sections.Add($current) }
  # 필터
  $filtered = @()
  if ($version) {
    $filtered = @($sections | Where-Object { $_.version -eq $version })
  } elseif ($sinceStr) {
    $sinceParts = $sinceStr -split '\.'
    if ($sinceParts.Count -ge 3) {
      $sj = ([int]$sinceParts[0] * 10000) + ([int]$sinceParts[1] * 100) + [int]$sinceParts[2]
      $filtered = @($sections | Where-Object {
        $vp = $_.version -split '\.'
        if ($vp.Count -ge 3) {
          $vj = ([int]$vp[0] * 10000) + ([int]$vp[1] * 100) + [int]$vp[2]
          $vj -ge $sj
        } else { $false }
      })
    }
  } else {
    if ($sections.Count -gt 0) { $filtered = @($sections[0]) }
  }
  # 각 버전 body 에서 ###Added/Improved/Verified/Fixed 분리
  $notes = New-Object System.Collections.ArrayList
  foreach ($s in $filtered) {
    $added = New-Object System.Collections.ArrayList
    $improved = New-Object System.Collections.ArrayList
    $verified = New-Object System.Collections.ArrayList
    $fixed = New-Object System.Collections.ArrayList
    $cur = $null
    foreach ($bl in $s.body) {
      if ($bl -match '^###\s+(Added|Improved|Verified|Fixed|Why|Internal|Documentation|Tests|Limits)') {
        $cur = $Matches[1]
      } elseif ($bl -match '^-\s+(.+)$') {
        $item = _Cucp-RedactSecrets -Text $Matches[1]
        switch ($cur) {
          "Added"    { [void]$added.Add($item) }
          "Improved" { [void]$improved.Add($item) }
          "Verified" { [void]$verified.Add($item) }
          "Fixed"    { [void]$fixed.Add($item) }
        }
      }
    }
    $highlights = @()
    if ($added.Count -gt 0)    { $highlights += @($added | Select-Object -First 3) }
    if ($improved.Count -gt 0) { $highlights += @($improved | Select-Object -First 2) }
    [void]$notes.Add([ordered]@{
      version    = $s.version
      highlights = @($highlights | Select-Object -First 5)
      added      = @($added)
      improved   = @($improved)
      verified   = @($verified)
      fixed      = @($fixed)
    })
  }
  $filterDesc = "latest"
  if ($version)        { $filterDesc = "version=$version" }
  elseif ($sinceStr)   { $filterDesc = "since=$sinceStr" }
  $migration = "v1.4.0: 새 매크로 9개 추가 (cdp-deep-find, ime-paste, safe-type-ime, modal-detect, recovery-plan, recovery-run, precision-validate, benchmark, release-notes). 기존 매크로 호환성 영향 없음. DOM bridge v2 (Shadow DOM/iframe traversal) 자동 적용."
  $usage = "AI agent loop: Observe (windows/find-label) -> Plan (smart-plan/task-plan) -> Act (-AllowLiveControl + safety gate -> click-label/safe-type-ime) -> Verify (modal-detect/precision-validate) -> Recover (recovery-run --confirm-sensitive)."
  $out = [ordered]@{
    schema = $Script:CucpV14Schema.ReleaseNotes
    status = "ok"
    changelog_path = $clResolved.Path
    total_versions_in_changelog = [int]$sections.Count
    filter      = $filterDesc
    note_count  = [int]$notes.Count
    notes       = @($notes)
    migration_notes      = $migration
    external_agent_usage = $usage
  }
  if ($Brief) {
    $vList = @($notes | ForEach-Object { $_.version }) -join ","
    [Console]::Out.WriteLine("ok release-notes notes=$($out.note_count) versions=$vList")
  } else {
    [Console]::Out.WriteLine(($out | ConvertTo-Json -Depth 10))
  }
  return 0
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
