// Re-export `WikiFSTypes` so every link-cluster file (and every consumer of
// `WikiFSLinks`) sees `PageID`/`ULID`/`ParsedLink`/`ResourceKind`/`EmbedTarget`
// without per-file imports. The link cluster is pure logic whose only external
// types are these foundational ones (module restructuring Phase 1, #532).
@_exported import WikiFSTypes
