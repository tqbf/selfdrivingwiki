import Foundation

/// Optional content-source hook for forcing an on-disk Tantivy rebuild even
/// when the index is non-empty. Phase 2 uses this after destructive
/// chat-subsystem rebuilds so stale chat documents do not survive in the
/// sidecar index.
public protocol TantivyRebuildMarkerSource: Sendable {
    func requiresTantivyRebuild() async -> Bool
    func clearTantivyRebuildRequirement() async
}
