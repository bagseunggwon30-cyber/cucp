---
name: xg5000-ladder-diagnostician
description: Diagnose, explain, teach, and safely plan fixes for LS XG5000 ladder logic, especially XGB/XGT projects using CUCP, spec-board, task-card, PLC scan principles, self-hold circuits, NO/NC contacts, coils, SET/RST, timers, counters, device maps, and Korean classroom PLC work. Use when the user asks for ladder troubleshooting, ladder diagnosis, XG5000 behavior explanation, automatic operation failures, PLC education, or safe fix planning.
---

# XG5000 Ladder Diagnostician

Use this skill as a read-first ladder logic diagnosis and teaching agent for LS XG5000 work. It pairs with CUCP `spec-board` and `task-card`.

## Safety Default

Default to read-only diagnosis. Do not download, online-write, force outputs, run live equipment, or edit XG5000 directly unless the user explicitly authorizes live CUCP control and the current `spec_board` / `task_card` safety fields allow it.

When the user wants live XG5000 work, follow:

1. Read context:
   ```powershell
   & C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro spec-board show
   & C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro task-card show
   ```
2. Profile XG5000:
   ```powershell
   & C:\Users\bark\.codex\skills\cucp-computer-use\scripts\cucp.ps1 macro app-profile --match XG5000 --probe-uia --include-affordances --json-only
   ```
3. Diagnose and teach before editing.
4. Present a fix plan and dry-run route.
5. Only then use `-AllowLiveControl`, if explicitly approved.

## Workflow

1. Collect evidence: spec-board JSON, task-card JSON, XG5000 profile, ladder text/OCR/manual notes/screenshots.
2. Normalize device map: map each address to name, type, direction, and description.
3. Run deterministic checks with `scripts/diagnose-ladder.ps1` when ladder text is available.
4. Apply reasoning rules from:
   - `references/ladder-diagnosis-rules.md`
   - `references/plc-scan-principles.md`
   - `references/ls-xgb-device-map.md`
   - `references/communication-diagnosis.md`
   - `references/manual-sources.md`
   - `references/xg5000-workflow.md`
5. Explain in this order:
   - What the circuit is intended to do.
   - Why it currently works or fails.
   - Which device/contact/coil causes the issue.
   - What to change.
   - What safety check must happen before PLC download or output test.

## Deterministic Check

Use the script when the ladder can be represented as text:

```powershell
& C:\Users\bark\.codex\skills\cucp-computer-use\skills\xg5000-ladder-diagnostician\scripts\diagnose-ladder.ps1 `
  -SpecBoardPath C:\Users\bark\AppData\Local\Temp\computer-use-control-plane\spec-board\current-spec-board.json `
  -LadderTextPath C:\path\to\ladder.txt `
  -Markdown
```

If ladder text is not available, first use CUCP read-only observation/OCR to gather enough evidence, then diagnose from the visible rung structure. Treat low-confidence OCR as a hint, not proof.

## Report Style

Keep reports practical and educational:

- `요약`: one-sentence diagnosis.
- `문제`: address, symptom, cause.
- `원리`: PLC scan / contact / coil behavior.
- `수정안`: specific rung/device change.
- `안전`: download/output-test guard.

For classroom use, explain the underlying principle gently and concretely rather than only giving the answer.
