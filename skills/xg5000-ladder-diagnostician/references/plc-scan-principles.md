# PLC Scan Principles

Use this reference when teaching why a ladder works or fails.

## Scan Order

1. Read input image.
2. Execute ladder from top to bottom, left to right.
3. Update internal bits/registers as instructions execute.
4. Write output image to physical outputs.

Important teaching point: a coil written later in the scan can overwrite or conflict with an earlier rung. This is why duplicate coils are risky.

## Contact and Coil Meaning

- NO contact `--| |--`: true when the bit is ON.
- NC contact `--|/|--`: true when the bit is OFF.
- Coil `( )`: writes the result of the rung to the target bit.
- SET: latches a bit ON until RST.
- RST: unlatches a bit OFF.

## Motor Self-Hold

A self-hold circuit uses the output bit as a parallel contact with the START button. Once the output turns ON, the output contact keeps the rung true even when START is released. STOP must break both START and self-hold paths.

## Common Student Mistakes

- Placing STOP as NO, causing the circuit to run only while stop is pressed.
- Placing the self-hold contact in series instead of parallel with START.
- Using the output contact before the coil ever turns ON without a START bypass.
- Using the same coil in two rungs and wondering why one rung seems ignored.
- Treating a word register as a bit signal.
