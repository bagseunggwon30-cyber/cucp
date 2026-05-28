# =============================================================================
# CUCP Helper Persistent Server (v2.0.0)
# =============================================================================
# 동기:
#   기존 cucp-native-helper.ps1 은 매 호출마다 child PowerShell 프로세스를 생성
#   (cold start ~500ms). cascade chain (smart-click 6 stage, workflow-run, recovery-plan)
#   이나 single-shot 반복 호출 시 누적 비용 큼.
#
# 해결:
#   long-running PowerShell 프로세스를 named pipe (`cucp-helper-<pid>`) 로 listener
#   띄움. wrapper 가 첫 호출 시 server detect → JSON request 보내고 JSON response 받음.
#   server 미가동이면 wrapper 가 fallback 으로 기존 child process 방식 사용.
#
# 지원 action (server 내장 4개, 가장 자주 호출되는 read-only):
#   - windows  (Win32 EnumWindows + foreground)
#   - health   (status=ok + uptime)
#   - focused  (GetForegroundWindow + GetWindowText + GetClassName)
#   - modal-detect (UIA root.FindAll + IsModal score)
#
#   다른 action 은 server 가 fallback 신호 보내고 wrapper 가 child process 로 처리.
#
# JSON 프로토콜 (newline-delimited):
#   request:  {"id": <int>, "action": "<name>", "args": {"Match": "...", ...}}
#   response: {"id": <int>, "exit_code": <int>, "result": <obj|null>, "error": <str|null>}
#
# Lock file:
#   %TEMP%\computer-use-control-plane\helper.pid 에 PID + pipe name 기록.
#   wrapper 가 이 파일로 server 발견. server 종료 시 삭제.
#
# Idle timeout:
#   기본 60초 동안 request 없으면 server 자동 종료 (메모리 보호).
# =============================================================================

[CmdletBinding()]
param(
  # named pipe 이름 (기본: cucp-helper-<자기 PID>)
  [string]$PipeName,
  # idle 종료 시간 (밀리초). 기본 60000.
  [int]$IdleTimeoutMs = 60000,
  # lock 파일 경로 (기본: %TEMP%\computer-use-control-plane\helper.pid)
  [string]$LockFile,
  # debug 모드 (서버 stderr 에 로그)
  [switch]$DebugLog
)

$ErrorActionPreference = "Stop"

# ----- 콘솔 인코딩 (PS5 기본 CP949 회피) ------------------------------------
try {
  [System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

if (-not $PipeName) { $PipeName = "cucp-helper-$PID" }
if (-not $LockFile) {
  $tmpDir = Join-Path $env:TEMP "computer-use-control-plane"
  if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
  $LockFile = Join-Path $tmpDir "helper.pid"
}

function _Log { param([string]$Msg)
  if ($DebugLog) { [Console]::Error.WriteLine("[helper-server $(Get-Date -Format 'HH:mm:ss.fff')] $Msg") }
}

# =============================================================================
# Win32 P/Invoke (helper server 내장 — wrapper / native helper 와 별도)
# =============================================================================
$Script:_Win32Loaded = $false
function _Ensure-Win32Loaded {
  if ($Script:_Win32Loaded) { return $true }
  try {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class HelperWin32 {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
    $Script:_Win32Loaded = $true
    return $true
  } catch {
    _Log "Win32 load failed: $($_.Exception.Message)"
    return $false
  }
}

# =============================================================================
# Action 구현 (4개 핵심 read-only)
# =============================================================================
function _Action-Windows {
  param([hashtable]$Args)
  if (-not (_Ensure-Win32Loaded)) {
    return @{ status="error"; reason="win32_unavailable" }
  }
  $match = if ($Args -and $Args.Match) { "$($Args.Match)" } else { $null }
  $rxMatch = $null
  if ($match) {
    try { $rxMatch = [regex]::new([regex]::Escape($match), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) } catch { $rxMatch = $null }
  }
  $list = New-Object System.Collections.ArrayList
  $proc = {
    param([IntPtr]$hWnd, [IntPtr]$lParam)
    if ([HelperWin32]::IsWindowVisible($hWnd)) {
      $len = [HelperWin32]::GetWindowTextLength($hWnd)
      if ($len -gt 0) {
        $sb = New-Object System.Text.StringBuilder ($len + 1)
        [void][HelperWin32]::GetWindowText($hWnd, $sb, $len + 1)
        $title = $sb.ToString()
        if ($title) {
          $cls = New-Object System.Text.StringBuilder 256
          [void][HelperWin32]::GetClassName($hWnd, $cls, 256)
          $procId = 0
          [void][HelperWin32]::GetWindowThreadProcessId($hWnd, [ref]$procId)
          if (-not $rxMatch -or $rxMatch.IsMatch($title)) {
            $rect = New-Object HelperWin32+RECT
            [void][HelperWin32]::GetWindowRect($hWnd, [ref]$rect)
            [void]$list.Add(@{
              hwnd = [int64]$hWnd
              title = $title
              class = $cls.ToString()
              pid = [int]$procId
              rect = @{ x=$rect.Left; y=$rect.Top; w=($rect.Right - $rect.Left); h=($rect.Bottom - $rect.Top) }
            })
          }
        }
      }
    }
    return $true
  }
  [void][HelperWin32]::EnumWindows($proc, [IntPtr]::Zero)
  $fg = [HelperWin32]::GetForegroundWindow()
  $fgInfo = $null
  if ($fg -ne [IntPtr]::Zero) {
    $fgLen = [HelperWin32]::GetWindowTextLength($fg)
    if ($fgLen -gt 0) {
      $sb = New-Object System.Text.StringBuilder ($fgLen + 1)
      [void][HelperWin32]::GetWindowText($fg, $sb, $fgLen + 1)
      $fgInfo = @{ hwnd = [int64]$fg; title = $sb.ToString() }
    }
  }
  return @{
    status = "ok"
    schema = "cucp.observation/v1"
    kind = "windows"
    sources = @("win32_helper_server")
    foreground = $fgInfo
    windows = @($list)
    count = $list.Count
  }
}

function _Action-Health {
  param([hashtable]$Args)
  return @{
    status = "ok"
    schema = "cucp.health/v1"
    helper_mode = "persistent_server"
    pid = $PID
    pipe_name = $PipeName
    uptime_s = [int]([DateTime]::UtcNow - $Script:_StartedAt).TotalSeconds
    request_count = $Script:_RequestCount
    win32_loaded = $Script:_Win32Loaded
  }
}

function _Action-Focused {
  param([hashtable]$Args)
  if (-not (_Ensure-Win32Loaded)) {
    return @{ status="error"; reason="win32_unavailable" }
  }
  $fg = [HelperWin32]::GetForegroundWindow()
  if ($fg -eq [IntPtr]::Zero) { return @{ status="partial"; reason="no_foreground" } }
  $sb = New-Object System.Text.StringBuilder 512
  [void][HelperWin32]::GetWindowText($fg, $sb, 512)
  $cls = New-Object System.Text.StringBuilder 256
  [void][HelperWin32]::GetClassName($fg, $cls, 256)
  $procId = 0
  [void][HelperWin32]::GetWindowThreadProcessId($fg, [ref]$procId)
  $rect = New-Object HelperWin32+RECT
  [void][HelperWin32]::GetWindowRect($fg, [ref]$rect)
  return @{
    status = "ok"
    schema = "cucp.focused/v1"
    hwnd = [int64]$fg
    title = $sb.ToString()
    class = $cls.ToString()
    pid = [int]$procId
    rect = @{ x=$rect.Left; y=$rect.Top; w=($rect.Right - $rect.Left); h=($rect.Bottom - $rect.Top) }
  }
}

function _Action-ModalDetect {
  param([hashtable]$Args)
  Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
  Add-Type -AssemblyName UIAutomationTypes -ErrorAction SilentlyContinue
  if (-not (_Ensure-Win32Loaded)) {
    return @{ status="error"; reason="win32_unavailable" }
  }
  $candidates = New-Object System.Collections.ArrayList
  $fgInfo = $null
  try {
    $fg = [HelperWin32]::GetForegroundWindow()
    if ($fg -ne [IntPtr]::Zero) {
      $sb = New-Object System.Text.StringBuilder 512
      [void][HelperWin32]::GetWindowText($fg, $sb, 512)
      $cls = New-Object System.Text.StringBuilder 256
      [void][HelperWin32]::GetClassName($fg, $cls, 256)
      $fgInfo = @{ hwnd = [int64]$fg; title = $sb.ToString(); class = $cls.ToString() }
    }
  } catch { }
  try {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.OrCondition @(
      (New-Object System.Windows.Automation.PropertyCondition `
        ([System.Windows.Automation.AutomationElement]::ControlTypeProperty),
        ([System.Windows.Automation.ControlType]::Window)),
      (New-Object System.Windows.Automation.PropertyCondition `
        ([System.Windows.Automation.AutomationElement]::ControlTypeProperty),
        ([System.Windows.Automation.ControlType]::Pane))
    )
    $els = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
    foreach ($el in $els) {
      try {
        $name = "$($el.Current.Name)"
        $clazz = "$($el.Current.ClassName)"
        $rect = $el.Current.BoundingRectangle
        $isModal = $false
        try {
          $wp = $el.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
          if ($wp -and $wp.Current.IsModal) { $isModal = $true }
        } catch { }
        $reason = $null
        $score = 0
        if ($isModal) { $score += 100; $reason = "uia_window_is_modal" }
        if ($clazz -match "(?i)#32770|MessageBox|Dialog|TaskDialog|Popup") {
          $score += 60
          if (-not $reason) { $reason = "dialog_class_name" }
        }
        if ($rect -and $rect.Width -gt 0 -and $rect.Width -lt 900 -and $rect.Height -gt 0 -and $rect.Height -lt 600) {
          $score += 20
          if (-not $reason) { $reason = "small_window_size" }
        }
        if ($score -gt 0) {
          $hwndProp = $null
          try { $hwndProp = [int]$el.Current.NativeWindowHandle } catch { $hwndProp = $null }
          [void]$candidates.Add(@{
            hwnd = $hwndProp
            title = $name
            class = $clazz
            score = $score
            reason = $reason
            is_modal = $isModal
          })
        }
      } catch { continue }
    }
  } catch { }
  $sorted = @($candidates | Sort-Object -Property score -Descending)
  $rec = "observe"
  if ($sorted.Count -gt 0) {
    $top = $sorted[0]
    if ($top.is_modal -or ($top.score -ge 100)) { $rec = "dismiss_or_confirm" }
    elseif ($top.score -ge 60) { $rec = "confirm_dialog" }
    else { $rec = "wait" }
  }
  return @{
    status = "ok"
    schema = "cucp.modal-detect/v1"
    foreground = $fgInfo
    modal_candidates = @($sorted)
    candidate_count = [int]$sorted.Count
    recommended_action = $rec
  }
}

# =============================================================================
# Dispatch + JSON 프로토콜
# =============================================================================
# v1.7.0 — OCR engine + UIA element process-scope cache
# =============================================================================
# server 가 long-running 이라 OCR engine 1회 init 후 영속, UIA 객체도 같은 STA
# thread 에서 reuse. cold-start ~700ms × N → warm ~50ms × N.
# =============================================================================
$Script:_OCREngine = $null
$Script:_OCRError = $null
$Script:_UIALoaded = $false

function _Server-Ensure-OCR {
  if ($Script:_OCREngine) { return $true }
  try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
    [void][Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType=WindowsRuntime]
    [void][Windows.Storage.StorageFile, Windows.Storage, ContentType=WindowsRuntime]
    [void][Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
    [void][Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
    [void][Windows.Storage.Streams.RandomAccessStream, Windows.Storage.Streams, ContentType=WindowsRuntime]
    [void][Windows.Globalization.Language, Windows.Globalization, ContentType=WindowsRuntime]
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if (-not $engine) {
      $avail = [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages
      if ($avail -and $avail.Count -gt 0) {
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($avail[0])
      }
    }
    if (-not $engine) { $Script:_OCRError = "no_ocr_language_available"; return $false }
    $Script:_OCREngine = $engine
    return $true
  } catch {
    $Script:_OCRError = $_.Exception.Message
    return $false
  }
}

function _Server-Ensure-UIA {
  if ($Script:_UIALoaded) { return $true }
  try {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    Add-Type -AssemblyName WindowsBase -ErrorAction Stop
    $Script:_UIALoaded = $true
    return $true
  } catch { return $false }
}

# =============================================================================
# Action: ocr-screen-fast (read-only, server-cached engine)
# screen region 캡처 + OCR. server scope OcrEngine reuse 로 cold start 회피.
# =============================================================================
function _Action-OcrScreenFast {
  param([hashtable]$Args)
  if (-not (_Ensure-Win32Loaded)) {
    return @{ status="error"; reason="win32_unavailable" }
  }
  if (-not (_Server-Ensure-OCR)) {
    return @{ status="error"; reason="ocr_init_failed"; detail=$Script:_OCRError }
  }
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop
  # region 결정 (전체 가상 데스크톱 또는 인자 X/Y/W/H)
  $vx = 0; $vy = 0; $vw = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $vw = [System.Windows.Forms.SystemInformation]::VirtualScreen.Width
  } catch { }
  $sx = if ($Args.X) { [int]$Args.X } else { 0 }
  $sy = if ($Args.Y) { [int]$Args.Y } else { 0 }
  $sw = if ($Args.W) { [int]$Args.W } else { 800 }
  $sh = if ($Args.H) { [int]$Args.H } else { 600 }
  $maxDim = 10000
  try { $maxDim = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension } catch { }
  if ($sw -gt $maxDim -or $sh -gt $maxDim) {
    return @{ status="error"; reason="region_exceeds_max_image_dimension"; max_dim=$maxDim }
  }
  $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "cucp-srv-ocr-$([guid]::NewGuid().ToString('N')).png")
  $bmp = $null; $g = $null
  try {
    $bmp = New-Object System.Drawing.Bitmap $sw, $sh
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($sx, $sy, 0, 0, (New-Object System.Drawing.Size $sw, $sh))
    $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
  } catch {
    return @{ status="error"; reason="screenshot_failed"; detail=$_.Exception.Message }
  } finally {
    if ($g) { $g.Dispose() }
    if ($bmp) { $bmp.Dispose() }
  }
  # OCR — async helper
  try {
    $asTask = [WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
      $_.Name -eq "AsTask" -and $_.GetParameters().Count -eq 1 -and $_.IsGenericMethod
    } | Select-Object -First 1
    function _AsyncWait { param($Op, [Type]$T)
      $g = $asTask.MakeGenericMethod($T)
      $t = $g.Invoke($null, @($Op))
      $t.Wait()
      return $t.Result
    }
    $file = _AsyncWait ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tmp)) ([Windows.Storage.StorageFile])
    $stream = _AsyncWait ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = _AsyncWait ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $sbmp = _AsyncWait ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $result = _AsyncWait ($Script:_OCREngine.RecognizeAsync($sbmp)) ([Windows.Media.Ocr.OcrResult])
    $lines = @()
    foreach ($line in $result.Lines) {
      $lines += @{
        text = $line.Text
        word_count = $line.Words.Count
      }
    }
    return @{
      status = "ok"
      schema = "cucp.ocr-screen/v1"
      region = @{ x=$sx; y=$sy; w=$sw; h=$sh }
      text = $result.Text
      line_count = $lines.Count
      lines = $lines
      engine_warm = $true
    }
  } catch {
    return @{ status="error"; reason="ocr_failed"; detail=$_.Exception.Message }
  } finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

# =============================================================================
# Action: uia-find-fast (read-only, server-cached UIA)
# 같은 server process 안에서 UIAutomation assembly 1회 load, 매 호출 reuse.
# =============================================================================
function _Action-UiaFindFast {
  param([hashtable]$Args)
  if (-not (_Server-Ensure-UIA)) {
    return @{ status="error"; reason="uia_load_failed" }
  }
  if (-not (_Ensure-Win32Loaded)) {
    return @{ status="error"; reason="win32_unavailable" }
  }
  $label = if ($Args.Label) { "$($Args.Label)" } else { $null }
  $match = if ($Args.Match) { "$($Args.Match)" } else { $null }
  if (-not $label) {
    return @{ status="error"; reason="missing_label" }
  }
  try {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    # 좁은 scope — match 가 있으면 해당 윈도우만, 없으면 root children 중 visible
    $scope = [System.Windows.Automation.TreeScope]::Children
    $target = $root
    if ($match) {
      $rxMatch = [regex]::new([regex]::Escape($match), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
      $children = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
      foreach ($w in $children) {
        try {
          $title = "$($w.Current.Name)"
          if ($rxMatch.IsMatch($title)) { $target = $w; break }
        } catch { }
      }
    }
    # Subtree 안에서 Name 부분 일치 (case-insensitive)
    $rxLabel = [regex]::new([regex]::Escape($label), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $cands = New-Object System.Collections.ArrayList
    $all = $target.FindAll([System.Windows.Automation.TreeScope]::Subtree, [System.Windows.Automation.Condition]::TrueCondition)
    $idx = 0
    foreach ($el in $all) {
      $idx++
      if ($idx -gt 800) { break }  # cap
      try {
        $name = "$($el.Current.Name)"
        if (-not $name) { continue }
        if (-not $rxLabel.IsMatch($name)) { continue }
        $rect = $el.Current.BoundingRectangle
        if ($rect.Width -le 0 -or $rect.Height -le 0) { continue }
        $score = 50
        if ($name -ieq $label) { $score = 100 }
        elseif ($name.ToLowerInvariant().StartsWith($label.ToLowerInvariant())) { $score = 80 }
        $cx = [int]($rect.X + $rect.Width / 2)
        $cy = [int]($rect.Y + $rect.Height / 2)
        [void]$cands.Add(@{
          name = $name
          score = $score
          rect = @{ x=[int]$rect.X; y=[int]$rect.Y; w=[int]$rect.Width; h=[int]$rect.Height }
          click_point = @{ x=$cx; y=$cy }
          control_type = "$($el.Current.LocalizedControlType)"
        })
        if ($cands.Count -ge 16) { break }
      } catch { continue }
    }
    $sorted = @($cands | Sort-Object -Property score -Descending)
    $best = if ($sorted.Count -gt 0) { $sorted[0] } else { $null }
    if ($best) {
      return @{
        status = "ok"
        schema = "cucp.uia-find/v1"
        label = $label
        match = $match
        score = [int]$best.score
        best = $best
        candidates = @($sorted)
        candidate_count = [int]$sorted.Count
        uia_warm = $true
      }
    } else {
      return @{
        status = "partial"
        reason = "no_match"
        label = $label
        match = $match
        candidate_count = 0
      }
    }
  } catch {
    return @{ status="error"; reason="uia_query_failed"; detail=$_.Exception.Message }
  }
}

# =============================================================================
# Dispatch + JSON 프로토콜
# =============================================================================
$Script:_StartedAt = [DateTime]::UtcNow
$Script:_RequestCount = 0

function _Dispatch {
  param([string]$Action, [hashtable]$Args)
  $Script:_RequestCount++
  switch ($Action) {
    "windows"          { return _Action-Windows -Args $Args }
    "health"           { return _Action-Health -Args $Args }
    "focused"          { return _Action-Focused -Args $Args }
    "modal-detect"     { return _Action-ModalDetect -Args $Args }
    "ocr-screen-fast"  { return _Action-OcrScreenFast -Args $Args }
    "uia-find-fast"    { return _Action-UiaFindFast -Args $Args }
    "shutdown"         { return @{ status="ok"; shutting_down=$true } }
    default {
      return @{
        status = "fallback_required"
        reason = "action_not_supported_in_server"
        action = $Action
        recommended_action = "wrapper should fall back to child process for this action"
      }
    }
  }
}

# =============================================================================
# Lock file 관리
# =============================================================================
$lockData = @{
  pid = $PID
  pipe_name = $PipeName
  started_at = $Script:_StartedAt.ToString("o")
  helper_version = "2.0.0"
  owner_user = ([Environment]::UserName)
  owner_sid = (try { [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { $null })
}
try {
  $lockJson = $lockData | ConvertTo-Json -Compress
  Set-Content -LiteralPath $LockFile -Value $lockJson -Encoding UTF8
  _Log "lock file written: $LockFile pipe=$PipeName"
} catch {
  _Log "lock file write failed: $($_.Exception.Message)"
}

# 종료 핸들러 — lock file cleanup
$cleanupBlock = {
  try {
    if (Test-Path -LiteralPath $LockFile) {
      $existing = $null
      try { $existing = Get-Content -LiteralPath $LockFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
      # 자기 PID 가 아닌 경우 lock 안 지움 (다른 helper 가 새로 시작했을 수 있음)
      if ($existing -and [int]$existing.pid -eq $PID) {
        Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
      }
    }
  } catch { }
}
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action $cleanupBlock | Out-Null

# =============================================================================
# Named Pipe Server Loop
# =============================================================================
_Log "starting server: pipe=$PipeName idle_timeout_ms=$IdleTimeoutMs"

$running = $true
$lastActivity = [DateTime]::UtcNow
while ($running) {
  $pipe = $null
  $reader = $null
  $writer = $null
  try {
    $pipe = New-Object System.IO.Pipes.NamedPipeServerStream(
      $PipeName,
      [System.IO.Pipes.PipeDirection]::InOut,
      1,
      [System.IO.Pipes.PipeTransmissionMode]::Byte,
      [System.IO.Pipes.PipeOptions]::None
    )
    # v2.0.0 — Multi-user 격리: pipe 에 owner-only ACL 적용. 같은 머신에서 다른 user
    # session 이 같은 pipe 를 sniff / write 못하게 함. 실패해도 server 자체는 계속
    # (PowerShell 5.x 가 일부 환경에서 GetAccessControl 미지원) — fail-soft.
    try {
      $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
      $sec = New-Object System.IO.Pipes.PipeSecurity
      $rule = New-Object System.IO.Pipes.PipeAccessRule($sid, [System.IO.Pipes.PipeAccessRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)
      $sec.AddAccessRule($rule)
      # pipe.SetAccessControl 은 .NET 4.x Windows PowerShell 에서 지원 (Mono / .NET Core 일부 미지원)
      $pipe.SetAccessControl($sec)
    } catch {
      _Log "PipeSecurity ACL failed (continuing): $($_.Exception.Message)"
    }
    # async wait + idle timeout 체크 (BeginWaitForConnection async, idle 시 cancel)
    $waitAr = $pipe.BeginWaitForConnection($null, $null)
    $idleExit = $false
    while (-not $waitAr.AsyncWaitHandle.WaitOne(100, $false)) {
      if (([DateTime]::UtcNow - $lastActivity).TotalMilliseconds -gt $IdleTimeoutMs) {
        _Log "idle timeout reached, shutting down"
        try { $pipe.Dispose() } catch { }
        $running = $false
        $idleExit = $true
        break
      }
    }
    if ($idleExit) {
      # outer try-finally 거쳐 정상 cleanup
    } else {
      try { $pipe.EndWaitForConnection($waitAr) } catch { _Log "EndWait failed: $($_.Exception.Message)" }
      $reader = New-Object System.IO.StreamReader($pipe, [System.Text.Encoding]::UTF8)
      $writer = New-Object System.IO.StreamWriter($pipe, [System.Text.Encoding]::UTF8)
      $writer.AutoFlush = $true
      _Log "client connected"

      # 한 connection 안에서 여러 request 처리 가능
      $clientLoop = $true
      while ($clientLoop -and $pipe.IsConnected) {
        $line = $null
        try { $line = $reader.ReadLine() } catch { $line = $null }
        if (-not $line) { $clientLoop = $false; continue }
        $lastActivity = [DateTime]::UtcNow
      $reqId = $null
      $action = $null
      $args = $null
      $parseFailed = $false
      try {
        $req = $line | ConvertFrom-Json
        $reqId = $req.id
        $action = "$($req.action)"
        # 객체 -> hashtable 변환
        $args = @{}
        if ($req.args) {
          $req.args.PSObject.Properties | ForEach-Object {
            $args[$_.Name] = $_.Value
          }
        }
      } catch {
        $resp = @{ id = $reqId; exit_code = 1; result = $null; error = "invalid_json: $($_.Exception.Message)" }
        try { $writer.WriteLine(($resp | ConvertTo-Json -Compress -Depth 10)) } catch { }
        $parseFailed = $true
      }
      if ($parseFailed) { continue }

      _Log "req id=$reqId action=$action"
      $result = $null
      $err = $null
      $exitCode = 0
      try {
        $result = _Dispatch -Action $action -Args $args
        if ($result -and $result.status -eq "error") { $exitCode = 1 }
        elseif ($result -and $result.status -eq "partial") { $exitCode = 2 }
        elseif ($result -and $result.status -eq "fallback_required") { $exitCode = 99 }
      } catch {
        $err = $_.Exception.Message
        $exitCode = 1
      }
      $resp = @{
        id = $reqId
        exit_code = $exitCode
        result = $result
        error = $err
      }
      $writeFailed = $false
      try {
        $writer.WriteLine(($resp | ConvertTo-Json -Compress -Depth 12))
      } catch {
        _Log "write failed: $($_.Exception.Message)"
        $writeFailed = $true
      }
      if ($writeFailed) { $clientLoop = $false; continue }

      if ($action -eq "shutdown") {
        _Log "shutdown requested by client"
        $running = $false
        $clientLoop = $false
      }
    }
    } # else (idleExit false 분기 끝)
  } catch {
    _Log "pipe error: $($_.Exception.Message)"
  } finally {
    try { if ($reader) { $reader.Close() } } catch { }
    try { if ($writer) { $writer.Close() } } catch { }
    try { if ($pipe) { $pipe.Dispose() } } catch { }
  }
}

# 종료 시 lock 정리
& $cleanupBlock
_Log "server exited"
exit 0
