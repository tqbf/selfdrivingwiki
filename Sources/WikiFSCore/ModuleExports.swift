// Re-exports the shared leaf types (`PageID`, `ULID`, `ResourceKind`,
// `EmbedTarget`, `ParsedLink`, `DebugLog`) from `WikiFSTypes`, the wiki-link
// cluster from `WikiFSLinks`, the markdown/content-transformation cluster from
// `WikiFSMarkdown`, and the search/embedding cluster from `WikiFSSearch` so
// that every file importing `WikiFSCore` — and every file *within* `WikiFSCore`
// — sees them without per-file `import` statements.
//
// This breaks what would otherwise be circular dependencies: each extracted
// module depends only on its own predecessors (WikiFSTypes → WikiFSLinks →
// WikiFSMarkdown; WikiFSTypes → WikiFSSearch), and WikiFSCore depends on all
// of them and re-exports. Module restructuring Phases 1–3 (#532 /
// plans/module-restructure.md §5).
@_exported import WikiFSTypes
@_exported import WikiFSLinks
@_exported import WikiFSMarkdown
@_exported import WikiFSSearch
