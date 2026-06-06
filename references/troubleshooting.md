# Troubleshooting

CUCP commands should fail with explicit status, exit code, warnings, or
`recoverable_errors[]`. Start with the smallest read-only command that proves the
layer you need.

## Quick Checks

```powershell
cucp version
cucp macro health-quick
cucp macro windows
cucp macro log-tail --errors-only
```

If the wrapper itself fails, run the script directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cucp.ps1 macro health-quick
```

## Common Problems

| Symptom | Likely Cause | Next Step |
|:--|:--|:--|
| No windows returned | Desktop is locked, hidden, or helper fallback failed. | Unlock the desktop and run `cucp macro windows --json-only`. |
| Label not found | UIA/OCR did not expose the target or the label is different. | Run `list-affordances --window "<title>"`. |
| Ambiguous target | Multiple candidates are close in score. | Add `--match`, `--window`, `--role`, or use `click-id`. |
| Exit code `3` | Safety gate blocked the action. | Confirm the action is allowed and add `-AllowLiveControl` only for live control. |
| Coordinate click blocked | Hit-test guard did not match the expected target. | Re-run `hit-test` and pass `--target-match` or `--target-hwnd`. |
| CDP unavailable | App was not launched with a local debugging port. | See `references/cdp-setup.md`. |
| OCR misses text | OCR language pack, contrast, scale, or region is unsuitable. | Try a smaller region or prefer UIA/CDP labels. |
| Command times out | Helper startup or child process is slow. | Increase `-InvokeTimeoutMs`, run `health-quick`, then `ensure-helper`. |

## Read-Only Before Live Control

Before a click or type action:

```powershell
cucp macro windows --match "Notepad"
cucp macro find-label --label "Save" --match "Notepad" --explain
cucp macro hit-test --x 1200 --y 720 --target-match "Notepad"
```

Then run the live action only after the user approved it:

```powershell
cucp -AllowLiveControl macro click-label --label "Save" --match "Notepad"
```

Verify immediately:

```powershell
cucp macro wait-label --label "Saved" --window "Notepad" --timeout-ms 3000
```

## Helper Server

The resident helper is optional. It can reduce latency for repeated calls, but
the wrapper should still provide read-only fallback behavior without it.

```powershell
cucp macro ensure-helper
cucp macro health-detail
cucp macro session info
cucp macro session clear-cache
```

If the helper looks stale, clear the session cache and retry the read-only
command before attempting live control.

## Logs And Cleanup

```powershell
cucp macro log-tail --lines 80 --errors-only
cucp macro trajectory show --last 20
cucp macro cleanup --dry-run
cucp macro cleanup --execute --older-than-minutes 30 --keep-latest 50
```

`cleanup --dry-run` should be used first. It reports candidates without deleting
runtime files.

## Performance

```powershell
cucp macro perf --iters 1 --quick
cucp macro diagnose-lag --sample-ms 3000
```

Use these when an agent loop feels slow. They are diagnostic tools, not hard
pass/fail benchmarks.

## Parser Check

If a script edit may have broken PowerShell syntax:

```powershell
$files = 'scripts\cucp.ps1','scripts\cucp-native-helper.ps1','scripts\cucp-helper-server.ps1'
foreach ($file in $files) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file), [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count) { $errors | Format-List; exit 1 }
}
```
