# Remaining Work

Public repository scope: vendor-neutral Windows GUI automation for local AI
agents.

## Current Focus

- Keep the `cucp` wrapper easy to install and easy to run without admin rights.
- Keep live-control behavior explicit, gated, auditable, and recoverable.
- Keep public docs focused on generic Windows desktop automation.
- Keep examples centered on Notepad, Explorer, browsers, Chromium/Electron apps,
  forms, and other common desktop workflows.

## Next Improvements

- Add clearer unsupported-mode notes for macOS and Linux.
- Improve multi-monitor coordinate validation documentation.
- Add repeatable benchmark instructions that separate smoke tests from live
  desktop tests.
- Add more deterministic examples for CDP, UIA, OCR fallback, and recovery.
- Keep private workflow details out of public release notes and references.

## Verification Targets

- PowerShell AST parse for core scripts.
- Fast Pester smoke tests for wrapper and read-only macro surface.
- Public documentation keyword scan before release.
- Manual live smoke only when the user explicitly approves desktop control.
