# Changelog

This public changelog tracks the vendor-neutral Windows GUI automation surface.
Older internal workflow notes are intentionally not carried forward here.

## Unreleased

### Changed

- Polished the public repository presentation around CUCP as a generic Windows
  computer-use control plane.
- Replaced long internal-style reference material with concise public README,
  skill, command reference, CDP setup, and troubleshooting docs.
- Removed hard-coded local maintainer paths from public-facing documentation.
- Removed stale public claims that depended on an unpublished release tag.

## v2.4.1 - Generic GUI Control Plane Baseline

### Changed

- Scoped the repository to Windows GUI automation primitives: Win32, UIA, OCR,
  CDP, workflow planning, recovery, diagnostics, and guarded live control.
- Kept the CLI wrapper surface centered on the single `cucp` entry point.
- Kept live-control operations behind explicit `-AllowLiveControl` approval.

### Verification

- Pester smoke and regression test suites are available under `tests/`.
- Core PowerShell entry points can be parsed with the AST parser check shown in
  the README.

## Notes

- This repository is no longer positioned around any single private engineering
  workflow or vendor toolchain.
- Historical commits may still exist in Git history. The current public surface
  is the files on `main`.
