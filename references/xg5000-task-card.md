# XG5000 / XP-Builder Task Card Bridge

Use this bridge when CUCP is paired with an XG5000 or XP-Builder workflow.

## Startup Flow

1. Open the local card before analysis:

   ```powershell
   & C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro task-card open
   ```

2. Before planning or editing, read the card:

   ```powershell
   & C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro task-card show
   ```

3. Profile the active tool window:

   ```powershell
   & C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro app-profile --match "XG5000" --probe-uia --include-affordances --json-only
   ```

`app-profile` includes the card as `task_card` for PLC/SCADA-like windows. The caller should use that context before any live action.

## Card Fields

- `tool`: XG5000, XP-Builder, CIMON, SCADA, or other.
- `project_name`: current project or lesson name.
- `plc_model`: target PLC family/model.
- `communication`: XGT/P2P, XGT Server, Modbus RTU/TCP, Serial, Ethernet, or other.
- `devices`: parsed list from `devices_text`.
- `address_ranges`: parsed list from `address_ranges_text`.
- `requirements`: requested behavior or checks.
- `constraints`: safety limits such as no download, no online write, or real equipment guard.
- `safety_flags`: generated hints from constraints.

## XG5000 Skill Hook

If a separate XG5000 skill is installed later, add this rule to its `SKILL.md`:

> At session start, run `macro task-card open` if the user wants CUCP help, and read `macro task-card show` before planning. Treat `constraints` and `safety_flags` as hard planning input. Prefer read-only analysis unless the user explicitly allows live control.
