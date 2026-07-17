// Re-export `WikiFSTypes` (PageID/ULID/ParsedLink/DebugLog/etc.) and
// `WikiFSLinks` (WikiLinkFixer/WikiLinkSpan/etc.) so every markdown-cluster
// file — and every consumer of `WikiFSMarkdown` — sees the foundational and
// link types without per-file imports. The markdown cluster's only external
// types are these (module restructuring Phase 2, #532).
@_exported import WikiFSTypes
@_exported import WikiFSLinks
