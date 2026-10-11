#if os(macOS)
import Foundation
import Synchronization
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFSEngine
@testable import wikid
@testable import WikiFS

/// AC.4 + AC.7: BOTH process hosts route the `application/zotero` source
/// MIME through the same package FETCHER adapter, and a completed
/// acquisition becomes source content:
///
/// - A `source-bytes` result (PDF) stores the blob with the real MIME/ext/
///   byte size, populates the retained `external_item_key`/
///   `external_item_title` columns from `articleMetadata`, and the follow-on
///   format route is enqueued under its typed dedupe key.
/// - A `markdown` result appends a package-provenance Markdown version
///   (podcast-shaped) and still populates the provenance columns.
///
/// The managed executor is faked, so this exercises the REAL provider arms
/// (route decision, prepared-fetcher execution, provenance, persistence,
/// follow-on enqueue) without `uv` or Zotero's network.
@MainActor
@Suite("Zotero queue extraction providers", .timeLimit(.minutes(2)))
struct ZoteroQueueExtractionProviderTests {

    private static let zoteroPackage = ReviewedExtractorPackages.zotero
    private static let fileURL = "https://api.zotero.org/users/12345/items/ABCD1234/file"

    /// The claimed input MIME fixture: `application/zotero`, guaranteed
    /// constructible without a throwing context (snapshots are non-throwing).
    nonisolated private static let claimedInputMIME: ExtractorMIMEType = {
        guard let mime = ExtractorMIMEType(rawValue: ContentTypeRegistry.zoteroAttachment) else {
            preconditionFailure("application/zotero is a valid extractor MIME type")
        }
        return mime
    }()

    // MARK: - Fixtures

    /// Writes the configured bytes at the requested output path and answers
    /// with a revision-5 typed fetch-result frame; records the fetch request.
    private final class FakeZoteroExecutor: ManagedProcessExecuting, @unchecked Sendable {
        let outputBytes: Data
        let resultMIMEType: ExtractorMIMEType?
        let identifier: String?
        private(set) var lastRequest: ExtractorFetchRequest?

        init(
            outputBytes: Data,
            resultMIMEType: ExtractorMIMEType?,
            identifier: String?
        ) {
            self.outputBytes = outputBytes
            self.resultMIMEType = resultMIMEType
            self.identifier = identifier
        }

        func execute(
            _ operation: ManagedExtractorProcessRequest,
            onFrame: @escaping @Sendable (ExtractorProtocolFrame) -> Void
        ) async throws -> ManagedExtractorProcessResult {
            guard case .fetch(let request) = operation.request else {
                throw ExtractionServicesError.unavailable
            }
            lastRequest = request
            let output = operation.paths.operationRoot
                .appendingPathComponent(request.outputPath.rawValue)
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try outputBytes.write(to: output)
            let articleMetadata = try ExtractorArticleMetadata(
                title: "A Study of Extraction",
                author: "Doe, J.",
                published: "2024-05-01",
                identifier: identifier)
            let frame = ExtractorProtocolFrame.result(try ExtractorResultFrame(
                requestID: request.requestID,
                outputPath: request.outputPath,
                markdownByteCount: outputBytes.count,
                metadata: ExtractorReportedMetadata(toolName: "zotero"),
                articleMetadata: articleMetadata,
                resultMIMEType: resultMIMEType,
                resultType: resultMIMEType == nil ? .markdown : .sourceBytes,
                originalFilename: resultMIMEType == nil ? nil : "ABCD1234.bin"))
            return ManagedExtractorProcessResult(
                terminationCause: .exited(code: 0),
                terminalFrame: frame,
                progressEventCount: 2,
                standardOutputByteCount: 0,
                standardError: Data(),
                executableURL: operation.paths.packageRoot)
        }
    }

    private static func manifest() throws -> ExtractorManifest {
        let json = """
        {
          "manifestRevision": 4,
          "packageID": "org.selfdrivingwiki.zotero",
          "version": "1.0.0",
          "displayName": "Zotero Attachment",
          "protocolRevision": 5,
          "entryPoint": "bin/zotero-extractor",
          "launch": {"mode": "runtime", "command": "uv", "arguments": ["run", "--script"]},
          "registrations": [
            {
              "id": "attachment",
              "displayName": "Zotero Attachment",
              "role": "fetcher",
              "kinds": [],
              "mimeTypes": ["application/zotero"],
              "credentialRequirements": [
                {
                  "id": "zotero-api-key",
                  "kind": "secret",
                  "optional": false,
                  "label": "Zotero API Key",
                  "purpose": "Read your Zotero library and download attachment files."
                }
              ]
            }
          ],
          "capabilities": ["network"],
          "files": [
            {
              "path": "bin/zotero-extractor",
              "digest": "0000000000000000000000000000000000000000000000000000000000000000"
            }
          ],
          "limits": {
            "maximumInputByteCount": 1048576,
            "maximumMarkdownOutputByteCount": 134217728,
            "maximumDurationMilliseconds": 600000,
            "maximumProgressEventCount": 64
          }
        }
        """
        return try JSONDecoder().decode(ExtractorManifest.self, from: Data(json.utf8))
    }

    /// Builds one prepared Zotero fetcher operation over a real (empty)
    /// operation directory tree and registers it in a fresh extraction
    /// registry under the kind-free fetcher namespace.
    private func makeServices(
        executor: FakeZoteroExecutor,
        formatRoutePreparation: ExtractionPreparation? = nil
    ) async throws -> any ExtractionServices {
        let revision = Self.zoteroPackage.revision
        let manifest = try Self.manifest()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikifs-zotero-queue-\(UUID().uuidString)", isDirectory: true)
        for sub in ["", "input", "output", "home", "tmp", "cache"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let registrationID = try ExtractorRegistrationID(validating: "attachment")
        let registration = try ExtractorRegistration(
            id: registrationID,
            displayName: "Zotero Attachment",
            kinds: [],
            mimeTypes: [try ExtractorMIMEType(validating: ContentTypeRegistry.zoteroAttachment)],
            filenameExtensions: [],
            role: .fetcher)
        let operation = PreparedProcessOperation(
            directoryRoot: root,
            packageRoot: root.appendingPathComponent("package", isDirectory: true),
            homeRoot: root.appendingPathComponent("home", isDirectory: true),
            temporaryRoot: root.appendingPathComponent("tmp", isDirectory: true),
            cacheRoot: root.appendingPathComponent("cache", isDirectory: true),
            sharedRuntimeCacheRoot: nil,
            sharedModelCacheRoot: nil,
            revision: revision,
            manifest: manifest,
            registration: registration,
            registrationID: registrationID,
            protocolRevision: .v5,
            mimeTypes: [ContentTypeRegistry.zoteroAttachment],
            executor: executor,
            launchGate: nil,
            operationCredentials: nil,
            operationConfiguration: nil,
            runtimeResolution: nil)

        let registry = ExtractionBackendRegistry()
        let reference = ExtractorReference(revision: revision, registrationID: registrationID)
        let adapterKey = ExtractionAdapterKey.installedFetcher(reference: reference)
        _ = try await registry.register(
            RegisteredExtractionBackend(
                key: ExtractionBackendKey(kind: .pdf, backendID: "placeholder")
            ) {
                .fetcher(ProcessPackageFetcher(operation: operation))
            },
            key: adapterKey)
        return StubZoteroExtractionServices(
            registry: registry,
            adapterKey: adapterKey,
            reference: reference,
            formatRoutePreparation: formatRoutePreparation)
    }

    /// Only the fetcher prepare seam and the active-claims snapshot are
    /// overridden; everything else inherits the protocol defaults
    /// (unavailable), which the fetch arm never calls.
    /// `formatRoutePreparation`, when set, is what the bytes (format) route's
    /// `prepare` returns instead of throwing unavailable.
    private struct StubZoteroExtractionServices: ExtractionServices {
        let registry: ExtractionBackendRegistry
        let adapterKey: ExtractionAdapterKey
        let reference: ExtractorReference
        var formatRoutePreparation: ExtractionPreparation?

        func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation {
            guard let formatRoutePreparation else {
                throw ExtractionServicesError.unavailable
            }
            return formatRoutePreparation
        }

        func prepareFetcher(sourceMIMEType: ExtractorMIMEType) async throws -> ProcessPackageFetcher {
            // Resolve through the registry exactly like the process facade.
            guard let backend = await registry.resolve(adapterKey) else {
                throw ExtractionServicesError.unavailable
            }
            let adapter = try await backend.make()
            guard case .fetcher(let prepared) = adapter else {
                throw ExtractionServicesError.unavailable
            }
            return prepared
        }

        func registeredExtractionInputs() async -> RegisteredExtractionInputs {
            .none
        }

        /// The fetch route decision reads the active fetcher claims, so the
        /// stub reports exactly this registration: role fetcher, claiming
        /// the synthetic `application/zotero` source MIME.
        func activeRegistrationSnapshots() async -> [ExtractorRouteRegistrationSnapshot] {
            [
                ExtractorRouteRegistrationSnapshot(
                    reference: reference,
                    displayName: "Zotero Attachment",
                    packageName: "Zotero",
                    role: .fetcher,
                    kinds: [],
                    mimeTypes: [ZoteroQueueExtractionProviderTests.claimedInputMIME],
                    filenameExtensions: [])
            ]
        }
    }

    private func makeStore() throws -> GRDBWikiStore {
        try TestStoreFactory.inMemory()
    }

    /// Seeds one byteless zotero source (the sync command's output shape).
    private func seedZoteroSource(_ store: GRDBWikiStore) throws -> SourceID {
        let summary = try store.addBytelessSource(
            filename: "ABCD1234",
            mimeType: ContentTypeRegistry.zoteroAttachment,
            provenance: SourceProvenance(
                agentName: SourceProvider.zotero.rawValue,
                activityKind: "fetch",
                plan: Self.fileURL,
                externalRef: Self.fileURL,
                externalIdentity: "ABCD1234"),
            role: .primary)
        return summary.id
    }

    private func makeFollowOnQueueStore() throws -> (QueueStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zotero-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("queue.sqlite")
        return (try QueueStore(databaseURL: url), url)
    }

    /// The typed dedupe key for one acquired fetch — the same construction
    /// the worker and the recovery scan use.
    private func followOnDedupeKey(
        wikiID: WikiID, sourceID: SourceID, acquiredContentVersionID: SourceVersionID
    ) -> QueueItemDedupeKey {
        .followOnFormatExtraction(
            wikiID: wikiID,
            sourceID: sourceID,
            acquiredContentVersionID: acquiredContentVersionID)
    }

    // MARK: - source-bytes result (AC.7 pdf variant)

    @Test func appProviderBytesResultStoresBlobAndProvenanceAndEnqueuesFollowOn() async throws {
        let store = try makeStore()
        let sourceID = try seedZoteroSource(store)
        let pdfBytes = Data("%PDF-1.4 fixture bytes".utf8)
        let executor = FakeZoteroExecutor(
            outputBytes: pdfBytes,
            resultMIMEType: try ExtractorMIMEType(validating: "application/pdf"),
            identifier: "PARENT01")

        let (queueStore, queueURL) = try makeFollowOnQueueStore()
        defer { queueStore.close() }
        let box = SessionLookupBox()
        box.setLookup { _ in WikiStoreModel(store: store) }
        let provider = AppQueueExtractionProvider(
            extractionServices: try await makeServices(executor: executor),
            sessionBox: box,
            queueDatabaseURL: queueURL)

        // Resolution runs the fetch arm with the stored file URL, revision-5.
        let resolution = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID, backendOverride: nil, transcriptionIntent: nil)
        guard case .fetch(let fetcher)? = resolution else {
            Issue.record("expected a fetch resolution")
            return
        }
        #expect(fetcher.producer.revision == Self.zoteroPackage.revision)
        #expect(fetcher.producer.protocolRevision == .v5)
        let outcome = try await fetcher.fetch { _ in }
        #expect(executor.lastRequest?.remoteURL.rawValue == Self.fileURL)
        #expect(executor.lastRequest?.mimeType == Self.claimedInputMIME)
        #expect(executor.lastRequest?.originalFilename == "ABCD1234")
        #expect(executor.lastRequest?.protocolRevision == .v5)
        guard case .sourceBytes(let bytesOutcome) = outcome else {
            Issue.record("expected a source-bytes fetch outcome")
            return
        }
        #expect(bytesOutcome.bytes == pdfBytes)
        #expect(bytesOutcome.mimeType.rawValue == "application/pdf")
        #expect(bytesOutcome.articleMetadata?.identifier == "PARENT01")

        // Persistence: the blob IS the source content; the retained external
        // provenance columns and the display name come from articleMetadata.
        let reference = try await provider.persistFetch(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            resolution: fetcher, outcome: outcome)
        #expect(reference != nil)

        let summary = try #require(try store.listSources().first(where: { $0.id == sourceID }))
        #expect(summary.byteSize == pdfBytes.count)
        #expect(summary.mimeType == "application/pdf")
        #expect(summary.ext == "pdf")
        #expect(summary.externalItemKey == "PARENT01")
        #expect(summary.externalItemTitle == "A Study of Extraction")
        #expect(summary.effectiveName == "A Study of Extraction")
        let bytes = try store.sourceContent(id: sourceID)
        #expect(bytes == pdfBytes)

        // The follow-on format route is enqueued for a bytes result, scoped
        // to the acquired content version under the typed dedupe key.
        let acquiredVersionID = SourceVersionID(
            rawValue: try #require(reference?.versionID))
        try await provider.enqueueFollowOnExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            acquiredContentVersionID: acquiredVersionID,
            dedupeKey: followOnDedupeKey(
                wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
                acquiredContentVersionID: acquiredVersionID))
        let active = try queueStore.loadActive(for: .extraction)
        #expect(active.count == 1)
        #expect(active.first?.payload.sourceIDs == [sourceID])
    }

    // MARK: - Markdown result

    @Test func appProviderMarkdownResultAppendsPackageMarkdownAndProvenance() async throws {
        let store = try makeStore()
        let sourceID = try seedZoteroSource(store)
        let markdown = Data("# Converted notes\n".utf8)
        let executor = FakeZoteroExecutor(
            outputBytes: markdown,
            resultMIMEType: nil, // no resultMIMEType: the output IS the Markdown
            identifier: "PARENT02")

        let box = SessionLookupBox()
        box.setLookup { _ in WikiStoreModel(store: store) }
        let provider = AppQueueExtractionProvider(
            extractionServices: try await makeServices(executor: executor),
            sessionBox: box)

        guard case .fetch(let fetcher)? = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID, backendOverride: nil, transcriptionIntent: nil) else {
            Issue.record("expected a fetch resolution")
            return
        }
        let outcome = try await fetcher.fetch { _ in }
        guard case .markdown(let markdownOutcome) = outcome else {
            Issue.record("expected a markdown fetch outcome")
            return
        }
        #expect(markdownOutcome.markdown == String(decoding: markdown, as: UTF8.self))

        let reference = try await provider.persistFetch(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            resolution: fetcher, outcome: outcome)
        #expect(reference != nil)

        let head = try #require(try store.processedMarkdownHead(sourceID: sourceID))
        #expect(head.content == String(decoding: markdown, as: UTF8.self))
        let summary = try #require(try store.listSources().first(where: { $0.id == sourceID }))
        #expect(summary.externalItemKey == "PARENT02")
        #expect(summary.externalItemTitle == "A Study of Extraction")
        #expect(summary.effectiveName == "A Study of Extraction")
    }

    // MARK: - Daemon provider

    @Test func daemonProviderBytesResultStoresBlobAndProvenance() async throws {
        let store = try makeStore()
        let sourceID = try seedZoteroSource(store)
        let pdfBytes = Data("%PDF-1.4 daemon fixture".utf8)
        let executor = FakeZoteroExecutor(
            outputBytes: pdfBytes,
            resultMIMEType: try ExtractorMIMEType(validating: "application/pdf"),
            identifier: "PARENT03")

        let (queueStore, _) = try makeFollowOnQueueStore()
        defer { queueStore.close() }
        let provider = DaemonQueueExtractionProvider(
            extractionServices: try await makeServices(executor: executor),
            storeResolver: { _ in store },
            queueStore: queueStore)

        guard case .fetch(let fetcher)? = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID, backendOverride: nil, transcriptionIntent: nil) else {
            Issue.record("expected a fetch resolution")
            return
        }
        let outcome = try await fetcher.fetch { _ in }
        #expect(executor.lastRequest?.protocolRevision == .v5)
        let reference = try await provider.persistFetch(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            resolution: fetcher, outcome: outcome)

        let summary = try #require(try store.listSources().first(where: { $0.id == sourceID }))
        #expect(summary.byteSize == pdfBytes.count)
        #expect(summary.mimeType == "application/pdf")
        #expect(summary.externalItemKey == "PARENT03")
        let bytes = try store.sourceContent(id: sourceID)
        #expect(bytes == pdfBytes)

        // The daemon's enqueue seam writes the durable follow-on item.
        let acquiredVersionID = SourceVersionID(
            rawValue: try #require(reference?.versionID))
        try await provider.enqueueFollowOnExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            acquiredContentVersionID: acquiredVersionID,
            dedupeKey: followOnDedupeKey(
                wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
                acquiredContentVersionID: acquiredVersionID))
        let active = try queueStore.loadActive(for: .extraction)
        #expect(active.count == 1)
    }

    // MARK: - Acquisition runs once (regression: follow-on re-fetch loop)

    /// Satisfies the format route's `prepare` seam. The regression tests
    /// assert on the resolution, never on a conversion, so the extractor is
    /// inert beyond being a real handle.
    private struct FakeFormatRouteExtractor: MarkdownExtractor {
        var displayName: String { "Fake format route" }

        func readiness() async -> ExtractionReadiness { .ready }

        func convert(
            pdfData: Data,
            filename: String,
            onProgress: (@Sendable (String) -> Void)?
        ) async throws -> String {
            "# Fake format-route markdown\n"
        }
    }

    private static let formatRoutePreparation = ExtractionPreparation(
        extractor: FakeFormatRouteExtractor(),
        backend: .localPdf2md,
        modelVersion: nil)

    /// Once a bytes result has landed, the source must resolve through the
    /// bytes (format) route — never another acquisition. The follow-on item a
    /// bytes result enqueues relies on this; before the guard it resolved as
    /// a fetch again and re-fetched the same attachment forever
    /// (observed live: one PDF re-acquired 200+ times, one queue item per
    /// fetch, no markdown ever produced).
    @Test func appProviderAcquiredBytesResolveThroughFormatRoute() async throws {
        let store = try makeStore()
        let sourceID = try seedZoteroSource(store)
        let pdfBytes = Data("%PDF-1.4 fixture bytes".utf8)
        let executor = FakeZoteroExecutor(
            outputBytes: pdfBytes,
            resultMIMEType: try ExtractorMIMEType(validating: "application/pdf"),
            identifier: "PARENT10")
        let box = SessionLookupBox()
        box.setLookup { _ in WikiStoreModel(store: store) }
        let provider = AppQueueExtractionProvider(
            extractionServices: try await makeServices(
                executor: executor,
                formatRoutePreparation: Self.formatRoutePreparation),
            sessionBox: box)

        // First resolution (byteless source): the acquisition arm.
        guard case .fetch(let fetcher)? = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID, backendOverride: nil, transcriptionIntent: nil) else {
            Issue.record("expected a fetch resolution")
            return
        }
        let outcome = try await fetcher.fetch { _ in }
        _ = try await provider.persistFetch(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            resolution: fetcher, outcome: outcome)

        // Second resolution (the follow-on format-route item): the acquired
        // bytes route the host's own format path, not another acquisition.
        guard case .bytes(let bytes)? = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID, backendOverride: nil, transcriptionIntent: nil) else {
            Issue.record("expected a bytes (format-route) resolution after acquisition")
            return
        }
        #expect(bytes.sourceBytes == pdfBytes)
        #expect(bytes.backend == ExtractionBackend.localPdf2md)
    }

    /// The daemon host runs the same follow-on; the same invariant holds.
    @Test func daemonProviderAcquiredBytesResolveThroughFormatRoute() async throws {
        let store = try makeStore()
        let sourceID = try seedZoteroSource(store)
        let pdfBytes = Data("%PDF-1.4 daemon fixture".utf8)
        let executor = FakeZoteroExecutor(
            outputBytes: pdfBytes,
            resultMIMEType: try ExtractorMIMEType(validating: "application/pdf"),
            identifier: "PARENT11")
        let provider = DaemonQueueExtractionProvider(
            extractionServices: try await makeServices(
                executor: executor,
                formatRoutePreparation: Self.formatRoutePreparation),
            storeResolver: { _ in store })

        guard case .fetch(let fetcher)? = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID, backendOverride: nil, transcriptionIntent: nil) else {
            Issue.record("expected a fetch resolution")
            return
        }
        let outcome = try await fetcher.fetch { _ in }
        try await provider.persistFetch(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            resolution: fetcher, outcome: outcome)

        guard case .bytes(let bytes)? = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID, backendOverride: nil, transcriptionIntent: nil) else {
            Issue.record("expected a bytes (format-route) resolution after acquisition")
            return
        }
        #expect(bytes.sourceBytes == pdfBytes)
    }

    // MARK: - Engine wakeup (Tier 1 Phase 4)

    /// With the engine-enqueue seam injected, a follow-on format route goes
    /// THROUGH the engine — the closure receives the request (and the
    /// engine's dispatch scan runs) without needing any other engine event.
    /// The store-only fallback is not used.
    @Test func followOnEnqueueWakesTheEngineWhenTheSeamIsInjected() async throws {
        let executor = FakeZoteroExecutor(
            outputBytes: Data("%PDF-1.4\n".utf8),
            resultMIMEType: try ExtractorMIMEType(validating: "application/pdf"),
            identifier: "WAKE01")
        let (queueStore, _) = try makeFollowOnQueueStore()
        defer { queueStore.close() }

        let recorded = Mutex<[QueueItemRequest]>([])
        let provider = DaemonQueueExtractionProvider(
            extractionServices: try await makeServices(executor: executor),
            storeResolver: { _ in nil },
            queueStore: queueStore,
            engineEnqueue: { request in
                var seen = recorded.withLock { $0 }
                seen.append(request)
                recorded.withLock { $0 = seen }
                return QueueItemID(rawValue: "01JWAKEDINSERT00000000000")
            })

        let sourceID = SourceID(rawValue: "01JWAKESOURCE00000000000")
        let acquiredVersionID = SourceVersionID(rawValue: "01JWAKEVERSION00000000000")
        let dedupeKey = followOnDedupeKey(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            acquiredContentVersionID: acquiredVersionID)
        try await provider.enqueueFollowOnExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            acquiredContentVersionID: acquiredVersionID,
            dedupeKey: dedupeKey)

        let requests = recorded.withLock { $0 }
        #expect(requests.count == 1)
        #expect(requests.first?.queue == QueueKind.extraction)
        #expect(requests.first?.wikiID == WikiID(rawValue: "w"))
        #expect(requests.first?.payload.sourceIDs == [sourceID])
        #expect(requests.first?.dedupeKey == dedupeKey)
        // The engine route means the bare store row was never written.
        #expect(try queueStore.loadActive(for: .extraction).isEmpty)
    }
}
#endif
