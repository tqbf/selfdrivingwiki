# Plan: Fix FileProvider EXC_BREAKPOINT crash (#756)

## Root cause (CONFIRMED)
`Sources/WikiFS/Window/FileProviderFacade.swift:623`:
```swift
let url = try await manager.getUserVisibleURL(for: itemIdentifier)
```
`NSFileProviderManager.getUserVisibleURL(for:)` is imported as `async throws -> URL`
(non-optional), bridged from an Obj-C completion handler `(NSURL?, NSError?)`. Apple's
docs say the URL is returned "or nil if an error occurs" — nil is a **documented, valid**
return. The async bridging calls `URL._unconditionallyBridgeFromObjectiveC(_:)`, which
traps (`brk 1`, EXC_BREAKPOINT/SIGTRAP) when the NSURL is nil. This is an **uncatchable
Swift runtime trap** — it fires before the `try`/`throws` machinery can intervene. The
5-second timeout and `CheckedContinuation` wrapper give no protection.

**The race (confirmed):** At launch, two fire-and-forget Tasks compete with no ordering:
Task A registers domains (`WikiFSApp.swift:334`, `registerAllDomains`); Task B resolves
the mount path (`RootScene.swift:196`, `activate` → `resolvePath`). `resolvePath` does
NOT gate on `isDomainRegistered` — its only gate is `NSFileProviderManager(for: domain)`,
which returns a manager for any identifier whether registered or not. So
`getUserVisibleURL(for: .rootContainer)` can be asked of a domain Task A hasn't finished
mounting yet → nil URL → trap.

**macOS 26 specificity:** The trap is latent on macOS 15 too (no `#available` guards; the
contract permits nil on all versions). But macOS Tahoe's well-documented `fileproviderd`
instability makes the daemon return nil URLs far more often during the launch window,
which is why it manifests on Tahoe. Not Tahoe-only; Tahoe makes it reproducible.

## Fix

### Primary: switch to the completion-handler overload (the single chokepoint)
`Sources/WikiFS/Window/FileProviderFacade.swift`, `userVisibleURL(manager:itemIdentifier:timeout:)`
(L614-636). Replace L623's `try await manager.getUserVisibleURL(for:)` with the
completion-handler form that returns `URL?` directly:

```swift
// BEFORE (L623 — traps on nil):
let url = try await manager.getUserVisibleURL(for: itemIdentifier)

// AFTER — use the completion-handler overload, branch on nil:
manager.getUserVisibleURL(for: itemIdentifier) { url, error in
    if let url {
        resolution.succeed(url)
    } else {
        resolution.fail(error ?? MountResolutionError.urlNil)
    }
}
```
Add a `MountResolutionError.urlNil` case with a descriptive `errorDescription` (e.g.
"File Provider returned no URL for this item — the domain may not be fully mounted yet").
Do NOT use bare `try?` — surface via `DebugLog.reader` + the `MountURLResolution.fail`
path. This is the ONLY `getUserVisibleURL` call site in the codebase (grep-confirmed),
so it makes ALL callers nil-safe with no caller-side changes: `resolvePath`, `openSource`,
`resolvePageByTitleURL`, `resolveChatByNameURL`, `resolveSourceByNameURL`.

### Secondary: gate resolvePath on domain registration
`Sources/WikiFS/Window/FileProviderFacade.swift`, `resolvePath(id:displayName:)` (~L256).
Before calling `userVisibleURL`, add `guard await isDomainRegistered(id: id)` — reusing
the existing `isDomainRegistered(id:)` (L190-204). If the domain isn't registered yet,
either wait (poll with a short delay) or fail gracefully with a `DebugLog.reader` line
and a user-facing "wiki is still mounting" message. This kills the race at its source.

### Rejected (do NOT do)
- `#available(macOS 26, *)` branching — nil is contractually valid on both macOS 15 and 26;
  version-gating would leave macOS 15 latent.
- `FileProviderExtension.fetchContents` (`:40`) as an "alternative API" — it's the extension's
  server-side byte-fetch callback, correctly typed `(URL?, NSFileProviderItem?, Error?)`, NOT a
  client-side path-resolution API the app can call.

## Files
- `Sources/WikiFS/Window/FileProviderFacade.swift` — L614-636 (the chokepoint: switch to
  completion-handler overload + add `MountResolutionError.urlNil`); L256 (gate `resolvePath`
  on `isDomainRegistered`).

## Acceptance
- The app does NOT `EXC_BREAKPOINT`/`SIGTRAP` on macOS 26.5.2 during launch / mount
  resolution / opening a page/source/chat.
- `getUserVisibleURL` nil → a recoverable error (visible in `DebugLog.reader` + a
  user-facing message), NOT a trap.
- `resolvePath` only calls `userVisibleURL` after the domain is confirmed registered.
- No bare `try?`; no `print`; route through `DebugLog`.
- `make build && make test` green.
- Manual validation in the running app (`make run`): cold launch on macOS 26 → no crash;
  open a page → opens correctly; the mount path resolves.

## Build/test
`make build && make test`. Push the branch, open a PR with `Closes #756`. **Do NOT merge
to main.** Scratch in `tmp/` inside your own worktree.
