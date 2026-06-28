# File Provider Schema Migration & Cache Warming

**Status:** Implemented on `feature/fileprovider-schema-migration`. 1149 tests pass.
**Depends on:** `main` (ships ahead of the share feature on `feature/more-share`).
**Parent design:** this plan covers the File Provider infrastructure the share feature needs — schema migration for container renames, cache warming for directory enumeration, and the shared `source-by-name:` identifier prefix.

## Problem

Three related defects blocked the share feature for sources:

1. **Stale container names across upgrades.** The `files` container was renamed to `sources`, but the File Provider daemon (`fileproviderd`) caches the extension binary and the domain's item hierarchy indefinitely. A user upgrading from an older build would see `files/` in the mount while the code expected `sources/` — every path-based access to `sources/by-name/` failed with "no such file."

2. **Cold directory cache.** The daemon enumerates containers lazily on first access. `pages/by-title/` happened to be warm because opening pages triggers enumeration, but `sources/by-name/` was cold. When `NSSharingServicePicker` tried to resolve a source's mount path, the daemon had no cached children for `sources-by-name` and the share sheet saw an empty service list.

3. **Cross-module identifier drift.** The `source-by-name:` leaf identifier prefix was hardcoded as `"source-by-name:"` in `Projection.swift` (the extension) but had no shared constant on the app side. A typo or rename in one module would silently break mount-path resolution.

## Decisions

1. **Schema version in UserDefaults, auto-migration on launch.** Bump `currentSchemaVersion` whenever container names or required hierarchy elements change. On launch, if the stored version is stale, every registered domain is torn down and re-registered. Users never see a broken mount — the daemon picks up the new extension on the next domain registration.

2. **Top-down cache warming after domain activation.** The daemon must enumerate a parent container before its children exist as directories. Warm by listing `sources/` first (forces enumeration of root → discovers `sources` → enumerates `sources` children → discovers `by-name`), then `sources/by-name/` (now the directory exists). Same for `pages/` → `pages/by-title/`.

3. **Shared `sourceByNamePrefix` constant.** Moved from a hardcoded string in `Projection.swift` to `WikiFSContainerID.sourceByNamePrefix`, imported by both the app (`FileProviderSpike.sourceMountPath(for:)`) and the extension (`Projection.Identity`). A cross-module unit test verifies the two sides produce identical identifiers.

## Schema migration (`FileProviderSpike`)

`currentSchemaVersion = 2` (v1: `files` container, v2: `sources` container).

`migrateDomainsIfNeeded(wikiIDs:)` — called once at startup in `WikiFSApp.task`, before `registerAllDomains`. Reads the stored version from `UserDefaults`; if stale, removes every wiki's domain via `NSFileProviderManager.remove(_:)`, then records the current version. Subsequent `registerDomain` calls re-add each domain with the current extension.

`needsDomainMigration` — a computed property that `registerDomain` also checks as a safety net, in case the app calls `registerDomain` directly (e.g., wiki creation) without going through the startup path.

History:
- **v2** — `files` container renamed to `sources`; `source-by-name:` prefix shared via `WikiFSContainerID`
- **v1** — initial schema

## Cache warming (`FileProviderSpike.warmCaches(root:)`)

Called from `resolvePath` after the mount URL is resolved. Lists directories top-down with `FileManager.default.contentsOfDirectory`:

1. List `sources/` — daemon enumerates the `sources` container, discovers `by-id` and `by-name` children
2. List `sources/by-name/` — daemon enumerates all source file nodes, caches filenames
3. Same for `pages/` → `pages/by-title/`

Errors are logged but never surfaced to the user — the cache warming is best-effort; the share button's `resourceValues(forKeys:)` call is the safety net for individual file access.

## Source mount path (`FileProviderSpike.sourceMountPath(for:)`)

Constructs the user-visible POSIX path for a source in the `sources/by-name/` view:

```swift
func sourceMountPath(for source: SourceSummary) -> String? {
    guard let root = path else { return nil }
    let humanName = source.displayName ?? source.filename
    let leaf = FilenameEscaping.byNameSourceFilename(
        filename: humanName, ext: source.ext, sourceID: source.id.rawValue)
    return "\(root)/sources/by-name/\(leaf)"
}
```

Returns `nil` only when the mount root hasn't been resolved. The path is constructed synchronously — the daemon materializes the file on first access. Mirrors the pattern used for `pages/by-title/` in `PageDetailView.pageMountPath`.

## Shared identifier prefix (`WikiFSContainerID`)

```swift
public static let sourceByNamePrefix = "source-by-name:"
public static func sourceByName(_ ulid: String) -> String {
    sourceByNamePrefix + ulid
}
```

`Projection.Identity.sourceByNamePrefix` now references `WikiFSContainerID.sourceByNamePrefix` instead of a hardcoded literal. Both sides of the contract (app path construction and extension item identification) use the same constant.

## Tests

- **`FileProviderSpikeMountPathTests`** (5 cases) — `sourceMountPath` returns nil when root is unset; uses filename when no display name; prefers display name over filename; handles empty extension; strips embedded extension from display name before re-appending the canonical `ext`.

- **`ProjectionTests` cross-module prefix checks** (2 cases) — `sourceByNamePrefix` matches across app and extension; `sourceByIDPrefix` matches across app and extension.

## What the share feature expects

The `feature/more-share` branch (which lands after this one) assumes:

- `fileProvider.sourceMountPath(for:)` exists and returns a valid mount path for any source
- The `sources/by-name/` directory hierarchy is warm by the time the user clicks Share
- Schema migration handles the `files` → `sources` rename transparently
