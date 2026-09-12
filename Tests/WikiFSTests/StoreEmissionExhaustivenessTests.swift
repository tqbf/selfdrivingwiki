import Foundation
import Testing

/// Classifies the Phase 3 public page-provenance writers. Any future writer in
/// this group must enter the post-commit event seam rather than emit directly.
struct StoreEmissionExhaustivenessTests {
    @Test func pageProvenancePublicMutatorsRouteThroughMutate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFSCore/Store/GRDBWikiStore.swift"),
            encoding: .utf8)

        for signature in [
            "public func createPage(",
            "public func updatePage(",
            "public func appendPageVersion(",
            "public func workspaceWritePage(",
            "public func workspaceRefresh(",
            "public func workspaceResolveConflict(",
            "public func restorePage(",
            "public func revertPage(",
            "public func appendDerivedMarkdown(",
        ] {
            guard let start = source.range(of: signature)?.lowerBound else {
                Issue.record("missing classified public mutator \(signature)")
                continue
            }
            let afterSignature = source[start...]
            let end = afterSignature.dropFirst().range(of: "\n    public func ")?.lowerBound
                ?? source.endIndex
            let implementation = source[start..<end]
            #expect(implementation.contains("mutate("), "\(signature) must use mutate")
        }
    }

    /// The protected deletion (issue #219 hardening) is the one batch mutator:
    /// impact recheck → provenance gate → rewrites → bookmark cleanup → target
    /// deletion, all in ONE `mutateBatch` transaction with post-commit events.
    /// The single-target `deletePage` / `deleteSource` methods are compatibility
    /// forwarders into it — they must NOT open their own `mutate` transaction
    /// (that would split the write and bypass the mandatory bookmark cleanup).
    @Test func protectedDeletionRoutesThroughBatchMutationAndForwardersForward() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFSCore/Store/GRDBWikiStore.swift"),
            encoding: .utf8)

        // The batch mutator must route through mutateBatch.
        let deleteResourcesStart = try #require(
            source.range(of: "public func deleteResources(")?.lowerBound)
        let deleteResourcesTail = source[deleteResourcesStart...]
        let deleteResourcesEnd = deleteResourcesTail.dropFirst()
            .range(of: "\n    public func ")?.lowerBound ?? source.endIndex
        #expect(
            source[deleteResourcesStart..<deleteResourcesEnd].contains("mutateBatch("),
            "deleteResources must use mutateBatch (one transaction, post-commit events)")

        // The compatibility forwarders must forward, not write directly.
        for signature in [
            "public func deletePage(",
            "public func deleteSource(",
        ] {
            let start = try #require(source.range(of: signature)?.lowerBound)
            let tail = source[start...]
            let end = tail.dropFirst().range(of: "\n    public func ")?.lowerBound
                ?? source.endIndex
            let implementation = source[start..<end]
            #expect(
                implementation.contains("deleteResources("),
                "\(signature) must forward to the protected deleteResources contract")
        }
    }

    @Test func MIMERepairRoutesThroughBatchMutation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFSCore/Store/GRDBWikiStore.swift"),
            encoding: .utf8)
        let signature = "public func repairMIME("
        let start = try #require(source.range(of: signature)?.lowerBound)
        let tail = source[start...]
        let end = tail.dropFirst().range(of: "\n    public func ")?.lowerBound ?? source.endIndex
        #expect(source[start..<end].contains("mutateBatch("))
    }

    @Test func chatSelectionPublicMutatorRoutesThroughMutate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFSCore/Store/GRDBWikiStore.swift"),
            encoding: .utf8)
        let signature = "public func updateChatModelAndThinkingSelection("
        let start = try #require(source.range(of: signature)?.lowerBound)
        let tail = source[start...]
        let end = tail.dropFirst().range(of: "\n    public func ")?.lowerBound ?? source.endIndex
        #expect(source[start..<end].contains("mutate("))
    }

    /// The first-send title write MUST route through `mutate(event:_:)`: the
    /// conditional `false` result emits nothing, `true` emits exactly one
    /// `.chat .updated`, and a missing chat throws inside the savepoint so the
    /// rollback also emits nothing.
    @Test func chatTitleIfEmptyPublicMutatorRoutesThroughMutate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/WikiFSCore/Store/GRDBWikiStore.swift"),
            encoding: .utf8)
        for signature in [
            "public func setChatTitleIfEmpty(",
            "public func setChatTitleIf(",
        ] {
            let start = try #require(source.range(of: signature)?.lowerBound)
            let tail = source[start...]
            let end = tail.dropFirst().range(of: "\n    public func ")?.lowerBound ?? source.endIndex
            let implementation = source[start..<end]
            #expect(
                implementation.contains("mutate(") || implementation.contains("setChatTitleIf("),
                "\(signature) must route through mutate (directly or via the CAS mutator)")
        }
    }
}
