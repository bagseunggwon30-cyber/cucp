param(
  [string]$Root = (Join-Path (Split-Path -Parent $PSScriptRoot) 'live-verify'),
  [string]$Out,
  [switch]$JsonOnly
)

$ErrorActionPreference = 'Stop'

function Get-Reason {
  param($Json)

  $parts = New-Object System.Collections.Generic.List[string]
  if ($Json.reason) { [void]$parts.Add([string]$Json.reason) }
  if ($Json.error) { [void]$parts.Add([string]$Json.error) }
  if ($Json.warnings) {
    foreach ($w in @($Json.warnings)) { if ($w) { [void]$parts.Add([string]$w) } }
  }
  if ($Json.recoverable_errors) {
    foreach ($e in @($Json.recoverable_errors)) {
      if ($e.code) { [void]$parts.Add([string]$e.code) }
      elseif ($e.message) { [void]$parts.Add([string]$e.message) }
      else { [void]$parts.Add(($e | ConvertTo-Json -Compress -Depth 5)) }
    }
  }
  if ($Json.cassette) {
    foreach ($c in @($Json.cassette)) {
      if ($c.reason) { [void]$parts.Add([string]$c.reason) }
      if ($c.status) { [void]$parts.Add("cassette_status=" + [string]$c.status) }
    }
  }
  if ($Json.focus -and $Json.focus.reason) { [void]$parts.Add("focus=" + [string]$Json.focus.reason) }
  if ($Json.paste -and $Json.paste.reason) { [void]$parts.Add("paste=" + [string]$Json.paste.reason) }
  if ($Json.paste -and $Json.paste.detail) { [void]$parts.Add("paste_detail=" + [string]$Json.paste.detail) }
  if ($Json.recommendation) { [void]$parts.Add("recommendation=" + [string]$Json.recommendation) }
  return ($parts | Where-Object { $_ } | Select-Object -Unique) -join ' | '
}

function Get-Class {
  param([string]$Status, [string]$Reason)

  if ($Status -eq 'ok') { return 'pass' }
  if ([string]::IsNullOrWhiteSpace($Status) -and [string]::IsNullOrWhiteSpace($Reason)) { return 'pass' }
  if ([string]::IsNullOrWhiteSpace($Status)) { return 'needs_review' }
  if ($Reason -match 'cdp_port_closed|no_window|no_matching_window|no_text_match|hit_test_target_mismatch|missing_target') {
    return 'environment_missing'
  }
  if ($Status -eq 'partial') { return 'partial_review' }
  return 'fail'
}

if (-not (Test-Path -LiteralPath $Root)) {
  $summary = [pscustomobject][ordered]@{
    schema = 'cucp.live-verify-summary/v1'
    status = 'empty'
    root = $Root
    generated_at = (Get-Date).ToString('o')
    count = 0
    classes = @{}
    items = @()
  }
} else {
  $items = New-Object System.Collections.Generic.List[object]
  foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue) {
    if ($file.Name -eq 'summary.json') { continue }
    $rel = $file.FullName.Substring($Root.Length).TrimStart('\','/')
    $json = $null
    $reason = ''
    $status = 'invalid'
    $schema = $null
    try {
      $json = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
      $status = if ($json.status) { [string]$json.status } else { '' }
      $schema = $json.schema
      $reason = Get-Reason $json
    } catch {
      $reason = $_.Exception.Message
    }
    $class = Get-Class -Status $status -Reason $reason
    [void]$items.Add([pscustomobject]@{
      file = $rel
      status = $status
      class = $class
      schema = $schema
      reason = $reason
      length = $file.Length
      last_write = $file.LastWriteTime.ToString('o')
    })
  }

  $classCounts = @{}
  foreach ($group in ($items | Group-Object class)) { $classCounts[$group.Name] = $group.Count }
  $overall = if ($items.Count -eq 0) {
    'empty'
  } elseif ($classCounts.ContainsKey('fail') -or $classCounts.ContainsKey('needs_review') -or $classCounts.ContainsKey('partial_review')) {
    'review'
  } else {
    'ok'
  }

  $summary = [pscustomobject]@{
    schema = 'cucp.live-verify-summary/v1'
    status = $overall
    root = $Root
    generated_at = (Get-Date).ToString('o')
    count = $items.Count
    classes = [pscustomobject]$classCounts
    items = @($items.ToArray())
  }
}

if ($Out) {
  $dir = Split-Path -Parent $Out
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  # BOM 없는 UTF-8 로 저장 (no_utf8_bom 계약 검사 회귀 방지).
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Out, ($summary | ConvertTo-Json -Depth 8), $utf8NoBom)
}

if ($JsonOnly) {
  $summary | ConvertTo-Json -Depth 8
} else {
  $classes = ($summary.classes.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '
  [Console]::Out.WriteLine("live-verify-summary status=$($summary.status) count=$($summary.count) $classes")
  foreach ($item in @($summary.items)) {
    if ($item.class -ne 'pass') {
      [Console]::Out.WriteLine("  $($item.class): $($item.file) status=$($item.status) reason=$($item.reason)")
    }
  }
}
