#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSCore
@testable import WikiFSEngine

/// Live-UI reproduction for the blank right-inspector Outline pane reported on
/// pages and sources. Mounts the REAL `PageDetailView` through the same
/// registration → `DetailInspectorView` composition the window shell uses, so
/// the failure mode (outline pane completely empty despite parseable headings)
/// is exercised end-to-end rather than through a synthetic outline view.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct InspectorOutlineHostedTests {
    private static let outlineWidth: CGFloat = 280
    private static let minimumBrightOutlinePixels = 100
    private static let brightChannelThreshold = 180
    private static let renderSettleYields = 4

    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    /// Mirrors `ContentView`'s trailing inspector column: the real
    /// `DetailInspectorView` fed from the live registration payload.
    private struct HostedPageWithInspector: View {
        @Bindable var store: WikiStoreModel
        let session: ProfileWikiSession
        let inspector: WindowRightInspectorController

        var body: some View {
            HStack(spacing: 0) {
                PageDetailView(
                    store: store,
                    launcher: AgentLauncher(),
                    session: session,
                    fileProvider: FileProviderFacade())
                    .environment(FindModel())
                    .environment(QueueActivityTracker())
                    .environment(inspector)
                if inspector.isPresented, let registration = inspector.registration {
                    Divider()
                    DetailInspectorView(
                        inspectorTab: registration.inspectorTab,
                        outlineWidth: registration.outlineWidth,
                        availableTabs: registration.availableTabs,
                        metadataState: registration.metadataState,
                        origin: registration.origin,
                        history: registration.history,
                        onOpenChat: registration.onOpenChat,
                        onCompareVersions: registration.onCompareVersions,
                        performMetadataAction: { _ in },
                        openMetadataLink: { _ in }
                    ) {
                        registration.outline()
                    }
                    .frame(width: InspectorOutlineHostedTests.outlineWidth)
                    // Mirrors ContentView's trailing inspector column so the
                    // remount/animation dynamics match the live window.
                    .id(registration.subject)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    @Test func pageOutlineRendersInsideRealInspectorHost() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-outline-hosted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove inspector outline fixture: \(error)")
            }
        }

        let store = try StoreBackend.current.makeStore(
            databaseURL: directory.appendingPathComponent("WikiFS.sqlite"))
        let model = WikiStoreModel(store: store)
        model.reloadFromStore()

        let markdown = """
        # Outline Repro Page

        Intro paragraph with plain text.

        ## First Section

        Content under the first section.

        ## Second Section

        Content under the second section.

        ### Nested Detail

        Deepest heading for the outline.
        """
        let first = try store.createPage(title: "Outline Repro First")
        try store.updatePage(id: first.id, title: "Outline Repro First", body: markdown)
        let second = try store.createPage(title: "Outline Repro Second")
        try store.updatePage(id: second.id, title: "Outline Repro Second", body: markdown)
        model.reloadFromStore()
        model.openTab(.page(first.id))

        UserDefaults.standard.set(InspectorTab.outline.rawValue, forKey: "pageInspectorTab")
        defer { UserDefaults.standard.removeObject(forKey: "pageInspectorTab") }

        let inspector = WindowRightInspectorController()
        inspector.isPresented = true
        let session = try Self.makeMinimalSession()
        let hosting = NSHostingController(rootView: HostedPageWithInspector(
            store: model,
            session: session,
            inspector: inspector
        ))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 1_200, height: 760))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let firstRegistered = await waitUntil {
            inspector.registration?.subject == .page(first.id)
        }
        #expect(firstRegistered, "the first page must register its inspector payload")
        let firstBrightPixels = try await settledBrightOutlinePixelCount(in: window.contentView)
        #expect(
            firstBrightPixels >= Self.minimumBrightOutlinePixels,
            "the first page outline must render visible heading rows"
        )

        // The live journey: switch subjects with the inspector already open.
        model.openTab(.page(second.id))
        let secondRegistered = await waitUntil {
            inspector.registration?.subject == .page(second.id)
        }
        #expect(secondRegistered, "the second page must take over the inspector")
        let secondBrightPixels = try await settledBrightOutlinePixelCount(in: window.contentView)
        #expect(
            secondBrightPixels >= Self.minimumBrightOutlinePixels,
            "the outline must render visible heading rows immediately after the subject switch"
        )
    }

    // MARK: - Source outline reproduction

    private struct HostedSourceWithInspector: View {
        @Bindable var store: WikiStoreModel
        let file: SourceSummary
        let session: ProfileWikiSession
        let fixtureDirectory: URL
        let queueEngine: QueueEngine
        let inspector: WindowRightInspectorController

        var body: some View {
            HStack(spacing: 0) {
                SourceDetailView(
                    file: file,
                    hasBeenIngested: false,
                    isIngesting: false,
                    isRunning: false,
                    isAnySourceIngesting: false,
                    isThisFileExtracting: false,
                    isEditLockedExternally: false,
                    wikiID: session.wikiID,
                    runIngest: { _ in },
                    launcher: AgentLauncher(),
                    extractionCoordinator: ExtractionCoordinator(
                        containerDirectory: fixtureDirectory,
                        localExtractorFactory: { InspectorOutlineStubExtractor() }
                    ),
                    queueEngine: queueEngine,
                    extractionProvider: InspectorOutlineStubExtractionProvider(),
                    fileProvider: FileProviderFacade(),
                    store: store,
                    installedRendererFactory: .unavailable,
                    installedRendererFactoryInputs: .init(
                        availableDescriptors: [],
                        registeredSourceTypes: nil,
                        hostNavigationRouting: .unavailable,
                        resolveConfiguration: { _, _ in nil })
                )
                .environment(FindModel())
                .environment(QueueActivityTracker())
                .environment(inspector)
                if inspector.isPresented, let registration = inspector.registration {
                    Divider()
                    DetailInspectorView(
                        inspectorTab: registration.inspectorTab,
                        outlineWidth: registration.outlineWidth,
                        availableTabs: registration.availableTabs,
                        metadataState: registration.metadataState,
                        origin: registration.origin,
                        history: registration.history,
                        onOpenChat: registration.onOpenChat,
                        onCompareVersions: registration.onCompareVersions,
                        performMetadataAction: { _ in },
                        openMetadataLink: { _ in }
                    ) {
                        registration.outline()
                    }
                    .frame(width: InspectorOutlineHostedTests.outlineWidth)
                    .id(registration.subject)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    /// Mounts the real `SourceDetailView` for a transcript-shaped source and
    /// returns whether it registered plus the settled bright-pixel count in the
    /// inspector outline region. `dropRendererPreferenceTable` reproduces the
    /// operator's live wiki state, where `renderer_source_preferences` is
    /// missing and every preference read logs a SQLite error at registration.
    private func hostedSourceOutlinePixels(
        dropRendererPreferenceTable: Bool
    ) async throws -> (registered: Bool, brightPixels: Int) {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-source-outline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove source outline fixture: \(error)")
            }
        }

        let databaseURL = directory.appendingPathComponent("WikiFS.sqlite")
        let store = try StoreBackend.current.makeStore(databaseURL: databaseURL)
        let source = try store.addSource(
            filename: "youtube-iZ_hhezC1mA",
            data: Data("# YouTube Transcript: iZ_hhezC1mA\n".utf8)
        )
        _ = try store.appendDerivedMarkdown(
            sourceID: source.id,
            content: Self.transcriptMarkdown,
            origin: .extraction,
            producer: .tool(.pdf2md),
            providerID: nil,
            modelID: nil,
            toolVersion: nil,
            sourceVersionID: nil,
            note: nil
        )
        if dropRendererPreferenceTable {
            try await Self.dropRendererPreferenceTable(at: databaseURL)
        }

        let model = WikiStoreModel(store: store)
        model.reloadFromStore()
        model.openTab(.source(source.id))

        UserDefaults.standard.set(InspectorTab.outline.rawValue, forKey: "sourceInspectorTab")
        defer { UserDefaults.standard.removeObject(forKey: "sourceInspectorTab") }

        let inspector = WindowRightInspectorController()
        inspector.isPresented = true
        let session = try Self.makeMinimalSession()
        let queueEngine = try makeInspectorOutlineTestQueueEngine()
        let hosting = NSHostingController(rootView: HostedSourceWithInspector(
            store: model,
            file: source,
            session: session,
            fixtureDirectory: directory,
            queueEngine: queueEngine,
            inspector: inspector
        ))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 1_200, height: 760))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let registered = await waitUntil {
            inspector.registration?.subject == .source(source.id)
        }
        let brightPixels = try await settledBrightOutlinePixelCount(in: window.contentView)
        return (registered, brightPixels)
    }

    private static let transcriptMarkdown = """
    # YouTube Transcript: iZ_hhezC1mA

    ## Opening Remarks

    Speaker one introduces the topic and frames the conversation.

    ## On Tools And Computing

    Discussion of live shared documents and versioning.

    ## On Deployment Barriers

    The gap between prototype and shared software.

    ## Closing Thoughts

    Where malleable software goes next.
    """

    /// Drops the renderer preference table from a fixture database via the
    /// `sqlite3` CLI, mirroring the operator's live wiki where the table is
    /// absent. Uses the non-blocking terminationHandler + timeout race so a
    /// stuck CLI cannot park the cooperative pool (see AGENTS.md).
    private static func dropRendererPreferenceTable(at url: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, "DROP TABLE IF EXISTS renderer_source_preferences;"]
        try process.run()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    if !process.isRunning {
                        cont.resume()
                        return
                    }
                    process.terminationHandler = { _ in cont.resume() }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
            }
            _ = try await group.next()
            group.cancelAll()
        }
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "InspectorOutlineHostedTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "sqlite3 DROP TABLE failed"]
            )
        }
    }

    @Test func sourceOutlineRendersInsideRealInspectorHost() async throws {
        let result = try await hostedSourceOutlinePixels(dropRendererPreferenceTable: false)
        #expect(result.registered, "the source must register its inspector payload")
        #expect(
            result.brightPixels >= Self.minimumBrightOutlinePixels,
            "the transcript outline must render visible heading rows"
        )
    }

    @Test func sourceOutlineSurvivesMissingRendererPreferenceTable() async throws {
        let result = try await hostedSourceOutlinePixels(dropRendererPreferenceTable: true)
        #expect(result.registered, "the source must register its inspector payload")
        #expect(
            result.brightPixels >= Self.minimumBrightOutlinePixels,
            "a missing renderer_source_preferences table must not blank the outline pane"
        )
    }

    // MARK: - Fixture + helpers

    private static func makeMinimalSession() throws -> ProfileWikiSession {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-outline-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let descriptor = WikiDescriptor.make(displayName: "Inspector Outline Test")
        let coordinator = ExtractionCoordinator(
            containerDirectory: dir,
            localExtractorFactory: { InspectorOutlineStubExtractor() }
        )
        return try ProfileWikiSession(
            testFixtureWikiID: descriptor.id,
            descriptor: descriptor,
            containerDirectory: dir,
            extractionCoordinator: coordinator,
            queueEngine: try makeInspectorOutlineTestQueueEngine(),
            extractionProvider: InspectorOutlineStubExtractionProvider()
        )
    }

    private func settleRendering() async {
        for _ in 0..<Self.renderSettleYields {
            await Task.yield()
        }
    }

    /// Poll the outline region until it has content — `PageOutlineView`
    /// populates `@State headings` in `.onAppear`, which lands asynchronously
    /// relative to window ordering. Bounded so a genuinely blank render fails
    /// fast instead of hanging the suite.
    private func settledBrightOutlinePixelCount(
        in view: NSView?,
        timeout: Duration = .seconds(2)
    ) async throws -> Int {
        let deadline = ContinuousClock.now + timeout
        var last = try brightOutlinePixelCount(in: view)
        while last == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            last = try brightOutlinePixelCount(in: view)
        }
        return last
    }

    private func waitUntil(
        timeout: Duration = .seconds(6),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while condition() == false {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private func brightOutlinePixelCount(
        in view: NSView?,
        outlineWidth: CGFloat = Self.outlineWidth
    ) throws -> Int {
        let view = try #require(view)
        view.layoutSubtreeIfNeeded()
        let scale = view.window?.backingScaleFactor ?? 1
        let outlineBounds = NSRect(
            x: view.bounds.maxX - outlineWidth,
            y: view.bounds.minY,
            width: outlineWidth,
            height: view.bounds.height
        )
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: outlineBounds))
        view.cacheDisplay(in: outlineBounds, to: bitmap)
        guard let data = bitmap.bitmapData else {
            Issue.record("The hosted outline bitmap has no pixel buffer.")
            return 0
        }
        guard bitmap.bitsPerSample == 8, bitmap.bitsPerPixel >= 24 else {
            Issue.record("The hosted outline bitmap must expose 8-bit RGB channels.")
            return 0
        }
        let bytesPerPixel = (bitmap.bitsPerPixel + 7) / 8
        let width = Int(outlineWidth * scale)
        var brightPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            let row = data.advanced(by: y * bitmap.bytesPerRow)
            for x in 0..<min(width, bitmap.pixelsWide) {
                let pixel = row.advanced(by: x * bytesPerPixel)
                let red = Int(pixel[0])
                let green = Int(pixel[1])
                let blue = Int(pixel[2])
                if red >= Self.brightChannelThreshold,
                   green >= Self.brightChannelThreshold,
                   blue >= Self.brightChannelThreshold {
                    brightPixels += 1
                }
            }
        }
        return brightPixels
    }
}

@MainActor
private final class InspectorOutlineStubExtractor: MarkdownExtractor {
    nonisolated var displayName: String { "Stub" }
    func readiness() async -> ExtractionReadiness { .ready }
    func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String { "" }
}

private struct InspectorOutlineStubExtractionProvider: QueueExtractionProvider {
    func resolveExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        backendOverride: ExtractionBackend?
    ) async throws -> ExtractionResolution? { nil }

    func persistBytesExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: BytesExtractionResolution,
        markdown: String
    ) async throws -> QueueExtractionOutputReference? { nil }

    func persistTranscriptExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: TranscriptExtractionResolution,
        outcome: TranscriptFetchOutcome
    ) async throws -> QueueExtractionOutputReference? { nil }
}

private func makeInspectorOutlineTestQueueEngine() throws -> QueueEngine {
    let store = try QueueStore(databaseURL: URL(fileURLWithPath: ":memory:"))
    let provider = InspectorOutlineStubExtractionProvider()
    let factory = QueueExtractionWorkerFactory(provider: provider, emitProgress: { _, _ in })
    return QueueEngine(store: store, workerFactory: factory)
}
#endif
