# CUCP v1.5.1 XG5000 Task Card Upload Notes

Prepared on 2026-05-27.

## Included Updates

- Added `scripts/cucp-task-card.ps1`.
- Added `scripts/cucp-xg5000-bridge.ps1`.
- Updated `scripts/cucp.ps1` locally with `macro task-card` and `app-profile.task_card` auto-load.
- Added `references/xg5000-task-card.md`.
- Added separate Codex skill `skills/xg5000-cucp-assistant/SKILL.md`.
- Updated `README.md`, `SKILL.md`, `CHANGELOG.md`, `references/command-reference.md`, and `references/remaining-work.md`.

## Verification

- PowerShell AST parse passed for:
  - `scripts/cucp.ps1`
  - `scripts/cucp-task-card.ps1`
  - `scripts/cucp-xg5000-bridge.ps1`
- Verified `task-card clear`, `task-card ensure`, `task-card save`, `task-card path`, and `app-profile --match XG5000` with `task_card` output locally.

## GitHub Upload Status

The Codex GitHub connector can read `bagseunggwon30-cyber/cucp`, but GitHub returned `403 Resource not accessible by integration` for write attempts. The prepared ZIP is:

`C:\Users\K\Documents\Codex\cucp-github-main\cucp-main-v1.5.1-xg5000-task-card.zip`

Reauthorize the GitHub connector with repository contents write access, install Git with credentials, or upload the ZIP contents through GitHub web UI to publish these changes.
