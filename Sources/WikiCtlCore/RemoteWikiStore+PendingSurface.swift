#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiFSCore
import WikiFSTypes

// MARK: - Slice-2 pending surface (typed-rejection witnesses)
//
// SLICE-2 LEDGER — Phase 2d slice 1 of plans/daemon-only-access.md.
//
// Every requirement below is a `WikiStore` operation the daemon's store
// family will serve, but this slice wires only the representative subset
// named in `RemoteWikiStore.wiredOperations` (the core file). Each member
// here rejects typed — `RemoteStoreClientError.unsupportedRemote` carrying
// the operation name — instead of inheriting a protocol-extension default
// (the sequential defaults are local-composition semantics a remote store
// must never run) and instead of failing silently.
//
// Signature fidelity: every declaration below is extracted verbatim from
// the `WikiStore` protocol declaration, so a protocol edit that does not
// update this file is a compile error (the witness stops matching the
// requirement). The 2f exhaustiveness test
// (`RemoteStoreSurfaceExhaustivenessTests`) later re-parses the protocol
// and pins the full three-way rpc/client/removed partition; this file is
// the interim honest surface.
//
// Counts this slice: 159 witnesses over 153 distinct operations
// (138 manifest-rpc pending, 15 deliberately removed;
// 13 rpc wired + 3 client properties live in the core file).

extension RemoteWikiStore {

    // SLICE-2 LEDGER: pending
    public func createPage(title: String) async throws -> WikiPage {
        throw Self.unsupportedRemote("createPage")
    }

    // SLICE-2 LEDGER: pending
    public func createPage( title: String, body: String, createdBy: String?, provenance: [PageVersionSourceInput] ) async throws -> WikiPage {
        throw Self.unsupportedRemote("createPage")
    }

    // SLICE-2 LEDGER: pending
    public func createPage(title: String, createdBy: String?, provenance: [PageVersionSourceInput]) async throws -> WikiPage {
        throw Self.unsupportedRemote("createPage")
    }

    // SLICE-2 LEDGER: pending
    public func updatePage(id: PageID, title: String, body: String, lastEditedBy: String?, provenance: [PageVersionSourceInput]) async throws {
        throw Self.unsupportedRemote("updatePage")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func deletePage(id: PageID) async throws {
        throw Self.unsupportedRemote("deletePage")
    }

    // SLICE-2 LEDGER: pending
    public func resolveSourceByName(_ displayName: String) async throws -> SourceID? {
        throw Self.unsupportedRemote("resolveSourceByName")
    }

    // SLICE-2 LEDGER: pending
    public func replaceLinks(from pageID: PageID, parsedLinks: [ParsedLink]) async throws {
        throw Self.unsupportedRemote("replaceLinks")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func pageLinkingPages(to pageID: PageID) async throws -> [PageID] {
        throw Self.unsupportedRemote("pageLinkingPages")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func sourceLinkingPages(to sourceID: SourceID) async throws -> [PageID] {
        throw Self.unsupportedRemote("sourceLinkingPages")
    }

    // SLICE-2 LEDGER: pending
    public func addBytelessSource( filename: String, mimeType: String?, provenance: SourceProvenance, role: SourceRole ) async throws -> SourceSummary {
        throw Self.unsupportedRemote("addBytelessSource")
    }

    // SLICE-2 LEDGER: pending
    public func listSources() async throws -> [SourceSummary] {
        throw Self.unsupportedRemote("listSources")
    }

    // SLICE-2 LEDGER: pending
    public func getWikiStrategyState() async throws -> WikiStrategyState {
        throw Self.unsupportedRemote("getWikiStrategyState")
    }

    // SLICE-2 LEDGER: pending
    public func getWikiStrategy() async throws -> WikiStrategy? {
        throw Self.unsupportedRemote("getWikiStrategy")
    }

    // SLICE-2 LEDGER: pending
    public func wikiStrategyRevision() async throws -> WikiStrategyRevision? {
        throw Self.unsupportedRemote("wikiStrategyRevision")
    }

    // SLICE-2 LEDGER: pending
    public func saveWikiStrategy( name: String, instructions: String, expectedRevision: WikiStrategyRevision? ) async throws -> WikiStrategySaveOutcome {
        throw Self.unsupportedRemote("saveWikiStrategy")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func listRendererSourcePreferences() async throws -> [RendererSourcePreference] {
        throw Self.unsupportedRemote("listRendererSourcePreferences")
    }

    // SLICE-2 LEDGER: pending
    public func rendererSourcePreference(sourceID: SourceID) async throws -> RendererSourcePreference? {
        throw Self.unsupportedRemote("rendererSourcePreference")
    }

    // SLICE-2 LEDGER: pending
    public func setRendererSourcePreference(sourceID: SourceID, preference: RendererPreferenceReference) async throws {
        throw Self.unsupportedRemote("setRendererSourcePreference")
    }

    // SLICE-2 LEDGER: pending
    public func rendererSourcePresentation(sourceID: SourceID) async throws -> RendererSourcePresentation? {
        throw Self.unsupportedRemote("rendererSourcePresentation")
    }

    // SLICE-2 LEDGER: pending
    public func setRendererSourcePresentation(sourceID: SourceID, presentation: RendererSourcePresentationMode) async throws {
        throw Self.unsupportedRemote("setRendererSourcePresentation")
    }

    // SLICE-2 LEDGER: pending
    public func removeRendererSourcePresentation(sourceID: SourceID) async throws {
        throw Self.unsupportedRemote("removeRendererSourcePresentation")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func rendererSettingsJournalRecords() async throws -> [PersistedWikiStoreChangeRecord] {
        throw Self.unsupportedRemote("rendererSettingsJournalRecords")
    }

    // SLICE-2 LEDGER: pending
    public func sourceContent(id: SourceID) async throws -> Data {
        throw Self.unsupportedRemote("sourceContent")
    }

    // SLICE-2 LEDGER: pending
    public func sourceContent(versionID: SourceVersionID) async throws -> Data {
        throw Self.unsupportedRemote("sourceContent")
    }

    // SLICE-2 LEDGER: pending
    public func rendererInputByteCount(_ input: RendererBridgeInput) async throws -> Int? {
        throw Self.unsupportedRemote("rendererInputByteCount")
    }

    // SLICE-2 LEDGER: pending
    public func sourceVersion(id: SourceVersionID) async throws -> SourceVersion? {
        throw Self.unsupportedRemote("sourceVersion")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func deleteSource(id: SourceID) async throws {
        throw Self.unsupportedRemote("deleteSource")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func sourceProvenanceBlockers(sourceID: SourceID) async throws -> [ProvenanceDeletionBlocker] {
        throw Self.unsupportedRemote("sourceProvenanceBlockers")
    }

    // SLICE-2 LEDGER: pending
    public func sourceOrigin(sourceID: SourceID) async throws -> SourceOrigin? {
        throw Self.unsupportedRemote("sourceOrigin")
    }

    // SLICE-2 LEDGER: pending
    public func sourceMatchingURLIdentity(_ identity: String) async throws -> SourceSummary? {
        throw Self.unsupportedRemote("sourceMatchingURLIdentity")
    }

    // SLICE-2 LEDGER: pending
    public func sourceEditHistory(sourceID: SourceID) async throws -> [SourceOrigin] {
        throw Self.unsupportedRemote("sourceEditHistory")
    }

    // SLICE-2 LEDGER: pending
    public func activeContentVersion(sourceID: SourceID) async throws -> SourceVersion? {
        throw Self.unsupportedRemote("activeContentVersion")
    }

    // SLICE-2 LEDGER: pending
    public func initialContentVersion(sourceID: SourceID) async throws -> SourceVersion? {
        throw Self.unsupportedRemote("initialContentVersion")
    }

    // SLICE-2 LEDGER: pending
    public func renameSource(id: SourceID, to newDisplayName: String) async throws {
        throw Self.unsupportedRemote("renameSource")
    }

    // SLICE-2 LEDGER: pending
    public func setSourceDisplayName(id: SourceID, displayName: String) async throws {
        throw Self.unsupportedRemote("setSourceDisplayName")
    }

    // SLICE-2 LEDGER: pending
    public func markSourceIngested(id: SourceID) async throws {
        throw Self.unsupportedRemote("markSourceIngested")
    }

    // SLICE-2 LEDGER: pending
    public func markedSourceIDs() async throws -> Set<String> {
        throw Self.unsupportedRemote("markedSourceIDs")
    }

    // SLICE-2 LEDGER: pending
    public func appendContentVersion( sourceID: SourceID, data: Data, detectionHints: ContentTypeDetectionHints, provenance: SourceProvenance? ) async throws -> SourceVersion {
        throw Self.unsupportedRemote("appendContentVersion")
    }

    // SLICE-2 LEDGER: pending
    public func attachAcquiredBytes( sourceID: SourceID, bytes: Data, mimeType: String, originalFilename: String?, externalItemKey: String?, externalItemTitle: String?, producer: ExtractionInstalledPackageProducer? ) async throws -> SourceVersion {
        throw Self.unsupportedRemote("attachAcquiredBytes")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func setAcquisitionProvenance( sourceID: SourceID, externalItemKey: String?, externalItemTitle: String?, displayName: String? ) async throws {
        throw Self.unsupportedRemote("setAcquisitionProvenance")
    }

    // SLICE-2 LEDGER: pending
    public func appendFetchMarkdown( sourceID: SourceID, content: String, package: ExtractionInstalledPackageProducer, externalItemKey: String?, externalItemTitle: String?, sourceVersionID: SourceVersionID ) async throws -> SourceMarkdownVersion {
        throw Self.unsupportedRemote("appendFetchMarkdown")
    }

    // SLICE-2 LEDGER: pending
    public func markFetchComplete(sourceID: SourceID) async throws {
        throw Self.unsupportedRemote("markFetchComplete")
    }

    // SLICE-2 LEDGER: pending
    public func markFetchComplete( sourceID: SourceID, expectedContentVersionID: SourceVersionID ) async throws -> Bool {
        throw Self.unsupportedRemote("markFetchComplete")
    }

    // SLICE-2 LEDGER: pending
    public func fetchState(sourceID: SourceID) async throws -> SourceFetchState? {
        throw Self.unsupportedRemote("fetchState")
    }

    // SLICE-2 LEDGER: pending
    public func sourcesWithPendingFormatJobs() async throws -> [SourceID] {
        throw Self.unsupportedRemote("sourcesWithPendingFormatJobs")
    }

    // SLICE-2 LEDGER: pending
    public func processedMarkdownHead(sourceID: SourceID) async throws -> SourceMarkdownVersion? {
        throw Self.unsupportedRemote("processedMarkdownHead")
    }

    // SLICE-2 LEDGER: pending
    public func processedMarkdownHistory(sourceID: SourceID) async throws -> [SourceMarkdownVersion] {
        throw Self.unsupportedRemote("processedMarkdownHistory")
    }

    // SLICE-2 LEDGER: pending
    public func processedMarkdownVersion(id: SourceMarkdownVersionID) async throws -> SourceMarkdownVersion? {
        throw Self.unsupportedRemote("processedMarkdownVersion")
    }

    // SLICE-2 LEDGER: pending
    public func sourceDerivedChains() async throws -> [SourceID: [SourceMarkdownVersionID]] {
        throw Self.unsupportedRemote("sourceDerivedChains")
    }

    // SLICE-2 LEDGER: pending
    public func embedDescriptors() async throws -> [SourceID: SourceEmbedDescriptor] {
        throw Self.unsupportedRemote("embedDescriptors")
    }

    // SLICE-2 LEDGER: pending
    public func sourceOriginsBySource() async throws -> [SourceID: SourceOrigin] {
        throw Self.unsupportedRemote("sourceOriginsBySource")
    }

    // SLICE-2 LEDGER: pending
    public func ensureFetchActivity(provenance: SourceProvenance) async throws -> String {
        throw Self.unsupportedRemote("ensureFetchActivity")
    }

    // SLICE-2 LEDGER: pending
    public func addSnapshotImage( filename: String, data: Data, detectionHints: ContentTypeDetectionHints, originalPath: String, sourceURL: URL, activityID: String, role: SourceRole ) async throws -> SourceSummary {
        throw Self.unsupportedRemote("addSnapshotImage")
    }

    // SLICE-2 LEDGER: pending
    public func hasImageSiblings(sourceID: SourceID) async throws -> Bool {
        throw Self.unsupportedRemote("hasImageSiblings")
    }

    // SLICE-2 LEDGER: pending
    public func siblingImageResolvers() async throws -> [SourceID: [String: SourceID]] {
        throw Self.unsupportedRemote("siblingImageResolvers")
    }

    // SLICE-2 LEDGER: pending
    public func processedMarkdownAgentNames(sourceID: SourceID) async throws -> [SourceMarkdownVersionID: String] {
        throw Self.unsupportedRemote("processedMarkdownAgentNames")
    }

    // SLICE-2 LEDGER: pending
    public func processedMarkdownAlternatives(sourceID: SourceID) async throws -> [ExtractionAlternative] {
        throw Self.unsupportedRemote("processedMarkdownAlternatives")
    }

    // SLICE-2 LEDGER: pending
    public func appendProcessedMarkdown(sourceID: SourceID, content: String, origin: SourceMarkdownOrigin, note: String?, technique: String?) async throws -> SourceMarkdownVersion {
        throw Self.unsupportedRemote("appendProcessedMarkdown")
    }

    // SLICE-2 LEDGER: pending
    public func appendUserProcessedMarkdown( sourceID: SourceID, content: String, expectedHead: SourceMarkdownVersionID ) async throws -> SourceMarkdownVersion {
        throw Self.unsupportedRemote("appendUserProcessedMarkdown")
    }

    // SLICE-2 LEDGER: pending
    public func appendDerivedMarkdown( sourceID: SourceID, content: String, origin: SourceMarkdownOrigin, producer: ExtractionProducer?, providerID: ProviderID?, modelID: ModelID?, toolVersion: String?, sourceVersionID: SourceVersionID?, note: String? ) async throws -> SourceMarkdownVersion {
        throw Self.unsupportedRemote("appendDerivedMarkdown")
    }

    // SLICE-2 LEDGER: pending
    public func appendInstalledPackageMarkdown( sourceID: SourceID, content: String, package: ExtractionInstalledPackageProducer, origin: SourceMarkdownOrigin, toolVersion: String?, sourceVersionID: SourceVersionID?, note: String? ) async throws -> SourceMarkdownVersion {
        throw Self.unsupportedRemote("appendInstalledPackageMarkdown")
    }

    // SLICE-2 LEDGER: pending
    public func appendHostSpeechTranscript( sourceID: SourceID, content: String, producer: ExtractionHostSpeechProducer, sourceVersionID: SourceVersionID ) async throws -> SourceMarkdownVersion {
        throw Self.unsupportedRemote("appendHostSpeechTranscript")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func revertProcessedMarkdown(sourceID: SourceID, to versionID: SourceMarkdownVersionID) async throws -> SourceMarkdownVersion {
        throw Self.unsupportedRemote("revertProcessedMarkdown")
    }

    // SLICE-2 LEDGER: pending
    public func recordMarkdownExtraction( sourceID: SourceID, content: String, backend: ExtractionBackend, sourceVersionID: SourceVersionID?, note: String?, modelVersion: String? ) async throws -> SourceMarkdownVersion {
        throw Self.unsupportedRemote("recordMarkdownExtraction")
    }

    // SLICE-2 LEDGER: pending
    public func setActiveMarkdown(sourceID: SourceID, to versionID: SourceMarkdownVersionID) async throws {
        throw Self.unsupportedRemote("setActiveMarkdown")
    }

    // SLICE-2 LEDGER: pending
    public func appendPageVersion( pageID: PageID, title: String, body: String, expectedHeadVersionID: PageVersionID?, lastEditedBy: String?, provenance: [PageVersionSourceInput] ) async throws -> PageVersionID {
        throw Self.unsupportedRemote("appendPageVersion")
    }

    // SLICE-2 LEDGER: pending
    public func pageVersionSources(versionID: PageVersionID) async throws -> [PageVersionSource] {
        throw Self.unsupportedRemote("pageVersionSources")
    }

    // SLICE-2 LEDGER: pending
    public func pageHeadSources(pageID: PageID) async throws -> [PageVersionSource] {
        throw Self.unsupportedRemote("pageHeadSources")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func sourceReferencingPageVersions(sourceID: SourceID) async throws -> [PageVersionID] {
        throw Self.unsupportedRemote("sourceReferencingPageVersions")
    }

    // SLICE-2 LEDGER: pending
    public func pagesCitingSources(sourceIDs: [SourceID], limit: Int) async throws -> [CitedPage] {
        throw Self.unsupportedRemote("pagesCitingSources")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func extractionProvenance(markdownVersionID: SourceMarkdownVersionID) async throws -> ExtractionProvenance? {
        throw Self.unsupportedRemote("extractionProvenance")
    }

    // SLICE-2 LEDGER: pending
    public func activeExtractionProvenance(sourceID: SourceID) async throws -> ExtractionProvenance? {
        throw Self.unsupportedRemote("activeExtractionProvenance")
    }

    // SLICE-2 LEDGER: pending
    public func pageVersionHistory(pageID: PageID) async throws -> [PageVersionSummary] {
        throw Self.unsupportedRemote("pageVersionHistory")
    }

    // SLICE-2 LEDGER: pending
    public func pageOrigin(pageID: PageID) async throws -> PageOrigin? {
        throw Self.unsupportedRemote("pageOrigin")
    }

    // SLICE-2 LEDGER: pending
    public func pageEditHistory(pageID: PageID) async throws -> [PageOrigin] {
        throw Self.unsupportedRemote("pageEditHistory")
    }

    // SLICE-2 LEDGER: pending
    public func pageVersionBody(versionID: PageVersionID) async throws -> String? {
        throw Self.unsupportedRemote("pageVersionBody")
    }

    // SLICE-2 LEDGER: pending
    public func pageOKFMetadata(versionID: PageVersionID, includeCorrected: Bool) async throws -> PageOKFTrustMetadata? {
        throw Self.unsupportedRemote("pageOKFMetadata")
    }

    // SLICE-2 LEDGER: pending
    public func sourceMarkdownOKFMetadata( versionID: SourceMarkdownVersionID, includeCorrected: Bool ) async throws -> SourceMarkdownOKFTrustMetadata? {
        throw Self.unsupportedRemote("sourceMarkdownOKFMetadata")
    }

    // SLICE-2 LEDGER: pending
    public func setPageOKFStatus(versionID: PageVersionID, status: OKFConceptStatus?) async throws {
        throw Self.unsupportedRemote("setPageOKFStatus")
    }

    // SLICE-2 LEDGER: pending
    public func setSourceMarkdownOKFStatus( versionID: SourceMarkdownVersionID, status: OKFConceptStatus? ) async throws {
        throw Self.unsupportedRemote("setSourceMarkdownOKFStatus")
    }

    // SLICE-2 LEDGER: pending
    public func setPageOKFFreshness( versionID: PageVersionID, policy: OKFFreshnessPolicy? ) async throws {
        throw Self.unsupportedRemote("setPageOKFFreshness")
    }

    // SLICE-2 LEDGER: pending
    public func setSourceMarkdownOKFFreshness( versionID: SourceMarkdownVersionID, policy: OKFFreshnessPolicy? ) async throws {
        throw Self.unsupportedRemote("setSourceMarkdownOKFFreshness")
    }

    // SLICE-2 LEDGER: pending
    public func recordPageOKFVerification( versionID: PageVersionID, verifier: OKFVerifierIdentity, verifiedAt: Date, basis: OKFVerificationBasis, freshnessPolicy: OKFFreshnessPolicy? ) async throws -> OKFVerificationID {
        throw Self.unsupportedRemote("recordPageOKFVerification")
    }

    // SLICE-2 LEDGER: pending
    public func recordSourceMarkdownOKFVerification( versionID: SourceMarkdownVersionID, verifier: OKFVerifierIdentity, verifiedAt: Date, basis: OKFVerificationBasis, freshnessPolicy: OKFFreshnessPolicy? ) async throws -> OKFVerificationID {
        throw Self.unsupportedRemote("recordSourceMarkdownOKFVerification")
    }

    // SLICE-2 LEDGER: pending
    public func correctPageOKFVerification( versionID: PageVersionID, verificationID: OKFVerificationID, correctingVerifier: OKFVerifierIdentity, correctedAt: Date, reason: OKFVerificationCorrectionReason? ) async throws {
        throw Self.unsupportedRemote("correctPageOKFVerification")
    }

    // SLICE-2 LEDGER: pending
    public func correctSourceMarkdownOKFVerification( versionID: SourceMarkdownVersionID, verificationID: OKFVerificationID, correctingVerifier: OKFVerifierIdentity, correctedAt: Date, reason: OKFVerificationCorrectionReason? ) async throws {
        throw Self.unsupportedRemote("correctSourceMarkdownOKFVerification")
    }

    // SLICE-2 LEDGER: pending
    public func revertPage(pageID: PageID, to versionID: PageVersionID) async throws {
        throw Self.unsupportedRemote("revertPage")
    }

    // SLICE-2 LEDGER: pending
    public func restorePage(pageID: PageID, to versionID: PageVersionID) async throws -> PageVersionID {
        throw Self.unsupportedRemote("restorePage")
    }

    // SLICE-2 LEDGER: pending
    public func createWorkspace(name: String?, activityID: String?) async throws -> WorkspaceID {
        throw Self.unsupportedRemote("createWorkspace")
    }

    // SLICE-2 LEDGER: pending
    public func workspaceSummary(id: WorkspaceID) async throws -> WorkspaceSummary? {
        throw Self.unsupportedRemote("workspaceSummary")
    }

    // SLICE-2 LEDGER: pending
    public func workspaceRefs(workspaceID: WorkspaceID) async throws -> [WorkspaceRef] {
        throw Self.unsupportedRemote("workspaceRefs")
    }

    // SLICE-2 LEDGER: pending
    public func workspaceWritePage( workspaceID: WorkspaceID, pageID: PageID, title: String, body: String, author: String?, provenance: [PageVersionSourceInput] ) async throws -> PageVersionID? {
        throw Self.unsupportedRemote("workspaceWritePage")
    }

    // SLICE-2 LEDGER: pending
    public func workspacePageVersion(workspaceID: WorkspaceID, pageID: PageID) async throws -> PageVersionID? {
        throw Self.unsupportedRemote("workspacePageVersion")
    }

    // SLICE-2 LEDGER: pending
    public func workspacePageBody(workspaceID: WorkspaceID, pageID: PageID) async throws -> String? {
        throw Self.unsupportedRemote("workspacePageBody")
    }

    // SLICE-2 LEDGER: pending
    public func setWorkspaceIndexBody( workspaceID: WorkspaceID, indexBody: String, indexBaseVersion: String ) async throws {
        throw Self.unsupportedRemote("setWorkspaceIndexBody")
    }

    // SLICE-2 LEDGER: pending
    public func workspaceMerge(workspaceID: WorkspaceID) async throws -> [String] {
        throw Self.unsupportedRemote("workspaceMerge")
    }

    // SLICE-2 LEDGER: pending
    public func abandonWorkspace(id: WorkspaceID) async throws {
        throw Self.unsupportedRemote("abandonWorkspace")
    }

    // SLICE-2 LEDGER: pending
    public func workspaceRefresh(workspaceID: WorkspaceID) async throws {
        throw Self.unsupportedRemote("workspaceRefresh")
    }

    // SLICE-2 LEDGER: pending
    public func workspaceConflicts(workspaceID: WorkspaceID) async throws -> [WorkspaceConflict] {
        throw Self.unsupportedRemote("workspaceConflicts")
    }

    // SLICE-2 LEDGER: pending
    public func workspaceResolveConflict( workspaceID: WorkspaceID, pageID: PageID, body: String ) async throws {
        throw Self.unsupportedRemote("workspaceResolveConflict")
    }

    // SLICE-2 LEDGER: pending
    public func workspaceRetryMerge(workspaceID: WorkspaceID) async throws {
        throw Self.unsupportedRemote("workspaceRetryMerge")
    }

    // SLICE-2 LEDGER: pending
    public func reapStaleWorkspaces(ttl: TimeInterval) async throws -> Int {
        throw Self.unsupportedRemote("reapStaleWorkspaces")
    }

    // SLICE-2 LEDGER: pending
    public func appendLog(kind: LogEntry.Kind, title: String, note: String?) async throws -> LogEntry {
        throw Self.unsupportedRemote("appendLog")
    }

    // SLICE-2 LEDGER: pending
    public func recentLogEntries(limit: Int) async throws -> [LogEntry] {
        throw Self.unsupportedRemote("recentLogEntries")
    }

    // SLICE-2 LEDGER: pending
    public func getWikiIndex() async throws -> WikiIndex {
        throw Self.unsupportedRemote("getWikiIndex")
    }

    // SLICE-2 LEDGER: pending
    public func updateWikiIndex(body: String) async throws {
        throw Self.unsupportedRemote("updateWikiIndex")
    }

    // SLICE-2 LEDGER: pending
    public func storePageChunks(id: PageID, chunks: [Data]) async throws {
        throw Self.unsupportedRemote("storePageChunks")
    }

    // SLICE-2 LEDGER: pending
    public func missingPageEmbeddingWork() async throws -> [(id: PageID, text: String)] {
        throw Self.unsupportedRemote("missingPageEmbeddingWork")
    }

    // SLICE-2 LEDGER: pending
    public func searchSimilar(query: String, limit: Int, bm25Leg: [WikiPageSummary]?) async throws -> [WikiPageSummary] {
        throw Self.unsupportedRemote("searchSimilar")
    }

    // SLICE-2 LEDGER: pending
    public func storeSourceChunks(id: SourceID, chunks: [Data]) async throws {
        throw Self.unsupportedRemote("storeSourceChunks")
    }

    // SLICE-2 LEDGER: pending
    public func missingSourceEmbeddingWork() async throws -> [(id: SourceID, text: String)] {
        throw Self.unsupportedRemote("missingSourceEmbeddingWork")
    }

    // SLICE-2 LEDGER: pending
    public func searchSimilarSources(query: String, limit: Int, bm25Leg: [SourceSummary]?) async throws -> [SourceSummary] {
        throw Self.unsupportedRemote("searchSimilarSources")
    }

    // SLICE-2 LEDGER: pending
    public func listBookmarkNodes() async throws -> [BookmarkNode] {
        throw Self.unsupportedRemote("listBookmarkNodes")
    }

    // SLICE-2 LEDGER: pending
    public func createBookmarkNode( parentID: BookmarkID?, position: Int, content: BookmarkNode.Content ) async throws -> BookmarkNode {
        throw Self.unsupportedRemote("createBookmarkNode")
    }

    // SLICE-2 LEDGER: pending
    public func renameBookmarkFolder(id: BookmarkID, to label: String) async throws {
        throw Self.unsupportedRemote("renameBookmarkFolder")
    }

    // SLICE-2 LEDGER: pending
    public func retargetBookmarkNode(id: BookmarkID, to content: BookmarkNode.Content) async throws {
        throw Self.unsupportedRemote("retargetBookmarkNode")
    }

    // SLICE-2 LEDGER: pending
    public func deleteBookmarkNode(id: BookmarkID) async throws {
        throw Self.unsupportedRemote("deleteBookmarkNode")
    }

    // SLICE-2 LEDGER: pending
    public func moveBookmarkNode(id: BookmarkID, toParentID: BookmarkID?, position: Int) async throws {
        throw Self.unsupportedRemote("moveBookmarkNode")
    }

    // SLICE-2 LEDGER: pending
    public func chatAttachments(chatID: ChatID) async throws -> [ChatAttachmentTarget] {
        throw Self.unsupportedRemote("chatAttachments")
    }

    // SLICE-2 LEDGER: pending
    public func setChatAttachments(chatID: ChatID, targets: [ChatAttachmentTarget]) async throws {
        throw Self.unsupportedRemote("setChatAttachments")
    }

    // SLICE-2 LEDGER: pending
    public func appendChatMessages(chatID: ChatID, events: [AgentEvent]) async throws -> [ChatMessage] {
        throw Self.unsupportedRemote("appendChatMessages")
    }

    // SLICE-2 LEDGER: pending
    public func chatMessages(chatID: ChatID) async throws -> [ChatMessage] {
        throw Self.unsupportedRemote("chatMessages")
    }

    // SLICE-2 LEDGER: pending
    public func renameChat(id: ChatID, to title: String) async throws {
        throw Self.unsupportedRemote("renameChat")
    }

    // SLICE-2 LEDGER: pending
    public func setChatTitleIfEmpty(chatID: ChatID, title: String) async throws -> Bool {
        throw Self.unsupportedRemote("setChatTitleIfEmpty")
    }

    // SLICE-2 LEDGER: pending
    public func setChatTitleIf( chatID: ChatID, expectedTitle: String, title: String ) async throws -> Bool {
        throw Self.unsupportedRemote("setChatTitleIf")
    }

    // SLICE-2 LEDGER: pending
    public func deleteChat(id: ChatID) async throws {
        throw Self.unsupportedRemote("deleteChat")
    }

    // SLICE-2 LEDGER: pending
    public func updateChatAcpSessionId(chatID: ChatID, acpSessionId: AcpSessionID?) async throws {
        throw Self.unsupportedRemote("updateChatAcpSessionId")
    }

    // SLICE-2 LEDGER: pending
    public func updateChatModelOverride(id: ChatID, providerId: ProviderID?, modelId: ModelID?) async throws {
        throw Self.unsupportedRemote("updateChatModelOverride")
    }

    // SLICE-2 LEDGER: pending
    public func updateChatModelAndThinkingSelection( chatID: ChatID, providerID: ProviderID?, modelID: ModelID?, configuredThinkingID: ChatConfigurationValueID?, effectiveThinkingID: ChatConfigurationValueID? ) async throws {
        throw Self.unsupportedRemote("updateChatModelAndThinkingSelection")
    }

    // SLICE-2 LEDGER: pending
    public func getChat(id: ChatID) async throws -> ChatSummary {
        throw Self.unsupportedRemote("getChat")
    }

    // SLICE-2 LEDGER: pending
    public func updateMessageSummary( chatID: ChatID, cursor: ChatTranscriptCursor, summary: String, kind: ChatMessageSummaryKind ) async throws {
        throw Self.unsupportedRemote("updateMessageSummary")
    }

    // SLICE-2 LEDGER: pending
    public func checkpointStreamingMessage( chatID: ChatID, handle: String, event: AgentEvent, isDraft: Bool ) async throws {
        throw Self.unsupportedRemote("checkpointStreamingMessage")
    }

    // SLICE-2 LEDGER: pending
    public func finalizeStaleDrafts(forChat chatID: ChatID) async throws {
        throw Self.unsupportedRemote("finalizeStaleDrafts")
    }

    // SLICE-2 LEDGER: pending
    public func enqueuePersistedChatTurn(chatID: ChatID, submission: ChatTurnSubmission) async throws -> PersistedChatTurn {
        throw Self.unsupportedRemote("enqueuePersistedChatTurn")
    }

    // SLICE-2 LEDGER: pending
    public func listPersistedChatTurns(chatID: ChatID) async throws -> [PersistedChatTurn] {
        throw Self.unsupportedRemote("listPersistedChatTurns")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func editPersistedChatTurn( chatID: ChatID, turnID: ChatTurnID, userText: String, contextReferences: [ChatContextReference], editedAt: Date ) async throws -> PersistedChatTurn {
        throw Self.unsupportedRemote("editPersistedChatTurn")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func removePersistedQueuedChatTurn(chatID: ChatID, turnID: ChatTurnID) async throws -> Bool {
        throw Self.unsupportedRemote("removePersistedQueuedChatTurn")
    }

    // SLICE-2 LEDGER: pending
    public func cancelUnclaimedPersistedChatTurn(chatID: ChatID, turnID: ChatTurnID) async throws -> PersistedChatTurn? {
        throw Self.unsupportedRemote("cancelUnclaimedPersistedChatTurn")
    }

    // SLICE-2 LEDGER: pending
    public func claimNextPersistedChatTurn( chatID: ChatID, claimID: ChatTurnClaimID, claimedAt: Date ) async throws -> PersistedChatTurn? {
        throw Self.unsupportedRemote("claimNextPersistedChatTurn")
    }

    // SLICE-2 LEDGER: pending
    public func claimNextPersistedChatTurn( chatID: ChatID, claimID: ChatTurnClaimID, claimedAt: Date, providerID: ProviderID?, modelID: ModelID? ) async throws -> PersistedChatTurn? {
        throw Self.unsupportedRemote("claimNextPersistedChatTurn")
    }

    // SLICE-2 LEDGER: pending
    public func markPersistedChatTurnProviderSubmitted( chatID: ChatID, turnID: ChatTurnID, claimID: ChatTurnClaimID, providerSessionID: AcpSessionID?, submittedAt: Date ) async throws -> PersistedChatTurn {
        throw Self.unsupportedRemote("markPersistedChatTurnProviderSubmitted")
    }

    // SLICE-2 LEDGER: pending
    public func finishPersistedChatTurn( chatID: ChatID, turnID: ChatTurnID, claimID: ChatTurnClaimID, state: ChatTurnPersistenceState, terminalMessage: String? ) async throws -> PersistedChatTurn {
        throw Self.unsupportedRemote("finishPersistedChatTurn")
    }

    // SLICE-2 LEDGER: pending
    public func finishPersistedChatTurn( chatID: ChatID, turnID: ChatTurnID, claimID: ChatTurnClaimID, state: ChatTurnPersistenceState, terminalMessage: String?, finishedAt: Date, usage: ChatTurnUsageValues? ) async throws -> PersistedChatTurn {
        throw Self.unsupportedRemote("finishPersistedChatTurn")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func chatTurnUsage(chatID: ChatID, turnID: ChatTurnID) async throws -> ChatTurnUsage? {
        throw Self.unsupportedRemote("chatTurnUsage")
    }

    // SLICE-2 LEDGER: pending [manifest: removed]
    public func latestChatTurnUsage(chatID: ChatID) async throws -> ChatTurnUsage? {
        throw Self.unsupportedRemote("latestChatTurnUsage")
    }

    // SLICE-2 LEDGER: pending
    public func chatUsageSummary(chatID: ChatID) async throws -> ChatUsageSummary {
        throw Self.unsupportedRemote("chatUsageSummary")
    }

    // SLICE-2 LEDGER: pending
    public func updatePersistedChatTurnUsage( chatID: ChatID, turnID: ChatTurnID, claimID: ChatTurnClaimID, usage: ChatTurnUsageValues ) async throws -> PersistedChatTurn {
        throw Self.unsupportedRemote("updatePersistedChatTurnUsage")
    }

    // SLICE-2 LEDGER: pending
    public func appendChatTranscriptItems( chatID: ChatID, items: [ChatTranscriptItem] ) async throws -> [PersistedChatTranscriptItem] {
        throw Self.unsupportedRemote("appendChatTranscriptItems")
    }

    // SLICE-2 LEDGER: pending
    public func readChatTranscriptPage( chatID: ChatID, after cursor: ChatTranscriptCursor?, limit: Int ) async throws -> ChatTranscriptPage {
        throw Self.unsupportedRemote("readChatTranscriptPage")
    }

    // SLICE-2 LEDGER: pending
    public func chatTranscriptCheckpoint(chatID: ChatID) async throws -> ChatTranscriptCursor {
        throw Self.unsupportedRemote("chatTranscriptCheckpoint")
    }

    // SLICE-2 LEDGER: pending
    public func listAllChatsOrderedByID() async throws -> [ChatSummary] {
        throw Self.unsupportedRemote("listAllChatsOrderedByID")
    }

    // SLICE-2 LEDGER: pending
    public func resolveChatByTitle(_ title: String) async throws -> ChatID? {
        throw Self.unsupportedRemote("resolveChatByTitle")
    }

    // SLICE-2 LEDGER: pending
    public func storeChatChunks(id: ChatID, chunks: [Data]) async throws {
        throw Self.unsupportedRemote("storeChatChunks")
    }

    // SLICE-2 LEDGER: pending
    public func missingChatEmbeddingWork() async throws -> [(id: ChatID, text: String)] {
        throw Self.unsupportedRemote("missingChatEmbeddingWork")
    }

    // SLICE-2 LEDGER: pending
    public func searchSimilarChats(query: String, limit: Int, bm25Leg: [ChatSummary]?) async throws -> [ChatSummary] {
        throw Self.unsupportedRemote("searchSimilarChats")
    }

    // SLICE-2 LEDGER: pending
    public func vacuumBlobs(dryRun: Bool) async throws -> BlobVacuumReport {
        throw Self.unsupportedRemote("vacuumBlobs")
    }

    // SLICE-2 LEDGER: pending
    public func repairMIME(dryRun: Bool) async throws -> MIMERepairReport {
        throw Self.unsupportedRemote("repairMIME")
    }

    // SLICE-2 LEDGER: pending
    public func vacuumActivities(dryRun: Bool) async throws -> ActivityVacuumReport {
        throw Self.unsupportedRemote("vacuumActivities")
    }

    // SLICE-2 LEDGER: pending
    public func vacuumPageVersions(dryRun: Bool) async throws -> PageVersionVacuumReport {
        throw Self.unsupportedRemote("vacuumPageVersions")
    }
}
#endif
