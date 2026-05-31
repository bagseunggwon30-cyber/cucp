# CUCP Remaining Work

Updated: 2026-05-31

Public repository scope: Windows computer-use control plane, desktop observation, UIA/CDP/OCR routing, guarded live control, workflow planning, diagnostics, and release hygiene.

## Done

- Removed private vendor-specific assets and public-facing references.
- Kept the reusable CUCP core focused on Windows GUI automation.
- Preserved public examples around Notepad, Kiro, Chrome, generic forms, documents, and browser/Electron workflows.

## Next

- Keep daemon startup and helper-server paths easy to install.
- Add concise macOS/Linux unsupported-mode notes.
- Improve DXGI capture and multi-monitor coordinate validation.
- Add benchmark documentation and repeatable smoke-test instructions.
- Keep release notes and public docs free of private workflow details.

## Verified Targets

- PowerShell AST parse for core scripts.
- Fast smoke tests for wrapper surface and read-only macros.
- Public documentation keyword scan before release.