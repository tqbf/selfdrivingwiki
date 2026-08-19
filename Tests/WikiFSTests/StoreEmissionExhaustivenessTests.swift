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
            "public func deleteSource(",
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
}
