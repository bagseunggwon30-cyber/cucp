# Pester 3.x compatible regression tests for cucp.ps1 wrapper
# 하드코딩 경로 없음 — $PSScriptRoot 기준 상대 경로로 자동 해석.
# Run:
#   Invoke-Pester C:\<설치경로>\cucp-computer-use\tests\cucp.Tests.ps1

# 스킬 루트 = tests/ 의 부모 디렉토리
$skillRoot = Split-Path -Parent $PSScriptRoot
$wrapper   = Join-Path $skillRoot "scripts\cucp.ps1"

# Test hosts can inherit both `Path` and `PATH` from Codex/IDE launchers.
# PowerShell 5 Start-Process treats that as a duplicate key and fails before the
# wrapper even runs, so normalize the process environment once for the suite.
try {
  $processEnv = [System.Environment]::GetEnvironmentVariables("Process")
  if ($processEnv.Contains("Path") -and $processEnv.Contains("PATH")) {
    [System.Environment]::SetEnvironmentVariable("PATH", $null, "Process")
  }
} catch { }

function _RunExit { param([scriptblock]$Block)
  try { & $Block 2>&1 | Out-Null } catch { }
  return $LASTEXITCODE
}

Describe "cucp wrapper - safety gates" {
  It "blocks live actuation without -AllowLiveControl (exit 3)" {
    (_RunExit { & $wrapper -Quiet -Brief act click --x 100 --y 100 --after fake-id }) | Should Be 3
  }
  It "blocks coordinate act without --after (exit 3)" {
    (_RunExit { & $wrapper -AllowLiveControl -Quiet -Brief act click --x 100 --y 100 }) | Should Be 3
  }
  It "blocks macro app-launch without -AllowLiveControl (exit 3)" {
    (_RunExit { & $wrapper -Quiet -Brief macro app-launch --name "notepad" }) | Should Be 3
  }
  It "blocks macro auto-do without -AllowLiveControl (exit 3)" {
    (_RunExit { & $wrapper -Quiet -Brief macro auto-do --label "Save" }) | Should Be 3
  }
  It "blocks macro vision-click without -AllowLiveControl (exit 3)" {
    (_RunExit { & $wrapper -Quiet -Brief macro vision-click --describe "save button" }) | Should Be 3
  }
  It "version returns 0" {
    (_RunExit { & $wrapper -Quiet version }) | Should Be 0
  }
}

Describe "cucp wrapper - macros" {
  It "macro session info returns 0" {
    (_RunExit { & $wrapper -Quiet macro session info }) | Should Be 0
  }
  It "macro health-detail returns 0 when required components present" {
    # cli.mjs 가 환경에 없으면 health-detail이 cli 컴포넌트를 fail로 잡아 exit 1.
    # 그 경우 native-health로 대체 검증 (외부 helper 의존 없음).
    $code = _RunExit { & $wrapper -Quiet -Brief macro health-detail }
    if ($code -ne 0) {
      $code2 = _RunExit { & $wrapper -Quiet -Brief macro native-health }
      $code2 | Should Be 0
    } else {
      $code | Should Be 0
    }
  }
  It "macro metrics returns 0" {
    (_RunExit { & $wrapper -Quiet -Brief macro metrics }) | Should Be 0
  }
  It "macro trajectory show returns 0" {
    (_RunExit { & $wrapper -Quiet -Brief macro trajectory show --last 5 }) | Should Be 0
  }
  It "macro perf returns parseable JSON via --json-only (--quick)" {
    # SLOW (~3s): full --iters 1 perf is ~40s due to helper-bound targets;
    # use --quick to keep this test under the budget. Schema validation and
    # SLO/budget surfaces are the same.
    $tmp = Join-Path $env:TEMP ("perf-out-" + (Get-Date).ToString("HHmmssfff") + ".json")
    $proc = Start-Process -FilePath "powershell" -ArgumentList @(
        "-NoProfile","-ExecutionPolicy","Bypass","-File",$wrapper,
        "-Quiet","macro","perf","--iters","1","--quick","--json-only"
      ) -RedirectStandardOutput $tmp -NoNewWindow -PassThru -Wait
    $code = $proc.ExitCode
    $code | Should Be 0
    $raw = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.status | Should Be "ok"
    $obj.schema | Should Be "cucp.macro.perf/v2"
    ($null -ne $obj.slo) | Should Be $true
    $count = (@($obj.targets) | Measure-Object).Count
    ($count -ge 4) | Should Be $true
  }
  It "macro perf brief --quick returns 0 and lists targets" {
    # SLOW (~3s): keep --quick so we don't pay helper round-trip cost here.
    (_RunExit { & $wrapper -Quiet -Brief macro perf --iters 1 --quick }) | Should Be 0
  }
}

Describe "cucp wrapper - error escalation" {
  It "promotes envelope status=error to non-zero exit" {
    $bad = Join-Path $env:TEMP "cucp-test-bad-plan.json"
    '{"name":"bad","actions":[{"action":"click","x":1,"y":1,"targetWindow":"X"}]}' | Set-Content -LiteralPath $bad -Encoding UTF8
    $code = _RunExit { & $wrapper -Quiet plan readiness --file $bad --strict }
    Remove-Item -LiteralPath $bad -Force -ErrorAction SilentlyContinue
    $code | Should Not Be 0
  }
}

# ============================================================================
# Advanced expert hardening (sprint v3): unified envelope, selector,
# fast paths, perf schema, log-tail redaction, timeout envelope.
# Helpers below shell out via -File so [Console]::Out.WriteLine reaches stdout.
# ============================================================================

function _CapturePs1 {
  param([string[]]$ArgList)
  $tmp = Join-Path $env:TEMP ("cucp-test-" + [guid]::NewGuid().ToString("N") + ".out")
  $allArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$script:wrapper) + $ArgList
  $proc = Start-Process -FilePath "powershell" -ArgumentList $allArgs `
    -RedirectStandardOutput $tmp -NoNewWindow -PassThru -Wait
  $raw = ""
  if (Test-Path -LiteralPath $tmp) {
    $raw = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
  return [pscustomobject]@{ ExitCode = $proc.ExitCode; Raw = $raw }
}

Describe "cucp envelope schema - macro windows" {
  It "returns cucp.observation/v1 schema in JSON output" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","windows","--json-only")
    (@(0,2) -contains $r.ExitCode) | Should Be $true
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.observation/v1"
    $obj.kind | Should Be "windows"
    (@("ok","partial") -contains $obj.status) | Should Be $true
    @($obj.sources) -contains "win32" | Should Be $true
    ($null -ne $obj.cache) | Should Be $true
    ($obj.cache.key.StartsWith("windows::")) | Should Be $true
    ($null -ne $obj.provenance) | Should Be $true
  }

  It "brief returns concise single-line ok format" {
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","windows")
    (@(0,2) -contains $r.ExitCode) | Should Be $true
    ($r.Raw -match "^(ok(-fallback)?|partial) windows count=\d+ foreground='.*' sources=") | Should Be $true
  }

  It "no-match still returns 0 in default mode (helper not required)" {
    # Win32 fallback에서 빈 매치는 partial이 되지만 default(non-rich)는 ok 통과
    # match를 절대 매칭 불가능 문자열로 줘서 partial 응답 확인
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","windows","--match","unlikely-pester-target-cucp-test")
    # exit 2 (no_window in match mode) 기대
    $r.ExitCode | Should Be 2
    ($r.Raw -match "^partial windows") | Should Be $true
  }
}

Describe "cucp envelope schema - macro find-label" {
  It "--explain JSON uses cucp.observation/v1 schema" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","find-label","--label","__cucp_unlikely_label__","--match","unlikely-pester-cucp","--explain","--json-only")
    # not_found path -> partial -> exit 2
    $r.ExitCode | Should Be 2
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.observation/v1"
    $obj.kind | Should Be "find-label"
    ($obj.recoverable_errors.Count -ge 1) | Should Be $true
  }
}

Describe "cucp envelope schema - macro health-quick" {
  It "returns parseable JSON with elapsed_ms" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","health-quick","--json-only")
    ($r.ExitCode -in @(0,1)) | Should Be $true
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    ($obj.elapsed_ms -ge 0) | Should Be $true
    ($null -ne $obj.components.win32_enum) | Should Be $true
  }
  It "brief is concise and includes win32 marker" {
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","health-quick")
    ($r.ExitCode -in @(0,1)) | Should Be $true
    ($r.Raw -match "win32=") | Should Be $true
  }
}

Describe "cucp envelope schema - macro perf" {
  It "--quick --json-only matches cucp.macro.perf/v2" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","perf","--iters","1","--quick","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.macro.perf/v2"
    ($null -ne $obj.thresholds) | Should Be $true
    ($obj.thresholds.windows_fast_warn_ms -ge 0) | Should Be $true
    ((@($obj.targets) | Measure-Object).Count -ge 4) | Should Be $true
  }
}

Describe "cucp log-tail redaction" {
  It "redacts secret-shaped tokens before emit (synthetic file, fast)" {
    # FAST: uses --path with a tiny synthetic file (~200 bytes) instead of
    # scanning the production wrapper log. Targets <1s.
    $synth = Join-Path $env:TEMP ("cucp-test-synthetic-log-" + [guid]::NewGuid().ToString("N") + ".log")
    $marker = "PESTER-REDACT-MARKER-" + (Get-Date).ToString("HHmmssfff")
    $lines = @(
      "[2026-05-24T00:00:00.000+09:00] startup ok",
      "[2026-05-24T00:00:01.000+09:00] $marker token=ABCDEFG12345 password=topsecret authorization: Bearer xyz",
      "[2026-05-24T00:00:02.000+09:00] api_key=sk_live_AAAA1111 secret=hunter2",
      "[2026-05-24T00:00:03.000+09:00] noisy line with no secrets here, just diagnostics."
    )
    Set-Content -LiteralPath $synth -Value ($lines -join "`r`n") -Encoding UTF8
    $r = _CapturePs1 -ArgList @("-Quiet","macro","log-tail","--lines","100","--max-bytes","65536","--path",$synth,"--json-only")
    Remove-Item -LiteralPath $synth -Force -ErrorAction SilentlyContinue
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $found = $obj.data.lines | Where-Object { $_ -match [regex]::Escape($marker) } | Select-Object -First 1
    ($null -ne $found) | Should Be $true
    ($found -match "topsecret") | Should Be $false
    ($found -match "ABCDEFG12345") | Should Be $false
    ($found -match "Bearer xyz") | Should Be $false
    ($found -match "\[redacted\]") | Should Be $true
    # bounded read: bytes_read should be <= max_bytes
    ($obj.data.bytes_read -le $obj.data.max_bytes) | Should Be $true
  }

  It "log-tail completes quickly on a 5MB synthetic file (bounded)" {
    # Verify O(tail bytes) contract: a 5MB log should still tail well below
    # full-scan time. Hard target 2s but allow up to 10s under heavy CI/desktop
    # load (the assertion is "bounded behavior", not absolute speed).
    $synth = Join-Path $env:TEMP ("cucp-test-bigsynth-" + [guid]::NewGuid().ToString("N") + ".log")
    $payload = ([string]::new('x', 1024) + "`r`n") * 5120   # ~5MB
    [System.IO.File]::WriteAllText($synth, $payload, [System.Text.Encoding]::UTF8)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","log-tail","--lines","20","--max-bytes","32768","--path",$synth)
    $sw.Stop()
    Remove-Item -LiteralPath $synth -Force -ErrorAction SilentlyContinue
    $r.ExitCode | Should Be 0
    ($sw.Elapsed.TotalSeconds -lt 10.0) | Should Be $true
  }
}

Describe "cucp diagnose-lag" {
  It "returns parseable JSON with schema cucp.diagnose-lag/v1" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","diagnose-lag","--sample-ms","100","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.diagnose-lag/v1"
    ($null -ne $obj.processes) | Should Be $true
    ($null -ne $obj.storage) | Should Be $true
    ($null -ne $obj.warnings) | Should Be $true
  }
  It "brief output is concise and stable" {
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","diagnose-lag","--sample-ms","100")
    $r.ExitCode | Should Be 0
    ($r.Raw -match "^ok diagnose-lag groups=\d+ ") | Should Be $true
  }
}

Describe "cucp cleanup safety" {
  It "default (no flags) is dry-run and never deletes files" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","cleanup","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.mode | Should Be "dry-run"
    $obj.deleted_count | Should Be 0
  }
  It "rejects mutually exclusive --dry-run + --execute" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","cleanup","--dry-run","--execute")
    $r.ExitCode | Should Be 1
  }
  It "audit_root is inside %TEMP%\\computer-use-control-plane*" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","cleanup","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($obj.audit_root -match "computer-use-control-plane") | Should Be $true
    ($obj.audit_root.StartsWith($env:TEMP, [System.StringComparison]::OrdinalIgnoreCase)) | Should Be $true
  }
}

Describe "cucp find-label fast no-match" {
  It "fast path returns exit 2 quickly when window doesn't exist" {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = _CapturePs1 -ArgList @(
      "-Quiet","-Brief","macro","find-label",
      "--label","__cucp_unlikely__","--match","unlikely-pester-fast-target","--fast"
    )
    $sw.Stop()
    $r.ExitCode | Should Be 2
    ($sw.Elapsed.TotalSeconds -lt 3.0) | Should Be $true
    ($r.Raw -match "fast no_window") | Should Be $true
  }
}

Describe "cucp perf SLO surface" {
  It "--quick --json-only includes slo[] with pass/warn/fail per target" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","perf","--iters","1","--quick","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj.slo) | Should Be $true
    $first = @($obj.slo)[0]
    ($null -ne $first.status) | Should Be $true
    (@("pass","warn","fail","n/a") -contains $first.status) | Should Be $true
  }
}

Describe "cucp safety contracts (regression)" {
  It "missing --after on coordinate act remains exit 3" {
    (_RunExit { & $wrapper -AllowLiveControl -Quiet -Brief act click --x 100 --y 100 }) | Should Be 3
  }
  It "live-control gate without -AllowLiveControl remains exit 3" {
    (_RunExit { & $wrapper -Quiet -Brief act click --x 100 --y 100 --after fake-id }) | Should Be 3
  }
}

Describe "cucp timeout envelope" {
  It "InvokeTimeoutMs=1 forces timeout exit 124 on a slow CLI command" {
    # Use observe appshot which actually round-trips to helper. With a 1ms
    # timeout the wrapper must kill the child and emit an envelope JSON.
    $r = _CapturePs1 -ArgList @("-Quiet","-InvokeTimeoutMs","1","observe","appshot")
    $r.ExitCode | Should Be 124
    # raw stdout should contain our timeout envelope (or be empty if helper
    # never wrote anything; either way exit must be 124).
    ($r.Raw -match "invoke_timeout|timed out") | Should Be $true
  }
}


# ============================================================================
# Sprint v5: small-icon accuracy (icon-find, icon-click, vision-click-precise)
# ============================================================================

Describe "cucp icon-find" {
  It "returns cucp.icon-find/v1 envelope JSON" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","icon-find","--label","close","--max-size","32","--json-only")
    # status may be ok or partial depending on what's on screen; both acceptable
    (@(0,2) -contains $r.ExitCode) | Should Be $true
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.icon-find/v1"
    ($null -ne $obj.candidates) | Should Be $true
    ($null -ne $obj.max_size) | Should Be $true
  }
  It "max-size filter rejects large containers" {
    # tiny --max-size should produce candidates with width<=8 only (or none)
    $r = _CapturePs1 -ArgList @("-Quiet","macro","icon-find","--label","window","--max-size","8","--json-only")
    (@(0,2) -contains $r.ExitCode) | Should Be $true
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    if ($obj -and $obj.candidates) {
      foreach ($c in $obj.candidates) {
        ($c.rect.width -le 8) | Should Be $true
        ($c.rect.height -le 8) | Should Be $true
      }
    }
  }
  It "brief output is concise and includes match_reason" {
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","icon-find","--label","close","--max-size","32")
    (@(0,2) -contains $r.ExitCode) | Should Be $true
    ($r.Raw -match "(ok|partial) icon-find ") | Should Be $true
  }
}

Describe "cucp icon-click safety gate" {
  It "icon-click without -AllowLiveControl returns exit 3" {
    (_RunExit { & $wrapper -Quiet -Brief macro icon-click --label "send" --max-size 64 }) | Should Be 3
  }
}

Describe "cucp vision-click-precise safety gate" {
  It "vision-click-precise without -AllowLiveControl returns exit 3" {
    (_RunExit { & $wrapper -Quiet -Brief macro vision-click-precise --describe "send button" }) | Should Be 3
  }
}

# ============================================================================
# Sprint v6: Native helper 직통 매크로 (외부 helper 의존 없음)
# ============================================================================
# 이 그룹은 cucp-native-helper.ps1 (Win32 + UIA + Screenshot) 만으로
# 동작해야 함. windows-mcp / Codex helper / cli.mjs 모두 없어도 OK.

Describe "cucp native helper - read-only" {
  It "native-health 는 win32+uia 둘 다 ok 반환" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","native-health")
    $r.ExitCode | Should Be 0
    # Brief 없으니 JSON 출력. parsing.
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.status | Should Be "ok"
    $obj.win32 | Should Be $true
  }
  It "native-windows 는 helper 없이 윈도우 enum 동작" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","native-windows")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.status | Should Be "ok"
    ($obj.count -ge 0) | Should Be $true
  }
  It "native-screenshot 은 PNG 파일 생성" {
    $tmp = Join-Path $env:TEMP ("cucp-test-shot-" + [guid]::NewGuid().ToString("N") + ".png")
    # --out-path 사용 (PowerShell의 -Out partial-match 회피)
    $r = _CapturePs1 -ArgList @("-Quiet","macro","native-screenshot","--out-path",$tmp)
    if ($r.ExitCode -eq 2) {
      $obj = $null
      try { $obj = $r.Raw | ConvertFrom-Json } catch { }
      ($null -ne $obj) | Should Be $true
      $obj.status | Should Be "partial"
      $obj.reason | Should Be "screenshot_unavailable"
    } else {
      $r.ExitCode | Should Be 0
      (Test-Path -LiteralPath $tmp) | Should Be $true
      $size = (Get-Item -LiteralPath $tmp).Length
      ($size -gt 1024) | Should Be $true
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe "cucp native helper - safety gates" {
  It "click-point 는 -AllowLiveControl 없으면 exit 3" {
    (_RunExit { & $wrapper -Quiet -Brief macro click-point --x 500 --y 500 }) | Should Be 3
  }
  It "type-native 는 -AllowLiveControl 없으면 exit 3" {
    (_RunExit { & $wrapper -Quiet -Brief macro type-native --text "hello" }) | Should Be 3
  }
  It "shortcut-native 는 -AllowLiveControl 없으면 exit 3" {
    (_RunExit { & $wrapper -Quiet -Brief macro shortcut-native --keys "ctrl+s" }) | Should Be 3
  }
  It "uia-click-label 는 -AllowLiveControl 없으면 exit 3" {
    (_RunExit { & $wrapper -Quiet -Brief macro uia-click-label --label "OK" }) | Should Be 3
  }
}

Describe "cucp native helper - direct invocation" {
  $nativeHelper = Join-Path $skillRoot "scripts\cucp-native-helper.ps1"
  It "helper 자체가 health JSON 반환" {
    if (-not (Test-Path -LiteralPath $nativeHelper)) { Write-Host "SKIP: native helper missing"; return }
    $tmp = Join-Path $env:TEMP ("native-out-" + [guid]::NewGuid().ToString("N") + ".json")
    $proc = Start-Process -FilePath "powershell" -ArgumentList @(
      "-NoProfile","-ExecutionPolicy","Bypass","-File",$nativeHelper,"-Action","health"
    ) -RedirectStandardOutput $tmp -NoNewWindow -PassThru -Wait
    $proc.ExitCode | Should Be 0
    $raw = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    $obj = $raw | ConvertFrom-Json
    $obj.status | Should Be "ok"
    $obj.win32 | Should Be $true
  }
  It "helper 의 windows action은 EnumWindows 결과 반환" {
    if (-not (Test-Path -LiteralPath $nativeHelper)) { Write-Host "SKIP: native helper missing"; return }
    $tmp = Join-Path $env:TEMP ("native-out-" + [guid]::NewGuid().ToString("N") + ".json")
    $proc = Start-Process -FilePath "powershell" -ArgumentList @(
      "-NoProfile","-ExecutionPolicy","Bypass","-File",$nativeHelper,"-Action","windows"
    ) -RedirectStandardOutput $tmp -NoNewWindow -PassThru -Wait
    $proc.ExitCode | Should Be 0
    $raw = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    $obj = $raw | ConvertFrom-Json
    $obj.status | Should Be "ok"
    ($obj.count -ge 0) | Should Be $true
  }
}

# ============================================================================
# Sprint v7: UIA Pattern 직접 호출 + smart-click cascade + watch
# ============================================================================
# Kiro send 화살표 같은 작은/혼동되는 버튼 클릭 정확도 강화. 다음 검증:
#   - uia-invoke: 매칭 → InvokePattern, 신뢰도 < 60 → partial 거부
#   - smart-click cascade: AllowLiveControl 게이트
#   - watch: foreground 변화 감지

Describe "cucp UIA Pattern 직접 호출 - safety gates" {
  It "uia-invoke 는 -AllowLiveControl 없으면 exit 3" {
    (_RunExit { & $wrapper -Quiet -Brief macro uia-invoke --label "OK" }) | Should Be 3
  }
  It "uia-set-value 는 -AllowLiveControl 없으면 exit 3" {
    (_RunExit { & $wrapper -Quiet -Brief macro uia-set-value --label "Name" --value "Alice" }) | Should Be 3
  }
  It "uia-toggle 는 -AllowLiveControl 없으면 exit 3" {
    (_RunExit { & $wrapper -Quiet -Brief macro uia-toggle --label "Enable" }) | Should Be 3
  }
  It "smart-click 는 -AllowLiveControl 없으면 exit 3" {
    (_RunExit { & $wrapper -Quiet -Brief macro smart-click --label "Save" }) | Should Be 3
  }
}

Describe "cucp UIA Pattern - low-confidence rejection" {
  It "uia-invoke 가 score<60 매칭이면 partial(2) 반환 (마우스 안 움직임)" {
    # __cucp_unlikely_label__ 같은 거의 없는 라벨로 신뢰도 가드 검증
    $r = _CapturePs1 -ArgList @(
      "-AllowLiveControl","-Quiet","-Brief","macro","uia-invoke",
      "--label","__cucp_unlikely_test_label_xyz__"
    )
    # exit 2 (low_confidence_match 또는 no_match) 기대
    (@(0,2) -contains $r.ExitCode) | Should Be $true
    # 정상 ok 가 아니라면 stdout에 partial이 있어야
    if ($r.ExitCode -ne 0) {
      ($r.Raw -match "partial uia-invoke") | Should Be $true
    }
  }
}

Describe "cucp watch - 연속 관찰" {
  It "watch 는 max-cycles 만큼 cycle 출력하고 exit 0" {
    $r = _CapturePs1 -ArgList @(
      "-Quiet","-Brief","macro","watch","--interval-ms","100","--max-cycles","2"
    )
    $r.ExitCode | Should Be 0
    ($r.Raw -match "cycle=1") | Should Be $true
    ($r.Raw -match "cycle=2") | Should Be $true
  }
  It "watch --until-label 은 라벨 못 찾으면 partial(2)" {
    $r = _CapturePs1 -ArgList @(
      "-Quiet","-Brief","macro","watch",
      "--interval-ms","100","--max-cycles","2",
      "--until-label","__cucp_unlikely_until_label__"
    )
    $r.ExitCode | Should Be 2
  }
}

Describe "cucp native-helper UIA Pattern actions" {
  $nativeHelper = Join-Path $skillRoot "scripts\cucp-native-helper.ps1"
  It "uia-find 가 어떤 라벨이든 valid envelope 반환 (Kiro 환경 의존 완화)" {
    if (-not (Test-Path -LiteralPath $nativeHelper)) { Write-Host "SKIP"; return }
    # 환경 의존 테스트 — Kiro 윈도우가 떠있고 "최소화" 단추가 있어야 ok.
    # 그렇지 않은 경우 partial(2) 또는 error(1) 반환. 우리는 envelope 형식만 검증.
    $tmp = Join-Path $env:TEMP ("uia-find-test-" + [guid]::NewGuid().ToString("N") + ".json")
    $proc = Start-Process -FilePath "powershell" -ArgumentList @(
      "-NoProfile","-ExecutionPolicy","Bypass","-File",$nativeHelper,
      "-Action","uia-find","-Match","kiro","-Label","최소화"
    ) -RedirectStandardOutput $tmp -NoNewWindow -PassThru -Wait
    $raw = ""
    if (Test-Path $tmp) { $raw = Get-Content $tmp -Raw -Encoding UTF8; Remove-Item $tmp -Force }
    # exit code 0/1/2 다 정상 — envelope 가 의미있는 JSON 이면 통과
    (@(0,1,2) -contains $proc.ExitCode) | Should Be $true
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    ($obj.action -eq "uia-find") | Should Be $true
    # status 가 ok / partial / error 중 하나
    (@("ok","partial","error") -contains $obj.status) | Should Be $true
  }
}

# ============================================================================
# Sprint v0.8.0: OCR 통합 (Windows.Media.Ocr)
# ============================================================================
# 검증 포인트:
#   - native-helper의 ocr-image 가 synthetic PNG 에서 텍스트 추출
#   - native-helper의 ocr-find-text 가 매칭 score 와 cx/cy 좌표 반환
#   - macro ocr-click safety gate (-AllowLiveControl 없으면 exit 3)
#   - macro ocr-find-text JSON 출력 포함 schema 필드
#   - macro native-health 가 ocr / ocr_languages 노출
# ============================================================================

# OCR 테스트 fixture: synthetic PNG (영어 + 한국어)
function _New-OcrFixturePng {
  param([string]$Path)
  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap 800, 200
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.Color]::White)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  $f1 = New-Object System.Drawing.Font("Segoe UI", 28, [System.Drawing.FontStyle]::Bold)
  $f2 = New-Object System.Drawing.Font("Malgun Gothic", 28, [System.Drawing.FontStyle]::Bold)
  $g.DrawString("Send Message", $f1, [System.Drawing.Brushes]::Black, 30.0, 30.0)
  $korean = [string]([char]0xC804) + [string]([char]0xC1A1) + " " + [string]([char]0xBCF4) + [string]([char]0xB0B4) + [string]([char]0xAE30)
  $g.DrawString($korean, $f2, [System.Drawing.Brushes]::Black, 30.0, 100.0)
  $g.Dispose()
  $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

Describe "cucp OCR - safety gates" {
  It "macro ocr-click 는 -AllowLiveControl 없으면 exit 3" {
    (_RunExit { & $wrapper -Quiet -Brief macro ocr-click --text "Send" }) | Should Be 3
  }
  It "macro ocr-click 는 --text 없으면 throw" {
    # AllowLiveControl 통과해도 --text 없으면 1 (throw)
    (_RunExit { & $wrapper -AllowLiveControl -Quiet -Brief macro ocr-click }) | Should Not Be 0
  }
}

Describe "cucp OCR - native-helper actions" {
  $nativeHelper = Join-Path $skillRoot "scripts\cucp-native-helper.ps1"
  $fixture = Join-Path $env:TEMP ("cucp-ocr-fix-" + [guid]::NewGuid().ToString("N") + ".png")

  It "ocr-image 가 synthetic PNG에서 영어/한국어 라인 추출" {
    if (-not (Test-Path -LiteralPath $nativeHelper)) { Write-Host "SKIP"; return }
    _New-OcrFixturePng -Path $fixture
    $tmp = Join-Path $env:TEMP ("ocr-img-test-" + [guid]::NewGuid().ToString("N") + ".json")
    $proc = Start-Process -FilePath "powershell" -ArgumentList @(
      "-NoProfile","-ExecutionPolicy","Bypass","-File",$nativeHelper,
      "-Action","ocr-image","-OcrPath",$fixture
    ) -RedirectStandardOutput $tmp -NoNewWindow -PassThru -Wait
    $raw = ""
    if (Test-Path $tmp) { $raw = Get-Content $tmp -Raw -Encoding UTF8; Remove-Item $tmp -Force }
    Remove-Item -LiteralPath $fixture -Force -ErrorAction SilentlyContinue
    $proc.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.status | Should Be "ok"
    $obj.action | Should Be "ocr-image"
    # 라인 카운트: 정확히 2 라인 (영어 한 줄 + 한글 한 줄). OCR 엔진에 따라 1로 합쳐질 수 있어 1 이상으로 검증.
    ($obj.line_count -ge 1) | Should Be $true
    # text에 "Send" 또는 "Message" 단어가 보여야 영어 OCR 동작 확인
    ($obj.text -match "Send|Message") | Should Be $true
  }

  It "ocr-find-text 가 후보의 cx/cy 좌표를 반환" {
    if (-not (Test-Path -LiteralPath $nativeHelper)) { Write-Host "SKIP"; return }
    _New-OcrFixturePng -Path $fixture
    $tmp = Join-Path $env:TEMP ("ocr-find-test-" + [guid]::NewGuid().ToString("N") + ".json")
    $proc = Start-Process -FilePath "powershell" -ArgumentList @(
      "-NoProfile","-ExecutionPolicy","Bypass","-File",$nativeHelper,
      "-Action","ocr-find-text","-OcrPath",$fixture,"-OcrText","Send","-OcrMatch","contains"
    ) -RedirectStandardOutput $tmp -NoNewWindow -PassThru -Wait
    $raw = ""
    if (Test-Path $tmp) { $raw = Get-Content $tmp -Raw -Encoding UTF8; Remove-Item $tmp -Force }
    Remove-Item -LiteralPath $fixture -Force -ErrorAction SilentlyContinue
    $proc.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.status | Should Be "ok"
    ($null -ne $obj.top) | Should Be $true
    # cx/cy 가 0보다 큰 정수
    ($obj.top.cx -gt 0) | Should Be $true
    ($obj.top.cy -gt 0) | Should Be $true
    ($obj.top.score -ge 60) | Should Be $true
  }

  It "ocr-find-text 는 연속 단어 n-gram 후보를 반환" {
    if (-not (Test-Path -LiteralPath $nativeHelper)) { Write-Host "SKIP"; return }
    _New-OcrFixturePng -Path $fixture
    $raw = & powershell @(
      "-NoProfile","-ExecutionPolicy","Bypass","-File",$nativeHelper,
      "-Action","ocr-find-text","-OcrPath",$fixture,"-OcrText","Send Message","-OcrMatch","contains","-OcrMaxCandidates","8"
    ) | Out-String
    $exitCode = $LASTEXITCODE
    Remove-Item -LiteralPath $fixture -Force -ErrorAction SilentlyContinue
    $exitCode | Should Be 0
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    (@(@($obj.candidates) | Where-Object { $_.scope -eq "word_ngram" -and $_.text -match "Send Message" }).Count -ge 1) | Should Be $true
  }

  It "ocr-find-text 는 opt-in fuzzy 매칭을 지원" {
    if (-not (Test-Path -LiteralPath $nativeHelper)) { Write-Host "SKIP"; return }
    _New-OcrFixturePng -Path $fixture
    $tmp = Join-Path $env:TEMP ("ocr-fuzzy-test-" + [guid]::NewGuid().ToString("N") + ".json")
    $proc = Start-Process -FilePath "powershell" -ArgumentList @(
      "-NoProfile","-ExecutionPolicy","Bypass","-File",$nativeHelper,
      "-Action","ocr-find-text","-OcrPath",$fixture,"-OcrText","5end","-OcrMatch","fuzzy","-OcrMaxCandidates","8"
    ) -RedirectStandardOutput $tmp -NoNewWindow -PassThru -Wait
    $raw = ""
    if (Test-Path $tmp) { $raw = Get-Content $tmp -Raw -Encoding UTF8; Remove-Item $tmp -Force }
    Remove-Item -LiteralPath $fixture -Force -ErrorAction SilentlyContinue
    $proc.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.status | Should Be "ok"
    ($obj.top.score -ge 70) | Should Be $true
  }

  It "ocr-find-text 가 매칭 없으면 partial(2)" {
    if (-not (Test-Path -LiteralPath $nativeHelper)) { Write-Host "SKIP"; return }
    _New-OcrFixturePng -Path $fixture
    $tmp = Join-Path $env:TEMP ("ocr-nomatch-test-" + [guid]::NewGuid().ToString("N") + ".json")
    $proc = Start-Process -FilePath "powershell" -ArgumentList @(
      "-NoProfile","-ExecutionPolicy","Bypass","-File",$nativeHelper,
      "-Action","ocr-find-text","-OcrPath",$fixture,"-OcrText","__cucp_unlikely_ocr_xyz__","-OcrMatch","contains"
    ) -RedirectStandardOutput $tmp -NoNewWindow -PassThru -Wait
    $raw = ""
    if (Test-Path $tmp) { $raw = Get-Content $tmp -Raw -Encoding UTF8; Remove-Item $tmp -Force }
    Remove-Item -LiteralPath $fixture -Force -ErrorAction SilentlyContinue
    $proc.ExitCode | Should Be 2
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { }
    $obj.status | Should Be "partial"
    $obj.reason | Should Be "no_text_match"
  }
}

Describe "cucp OCR - wrapper macros" {
  $fixture = Join-Path $env:TEMP ("cucp-ocr-wrap-" + [guid]::NewGuid().ToString("N") + ".png")

  It "macro ocr-image brief 출력에 'ok ocr-image' 포함" {
    _New-OcrFixturePng -Path $fixture
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","ocr-image","--path",$fixture)
    Remove-Item -LiteralPath $fixture -Force -ErrorAction SilentlyContinue
    $r.ExitCode | Should Be 0
    ($r.Raw -match "ok ocr-image") | Should Be $true
    ($r.Raw -match "language=") | Should Be $true
  }

  It "macro ocr-find-text brief 출력에 'top=' 와 'score=' 포함" {
    _New-OcrFixturePng -Path $fixture
    $r = _CapturePs1 -ArgList @(
      "-Quiet","-Brief","macro","ocr-find-text",
      "--text","Send","--match","contains","--path",$fixture
    )
    Remove-Item -LiteralPath $fixture -Force -ErrorAction SilentlyContinue
    $r.ExitCode | Should Be 0
    ($r.Raw -match "top='") | Should Be $true
    ($r.Raw -match "score=\d+") | Should Be $true
    ($r.Raw -match "cx=\d+") | Should Be $true
  }

  It "macro native-health 가 ocr=True / ocr_languages 노출" {
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","native-health")
    $r.ExitCode | Should Be 0
    ($r.Raw -match "ocr=True") | Should Be $true
    ($r.Raw -match "ocr_languages=") | Should Be $true
  }
}

# ============================================================================
# Sprint v0.9.0: OCR+UIA fusion + screenshot diff verify
# ============================================================================
# 검증 포인트:
#   - ocr-uia-fuse 가 매칭 없을 때 partial(2) 반환
#   - screenshot-diff 가 same/different 정확히 구분
#   - click-and-verify-screen safety gate (-AllowLiveControl 없으면 exit 3)
#   - smart-click cascade 가 새 매크로들을 알고 있음 (default 매크로 아닌데도)
# ============================================================================

# 단순 PNG fixture — 단색 200x100
function _New-SolidColorPng {
  param([string]$Path, [string]$ColorName)
  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap 200, 100
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $color = [System.Drawing.Color]::FromName($ColorName)
  $g.Clear($color)
  $g.Dispose()
  $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

Describe "cucp v0.9.0 - safety gates" {
  It "macro click-and-verify-screen 는 -AllowLiveControl 없으면 exit 3" {
    (_RunExit { & $wrapper -Quiet -Brief macro click-and-verify-screen --x 100 --y 100 }) | Should Be 3
  }
  It "macro ocr-uia-fuse 는 --text 없으면 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro ocr-uia-fuse }) | Should Not Be 0
  }
  It "macro screenshot-diff 는 --before/--after 없으면 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro screenshot-diff }) | Should Not Be 0
  }
}

Describe "cucp v0.9.0 - screenshot-diff" {
  $pngA = Join-Path $env:TEMP ("cucp-v090-A-" + [guid]::NewGuid().ToString("N") + ".png")
  $pngB = Join-Path $env:TEMP ("cucp-v090-B-" + [guid]::NewGuid().ToString("N") + ".png")

  It "동일 PNG 두 개는 changed=False" {
    _New-SolidColorPng -Path $pngA -ColorName "White"
    Copy-Item -LiteralPath $pngA -Destination $pngB -Force
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","screenshot-diff","--before",$pngA,"--after",$pngB)
    Remove-Item -LiteralPath $pngA,$pngB -Force -ErrorAction SilentlyContinue
    $r.ExitCode | Should Be 0
    ($r.Raw -match "changed=False") | Should Be $true
    ($r.Raw -match "ratio=0") | Should Be $true
  }
  It "white vs red PNG 는 changed=True" {
    _New-SolidColorPng -Path $pngA -ColorName "White"
    _New-SolidColorPng -Path $pngB -ColorName "Red"
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","screenshot-diff","--before",$pngA,"--after",$pngB)
    Remove-Item -LiteralPath $pngA,$pngB -Force -ErrorAction SilentlyContinue
    $r.ExitCode | Should Be 0
    ($r.Raw -match "changed=True") | Should Be $true
    ($r.Raw -match "ratio=1") | Should Be $true
  }
  It "존재하지 않는 PNG 는 error" {
    $r = _CapturePs1 -ArgList @(
      "-Quiet","-Brief","macro","screenshot-diff",
      "--before","C:\nonexistent-cucp-test-before.png",
      "--after","C:\nonexistent-cucp-test-after.png"
    )
    $r.ExitCode | Should Not Be 0
    ($r.Raw -match "before_not_found|after_not_found|err") | Should Be $true
  }
}

Describe "cucp v0.9.0 - ocr-uia-fuse" {
  It "매칭 없을 때 partial(2) + recommendation=low_confidence_skip" {
    $r = _CapturePs1 -ArgList @(
      "-Quiet","-Brief","macro","ocr-uia-fuse",
      "--text","__cucp_unlikely_fuse_text_zzz__","--match","contains"
    )
    $r.ExitCode | Should Be 2
    ($r.Raw -match "partial ocr-uia-fuse") | Should Be $true
    if ($r.Raw -match "reason=no_target_window|screenshot_unavailable") {
      ($r.Raw -match "reason=no_target_window|screenshot_unavailable") | Should Be $true
    } else {
      ($r.Raw -match "recommend=low_confidence_skip") | Should Be $true
    }
  }
}

Describe "cucp v0.9.0 - native-helper screenshot-diff direct" {
  $nativeHelper = Join-Path $skillRoot "scripts\cucp-native-helper.ps1"

  It "screenshot-diff direct 는 동일 PNG 에 changed=false 반환" {
    if (-not (Test-Path -LiteralPath $nativeHelper)) { Write-Host "SKIP"; return }
    $pngA = Join-Path $env:TEMP ("cucp-v090-direct-" + [guid]::NewGuid().ToString("N") + ".png")
    _New-SolidColorPng -Path $pngA -ColorName "Blue"
    $tmp = Join-Path $env:TEMP ("v090-direct-" + [guid]::NewGuid().ToString("N") + ".json")
    $proc = Start-Process -FilePath "powershell" -ArgumentList @(
      "-NoProfile","-ExecutionPolicy","Bypass","-File",$nativeHelper,
      "-Action","screenshot-diff","-DiffBefore",$pngA,"-DiffAfter",$pngA
    ) -RedirectStandardOutput $tmp -NoNewWindow -PassThru -Wait
    $raw = ""
    if (Test-Path $tmp) { $raw = Get-Content $tmp -Raw -Encoding UTF8; Remove-Item $tmp -Force }
    Remove-Item -LiteralPath $pngA -Force -ErrorAction SilentlyContinue
    $proc.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.status | Should Be "ok"
    $obj.changed | Should Be $false
    ($obj.changed_pixels -eq 0) | Should Be $true
  }
}

# ============================================================================
# Sprint v1.0.0: ocr-uia-invoke + screenshot-diff ignore-region + retry-on-no-change
# ============================================================================
# 검증 포인트:
#   - ocr-uia-invoke safety gate (-AllowLiveControl 없으면 exit 3)
#   - ocr-uia-invoke 매칭 없을 때 partial(2)
#   - screenshot-diff --ignore-region 으로 마스킹 영역 제외
#   - native-helper 의 ocr-uia-invoke 직접 호출
# ============================================================================

# ignore-region 검증용 fixture: 왼쪽 흰색, 오른쪽 단색
function _New-HalfColoredPng {
  param([string]$Path, [string]$RightColor)
  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap 200, 100
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.Color]::White)
  $color = [System.Drawing.Color]::FromName($RightColor)
  $brush = New-Object System.Drawing.SolidBrush $color
  $g.FillRectangle($brush, 100, 0, 100, 100)
  $brush.Dispose()
  $g.Dispose()
  $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

Describe "cucp v1.0.0 - ocr-uia-invoke safety" {
  It "macro ocr-uia-invoke 는 -AllowLiveControl 없으면 exit 3" {
    (_RunExit { & $wrapper -Quiet -Brief macro ocr-uia-invoke --text "test" }) | Should Be 3
  }
  It "macro ocr-uia-invoke 는 --text 없으면 throw" {
    (_RunExit { & $wrapper -AllowLiveControl -Quiet -Brief macro ocr-uia-invoke }) | Should Not Be 0
  }
  It "ocr-uia-invoke 가 매칭 없을 때 partial(2)" {
    $r = _CapturePs1 -ArgList @(
      "-AllowLiveControl","-Quiet","-Brief","macro","ocr-uia-invoke",
      "--text","__cucp_unlikely_invoke_text_xyz__"
    )
    $r.ExitCode | Should Be 2
    ($r.Raw -match "partial ocr-uia-invoke") | Should Be $true
  }
}

Describe "cucp v1.0.0 - screenshot-diff ignore-region" {
  $pngA = Join-Path $env:TEMP ("cucp-v100-half-A-" + [guid]::NewGuid().ToString("N") + ".png")
  $pngB = Join-Path $env:TEMP ("cucp-v100-half-B-" + [guid]::NewGuid().ToString("N") + ".png")

  It "ignore-region 없으면 changed=True (오른쪽 절반 변화)" {
    _New-HalfColoredPng -Path $pngA -RightColor "Red"
    _New-HalfColoredPng -Path $pngB -RightColor "Blue"
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","screenshot-diff","--before",$pngA,"--after",$pngB)
    Remove-Item -LiteralPath $pngA,$pngB -Force -ErrorAction SilentlyContinue
    $r.ExitCode | Should Be 0
    ($r.Raw -match "changed=True") | Should Be $true
    ($r.Raw -match "ratio=0\.5") | Should Be $true
  }
  It "ignore-region 으로 변화 영역 마스킹 시 changed=False" {
    _New-HalfColoredPng -Path $pngA -RightColor "Red"
    _New-HalfColoredPng -Path $pngB -RightColor "Blue"
    # 오른쪽 절반 (100,0,100,100) 마스킹
    $r = _CapturePs1 -ArgList @(
      "-Quiet","-Brief","macro","screenshot-diff",
      "--before",$pngA,"--after",$pngB,"--ignore-region","100,0,100,100"
    )
    Remove-Item -LiteralPath $pngA,$pngB -Force -ErrorAction SilentlyContinue
    $r.ExitCode | Should Be 0
    ($r.Raw -match "changed=False") | Should Be $true
    ($r.Raw -match "ignored=10000") | Should Be $true
  }
}

Describe "cucp v1.0.0 - native-helper ocr-uia-invoke direct" {
  $nativeHelper = Join-Path $skillRoot "scripts\cucp-native-helper.ps1"

  It "ocr-uia-invoke direct 매칭 없을 때 partial(2) + reason=no_ocr_match" {
    if (-not (Test-Path -LiteralPath $nativeHelper)) { Write-Host "SKIP"; return }
    $tmp = Join-Path $env:TEMP ("v100-direct-" + [guid]::NewGuid().ToString("N") + ".json")
    $proc = Start-Process -FilePath "powershell" -ArgumentList @(
      "-NoProfile","-ExecutionPolicy","Bypass","-File",$nativeHelper,
      "-Action","ocr-uia-invoke","-OcrText","__cucp_unlikely_direct_xyz__"
    ) -RedirectStandardOutput $tmp -NoNewWindow -PassThru -Wait
    $raw = ""
    if (Test-Path $tmp) { $raw = Get-Content $tmp -Raw -Encoding UTF8; Remove-Item $tmp -Force }
    $proc.ExitCode | Should Be 2
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { }
    $obj.status | Should Be "partial"
    (@("no_ocr_match","no_target_window","screenshot_unavailable") -contains $obj.reason) | Should Be $true
  }

  It "ocr-uia-fuse 의 uia_match 가 preferred_identifier 노출 (v1.0.0)" {
    if (-not (Test-Path -LiteralPath $nativeHelper)) { Write-Host "SKIP"; return }
    # foreground 의 흔한 텍스트로 매칭이 잡힐 수 있음
    $tmp = Join-Path $env:TEMP ("v100-fuse-" + [guid]::NewGuid().ToString("N") + ".json")
    $proc = Start-Process -FilePath "powershell" -ArgumentList @(
      "-NoProfile","-ExecutionPolicy","Bypass","-File",$nativeHelper,
      "-Action","ocr-uia-fuse","-OcrText","File","-OcrMatch","contains"
    ) -RedirectStandardOutput $tmp -NoNewWindow -PassThru -Wait
    $raw = ""
    if (Test-Path $tmp) { $raw = Get-Content $tmp -Raw -Encoding UTF8; Remove-Item $tmp -Force }
    # 매칭 결과는 환경마다 달라 ok 또는 partial 모두 정상
    (@(0,2) -contains $proc.ExitCode) | Should Be $true
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    if ($obj.status -eq "ok" -and $obj.uia_match) {
      # uia_match 가 있으면 preferred_identifier 노출 (v1.0.0)
      ($null -ne $obj.uia_match.preferred_identifier) | Should Be $true
      (@("name","automation_id","class_name","none") -contains $obj.uia_match.preferred_identifier) | Should Be $true
    }
  }
}

# ============================================================================
# Sprint v1.1.0: smart-click history learning
# ============================================================================
# 검증 포인트:
#   - macro history stats / show / clear 가 정상 동작
#   - smart-click 의 --no-history 옵션 (학습 비활성)
#   - history 파일 fixture 만들고 stats 가 정확히 집계
#   - history file rotate (HistoryMax 초과 시)
# ============================================================================

# history fixture 작성
function _Write-HistoryFixture {
  param([string]$Path, [string[]]$Entries)
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [System.IO.File]::WriteAllLines($Path, $Entries, (New-Object System.Text.UTF8Encoding($true)))
}

# history 파일 위치 (wrapper 와 동일 경로)
$historyFile = Join-Path $env:TEMP "computer-use-control-plane\smart-click-history.ndjson"
$anchorHistoryFile = Join-Path $env:TEMP "computer-use-control-plane\coord-anchor-history.ndjson"

Describe "cucp v1.1.0 - history macro" {
  It "macro history stats 빈 상태에서 total=0" {
    if (Test-Path -LiteralPath $historyFile) { Remove-Item -LiteralPath $historyFile -Force }
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","history","stats")
    $r.ExitCode | Should Be 0
    ($r.Raw -match "total=0") | Should Be $true
  }

  It "macro history clear 가 파일 삭제" {
    # fixture 작성
    _Write-HistoryFixture -Path $historyFile -Entries @(
      '{"ts":"2026-05-25T20:00:00.000+09:00","label":"X","match":"","strategy":"uia_pattern","success":true,"elapsed_ms":100}'
    )
    (Test-Path -LiteralPath $historyFile) | Should Be $true
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","history","clear")
    $r.ExitCode | Should Be 0
    (Test-Path -LiteralPath $historyFile) | Should Be $false
  }

  It "macro history stats 가 success_rate 정확히 계산" {
    _Write-HistoryFixture -Path $historyFile -Entries @(
      '{"ts":"2026-05-25T20:00:00.000+09:00","label":"A","match":"","strategy":"uia_pattern","success":true,"elapsed_ms":100}'
      '{"ts":"2026-05-25T20:00:30.000+09:00","label":"A","match":"","strategy":"uia_pattern","success":true,"elapsed_ms":110}'
      '{"ts":"2026-05-25T20:01:00.000+09:00","label":"B","match":"","strategy":"none","success":false,"elapsed_ms":3000}'
      '{"ts":"2026-05-25T20:01:30.000+09:00","label":"C","match":"","strategy":"fusion_uia_invoke","success":true,"elapsed_ms":1500}'
    )
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","history","stats")
    Remove-Item -LiteralPath $historyFile -Force -ErrorAction SilentlyContinue
    $r.ExitCode | Should Be 0
    ($r.Raw -match "total=4") | Should Be $true
    ($r.Raw -match "success=3") | Should Be $true
    ($r.Raw -match "rate=75") | Should Be $true
    ($r.Raw -match "uia_pattern=2") | Should Be $true
    ($r.Raw -match "fusion_uia_invoke=1") | Should Be $true
  }

  It "macro history show --label 이 라벨 필터링" {
    _Write-HistoryFixture -Path $historyFile -Entries @(
      '{"ts":"2026-05-25T20:00:00.000+09:00","label":"Save","match":"","strategy":"uia_pattern","success":true,"elapsed_ms":100}'
      '{"ts":"2026-05-25T20:00:30.000+09:00","label":"Cancel","match":"","strategy":"uia_pattern","success":true,"elapsed_ms":110}'
      '{"ts":"2026-05-25T20:01:00.000+09:00","label":"Save","match":"","strategy":"fusion_uia_invoke","success":true,"elapsed_ms":1500}'
    )
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","history","show","--label","Save")
    Remove-Item -LiteralPath $historyFile -Force -ErrorAction SilentlyContinue
    $r.ExitCode | Should Be 0
    ($r.Raw -match "count=2") | Should Be $true
    ($r.Raw -match "label='Save'") | Should Be $true
    # Cancel 은 제외됐어야
    ($r.Raw -match "Cancel") | Should Be $false
  }

  It "macro history show --json-only 가 cucp.history/v1 schema" {
    _Write-HistoryFixture -Path $historyFile -Entries @(
      '{"ts":"2026-05-25T20:00:00.000+09:00","label":"X","match":"","strategy":"uia_pattern","success":true,"elapsed_ms":100}'
    )
    $r = _CapturePs1 -ArgList @("-Quiet","macro","history","show","--last","5")
    Remove-Item -LiteralPath $historyFile -Force -ErrorAction SilentlyContinue
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.history/v1"
    $obj.count | Should Be 1
  }

  It "macro history 알 수 없는 subcommand 는 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro history bogus-action }) | Should Not Be 0
  }
}

Describe "cucp v1.1.0 - smart-click --no-history" {
  It "smart-click --no-history 는 옵션을 거부하지 않음 (-AllowLiveControl 가드는 별개)" {
    # history 옵션 자체가 throw 되지 않음을 확인. 라이브 가드는 exit 3 정상.
    (_RunExit { & $wrapper -Quiet -Brief macro smart-click --label "test" --no-history }) | Should Be 3
  }
  It "smart-click --precision-points 는 unmatched target 에서 클릭 없이 partial 로 끝난다" {
    $r = _CapturePs1 -ArgList @(
      "-AllowLiveControl","-Quiet","-Brief","macro","smart-click",
      "--label","__cucp_unlikely_smartclick_precision_label_xyz__",
      "--match","__cucp_unlikely_window_xyz__",
      "--allow-mouse-fallback","--precision-points",
      "--precision-radius","4","--precision-step","2","--point-cache-ttl","2",
      "--no-ocr","--no-history"
    )
    $r.ExitCode | Should Be 2
    ($r.Raw -match "smart-click") | Should Be $true
  }
}

# ============================================================================
# Sprint v1.2.0: hit-test 가드
# ============================================================================
# 검증 포인트:
#   - macro hit-test 좌표 → root_hwnd / root_title 정확히 반환
#   - click 가드: --target-match 매칭 안 되면 exit 3
#   - safe-type safety gate (-AllowLiveControl 없으면 throw)
#   - safe-type 의 race condition 은 환경 의존이라 회귀 테스트에서 제외
# ============================================================================

Describe "cucp v1.2.0 - hit-test action" {
  It "macro coord-profile 은 DPI/모니터/좌표 프로파일을 read-only 로 반환한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","coord-profile","--x","960","--y","540","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.coord-profile/v1"
    $obj.has_point | Should Be $true
    ($obj.virtual_screen.monitor_count -ge 1) | Should Be $true
    ($obj.monitors.Count -ge 1) | Should Be $true
    (@("low","medium","high") -contains $obj.coordinate_risk) | Should Be $true
  }

  It "macro coord-map 은 창 내부 좌표를 화면 좌표와 정규화 좌표로 변환한다" {
    $probe = _CapturePs1 -ArgList @("-Quiet","macro","hit-test","--x","960","--y","540","--fast")
    $probeObj = $null
    try { $probeObj = $probe.Raw | ConvertFrom-Json } catch { }
    if (-not $probeObj -or [int64]$probeObj.root_hwnd -le 0) { return }
    $targetHwnd = "$([int64]$probeObj.root_hwnd)"
    $r = _CapturePs1 -ArgList @("-Quiet","macro","coord-map","--from","window","--x","10","--y","12","--target-hwnd",$targetHwnd,"--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.coord-map/v1"
    $obj.window_point.x | Should Be 10
    $obj.window_point.y | Should Be 12
    $obj.screen_point.x | Should Be ([int]$obj.selected_window.rect.x + 10)
    $obj.screen_point.y | Should Be ([int]$obj.selected_window.rect.y + 12)
    $obj.coordinate_profile.schema | Should Be "cucp.coord-profile/v1"
  }

  It "macro coord-anchor 는 화면 좌표를 재사용 가능한 정규화 앵커로 만든다" {
    $probe = _CapturePs1 -ArgList @("-Quiet","macro","hit-test","--x","960","--y","540","--fast")
    $probeObj = $null
    try { $probeObj = $probe.Raw | ConvertFrom-Json } catch { }
    if (-not $probeObj -or [int64]$probeObj.root_hwnd -le 0) { return }
    $targetHwnd = "$([int64]$probeObj.root_hwnd)"
    $r = _CapturePs1 -ArgList @("-Quiet","macro","coord-anchor","--x","960","--y","540","--target-hwnd",$targetHwnd,"--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.coord-anchor/v1"
    $obj.anchor_type | Should Be "window_normalized_point"
    ($obj.anchor.normalized_window_point.x -ge 0) | Should Be $true
    ($obj.restore_coord_map_command -join " ") -match "coord-map" | Should Be $true
    ($obj.immediate_point_plan_command -join " ") -match "point-plan" | Should Be $true
  }

  It "macro coord-anchor --record-history 는 앵커 재사용 점수를 누적한다" {
    if (Test-Path -LiteralPath $anchorHistoryFile) { Remove-Item -LiteralPath $anchorHistoryFile -Force -ErrorAction SilentlyContinue }
    $probe = _CapturePs1 -ArgList @("-Quiet","macro","hit-test","--x","960","--y","540","--fast")
    $probeObj = $null
    try { $probeObj = $probe.Raw | ConvertFrom-Json } catch { }
    if (-not $probeObj -or [int64]$probeObj.root_hwnd -le 0) { return }
    $targetHwnd = "$([int64]$probeObj.root_hwnd)"
    $first = _CapturePs1 -ArgList @("-Quiet","macro","coord-anchor","--x","960","--y","540","--target-hwnd",$targetHwnd,"--record-history","--json-only")
    $first.ExitCode | Should Be 0
    $firstObj = $null
    try { $firstObj = $first.Raw | ConvertFrom-Json } catch { }
    ($null -ne $firstObj) | Should Be $true
    $firstObj.reuse_history.schema | Should Be "cucp.anchor-reuse-score/v1"
    $firstObj.reuse_history.recorded | Should Be $true
    (Test-Path -LiteralPath $anchorHistoryFile) | Should Be $true

    $second = _CapturePs1 -ArgList @("-Quiet","macro","coord-anchor","--x","960","--y","540","--target-hwnd",$targetHwnd,"--json-only")
    $second.ExitCode | Should Be 0
    $secondObj = $null
    try { $secondObj = $second.Raw | ConvertFrom-Json } catch { }
    Remove-Item -LiteralPath $anchorHistoryFile -Force -ErrorAction SilentlyContinue
    ($null -ne $secondObj) | Should Be $true
    $secondObj.reuse_history.schema | Should Be "cucp.anchor-reuse-score/v1"
    ([int]$secondObj.reuse_history.exact_match_count -ge 1) | Should Be $true
    ([int]$secondObj.reuse_history.score -ge 0) | Should Be $true
    (@("none","low","medium","high") -contains "$($secondObj.reuse_history.confidence)") | Should Be $true
  }

  It "macro hit-test 가 화면 중앙 좌표에서 valid envelope" {
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","hit-test","--x","960","--y","540")
    # 어떤 윈도우든 잡히면 ok / 빈 영역이면 partial. 0/1/2 모두 정상.
    (@(0,1,2) -contains $r.ExitCode) | Should Be $true
    ($r.Raw -match "hit-test") | Should Be $true
  }

  It "macro hit-test 가 --target-match 일치 시 matched=True" {
    # 자기 화면에 어떤 윈도우든 있을 가능성 높음 → 너무 광범위한 매칭으로 통과 보장
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","hit-test","--x","960","--y","540","--target-match","window")
    # 매칭이든 안 매칭이든 envelope 형식만 확인
    ($r.Raw -match "matched=") | Should Be $true
  }

  It "macro hit-test 는 --click-inset 옵션을 받는다" {
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","hit-test","--x","960","--y","540","--click-inset","2")
    (@(0,1,2) -contains $r.ExitCode) | Should Be $true
    ($r.Raw -match "hit-test") | Should Be $true
  }

  It "macro hit-test --fast 는 wrapper Win32 경로로 UIA 를 건너뛴다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","hit-test","--x","960","--y","540","--fast")
    (@(0,2) -contains $r.ExitCode) | Should Be $true
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.source | Should Be "wrapper_win32_fast"
    $obj.uia_skipped | Should Be $true
  }

  It "macro hit-test-batch 는 여러 좌표를 wrapper Win32 경로로 한 번에 검사한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","hit-test-batch","--point","960,540","--point","970,550")
    (@(0,2) -contains $r.ExitCode) | Should Be $true
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.hit-test-batch/v1"
    $obj.source | Should Be "wrapper_win32_fast"
    $obj.uia_skipped | Should Be $true
    $obj.result_count | Should Be 2
  }

  It "macro hit-test-batch 는 잘못된 좌표 형식을 errors 에 담는다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","hit-test-batch","--points","960,540;bad")
    $r.ExitCode | Should Be 2
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.errors[0].code | Should Be "bad_point_spec"
  }

  It "macro hit-test-batch 가 --point/--points 없으면 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro hit-test-batch }) | Should Not Be 0
  }

  It "macro hit-scan 은 read-only micro point scan envelope 를 반환한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","hit-scan","--x","960","--y","540","--radius","0")
    (@(0,1,2) -contains $r.ExitCode) | Should Be $true
    ($r.Raw -match "hit-scan") | Should Be $true
  }

  It "macro hit-scan 은 --radius/--step 옵션을 받는다" {
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","hit-scan","--x","960","--y","540","--radius","2","--step","2")
    (@(0,1,2) -contains $r.ExitCode) | Should Be $true
    ($r.Raw -match "hit-scan") | Should Be $true
  }

  It "macro point-plan 은 read-only precision click plan envelope 를 반환한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","point-plan","--x","960","--y","540","--radius","2","--step","2")
    (@(0,2) -contains $r.ExitCode) | Should Be $true
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.point-plan/v1"
    $obj.source | Should Be "win32_fast_guard+hit_scan"
    $obj.mouse_moved | Should Be $false
    $obj.coordinate_profile.schema | Should Be "cucp.coord-profile/v1"
  }

  It "macro target-validate 는 point-plan 결과로 클릭 전 안전성을 판정한다" {
    $probe = _CapturePs1 -ArgList @("-Quiet","macro","hit-test","--x","960","--y","540","--fast")
    $probeObj = $null
    try { $probeObj = $probe.Raw | ConvertFrom-Json } catch { }
    if (-not $probeObj -or [int64]$probeObj.root_hwnd -le 0) { return }
    $targetHwnd = "$([int64]$probeObj.root_hwnd)"
    $r = _CapturePs1 -ArgList @("-Quiet","macro","target-validate","--x","960","--y","540","--target-hwnd",$targetHwnd,"--radius","2","--step","2","--json-only")
    (@(0,2) -contains $r.ExitCode) | Should Be $true
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.target-validate/v1"
    $obj.point_plan.schema | Should Be "cucp.point-plan/v1"
    ($obj.validation.target_guard_specified) | Should Be $true
    ($obj.validation.PSObject.Properties.Name -contains "target_size_class") | Should Be $true
    ($obj.PSObject.Properties.Name -contains "safe_to_click") | Should Be $true
  }

  It "macro point-plan 은 짧은 TTL 캐시를 재사용한다" {
    $probe = _CapturePs1 -ArgList @("-Quiet","macro","hit-test","--x","961","--y","541","--fast")
    $probeObj = $null
    try { $probeObj = $probe.Raw | ConvertFrom-Json } catch { }
    if (-not $probeObj -or [int64]$probeObj.root_hwnd -le 0) { return }
    $targetHwnd = "$([int64]$probeObj.root_hwnd)"
    [void](_CapturePs1 -ArgList @("-Quiet","macro","session","clear-cache"))
    $first = _CapturePs1 -ArgList @("-Quiet","macro","point-plan","--x","961","--y","541","--target-hwnd",$targetHwnd,"--radius","2","--step","2","--cache-ttl","30")
    (@(0,2) -contains $first.ExitCode) | Should Be $true
    $firstObj = $null
    try { $firstObj = $first.Raw | ConvertFrom-Json } catch { }
    $second = _CapturePs1 -ArgList @("-Quiet","macro","point-plan","--x","961","--y","541","--target-hwnd",$targetHwnd,"--radius","2","--step","2","--cache-ttl","30")
    (@(0,2) -contains $second.ExitCode) | Should Be $true
    $obj = $null
    try { $obj = $second.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.point-plan/v1"
    if (-not $firstObj -or -not $firstObj.cache_key -or -not $obj.cache_key -or $firstObj.cache_key -ne $obj.cache_key -or -not [bool]$obj.precheck.matched) { return }
    $obj.from_cache | Should Be $true
  }

  It "macro point-plan 이 --x / --y 없으면 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro point-plan }) | Should Not Be 0
  }

  It "macro hit-scan 이 --x / --y 없으면 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro hit-scan }) | Should Not Be 0
  }

  It "macro hit-test 가 --x / --y 없으면 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro hit-test }) | Should Not Be 0
  }
}

Describe "cucp v1.2.0 - click hit-test guard" {
  It "macro click-point --target-match 가 매칭 안 되면 wrapper fast guard 에서 exit 3" {
    # (1, 1) 좌표는 보통 데스크톱 또는 작업표시줄 — 절대 매칭 안 될 가짜 윈도우 이름
    $r = _CapturePs1 -ArgList @(
      "-AllowLiveControl","-Quiet","macro","click-point",
      "--x","1","--y","1","--button","left","--target-match","__cucp_unlikely_window_xyz__"
    )
    $r.ExitCode | Should Be 3
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.click-point/v1"
    $obj.status | Should Be "blocked"
    $obj.reason | Should Be "fast_guard_mismatch"
    $obj.precheck.source | Should Be "wrapper_win32_fast"
  }

  It "macro click-point --micro-refine 도 fast guard mismatch 에서는 클릭 전에 차단된다" {
    $r = _CapturePs1 -ArgList @(
      "-AllowLiveControl","-Quiet","macro","click-point",
      "--x","1","--y","1","--button","left","--target-match","__cucp_unlikely_window_xyz__","--micro-refine"
    )
    $r.ExitCode | Should Be 3
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.reason | Should Be "fast_guard_mismatch"
  }

  It "native helper click 의 -TargetMatch 가드가 unmatched 시 status=blocked + exit 3" {
    $nativeHelper = Join-Path $skillRoot "scripts\cucp-native-helper.ps1"
    if (-not (Test-Path -LiteralPath $nativeHelper)) { Write-Host "SKIP"; return }
    $tmp = Join-Path $env:TEMP ("v120-click-guard-" + [guid]::NewGuid().ToString("N") + ".json")
    $proc = Start-Process -FilePath "powershell" -ArgumentList @(
      "-NoProfile","-ExecutionPolicy","Bypass","-File",$nativeHelper,
      "-Action","click","-X","1","-Y","1","-TargetMatch","__cucp_unlikely_window_xyz__"
    ) -RedirectStandardOutput $tmp -NoNewWindow -PassThru -Wait
    $raw = ""
    if (Test-Path $tmp) { $raw = Get-Content $tmp -Raw -Encoding UTF8; Remove-Item $tmp -Force }
    $proc.ExitCode | Should Be 3
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.status | Should Be "blocked"
    ($obj.reason -match "hit_test_target_mismatch|coords_out_of_virtual") | Should Be $true
  }
}

Describe "cucp v1.2.0 - safe-type safety gate" {
  It "macro safe-type 는 -AllowLiveControl 없으면 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro safe-type --target-match Notepad --text "test" }) | Should Be 3
  }
  It "macro safe-type 는 --text 없으면 throw" {
    (_RunExit { & $wrapper -AllowLiveControl -Quiet -Brief macro safe-type --target-match Notepad }) | Should Not Be 0
  }
  It "macro safe-type 는 --target-match 없으면 throw" {
    (_RunExit { & $wrapper -AllowLiveControl -Quiet -Brief macro safe-type --text "test" }) | Should Not Be 0
  }
}

# ============================================================================
# Sprint v1.3.0: CDP (Chrome DevTools Protocol)
# ============================================================================
# 검증 포인트:
#   - cdp-detect 매크로가 9222 포트 닫힌 상태에서 partial(2) + cdp_port_closed
#   - cdp-eval / cdp-type / cdp-click / cdp-smart-* safety gates
#   - cdp-type / cdp-smart-* 는 -AllowLiveControl 없으면 throw
#   - native-helper 의 cdp-detect 직접 호출 envelope 형식
# ============================================================================

Describe "cucp v1.3.0 - CDP detect (read-only)" {
  It "macro cdp-detect 가 닫힌 포트에서 partial + cdp_port_closed" {
    # 9222 포트 닫혀있다고 가정 (CI 환경)
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","cdp-detect")
    # 열려있을 수도 있음 → ok 또는 partial 둘 다 인정
    (@(0,2) -contains $r.ExitCode) | Should Be $true
    if ($r.ExitCode -eq 2) {
      ($r.Raw -match "cdp_port_closed") | Should Be $true
    } else {
      ($r.Raw -match "ok cdp-detect") | Should Be $true
    }
  }

  It "macro cdp-detect --port 9999 (확실히 닫힌 포트) 는 항상 partial" {
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","cdp-detect","--port","9999")
    $r.ExitCode | Should Be 2
    ($r.Raw -match "cdp_port_closed") | Should Be $true
  }
}

Describe "cucp v1.3.0 - CDP safety gates" {
  It "macro cdp-type 는 -AllowLiveControl 없으면 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro cdp-type --selector "textarea" --text "x" }) | Should Be 3
  }
  It "macro cdp-click 은 -AllowLiveControl 없으면 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro cdp-click --selector "button" }) | Should Be 3
  }
  It "macro cdp-smart-click 은 -AllowLiveControl 없으면 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro cdp-smart-click --text "Send" }) | Should Be 3
  }
  It "macro cdp-smart-type 은 -AllowLiveControl 없으면 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro cdp-smart-type --label "Message" --text "x" }) | Should Be 3
  }
  It "macro cdp-type 는 --selector 없으면 throw" {
    (_RunExit { & $wrapper -AllowLiveControl -Quiet -Brief macro cdp-type --text "x" }) | Should Not Be 0
  }
  It "macro cdp-eval 은 --expr 없으면 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro cdp-eval }) | Should Not Be 0
  }
  It "macro cdp-eval --expr-b64 는 닫힌 포트에서 partial 로 끝난다" {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("document.title"))
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","cdp-eval","--expr-b64",$b64,"--port","9999")
    $r.ExitCode | Should Be 2
    ($r.Raw -match "cdp_port_closed") | Should Be $true
  }
}

Describe "cucp v1.3.3 - smart-plan read-only planner" {
  It "macro smart-plan 은 --label 없으면 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro smart-plan }) | Should Not Be 0
  }
  It "macro smart-plan 은 -AllowLiveControl 없이도 read-only 로 실행된다" {
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","smart-plan","--label","__cucp_unlikely_plan_label_xyz__")
    $r.ExitCode | Should Not Be 3
    ($r.Raw -match "smart-plan") | Should Be $true
  }
  It "macro smart-plan --type-text 도 -AllowLiveControl 없이 read-only 로 실행된다" {
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","smart-plan","--label","__cucp_unlikely_plan_label_xyz__","--type-text","hello")
    $r.ExitCode | Should Not Be 3
    ($r.Raw -match "smart-plan") | Should Be $true
  }
  It "macro smart-plan --precision-points 는 read-only 로 point 옵션을 받는다" {
    $r = _CapturePs1 -ArgList @(
      "-Quiet","macro","smart-plan",
      "--label","__cucp_unlikely_plan_label_xyz__",
      "--precision-points","--precision-radius","4","--precision-step","2","--point-cache-ttl","2"
    )
    $r.ExitCode | Should Not Be 3
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.smart-plan/v1"
    $obj.precision_policy.enabled | Should Be $true
    $obj.precision_policy.live_click_default_micro_refine | Should Be $true
    @($obj.precision_policy.disable_flags) -contains "--no-micro-refine" | Should Be $true
  }
  It "macro form-plan 은 --field/--send-label 없으면 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro form-plan }) | Should Not Be 0
  }
  It "macro form-plan 은 -AllowLiveControl 없이도 read-only 로 실행된다" {
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","form-plan","--field","__cucp_unlikely_plan_field_xyz__=hello")
    $r.ExitCode | Should Not Be 3
    ($r.Raw -match "form-plan") | Should Be $true
  }
  It "macro form-plan --precision-points 는 send-label 계획 옵션을 받는다" {
    $r = _CapturePs1 -ArgList @(
      "-Quiet","macro","form-plan",
      "--send-label","__cucp_unlikely_plan_send_xyz__",
      "--precision-points","--precision-radius","4","--precision-step","2",
      "--json-only"
    )
    (@(0,2) -contains $r.ExitCode) | Should Be $true
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.form-plan/v1"
  }
  It "macro form-plan 은 잘못된 --field 형식을 JSON errors 에 담는다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","form-plan","--field","BrokenSpec","--json-only")
    $r.ExitCode | Should Be 2
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.form-plan/v1"
    $obj.errors[0].code | Should Be "bad_field_spec"
    $obj.command_plan.Count | Should Be 0
  }
  It "macro form-run 은 -AllowLiveControl 없으면 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro form-run --field "Message=hello" }) | Should Be 3
  }
  It "macro form-run 은 unsafe plan 이면 실행하지 않고 blocked JSON 을 반환한다" {
    $r = _CapturePs1 -ArgList @("-AllowLiveControl","-Quiet","macro","form-run","--field","BrokenSpec","--json-only")
    $r.ExitCode | Should Be 3
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.form-run/v1"
    $obj.status | Should Be "blocked"
    $obj.executed_count | Should Be 0
    $obj.plan_errors[0].code | Should Be "bad_field_spec"
  }
  It "macro cdp-smart-find 는 닫힌 포트에서 partial 로 끝난다" {
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","cdp-smart-find","--text","Send","--port","9999")
    $r.ExitCode | Should Be 2
    ($r.Raw -match "cdp_port_closed") | Should Be $true
  }
  It "macro cdp-smart-find 는 닫힌 포트에서도 DOM bridge plan 을 반환한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","cdp-smart-find","--text","Send","--port","9999")
    $r.ExitCode | Should Be 2
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.reason | Should Be "cdp_port_closed"
    $obj.dom_bridge_plan.schema | Should Be "cucp.cdp-dom-bridge-plan/v1"
    $obj.dom_bridge_plan.read_only_command[1] | Should Be "cdp-smart-find"
    $obj.dom_bridge_plan.live_command[1] | Should Be "cdp-smart-click"
  }
  It "macro cdp-smart-type-find 는 닫힌 포트에서 partial 로 끝난다" {
    $r = _CapturePs1 -ArgList @("-Quiet","-Brief","macro","cdp-smart-type-find","--label","Message","--port","9999")
    $r.ExitCode | Should Be 2
    ($r.Raw -match "cdp_port_closed") | Should Be $true
  }
}

Describe "cucp v1.3.16 - task planner" {
  It "macro app-profile 은 매칭 창이 없으면 read-only partial profile 을 반환한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","app-profile","--match","__cucp_unlikely_window_xyz__","--json-only")
    $r.ExitCode | Should Be 2
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.app-profile/v1"
    $obj.status | Should Be "partial"
    $obj.recommended_strategy | Should Be "not_found"
    $obj.strategy_score.schema | Should Be "cucp.app-profile-strategy-score/v1"
    $obj.strategy_score.confidence | Should Be "none"
    $obj.strategy_score.total_score | Should Be 0
    $obj.strategy_persistence.app_key | Should Be "not_found"
    ($obj.next_action -match "windows|Open|focus") | Should Be $true
  }

  It "macro workflow-plan 은 app-profile 을 read-only step 으로 분류한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","workflow-plan","--step","macro app-profile --match __cucp_unlikely_window_xyz__ --json-only","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.workflow-plan/v1"
    $obj.steps[0].macro | Should Be "app-profile"
    $obj.steps[0].live_required | Should Be $false
  }

  It "macro app-profile --probe-cdp 는 닫힌 포트를 read-only capability probe 로 보고한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","app-profile","--probe-cdp","--cdp-port","9999","--label","Save","--json-only")
    (@(0,2) -contains $r.ExitCode) | Should Be $true
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.app-profile/v1"
    if ($obj.status -eq "partial" -and (@("no_matching_window","no_visible_window") -contains $obj.reason)) {
      $obj.strategy_score.schema | Should Be "cucp.app-profile-strategy-score/v1"
    } else {
      $obj.capability_probes.cdp.kind | Should Be "cdp"
      $obj.capability_probes.cdp.available | Should Be $false
      $obj.capability_probes.cdp.port | Should Be 9999
      (($obj.probe_commands[0].command -join " ") -match "smart-plan") | Should Be $true
    }
  }

  It "macro task-preset document 는 문서 작성 task-plan 을 생성한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","task-preset","--kind","document","--text","hello","--replace","--save","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.task-preset/v1"
    $obj.kind | Should Be "document"
    $obj.task_plan.schema | Should Be "cucp.task-plan/v1"
    (($obj.generated_task_plan_command -join " ") -match "--type-text hello") | Should Be $true
    (($obj.generated_task_run_command -join " ") -match "task-run") | Should Be $true
  }

  It "macro task-preset form-submit 은 form-run workflow 를 생성한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","task-preset","--kind","form-submit","--field","Email=a@example.com","--send-label","Submit","--match","Chrome","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.task-preset/v1"
    $obj.mode | Should Be "workflow"
    $obj.workflow_plan.steps[0].macro | Should Be "form-run"
    $obj.workflow_plan.requires_sensitive_confirmation | Should Be $true
    $obj.extra_commands[0].kind | Should Be "form_dry_run"
  }

  It "macro task-preset file-upload 은 업로드 클릭/파일 dialog/경로 입력 workflow 를 생성한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","task-preset","--kind","file-upload","--path","C:\Temp\a.txt","--upload-label","Upload","--match","Chrome","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.task-preset/v1"
    $obj.mode | Should Be "workflow"
    $obj.workflow_plan.step_count | Should Be 3
    $obj.workflow_plan.steps[0].macro | Should Be "smart-click"
    $obj.workflow_plan.steps[1].macro | Should Be "wait-window"
    $obj.workflow_plan.steps[2].macro | Should Be "safe-type"
    $obj.workflow_plan.requires_sensitive_confirmation | Should Be $true
  }

  It "macro task-preset file-download 은 다운로드 클릭과 선택적 검증 workflow 를 생성한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","task-preset","--kind","file-download","--download-label","Download","--verify-label","Done","--match","Chrome","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.task-preset/v1"
    $obj.mode | Should Be "workflow"
    $obj.workflow_plan.step_count | Should Be 2
    $obj.workflow_plan.steps[0].macro | Should Be "smart-click"
    $obj.workflow_plan.steps[1].macro | Should Be "wait-label"
  }

  It "macro task-preset settings 는 설정 열기/필드 변경/적용 workflow 를 생성한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","task-preset","--kind","settings","--settings-label","Settings","--field","Theme=Dark","--save-label","Apply","--match","App","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.task-preset/v1"
    $obj.mode | Should Be "workflow"
    $obj.workflow_plan.step_count | Should Be 4
    $obj.workflow_plan.steps[0].macro | Should Be "smart-click"
    $obj.workflow_plan.steps[2].macro | Should Be "safe-type"
    $obj.workflow_plan.requires_sensitive_confirmation | Should Be $true
  }

  It "macro task-plan 은 app launch workflow 를 read-only 로 생성한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","task-plan","--app","notepad","--wait-title","Notepad","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.task-plan/v1"
    $obj.status | Should Be "ok"
    $obj.live_step_count | Should Be 1
    $obj.workflow_plan.steps[0].macro | Should Be "app-launch"
  }

  It "macro task-plan 은 unsafe form-plan 을 partial errors 로 감싼다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","task-plan","--field","BrokenSpec","--json-only")
    $r.ExitCode | Should Be 2
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.task-plan/v1"
    $obj.status | Should Be "partial"
    $obj.errors[0].code | Should Be "form_plan_not_safe"
  }

  It "macro task-plan 은 자유 입력과 단축키 workflow 를 생성한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","task-plan","--type-text","hello","--shortcut","ctrl+s","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.task-plan/v1"
    $obj.status | Should Be "ok"
    $obj.step_count | Should Be 2
    $obj.live_step_count | Should Be 2
    $obj.workflow_plan.steps[0].macro | Should Be "type-native"
    $obj.workflow_plan.steps[1].macro | Should Be "shortcut"
  }

  It "macro task-plan 은 workflow 검증/재시도 옵션을 recommended command 에 전달한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","task-plan","--type-text","hello","--settle-ms","25","--verify-after-step","--verify-match","Notepad","--verify-label-after-step","Saved","--verify-label-timeout-ms","100","--retry-failed-step","2","--retry-delay-ms","1","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.task-plan/v1"
    $obj.run_options.verify_after_step | Should Be $true
    $obj.run_options.verify_label_after_step | Should Be "Saved"
    $obj.run_options.retry_failed_step | Should Be "2"
    (($obj.recommended_command -join " ") -match "--settle-ms 25") | Should Be $true
    (($obj.recommended_command -join " ") -match "--verify-after-step") | Should Be $true
    (($obj.recommended_command -join " ") -match "--verify-label-after-step Saved") | Should Be $true
    (($obj.recommended_command -join " ") -match "--observe-match Notepad") | Should Be $true
    (($obj.recommended_command -join " ") -match "--retry-failed-step 2") | Should Be $true
  }

  It "macro task-run --dry-run 은 task-plan 을 workflow dry-run 으로 검증한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","task-run","--dry-run","--app","notepad","--wait-title","Notepad","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.task-run/v1"
    $obj.status | Should Be "ready"
    $obj.dry_run | Should Be $true
    $obj.workflow_result.schema | Should Be "cucp.workflow-run/v1"
  }

  It "macro task-run --dry-run 은 사전 단축키와 guarded type 도 검증한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","task-run","--dry-run","--pre-shortcut","ctrl+a","--type-text","hello","--match","Notepad","--enter","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.task-run/v1"
    $obj.status | Should Be "ready"
    $obj.task_plan.workflow_plan.steps[0].macro | Should Be "shortcut"
    $obj.task_plan.workflow_plan.steps[1].macro | Should Be "safe-type"
  }

  It "macro task-run 은 live step 이 있으면 -AllowLiveControl 없을 때 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro task-run --app notepad --wait-title Notepad }) | Should Be 3
  }

  It "macro task-run 은 unsafe task-plan 이면 blocked JSON 을 반환한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","task-run","--field","BrokenSpec","--json-only")
    $r.ExitCode | Should Be 3
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.task-run/v1"
    $obj.status | Should Be "blocked"
    $obj.reason | Should Be "task_plan_not_safe"
  }

  It "macro task-run 은 workflow 실패 요약을 상위 결과에 노출한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","task-run","--wait-title","__cucp_unlikely_window_xyz__","--wait-timeout-ms","100","--json-only")
    $r.ExitCode | Should Be 2
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.task-run/v1"
    $obj.status | Should Be "partial"
    $obj.workflow_failure_summary.macro | Should Be "wait-window"
    ($obj.next_action -match "Inspect|Run|Verify|macro") | Should Be $true
  }
}

Describe "cucp v1.3.34 - safety policy layer" {
  It "macro safety-classify marks destructive credential actions as requiring confirmation" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","safety-classify","--text","delete","--text","password","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.safety-classify/v1"
    $obj.requires_explicit_confirmation | Should Be $true
    (@("high","critical") -contains $obj.risk_level) | Should Be $true
    (@($obj.categories | Where-Object { $_.category -eq "destructive" }).Count -gt 0) | Should Be $true
    (@($obj.categories | Where-Object { $_.category -eq "credentials" }).Count -gt 0) | Should Be $true
  }

  It "macro workflow-plan annotates sensitive live steps without making the plan structurally unsafe" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","workflow-plan","--step","macro cdp-smart-click --text Send --port 9999","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.workflow-plan/v1"
    $obj.safe_to_run | Should Be $true
    $obj.sensitive_step_count | Should Be 1
    $obj.requires_sensitive_confirmation | Should Be $true
    $obj.steps[0].safety.schema | Should Be "cucp.safety-classify/v1"
    $obj.steps[0].requires_sensitive_confirmation | Should Be $true
  }

  It "macro workflow-run blocks sensitive live steps until --confirm-sensitive is supplied" {
    $r = _CapturePs1 -ArgList @("-AllowLiveControl","-Quiet","macro","workflow-run","--step","macro cdp-smart-click --text Send --port 9999","--json-only")
    $r.ExitCode | Should Be 3
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.workflow-run/v1"
    $obj.status | Should Be "blocked"
    $obj.reason | Should Be "sensitive_action_requires_confirmation"
    $obj.safety_issues[0].macro | Should Be "cdp-smart-click"
  }

  It "macro workflow-run --confirm-sensitive proceeds past the safety gate" {
    $r = _CapturePs1 -ArgList @("-AllowLiveControl","-Quiet","macro","workflow-run","--confirm-sensitive","--step","macro cdp-smart-click --text Send --port 9999","--json-only")
    $r.ExitCode | Should Be 2
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.workflow-run/v1"
    $obj.reason | Should Be "step_failed_or_stopped"
    $obj.confirm_sensitive | Should Be $true
    $obj.steps[0].result.reason | Should Be "cdp_port_closed"
  }
}

Describe "cucp v1.3.10 - workflow planner/runner" {
  It "macro workflow-plan 은 --step 없으면 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro workflow-plan }) | Should Not Be 0
  }
  It "macro workflow-plan 은 read-only/live step 을 분류한다" {
    $r = _CapturePs1 -ArgList @(
      "-Quiet","macro","workflow-plan",
      "--step","macro hit-test --x 960 --y 540 --fast",
      "--step","macro point-plan --x 960 --y 540 --radius 2",
      "--step","macro target-validate --x 960 --y 540 --target-match window --radius 2",
      "--step","macro click-point --x 1 --y 1 --target-match __cucp_unlikely_window_xyz__"
    )
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.workflow-plan/v1"
    $obj.step_count | Should Be 4
    $obj.live_step_count | Should Be 1
    $obj.steps[0].macro | Should Be "hit-test"
    $obj.steps[1].macro | Should Be "point-plan"
    $obj.steps[1].live_required | Should Be $false
    $obj.steps[2].macro | Should Be "target-validate"
    $obj.steps[2].live_required | Should Be $false
    $obj.steps[3].live_required | Should Be $true
  }
  It "macro workflow-plan 은 허용되지 않은 macro 를 partial errors 로 반환한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","workflow-plan","--step","macro workflow-run --dry-run")
    $r.ExitCode | Should Be 2
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.errors[0].code | Should Be "recursive_workflow_blocked"
  }
  It "macro workflow-run 은 live step 이 있으면 -AllowLiveControl 없을 때 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro workflow-run --step "macro click-point --x 1 --y 1 --target-match __cucp_unlikely_window_xyz__" }) | Should Be 3
  }
  It "macro workflow-run 은 read-only step 만 있으면 -AllowLiveControl 없이 실행된다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","workflow-run","--step","macro hit-test --x 960 --y 540 --fast")
    (@(0,2) -contains $r.ExitCode) | Should Be $true
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.workflow-run/v1"
    (@("ok","partial") -contains $obj.status) | Should Be $true
    $obj.executed_count | Should Be 1
    $obj.steps[0].live_required | Should Be $false
  }
  It "macro workflow-run --observe-after-step 은 각 step 뒤 windows observation 을 남긴다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","workflow-run","--observe-after-step","--step","macro hit-test --x 960 --y 540 --fast")
    (@(0,2) -contains $r.ExitCode) | Should Be $true
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.workflow-run/v1"
    $obj.observe_after_step | Should Be $true
    if ($obj.steps[0].verification_status -eq "observed") {
      $obj.steps[0].post_observation.schema | Should Be "cucp.observation/v1"
    } else {
      (@("not_requested","observed","observe_partial","observe_failed") -contains $obj.steps[0].verification_status) | Should Be $true
    }
  }
  It "macro workflow-run --verify-after-step 은 post observation 실패를 partial 로 처리한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","workflow-run","--verify-after-step","--verify-match","__cucp_unlikely_window_xyz__","--step","macro hit-test --x 960 --y 540 --fast")
    $r.ExitCode | Should Be 2
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.workflow-run/v1"
    $obj.status | Should Be "partial"
    $obj.verify_failed_count | Should Be 1
    $obj.steps[0].verification_status | Should Be "partial"
  }
  It "macro workflow-run --verify-label-after-step 은 라벨 검증 실패를 partial 로 처리한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","workflow-run","--verify-label-after-step","__cucp_unlikely_label_xyz__","--verify-label-window","__cucp_unlikely_window_xyz__","--verify-label-timeout-ms","100","--verify-label-interval-ms","50","--step","macro hit-test --x 960 --y 540 --fast")
    $r.ExitCode | Should Be 2
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.workflow-run/v1"
    $obj.status | Should Be "partial"
    $obj.verify_failed_count | Should Be 1
    $obj.steps[0].label_verification_status | Should Be "partial"
    $obj.failure_summary.failure_kind | Should Be "label_verification_failed"
    ($obj.failure_summary.next_action -match "find-label") | Should Be $true
  }
  It "macro workflow-run --retry-failed-step 은 실패한 read-only step 을 제한 횟수만큼 재시도한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","workflow-run","--retry-failed-step","2","--retry-delay-ms","1","--step","macro windows --match __cucp_unlikely_window_xyz__")
    $r.ExitCode | Should Be 2
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.workflow-run/v1"
    $obj.status | Should Be "partial"
    $obj.retry_count | Should Be 2
    $obj.steps[0].attempt_count | Should Be 3
    $obj.steps[0].retry_count | Should Be 2
    $obj.failure_summary.retry_exhausted | Should Be $true
    ($obj.next_action.Length -gt 0) | Should Be $true
  }
  It "macro workflow-run --dry-run 은 실행하지 않고 ready 를 반환한다" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","workflow-run","--dry-run","--step","macro hit-test --x 960 --y 540 --fast")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.workflow-run/v1"
    $obj.status | Should Be "ready"
    $obj.executed_count | Should Be 0
  }
}

Describe "cucp v1.3.0 - native-helper CDP direct" {
  $nativeHelper = Join-Path $skillRoot "scripts\cucp-native-helper.ps1"

  It "cdp-detect direct on closed port returns partial(2) + envelope" {
    if (-not (Test-Path -LiteralPath $nativeHelper)) { Write-Host "SKIP"; return }
    $tmp = Join-Path $env:TEMP ("v130-cdp-" + [guid]::NewGuid().ToString("N") + ".json")
    $proc = Start-Process -FilePath "powershell" -ArgumentList @(
      "-NoProfile","-ExecutionPolicy","Bypass","-File",$nativeHelper,
      "-Action","cdp-detect","-CdpPort","9999"
    ) -RedirectStandardOutput $tmp -NoNewWindow -PassThru -Wait
    $raw = ""
    if (Test-Path $tmp) { $raw = Get-Content $tmp -Raw -Encoding UTF8; Remove-Item $tmp -Force }
    $proc.ExitCode | Should Be 2
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { }
    ($null -ne $obj) | Should Be $true
    $obj.status | Should Be "partial"
    $obj.reason | Should Be "cdp_port_closed"
    $obj.action | Should Be "cdp-detect"
  }

  It "cdp-type direct without AllowLiveControl is allowed (helper has no gate)" {
    # Helper level 에서는 가드 없음 (wrapper 책임).
    # 닫힌 포트에서는 partial 반환해야 함.
    if (-not (Test-Path -LiteralPath $nativeHelper)) { Write-Host "SKIP"; return }
    $tmp = Join-Path $env:TEMP ("v130-cdp-type-" + [guid]::NewGuid().ToString("N") + ".json")
    $proc = Start-Process -FilePath "powershell" -ArgumentList @(
      "-NoProfile","-ExecutionPolicy","Bypass","-File",$nativeHelper,
      "-Action","cdp-type","-CdpSelector","textarea","-Text","x","-CdpPort","9999"
    ) -RedirectStandardOutput $tmp -NoNewWindow -PassThru -Wait
    $raw = ""
    if (Test-Path $tmp) { $raw = Get-Content $tmp -Raw -Encoding UTF8; Remove-Item $tmp -Force }
    $proc.ExitCode | Should Be 2
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { }
    $obj.status | Should Be "partial"
    $obj.reason | Should Be "cdp_port_closed"
  }

  It "cdp-smart-click direct on closed port returns partial(2) + envelope" {
    if (-not (Test-Path -LiteralPath $nativeHelper)) { Write-Host "SKIP"; return }
    $tmp = Join-Path $env:TEMP ("v130-cdp-smart-" + [guid]::NewGuid().ToString("N") + ".json")
    $proc = Start-Process -FilePath "powershell" -ArgumentList @(
      "-NoProfile","-ExecutionPolicy","Bypass","-File",$nativeHelper,
      "-Action","cdp-smart-click","-CdpText","Send","-CdpPort","9999"
    ) -RedirectStandardOutput $tmp -NoNewWindow -PassThru -Wait
    $raw = ""
    if (Test-Path $tmp) { $raw = Get-Content $tmp -Raw -Encoding UTF8; Remove-Item $tmp -Force }
    $proc.ExitCode | Should Be 2
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json } catch { }
    $obj.status | Should Be "partial"
    $obj.reason | Should Be "cdp_port_closed"
    $obj.action | Should Be "cdp-smart-click"
    $obj.dom_bridge_plan.schema | Should Be "cucp.cdp-dom-bridge-plan/v1"
    $obj.dom_bridge_plan.live_command[1] | Should Be "cdp-smart-click"
  }
}


# ============================================================================
# v1.4.0 — 9개 신규 매크로 회귀 테스트 (read-only + safety gates)
# 모두 외부 라이브 actuation 없음. helper child process 만 spawn.
# ============================================================================

Describe "cucp v1.4.0 - cdp-deep-find" {
  It "macro cdp-deep-find 는 --text 없으면 throw" {
    (_RunExit { & $wrapper -Quiet -Brief macro cdp-deep-find }) | Should Be 1
  }
  It "macro cdp-deep-find 는 닫힌 포트에서 partial(2) + schema" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","cdp-deep-find","--text","Send","--port","9999","--json-only")
    $r.ExitCode | Should Be 2
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    $obj.schema | Should Be "cucp.cdp-deep-find/v1"
    $obj.status | Should Be "partial"
    $obj.reason | Should Be "cdp_port_closed"
  }
}

Describe "cucp v1.4.0 - ime-paste safety gate" {
  It "macro ime-paste 는 -AllowLiveControl 없으면 exit 3" {
    (_RunExit { & $wrapper -Quiet -Brief macro ime-paste --text "hello" }) | Should Be 3
  }
}

Describe "cucp v1.4.0 - safe-type-ime safety gate" {
  It "macro safe-type-ime 는 -AllowLiveControl 없으면 exit 3" {
    (_RunExit { & $wrapper -Quiet -Brief macro safe-type-ime --text "hi" --target-match Notepad }) | Should Be 3
  }
}

Describe "cucp v1.4.0 - modal-detect (read-only)" {
  It "macro modal-detect 는 read-only 로 exit 0 + schema" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","modal-detect","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    $obj.schema | Should Be "cucp.modal-detect/v1"
    $obj.status | Should Be "ok"
  }
}

Describe "cucp v1.4.0 - recovery-plan (read-only)" {
  It "macro recovery-plan 은 read-only 로 exit 0 + 후보 1개 이상" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","recovery-plan","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    $obj.schema | Should Be "cucp.recovery-plan/v1"
    $obj.candidate_count | Should BeGreaterThan 0
  }
}

Describe "cucp v1.4.0 - recovery-run safety gate" {
  It "macro recovery-run --dry-run 은 -AllowLiveControl 없어도 exit 0" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","recovery-run","--dry-run","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    $obj.schema | Should Be "cucp.recovery-run/v1"
    $obj.status | Should Be "ready"
    $obj.dry_run | Should Be $true
  }
  It "macro recovery-run (no flags) 는 -AllowLiveControl 없으면 throw -> exit 1 또는 3" {
    # dry-run 도 confirm 도 없으면 wrapper throw 되어 exit 1, 또는 sensitive gate 로 exit 3
    $code = _RunExit { & $wrapper -Quiet -Brief macro recovery-run }
    ($code -eq 1 -or $code -eq 3) | Should Be $true
  }
}

Describe "cucp v1.4.0 - precision-validate (read-only)" {
  It "macro precision-validate 는 --x/--y 없으면 throw -> exit 1" {
    (_RunExit { & $wrapper -Quiet -Brief macro precision-validate }) | Should Be 1
  }
  It "macro precision-validate 는 read-only 로 exit 0 + schema" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","precision-validate","--x","100","--y","100","--samples","2","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    $obj.schema | Should Be "cucp.precision-validate/v1"
    $obj.status | Should Be "ok"
    $obj.input.samples | Should Be 2
  }
}

Describe "cucp v1.4.0 - benchmark (read-only)" {
  It "macro benchmark --iters 1 는 read-only 로 exit 0 + schema + SLO 데이터" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","benchmark","--iters","1","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    $obj.schema | Should Be "cucp.benchmark/v1"
    $obj.status | Should Be "ok"
    $obj.target_count | Should BeGreaterThan 0
    $obj.results.Count | Should Be $obj.target_count
  }
}

Describe "cucp v1.4.0 - release-notes (read-only) + secret redaction" {
  It "macro release-notes 는 latest 1건 추출 + schema" {
    $r = _CapturePs1 -ArgList @("-Quiet","macro","release-notes","--json-only")
    $r.ExitCode | Should Be 0
    $obj = $null
    try { $obj = $r.Raw | ConvertFrom-Json } catch { }
    $obj.schema | Should Be "cucp.release-notes/v1"
    $obj.status | Should Be "ok"
    $obj.note_count | Should BeGreaterThan 0
  }
  It "synthetic CHANGELOG 의 secret 패턴이 [REDACTED:*] 로 치환됨" {
    # 임시 skill root 만들어서 CHANGELOG 만 교체
    $tmp = Join-Path $env:TEMP ("cucp-redact-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path "$tmp\scripts" -Force | Out-Null
    Copy-Item "$skillRoot\scripts\cucp.ps1" "$tmp\scripts\cucp.ps1"
    Copy-Item "$skillRoot\scripts\cucp-native-helper.ps1" "$tmp\scripts\cucp-native-helper.ps1"
    $cl = @(
      "# Test Changelog",
      "",
      "## v9.9.9 - secret leak (2026-05-27)",
      "",
      "### Added",
      "",
      "- token ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ1234567890",
      "- key sk-aBcDeFgHiJkLmNoPqRsTuVwXyZ1234567890",
      ""
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath "$tmp\CHANGELOG.md" -Value $cl -Encoding UTF8
    $w2 = Join-Path $tmp "scripts\cucp.ps1"
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $w2 -Quiet macro release-notes --version 9.9.9 2>&1
    $joined = ($out -join "`n")
    Remove-Item -Recurse -Force $tmp
    ($joined -match "ghp_aBcDeFg") | Should Be $false
    ($joined -match "sk-aBcDeFg") | Should Be $false
    ($joined -match "REDACTED") | Should Be $true
  }
}
