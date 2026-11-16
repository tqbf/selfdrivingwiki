#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore
import WikiFSTypes

// MARK: - Deliberately removed requirements (typed-rejection witnesses)
//
// SLICE-2 LEDGER — Phase 2d slice 2 of plans/daemon-only-access.md.
//
// Slice 2 wired every remaining manifest-rpc operation (the four family
// files beside the core: small / list / blob / event-producer surfaces +
// the client-side mirror mappings). What remains HERE is exactly the 15
// `WikiStore` requirements deliberately absent from the remote surface
// (tmp/store-ops-manifest.md "removed"): no production consumer reaches
// them after the daemon-only cutover, so each rejects typed —
// `RemoteStoreClientError.unsupportedRemote` carrying the operation name —
// instead of inheriting a protocol-extension default (the sequential
// defaults are local-composition semantics a remote store must never run)
// and instead of failing silently.
//
// Signature fidelity: every declaration below is extracted verbatim from
// the `WikiStore` protocol declaration, so a protocol edit that does not
// update this file is a compile error (the witness stops matching the
// requirement). The 2f exhaustiveness test
// (`RemoteStoreSurfaceExhaustivenessTests`) re-parses the protocol and pins
// the full three-way wired/removed partition; this file is the removed
// surface's honest witness.
//
// Counts this slice: 15 removed witnesses (the manifest's removed list;
// 151 rpc wired + 3 client properties live in the core + family files).

extension RemoteWikiStore {

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func deletePage(id: PageID) async throws {
        throw Self.unsupportedRemote("deletePage")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func pageLinkingPages(to pageID: PageID) async throws -> [PageID] {
        throw Self.unsupportedRemote("pageLinkingPages")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func sourceLinkingPages(to sourceID: SourceID) async throws -> [PageID] {
        throw Self.unsupportedRemote("sourceLinkingPages")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func listRendererSourcePreferences() async throws -> [RendererSourcePreference] {
        throw Self.unsupportedRemote("listRendererSourcePreferences")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func rendererSettingsJournalRecords() async throws -> [PersistedWikiStoreChangeRecord] {
        throw Self.unsupportedRemote("rendererSettingsJournalRecords")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func deleteSource(id: SourceID) async throws {
        throw Self.unsupportedRemote("deleteSource")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func sourceProvenanceBlockers(sourceID: SourceID) async throws -> [ProvenanceDeletionBlocker] {
        throw Self.unsupportedRemote("sourceProvenanceBlockers")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func setAcquisitionProvenance( sourceID: SourceID, externalItemKey: String?, externalItemTitle: String?, displayName: String? ) async throws {
        throw Self.unsupportedRemote("setAcquisitionProvenance")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func revertProcessedMarkdown(sourceID: SourceID, to versionID: SourceMarkdownVersionID) async throws -> SourceMarkdownVersion {
        throw Self.unsupportedRemote("revertProcessedMarkdown")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func sourceReferencingPageVersions(sourceID: SourceID) async throws -> [PageVersionID] {
        throw Self.unsupportedRemote("sourceReferencingPageVersions")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func extractionProvenance(markdownVersionID: SourceMarkdownVersionID) async throws -> ExtractionProvenance? {
        throw Self.unsupportedRemote("extractionProvenance")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func editPersistedChatTurn( chatID: ChatID, turnID: ChatTurnID, userText: String, contextReferences: [ChatContextReference], editedAt: Date ) async throws -> PersistedChatTurn {
        throw Self.unsupportedRemote("editPersistedChatTurn")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func removePersistedQueuedChatTurn(chatID: ChatID, turnID: ChatTurnID) async throws -> Bool {
        throw Self.unsupportedRemote("removePersistedQueuedChatTurn")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func chatTurnUsage(chatID: ChatID, turnID: ChatTurnID) async throws -> ChatTurnUsage? {
        throw Self.unsupportedRemote("chatTurnUsage")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func latestChatTurnUsage(chatID: ChatID) async throws -> ChatTurnUsage? {
        throw Self.unsupportedRemote("latestChatTurnUsage")
    }
}
#endif
