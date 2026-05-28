[CmdletBinding(PositionalBinding = $false)]
param(
  [ValidateSet("open","show","ensure","path","save")]
  [string]$Mode = "open",
  [string]$Path,
  [string]$Tool,
  [string]$ProjectName,
  [string]$PlcModel,
  [string]$Communication,
  [string]$Devices,
  [string]$AddressRanges,
  [string]$Requirements,
  [string]$Constraints,
  [string]$Notes
)

$ErrorActionPreference = "Stop"

try {
  [System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$defaultDir = Join-Path $env:TEMP "computer-use-control-plane\task-card"
if (-not $Path) { $Path = Join-Path $defaultDir "current-task-card.json" }
$Path = [System.IO.Path]::GetFullPath($Path)

function Split-CardLines {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
  return @($Text -split "(?:`r`n|`n|`r|,|;)" | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne "" })
}

function New-DefaultCard {
  return [pscustomobject]@{
    schema = "cucp.task-card/v1"
    updated_at = (Get-Date).ToString("o")
    source = "cucp-task-card"
    tool = "XG5000"
    project_name = ""
    plc_model = ""
    communication = "XGT/P2P"
    devices_text = ""
    devices = @()
    address_ranges_text = ""
    address_ranges = @()
    requirements = ""
    constraints = ""
    notes = ""
    safety_flags = @()
  }
}

function Set-CardValue {
  param([psobject]$Card, [string]$Name, $Value)
  if ($Card.PSObject.Properties.Name -contains $Name) {
    $Card.$Name = $Value
  } else {
    $Card | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function Normalize-Card {
  param([psobject]$Card)
  if (-not $Card) { $Card = New-DefaultCard }
  $defaults = New-DefaultCard
  foreach ($prop in $defaults.PSObject.Properties) {
    if ($Card.PSObject.Properties.Name -notcontains $prop.Name) {
      $Card | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
    }
  }
  Set-CardValue -Card $Card -Name "schema" -Value "cucp.task-card/v1"
  Set-CardValue -Card $Card -Name "source" -Value "cucp-task-card"
  Set-CardValue -Card $Card -Name "devices" -Value @(Split-CardLines -Text "$($Card.devices_text)")
  Set-CardValue -Card $Card -Name "address_ranges" -Value @(Split-CardLines -Text "$($Card.address_ranges_text)")

  $flags = New-Object System.Collections.ArrayList
  $constraintText = "$($Card.constraints)".ToLowerInvariant()
  $koDownload = -join ([char[]](0xB2E4,0xC6B4,0xB85C,0xB4DC))
  $koOnline = -join ([char[]](0xC628,0xB77C,0xC778))
  $koWrite = -join ([char[]](0xC4F0,0xAE30))
  $koReal = @(
    (-join ([char[]](0xC2E4,0xAE30))),
    (-join ([char[]](0xC7A5,0xBE44))),
    (-join ([char[]](0xD604,0xC7A5))),
    (-join ([char[]](0xC124,0xBE44)))
  )
  if ($constraintText -match "download" -or $constraintText.Contains($koDownload)) { [void]$flags.Add("download_guard") }
  if ($constraintText -match "online|write" -or $constraintText.Contains($koOnline) -or $constraintText.Contains($koWrite)) { [void]$flags.Add("online_write_guard") }
  foreach ($word in $koReal) {
    if ($constraintText.Contains($word)) { [void]$flags.Add("real_equipment_guard"); break }
  }
  Set-CardValue -Card $Card -Name "safety_flags" -Value @($flags)
  Set-CardValue -Card $Card -Name "updated_at" -Value (Get-Date).ToString("o")
  return $Card
}

function Read-Card {
  if (Test-Path -LiteralPath $Path) {
    try {
      $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
      if (-not [string]::IsNullOrWhiteSpace($raw)) {
        return Normalize-Card -Card ($raw | ConvertFrom-Json)
      }
    } catch { }
  }
  return Normalize-Card -Card (New-DefaultCard)
}

function Save-Card {
  param([psobject]$Card)
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $normalized = Normalize-Card -Card $Card
  $json = $normalized | ConvertTo-Json -Depth 12
  Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
  return $normalized
}

if ($Mode -eq "path") {
  [Console]::Out.WriteLine($Path)
  return
}

if ($Mode -eq "ensure") {
  $card = Read-Card
  Save-Card -Card $card | Out-Null
  [Console]::Out.WriteLine((Get-Content -LiteralPath $Path -Raw -Encoding UTF8))
  return
}

if ($Mode -eq "show") {
  $card = Read-Card
  Save-Card -Card $card | Out-Null
  [Console]::Out.WriteLine((Get-Content -LiteralPath $Path -Raw -Encoding UTF8))
  return
}

if ($Mode -eq "save") {
  $card = Read-Card
  if ($PSBoundParameters.ContainsKey("Tool")) { Set-CardValue -Card $card -Name "tool" -Value $Tool }
  if ($PSBoundParameters.ContainsKey("ProjectName")) { Set-CardValue -Card $card -Name "project_name" -Value $ProjectName }
  if ($PSBoundParameters.ContainsKey("PlcModel")) { Set-CardValue -Card $card -Name "plc_model" -Value $PlcModel }
  if ($PSBoundParameters.ContainsKey("Communication")) { Set-CardValue -Card $card -Name "communication" -Value $Communication }
  if ($PSBoundParameters.ContainsKey("Devices")) { Set-CardValue -Card $card -Name "devices_text" -Value $Devices }
  if ($PSBoundParameters.ContainsKey("AddressRanges")) { Set-CardValue -Card $card -Name "address_ranges_text" -Value $AddressRanges }
  if ($PSBoundParameters.ContainsKey("Requirements")) { Set-CardValue -Card $card -Name "requirements" -Value $Requirements }
  if ($PSBoundParameters.ContainsKey("Constraints")) { Set-CardValue -Card $card -Name "constraints" -Value $Constraints }
  if ($PSBoundParameters.ContainsKey("Notes")) { Set-CardValue -Card $card -Name "notes" -Value $Notes }
  Save-Card -Card $card | Out-Null
  [Console]::Out.WriteLine((Get-Content -LiteralPath $Path -Raw -Encoding UTF8))
  return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$card = Read-Card

$form = New-Object System.Windows.Forms.Form
$form.Text = "CUCP Task Card - XG5000 / XP-Builder"
$form.StartPosition = "CenterScreen"
$form.TopMost = $true
$form.Width = 540
$form.Height = 720
$form.MinimumSize = New-Object System.Drawing.Size(480, 620)

$font = New-Object System.Drawing.Font("Malgun Gothic", 9)
$form.Font = $font

$panel = New-Object System.Windows.Forms.TableLayoutPanel
$panel.Dock = "Fill"
$panel.ColumnCount = 2
$panel.RowCount = 11
$panel.Padding = New-Object System.Windows.Forms.Padding(12)
$panel.AutoScroll = $true
$panel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 110))) | Out-Null
$panel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$form.Controls.Add($panel)

function Add-Label {
  param([string]$Text, [int]$Row)
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Text
  $label.Dock = "Fill"
  $label.TextAlign = "MiddleLeft"
  $label.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 4)
  $panel.Controls.Add($label, 0, $Row)
}

function Add-TextBox {
  param([string]$Text, [int]$Row, [int]$Height = 28, [switch]$Multiline)
  $box = New-Object System.Windows.Forms.TextBox
  $box.Text = $Text
  $box.Dock = "Fill"
  $box.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
  if ($Multiline) {
    $box.Multiline = $true
    $box.ScrollBars = "Vertical"
    $box.AcceptsReturn = $true
    $box.Height = $Height
    $panel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $Height))) | Out-Null
  } else {
    $panel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36))) | Out-Null
  }
  $panel.Controls.Add($box, 1, $Row)
  return $box
}

function Add-Combo {
  param([string[]]$Items, [string]$Value, [int]$Row)
  $combo = New-Object System.Windows.Forms.ComboBox
  $combo.DropDownStyle = "DropDown"
  $combo.Dock = "Fill"
  $combo.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
  foreach ($item in $Items) { [void]$combo.Items.Add($item) }
  $combo.Text = $Value
  $panel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36))) | Out-Null
  $panel.Controls.Add($combo, 1, $Row)
  return $combo
}

Add-Label -Text "Tool" -Row 0
$toolBox = Add-Combo -Items @("XG5000","XP-Builder","CIMON","SCADA","Other") -Value "$($card.tool)" -Row 0

Add-Label -Text "Project" -Row 1
$projectBox = Add-TextBox -Text "$($card.project_name)" -Row 1

Add-Label -Text "PLC Model" -Row 2
$plcBox = Add-TextBox -Text "$($card.plc_model)" -Row 2

Add-Label -Text "Comm" -Row 3
$commBox = Add-Combo -Items @("XGT/P2P","XGT Server","Modbus RTU","Modbus TCP","Serial","Ethernet","Other") -Value "$($card.communication)" -Row 3

Add-Label -Text "Devices" -Row 4
$devicesBox = Add-TextBox -Text "$($card.devices_text)" -Row 4 -Height 82 -Multiline

Add-Label -Text "Ranges" -Row 5
$rangesBox = Add-TextBox -Text "$($card.address_ranges_text)" -Row 5 -Height 68 -Multiline

Add-Label -Text "Requirements" -Row 6
$requirementsBox = Add-TextBox -Text "$($card.requirements)" -Row 6 -Height 112 -Multiline

Add-Label -Text "Constraints" -Row 7
$constraintsBox = Add-TextBox -Text "$($card.constraints)" -Row 7 -Height 82 -Multiline

Add-Label -Text "Notes" -Row 8
$notesBox = Add-TextBox -Text "$($card.notes)" -Row 8 -Height 82 -Multiline

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "Path: $Path"
$statusLabel.Dock = "Fill"
$statusLabel.AutoEllipsis = $true
$statusLabel.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 2)
$panel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 42))) | Out-Null
$panel.Controls.Add($statusLabel, 0, 9)
$panel.SetColumnSpan($statusLabel, 2)

$buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonPanel.Dock = "Fill"
$buttonPanel.FlowDirection = "RightToLeft"
$buttonPanel.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
$panel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 44))) | Out-Null
$panel.Controls.Add($buttonPanel, 0, 10)
$panel.SetColumnSpan($buttonPanel, 2)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = "Save"
$saveButton.Width = 86
$saveButton.Height = 30
$buttonPanel.Controls.Add($saveButton)

$saveCloseButton = New-Object System.Windows.Forms.Button
$saveCloseButton.Text = "Save Close"
$saveCloseButton.Width = 108
$saveCloseButton.Height = 30
$buttonPanel.Controls.Add($saveCloseButton)

$openJsonButton = New-Object System.Windows.Forms.Button
$openJsonButton.Text = "Open JSON"
$openJsonButton.Width = 92
$openJsonButton.Height = 30
$buttonPanel.Controls.Add($openJsonButton)

function Save-UiCard {
  Set-CardValue -Card $card -Name "tool" -Value $toolBox.Text
  Set-CardValue -Card $card -Name "project_name" -Value $projectBox.Text
  Set-CardValue -Card $card -Name "plc_model" -Value $plcBox.Text
  Set-CardValue -Card $card -Name "communication" -Value $commBox.Text
  Set-CardValue -Card $card -Name "devices_text" -Value $devicesBox.Text
  Set-CardValue -Card $card -Name "address_ranges_text" -Value $rangesBox.Text
  Set-CardValue -Card $card -Name "requirements" -Value $requirementsBox.Text
  Set-CardValue -Card $card -Name "constraints" -Value $constraintsBox.Text
  Set-CardValue -Card $card -Name "notes" -Value $notesBox.Text
  Save-Card -Card $card | Out-Null
  $statusLabel.Text = "Saved: $((Get-Date).ToString('HH:mm:ss'))  |  $Path"
}

$saveButton.Add_Click({
  try { Save-UiCard } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Save failed") | Out-Null }
})

$saveCloseButton.Add_Click({
  try {
    Save-UiCard
    $form.Close()
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Save failed") | Out-Null
  }
})

$openJsonButton.Add_Click({
  try {
    Save-UiCard
    Start-Process -FilePath "notepad.exe" -ArgumentList "`"$Path`""
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Open failed") | Out-Null
  }
})

$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
