# Plan: Make WikiFSEngine Linux-buildable (conditional ACP dep)

## Goal
Make the Linux CI job (#780) pass by making the `ACP` product from `swift-acp` a macOS-only dependency of `WikiFSEngine`, and guarding the source files that import `ACP` (and the cascading files that reference ACP-only types) with `#if os(macOS)`.

## Root cause
`swift-acp`'s `ACP` product uses `ACPProcessManager` and `os.log` — both macOS-only. `WikiFSEngine` hard-depends on both `ACP` and `ACPModel` products. `ACPModel` is portable (pure model types, no macOS imports). The `ACP` product is not.

`WikiFSCoreTests` → `WikiFSEngine` → `ACP` → breaks on Linux.

## Implementation

### 1. Package.swift: make ACP dep conditional
- `WikiFSEngine`: `ACP` product → `.when(platforms: [.macOS])`; `ACPModel` stays unconditional.
- `WikiFSCoreTests`: `WikiFSEngine` target dep → `.when(platforms: [.macOS])`; `ACPModel` stays unconditional.

### 2. Guard ACP-importing files with #if os(macOS)
Wrap ENTIRE file contents (after imports) in `#if os(macOS)` / `#endif`:
- `ACPBackend.swift` (defines: `ACPBackend`, `SessionUsage`, `ProviderEnvHint`, `ACPBackendError`, etc.)
- `ACPPermissions.swift` (defines: `PendingPermission`, `PermissionPolicy`, `ACPPermissionDelegate`, `ACPEventTranslator`, `ToolCallRendering`)
- `ACPProviderModelProbe.swift` (defines: `ACPProviderModelProbe`, `ACPProviderModelProbeError`)

### 3. Guard cascading files
Files that reference types defined in the guarded files (e.g. `ACPBackend`, `SessionUsage`, `PendingPermission`, `ACPPermissionDelegate`) must also be guarded. The cascade flows outward from the 3 ACP-importing files.

### 4. Guard test files
Check `Tests/WikiFSTests/` for references to ACP-only types; guard those.

### 5. Linux CI
The existing `linux-swift` job builds `WikiFSCoreTests` on `ubuntu-latest`. Once deps are conditional and guards are in place, it should compile and run the portable test suite.

## Acceptance criteria
- [ ] `swift build` on macOS still compiles.
- [ ] `swift test --filter WikiFSCoreTests` on macOS still passes.
- [ ] Linux CI job compiles `WikiFSCoreTests` on `ubuntu-latest`.
- [ ] Linux CI job runs the portable test suite.
- [ ] No macOS functionality is lost.
- [ ] PR links #754.

## Validation strategy
Cannot test Linux build locally (macOS only). Validation: (1) macOS build+test passes, (2) Package.swift changes correct, (3) #if guards correct. Linux CI validates the Linux path.
