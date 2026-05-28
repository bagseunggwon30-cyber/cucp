[CmdletBinding(PositionalBinding = $false)]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$wrapper = Join-Path $scriptDir "cucp.ps1"
$taskCard = Join-Path $scriptDir "cucp-task-card.ps1"
$taskCardPath = Join-Path $env:TEMP "computer-use-control-plane\task-card\current-task-card.json"

function Invoke-TaskCard {
  param([string[]]$Rest)
  $mode = if ($Rest.Count -gt 0) { "$($Rest[0])".ToLowerInvariant() } else { "open" }
  if ($mode -eq "clear") {
    if (Test-Path -LiteralPath $taskCardPath) { Remove-Item -LiteralPath $taskCardPath -Force }
    "ok task-card action=clear"
    return
  }
  if (@("open","show","ensure","path","save") -notcontains $mode) {
    throw "Usage: task-card open|show|ensure|save|path|clear"
  }
  $restArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$taskCard,"-Mode",$mode,"-Path",$taskCardPath)
  if ($Rest.Count -gt 1) { $restArgs += $Rest[1..($Rest.Count - 1)] }
  & powershell.exe @restArgs
}

function Get-TaskCard {
  if (-not (Test-Path -LiteralPath $taskCardPath)) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $taskCard -Mode ensure -Path $taskCardPath | Out-Null
  }
  try {
    return (Get-Content -LiteralPath $taskCardPath -Raw -Encoding UTF8 | ConvertFrom-Json)
  } catch {
    return $null
  }
}

if (-not $Args -or $Args.Count -eq 0) {
  "Usage: cucp-xg5000-bridge.ps1 task-card <open|show|ensure|save|path|clear> | app-profile <cucp app-profile args>"
  exit 2
}

$command = "$($Args[0])".ToLowerInvariant()
$rest = if ($Args.Count -gt 1) { $Args[1..($Args.Count - 1)] } else { @() }

switch ($command) {
  "task-card" {
    Invoke-TaskCard -Rest $rest
  }
  "app-profile" {
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Quiet macro app-profile @rest --json-only
    try {
      $profile = $raw -join "`n" | ConvertFrom-Json
      $profile | Add-Member -NotePropertyName task_card -NotePropertyValue (Get-TaskCard) -Force
      $profile | ConvertTo-Json -Depth 16
    } catch {
      $raw
    }
  }
  default {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper @Args
  }
}
