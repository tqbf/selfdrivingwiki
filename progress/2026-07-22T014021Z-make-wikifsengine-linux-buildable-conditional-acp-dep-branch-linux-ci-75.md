---
timestamp: 2026-07-22T014021Z
title: "2026-07-21 — Make WikiFSEngine Linux-buildable: conditional ACP dep (branch `linux-ci`, #754, #780)"
branch: null
status: historical
timestamp_source: git-commit
---

# 2026-07-21 — Make WikiFSEngine Linux-buildable: conditional ACP dep (branch `linux-ci`, #754, #780)

## Progress


**Outcome.** Made the `ACP` product from `swift-acp` a macOS-only dependency
of `WikiFSEngine`, and guarded the source files that import `ACP` (and the
cascading files that reference ACP-only types) with `#if os(macOS)`. This
unblocks the `linux-swift` CI job which builds `WikiFSCoreTests` on
`ubuntu-latest`.

**Root cause.** `swift-acp`'s `ACP` product uses `ACPProcessManager` and
`os.log` — both macOS-only. `WikiFSEngine` hard-depended on both `ACP` and
`ACPModel` products. `ACPModel` is portable (pure model types).

**Changes.**
- `Package.swift`: `ACP` product → `.when(platforms: [.macOS])` for
  `WikiFSEngine`. `WikiFSEngine` → `.when(platforms: [.macOS])` for
  `WikiFSCoreTests`, `WikiFSAppTests`, and `WikiFS` executable.
- `ACPModelValueTypes.swift` (new): extracted `SessionUsage`,
  `PendingPermission`, `PermissionPolicy` from `ACPBackend.swift` /
  `ACPPermissions.swift` — pure value types used by the portable queue
  system.
- Guarded 3 ACP-importing files with `#if os(macOS)`: `ACPBackend.swift`,
  `ACPPermissions.swift`, `ACPProviderModelProbe.swift`.
- Guarded 9 cascading files with `#if os(macOS)`: `AgentLauncher.swift`,
  `AgentOperationRunner.swift`, `ACPExtractionClient.swift`,
  `MessageSummarizer.swift`, `QuotaFallbackCoordinator.swift`,
  `WikiSession.swift`, `SessionManager.swift`, `ExtractionCoordinator.swift`,
  `SpawnModelGuard.swift`.
- `PermissionResolving.swift`: guarded the `ACPBackend` conformance extension.
- `AgentBackendFactory.swift`: guarded `makeBackend`'s `ACPBackend` construction
  (fatalError on Linux — only called from macOS code paths).
- `LinuxStubBackend.swift` (new): no-op `AgentBackend` for Linux type
  resolution.

**Validation.** `swift build` passes on macOS. `swift test --filter
WikiFSCoreTests`: 2194 tests in 163 suites, all green. Linux path validated
by CI.

## Verification

Historical verification remains in the progress record above.
