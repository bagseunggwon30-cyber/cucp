<div align="center">

# 🖥️ CUCP — Computer Use Control Plane

**Let any AI agent operate your Windows desktop — safely, precisely, and with receipts.**

A single control plane that lets AI agents (Codex · Claude · Kiro · any LLM)
drive Windows apps through an **Observe → Think → Act → Verify** loop.
Instead of guessing pixel coordinates, CUCP grounds actions in the
**UIA accessibility tree, the DOM, OCR, and label matching** — and every live
action must pass an **explicit safety gate** before it runs.

[![Version](https://img.shields.io/badge/version-v2.4.1-blue.svg)](https://github.com/bagseunggwon30-cyber/Computer-Use-Control-Plane/releases)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D4.svg?logo=windows)](https://learn.microsoft.com/windows/)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg?logo=powershell)](https://learn.microsoft.com/powershell/)
[![Tests](https://img.shields.io/badge/Pester-190%2F190-brightgreen.svg)](#-verification)
[![Macros](https://img.shields.io/badge/macros-109-success.svg)](references/command-reference.md)

[Install](#-install-30s) · [First run](#-first-run-1-min) · [Macros](#-core-macros) · [Safety](#-safety--security) · [Use cases](#-use-cases) · [Docs](#-documentation)

</div>

---

## TL;DR

```powershell
git clone https://github.com/bagseunggwon30-cyber/Computer-Use-Control-Plane.git cucp
cd cucp
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

cucp macro windows        # list open windows (read-only)
```

- **One entry point** `cucp` — any AI agent drives the desktop through this single command
- **109 macros** — observe / actuate / verify / CDP / OCR / UIA / recovery / PLC tooling
- **Safety first** — every live action requires `-AllowLiveControl` + hit-test guard + sensitive-action blocking
- **Verified** — Pester 190/190, zero `Invoke-Expression` (no code-eval surface)

---

## ⚡ Install (30s)

```powershell
# 1. Clone
git clone https://github.com/bagseunggwon30-cyber/Computer-Use-Control-Plane.git cucp
cd cucp

# 2. One-click install (no admin / UAC required)
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

What `install.ps1` does:
- Checks for PowerShell 5.1+ on Windows
- Registers the `cucp` command on your PATH (user-scope shim, no UAC)
- Verifies the install with `health-quick`

> Prefer not to install? Just run `scripts\cucp.ps1` directly.
> To uninstall, delete `%LOCALAPPDATA%\Microsoft\WindowsApps\cucp.cmd` — that's it.

---

## 🚀 First run (1 min)

```powershell
# Observe — list open windows (read-only, safe)
cucp macro windows

# Observe — score 'Save' label candidates with reasoning
cucp macro find-label --label "Save" --explain

# Version — unified skill / cli / helper-server report
cucp version

# Actuate — a real click (LIVE: requires -AllowLiveControl)
cucp -AllowLiveControl macro smart-click --label "Save" --match "Notepad"
```

Read-only macros run with no gate. Macros that actually click or type **only run
when you add `-AllowLiveControl`**. That is CUCP's first safety rule.

---

## 🤔 Why CUCP

Most computer-use tools **look at a screenshot and guess coordinates** to click.
Small buttons, dense grids, or a window that moves — and they miss.

CUCP combines **four perception stacks** to minimize coordinate guessing:

```
Win32 API        UIA               OCR                    Chrome DevTools Protocol
   │              │                 │                          │
 window enum   accessibility     ko/en/ja/zh              Electron / Chromium apps
 & hit-test    tree + patterns   text recognition         (Kiro / VS Code / Slack / Chrome)
```

- **Click by label** — find the "Save" button by its name/role, not a coordinate
- **UIA Pattern.Invoke** — trigger controls through the accessibility API without moving the mouse
- **CDP / DOM** — for Electron apps, reach into the DOM directly (through Shadow DOM / iframes)
- **Hit-test guard** — before any click, confirm the coordinate really lands on the intended window

And every live action passes a layered safety gate ([below](#-safety--security)).

### What are UIA and CDP?

- **UIA (UI Automation)** — Windows' built-in accessibility layer (the same one screen
  readers use). It exposes every button, menu, and field by **name and role**, so CUCP
  can act on "the button named Save" instead of pixel `x=820, y=440`. Used for standard
  Win32 apps (Notepad, XG5000, etc.).
- **CDP (Chrome DevTools Protocol)** — the control channel for Chromium-based apps
  (Kiro, VS Code, Slack, Discord, Chrome). These apps are web pages inside, so CUCP
  reaches the **DOM element** directly — independent of screen coordinates.

---

## ✨ Features

| Area | Capability |
|:--|:--|
| 👁️ **Observe** | window enum, foreground extraction, UIA tree, OCR (ko/en/ja/zh) |
| 🖱️ **Actuate** | UIA Pattern.Invoke, Win32 SendInput, OCR+UIA fusion, IME-safe paste |
| ✅ **Verify** | pixel-level screenshot diff, hit-test guard, click-and-verify, precision-validate |
| 🧠 **Learn** | smart-click history (recent lookback), anchor reuse scoring |
| 🌐 **Electron/Chrome** | CDP integration — direct DOM access, Shadow DOM / iframe traversal |
| 🚑 **Recover** | modal-detect → recovery-plan → recovery-run (UI failure recovery loop) |
| ⚡ **Speed** | daemon serve — ~31ms per call in resident mode (vs ~2s single-shot) |
| 📊 **Benchmark** | read-only benchmark (p50/p95/avg + SLO, no PII collected) |
| 🏭 **PLC tooling** | LS XG5000 / XP-Builder task-card · spec-board · ladder diagnosis |
| 🛡️ **Governance** | audit-summary, policy-check, vision token budget, multi-user isolation |

---

## 🎯 Core macros

```powershell
# ── Observe (read-only) ───────────────────────────────────────
cucp macro windows                                  # Win32 window enum (deterministic)
cucp macro find-label --label "Save" --explain      # label candidates + scoring
cucp macro ocr-find-text --text "Send"              # OCR (Windows.Media.Ocr)
cucp macro app-profile --match Chrome --auto-probe  # app automation strategy score

# ── Actuate (live, requires -AllowLiveControl) ────────────────
cucp -AllowLiveControl macro click-label --label "Save"
cucp -AllowLiveControl macro smart-click --label "Save" --match Kiro
#     └ cascade: UIA Pattern → UIA coord → icon → fusion → OCR → vision
cucp -AllowLiveControl macro fill-label --label "Name" --text "Alice" --enter
cucp -AllowLiveControl macro shortcut --keys "ctrl+s"

# ── Electron/Chrome — CDP/DOM (coordinate-free) ───────────────
# Start the app with --remote-debugging-port=9222 first (references/cdp-setup.md)
cucp macro cdp-detect
cucp macro cdp-deep-find --text "Send" --page-match Kiro   # through Shadow DOM/iframes
cucp -AllowLiveControl macro cdp-smart-click --text "Send"

# ── Recovery loop ─────────────────────────────────────────────
cucp macro modal-detect
cucp macro recovery-plan --failed-step "macro click-label --label Save"

# ── Speed: resident daemon (~31ms per call) ───────────────────
cucp macro daemon serve            # resident mode that takes JSON-line commands on stdin
```

See [`references/command-reference.md`](references/command-reference.md) for all 109 macros.

---

## 🛡️ Safety & security

Every live action must pass a layered gate before it runs:

| Gate | Behavior |
|:--|:--|
| 🔐 **AllowLiveControl** | Any actuation macro is blocked (exit 3) without `-AllowLiveControl` |
| 🎯 **Hit-test guard** | Coordinate clicks must pass `--target-match` / `--target-hwnd` window checks |
| 🔢 **Confidence floor** | Low-confidence matches (score < 60) are auto-rejected |
| 🚫 **Sensitive gate** | UAC / password / payment / credential screens are auto-refused |
| 📝 **Audit trail** | Every live action is logged to a trajectory NDJSON |
| 🧹 **Secret redaction** | PAT / sk- / AKIA / Bearer / JWT / PEM (6 patterns) masked before output |
| 🔒 **Multi-user isolation** | helper-server pipe owner-only ACL + lock owner check |

Design principles: zero `Invoke-Expression`/`iex`, array/escaped args for external
processes, bounded input lengths.

### Standard exit codes

| code | meaning |
|:-:|:--|
| `0` | ok |
| `1` | generic failure / not_found / missing input |
| `2` | partial / ambiguous / no_match (recoverable) |
| `3` | safety blocked (gate not satisfied) |
| `124` | timeout |

---

## 🏭 Use cases

- **AI-agent desktop automation** — Codex / Claude / Kiro drive Windows apps via label-based, gated actions
- **Electron app control** — operate Kiro / VS Code / Slack / Discord through the DOM via CDP
- **Repetitive GUI workflows** — form filling, file ops, settings changes with a verify loop
- **PLC engineering assist (LS XG5000 / XP-Builder)** — manage device/address/requirement context with task-card · spec-board, run first-pass ladder diagnosis (STOP-NC / self-hold / duplicate coils / SET-RST / word-as-bit), and gate-check before download/RUN. The built-in industrial safety gates are what set CUCP apart from general-purpose tools here.

---

## ✅ Verification

| Item | Result |
|:--|:--|
| Pester regression | **190 / 190** |
| contract-verify | **8 / 8** |
| AST parse | 6 / 6 OK |
| code-eval surface | `Invoke-Expression` **0** |

```powershell
# Run the regression suite yourself (Pester required)
Invoke-Pester .\tests\cucp.Tests.ps1
```

---

## 📁 Layout

```
cucp/
├── install.ps1              # one-click installer
├── README.md · CHANGELOG.md · SKILL.md
├── scripts/
│   ├── cucp.ps1                  # main wrapper (single entry point)
│   ├── cucp-native-helper.ps1    # Win32 + UIA + OCR + CDP (P/Invoke)
│   ├── cucp-helper-server.ps1    # resident helper (named-pipe IPC)
│   ├── cucp-task-card.ps1        # XG5000 task card
│   └── cucp-spec-board.ps1       # XG5000 spec / checklist board
├── references/             # detailed docs (command-reference, cdp-setup, troubleshooting ...)
├── skills/                 # XG5000 Codex skills (assistant · ladder-diagnostician)
└── tests/                  # Pester regression tests
```

---

## 🚧 Limitations (honest)

- **Windows 10/11 only** — depends on `Windows.Media.Ocr` · UIA · Win32. macOS/Linux gets an honest stub only.
- **Single-shot calls take ~2s** — PowerShell + wrapper cold start. The fast path is `daemon serve` (~31ms per call).
- **DirectX/fullscreen games, DRM-protected screens** — capture may fail.
- **Very small fonts (<8pt)** — OCR accuracy drops.
- **Cross-origin iframes** — traversal is blocked for security (only the count is reported).

---

## 🗺️ Roadmap

- Make `daemon serve` the default call path (removes the single-shot penalty)
- macOS / Linux port
- DXGI capture (games / fullscreen)
- Multi-monitor coord-anchor auto re-anchoring

Full history in [`CHANGELOG.md`](CHANGELOG.md).

---

## 📚 Documentation

| Doc | Description |
|:--|:--|
| [`CHANGELOG.md`](CHANGELOG.md) | Version history |
| [`references/command-reference.md`](references/command-reference.md) | Full macro reference |
| [`references/troubleshooting.md`](references/troubleshooting.md) | Diagnostics / recovery / selector scoring |
| [`references/cdp-setup.md`](references/cdp-setup.md) | Enabling Electron CDP |
| [`SKILL.md`](SKILL.md) | AI-agent skill registration metadata |

---

## 📜 License

All rights reserved until stated otherwise. For usage/distribution, please open an issue.

---

<div align="center">

**Made with 🖱️ + ⌨️ for AI agents that respect your desktop**

⭐ If this helped, please star the repo.

</div>
