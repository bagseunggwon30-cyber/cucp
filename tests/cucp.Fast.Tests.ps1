# Pester 3.x compatible fast smoke tests for CUCP.
# This suite intentionally avoids OCR, screenshots, benchmarks, helper timeouts,
# and live app dependencies. Use tests/cucp.Tests.ps1 for full regression.

$skillRoot = Split-Path -Parent $PSScriptRoot
$wrapper = Join-Path $skillRoot "scripts\cucp.ps1"

function Invoke-CucpFast {
  param([string[]]$ArgList)

  $out = Join-Path $env:TEMP ("cucp-fast-out-" + [guid]::NewGuid().ToString("N") + ".txt")
  $err = Join-Path $env:TEMP ("cucp-fast-err-" + [guid]::NewGuid().ToString("N") + ".txt")
  try {
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList (@(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $wrapper
      ) + $ArgList) -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru -Wait
    $raw = ""
    if (Test-Path -LiteralPath $out) { $raw = Get-Content -LiteralPath $out -Raw -Encoding UTF8 }
    $stderr = ""
    if (Test-Path -LiteralPath $err) { $stderr = Get-Content -LiteralPath $err -Raw -Encoding UTF8 }
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Raw = $raw; Stderr = $stderr }
  } finally {
    Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue
  }
}

function ConvertFrom-CucpJson {
  param([string]$Raw)
  $obj = $null
  try { $obj = $Raw | ConvertFrom-Json } catch { }
  return $obj
}

Describe "cucp fast smoke - syntax" {
  It "parses core PowerShell entry points" {
    $files = @(
      "scripts\cucp.ps1",
      "scripts\cucp-native-helper.ps1",
      "scripts\cucp-helper-server.ps1",
      "scripts\cucp-spec-board.ps1",
      "references\live-cassette-runner.ps1",
      "references\live-verify-summary.ps1"
    )
    foreach ($file in $files) {
      $path = Join-Path $skillRoot $file
      if (-not (Test-Path -LiteralPath $path)) { continue }
      $tokens = $null
      $errors = $null
      [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
      $errors.Count | Should Be 0
    }
  }
}

Describe "cucp fast smoke - wrapper surface" {
  It "reports unified version envelope" {
    $r = Invoke-CucpFast -ArgList @("-Quiet", "version")
    $r.ExitCode | Should Be 0
    $obj = ConvertFrom-CucpJson $r.Raw
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.version/v1"
    $obj.versions.skill | Should Not BeNullOrEmpty
  }

  It "health-quick brief completes without helper startup" {
    $r = Invoke-CucpFast -ArgList @("-Quiet", "-Brief", "macro", "health-quick")
    $r.ExitCode | Should Be 0
    ($r.Raw -match "health-quick") | Should Be $true
  }

  It "windows JSON returns observation envelope" {
    $r = Invoke-CucpFast -ArgList @("-Quiet", "macro", "windows", "--json-only")
    $r.ExitCode | Should Be 0
    $obj = ConvertFrom-CucpJson $r.Raw
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.observation/v1"
    $obj.kind | Should Be "windows"
  }

  It "cleanup dry-run is safe and parseable" {
    $r = Invoke-CucpFast -ArgList @("-Quiet", "macro", "cleanup", "--dry-run", "--json-only")
    $r.ExitCode | Should Be 0
    $obj = ConvertFrom-CucpJson $r.Raw
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.cleanup/v1"
    $obj.mode | Should Be "dry-run"
    $obj.deleted_count | Should Be 0
  }

  It "new governance macros stay available" {
    $rec = Invoke-CucpFast -ArgList @("-Quiet", "macro", "recorder", "list")
    $rec.ExitCode | Should Be 0
    $policy = Invoke-CucpFast -ArgList @("-Quiet", "-Brief", "macro", "policy-check", "--action", "click-label")
    $policy.ExitCode | Should Be 0
    ($policy.Raw -match "require_confirm") | Should Be $true
  }

  It "spec-board ensure returns the XG5000 context schema" {
    $r = Invoke-CucpFast -ArgList @("-Quiet", "macro", "spec-board", "ensure")
    $r.ExitCode | Should Be 0
    $obj = ConvertFrom-CucpJson $r.Raw
    ($null -ne $obj) | Should Be $true
    $obj.schema | Should Be "cucp.spec-board/v1"
  }

  It "spec-board ladder emits a deterministic draft" {
    $r = Invoke-CucpFast -ArgList @("-Quiet", "macro", "spec-board", "ladder")
    $r.ExitCode | Should Be 0
    ($r.Raw -match "Rung 1: motor self-hold") | Should Be $true
  }
}
