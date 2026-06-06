# CDP Setup

CUCP can control Chromium and Electron apps through the Chrome DevTools Protocol
(CDP). CDP is useful when a target is implemented as a web view and UI
Automation does not expose the right control.

## When To Use CDP

Use CDP for:

- Chromium browsers
- Electron apps
- web-based editors
- contenteditable fields
- Shadow DOM or iframe-heavy interfaces

Avoid CDP when:

- the app is a native Win32/UWP application
- the app cannot be launched with a debugging port
- the desktop is shared with untrusted local users

## Launch With A Debugging Port

Use one port per app to avoid conflicts:

```powershell
code.exe --remote-debugging-port=9223
slack.exe --remote-debugging-port=9224
chrome.exe --remote-debugging-port=9225
```

Some apps need to be fully closed before the flag takes effect.

## Verify The Port

```powershell
cucp macro cdp-detect --port 9223
```

You can also open:

```text
http://127.0.0.1:9223/json/list
```

If the endpoint returns JSON page metadata, CDP is available.

## Use CUCP CDP Commands

```powershell
cucp macro cdp-eval --expr "document.title" --port 9223
cucp macro cdp-deep-find --text "Send" --port 9223
cucp macro cdp-smart-find --text "Send" --port 9223
cucp -AllowLiveControl macro cdp-click --selector "button[aria-label='Send']" --port 9223
cucp -AllowLiveControl macro cdp-type --selector "textarea" --text "hello" --press-enter --port 9223
cucp -AllowLiveControl macro cdp-smart-click --text "Send" --port 9223
```

`smart-click` can also try CDP first when explicitly requested:

```powershell
cucp -AllowLiveControl macro smart-click --label "Send" --allow-cdp --cdp-port 9223
```

## Security Notes

`--remote-debugging-port` exposes the app's DOM to local processes that can reach
`127.0.0.1:<port>`. On a trusted single-user development machine this is usually
acceptable. On shared or untrusted machines, disable the debugging port when it
is not needed.

Do not expose the debugging port on a public network interface.
Close the app or restart it without the flag when CDP access is no longer
needed.

## Troubleshooting

| Symptom | Likely Cause | Fix |
|:--|:--|:--|
| `cdp_port_closed` | App was not launched with the flag. | Restart the app with `--remote-debugging-port=<port>`. |
| No matching page | Wrong port or page title filter. | Run `cdp-detect` and inspect available pages. |
| Selector not found | DOM changed or target is inside Shadow DOM/iframe. | Try `cdp-deep-find` or a broader selector. |
| CDP action works but UI does not change | App needs input/change events. | Prefer `cdp-smart-type` or dispatch events in `cdp-eval`. |
