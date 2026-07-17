// Re-export `WikiFSTypes` (PageID/ULID/DebugLog/etc.) so every search-cluster
// file — and every consumer of `WikiFSSearch` — sees the foundational types
// without per-file imports. The search cluster's only external types are
// these (module restructuring Phase 3, #532).
@_exported import WikiFSTypes
