# Scripts

Public entry points:

- `cucp.ps1` - main wrapper, safety gates, macro dispatch, JSON envelopes.
- `cucp-native-helper.ps1` - Win32, UIA, OCR, screenshots, CDP, and hit-test helpers.
- `cucp-helper-server.ps1` - optional resident helper for repeated low-latency calls.

Keep live-control behavior gated by `-AllowLiveControl`.
