[CmdletBinding(PositionalBinding = $false)]
param(
  [string]$SpecBoardPath,
  [string]$LadderTextPath,
  [string]$LadderText,
  [switch]$Markdown,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

# Keep console/file output stable when Korean spec-board text is present.
try {
  [System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# Default to the CUCP spec-board created by the XG5000 kanban helper.
if (-not $SpecBoardPath) {
  $SpecBoardPath = Join-Path $env:TEMP "computer-use-control-plane\spec-board\current-spec-board.json"
}

# Accept ladder evidence either from a saved text file or an inline argument.
# ReDoS / 메모리 방어: 래더 텍스트는 정상적으로 수십 KB 수준이다. OCR 오인식이나
# 비정상 입력으로 거대한 문자열이 들어오면 이후 regex 매칭이 폭주할 수 있으므로
# 상한(MaxLadderTextChars)을 두고 초과분은 잘라낸다. 잘렸는지 여부는 호출자가
# $Script:LadderTextTruncated 로 확인할 수 있고, 진단 리포트의 note 로도 남는다.
$Script:MaxLadderTextChars = 262144  # 256 KB 상당
$Script:LadderTextTruncated = $false

function Read-TextInput {
  $raw = ""
  if ($LadderTextPath) {
    if (-not (Test-Path -LiteralPath $LadderTextPath)) { throw "LadderTextPath not found: $LadderTextPath" }
    $raw = Get-Content -LiteralPath $LadderTextPath -Raw -Encoding UTF8
  } elseif ($LadderText) {
    $raw = $LadderText
  }
  if (-not $raw) { return "" }
  if ($raw.Length -gt $Script:MaxLadderTextChars) {
    $Script:LadderTextTruncated = $true
    return $raw.Substring(0, $Script:MaxLadderTextChars)
  }
  return $raw
}

# The spec-board is context, not a hard dependency. If it is missing, fall back to
# an empty board so the text-only diagnosis can still run.
function Read-SpecBoard {
  if ($SpecBoardPath -and (Test-Path -LiteralPath $SpecBoardPath)) {
    $raw = Get-Content -LiteralPath $SpecBoardPath -Raw -Encoding UTF8
    if (-not [string]::IsNullOrWhiteSpace($raw)) { return ($raw | ConvertFrom-Json) }
  }
  return [pscustomobject]@{
    title = "XG5000 Ladder"
    device_map = @()
    warnings = @()
  }
}

# Findings use a fixed shape so JSON and Markdown reports stay consistent.
function Add-Finding {
  param(
    [System.Collections.ArrayList]$Findings,
    [string]$Severity,
    [string]$Code,
    [string]$Message,
    [string]$Principle,
    [string]$Fix
  )
  [void]$Findings.Add([pscustomobject]@{
    severity = $Severity
    code = $Code
    message = $Message
    principle = $Principle
    fix = $Fix
  })
}

# Device helpers keep ladder rules independent from the exact addresses used in
# the current class/project.
function Get-DeviceByName {
  param([psobject]$Board, [string]$Name)
  $hit = @($Board.device_map | Where-Object { "$($_.name)" -eq $Name } | Select-Object -First 1)
  if ($hit.Count -gt 0) { return $hit[0] }
  return $null
}

function Get-DeviceAddress {
  param([psobject]$Board, [string]$Name, [string]$Fallback)
  $hit = Get-DeviceByName -Board $Board -Name $Name
  if ($hit -and "$($hit.address)") { return "$($hit.address)" }
  return $Fallback
}

function Get-DeviceType {
  param([psobject]$Board, [string]$Address)
  $hit = @($Board.device_map | Where-Object { "$($_.address)".ToUpperInvariant() -eq $Address.ToUpperInvariant() } | Select-Object -First 1)
  if ($hit.Count -gt 0) { return "$($hit[0].type)" }
  if ($Address -match '^[D]\d+') { return "word" }
  return ""
}

# Detect simple output coil forms used in exported/transcribed ladder text.
function Get-CoilTargets {
  param([string]$Text)
  $targets = New-Object System.Collections.ArrayList
  foreach ($m in [regex]::Matches($Text, '(?im)\(\s*\)\s*([A-Z]\d{1,5})')) {
    [void]$targets.Add($m.Groups[1].Value.ToUpperInvariant())
  }
  foreach ($m in [regex]::Matches($Text, '(?im)\bOUT\s+([A-Z]\d{1,5})\b')) {
    [void]$targets.Add($m.Groups[1].Value.ToUpperInvariant())
  }
  return @($targets)
}

# These checks intentionally support a few common text forms, not every XG5000
# export style. CUCP/OCR output can be normalized before calling this script.
function Test-NcContactNearAddress {
  param([string]$Text, [string]$Address)
  if (-not $Address) { return $false }
  $escaped = [regex]::Escape($Address)
  return [regex]::IsMatch($Text, "(?is)(--\s*\|/\|\s*$escaped|NC\s+$escaped|$escaped\s+NC)")
}

function Test-NoContactNearAddress {
  param([string]$Text, [string]$Address)
  if (-not $Address) { return $false }
  $escaped = [regex]::Escape($Address)
  return [regex]::IsMatch($Text, "(?is)(--\s*\|\s*\|\s*$escaped|NO\s+$escaped|$escaped\s+NO)")
}

$board = Read-SpecBoard
$text = Read-TextInput
$findings = New-Object System.Collections.ArrayList
$notes = New-Object System.Collections.ArrayList

# 입력이 상한을 넘어 잘렸으면 정직하게 기록 (잘린 뒷부분은 진단에서 빠짐).
if ($Script:LadderTextTruncated) {
  [void]$notes.Add("Ladder text exceeded $($Script:MaxLadderTextChars) chars and was truncated; diagnosis covers only the leading portion.")
}

# Without ladder evidence, the only honest result is to ask for a rung capture.
if ([string]::IsNullOrWhiteSpace($text)) {
  Add-Finding -Findings $findings -Severity "info" -Code "NO_LADDER_TEXT" `
    -Message "No ladder text was provided, so visual/OCR/manual evidence is required." `
    -Principle "Ladder diagnosis must be based on actual contact and coil placement." `
    -Fix "Capture rung text or use CUCP OCR/observation, then run the diagnosis again."
} else {
  $textUpper = $text.ToUpperInvariant()
  $start = (Get-DeviceAddress -Board $board -Name "START_BUTTON" -Fallback "P0020").ToUpperInvariant()
  $stop = (Get-DeviceAddress -Board $board -Name "STOP_BUTTON" -Fallback "P0021").ToUpperInvariant()
  $motor = (Get-DeviceAddress -Board $board -Name "MOTOR_RUN" -Fallback "P0040").ToUpperInvariant()

  # Motor self-hold sanity checks: STOP should break the rung, START should
  # initiate it, and the motor output should seal itself in through a contact.
  if ($textUpper.Contains($stop) -and -not (Test-NcContactNearAddress -Text $textUpper -Address $stop)) {
    Add-Finding -Findings $findings -Severity "high" -Code "STOP_NOT_NC" `
      -Message "$stop STOP_BUTTON is not confirmed as an NC contact." `
      -Principle "A stop button normally breaks the whole self-hold rung, so it should be placed as an NC condition before the start/seal branch." `
      -Fix "Use $stop as an NC contact before the START and self-hold parallel branch."
  }

  if ($textUpper.Contains($start) -and -not (Test-NoContactNearAddress -Text $textUpper -Address $start)) {
    Add-Finding -Findings $findings -Severity "medium" -Code "START_NOT_NO" `
      -Message "$start START_BUTTON is not confirmed as an NO contact." `
      -Principle "The start button should make the rung true once, then the output seal contact keeps it true." `
      -Fix "Confirm $start is used as an NO contact."
  }

  $coils = @(Get-CoilTargets -Text $textUpper)
  # If the intended output coil is absent, the rung cannot drive the mapped output.
  if ($coils -notcontains $motor) {
    Add-Finding -Findings $findings -Severity "high" -Code "MOTOR_COIL_MISSING" `
      -Message "$motor MOTOR_RUN output coil was not found." `
      -Principle "A ladder rung must write the condition result to an output coil before the physical output image can update." `
      -Fix "Add or confirm the $motor output coil in the intended run rung."
  }

  $motorOccurrences = ([regex]::Matches($textUpper, [regex]::Escape($motor))).Count
  # A basic self-hold rung normally mentions the output twice: coil + seal contact.
  if ($coils -contains $motor -and $motorOccurrences -lt 2) {
    Add-Finding -Findings $findings -Severity "medium" -Code "SELF_HOLD_CONTACT_MISSING" `
      -Message "$motor appears as a coil but not clearly as a self-hold contact." `
      -Principle "A self-hold rung usually reuses the output bit as a parallel NO contact with START." `
      -Fix "Check that a $motor NO contact is parallel with $start."
  }

  # Duplicate coils are dangerous because later rungs can overwrite earlier writes.
  $coilGroups = $coils | Group-Object | Where-Object { $_.Count -gt 1 }
  foreach ($group in @($coilGroups)) {
    Add-Finding -Findings $findings -Severity "high" -Code "DUPLICATE_COIL" `
      -Message "$($group.Name) coil appears $($group.Count) times." `
      -Principle "PLC scan order can let a later rung overwrite an earlier coil result." `
      -Fix "Consolidate duplicate coils into one rung/state bit design, or use explicit SET/RST with clear reset logic."
  }

  # SET without RST is not always wrong, but it is a common classroom failure mode.
  $setTargets = @([regex]::Matches($textUpper, '(?im)\bSET\s+([A-Z]\d{1,5})\b') | ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() })
  $rstTargets = @([regex]::Matches($textUpper, '(?im)\b(RST|RESET)\s+([A-Z]\d{1,5})\b') | ForEach-Object { $_.Groups[2].Value.ToUpperInvariant() })
  foreach ($target in @($setTargets | Select-Object -Unique)) {
    if ($rstTargets -notcontains $target) {
      Add-Finding -Findings $findings -Severity "medium" -Code "SET_WITHOUT_RST" `
        -Message "$target has SET logic but no matching RST was found." `
        -Principle "SET remains on after its condition disappears; without reset logic the bit can stay on forever." `
        -Fix "Add an intentional RST condition for $target or use a normal coil if latch behavior is not required."
    }
  }

  # Word devices such as D registers should not be treated as plain bit contacts.
  foreach ($addrMatch in [regex]::Matches($textUpper, '\b[A-Z]\d{1,5}\b')) {
    $addr = $addrMatch.Value.ToUpperInvariant()
    $type = Get-DeviceType -Board $board -Address $addr
    if ($type -eq "word") {
      $escapedAddr = [regex]::Escape($addr)
      $line = ($textUpper -split "(`r`n|`n|`r)" | Where-Object { $_ -match $escapedAddr } | Select-Object -First 1)
      if ($line -match "--\s*\|\s*/?\|\s*$escapedAddr|\(\s*\)\s*$escapedAddr|\b(OUT|SET|RST|RESET)\s+$escapedAddr\b") {
        Add-Finding -Findings $findings -Severity "high" -Code "WORD_AS_BIT" `
          -Message "$addr is a word device but appears to be used like a bit contact or coil." `
          -Principle "Word registers such as D devices should be used by move/compare/math/communication instructions, not as ordinary bit contacts." `
          -Fix "Keep $addr for numeric data and use a separate bit device for ON/OFF logic."
      }
    }
  }

  # Missing mapped devices are notes, not faults: the current rung may only cover
  # part of the project.
  foreach ($dev in @($board.device_map)) {
    $addr = "$($dev.address)".ToUpperInvariant()
    if ($addr -and -not $textUpper.Contains($addr)) {
      [void]$notes.Add("$addr $($dev.name) is in the spec-board but was not found in ladder text.")
    }
  }

  # A clean first pass still needs XG5000-native checks before live changes.
  if ($findings.Count -eq 0) {
    Add-Finding -Findings $findings -Severity "ok" -Code "NO_BASIC_FAULT_FOUND" `
      -Message "No basic self-hold, duplicate coil, SET/RST, or word-as-bit fault was found in the text check." `
      -Principle "This is only a first-pass text diagnosis; actual XG5000 rung layout and I/O parameters still need verification." `
      -Fix "Verify the XG5000 screen, I/O parameters, module slots, and physical safety state."
  }
}

# Report format is intentionally simple so Codex can read it back or save it in notes.
$report = [pscustomobject]@{
  schema = "xg5000.ladder-diagnosis/v1"
  title = "$($board.title)"
  generated_at = (Get-Date).ToString("o")
  spec_board_path = $SpecBoardPath
  ladder_text_path = $LadderTextPath
  finding_count = [int]$findings.Count
  findings = @($findings)
  notes = @($notes)
  safety = @($board.warnings)
}

# Markdown is friendlier for class explanations; JSON is better for automation.
if ($Markdown -and -not $Json) {
  $lines = New-Object System.Collections.ArrayList
  [void]$lines.Add("# XG5000 Ladder Diagnosis")
  [void]$lines.Add("")
  [void]$lines.Add("- Project: $($report.title)")
  [void]$lines.Add("- Findings: $($report.finding_count)")
  [void]$lines.Add("")
  foreach ($finding in @($report.findings)) {
    [void]$lines.Add("## [$($finding.severity)] $($finding.code)")
    [void]$lines.Add("")
    [void]$lines.Add("- Problem: $($finding.message)")
    [void]$lines.Add("- Principle: $($finding.principle)")
    [void]$lines.Add("- Fix: $($finding.fix)")
    [void]$lines.Add("")
  }
  if ($report.notes.Count -gt 0) {
    [void]$lines.Add("## Notes")
    foreach ($note in @($report.notes)) { [void]$lines.Add("- $note") }
    [void]$lines.Add("")
  }
  if ($report.safety.Count -gt 0) {
    [void]$lines.Add("## Safety")
    foreach ($warning in @($report.safety)) { [void]$lines.Add("- $warning") }
  }
  [Console]::Out.WriteLine(($lines -join "`r`n"))
} else {
  [Console]::Out.WriteLine(($report | ConvertTo-Json -Depth 12))
}
