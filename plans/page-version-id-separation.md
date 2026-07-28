# PageVersionID separation

## Decision

`PageVersionID` identifies one row in `page_versions`. It is distinct from `PageID`, `SourceVersionID`, `SourceMarkdownVersionID`, and a blob hash.

The type is a `RawRepresentable`, `Codable`, `Sendable`, and `Comparable` wrapper. Its `rawValue` remains the existing ULID string at SQLite, CLI, JSON, and display boundaries.

`WorkspaceRef` uses `PageVersionID` only when a `page_versions` row exists. `WorkspaceConflict` uses a tagged target: `.pageVersion(PageVersionID)` for an existing version or `.stagedBlob(String)` for a created page that has not been minted. A created workspace page therefore returns `nil` from `workspaceWritePage`. Its staged `blob_hash` is never a `PageVersionID`.

Shared provenance uses `ProvenanceEntry.VersionID.page(PageVersionID)` or `.source(SourceVersionID)`. The display model exposes `rawValue` only when it copies or displays the identifier.

## Migration seams

- `Sources/WikiFSTypes/PageVersionID.swift` defines the nominal ID.
- `WikiStore`, `GRDBWikiStore`, `WikiStoreModel`, page history, CAS, revert, restore, and workspace APIs use the type internally.
- `PageVersionCompareSheet` uses typed state and cache keys.
- `PageCommand` parses CLI version strings at the command boundary and converts them immediately.
- SQLite and JSON contracts use `.rawValue` only at the boundary.

## Verification

`swift build --build-tests` passes after this migration. Focused tests cover raw-value Codable compatibility and the nil result for blob-only created-page workspace staging.

No SQLite schema migration is required. Existing IDs and external text formats remain unchanged.
