# CUCP Upload Notes - 2026-05-29

Target repository:

- `bagseunggwon30-cyber/cucp`
- `https://github.com/bagseunggwon30-cyber/cucp.git`

## Upload Attempt

GitHub plugin repository read worked, but file creation failed:

```text
403 Resource not accessible by integration
```

This means the current GitHub connector can read repository metadata/files, but does not have contents write permission for this repository session.

## Local Package Contents

This local package includes the 2026-05-29 CUCP update:

- `scripts/cucp-spec-board.ps1`
- `scripts/cucp-task-card.ps1`
- `scripts/cucp.ps1` with `macro spec-board` integration
- `references/command-reference.md`
- `references/xg5000-task-card.md`
- `skills/xg5000-ladder-diagnostician/`
- `CHANGELOG.md` v1.5.2 entry

## Summary

The update adds a compact XG5000 spec/Kanban board and a ladder diagnostician skill. The ladder diagnostician performs first-pass checks for STOP NC, START NO, self-hold, duplicate coils, SET/RST mismatch, and word-as-bit misuse, then explains the PLC scan principle and safe fix direction.

## Next Upload Path

Reconnect GitHub with contents write permission, then upload this package or push these files to `main` or a feature branch.
