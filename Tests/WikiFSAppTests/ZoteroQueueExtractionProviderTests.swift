#if os(macOS)
import Foundation
import Testing
import WikiFSCore
import WikiFSTypes
@testable import WikiFSEngine
@testable import wikid
@testable import WikiFS

/// AC.4 + AC.7: BOTH process hosts route `.zotero` through the same package
/// adapter, and a completed acquisition becomes source content:
///
/// - A bytes result (PDF) stores the blob with the real MIME/ext/byte size,
///   populates the retained `zotero_item_key`/`zotero_item_title` columns
///   from `articleMetadata`, and enqueues the follow-on format route.
/// - A Markdown result appends a package-provenance Markdown version
///   (podcast-shaped) and still populates the provenance columns.
///
/// The managed executor is faked, so this exercises the REAL provider arms
/// (URL resolution, prepared-operation execution, provenance, persistence,
/// follow-on enqueue) without `uv` or Zotero's network.
@MainActor
@Suite("Zotero queue extraction providers", .timeLimit(.minutes(2)))
struct ZoteroQueueExtractionProviderTests {

    private static let zoteroPackage = ReviewedExtractorPackages.zotero
    private static let fileURL = "https://api.zotero.org/users/12345/items/ABCD1234/file"

    // MARK: - Fixtures

    /// Writes the configured bytes at the requested output path and answers
    /// with a revision-4 result frame; records the protocol request.
    private final class FakeZoteroExecutor: ManagedProcessExecuting, @unchecked Sendable {
        let outputBytes: Data
        let resultMIMEType: ExtractorMIMEType?
        let identifier: String?
        private(set) var lastRequest: ExtractorProtocolRequest?

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
            lastRequest = operation.protocolRequest
            let output = operation.paths.operationRoot
                .appendingPathComponent(operation.protocolRequest.outputPath.rawValue)
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try outputBytes.write(to: output)
            let articleMetadata = try ExtractorArticleMetadata(
                title: "A Study of Extraction",
                author: "Doe, J.",
                published: "2024-05-01",
                identifier: identifier)
            let frame = ExtractorProtocolFrame.result(try ExtractorResultFrame(
                requestID: operation.protocolRequest.requestID,
                outputPath: operation.protocolRequest.outputPath,
                markdownByteCount: outputBytes.count,
                metadata: ExtractorReportedMetadata(toolName: "zotero"),
                articleMetadata: articleMetadata,
                resultMIMEType: resultMIMEType))
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
          "manifestRevision": 2,
          "packageID": "org.selfdrivingwiki.zotero",
          "version": "1.0.0",
          "displayName": "Zotero Attachment",
          "protocolRevision": 4,
          "entryPoint": "bin/zotero-extractor",
          "launch": {"mode": "runtime", "command": "uv", "arguments": ["run", "--script"]},
          "registrations": [
            {
              "id": "attachment",
              "displayName": "Zotero Attachment",
              "kinds": ["zotero"],
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

    /// Builds one prepared Zotero operation over a real (empty) operation
    /// directory tree and registers it in a fresh extraction registry.
    private func makeServices(executor: FakeZoteroExecutor) async throws -> any ExtractionServices {
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
            kinds: [.zotero],
            mimeTypes: [try ExtractorMIMEType(validating: ContentTypeRegistry.zoteroAttachment)],
            filenameExtensions: [])
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
            protocolRevision: .v4,
            mimeTypes: [ContentTypeRegistry.zoteroAttachment],
            executor: executor,
            launchGate: nil,
            operationCredentials: nil,
            operationConfiguration: nil,
            runtimeResolution: nil)

        let registry = ExtractionBackendRegistry()
        let reference = ExtractorReference(revision: revision, registrationID: registrationID)
        let adapterKey = ExtractionAdapterKey.installed(kind: .zotero, reference: reference)
        _ = try await registry.register(
            RegisteredExtractionBackend(
                key: ExtractionBackendKey(kind: .zotero, backendID: "placeholder")
            ) {
                .zotero(ProcessPackageZoteroAttachment(operation: operation))
            },
            key: adapterKey)
        return StubZoteroExtractionServices(registry: registry, adapterKey: adapterKey)
    }

    /// Only the Zotero prepare seam is overridden; everything else inherits
    /// the protocol defaults (unavailable), which the zotero arm never calls.
    private struct StubZoteroExtractionServices: ExtractionServices {
        let registry: ExtractionBackendRegistry
        let adapterKey: ExtractionAdapterKey

        func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation {
            throw ExtractionServicesError.unavailable
        }

        func prepareZoteroAttachment() async throws -> ProcessPackageZoteroAttachment {
            // Resolve through the registry exactly like the process facade.
            guard let backend = await registry.resolve(adapterKey) else {
                throw ExtractionServicesError.unavailable
            }
            let adapter = try await backend.make()
            guard case .zotero(let prepared) = adapter else {
                throw ExtractionServicesError.unavailable
            }
            return prepared
        }

        func registeredExtractionInputs() async -> RegisteredExtractionInputs {
            .none
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

    // MARK: - Bytes result (AC.7 pdf variant)

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

        // Resolution runs the zotero arm with the stored file URL, revision-4.
        let resolution = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID, backendOverride: nil)
        guard case .attachment(let attachment)? = resolution else {
            Issue.record("expected an attachment resolution")
            return
        }
        #expect(attachment.producer.revision == Self.zoteroPackage.revision)
        #expect(attachment.producer.protocolRevision == .v4)
        let outcome = try await attachment.fetch { _ in }
        #expect(executor.lastRequest?.remoteURL?.rawValue == Self.fileURL)
        #expect(executor.lastRequest?.kind == .zotero)
        #expect(executor.lastRequest?.protocolRevision == .v4)
        #expect(outcome.isMarkdownResult == false)
        #expect(outcome.articleMetadata?.identifier == "PARENT01")

        // Persistence: the blob IS the source content; the retained Zotero
        // columns and the display name come from articleMetadata.
        let reference = try await provider.persistAttachmentExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            resolution: attachment, outcome: outcome)
        #expect(reference != nil)

        let summary = try #require(try store.listSources().first(where: { $0.id == sourceID }))
        #expect(summary.byteSize == pdfBytes.count)
        #expect(summary.mimeType == "application/pdf")
        #expect(summary.ext == "pdf")
        #expect(summary.zoteroItemKey == "PARENT01")
        #expect(summary.zoteroItemTitle == "A Study of Extraction")
        #expect(summary.effectiveName == "A Study of Extraction")
        let bytes = try #require(try store.sourceContent(id: sourceID))
        #expect(bytes == pdfBytes)

        // The follow-on format route is enqueued for a bytes result.
        try await provider.enqueueFollowOnExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID)
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

        guard case .attachment(let attachment)? = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID, backendOverride: nil) else {
            Issue.record("expected an attachment resolution")
            return
        }
        let outcome = try await attachment.fetch { _ in }
        #expect(outcome.isMarkdownResult)

        let reference = try await provider.persistAttachmentExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            resolution: attachment, outcome: outcome)
        #expect(reference != nil)

        let head = try #require(try store.processedMarkdownHead(sourceID: sourceID))
        #expect(head.content == String(decoding: markdown, as: UTF8.self))
        let summary = try #require(try store.listSources().first(where: { $0.id == sourceID }))
        #expect(summary.zoteroItemKey == "PARENT02")
        #expect(summary.zoteroItemTitle == "A Study of Extraction")
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

        guard case .attachment(let attachment)? = try await provider.resolveExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID, backendOverride: nil) else {
            Issue.record("expected an attachment resolution")
            return
        }
        let outcome = try await attachment.fetch { _ in }
        #expect(executor.lastRequest?.kind == .zotero)
        try await provider.persistAttachmentExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID,
            resolution: attachment, outcome: outcome)

        let summary = try #require(try store.listSources().first(where: { $0.id == sourceID }))
        #expect(summary.byteSize == pdfBytes.count)
        #expect(summary.mimeType == "application/pdf")
        #expect(summary.zoteroItemKey == "PARENT03")
        let bytes = try #require(try store.sourceContent(id: sourceID))
        #expect(bytes == pdfBytes)

        // The daemon's enqueue seam writes the durable follow-on item.
        try await provider.enqueueFollowOnExtraction(
            wikiID: WikiID(rawValue: "w"), sourceID: sourceID)
        let active = try queueStore.loadActive(for: .extraction)
        #expect(active.count == 1)
    }
}
#endif
