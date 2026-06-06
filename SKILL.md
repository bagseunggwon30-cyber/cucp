---
name: cucp-computer-use
description: Use CUCP (Computer Use Control Plane) to observe, plan, and safely operate the local Windows desktop through Win32, UI Automation, OCR, and optional Chromium CDP routes. Trigger on cucp, computer use, Windows control, desktop control, GUI automation, screen control, app control, label click, button click, find-label, appshot, snapshot, OCR, UIA, CDP, or when the user asks an agent to inspect, click, type, drag, scroll, switch apps, run a desktop workflow, or verify a Windows GUI state.
---

# CUCP Computer Use

CUCP is a local Windows desktop control helper for agent workflows. The wrapper
entry point is:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cucp.ps1 [-AllowLiveControl] [-Brief] [-Quiet] [-CacheSeconds <n>] [-InvokeTimeoutMs <n>] <args>
```

When installed through `install.ps1`, the same wrapper is available as:

```powershell
cucp <args>
```

## Operating Loop

Use CUCP in this order:

1. Observe the current desktop state.
2. Pick a grounded target from windows, UIA controls, OCR text, or CDP DOM data.
3. Act only when the user approved live control and the wrapper gate is explicit.
4. Verify the changed state immediately after the action.

Read-only commands do not need `-AllowLiveControl`. Any command that clicks,
types, sends a shortcut, launches/closes apps, or runs a live workflow must use
`-AllowLiveControl`.

## Common Commands

Read-only observation:

```powershell
cucp macro windows
cucp macro find-label --label "Save" --explain
cucp macro list-affordances --window "Notepad" --limit 20
cucp macro health-quick
cucp macro log-tail --errors-only
```

Planning and verification:

```powershell
cucp macro smart-plan --label "Save" --match "Notepad"
cucp macro hit-test --x 1200 --y 720 --target-match "Notepad"
cucp macro target-validate --x 1200 --y 720 --target-match "Notepad"
cucp macro recovery-plan --failed-step "macro click-label --label Save"
```

Live control:

```powershell
cucp -AllowLiveControl macro click-label --label "Save" --match "Notepad"
cucp -AllowLiveControl macro fill-label --label "Name" --text "Alice"
cucp -AllowLiveControl macro shortcut --keys "ctrl+s"
cucp -AllowLiveControl macro smart-click --label "Save" --match "Notepad"
```

CDP for Chromium/Electron apps:

```powershell
cucp macro cdp-detect --port 9222
cucp macro cdp-deep-find --text "Send" --port 9222
cucp -AllowLiveControl macro cdp-smart-click --text "Send" --port 9222
```

## Safety Rules

- Do not operate UAC prompts, credential dialogs, payment screens, private
  messages, or identity documents unless the user explicitly approved the exact
  action.
- Prefer label/UIA/CDP targets over raw coordinates.
- For raw coordinates, use `hit-test`, `target-validate`, `--target-match`, or
  `--target-hwnd` before any live click.
- If a target is ambiguous or confidence is low, stop and report candidates.
- After live control, verify with `windows`, `find-label`, `wait-label`,
  `screenshot-diff`, or another read-only check.
- Treat exit code `3` as a safety block, not as a generic failure.

## Output Handling

Most rich commands return JSON envelopes with:

- `schema`
- `kind`
- `status`
- `elapsed_ms`
- `warnings`
- `recoverable_errors`
- command-specific `data`

Use `-Brief` for compact text when a model only needs the next action, and use
`--json-only` when deterministic parsing matters.

## Troubleshooting Pointers

- No matching window: run `cucp macro windows` and adjust `--match`.
- No matching label: run `cucp macro list-affordances --window "<title>"`.
- Helper unavailable: run `cucp macro health-quick` or `cucp macro ensure-helper`.
- CDP closed: launch the Chromium/Electron app with `--remote-debugging-port`.
- Slow session: run `cucp macro diagnose-lag --sample-ms 3000`.

Detailed references:

- `references/command-reference.md`
- `references/cdp-setup.md`
- `references/troubleshooting.md`
