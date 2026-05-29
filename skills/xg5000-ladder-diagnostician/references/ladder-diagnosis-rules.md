# Ladder Diagnosis Rules

Use these checks before proposing a ladder edit.

## High Priority Faults

- STOP contact in a motor self-hold circuit should usually be normally closed: `--|/| STOP --`.
- START contact usually triggers the run latch: `--| | START --`.
- The run output often appears twice: once as the output coil and once as the self-hold contact.
- The same output coil should not be driven by multiple unrelated rungs unless the design explicitly uses SET/RST or a structured state machine.
- `SET` and `RST` on the same bit must have clear, non-overlapping conditions. Missing reset conditions create outputs that never turn off.
- Word devices such as `D0100` should not be used as bit contacts or coils unless bit access syntax is intentionally used and supported.
- Timer/counter done bits must be paired with reset logic when the sequence requires repeated operation.

## Medium Priority Faults

- Input devices should normally appear as contacts, not coils.
- Output devices should normally appear as coils or output contacts used for seal-in/status, not as raw inputs.
- Device addresses in the ladder should match the current spec-board/device map.
- Safety interlocks should be before the output coil, not after it.
- Manual/auto mode conditions should be mutually understandable and should not energize the same output in two uncontrolled paths.

## Explanation Pattern

When explaining a fault:

1. Name the rung intent.
2. Describe the PLC scan path from left to right.
3. Say which condition becomes true/false.
4. Explain why the output energizes, stays energized, or never energizes.
5. Give a minimal correction.

## Typical Self-Hold Pattern

```text
--|/| STOP --+--| | START --+----------------( ) RUN
             |              |
             +--| | RUN ----+
```

Meaning:

- STOP false/open breaks the entire rung.
- START true energizes RUN once.
- RUN contact then keeps the rung true after START is released.
