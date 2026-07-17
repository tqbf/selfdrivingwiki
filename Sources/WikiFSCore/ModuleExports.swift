// Re-exports the shared leaf types (`PageID`, `ULID`, `ResourceKind`,
// `EmbedTarget`, `ParsedLink`) from `WikiFSTypes` and the wiki-link cluster
// from `WikiFSLinks` so that every file importing `WikiFSCore` — and every
// file *within* `WikiFSCore` — sees them without per-file `import` statements.
//
// This breaks what would otherwise be a circular `WikiFSCore ↔ WikiFSLinks`
// dependency: WikiFSLinks depends only on WikiFSTypes (the leaf), and WikiFSCore
// depends on both and re-exports them. Module restructuring Phase 1 (#532 /
// plans/module-restructure.md §5).
@_exported import WikiFSTypes
@_exported import WikiFSLinks
