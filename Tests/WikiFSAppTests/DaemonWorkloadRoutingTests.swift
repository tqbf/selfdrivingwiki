#if os(macOS)
import Foundation
import Testing
import WikiFSCore
@testable import WikiFSEngine
@testable import wikid
@testable import WikiFS

/// The P4 gate (plans/daemon-only-access.md Phase 4 gate + AC.8): a REAL
/// routed fixture extraction through the CLIENT queue path against a fixture
/// daemon asserts
///
/// 1. the provider executed IN THE DAEMON COMPOSITION (the daemon-side
///    invocation hook fires only inside the daemon's own queue provider),
/// 2. the extracted markdown committed DAEMON-SIDE (read through the
///    daemon's own store),
/// 3. the work is DURABLE — the item row lands in `queue.sqlite` before any
///    completion, and the job completes after the enqueuing "client" handle
///    is closed,
/// 4. the app-local provider counter (`WikiStorageSeam
///    .queueProviderInvocation`) records ZERO.
///
/// Plus the import auto-extraction end-to-end (package-only kind) and the
/// daemon-restart queue rehydration.
@Suite("Daemon workload routing (P4 gate)", .serialized, .timeLimit(.minutes(10)))
struct DaemonWorkloadRoutingTests {

    // MARK: - Fixture daemon extraction services

    /// Claims recognizing HTML (the data-selected import kind) and DOCX (the
    /// package-only kind), matching the production registration surface.
    private static let fixtureClaims = RegisteredExtractionInputs(claims: [
        .init(kind: .html, mimeTypes: ["text/html"], filenameExtensions: ["html", "htm"]),
        .init(kind: .docx, mimeTypes: [MimeType.docx], filenameExtensions: ["docx"]),
    ])

    /// Extraction services for the FIXTURE DAEMON: the HTML route resolves
    /// the built-in tag-based floor; the DOCX route resolves a scripted
    /// package adapter. No bun, no real packages.
    private struct FixtureFormatServices: ExtractionServices {
        var docxResult: DocxExtractionResult

        func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation {
            throw ExtractionServicesError.unavailable
        }

        func prepareHTML(
            backendOverride: HtmlExtractionBackend?
        ) async throws -> any HtmlMarkdownExtractor {
            FixtureHtmlExtractor()
        }

        func prepareDOCX() async throws -> any DocxMarkdownExtractor {
            FixtureDocxExtractor(result: docxResult)
        }

        func registeredExtractionInputs() async -> RegisteredExtractionInputs {
            RegisteredExtractionInputs(claims: [
                .init(kind: .html, mimeTypes: ["text/html"], filenameExtensions: ["html", "htm"]),
                .init(kind: .docx, mimeTypes: [MimeType.docx], filenameExtensions: ["docx"]),
            ])
        }
    }

    /// The built-in tag-based conversion (same engine the production floor uses).
    private struct FixtureHtmlExtractor: HtmlMarkdownExtractor {
        func extract(html: String) async -> HtmlExtractionResult? {
            let plain = html
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard plain.isEmpty == false else { return nil }
            return HtmlExtractionResult(
                markdown: plain, title: nil, author: nil, description: nil,
                published: nil, wordCount: plain.split(separator: " ").count)
        }
    }

    /// The scripted package adapter double.
    private struct FixtureDocxExtractor: DocxMarkdownExtractor {
        let result: DocxExtractionResult
        var packageProvenance: ExtractorPackageExecutionProvenance {
            ExtractorPackageExecutionProvenance(
                revision: ReviewedExtractorPackages.docx2md.revision,
                registrationID: ProcessExtractionServices.reviewedDOCXLogical.registrationID,
                protocolRevision: .v1)
        }
        func extract(docx: Data) async -> DocxExtractionResult? { result }
        func readiness() async -> ExtractionReadiness { .ready }
    }

    /// An extraction-runtime lease handing the fixture services to the
    /// daemon's composition owner.
    private struct FixtureExtractionRuntime: ExtractionRuntimeOwning {
        let services: any ExtractionServices
        func dispose() async throws {}
    }

    /// Thread-safe invocation recorder for the daemon-side provider hook.
    private final class InvocationLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func record(_ entry: String) {
            lock.withLock { entries.append(entry) }
        }
        func contains(_ needle: String) -> Bool { lock.withLock { entries.contains(needle) } }
    }

    // MARK: - Harness

    private func makeTempDir(named: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(named)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates the fixture wiki THROUGH the daemon (registry row + database)
    /// and prepares its services, returning the wiki ID.
    private func makeFixtureWiki(_ daemon: WikiDaemon, name: String) async throws -> WikiID {
        let created = try #require(daemon.testFixtureCreateWiki(name: name))
        let descriptor = try JSONDecoder().decode(WikiDescriptor.self, from: created)
        try await daemon.prepareWiki(descriptor.id)
        return descriptor.id
    }

    /// Boots the fixture daemon with the stub extraction services installed
    /// into its composition (the extraction assembly seam the synchronous
    /// fixture init takes) and the workload invocation hook wired — the hook
    /// fires ONLY inside the daemon's own `DaemonQueueExtractionProvider`.
    private func makeFixtureDaemon(
        named: String,
        docxMarkdown: String
    ) async throws -> (daemon: WikiDaemon, log: InvocationLog, dir: URL) {
        let dir = try makeTempDir(named: named)
        let log = InvocationLog()
        let docxResult = DocxExtractionResult(markdown: docxMarkdown, warnings: [])
        let daemon = WikiDaemon(
            containerDirectory: dir,
            testFixtureMakeStore: { url in try GRDBWikiStore(databaseURL: url) },
            extractionAssembly: {
                FixtureExtractionRuntime(services: FixtureFormatServices(docxResult: docxResult))
            },
            testWorkloadInvocationHook: { operation, _, sourceID in
                log.record("\(operation):\(sourceID.rawValue)")
            })
        return (daemon, log, dir)
    }

    /// Seeds one source in the daemon's own store and returns its summary.
    @discardableResult
    private func seedSource(
        _ daemon: WikiDaemon, wikiID: WikiID,
        filename: String, data: Data
    ) async throws -> SourceSummary {
        let store = try await daemon.domainCommandStore(wikiID: wikiID)
        return try await store.addSource(
            filename: filename,
            data: data,
            detectionHints: ContentTypeDetectionHints(filename: filename),
            ingestMetadata: nil,
            provenance: nil,
            role: .primary,
            originalPath: nil,
            activityID: nil,
            resolvedDisplayName: nil)
    }

    /// Waits until the durable queue store shows the item terminal.
    private func awaitTerminal(
        queueURL: URL, itemID: QueueItem.ID, timeout: Duration = .seconds(30)
    ) async throws -> QueueItemState {
        let reader = try QueueStore(databaseURL: queueURL)
        defer { reader.close() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if let item = try reader.getItem(itemID) {
                switch item.state {
                case .completed, .failed, .cancelled:
                    return item.state
                case .queued, .running:
                    break
                }
            }
            guard clock.now < deadline else {
                Issue.record("queue item \(itemID.rawValue) never settled")
                return .queued
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Gate 1: routed HTML extraction (HTML kind)

    @Test("routed HTML extraction: daemon-composition execution, daemon-side commit, zero app invocations")
    @MainActor
    func routedHTMLExtractionRunsDaemonSide() async throws {
        WikiOpenSeamRecorder.shared.reset()
        defer { WikiOpenSeamRecorder.shared.reset() }

        let (daemon, log, dir) = try await makeFixtureDaemon(
            named: "p4-html", docxMarkdown: "# unused")
        let wikiID = try await makeFixtureWiki(daemon, name: "P4 HTML Wiki")

        // Seed an HTML source IN the daemon's store.
        let html = "<html><body><article><p>Daemon converted this HTML body.</p></article></body></html>"
        let summary = try await seedSource(
            daemon, wikiID: wikiID, filename: "page.html", data: Data(html.utf8))

        // The CLIENT enqueue path: the same `engine.enqueue` the XPC queue
        // proxy fronts — the engine's dispatch scan owns the item from here.
        let queueURL = dir.appendingPathComponent("queue.sqlite")
        let item = try await daemon.daemonQueueHost.perform { engine in
            try await engine.enqueue(QueueItemRequest(
                queue: .extraction, wikiID: wikiID,
                payload: QueueItemPayload(sourceIDs: [summary.id])))
        }.value
        // DURABILITY: the item row is in queue.sqlite — a SEPARATE reader
        // handle sees it independent of the engine's in-memory state, so the
        // "client" can close before completion.
        do {
            let clientHandle = try QueueStore(databaseURL: queueURL)
            let persisted = try clientHandle.getItem(item)
            #expect(persisted != nil)
            clientHandle.close()  // …and the "client" closes first.
        }

        // The daemon completes the job on its own.
        let state = try await awaitTerminal(queueURL: queueURL, itemID: item)
        #expect(state == .completed)

        // DAEMON-SIDE COMMIT: the markdown is readable through the daemon's
        // own store — the app never wrote it.
        let daemonStore = try await daemon.domainCommandStore(wikiID: wikiID)
        let head = try await daemonStore.processedMarkdownHead(sourceID: summary.id)
        let headContent = try #require(head?.content)
        #expect(headContent.contains("Daemon converted this HTML body."))
        #expect(head?.origin == .extraction)
        #expect(head?.technique == QueueFormatRoute.htmlToMarkdownTechnique)

        // The DAEMON provider ran (invocation evidence from the hook that
        // fires only inside the daemon composition); the app-local provider
        // seam records ZERO worker entries anywhere in the harness.
        #expect(log.contains("resolveFormatRoute:\(summary.id.rawValue)"))
        #expect(log.contains("persistHtmlExtraction:\(summary.id.rawValue)"))
        #expect(WikiOpenSeamRecorder.shared.count(.queueProviderInvocation) == 0)
        #expect(WikiOpenSeamRecorder.shared.count(.queueStore) == 0)
    }

    // MARK: - Gate 2: import auto-extraction end-to-end (package-only kind)

    @Test("import auto-extraction: package-only kind enqueues, the daemon converts, the app sees the head")
    @MainActor
    func importConversionForPackageOnlyKindRunsDaemonSide() async throws {
        WikiOpenSeamRecorder.shared.reset()
        defer { WikiOpenSeamRecorder.shared.reset() }

        let (daemon, log, dir) = try await makeFixtureDaemon(
            named: "p4-import", docxMarkdown: "# Daemon DOCX conversion")
        let wikiID = try await makeFixtureWiki(daemon, name: "P4 Import Wiki")

        // The app-side session model over the SAME wiki database (in
        // production this store is the daemon-backed client; the fixture
        // reads the daemon-authored file, which is the commit evidence the
        // sink would project).
        let wikiDatabaseURL = dir.appendingPathComponent("\(wikiID.rawValue).sqlite")
        let appStore = try GRDBWikiStore(databaseURL: wikiDatabaseURL)
        appStore.eventBus = WikiEventBus(wikiID: wikiID)
        let model = WikiStoreModel(store: appStore)
        // The session-boot wiring: the derived kinds set (package-only here)
        // and the enqueue seam through the daemon queue engine.
        model.registeredExtractionInputs = Self.fixtureClaims
        model.importAutoExtractionKinds = [.docx]
        let queueURL = dir.appendingPathComponent("queue.sqlite")
        let enqueued = ItemIDBox()
        model.enqueueImportFormatJob = { sourceID in
            // The session seam enqueues through the daemon queue engine —
            // the same client path the manual actions use.
            let item = try await daemon.daemonQueueHost.perform { engine in
                try await engine.enqueue(QueueItemRequest(
                    queue: .extraction,
                    wikiID: wikiID,
                    payload: QueueItemPayload(
                        sourceIDs: [sourceID],
                        workloadIntent: .importConversion)))
            }.value
            enqueued.record(item)
        }
        // Import: seed the claimed package-only source IN the daemon's store,
        // then run the model's import gate over the same summary.
        let docxBytes = try Data(contentsOf: Self.fixtureDocxURL)
        let summary = try await seedSource(
            daemon, wikiID: wikiID, filename: "report.docx", data: docxBytes)
        model.autoExtractIfRegistered(summary)
        // The in-flight marker is visible synchronously at commit time…
        #expect(model.importExtractingSourceIDs.contains(summary.id))

        // …and clears at the enqueue ACK while the daemon converts.
        let itemID = try await enqueued.awaitValue(timeout: .seconds(10))
        let state = try await awaitTerminal(queueURL: queueURL, itemID: itemID)
        #expect(state == .completed)
        #expect(model.importExtractingSourceIDs.isEmpty)

        // DAEMON-SIDE COMMIT + app-visible projection: the daemon store holds
        // the converted markdown, and the app model (its store over the wiki
        // database) reads the same head.
        let daemonStore = try await daemon.domainCommandStore(wikiID: wikiID)
        let daemonHead = try await daemonStore.processedMarkdownHead(sourceID: summary.id)
        #expect(daemonHead?.content.contains("# Daemon DOCX conversion") == true)
        let appHead = await model.processedMarkdownHead(for: summary)
        #expect(appHead?.content.contains("# Daemon DOCX conversion") == true)
        #expect(log.contains("resolveFormatRoute:\(summary.id.rawValue)"))
        #expect(log.contains("persistDocxExtraction:\(summary.id.rawValue)"))
        #expect(WikiOpenSeamRecorder.shared.count(.queueProviderInvocation) == 0)
    }

    private static var fixtureDocxURL: URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return root
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("docx2md", isDirectory: true)
            .appendingPathComponent("tests", isDirectory: true)
            .appendingPathComponent("fixtures", isDirectory: true)
            .appendingPathComponent("fixture.docx")
    }

    /// Records the enqueued item ID from the model's enqueue seam.
    private final class ItemIDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: QueueItem.ID?
        func record(_ id: QueueItem.ID) {
            lock.withLock { value = id }
        }
        func awaitValue(timeout: Duration) async throws -> QueueItem.ID {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while true {
                if let id = lock.withLock({ value }) { return id }
                guard clock.now < deadline else {
                    Issue.record("the import enqueue never landed")
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    // MARK: - Gate 3: daemon-kill → relaunch rehydrates the snapshot

    @Test("daemon restart: the queue snapshot rehydrates the durable rows")
    func queueSnapshotRehydratesAfterDaemonRestart() async throws {
        // Daemon A owns the container; every probe and the restart daemon
        // read ITS queue.sqlite (a sibling temp dir is a different,
        // empty database).
        let (daemonA, _, daemonDir) = try await makeFixtureDaemon(
            named: "p4-restart-a", docxMarkdown: "# restart")
        let queueURL = daemonDir.appendingPathComponent("queue.sqlite")
        let wikiID = try await makeFixtureWiki(daemonA, name: "P4 Restart Wiki")
        _ = try await daemonA.daemonQueueHost.perform { engine in
            await engine.pause(.extraction)
        }
        let enqueued = try await daemonA.daemonQueueHost.perform { engine in
            try await engine.enqueue(QueueItemRequest(
                queue: .extraction, wikiID: wikiID,
                payload: QueueItemPayload(
                    sourceIDs: [SourceID(rawValue: "p4-restart-source")])))
        }.value
        do {
            let probe = try QueueStore(databaseURL: queueURL)
            defer { probe.close() }
            let preShutdown = try probe.getItem(enqueued)
            #expect(preShutdown?.state == .queued,
                    "the enqueued row is durable before shutdown")
        }
        await daemonA.shutdown()

        // The row is DURABLE on disk across the daemon's death.
        let durable = try QueueStore(databaseURL: queueURL)
        let row = try durable.getItem(enqueued)
        if let row {
            #expect(row.state == .queued, "restart row settled early: \(row.state.rawValue)")
        } else {
            let top = (try? FileManager.default.contentsOfDirectory(atPath: daemonDir.path)) ?? []
            Issue.record("restart row \(enqueued.rawValue) missing; queueURL=\(queueURL.path) contents=\(top.sorted())")
        }
        durable.close()

        // Relaunch: a fresh daemon over the same container rehydrates the
        // snapshot (the restart recovery).
        let daemonB = WikiDaemon(
            containerDirectory: daemonDir,
            testFixtureMakeStore: { url in try GRDBWikiStore(databaseURL: url) },
            extractionAssembly: {
                FixtureExtractionRuntime(services: FixtureFormatServices(
                    docxResult: DocxExtractionResult(markdown: "# restart", warnings: [])))
            })
        let snapshot = try await daemonB.daemonQueueHost.perform { engine in
            await engine.snapshot()
        }
        #expect(snapshot.value.activeItems.contains {
            $0.id == enqueued && $0.state == .queued
        })
        await daemonB.shutdown()
    }
}
#endif
