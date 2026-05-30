[CmdletBinding(PositionalBinding = $false)]
param(
  [ValidateSet("open","show","ensure","path","check","uncheck","ladder","markdown","sequence","clear")]
  [string]$Mode = "open",
  [string]$Path,
  [string]$TaskId
)

$ErrorActionPreference = "Stop"

try {
  [System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$defaultDir = Join-Path $env:TEMP "computer-use-control-plane\spec-board"
if (-not $Path) { $Path = Join-Path $defaultDir "current-spec-board.json" }
$Path = [System.IO.Path]::GetFullPath($Path)

function Set-BoardValue {
  param([psobject]$Board, [string]$Name, $Value)
  if ($Board.PSObject.Properties.Name -contains $Name) {
    $Board.$Name = $Value
  } else {
    $Board | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function New-DefaultSpecBoard {
  return [pscustomobject]@{
    schema = "cucp.spec-board/v1"
    updated_at = (Get-Date).ToString("o")
    source = "cucp-spec-board"
    title = "자동제어 XG5000 작업"
    environment = [pscustomobject]@{
      plc_series = "LS XGB"
      cpu_model = "XBC-DN32H"
      xg5000_version = "v4.82"
      communication = "Ethernet"
    }
    network = [pscustomobject]@{
      plc_ip = "192.0.2.10"
      engineering_pc_ip = "192.0.2.100"
      server_ip = "192.0.2.50"
      protocol = "XGT Dedicated"
      port = 2004
      notes = "EXAMPLE values (RFC 5737 192.0.2.0/24). Replace with the real PLC/PC/server IPs for your site before use. Host table registration required for the engineering PC."
    }
    device_map = @(
      [pscustomobject]@{ address = "P0020"; name = "START_BUTTON"; type = "bit"; direction = "input"; description = "시작 버튼 (XBE-DC16A)" },
      [pscustomobject]@{ address = "P0021"; name = "STOP_BUTTON"; type = "bit"; direction = "input"; description = "정지 버튼" },
      [pscustomobject]@{ address = "P0040"; name = "MOTOR_RUN"; type = "bit"; direction = "output"; description = "모터 운전 출력 (XBE-TN16A)" },
      [pscustomobject]@{ address = "D0100"; name = "TARGET_SPEED"; type = "word"; direction = "internal"; description = "목표 속도 레지스터" }
    )
    # ── 자산 3: 정수형 스텝 제어(Word State Machine) 시퀀스 정의 ──────────────
    # 각 step 은 레더 생성(자산 1)과 검증(자산 2)에 필요한 모든 정보를 담는다.
    # 이 sequences 가 "단일 진실 소스(contract)" — 아키텍트는 이걸 해석만 하고,
    # 검증기는 생성된 레더가 이걸 지켰는지 대조한다.
    # 스텝 번호 컨벤션: 0 = IDLE(대기), 900 = FAULT(결함), 본 공정은 10 간격(중간삽입 여지).
    sequences = @(
      [pscustomobject]@{
        id = "MAIN"
        state_word = "D1000"          # 이 시퀀스의 상태 레지스터 (단일!). 단계 제어는 오직 이 워드로만.
        timeout_timer = "T0000"       # 공통 타임아웃 타이머 (스텝마다 쪼개지 않음)
        timeout_ms = 30000            # 시퀀스 기본 타임아웃
        fault_step = 900              # 타임아웃/결함 시 이동할 스텝
        fault_record = "D1002"        # 결함 발생 당시 스텝 번호를 저장할 워드 (사후 추적)
        init = [pscustomobject]@{
          reset_to = 0                # 전원 첫 스캔 / E-Stop 시 강제할 스텝
          estop_input = "X_ESTOP"     # 비상정지 입력 심볼 (device_map 또는 글로벌)
          auto_condition = "M_AUTO_MODE"  # 자동 모드 게이트 (이 조건일 때만 시퀀스 진행)
          first_scan_relay = "F00099" # first-scan 특수릴레이 (기종별 다름 — 매뉴얼 확인 주석 대상)
        }
        steps = @(
          [pscustomobject]@{ step = 0;   name = "IDLE";    outputs = @();             interlocks = @();                 transition = [pscustomobject]@{ to = 10;  when = "X_START AND M_AUTO_MODE" } },
          [pscustomobject]@{ step = 10;  name = "A_ASM";   outputs = @("M_ASM_RUN");  interlocks = @("M_GUARD_CLOSED"); transition = [pscustomobject]@{ to = 20;  when = "X_ASM_DONE" };  timeout_ms = 10000 },
          [pscustomobject]@{ step = 20;  name = "B_WASH";  outputs = @("M_WASH_RUN"); interlocks = @();                 transition = [pscustomobject]@{ to = 30;  when = "T_WASH_DONE" } },
          [pscustomobject]@{ step = 30;  name = "C_DRY";   outputs = @("M_DRY_RUN");  interlocks = @();                 transition = [pscustomobject]@{ to = 40;  when = "X_DRY_DONE" } },
          [pscustomobject]@{ step = 40;  name = "D_EJECT"; outputs = @("M_EJECT");    interlocks = @();                 transition = [pscustomobject]@{ to = 0;   when = "X_EJECT_DONE" } },
          [pscustomobject]@{ step = 900; name = "FAULT";   outputs = @();             interlocks = @();                 transition = [pscustomobject]@{ to = 0;   when = "X_RESET" } }
        )
      }
    )
    tasks = @(
      [pscustomobject]@{ id = "XG-001"; title = "프로젝트 생성 (CPU 모델/통신 기준)"; done = $false },
      [pscustomobject]@{ id = "XG-002"; title = "I/O 파라미터 등록"; done = $false },
      [pscustomobject]@{ id = "XG-003"; title = "디바이스 맵 반영 (심볼/주석/래더)"; done = $false },
      [pscustomobject]@{ id = "XG-004"; title = "서버 통신 파라미터 설정"; done = $false }
    )
    warnings = @(
      "실제 PLC 다운로드 전에는 사람이 I/O 주소와 모듈 슬롯을 검증할 것.",
      "출력 접점 테스트는 설비 안전 상태에서만 수행할 것."
    )
    ladder_notes = @(
      "P0021 STOP_BUTTON은 NC 조건으로 사용한다.",
      "P0020 START_BUTTON과 P0040 MOTOR_RUN 자기유지 접점으로 P0040 MOTOR_RUN 출력을 유지한다.",
      "D0100 TARGET_SPEED는 속도 제어 출력 모듈/인버터 매핑이 정해진 뒤 MOV 또는 통신 쓰기 대상으로 연결한다."
    )
  }
}

function Normalize-SpecBoard {
  param([psobject]$Board)
  if (-not $Board) { $Board = New-DefaultSpecBoard }
  $defaults = New-DefaultSpecBoard
  foreach ($prop in $defaults.PSObject.Properties) {
    if ($Board.PSObject.Properties.Name -notcontains $prop.Name) {
      $Board | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
    }
  }
  foreach ($sectionName in @("environment","network")) {
    if (-not $Board.$sectionName) { Set-BoardValue -Board $Board -Name $sectionName -Value $defaults.$sectionName }
    foreach ($prop in $defaults.$sectionName.PSObject.Properties) {
      if ($Board.$sectionName.PSObject.Properties.Name -notcontains $prop.Name) {
        $Board.$sectionName | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
      }
    }
  }
  $tasks = New-Object System.Collections.ArrayList
  foreach ($task in @($Board.tasks)) {
    if (-not $task) { continue }
    [void]$tasks.Add([pscustomobject]@{
      id = "$($task.id)"
      title = "$($task.title)"
      done = [bool]$task.done
    })
  }
  Set-BoardValue -Board $Board -Name "tasks" -Value @($tasks)

  # ── sequences 정규화 (자산 3) ──────────────────────────────────────────────
  # 구버전(sequences 없는 v1) JSON 도 graceful 흡수: 없으면 빈 배열로 둔다.
  # 각 step 의 outputs/interlocks 는 항상 배열로, transition 은 항상 {to, when} 형태로 보정.
  $normSeqs = New-Object System.Collections.ArrayList
  foreach ($seq in @($Board.sequences)) {
    if (-not $seq) { continue }
    $normSteps = New-Object System.Collections.ArrayList
    foreach ($st in @($seq.steps)) {
      if (-not $st) { continue }
      $toVal = $null; $whenVal = ""
      if ($st.transition) {
        if ($st.transition.PSObject.Properties.Name -contains "to") { $toVal = $st.transition.to }
        if ($st.transition.PSObject.Properties.Name -contains "when") { $whenVal = "$($st.transition.when)" }
      }
      $stepObj = [ordered]@{
        step = [int]$st.step
        name = "$($st.name)"
        outputs = @(@($st.outputs) | Where-Object { $_ } | ForEach-Object { "$_" })
        interlocks = @(@($st.interlocks) | Where-Object { $_ } | ForEach-Object { "$_" })
        transition = [pscustomobject]@{ to = $toVal; when = $whenVal }
      }
      if ($st.PSObject.Properties.Name -contains "timeout_ms" -and $st.timeout_ms) {
        $stepObj["timeout_ms"] = [int]$st.timeout_ms
      }
      [void]$normSteps.Add([pscustomobject]$stepObj)
    }
    $initObj = $null
    if ($seq.init) {
      $initObj = [pscustomobject]@{
        reset_to = if ($seq.init.PSObject.Properties.Name -contains "reset_to") { [int]$seq.init.reset_to } else { 0 }
        estop_input = "$($seq.init.estop_input)"
        auto_condition = "$($seq.init.auto_condition)"
        first_scan_relay = "$($seq.init.first_scan_relay)"
      }
    }
    $seqObj = [ordered]@{
      id = "$($seq.id)"
      state_word = "$($seq.state_word)"
      timeout_timer = "$($seq.timeout_timer)"
      timeout_ms = if ($seq.PSObject.Properties.Name -contains "timeout_ms" -and $seq.timeout_ms) { [int]$seq.timeout_ms } else { 0 }
      fault_step = if ($seq.PSObject.Properties.Name -contains "fault_step") { [int]$seq.fault_step } else { 900 }
      fault_record = "$($seq.fault_record)"
      init = $initObj
      steps = @($normSteps)
    }
    [void]$normSeqs.Add([pscustomobject]$seqObj)
  }
  Set-BoardValue -Board $Board -Name "sequences" -Value @($normSeqs)

  # schema 는 sequences 가 1개 이상이면 v2, 아니면 v1 호환 표기 유지.
  if (@($normSeqs).Count -gt 0) {
    Set-BoardValue -Board $Board -Name "schema" -Value "cucp.spec-board/v2"
  } else {
    Set-BoardValue -Board $Board -Name "schema" -Value "cucp.spec-board/v1"
  }
  Set-BoardValue -Board $Board -Name "source" -Value "cucp-spec-board"
  Set-BoardValue -Board $Board -Name "updated_at" -Value (Get-Date).ToString("o")
  return $Board
}

function Read-SpecBoard {
  if (Test-Path -LiteralPath $Path) {
    try {
      $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
      if (-not [string]::IsNullOrWhiteSpace($raw)) {
        return Normalize-SpecBoard -Board ($raw | ConvertFrom-Json)
      }
    } catch { }
  }
  return Normalize-SpecBoard -Board (New-DefaultSpecBoard)
}

function Save-SpecBoard {
  param([psobject]$Board)
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $normalized = Normalize-SpecBoard -Board $Board
  $json = $normalized | ConvertTo-Json -Depth 16
  # BOM 없는 UTF-8 로 저장 (다른 도구의 no_utf8_bom 계약 검사와 일관성 유지).
  $utf8Bom = New-Object System.Text.UTF8Encoding($false)
  $lastError = $null
  for ($i = 0; $i -lt 6; $i++) {
    try {
      [System.IO.File]::WriteAllText($Path, $json, $utf8Bom)
      $lastError = $null
      break
    } catch {
      $lastError = $_.Exception
      Start-Sleep -Milliseconds (80 * ($i + 1))
    }
  }
  if ($lastError) { throw $lastError }
  return $normalized
}

function Render-BoardMarkdown {
  param([psobject]$Board)
  $lines = New-Object System.Collections.ArrayList
  [void]$lines.Add("# $($Board.title)")
  [void]$lines.Add("")
  [void]$lines.Add("## Environment")
  [void]$lines.Add("- PLC Series: $($Board.environment.plc_series)")
  [void]$lines.Add("- CPU Model: $($Board.environment.cpu_model)")
  [void]$lines.Add("- XG5000 Version: $($Board.environment.xg5000_version)")
  [void]$lines.Add("- Communication: $($Board.environment.communication)")
  [void]$lines.Add("")
  [void]$lines.Add("## Network")
  [void]$lines.Add("- PLC IP: $($Board.network.plc_ip)")
  [void]$lines.Add("- Engineering PC IP: $($Board.network.engineering_pc_ip)")
  [void]$lines.Add("- Server IP: $($Board.network.server_ip)")
  [void]$lines.Add("- Protocol: $($Board.network.protocol) / Port $($Board.network.port)")
  [void]$lines.Add("")
  [void]$lines.Add("## I/O & Device Map")
  [void]$lines.Add("| Address | Name | Type | Direction | Description |")
  [void]$lines.Add("| :--- | :--- | :--- | :--- | :--- |")
  foreach ($item in @($Board.device_map)) {
    [void]$lines.Add("| $($item.address) | $($item.name) | $($item.type) | $($item.direction) | $($item.description) |")
  }
  [void]$lines.Add("")
  [void]$lines.Add("## Tasks")
  foreach ($task in @($Board.tasks)) {
    $mark = if ([bool]$task.done) { "x" } else { " " }
    [void]$lines.Add("- [$mark] **$($task.id):** $($task.title)")
  }
  [void]$lines.Add("")
  [void]$lines.Add("## Warnings")
  foreach ($warning in @($Board.warnings)) {
    [void]$lines.Add("- $warning")
  }
  return ($lines -join "`r`n")
}

function Render-LadderPlan {
  param([psobject]$Board)
  function Get-DeviceAddress {
    param([string]$Name, [string]$Fallback)
    $item = @($Board.device_map | Where-Object { "$($_.name)" -eq $Name } | Select-Object -First 1)
    if ($item.Count -gt 0 -and $item[0].PSObject.Properties.Name -contains "address" -and "$($item[0].address)") {
      return "$($item[0].address)"
    }
    return $Fallback
  }
  $start = Get-DeviceAddress -Name "START_BUTTON" -Fallback "P0020"
  $stop = Get-DeviceAddress -Name "STOP_BUTTON" -Fallback "P0021"
  $motor = Get-DeviceAddress -Name "MOTOR_RUN" -Fallback "P0040"
  $speed = Get-DeviceAddress -Name "TARGET_SPEED" -Fallback "D0100"
  if (-not $start) { $start = "P0020" }
  if (-not $stop) { $stop = "P0021" }
  if (-not $motor) { $motor = "P0040" }
  if (-not $speed) { $speed = "D0100" }
  $lines = New-Object System.Collections.ArrayList
  [void]$lines.Add("Ladder draft for $($Board.title)")
  [void]$lines.Add("")
  [void]$lines.Add("Rung 1: motor self-hold")
  [void]$lines.Add("  --|/| $stop --+--| | $start --+----------------( ) $motor")
  [void]$lines.Add("                 |              |")
  [void]$lines.Add("                 +--| | $motor --+")
  [void]$lines.Add("")
  [void]$lines.Add("Device meaning:")
  [void]$lines.Add("  $start = START_BUTTON")
  [void]$lines.Add("  $stop = STOP_BUTTON, use normally-closed contact")
  [void]$lines.Add("  $motor = MOTOR_RUN output and self-hold contact")
  [void]$lines.Add("  $speed = TARGET_SPEED, reserve for speed command after drive/output mapping is confirmed")
  [void]$lines.Add("")
  [void]$lines.Add("Before live download: verify input/output module slots and physical safety state.")
  return ($lines -join "`r`n")
}

# ── 자산 3↔1 연동: 시퀀스를 아키텍트 프롬프트가 소비하기 좋은 형태로 렌더 ──────
# `spec-board sequence` 모드가 호출. 정수형 스텝 머신 정의를 표로 보여주고,
# 아키텍트가 변환할 때 참조할 contract 요약을 함께 출력한다.
function Render-SequencePlan {
  param([psobject]$Board)
  $lines = New-Object System.Collections.ArrayList
  [void]$lines.Add("# Word State Machine sequences for $($Board.title)")
  [void]$lines.Add("")
  $seqs = @($Board.sequences)
  if ($seqs.Count -eq 0) {
    [void]$lines.Add("(no sequences defined — add a 'sequences' entry to the spec-board JSON)")
    return ($lines -join "`r`n")
  }
  foreach ($seq in $seqs) {
    [void]$lines.Add("## Sequence: $($seq.id)")
    [void]$lines.Add("- state_word    : $($seq.state_word)   (single register — all step control goes through this)")
    [void]$lines.Add("- timeout_timer : $($seq.timeout_timer)  (common timeout, not split per step)")
    [void]$lines.Add("- timeout_ms    : $($seq.timeout_ms)")
    [void]$lines.Add("- fault_step    : $($seq.fault_step)   (go here on timeout/fault)")
    [void]$lines.Add("- fault_record  : $($seq.fault_record)  (stores the step number where the fault occurred)")
    if ($seq.init) {
      [void]$lines.Add("- init.reset_to        : $($seq.init.reset_to)")
      [void]$lines.Add("- init.estop_input     : $($seq.init.estop_input)")
      [void]$lines.Add("- init.auto_condition  : $($seq.init.auto_condition)")
      [void]$lines.Add("- init.first_scan_relay: $($seq.init.first_scan_relay)  (controller-specific — confirm in manual)")
    }
    [void]$lines.Add("")
    [void]$lines.Add("| step | name | outputs | interlocks | next | transition-when |")
    [void]$lines.Add("| ---: | :--- | :--- | :--- | ---: | :--- |")
    foreach ($st in @($seq.steps)) {
      $outs = (@($st.outputs) -join ", ")
      $itlk = (@($st.interlocks) -join ", ")
      $to = if ($st.transition) { "$($st.transition.to)" } else { "" }
      $when = if ($st.transition) { "$($st.transition.when)" } else { "" }
      [void]$lines.Add("| $($st.step) | $($st.name) | $outs | $itlk | $to | $when |")
    }
    [void]$lines.Add("")
  }
  [void]$lines.Add("## Architect contract (how to convert this to ladder)")
  [void]$lines.Add("- Rule 0 (init)   : first scan OR estop ON  ->  MOV <reset_to> <state_word>")
  [void]$lines.Add("- Rule E (estop)  : estop ON  ->  MOV <reset_to> <state_word>  (highest priority, above interlocks)")
  [void]$lines.Add("- Rule T (trans)  : [= state_word step] AND (transition.when)  ->  MOV transition.to state_word")
  [void]$lines.Add("- Rule O (output) : bottom of ladder, each output ONCE: [= state_word step] AND interlocks AND NOT estop -> ( ) output")
  [void]$lines.Add("- Rule W (timeout): while state_word <> reset_to, run common timer; timer done -> MOV fault_step state_word + record step")
  [void]$lines.Add("- Forbidden       : per-step M-bit SET/RST spaghetti, duplicate coils, output coils in the middle of logic")
  return ($lines -join "`r`n")
}

if ($Mode -eq "path") {
  [Console]::Out.WriteLine($Path)
  return
}

if ($Mode -eq "clear") {
  if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
  [Console]::Out.WriteLine("ok spec-board action=clear path=$Path")
  return
}

if ($Mode -eq "ensure" -or $Mode -eq "show") {
  $board = Read-SpecBoard
  Save-SpecBoard -Board $board | Out-Null
  [Console]::Out.WriteLine((Get-Content -LiteralPath $Path -Raw -Encoding UTF8))
  return
}

if ($Mode -eq "check" -or $Mode -eq "uncheck") {
  if (-not $TaskId) { throw "spec-board $Mode requires -TaskId <id>" }
  $board = Read-SpecBoard
  $found = $false
  foreach ($task in @($board.tasks)) {
    if ("$($task.id)".ToLowerInvariant() -eq "$TaskId".ToLowerInvariant()) {
      $task.done = ($Mode -eq "check")
      $found = $true
    }
  }
  if (-not $found) { throw "Task not found: $TaskId" }
  Save-SpecBoard -Board $board | Out-Null
  [Console]::Out.WriteLine((Get-Content -LiteralPath $Path -Raw -Encoding UTF8))
  return
}

if ($Mode -eq "markdown") {
  $board = Read-SpecBoard
  [Console]::Out.WriteLine((Render-BoardMarkdown -Board $board))
  return
}

if ($Mode -eq "ladder") {
  $board = Read-SpecBoard
  [Console]::Out.WriteLine((Render-LadderPlan -Board $board))
  return
}

if ($Mode -eq "sequence") {
  $board = Read-SpecBoard
  [Console]::Out.WriteLine((Render-SequencePlan -Board $board))
  return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$board = Read-SpecBoard

$form = New-Object System.Windows.Forms.Form
$form.Text = "CUCP Kanban"
$form.Width = 380
$form.Height = 330
$form.MinimumSize = New-Object System.Drawing.Size(320, 290)
$form.FormBorderStyle = "SizableToolWindow"
$form.TopMost = $true
$form.ShowInTaskbar = $true
$form.Font = New-Object System.Drawing.Font("Malgun Gothic", 8)
try {
  $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $form.StartPosition = "Manual"
  $form.Location = New-Object System.Drawing.Point(($area.Right - $form.Width - 18), ($area.Top + 72))
} catch {
  $form.StartPosition = "CenterScreen"
}

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = "Fill"
$root.RowCount = 4
$root.ColumnCount = 1
$root.Padding = New-Object System.Windows.Forms.Padding(6)
$root.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40))) | Out-Null
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30))) | Out-Null
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30))) | Out-Null
$form.Controls.Add($root)

$doneCount = @($board.tasks | Where-Object { [bool]$_.done }).Count
$taskCount = @($board.tasks).Count

$header = New-Object System.Windows.Forms.Label
$header.Dock = "Fill"
$header.TextAlign = "MiddleLeft"
$header.Font = New-Object System.Drawing.Font("Malgun Gothic", 9, [System.Drawing.FontStyle]::Bold)
$header.ForeColor = [System.Drawing.Color]::FromArgb(20, 35, 55)
$header.Text = "$($board.title)   $doneCount/$taskCount"
$root.Controls.Add($header, 0, 0)

$summary = New-Object System.Windows.Forms.Label
$summary.Dock = "Fill"
$summary.TextAlign = "MiddleLeft"
$summary.ForeColor = [System.Drawing.Color]::FromArgb(52, 64, 84)
$summary.Text = "$($board.environment.cpu_model) / $($board.environment.communication) / PLC $($board.network.plc_ip)"
$root.Controls.Add($summary, 0, 1)

$cardsPanel = New-Object System.Windows.Forms.TableLayoutPanel
$cardsPanel.Dock = "Fill"
$cardsPanel.RowCount = 2
$cardsPanel.ColumnCount = 2
$cardsPanel.Padding = New-Object System.Windows.Forms.Padding(0)
$cardsPanel.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
$cardsPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$cardsPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$cardsPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$cardsPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$root.Controls.Add($cardsPanel, 0, 2)

$taskCards = New-Object System.Collections.ArrayList
$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 12000
$toolTip.InitialDelay = 350

function Get-ShortTaskTitle {
  param([psobject]$Task)
  switch ("$($Task.id)") {
    "XG-001" { return "프로젝트 생성" }
    "XG-002" { return "I/O 파라미터" }
    "XG-003" { return "심볼/래더 반영" }
    "XG-004" { return "서버 통신 설정" }
    default {
      $title = "$($Task.title)" -replace "\s*\(.*?\)\s*", ""
      if ($title.Length -gt 14) { return $title.Substring(0, 14) }
      return $title
    }
  }
}

function Set-CardStyle {
  param([System.Windows.Forms.Panel]$Panel, [System.Windows.Forms.CheckBox]$Check)
  if ($Check.Checked) {
    $Panel.BackColor = [System.Drawing.Color]::FromArgb(224, 247, 235)
    $Check.ForeColor = [System.Drawing.Color]::FromArgb(24, 92, 61)
  } else {
    $Panel.BackColor = [System.Drawing.Color]::White
    $Check.ForeColor = [System.Drawing.Color]::FromArgb(34, 47, 62)
  }
}

foreach ($task in @($board.tasks)) {
  $card = New-Object System.Windows.Forms.Panel
  $card.Dock = "Fill"
  $card.Margin = New-Object System.Windows.Forms.Padding(3)
  $card.Padding = New-Object System.Windows.Forms.Padding(7, 5, 7, 5)
  $card.BorderStyle = "FixedSingle"

  $check = New-Object System.Windows.Forms.CheckBox
  $check.Dock = "Fill"
  $check.AutoEllipsis = $true
  $check.CheckAlign = "TopLeft"
  $check.TextAlign = "TopLeft"
  $check.Font = New-Object System.Drawing.Font("Malgun Gothic", 8, [System.Drawing.FontStyle]::Regular)
  $check.Text = "$($task.id)`r`n$(Get-ShortTaskTitle -Task $task)"
  $check.Checked = [bool]$task.done
  $check.Tag = "$($task.id)"
  $card.Controls.Add($check)
  $toolTip.SetToolTip($check, "$($task.id): $($task.title)")
  Set-CardStyle -Panel $card -Check $check

  $localCard = $card
  $localCheck = $check
  $check.Add_CheckedChanged({
    Set-CardStyle -Panel $localCard -Check $localCheck
  }.GetNewClosure())

  $index = @($taskCards).Count
  $col = $index % 2
  $row = [Math]::Floor($index / 2)
  if ($row -gt 1) { $row = 1 }
  [void]$cardsPanel.Controls.Add($card, $col, $row)
  [void]$taskCards.Add([pscustomobject]@{ task = $task; check = $check; panel = $card })
}

$ioText = (@($board.device_map) | ForEach-Object { "$($_.address) $($_.name)" }) -join "`r`n"
$toolTip.SetToolTip($summary, "Server $($board.network.server_ip):$($board.network.port)`r`n$ioText")

$buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonPanel.Dock = "Fill"
$buttonPanel.FlowDirection = "RightToLeft"
$buttonPanel.WrapContents = $false
$buttonPanel.Padding = New-Object System.Windows.Forms.Padding(0)
$root.Controls.Add($buttonPanel, 0, 3)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = "Save"
$saveButton.Width = 54
$saveButton.Height = 23
$buttonPanel.Controls.Add($saveButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = "Close"
$closeButton.Width = 54
$closeButton.Height = 23
$buttonPanel.Controls.Add($closeButton)

$jsonButton = New-Object System.Windows.Forms.Button
$jsonButton.Text = "JSON"
$jsonButton.Width = 50
$jsonButton.Height = 23
$buttonPanel.Controls.Add($jsonButton)

$ladderButton = New-Object System.Windows.Forms.Button
$ladderButton.Text = "Ladder"
$ladderButton.Width = 58
$ladderButton.Height = 23
$buttonPanel.Controls.Add($ladderButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Dock = "Left"
$statusLabel.Width = 80
$statusLabel.TextAlign = "MiddleLeft"
$statusLabel.ForeColor = [System.Drawing.Color]::DimGray
$statusLabel.Text = "Ready"
$buttonPanel.Controls.Add($statusLabel)

$feedbackTimer = New-Object System.Windows.Forms.Timer
$feedbackTimer.Interval = 1600
$feedbackTimer.Add_Tick({
  $feedbackTimer.Stop()
  $form.Text = "CUCP Kanban"
  $statusLabel.ForeColor = [System.Drawing.Color]::DimGray
})

function Save-UiBoard {
  foreach ($cardInfo in @($taskCards)) {
    $id = "$($cardInfo.check.Tag)"
    foreach ($task in @($board.tasks)) {
      if ("$($task.id)" -eq $id) {
        $task.done = [bool]$cardInfo.check.Checked
      }
    }
  }
  Save-SpecBoard -Board $board | Out-Null
  $doneNow = @($board.tasks | Where-Object { [bool]$_.done }).Count
  $header.Text = "$($board.title)   $doneNow/$taskCount"
  $statusLabel.Text = "Saved"
  $statusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
  $form.Text = "CUCP Kanban - Saved"
  $feedbackTimer.Stop()
  $feedbackTimer.Start()
}

$saveButton.Add_Click({
  try { Save-UiBoard } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Save failed") | Out-Null }
})

$closeButton.Add_Click({
  try {
    Save-UiBoard
    $form.Close()
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Save failed") | Out-Null
  }
})

$jsonButton.Add_Click({
  try {
    Save-UiBoard
    # argument injection 방어: 경로를 단일 배열 원소로 전달 (문자열 보간 회피).
    Start-Process -FilePath "notepad.exe" -ArgumentList @($Path)
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Open failed") | Out-Null
  }
})

$ladderButton.Add_Click({
  try {
    Save-UiBoard
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "cucp-spec-board-ladder.txt"
    Set-Content -LiteralPath $tmp -Value (Render-LadderPlan -Board $board) -Encoding UTF8
    # argument injection 방어: 경로를 단일 배열 원소로 전달.
    Start-Process -FilePath "notepad.exe" -ArgumentList @($tmp)
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Ladder failed") | Out-Null
  }
})

$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
