# CUCP Command Reference

CUCP exposes a single wrapper:

```powershell
cucp [wrapper-flags] <command> [command-args]
```

If the shim is not installed, call the wrapper directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cucp.ps1 <args>
```

## Wrapper Flags

| Flag | Purpose |
|:--|:--|
| `-AllowLiveControl` | Required for clicks, typing, shortcuts, app launch/close, and live workflow execution. |
| `-Brief` | Prefer compact text output where supported. |
| `-Quiet` | Suppress diagnostic chatter where supported. |
| `-CacheSeconds <n>` | Control observation cache TTL. Use `0` to disable. |
| `-InvokeTimeoutMs <n>` | Bound helper/child command execution time. |

## Exit Codes

| Code | Meaning |
|:--|:--|
| `0` | Success. |
| `1` | Generic failure, missing input, or not found. |
| `2` | Partial, ambiguous, or recoverable no-match result. |
| `3` | Safety block. Live-control approval or another safety gate is missing. |
| `124` | Timeout. |

## Read-Only Observation

```powershell
cucp macro windows
cucp macro windows --match "Notepad" --json-only
cucp macro find-label --label "Save" --explain
cucp macro list-affordances --window "Notepad" --limit 20
cucp macro screenshot --out-path .\screen.png
cucp macro native-windows
cucp macro native-screenshot --out-path .\screen.png
```

Use these before live control. They provide the evidence needed to choose a
target by title, label, role, HWND, or coordinate.

## Planning And Validation

```powershell
cucp macro smart-plan --label "Save" --match "Notepad"
cucp macro workflow-plan --step "macro windows" --step "macro find-label --label Save"
cucp macro form-plan --field "Name=Alice" --send-label "Save" --match "Notepad"
cucp macro task-plan --app notepad --wait-title Notepad --type-text "hello" --shortcut "ctrl+s"
cucp macro hit-test --x 1200 --y 720 --target-match "Notepad"
cucp macro hit-test-batch --points "1200,720;1210,720" --target-match "Notepad"
cucp macro hit-scan --x 1200 --y 720 --radius 6 --step 2 --target-match "Notepad"
cucp macro point-plan --x 1200 --y 720 --target-match "Notepad"
cucp macro target-validate --x 1200 --y 720 --target-match "Notepad"
```

Planning commands are read-only. They should return recommended commands, target
evidence, confidence, and recoverable errors rather than performing input.

## Live Control

Every command in this section requires `-AllowLiveControl`.

```powershell
cucp -AllowLiveControl macro click-label --label "Save" --match "Notepad"
cucp -AllowLiveControl macro double-click-label --label "File.txt" --match "Explorer"
cucp -AllowLiveControl macro right-click-label --label "File.txt" --match "Explorer"
cucp -AllowLiveControl macro click-id --id "<affordance-id>"
cucp -AllowLiveControl macro click-point --x 1200 --y 720 --target-match "Notepad"
cucp -AllowLiveControl macro fill-label --label "Name" --text "Alice"
cucp -AllowLiveControl macro shortcut --keys "ctrl+s"
cucp -AllowLiveControl macro focus-window --name "Notepad"
cucp -AllowLiveControl macro smart-click --label "Save" --match "Notepad"
```

Prefer `click-label`, `fill-label`, `smart-click`, or CDP routes before raw
coordinates. If coordinates are unavoidable, include `--target-match` or
`--target-hwnd`.

## App And Workflow Helpers

```powershell
cucp macro wait-window --title "Notepad" --timeout-ms 10000
cucp macro wait-label --label "Saved" --window "Notepad" --timeout-ms 3000
cucp -AllowLiveControl macro app-launch --name notepad
cucp -AllowLiveControl macro app-close --match "Notepad"
cucp -AllowLiveControl macro with-app --name notepad --hold-ms 1000 --close-after
cucp macro workflow-run --dry-run --step "macro windows" --step "macro find-label --label Save"
cucp -AllowLiveControl macro workflow-run --step "macro click-label --label Save --match Notepad"
cucp -AllowLiveControl macro form-run --field "Name=Alice" --send-label "Save" --match "Notepad"
```

Use `--dry-run` first when a workflow contains live steps.

## OCR, Vision, And Screen Diff

```powershell
cucp macro ocr-screen --region 0,0,800,600
cucp macro ocr-image --path .\screen.png
cucp macro ocr-find-text --text "Send"
cucp -AllowLiveControl macro ocr-click --text "Send" --target-match "App"
cucp macro ocr-uia-fuse --text "Send"
cucp -AllowLiveControl macro ocr-uia-invoke --text "Send"
cucp macro screenshot-diff --before .\before.png --after .\after.png
cucp -AllowLiveControl macro click-and-verify-screen --label "Save" --match "Notepad"
cucp macro vision-find --describe "the save button"
cucp -AllowLiveControl macro vision-click --describe "the save button"
```

OCR and vision should be fallback paths when UIA/CDP labels are not available.

## CDP For Chromium And Electron Apps

Start the app with a local debugging port, then use:

```powershell
cucp macro cdp-detect --port 9222
cucp macro cdp-eval --expr "document.title" --port 9222
cucp macro cdp-deep-find --text "Send" --port 9222
cucp macro cdp-smart-find --text "Send" --port 9222
cucp macro cdp-smart-type-find --label "Message" --port 9222
cucp -AllowLiveControl macro cdp-click --selector "button[aria-label='Send']" --port 9222
cucp -AllowLiveControl macro cdp-type --selector "textarea" --text "hello" --press-enter --port 9222
cucp -AllowLiveControl macro cdp-smart-click --text "Send" --port 9222
cucp -AllowLiveControl macro cdp-smart-type --label "Message" --text "hello" --press-enter --port 9222
```

See [cdp-setup.md](cdp-setup.md).

## Recovery And Diagnostics

```powershell
cucp macro modal-detect
cucp macro recovery-plan --failed-step "macro click-label --label Save"
cucp macro recovery-run --dry-run
cucp -AllowLiveControl macro recovery-run --confirm-sensitive
cucp macro health-quick
cucp macro health-detail
cucp macro metrics
cucp macro perf --iters 1 --quick
cucp macro diagnose-lag --sample-ms 3000
cucp macro cleanup --dry-run
cucp macro log-tail --lines 50 --errors-only
cucp macro trajectory show --last 20
cucp macro session info
cucp macro session clear-cache
```

## Governance And Audit Helpers

```powershell
cucp macro recorder list
cucp macro recorder show --name "<session>"
cucp macro audit-summary --since-minutes 60
cucp macro policy-check --action click-label
cucp macro safety-classify --text "delete this account"
cucp macro release-notes
```

## Plan Files

Example:

```powershell
cucp plan validate --file .\plans\notepad-hello-world.json
cucp plan dry-run --file .\plans\notepad-hello-world.json
cucp plan readiness --file .\plans\notepad-hello-world.json --strict
cucp plan preflight --file .\plans\notepad-hello-world.json
cucp -AllowLiveControl plan run --file .\plans\notepad-hello-world.json --readiness --strict-readiness --preflight
```

Plan files should make observations, actions, and verification steps explicit.
Keep examples generic enough to run on a clean Windows development machine.

## Testing

```powershell
Invoke-Pester .\tests\cucp.Fast.Tests.ps1
Invoke-Pester .\tests\cucp.Tests.ps1
```

For a parser-only check:

```powershell
$files = 'scripts\cucp.ps1','scripts\cucp-native-helper.ps1','scripts\cucp-helper-server.ps1'
foreach ($file in $files) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file), [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count) { $errors | Format-List; exit 1 }
}
```
