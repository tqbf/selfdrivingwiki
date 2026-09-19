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
                        openMetadataLink: { _ in },
                        outline: registration.outline,
                        onOutlineSelect: registration.onOutlineSelect
                    )
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
        // Value oracle: the accepted registration must carry the parsed
        // headings themselves, not a closure to be invoked later.
        let firstPayload = inspector.registration?.outline
        #expect(firstPayload?.subject == .page(first.id))
        if case .headings(let firstHeadings)? = firstPayload?.content {
            #expect(firstHeadings.count == 4, "the page payload must contain all four headings")
            #expect(firstPayload?.highlightedItemID == nil, "reader mode has no caret, so no heading is highlighted")
        } else {
            Issue.record("page outline payload must carry .headings content")
        }
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
        if case .headings(let secondHeadings)? = inspector.registration?.outline.content {
            #expect(!secondHeadings.isEmpty, "the second page payload must contain headings")
        } else {
            Issue.record("second page outline payload must carry .headings content")
        }
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
                        openMetadataLink: { _ in },
                        outline: registration.outline,
                        onOutlineSelect: registration.onOutlineSelect
                    )
                    .frame(width: InspectorOutlineHostedTests.outlineWidth)
                    .id(registration.subject)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    /// Mounts the real `SourceDetailView` for a transcript-shaped source and
    /// returns whether it registered, the accepted outline payload, and the
    /// settled bright-pixel count in the inspector outline region.
    /// `dropRendererPreferenceTable` reproduces the operator's live wiki
    /// state, where `renderer_source_preferences` is missing and every
    /// preference read logs a SQLite error at registration.
    private func hostedSourceOutlinePixels(
        dropRendererPreferenceTable: Bool
    ) async throws -> (registered: Bool, payload: InspectorOutlinePayload?, brightPixels: Int) {
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
        return (registered, inspector.registration?.outline, brightPixels)
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
        if case .headings(let headings)? = result.payload?.content {
            #expect(headings.count == 5, "the transcript payload must contain all five headings")
        } else {
            Issue.record("source outline payload must carry non-empty .headings content")
        }
        #expect(
            result.brightPixels >= Self.minimumBrightOutlinePixels,
            "the transcript outline must render visible heading rows"
        )
    }

    @Test func sourceOutlineSurvivesMissingRendererPreferenceTable() async throws {
        let result = try await hostedSourceOutlinePixels(dropRendererPreferenceTable: true)
        #expect(result.registered, "the source must register its inspector payload")
        if case .headings(let headings)? = result.payload?.content {
            #expect(!headings.isEmpty, "the missing-table variant must still carry headings")
        } else {
            Issue.record("source outline payload must carry .headings content")
        }
        #expect(
            result.brightPixels >= Self.minimumBrightOutlinePixels,
            "a missing renderer_source_preferences table must not blank the outline pane"
        )
    }

    // MARK: - Cross-type subject swaps (inspector stays open)

    /// Hosts all three detail surfaces, switching on the store selection the
    /// way `ContentView` does, with the trailing inspector column alongside.
    private struct HostedDetailSwitcherWithInspector: View {
        @Bindable var store: WikiStoreModel
        let session: ProfileWikiSession
        let sourceFile: SourceSummary
        let fixtureDirectory: URL
        let queueEngine: QueueEngine
        let chatID: ChatID
        let coordinator: ChatDaemonCoordinator
        let inspector: WindowRightInspectorController

        var body: some View {
            HStack(spacing: 0) {
                switch store.selection {
                case .page:
                    PageDetailView(
                        store: store,
                        launcher: AgentLauncher(),
                        session: session,
                        fileProvider: FileProviderFacade())
                        .environment(FindModel())
                        .environment(QueueActivityTracker())
                        .environment(inspector)
                case .source:
                    SourceDetailView(
                        file: sourceFile,
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
                case .chat:
                    ChatDetailView(
                        chatID: chatID,
                        store: store,
                        remoteSession: coordinator.session(
                            wikiID: session.wikiID, for: chatID),
                        coordinator: coordinator,
                        session: session,
                        fileProvider: FileProviderFacade()
                    )
                    .environment(inspector)
                default:
                    EmptyView()
                }
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
                        openMetadataLink: { _ in },
                        outline: registration.outline,
                        onOutlineSelect: registration.onOutlineSelect
                    )
                    .frame(width: InspectorOutlineHostedTests.outlineWidth)
                    .id(registration.subject)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    /// The previously untested dimension: cross-type subject swaps with the
    /// inspector open. The window journey page → source → chat → page must
    /// swap the accepted payload's kind AND render visible outline rows at
    /// every step — no blank first frame on any boundary.
    @Test func crossTypeSubjectSwapsKeepTheOutlinePopulated() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-outline-swap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove swap fixture: \(error)")
            }
        }

        let store = try StoreBackend.current.makeStore(
            databaseURL: directory.appendingPathComponent("WikiFS.sqlite"))
        let page = try store.createPage(title: "Swap Journey Page")
        try store.updatePage(id: page.id, title: "Swap Journey Page", body: Self.swapPageMarkdown)
        let source = try store.addSource(
            filename: "youtube-swap-journey",
            data: Data("# YouTube Transcript: swap\n".utf8))
        _ = try store.appendDerivedMarkdown(
            sourceID: source.id,
            content: Self.transcriptMarkdown,
            origin: .extraction,
            producer: .tool(.pdf2md),
            providerID: nil,
            modelID: nil,
            toolVersion: nil,
            sourceVersionID: nil,
            note: nil)
        let chat = try store.createChat(kind: .edit, title: "Swap Journey Chat")
        _ = try store.appendChatTranscriptItems(
            chatID: chat.id,
            items: [
                .message(ChatTranscriptMessageItem(
                    messageID: ChatMessageID(rawValue: "swap-question"),
                    turnID: ChatTurnID(rawValue: "swap-turn"),
                    role: .user,
                    text: "Swap journey question?",
                    createdAt: .distantPast)),
                .message(ChatTranscriptMessageItem(
                    messageID: ChatMessageID(rawValue: "swap-answer"),
                    turnID: ChatTurnID(rawValue: "swap-turn"),
                    role: .assistant,
                    text: "Swap journey answer.",
                    createdAt: .distantPast)),
            ])
        let model = WikiStoreModel(store: store)
        model.reloadFromStore()

        UserDefaults.standard.set(InspectorTab.outline.rawValue, forKey: "pageInspectorTab")
        UserDefaults.standard.set(InspectorTab.outline.rawValue, forKey: "sourceInspectorTab")
        UserDefaults.standard.set(InspectorTab.outline.rawValue, forKey: "chatInspectorTab")
        defer {
            UserDefaults.standard.removeObject(forKey: "pageInspectorTab")
            UserDefaults.standard.removeObject(forKey: "sourceInspectorTab")
            UserDefaults.standard.removeObject(forKey: "chatInspectorTab")
        }

        let inspector = WindowRightInspectorController()
        inspector.isPresented = true
        let session = try Self.makeMinimalSession()
        let daemon = StubChatDaemonCommands()
        let coordinator = ChatDaemonCoordinator(
            client: daemon,
            eventSink: DaemonQueueEventSink())
        let queueEngine = try makeInspectorOutlineTestQueueEngine()

        model.openTab(.page(page.id))
        let hosting = NSHostingController(rootView: HostedDetailSwitcherWithInspector(
            store: model,
            session: session,
            sourceFile: source,
            fixtureDirectory: directory,
            queueEngine: queueEngine,
            chatID: chat.id,
            coordinator: coordinator,
            inspector: inspector))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 1_200, height: 760))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        func assertHeadingsPayload(_ subject: WikiSelection, minimumRows: Int) throws {
            let payload = try #require(inspector.registration?.outline)
            #expect(payload.subject == subject)
            guard case .headings(let headings) = payload.content else {
                Issue.record("\(subject) swap must carry a .headings payload, got \(payload.contentKindDescription)")
                return
            }
            #expect(headings.count >= minimumRows)
        }

        // page → source
        model.openTab(.source(source.id))
        await settleRendering()
        #expect(model.selection == .source(source.id), "model.selection must switch to the source")
        let sourceTook = await waitUntil {
            inspector.registration?.subject == .source(source.id)
        }
        #expect(sourceTook, "the source must take over the inspector from the page")
        try assertHeadingsPayload(.source(source.id), minimumRows: 5)
        let sourcePixels = try await settledBrightOutlinePixelCount(in: window.contentView)
        #expect(sourcePixels >= Self.minimumBrightOutlinePixels,
                "the outline must render rows right after the page → source swap")

        // source → chat
        model.openTab(.chat(chat.id))
        await settleRendering()
        #expect(model.selection == .chat(chat.id), "model.selection must switch to the chat")
        let chatTook = await waitUntil {
            inspector.registration?.subject == .chat(chat.id)
        }
        #expect(chatTook, "the chat must take over the inspector from the source")
        let chatPayload = try #require(inspector.registration?.outline)
        #expect(chatPayload.subject == .chat(chat.id))
        guard case .chatTurns(let turns) = chatPayload.content else {
            Issue.record("chat swap must carry a .chatTurns payload")
            return
        }
        #expect(!turns.isEmpty, "the chat payload must contain the persisted turn")
        let chatPixels = try await settledBrightOutlinePixelCount(in: window.contentView)
        #expect(chatPixels >= Self.minimumBrightOutlinePixels,
                "the outline must render rows right after the source → chat swap")

        // chat → page
        model.openTab(.page(page.id))
        await settleRendering()
        #expect(model.selection == .page(page.id), "model.selection must switch back to the page")
        let pageTook = await waitUntil {
            inspector.registration?.subject == .page(page.id)
        }
        #expect(pageTook, "the page must take over the inspector from the chat")
        try assertHeadingsPayload(.page(page.id), minimumRows: 1)
        let pagePixels = try await settledBrightOutlinePixelCount(in: window.contentView)
        #expect(pagePixels >= Self.minimumBrightOutlinePixels,
                "the outline must render rows right after the chat → page swap")
    }

    private static let swapPageMarkdown = """
    # Swap Journey Root

    ## Swap Section

    Body for the swap journey.
    """

    // MARK: - Caret tracking (issue #268) through the payload

    /// Depth-first search for the first subview matching `type`.
    private func firstSubview<ViewType: NSView>(of view: NSView, ofType type: ViewType.Type) -> ViewType? {
        if let match = view as? ViewType { return match }
        for sub in view.subviews {
            if let match = firstSubview(of: sub, ofType: type) { return match }
        }
        return nil
    }

    /// The editor's text view, identified by its content so the page's title
    /// field or other stray text views cannot satisfy the lookup. Polls briefly
    /// because the editor mounts asynchronously relative to window ordering.
    private func editorTextView(
        containing marker: String,
        in view: NSView?,
        timeout: Duration = .seconds(2)
    ) async throws -> NSTextView? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let match = firstSubview(of: try #require(view), ofType: NSTextView.self),
               match.string.contains(marker) {
                return match
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// Move the real editor selection across heading regions and assert the
    /// accepted payload's `highlightedItemID` follows — the page editor half
    /// of AC.10.
    @Test func pageEditorCaretMoveUpdatesAcceptedPayloadHighlight() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-caret-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove page caret fixture: \(error)")
            }
        }

        let markdown = """
        # Alpha
        alpha body
        ## Beta
        beta body
        """
        let store = try StoreBackend.current.makeStore(
            databaseURL: directory.appendingPathComponent("WikiFS.sqlite"))
        let page = try store.createPage(title: "Caret Page")
        try store.updatePage(id: page.id, title: "Caret Page", body: markdown)
        let model = WikiStoreModel(store: store)
        model.reloadFromStore()
        model.openTab(.page(page.id))
        // Seed edit mode from the active tab before mount, exactly like a
        // "start in editor" tab does.
        model.setTabEditing(tabID: try #require(model.activeTabID), isEditing: true)

        UserDefaults.standard.set(InspectorTab.outline.rawValue, forKey: "pageInspectorTab")
        defer { UserDefaults.standard.removeObject(forKey: "pageInspectorTab") }

        let inspector = WindowRightInspectorController()
        inspector.isPresented = true
        let session = try Self.makeMinimalSession()
        let hosting = NSHostingController(rootView: HostedPageWithInspector(
            store: model,
            session: session,
            inspector: inspector))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 1_200, height: 760))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        _ = await waitUntil { inspector.registration?.subject == .page(page.id) }
        let headings = OutlineParser.headings(in: markdown)
        #expect(headings.map(\.id) == ["alpha", "beta"])

        let editor = try #require(
            await editorTextView(containing: "beta body", in: window.contentView),
            "the page editor's text view must mount")

        // Caret inside the Beta region → beta highlighted.
        editor.selectedRange = NSRange(location: headings[1].charOffset + 1, length: 0)
        let reachedBeta = await waitUntil {
            inspector.registration?.outline.highlightedItemID == "beta"
        }
        #expect(reachedBeta, "moving the caret into Beta's region must update the accepted payload's highlight")

        // Caret back inside Alpha's region → alpha highlighted.
        editor.selectedRange = NSRange(location: headings[0].charOffset + 2, length: 0)
        let reachedAlpha = await waitUntil {
            inspector.registration?.outline.highlightedItemID == "alpha"
        }
        #expect(reachedAlpha, "moving the caret back into Alpha's region must re-highlight Alpha")
    }

    /// The editable-source half of AC.10: the same caret → payload highlight
    /// chain must hold for the source editor, entered through the view's real
    /// edit-mode restore path (mark the tab editing, switch away, switch back).
    @Test func sourceEditorCaretMoveUpdatesAcceptedPayloadHighlight() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-caret-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove source caret fixture: \(error)")
            }
        }

        let store = try StoreBackend.current.makeStore(
            databaseURL: directory.appendingPathComponent("WikiFS.sqlite"))
        let navPage = try store.createPage(title: "Caret Source Nav Page")
        let source = try store.addSource(
            filename: "youtube-caret-journey",
            data: Data("# YouTube Transcript: caret\n".utf8))
        _ = try store.appendDerivedMarkdown(
            sourceID: source.id,
            content: Self.transcriptMarkdown,
            origin: .extraction,
            producer: .tool(.pdf2md),
            providerID: nil,
            modelID: nil,
            toolVersion: nil,
            sourceVersionID: nil,
            note: nil)
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
            inspector: inspector))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 1_200, height: 760))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        _ = await waitUntil { inspector.registration?.subject == .source(source.id) }

        // Enter edit mode via the view's own restore path: mark the source
        // tab editing, move the active tab away, then return to it. A real
        // await between the two switches is load-bearing — back-to-back
        // mutations coalesce into one SwiftUI update, and `onChange(of:
        // store.activeTabID)` would never observe the intermediate tab.
        model.setTabEditing(tabID: try #require(model.activeTabID), isEditing: true)
        model.openTab(.page(navPage.id))
        await settleRendering()
        model.openTab(.source(source.id))

        let headings = OutlineParser.headings(in: Self.transcriptMarkdown)
        #expect(headings.count == 5)
        let opening = headings[1]
        let closing = headings[4]

        let editor = try #require(
            await editorTextView(containing: "Opening Remarks", in: window.contentView),
            "the source editor's text view must mount in edit mode — the tab's edit-mode restore did not engage")

        editor.selectedRange = NSRange(location: closing.charOffset + 1, length: 0)
        let reachedClosing = await waitUntil {
            inspector.registration?.outline.highlightedItemID == closing.id
        }
        #expect(reachedClosing, "moving the source caret into the last heading's region must update the accepted payload's highlight")

        editor.selectedRange = NSRange(location: opening.charOffset + 1, length: 0)
        let reachedOpening = await waitUntil {
            inspector.registration?.outline.highlightedItemID == opening.id
        }
        #expect(reachedOpening, "moving the source caret back must re-highlight the opening heading")
    }

    // MARK: - Empty state (AC.6)

    /// An empty payload must render the explicit empty state — visible
    /// content, not blank space, and never stray heading rows. The oracle is
    /// the count of drawn (non-near-black) pixels in the cached bitmap, which
    /// is independent of the bright-row threshold the populated-outline tests
    /// use: the empty state's secondary-gray label draws pixels but never
    /// crosses the bright threshold.
    @Test func emptyPayloadRendersExplicitEmptyStateInsteadOfBlankSpace() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app

        let emptyPayload = InspectorOutlinePayload(
            subject: .page(PageID(rawValue: "empty-state-page")),
            content: .headings([]),
            highlightedItemID: nil)
        let populatedPayload = InspectorOutlinePayload(
            subject: .page(PageID(rawValue: "empty-state-page")),
            content: .headings([
                OutlineHeading(id: "first", text: "First Section", level: 1, charOffset: 0),
                OutlineHeading(id: "second", text: "Second Section", level: 2, charOffset: 24),
                OutlineHeading(id: "third", text: "Third Section", level: 3, charOffset: 60),
            ]),
            highlightedItemID: nil)

        func mount(_ view: some View) -> (window: NSWindow, view: NSView) {
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.setContentSize(NSSize(width: Self.outlineWidth, height: 480))
            window.orderFront(nil)
            return (window, hosting.view)
        }

        func drawnPixelCount(in view: NSView?) throws -> Int {
            let view = try #require(view)
            view.layoutSubtreeIfNeeded()
            let bounds = view.bounds
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: bounds))
            view.cacheDisplay(in: bounds, to: bitmap)
            guard let data = bitmap.bitmapData else {
                Issue.record("The empty-state bitmap has no pixel buffer.")
                return 0
            }
            let bytesPerPixel = (bitmap.bitsPerPixel + 7) / 8
            var drawn = 0
            for y in 0..<bitmap.pixelsHigh {
                let row = data.advanced(by: y * bitmap.bytesPerRow)
                for x in 0..<bitmap.pixelsWide {
                    let pixel = row.advanced(by: x * bytesPerPixel)
                    if pixel[0] > 8 || pixel[1] > 8 || pixel[2] > 8 {
                        drawn += 1
                    }
                }
            }
            return drawn
        }

        // A control mount that draws nothing anchors the floor of the oracle.
        let blankMount = mount(EmptyView())
        defer { blankMount.window.orderOut(nil) }
        await settleRendering()
        let blankPixels = try drawnPixelCount(in: blankMount.view)

        let emptyMount = mount(InspectorOutlineView(
            payload: emptyPayload, onSelect: { _ in }))
        defer { emptyMount.window.orderOut(nil) }
        await settleRendering()
        let emptyPixels = try drawnPixelCount(in: emptyMount.view)
        #expect(
            emptyPixels > blankPixels,
            "an empty payload must render the explicit empty state, not blank space")

        let populatedMount = mount(InspectorOutlineView(
            payload: populatedPayload, onSelect: { _ in }))
        defer { populatedMount.window.orderOut(nil) }
        await settleRendering()
        let populatedPixels = try drawnPixelCount(in: populatedMount.view)
        #expect(
            populatedPixels > emptyPixels,
            "the populated outline must render more content than the empty state")
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

    /// Poll the outline region until it has content — the inspector renders
    /// from the registered payload, which lands asynchronously relative to
    /// window ordering. Bounded so a genuinely blank render fails fast instead
    /// of hanging the suite.
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
    func persistAttachmentExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        resolution: AttachmentExtractionResolution,
        outcome: AttachmentFetchOutcome
    ) async throws -> QueueExtractionOutputReference? { nil }
    func enqueueFollowOnExtraction(wikiID: WikiID, sourceID: SourceID) async throws {}
}

private func makeInspectorOutlineTestQueueEngine() throws -> QueueEngine {
    let store = try QueueStore(databaseURL: URL(fileURLWithPath: ":memory:"))
    let provider = InspectorOutlineStubExtractionProvider()
    let factory = QueueExtractionWorkerFactory(provider: provider, emitProgress: { _, _ in })
    return QueueEngine(store: store, workerFactory: factory)
}
#endif
