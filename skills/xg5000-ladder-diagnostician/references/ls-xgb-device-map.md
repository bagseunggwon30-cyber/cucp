# LS XGB Device Map Notes

Use the project/spec-board as the authority. These notes are only practical defaults.

## Common Devices

- `P`: physical I/O bit area in many LS XGB/XG5000 projects. Check module and slot mapping.
- `M`: internal auxiliary bit.
- `D`: data register / word.
- `T`: timer.
- `C`: counter.
- `K`: constant.

## Current Classroom Spec Pattern

From the CUCP spec-board example:

| Address | Name | Type | Direction | Meaning |
| :--- | :--- | :--- | :--- | :--- |
| `P0020` | `START_BUTTON` | bit | input | Start pushbutton |
| `P0021` | `STOP_BUTTON` | bit | input | Stop pushbutton |
| `P0040` | `MOTOR_RUN` | bit | output | Motor run output |
| `D0100` | `TARGET_SPEED` | word | internal | Target speed register |

## Address Reasoning

- Bit inputs should be used as contacts.
- Bit outputs can be coils and can also be contacts for self-hold/status.
- Word registers should be used by word instructions such as move/compare/math/communication mapping, not as basic bit contacts.
- Before physical download, always verify module slot, I/O parameter assignment, and actual terminal wiring.
