//
//  ModelDelayedWikiStore.swift
//  Tests/WikiFSTests — P1.4 delayed-store semantics suite support.
//
//  GENERATED from Sources/WikiFSCore/Store/WikiStore.swift (the `WikiStore`
//  protocol block) by tmp/generate_delayed_store.py — regenerate after
//  protocol changes:
//
//      python3 tmp/generate_delayed_store.py
//
//  The proxy wraps an in-memory `GRDBWikiStore` and forwards every
//  `WikiStore` requirement through an `any WikiStore` existential (sync GRDB
//  witnesses satisfy the async requirements). Three seams are INTERCEPTED and
//  consult a `TestStoreController`: `getPage`, `listPages`, and `upsertPage`
//  (the model's save seam — `save()` and the transition flush both route
//  through `PageUpsert.upsert` → `store.upsertPage`). The `eventBus` and the
//  two registration properties are client-local stored fields, so the suite
//  can drive the model's change subscription without touching the inner
//  store's own bus.
//
//  Gate waits race a timeout (repo rule: never a bare unbounded
//  continuation), so a starved cooperative pool produces a fast, diagnosed
//  failure instead of hanging `swift test`.

#if os(macOS)
import Foundation
@testable import WikiFSCore

/// Thrown by `DelayedStoreGate.wait` when a gate stays closed past its timeout.
struct GateTimeoutError: Error, CustomStringConvertible {
    let gate: String
    let timeout: Duration

    var description: String {
        let secs = Double(timeout.components.seconds)
        return "gate \(gate) still closed after \(secs)s — the awaited model task never reached (or never left) the gate"
    }
}

/// Continuation-based latch for delayed-store tests. `open()` releases every
/// current and future waiter; `wait()` blocks callers until then, raced
/// against a timeout so a lost completion is a failure, not a hang.
final class DelayedStoreGate: @unchecked Sendable {
    private struct Waiter {
        let id: Int
        var continuation: CheckedContinuation<Void, any Error>?
    }

    private let lock = NSLock()
    private var opened = false
    private var waiters: [Waiter] = []
    private var nextWaiterID = 0
    private var enteredCount = 0
    private let name: String

    init(name: String) {
        self.name = name
    }

    /// Suspend until `open()`. Raced against `timeout`; BOTH racing paths
    /// abort the waiter (lock-protected remove + resume) so nothing leaks
    /// and the cooperative pool is never blocked:
    /// - the timeout child aborts the waiter BEFORE the group scope waits on
    ///   its children (H7: cancelling a parked continuation child does NOT
    ///   resume a `CheckedContinuation` — without the explicit abort the
    ///   group scope deadlocks on the parked child forever),
    /// - external cancellation of `wait()` aborts+resumes via the
    ///   cancellation handler,
    /// - `open()` resumes through its own removal path; the lock guarantees
    ///   each waiter's continuation resumes at most once.
    func wait(timeout: Duration = delayedStoreHarnessPatience) async throws {
        let waiterID: Int? = {
            lock.lock()
            defer { lock.unlock() }
            if opened { return nil }
            enteredCount += 1
            nextWaiterID += 1
            waiters.append(Waiter(id: nextWaiterID, continuation: nil))
            return nextWaiterID
        }()
        guard let waiterID else { return } // already open: latch passes through
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                        self.attachContinuation(waiterID, cont)
                    }
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    // Timeout wins: abort the parked waiter FIRST (remove +
                    // resume with the timeout error) so the group scope can
                    // never wait on a still-parked child, then surface the
                    // timeout through the group.
                    self.abortWaiter(
                        waiterID,
                        error: GateTimeoutError(gate: self.name, timeout: timeout))
                    throw GateTimeoutError(gate: self.name, timeout: timeout)
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } onCancel: {
            // External cancellation of wait() must also abort+resume the
            // parked waiter, or the parked child would leak its continuation.
            self.abortWaiter(waiterID, error: CancellationError())
        }
    }

    /// Latch open and release every registered waiter.
    func open() {
        lock.lock()
        opened = true
        let released = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in released {
            waiter.continuation?.resume()
        }
    }

    func entryCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return enteredCount
    }

    /// Store a waiter's continuation. If the gate already opened (or the
    /// waiter was abandoned by a timeout), resume immediately — the caller
    /// must not park on a continuation nobody will release.
    private func attachContinuation(_ id: Int, _ cont: CheckedContinuation<Void, any Error>) {
        lock.lock()
        if opened {
            lock.unlock()
            cont.resume()
            return
        }
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            cont.resume()
            return
        }
        waiters[index].continuation = cont
        lock.unlock()
    }

    /// Remove waiter `id` (if still registered) and resume its continuation —
    /// at most once per waiter — throwing `error`. Called by the timeout
    /// child BEFORE the group scope waits on children, and by external
    /// cancellation of `wait()`, so a parked continuation can never outlive
    /// both racing paths (H7). Concurrent with `open()`: only the side that
    /// removes the waiter entry under the lock resumes it.
    private func abortWaiter(_ id: Int, error: any Error) {
        lock.lock()
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let waiter = waiters.remove(at: index)
        lock.unlock()
        waiter.continuation?.resume(throwing: error)
    }
}

/// One recorded `upsertPage` call (the model's shared save seam).
struct RecordedUpsert: Sendable {
    let id: PageID?
    let title: String
    let rawBody: String
}

/// Lock-guarded interception state the generated proxy consults. The suite
/// installs gates/errors/overrides BEFORE driving the model; the proxy only
/// reads.
final class TestStoreController: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [String: DelayedStoreGate] = [:]
    private var callCounts: [String: Int] = [:]
    private var entryCounts: [String: Int] = [:]
    private var upserts: [RecordedUpsert] = []
    private var errors: [String: any Error] = [:]
    private var overrides: [String: WikiPage] = [:]

    func installGate(_ gate: DelayedStoreGate, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        gates[key] = gate
    }

    func gate(forKey key: String) -> DelayedStoreGate? {
        lock.lock()
        defer { lock.unlock() }
        return gates[key]
    }

    func setError(_ error: any Error, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        errors[key] = error
    }

    func setPageOverride(_ page: WikiPage, forKey id: PageID) {
        lock.lock()
        defer { lock.unlock() }
        overrides[id.rawValue] = page
    }

    func recordCall(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        callCounts[name, default: 0] += 1
    }

    func callCount(_ name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callCounts[name] ?? 0
    }

    func recordEntry(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        entryCounts[key, default: 0] += 1
    }

    func entryCount(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entryCounts[key] ?? 0
    }

    func recordUpsert(_ upsert: RecordedUpsert) {
        lock.lock()
        defer { lock.unlock() }
        upserts.append(upsert)
    }

    func allUpserts() -> [RecordedUpsert] {
        lock.lock()
        defer { lock.unlock() }
        return upserts
    }

    func error(forKey key: String) -> (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return errors[key]
    }

    func pageOverride(forKey id: PageID) -> WikiPage? {
        lock.lock()
        defer { lock.unlock() }
        return overrides[id.rawValue]
    }

    /// Poll until `entryCount(key) >= minimum` (absolute count), raced against
    /// a timeout so a model task that never reaches the seam fails fast with
    /// context.
    func waitForEntry(_ key: String, minimum: Int = 1, timeout: Duration = delayedStoreHarnessPatience) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while self.entryCount(key) < minimum {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw GateTimeoutError(gate: "entry:\(key) (waiting for >= \(minimum))", timeout: timeout)
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}

/// Integration patience for the delayed-store harness. CI's 3-vCPU runner
/// has starved continuation resumption ~40x a gate window, so the harness's
/// seam-wait budgets derive from this one constant instead of scattered
/// 5 s defaults. A genuine hang still fails fast relative to the
/// choreography suite's 5-minute time limit.
private let delayedStoreHarnessPatience: Duration = .seconds(30)

/// Generated delaying proxy. `@unchecked Sendable`: the three mutable
/// protocol properties are NSLock-guarded backing fields; `inner`, the
/// existential forward, and `controller` are immutable.
final class ModelDelayedWikiStore: WikiStore, @unchecked Sendable {
    private let inner: GRDBWikiStore
    private let innerAsStore: any WikiStore
    let controller: TestStoreController

    private let stateLock = NSLock()
    private var _eventBus: WikiEventBus?
    private var _registeredExtractionInputs = RegisteredExtractionInputs.none
    private var _registeredRendererSourceTypes = RegisteredRendererSourceTypes.none

    init(controller: TestStoreController = TestStoreController()) throws {
        self.controller = controller
        self.inner = try GRDBWikiStore()
        self.innerAsStore = inner
    }

    /// Direct inner-store access for fixture seeding (bypasses interception).
    var innerStore: GRDBWikiStore { inner }

    // MARK: - Client-local properties ({ get set } requirements)

    var eventBus: WikiEventBus? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _eventBus
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _eventBus = newValue
        }
    }

    var registeredExtractionInputs: RegisteredExtractionInputs {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _registeredExtractionInputs
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _registeredExtractionInputs = newValue
        }
    }

    var registeredRendererSourceTypes: RegisteredRendererSourceTypes {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _registeredRendererSourceTypes
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _registeredRendererSourceTypes = newValue
        }
    }

    // MARK: - Interceptors (hand-written; the suite drives these)

    func listPages(sortBy: PageSortOrder) async throws -> [WikiPageSummary] {
        controller.recordCall("listPages")
        controller.recordEntry("listPages")
        if let gate = controller.gate(forKey: "listPages") {
            try await gate.wait()
        }
        if let error = controller.error(forKey: "listPages") { throw error }
        let pages = try await innerAsStore.listPages(sortBy: sortBy)
        controller.recordEntry("listPages:returned")
        return pages
    }

    func getPage(id: PageID) async throws -> WikiPage {
        controller.recordCall("getPage")
        controller.recordEntry("getPage:\(id.rawValue)")
        if let override = controller.pageOverride(forKey: id) { return override }
        if let gate = controller.gate(forKey: "getPage:\(id.rawValue)") {
            try await gate.wait()
        }
        if let error = controller.error(forKey: "getPage") { throw error }
        let page = try await innerAsStore.getPage(id: id)
        controller.recordEntry("getPage:\(id.rawValue):returned")
        return page
    }

    @discardableResult
    func createPage(title: String) async throws -> WikiPage {
        return try await innerAsStore.createPage(title: title)
    }

    func createPage(title: String, body: String, createdBy: String?, provenance: [PageVersionSourceInput]) async throws -> WikiPage {
        return try await innerAsStore.createPage(title: title, body: body, createdBy: createdBy, provenance: provenance)
    }

    func createPage(title: String, createdBy: String?, provenance: [PageVersionSourceInput]) async throws -> WikiPage {
        return try await innerAsStore.createPage(title: title, createdBy: createdBy, provenance: provenance)
    }

    func updatePage(id: PageID, title: String, body: String, lastEditedBy: String?, provenance: [PageVersionSourceInput]) async throws {
        try await innerAsStore.updatePage(id: id, title: title, body: body, lastEditedBy: lastEditedBy, provenance: provenance)
    }

    func deletePage(id: PageID) async throws {
        try await innerAsStore.deletePage(id: id)
    }

    func deletionImpact(for targets: Set<ResourceDeletionTarget>) async throws -> DeletionImpact {
        return try await innerAsStore.deletionImpact(for: targets)
    }

    @discardableResult
    func deleteResources(_ request: ResourceDeletionRequest) async throws -> ResourceDeletionResult {
        return try await innerAsStore.deleteResources(request)
    }

    func resolveTitleToID(_ title: String) async throws -> PageID? {
        return try await innerAsStore.resolveTitleToID(title)
    }

    func resolveSourceByName(_ displayName: String) async throws -> SourceID? {
        return try await innerAsStore.resolveSourceByName(displayName)
    }

    func replaceLinks(from pageID: PageID, parsedLinks: [ParsedLink]) async throws {
        try await innerAsStore.replaceLinks(from: pageID, parsedLinks: parsedLinks)
    }

    @discardableResult
    func upsertPage(id: PageID?, title: String, rawBody: String, expectation: PageWriteExpectation, author: String?, provenance: [PageVersionSourceInput]) async throws -> PageUpsert.Outcome {
        controller.recordCall("upsertPage")
        controller.recordEntry("upsertPage:\(id?.rawValue ?? "new")")
        controller.recordUpsert(
            RecordedUpsert(id: id, title: title, rawBody: rawBody))
        if let gate = controller.gate(forKey: "upsertPage") {
            try await gate.wait()
        }
        if let error = controller.error(forKey: "upsertPage") { throw error }
        let outcome = try await innerAsStore.upsertPage(
            id: id, title: title, rawBody: rawBody, expectation: expectation,
            author: author, provenance: provenance)
        controller.recordEntry("upsertPage:returned")
        return outcome
    }

    func pageLinkingPages(to pageID: PageID) async throws -> [PageID] {
        return try await innerAsStore.pageLinkingPages(to: pageID)
    }

    func sourceLinkingPages(to sourceID: SourceID) async throws -> [PageID] {
        return try await innerAsStore.sourceLinkingPages(to: sourceID)
    }

    @discardableResult
    func addSource(filename: String, data: Data) async throws -> SourceSummary {
        return try await innerAsStore.addSource(filename: filename, data: data)
    }

    @discardableResult
    func addSource(filename: String, data: Data, detectionHints: ContentTypeDetectionHints, ingestMetadata: SourceIngestMetadata?, provenance: SourceProvenance?, role: SourceRole, originalPath: String?, activityID: String?, resolvedDisplayName: String??) async throws -> SourceSummary {
        return try await innerAsStore.addSource(filename: filename, data: data, detectionHints: detectionHints, ingestMetadata: ingestMetadata, provenance: provenance, role: role, originalPath: originalPath, activityID: activityID, resolvedDisplayName: resolvedDisplayName)
    }

    @discardableResult
    func addBytelessSource(filename: String, mimeType: String?, provenance: SourceProvenance, role: SourceRole) async throws -> SourceSummary {
        return try await innerAsStore.addBytelessSource(filename: filename, mimeType: mimeType, provenance: provenance, role: role)
    }

    func listSources() async throws -> [SourceSummary] {
        return try await innerAsStore.listSources()
    }

    func getWikiStrategyState() async throws -> WikiStrategyState {
        return try await innerAsStore.getWikiStrategyState()
    }

    func getWikiStrategy() async throws -> WikiStrategy? {
        return try await innerAsStore.getWikiStrategy()
    }

    func wikiStrategyRevision() async throws -> WikiStrategyRevision? {
        return try await innerAsStore.wikiStrategyRevision()
    }

    @discardableResult
    func saveWikiStrategy(name: String, instructions: String, expectedRevision: WikiStrategyRevision?) async throws -> WikiStrategySaveOutcome {
        return try await innerAsStore.saveWikiStrategy(name: name, instructions: instructions, expectedRevision: expectedRevision)
    }

    func listRendererSourcePreferences() async throws -> [RendererSourcePreference] {
        return try await innerAsStore.listRendererSourcePreferences()
    }

    func rendererSourcePreference(sourceID: SourceID) async throws -> RendererSourcePreference? {
        return try await innerAsStore.rendererSourcePreference(sourceID: sourceID)
    }

    func setRendererSourcePreference(sourceID: SourceID, preference: RendererPreferenceReference) async throws {
        try await innerAsStore.setRendererSourcePreference(sourceID: sourceID, preference: preference)
    }

    func rendererSourcePresentation(sourceID: SourceID) async throws -> RendererSourcePresentation? {
        return try await innerAsStore.rendererSourcePresentation(sourceID: sourceID)
    }

    func setRendererSourcePresentation(sourceID: SourceID, presentation: RendererSourcePresentationMode) async throws {
        try await innerAsStore.setRendererSourcePresentation(sourceID: sourceID, presentation: presentation)
    }

    func removeRendererSourcePresentation(sourceID: SourceID) async throws {
        try await innerAsStore.removeRendererSourcePresentation(sourceID: sourceID)
    }

    func rendererSettingsJournalRecords() async throws -> [PersistedWikiStoreChangeRecord] {
        return try await innerAsStore.rendererSettingsJournalRecords()
    }

    func sourceContent(id: SourceID) async throws -> Data {
        return try await innerAsStore.sourceContent(id: id)
    }

    func sourceContent(versionID: SourceVersionID) async throws -> Data {
        return try await innerAsStore.sourceContent(versionID: versionID)
    }

    func rendererInputByteCount(_ input: RendererBridgeInput) async throws -> Int? {
        return try await innerAsStore.rendererInputByteCount(input)
    }

    func sourceVersion(id: SourceVersionID) async throws -> SourceVersion? {
        return try await innerAsStore.sourceVersion(id: id)
    }

    func deleteSource(id: SourceID) async throws {
        try await innerAsStore.deleteSource(id: id)
    }

    func sourceProvenanceBlockers(sourceID: SourceID) async throws -> [ProvenanceDeletionBlocker] {
        return try await innerAsStore.sourceProvenanceBlockers(sourceID: sourceID)
    }

    func sourceOrigin(sourceID: SourceID) async throws -> SourceOrigin? {
        return try await innerAsStore.sourceOrigin(sourceID: sourceID)
    }

    func sourceMatchingURLIdentity(_ identity: String) async throws -> SourceSummary? {
        return try await innerAsStore.sourceMatchingURLIdentity(identity)
    }

    func sourceEditHistory(sourceID: SourceID) async throws -> [SourceOrigin] {
        return try await innerAsStore.sourceEditHistory(sourceID: sourceID)
    }

    func activeContentVersion(sourceID: SourceID) async throws -> SourceVersion? {
        return try await innerAsStore.activeContentVersion(sourceID: sourceID)
    }

    func initialContentVersion(sourceID: SourceID) async throws -> SourceVersion? {
        return try await innerAsStore.initialContentVersion(sourceID: sourceID)
    }

    func renameSource(id: SourceID, to newDisplayName: String) async throws {
        try await innerAsStore.renameSource(id: id, to: newDisplayName)
    }

    func setSourceDisplayName(id: SourceID, displayName: String) async throws {
        try await innerAsStore.setSourceDisplayName(id: id, displayName: displayName)
    }

    func markSourceIngested(id: SourceID) async throws {
        try await innerAsStore.markSourceIngested(id: id)
    }

    func markedSourceIDs() async throws -> Set<String> {
        return try await innerAsStore.markedSourceIDs()
    }

    @discardableResult
    func appendContentVersion(sourceID: SourceID, data: Data, detectionHints: ContentTypeDetectionHints, provenance: SourceProvenance?) async throws -> SourceVersion {
        return try await innerAsStore.appendContentVersion(sourceID: sourceID, data: data, detectionHints: detectionHints, provenance: provenance)
    }

    @discardableResult
    func attachAcquiredBytes(sourceID: SourceID, bytes: Data, mimeType: String, originalFilename: String?, externalItemKey: String?, externalItemTitle: String?, producer: ExtractionInstalledPackageProducer?) async throws -> SourceVersion {
        return try await innerAsStore.attachAcquiredBytes(sourceID: sourceID, bytes: bytes, mimeType: mimeType, originalFilename: originalFilename, externalItemKey: externalItemKey, externalItemTitle: externalItemTitle, producer: producer)
    }

    func setAcquisitionProvenance(sourceID: SourceID, externalItemKey: String?, externalItemTitle: String?, displayName: String?) async throws {
        try await innerAsStore.setAcquisitionProvenance(sourceID: sourceID, externalItemKey: externalItemKey, externalItemTitle: externalItemTitle, displayName: displayName)
    }

    @discardableResult
    func appendFetchMarkdown(sourceID: SourceID, content: String, package: ExtractionInstalledPackageProducer, externalItemKey: String?, externalItemTitle: String?, sourceVersionID: SourceVersionID) async throws -> SourceMarkdownVersion {
        return try await innerAsStore.appendFetchMarkdown(sourceID: sourceID, content: content, package: package, externalItemKey: externalItemKey, externalItemTitle: externalItemTitle, sourceVersionID: sourceVersionID)
    }

    func markFetchComplete(sourceID: SourceID) async throws {
        try await innerAsStore.markFetchComplete(sourceID: sourceID)
    }

    @discardableResult
    func markFetchComplete(sourceID: SourceID, expectedContentVersionID: SourceVersionID) async throws -> Bool {
        return try await innerAsStore.markFetchComplete(sourceID: sourceID, expectedContentVersionID: expectedContentVersionID)
    }

    func fetchState(sourceID: SourceID) async throws -> SourceFetchState? {
        return try await innerAsStore.fetchState(sourceID: sourceID)
    }

    func sourcesWithPendingFormatJobs() async throws -> [SourceID] {
        return try await innerAsStore.sourcesWithPendingFormatJobs()
    }

    func processedMarkdownHead(sourceID: SourceID) async throws -> SourceMarkdownVersion? {
        return try await innerAsStore.processedMarkdownHead(sourceID: sourceID)
    }

    func hasProcessedMarkdown(sourceID: SourceID) async throws -> Bool {
        return try await innerAsStore.hasProcessedMarkdown(sourceID: sourceID)
    }

    func processedMarkdownHistory(sourceID: SourceID) async throws -> [SourceMarkdownVersion] {
        return try await innerAsStore.processedMarkdownHistory(sourceID: sourceID)
    }

    func processedMarkdownVersion(id: SourceMarkdownVersionID) async throws -> SourceMarkdownVersion? {
        return try await innerAsStore.processedMarkdownVersion(id: id)
    }

    func sourceDerivedChains() async throws -> [SourceID: [SourceMarkdownVersionID]] {
        return try await innerAsStore.sourceDerivedChains()
    }

    func embedDescriptors() async throws -> [SourceID: SourceEmbedDescriptor] {
        return try await innerAsStore.embedDescriptors()
    }

    func sourceOriginsBySource() async throws -> [SourceID: SourceOrigin] {
        return try await innerAsStore.sourceOriginsBySource()
    }

    @discardableResult
    func ensureFetchActivity(provenance: SourceProvenance) async throws -> String {
        return try await innerAsStore.ensureFetchActivity(provenance: provenance)
    }

    @discardableResult
    func addSnapshotImage(filename: String, data: Data, detectionHints: ContentTypeDetectionHints, originalPath: String, sourceURL: URL, activityID: String, role: SourceRole) async throws -> SourceSummary {
        return try await innerAsStore.addSnapshotImage(filename: filename, data: data, detectionHints: detectionHints, originalPath: originalPath, sourceURL: sourceURL, activityID: activityID, role: role)
    }

    func hasImageSiblings(sourceID: SourceID) async throws -> Bool {
        return try await innerAsStore.hasImageSiblings(sourceID: sourceID)
    }

    func siblingImageResolvers() async throws -> [SourceID: [String: SourceID]] {
        return try await innerAsStore.siblingImageResolvers()
    }

    func processedMarkdownAgentNames(sourceID: SourceID) async throws -> [SourceMarkdownVersionID: String] {
        return try await innerAsStore.processedMarkdownAgentNames(sourceID: sourceID)
    }

    func processedMarkdownAlternatives(sourceID: SourceID) async throws -> [ExtractionAlternative] {
        return try await innerAsStore.processedMarkdownAlternatives(sourceID: sourceID)
    }

    @discardableResult
    func appendProcessedMarkdown(sourceID: SourceID, content: String, origin: SourceMarkdownOrigin, note: String?, technique: String?) async throws -> SourceMarkdownVersion {
        return try await innerAsStore.appendProcessedMarkdown(sourceID: sourceID, content: content, origin: origin, note: note, technique: technique)
    }

    @discardableResult
    func appendUserProcessedMarkdown(sourceID: SourceID, content: String, expectedHead: SourceMarkdownVersionID) async throws -> SourceMarkdownVersion {
        return try await innerAsStore.appendUserProcessedMarkdown(sourceID: sourceID, content: content, expectedHead: expectedHead)
    }

    @discardableResult
    func appendDerivedMarkdown(sourceID: SourceID, content: String, origin: SourceMarkdownOrigin, producer: ExtractionProducer?, providerID: ProviderID?, modelID: ModelID?, toolVersion: String?, sourceVersionID: SourceVersionID?, note: String?) async throws -> SourceMarkdownVersion {
        return try await innerAsStore.appendDerivedMarkdown(sourceID: sourceID, content: content, origin: origin, producer: producer, providerID: providerID, modelID: modelID, toolVersion: toolVersion, sourceVersionID: sourceVersionID, note: note)
    }

    @discardableResult
    func appendInstalledPackageMarkdown(sourceID: SourceID, content: String, package: ExtractionInstalledPackageProducer, origin: SourceMarkdownOrigin, toolVersion: String?, sourceVersionID: SourceVersionID?, note: String?) async throws -> SourceMarkdownVersion {
        return try await innerAsStore.appendInstalledPackageMarkdown(sourceID: sourceID, content: content, package: package, origin: origin, toolVersion: toolVersion, sourceVersionID: sourceVersionID, note: note)
    }

    @discardableResult
    func appendHostSpeechTranscript(sourceID: SourceID, content: String, producer: ExtractionHostSpeechProducer, sourceVersionID: SourceVersionID) async throws -> SourceMarkdownVersion {
        return try await innerAsStore.appendHostSpeechTranscript(sourceID: sourceID, content: content, producer: producer, sourceVersionID: sourceVersionID)
    }

    @discardableResult
    func revertProcessedMarkdown(sourceID: SourceID, to versionID: SourceMarkdownVersionID) async throws -> SourceMarkdownVersion {
        return try await innerAsStore.revertProcessedMarkdown(sourceID: sourceID, to: versionID)
    }

    @discardableResult
    func recordMarkdownExtraction(sourceID: SourceID, content: String, backend: ExtractionBackend, sourceVersionID: SourceVersionID?, note: String?, modelVersion: String?) async throws -> SourceMarkdownVersion {
        return try await innerAsStore.recordMarkdownExtraction(sourceID: sourceID, content: content, backend: backend, sourceVersionID: sourceVersionID, note: note, modelVersion: modelVersion)
    }

    func setActiveMarkdown(sourceID: SourceID, to versionID: SourceMarkdownVersionID) async throws {
        try await innerAsStore.setActiveMarkdown(sourceID: sourceID, to: versionID)
    }

    func appendPageVersion(pageID: PageID, title: String, body: String, expectedHeadVersionID: PageVersionID?, lastEditedBy: String?, provenance: [PageVersionSourceInput]) async throws -> PageVersionID {
        return try await innerAsStore.appendPageVersion(pageID: pageID, title: title, body: body, expectedHeadVersionID: expectedHeadVersionID, lastEditedBy: lastEditedBy, provenance: provenance)
    }

    func pageVersionSources(versionID: PageVersionID) async throws -> [PageVersionSource] {
        return try await innerAsStore.pageVersionSources(versionID: versionID)
    }

    func pageHeadSources(pageID: PageID) async throws -> [PageVersionSource] {
        return try await innerAsStore.pageHeadSources(pageID: pageID)
    }

    func sourceReferencingPageVersions(sourceID: SourceID) async throws -> [PageVersionID] {
        return try await innerAsStore.sourceReferencingPageVersions(sourceID: sourceID)
    }

    func pagesCitingSources(sourceIDs: [SourceID], limit: Int) async throws -> [CitedPage] {
        return try await innerAsStore.pagesCitingSources(sourceIDs: sourceIDs, limit: limit)
    }

    func extractionProvenance(markdownVersionID: SourceMarkdownVersionID) async throws -> ExtractionProvenance? {
        return try await innerAsStore.extractionProvenance(markdownVersionID: markdownVersionID)
    }

    func activeExtractionProvenance(sourceID: SourceID) async throws -> ExtractionProvenance? {
        return try await innerAsStore.activeExtractionProvenance(sourceID: sourceID)
    }

    func pageHeadVersionID(pageID: PageID) async throws -> PageVersionID? {
        return try await innerAsStore.pageHeadVersionID(pageID: pageID)
    }

    func pageVersionHistory(pageID: PageID) async throws -> [PageVersionSummary] {
        return try await innerAsStore.pageVersionHistory(pageID: pageID)
    }

    func pageOrigin(pageID: PageID) async throws -> PageOrigin? {
        return try await innerAsStore.pageOrigin(pageID: pageID)
    }

    func pageEditHistory(pageID: PageID) async throws -> [PageOrigin] {
        return try await innerAsStore.pageEditHistory(pageID: pageID)
    }

    func pageVersionBody(versionID: PageVersionID) async throws -> String? {
        return try await innerAsStore.pageVersionBody(versionID: versionID)
    }

    func pageOKFMetadata(versionID: PageVersionID, includeCorrected: Bool) async throws -> PageOKFTrustMetadata? {
        return try await innerAsStore.pageOKFMetadata(versionID: versionID, includeCorrected: includeCorrected)
    }

    func sourceMarkdownOKFMetadata(versionID: SourceMarkdownVersionID, includeCorrected: Bool) async throws -> SourceMarkdownOKFTrustMetadata? {
        return try await innerAsStore.sourceMarkdownOKFMetadata(versionID: versionID, includeCorrected: includeCorrected)
    }

    func setPageOKFStatus(versionID: PageVersionID, status: OKFConceptStatus?) async throws {
        try await innerAsStore.setPageOKFStatus(versionID: versionID, status: status)
    }

    func setSourceMarkdownOKFStatus(versionID: SourceMarkdownVersionID, status: OKFConceptStatus?) async throws {
        try await innerAsStore.setSourceMarkdownOKFStatus(versionID: versionID, status: status)
    }

    func setPageOKFFreshness(versionID: PageVersionID, policy: OKFFreshnessPolicy?) async throws {
        try await innerAsStore.setPageOKFFreshness(versionID: versionID, policy: policy)
    }

    func setSourceMarkdownOKFFreshness(versionID: SourceMarkdownVersionID, policy: OKFFreshnessPolicy?) async throws {
        try await innerAsStore.setSourceMarkdownOKFFreshness(versionID: versionID, policy: policy)
    }

    @discardableResult
    func recordPageOKFVerification(versionID: PageVersionID, verifier: OKFVerifierIdentity, verifiedAt: Date, basis: OKFVerificationBasis, freshnessPolicy: OKFFreshnessPolicy?) async throws -> OKFVerificationID {
        return try await innerAsStore.recordPageOKFVerification(versionID: versionID, verifier: verifier, verifiedAt: verifiedAt, basis: basis, freshnessPolicy: freshnessPolicy)
    }

    @discardableResult
    func recordSourceMarkdownOKFVerification(versionID: SourceMarkdownVersionID, verifier: OKFVerifierIdentity, verifiedAt: Date, basis: OKFVerificationBasis, freshnessPolicy: OKFFreshnessPolicy?) async throws -> OKFVerificationID {
        return try await innerAsStore.recordSourceMarkdownOKFVerification(versionID: versionID, verifier: verifier, verifiedAt: verifiedAt, basis: basis, freshnessPolicy: freshnessPolicy)
    }

    func correctPageOKFVerification(versionID: PageVersionID, verificationID: OKFVerificationID, correctingVerifier: OKFVerifierIdentity, correctedAt: Date, reason: OKFVerificationCorrectionReason?) async throws {
        try await innerAsStore.correctPageOKFVerification(versionID: versionID, verificationID: verificationID, correctingVerifier: correctingVerifier, correctedAt: correctedAt, reason: reason)
    }

    func correctSourceMarkdownOKFVerification(versionID: SourceMarkdownVersionID, verificationID: OKFVerificationID, correctingVerifier: OKFVerifierIdentity, correctedAt: Date, reason: OKFVerificationCorrectionReason?) async throws {
        try await innerAsStore.correctSourceMarkdownOKFVerification(versionID: versionID, verificationID: verificationID, correctingVerifier: correctingVerifier, correctedAt: correctedAt, reason: reason)
    }

    func revertPage(pageID: PageID, to versionID: PageVersionID) async throws {
        try await innerAsStore.revertPage(pageID: pageID, to: versionID)
    }

    @discardableResult
    func restorePage(pageID: PageID, to versionID: PageVersionID) async throws -> PageVersionID {
        return try await innerAsStore.restorePage(pageID: pageID, to: versionID)
    }

    func createWorkspace(name: String?, activityID: String?) async throws -> WorkspaceID {
        return try await innerAsStore.createWorkspace(name: name, activityID: activityID)
    }

    func workspaceSummary(id: WorkspaceID) async throws -> WorkspaceSummary? {
        return try await innerAsStore.workspaceSummary(id: id)
    }

    func workspaceRefs(workspaceID: WorkspaceID) async throws -> [WorkspaceRef] {
        return try await innerAsStore.workspaceRefs(workspaceID: workspaceID)
    }

    func workspaceWritePage(workspaceID: WorkspaceID, pageID: PageID, title: String, body: String, author: String?, provenance: [PageVersionSourceInput]) async throws -> PageVersionID? {
        return try await innerAsStore.workspaceWritePage(workspaceID: workspaceID, pageID: pageID, title: title, body: body, author: author, provenance: provenance)
    }

    func workspacePageVersion(workspaceID: WorkspaceID, pageID: PageID) async throws -> PageVersionID? {
        return try await innerAsStore.workspacePageVersion(workspaceID: workspaceID, pageID: pageID)
    }

    func workspacePageBody(workspaceID: WorkspaceID, pageID: PageID) async throws -> String? {
        return try await innerAsStore.workspacePageBody(workspaceID: workspaceID, pageID: pageID)
    }

    func setWorkspaceIndexBody(workspaceID: WorkspaceID, indexBody: String, indexBaseVersion: String) async throws {
        try await innerAsStore.setWorkspaceIndexBody(workspaceID: workspaceID, indexBody: indexBody, indexBaseVersion: indexBaseVersion)
    }

    @discardableResult
    func workspaceMerge(workspaceID: WorkspaceID) async throws -> [String] {
        return try await innerAsStore.workspaceMerge(workspaceID: workspaceID)
    }

    func abandonWorkspace(id: WorkspaceID) async throws {
        try await innerAsStore.abandonWorkspace(id: id)
    }

    func workspaceRefresh(workspaceID: WorkspaceID) async throws {
        try await innerAsStore.workspaceRefresh(workspaceID: workspaceID)
    }

    func workspaceConflicts(workspaceID: WorkspaceID) async throws -> [WorkspaceConflict] {
        return try await innerAsStore.workspaceConflicts(workspaceID: workspaceID)
    }

    func workspaceResolveConflict(workspaceID: WorkspaceID, pageID: PageID, body: String) async throws {
        try await innerAsStore.workspaceResolveConflict(workspaceID: workspaceID, pageID: pageID, body: body)
    }

    func workspaceRetryMerge(workspaceID: WorkspaceID) async throws {
        try await innerAsStore.workspaceRetryMerge(workspaceID: workspaceID)
    }

    func reapStaleWorkspaces(ttl: TimeInterval) async throws -> Int {
        return try await innerAsStore.reapStaleWorkspaces(ttl: ttl)
    }

    @discardableResult
    func appendLog(kind: LogEntry.Kind, title: String, note: String?) async throws -> LogEntry {
        return try await innerAsStore.appendLog(kind: kind, title: title, note: note)
    }

    func recentLogEntries(limit: Int) async throws -> [LogEntry] {
        return try await innerAsStore.recentLogEntries(limit: limit)
    }

    func getWikiIndex() async throws -> WikiIndex {
        return try await innerAsStore.getWikiIndex()
    }

    func updateWikiIndex(body: String) async throws {
        try await innerAsStore.updateWikiIndex(body: body)
    }

    func storePageChunks(id: PageID, chunks: [Data]) async throws {
        try await innerAsStore.storePageChunks(id: id, chunks: chunks)
    }

    func missingPageEmbeddingWork() async throws -> [(id: PageID, text: String)] {
        return try await innerAsStore.missingPageEmbeddingWork()
    }

    func searchSimilar(query: String, limit: Int, bm25Leg: [WikiPageSummary]?) async throws -> [WikiPageSummary] {
        return try await innerAsStore.searchSimilar(query: query, limit: limit, bm25Leg: bm25Leg)
    }

    func storeSourceChunks(id: SourceID, chunks: [Data]) async throws {
        try await innerAsStore.storeSourceChunks(id: id, chunks: chunks)
    }

    func missingSourceEmbeddingWork() async throws -> [(id: SourceID, text: String)] {
        return try await innerAsStore.missingSourceEmbeddingWork()
    }

    func searchSimilarSources(query: String, limit: Int, bm25Leg: [SourceSummary]?) async throws -> [SourceSummary] {
        return try await innerAsStore.searchSimilarSources(query: query, limit: limit, bm25Leg: bm25Leg)
    }

    func listBookmarkNodes() async throws -> [BookmarkNode] {
        return try await innerAsStore.listBookmarkNodes()
    }

    @discardableResult
    func createBookmarkNode(parentID: BookmarkID?, position: Int, content: BookmarkNode.Content) async throws -> BookmarkNode {
        return try await innerAsStore.createBookmarkNode(parentID: parentID, position: position, content: content)
    }

    func renameBookmarkFolder(id: BookmarkID, to label: String) async throws {
        try await innerAsStore.renameBookmarkFolder(id: id, to: label)
    }

    func retargetBookmarkNode(id: BookmarkID, to content: BookmarkNode.Content) async throws {
        try await innerAsStore.retargetBookmarkNode(id: id, to: content)
    }

    func deleteBookmarkNode(id: BookmarkID) async throws {
        try await innerAsStore.deleteBookmarkNode(id: id)
    }

    func moveBookmarkNode(id: BookmarkID, toParentID: BookmarkID?, position: Int) async throws {
        try await innerAsStore.moveBookmarkNode(id: id, toParentID: toParentID, position: position)
    }

    @discardableResult
    func createChat(kind: ChatKind, title: String) async throws -> ChatSummary {
        return try await innerAsStore.createChat(kind: kind, title: title)
    }

    @discardableResult
    func createChat(kind: ChatKind, title: String, modelProviderId: ProviderID?, modelId: ModelID?, configuredThinkingOptionID: ChatConfigurationValueID?, effectiveThinkingOptionID: ChatConfigurationValueID?) async throws -> ChatSummary {
        return try await innerAsStore.createChat(kind: kind, title: title, modelProviderId: modelProviderId, modelId: modelId, configuredThinkingOptionID: configuredThinkingOptionID, effectiveThinkingOptionID: effectiveThinkingOptionID)
    }

    @discardableResult
    func createChat(kind: ChatKind, title: String, attachments: [ChatAttachmentTarget]) async throws -> ChatSummary {
        return try await innerAsStore.createChat(kind: kind, title: title, attachments: attachments)
    }

    func chatAttachments(chatID: ChatID) async throws -> [ChatAttachmentTarget] {
        return try await innerAsStore.chatAttachments(chatID: chatID)
    }

    func setChatAttachments(chatID: ChatID, targets: [ChatAttachmentTarget]) async throws {
        try await innerAsStore.setChatAttachments(chatID: chatID, targets: targets)
    }

    @discardableResult
    func appendChatMessages(chatID: ChatID, events: [AgentEvent]) async throws -> [ChatMessage] {
        return try await innerAsStore.appendChatMessages(chatID: chatID, events: events)
    }

    func listChats() async throws -> [ChatSummary] {
        return try await innerAsStore.listChats()
    }

    func chatMessages(chatID: ChatID) async throws -> [ChatMessage] {
        return try await innerAsStore.chatMessages(chatID: chatID)
    }

    func renameChat(id: ChatID, to title: String) async throws {
        try await innerAsStore.renameChat(id: id, to: title)
    }

    @discardableResult
    func setChatTitleIfEmpty(chatID: ChatID, title: String) async throws -> Bool {
        return try await innerAsStore.setChatTitleIfEmpty(chatID: chatID, title: title)
    }

    @discardableResult
    func setChatTitleIf(chatID: ChatID, expectedTitle: String, title: String) async throws -> Bool {
        return try await innerAsStore.setChatTitleIf(chatID: chatID, expectedTitle: expectedTitle, title: title)
    }

    func deleteChat(id: ChatID) async throws {
        try await innerAsStore.deleteChat(id: id)
    }

    func updateChatAcpSessionId(chatID: ChatID, acpSessionId: AcpSessionID?) async throws {
        try await innerAsStore.updateChatAcpSessionId(chatID: chatID, acpSessionId: acpSessionId)
    }

    func updateChatModelOverride(id: ChatID, providerId: ProviderID?, modelId: ModelID?) async throws {
        try await innerAsStore.updateChatModelOverride(id: id, providerId: providerId, modelId: modelId)
    }

    func updateChatModelAndThinkingSelection(chatID: ChatID, providerID: ProviderID?, modelID: ModelID?, configuredThinkingID: ChatConfigurationValueID?, effectiveThinkingID: ChatConfigurationValueID?) async throws {
        try await innerAsStore.updateChatModelAndThinkingSelection(chatID: chatID, providerID: providerID, modelID: modelID, configuredThinkingID: configuredThinkingID, effectiveThinkingID: effectiveThinkingID)
    }

    func getChat(id: ChatID) async throws -> ChatSummary {
        return try await innerAsStore.getChat(id: id)
    }

    func updateMessageSummary(chatID: ChatID, cursor: ChatTranscriptCursor, summary: String, kind: ChatMessageSummaryKind) async throws {
        try await innerAsStore.updateMessageSummary(chatID: chatID, cursor: cursor, summary: summary, kind: kind)
    }

    func checkpointStreamingMessage(chatID: ChatID, handle: String, event: AgentEvent, isDraft: Bool) async throws {
        try await innerAsStore.checkpointStreamingMessage(chatID: chatID, handle: handle, event: event, isDraft: isDraft)
    }

    func finalizeStaleDrafts(forChat chatID: ChatID) async throws {
        try await innerAsStore.finalizeStaleDrafts(forChat: chatID)
    }

    @discardableResult
    func enqueuePersistedChatTurn(chatID: ChatID, submission: ChatTurnSubmission) async throws -> PersistedChatTurn {
        return try await innerAsStore.enqueuePersistedChatTurn(chatID: chatID, submission: submission)
    }

    func listPersistedChatTurns(chatID: ChatID) async throws -> [PersistedChatTurn] {
        return try await innerAsStore.listPersistedChatTurns(chatID: chatID)
    }

    @discardableResult
    func editPersistedChatTurn(chatID: ChatID, turnID: ChatTurnID, userText: String, contextReferences: [ChatContextReference], editedAt: Date) async throws -> PersistedChatTurn {
        return try await innerAsStore.editPersistedChatTurn(chatID: chatID, turnID: turnID, userText: userText, contextReferences: contextReferences, editedAt: editedAt)
    }

    @discardableResult
    func removePersistedQueuedChatTurn(chatID: ChatID, turnID: ChatTurnID) async throws -> Bool {
        return try await innerAsStore.removePersistedQueuedChatTurn(chatID: chatID, turnID: turnID)
    }

    @discardableResult
    func cancelUnclaimedPersistedChatTurn(chatID: ChatID, turnID: ChatTurnID) async throws -> PersistedChatTurn? {
        return try await innerAsStore.cancelUnclaimedPersistedChatTurn(chatID: chatID, turnID: turnID)
    }

    @discardableResult
    func claimNextPersistedChatTurn(chatID: ChatID, claimID: ChatTurnClaimID, claimedAt: Date) async throws -> PersistedChatTurn? {
        return try await innerAsStore.claimNextPersistedChatTurn(chatID: chatID, claimID: claimID, claimedAt: claimedAt)
    }

    @discardableResult
    func claimNextPersistedChatTurn(chatID: ChatID, claimID: ChatTurnClaimID, claimedAt: Date, providerID: ProviderID?, modelID: ModelID?) async throws -> PersistedChatTurn? {
        return try await innerAsStore.claimNextPersistedChatTurn(chatID: chatID, claimID: claimID, claimedAt: claimedAt, providerID: providerID, modelID: modelID)
    }

    @discardableResult
    func markPersistedChatTurnProviderSubmitted(chatID: ChatID, turnID: ChatTurnID, claimID: ChatTurnClaimID, providerSessionID: AcpSessionID?, submittedAt: Date) async throws -> PersistedChatTurn {
        return try await innerAsStore.markPersistedChatTurnProviderSubmitted(chatID: chatID, turnID: turnID, claimID: claimID, providerSessionID: providerSessionID, submittedAt: submittedAt)
    }

    @discardableResult
    func finishPersistedChatTurn(chatID: ChatID, turnID: ChatTurnID, claimID: ChatTurnClaimID, state: ChatTurnPersistenceState, terminalMessage: String?) async throws -> PersistedChatTurn {
        return try await innerAsStore.finishPersistedChatTurn(chatID: chatID, turnID: turnID, claimID: claimID, state: state, terminalMessage: terminalMessage)
    }

    @discardableResult
    func finishPersistedChatTurn(chatID: ChatID, turnID: ChatTurnID, claimID: ChatTurnClaimID, state: ChatTurnPersistenceState, terminalMessage: String?, finishedAt: Date, usage: ChatTurnUsageValues?) async throws -> PersistedChatTurn {
        return try await innerAsStore.finishPersistedChatTurn(chatID: chatID, turnID: turnID, claimID: claimID, state: state, terminalMessage: terminalMessage, finishedAt: finishedAt, usage: usage)
    }

    func chatTurnUsage(chatID: ChatID, turnID: ChatTurnID) async throws -> ChatTurnUsage? {
        return try await innerAsStore.chatTurnUsage(chatID: chatID, turnID: turnID)
    }

    func latestChatTurnUsage(chatID: ChatID) async throws -> ChatTurnUsage? {
        return try await innerAsStore.latestChatTurnUsage(chatID: chatID)
    }

    func chatUsageSummary(chatID: ChatID) async throws -> ChatUsageSummary {
        return try await innerAsStore.chatUsageSummary(chatID: chatID)
    }

    @discardableResult
    func updatePersistedChatTurnUsage(chatID: ChatID, turnID: ChatTurnID, claimID: ChatTurnClaimID, usage: ChatTurnUsageValues) async throws -> PersistedChatTurn {
        return try await innerAsStore.updatePersistedChatTurnUsage(chatID: chatID, turnID: turnID, claimID: claimID, usage: usage)
    }

    @discardableResult
    func appendChatTranscriptItems(chatID: ChatID, items: [ChatTranscriptItem]) async throws -> [PersistedChatTranscriptItem] {
        return try await innerAsStore.appendChatTranscriptItems(chatID: chatID, items: items)
    }

    func readChatTranscriptPage(chatID: ChatID, after cursor: ChatTranscriptCursor?, limit: Int) async throws -> ChatTranscriptPage {
        return try await innerAsStore.readChatTranscriptPage(chatID: chatID, after: cursor, limit: limit)
    }

    func chatTranscriptCheckpoint(chatID: ChatID) async throws -> ChatTranscriptCursor {
        return try await innerAsStore.chatTranscriptCheckpoint(chatID: chatID)
    }

    func listAllChatsOrderedByID() async throws -> [ChatSummary] {
        return try await innerAsStore.listAllChatsOrderedByID()
    }

    func resolveChatByTitle(_ title: String) async throws -> ChatID? {
        return try await innerAsStore.resolveChatByTitle(title)
    }

    func storeChatChunks(id: ChatID, chunks: [Data]) async throws {
        try await innerAsStore.storeChatChunks(id: id, chunks: chunks)
    }

    func missingChatEmbeddingWork() async throws -> [(id: ChatID, text: String)] {
        return try await innerAsStore.missingChatEmbeddingWork()
    }

    func searchSimilarChats(query: String, limit: Int, bm25Leg: [ChatSummary]?) async throws -> [ChatSummary] {
        return try await innerAsStore.searchSimilarChats(query: query, limit: limit, bm25Leg: bm25Leg)
    }

    @discardableResult
    func vacuumBlobs(dryRun: Bool) async throws -> BlobVacuumReport {
        return try await innerAsStore.vacuumBlobs(dryRun: dryRun)
    }

    @discardableResult
    func repairMIME(dryRun: Bool) async throws -> MIMERepairReport {
        return try await innerAsStore.repairMIME(dryRun: dryRun)
    }

    @discardableResult
    func vacuumActivities(dryRun: Bool) async throws -> ActivityVacuumReport {
        return try await innerAsStore.vacuumActivities(dryRun: dryRun)
    }

    @discardableResult
    func vacuumPageVersions(dryRun: Bool) async throws -> PageVersionVacuumReport {
        return try await innerAsStore.vacuumPageVersions(dryRun: dryRun)
    }

    func getMetadata(_ key: String) async throws -> String? {
        return try await innerAsStore.getMetadata(key)
    }

    func setMetadata(_ key: String, value: String) async throws {
        try await innerAsStore.setMetadata(key, value: value)
    }


}
#endif // os(macOS)
