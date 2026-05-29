---
name: xg5000-cucp-assistant
description: Use when helping with LS ELECTRIC XG5000, XP-Builder, XGT PLC ladder/HMI work, PLC/SCADA class exercises, device/address checks, communication setup, P2P/XGT/Modbus review, or when CUCP should inspect or plan actions for XG5000/XP-Builder without unsafe live edits.
---

# XG5000 CUCP Assistant

Use this skill with `cucp-computer-use`. It specializes CUCP for XG5000 and XP-Builder sessions where device names, address ranges, PLC communication settings, ladder logic, and HMI requirements must be kept in context.

## Required Context Flow

1. Start with the task card and spec board:

   ```powershell
   & C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro task-card open
   & C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro spec-board open
   ```

   If the installed CUCP wrapper does not yet expose `macro task-card`, use the repository bridge script:

   ```powershell
   & .\scripts\cucp-xg5000-bridge.ps1 task-card open
   ```

2. Before planning, read the saved JSON:

   ```powershell
   & C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro task-card show
   & C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro spec-board show
   ```

3. Profile the active program without moving the mouse:

   ```powershell
   & C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro app-profile --match "XG5000" --probe-uia --include-affordances --json-only
   ```

For XP-Builder, replace the match string with `XP-Builder`.

## Safety Defaults

- Prefer read-only analysis: `app-profile`, `windows`, `list-affordances`, `find-label`, `ocr-find-text`, `coord-info`, `target-validate`, and screenshots.
- Do not download to PLC, online-write, force I/O, change live equipment, or close a project unless the user explicitly asks for that exact action.
- Treat `task_card.constraints`, `task_card.safety_flags`, and `spec_board.warnings` as hard planning input.
- Use `task-run --dry-run` or `workflow-run --dry-run` before any live operation.
- Live control requires `-AllowLiveControl` and a fresh confirmation from the user when the action can affect PLC/HMI state.

## Planning Heuristics

- XG5000 surfaces often mix UIA controls with owner-drawn ladder/canvas areas. Try UIA patterns first, then guarded hit-test or precision-point routes, and use OCR only when labels are not exposed.
- XP-Builder/HMI screens may expose object names poorly. Capture the foreground window and use OCR/affordance lists to identify dialogs, property panes, and toolbars.
- For ladder checks, collect device context first: `X`, `Y`, `M`, `D`, `T`, `C`, communication channel, PLC number, station number, and P2P/XGT/Modbus role.
- When a ladder fault diagnosis is requested, use the nested `xg5000-ladder-diagnostician` skill and the deterministic `diagnose-ladder.ps1` helper when ladder text is available.
- For communication lessons, distinguish these clearly:
  - `XGT Server`: PLC serves LS/XGT protocol requests.
  - `P2P`: PLC-to-PLC or PLC-to-device configured peer communication.
  - `Modbus RTU/TCP`: Modbus protocol mapping; do not assume P2P just because serial wiring is used.

## Output Expectations

When reporting findings, include:

- The active tool/window used for evidence.
- Device/address assumptions from the task card and spec board.
- Read-only observations versus planned live actions.
- Any safety block, ambiguity, or missing requirement before suggesting edits.
