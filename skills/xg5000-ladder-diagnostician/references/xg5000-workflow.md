# XG5000 Diagnosis Workflow

Use this workflow with CUCP.

## Read-Only Observation

```powershell
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro app-profile --match XG5000 --probe-uia --include-affordances --json-only
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro spec-board show
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro task-card show
```

If the ladder surface is not exposed through UIA, use foreground OCR only as a fallback:

```powershell
& C:\Users\K\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro ocr-screen --foreground --auto-region foreground
```

## Diagnosis Output

Return:

- circuit intent
- observed rung structure
- likely fault
- principle explanation
- proposed correction
- safety guard
- whether live XG5000 edit is allowed or still blocked

## XG5000 Native Evidence

When CUCP can access the UI, prefer XG5000's own diagnostic windows as evidence:

- Check Program for syntax/errors/warnings/messages.
- Duplicate Coil for redundant coil use.
- Used Device for memory address use.
- Cross Reference for where a device or variable is applied.
- Communication window for CPU connection status.
- P2P window for peer-to-peer configuration.

## Live Edit Guard

Before editing in XG5000:

- User explicitly approved live control.
- Spec-board warnings do not forbid editing.
- Task-card constraints do not include download/online-write block for the requested action.
- A dry-run plan has been shown.
- The target XG5000 window was re-profiled immediately before action.
