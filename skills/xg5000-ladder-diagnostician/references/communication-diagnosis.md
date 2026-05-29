# Communication Diagnosis Notes

Use these notes to avoid misdiagnosing a communication setup issue as a ladder logic fault.

## XGT/P2P Classroom Pattern

In the class notes, the HMI does not directly control PLC #2. PLC #1 acts as a relay:

```text
HMI
-> PLC #1 channel 1: XGT
-> PLC #1 channel 2: P2P
-> PLC #2 XGT channel
-> PLC #2 ladder action
-> status returns to PLC #1
-> HMI display
```

Checks:

- PLC #1 channel 1 should match the HMI XGT tag path.
- PLC #1 channel 2 should be set to `Use P2P`.
- The P2P channel driver depends on the actual protocol; for PLC-to-PLC class work it can be `XGT Client`.
- PLC #2 should be ready to receive XGT communication.
- After configuration, parameter download and P2P Link Enable must be checked.

## P2P Is a Block Execution Method

P2P is not always the protocol itself. In XG5000/Cnet, P2P is a way to register communication blocks and run them. The actual driver may be:

| Driver | Meaning |
| :--- | :--- |
| XGT Client | Read/write another LS XGT/XGB PLC |
| Modbus RTU Client | Read/write a Modbus RTU slave device |
| User Frame | Custom frame protocol |

## Modbus Versus D Device

Modbus address means the external logical address. `D` device means PLC internal word storage.

Typical flow:

```text
External register 30001
-> P2P read
-> store in PLC D100
-> show D100 in HMI
```

Address area rule of thumb:

```text
0/1 = Bit
3/4 = Word
0/4 = writable
1/3 = read-only
```

If an HMI/SCADA write does not work, first check whether the target area is writable. Do not assume the ladder is wrong before checking address area and mapping.

## Ladder Diagnosis Boundary

When symptoms say "the output does not move":

1. Verify the ladder condition and coil first.
2. Verify I/O parameter and physical module mapping.
3. Verify communication path, channel mode, host table/IP, and P2P Link Enable.
4. Only then decide whether it is a ladder logic bug or communication/configuration bug.
