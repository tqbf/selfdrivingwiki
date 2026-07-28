---
timestamp: 2026-07-22T014021Z
title: "2026-07-21 — PR #793 rebase + FileProvider/wikictl target filters (branch `linux-ci-acp`)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-21 — PR #793 rebase + FileProvider/wikictl target filters (branch `linux-ci-acp`)

## Progress


**Outcome.** Continued closing out Linux-build failures on PR #793. Three
consecutive target-filter commits; GitHub Actions stopped firing new runs
on the branch mid-session (likely a quota issue — closing/reopening the
PR and pushing empty trigger commits all failed to start a new run).

**Rebased.** A maintainer merge of `main` into the branch created commit
`d0b9c14`. Rebased `b2494e6` (wikictl filter) on top → `6e35180`.

**New filters (each in Package.swift):**
- `wikictl` (macOS CLI executable) — main.swift references
  `WikiDaemonConnection` and `DarwinNotifier.postChange`, both guarded
  `#if os(macOS)` in WikiCtlCore. The library still builds on Linux
  (symbols become unavailable / no-op), but wikictl/main.swift's
  unconditional references fail compilation.
- `WikiFSFileProvider` (File Provider extension binary) — first import
  is `import FileProvider` (the macOS-only FileProvider framework with
  `NSFileProviderExtension` / `NSFileProviderManager`).

Same pattern as `podcast-token-helper` (filtered earlier in this session)
— `swift test` builds every target in the manifest, not just test-target
deps, so macOS-only executables must be filtered out of the manifest on
Linux.

**CI status at session end.** The last fired Linux CI run was `29873085214`
(for SHA `d0b9c14` — the maintainer merge, before my wikictl and
WikiFSFileProvider filters). It failed at build time on
`WikiFSFileProvider` (the FileProvider framework import). My fix (commit
`921cc24`) addresses that, but no new Actions run has fired for the
branch since then — the Actions quota on `tqbf/selfdrivingwiki` appears
exhausted for this billing cycle (close+reopen, empty-commits, and
direct pushes all failed to trigger).

## Verification

Historical verification remains in the progress record above.
