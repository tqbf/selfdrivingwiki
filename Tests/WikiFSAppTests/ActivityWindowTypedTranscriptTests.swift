#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import WebKit
@testable import WikiFS
import WikiFSCore
import WikiFSEngine

/// Hosts the real Activity window with a typed queue client, then verifies the
/// value-only transcript seam that the hosted detail pane uses. This keeps the
/// assertions deterministic while still mounting the production split view.
@Suite(.serialized)
@MainActor
struct ActivityWindowTypedTranscriptTests {
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    @Test func persistedOnlyTranscriptProducesVisibleTypedRows() async throws {
        let item = queueItem()
        let persisted = message(id: "persisted", text: "durable typed row")
        let client = StaticQueueEngineClient(item: item, transcript: [persisted])
        let tracker = QueueActivityTracker()

        let webView = try await hostActivityWindow(item: item, client: client, tracker: tracker)
        let presentation = makePresentation(items: [persisted])
        #expect(presentation.transcriptView().rendering.rows.count == 1)
        #expect(webView != nil)
    }

    @Test func partialLiveTranscriptReplacesPersistedRow() async throws {
        let persisted = message(id: "message", text: "partial")
        let live = message(id: "message", text: "complete")
        let merged = ActivityTranscriptPresentation.canonicalItems(persisted: [persisted], live: [live])

        let view = makePresentation(items: merged).transcriptView()
        #expect(view.rendering.rows.count == 1)
        #expect(merged == [live])
    }

    @Test func copyTextEqualsCanonicalVisibleTranscript() {
        let persisted = message(id: "message", text: "old")
        let live = message(id: "message", text: "new")
        let appended = message(id: "next", text: "next")
        let items = ActivityTranscriptPresentation.canonicalItems(
            persisted: [persisted], live: [live, appended])

        let presentation = makePresentation(items: items)
        #expect(presentation.copyText == "new\n\nnext")
        #expect(presentation.transcriptView().rendering.rows.count == items.count)
    }

    @Test func wikiLinkIntentUsesSelectedItemsWikiHandler() {
        var received: (URL, Bool)?
        let presentation = makePresentation(
            items: [message(id: "message", text: "[[Target]]")],
            onIntent: { intent in
                if case .openWikiLink(let url, let inNewTab) = intent {
                    received = (url, inNewTab)
                }
            }
        )
        let target = URL(string: "wikifs://page/selected")!
        presentation.onIntent(.openWikiLink(target, inNewTab: true))

        #expect(received?.0 == target)
        #expect(received?.1 == true)
    }

    @Test func rendererReceivesBlobStoreAndRenderContext() {
        let presentation = makePresentation(items: [message(id: "message", text: "row")])
        let view = presentation.transcriptView()

        #expect(view.blobStore == nil)
        #expect(view.renderContext?() == nil)
    }

    @Test func rendererUsesQueueItemTranscriptIdentity() {
        let item = queueItem()
        let presentation = makePresentation(
            items: [message(id: "message", text: "row")],
            transcriptID: .queueItem(item.id)
        )

        #expect(presentation.transcriptView().transcriptID == .queueItem(item.id))
    }

    @Test func progressOnlyItemUsesProgressFallback() {
        let presentation = makePresentation(items: [], progressText: "extracting page 1")

        #expect(presentation.usesProgressFallback)
        #expect(presentation.copyText == "extracting page 1")
    }

    private func hostActivityWindow(
        item: QueueItem,
        client: StaticQueueEngineClient,
        tracker: QueueActivityTracker
    ) async throws -> WKWebView? {
        let lease = await HostedAppKitTestGate.shared.acquire()
        _ = Self.app
        let root = ActivityWindowView(
            queue: item.queue,
            queueEngine: client,
            activityTracker: tracker,
            sessionManager: nil
        )
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            lease.release()
        }

        for _ in 0..<20 {
            if let webView = firstWebView(in: hosting.view) {
                return webView
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func firstWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews {
            if let webView = firstWebView(in: child) { return webView }
        }
        return nil
    }

    private func makePresentation(
        items: [ChatTranscriptItem],
        progressText: String = "",
        transcriptID: TranscriptID = .queueItem(QueueItemID(rawValue: "activity-window-item")),
        onIntent: @escaping (ChatTranscriptIntent) -> Void = { _ in }
    ) -> ActivityTranscriptPresentation {
        ActivityTranscriptPresentation(
            items: items,
            progressText: progressText,
            transcriptID: transcriptID,
            isStreaming: false,
            onIntent: onIntent,
            renderContext: { nil },
            blobStore: nil
        )
    }

    private func queueItem() -> QueueItem {
        QueueItem(
            id: QueueItemID(rawValue: "activity-window-item"),
            queue: .ingestion,
            wikiID: WikiID(rawValue: "activity-window-wiki"),
            payload: QueueItemPayload(sourceIDs: [SourceID(rawValue: "source")]),
            state: .completed,
            orderingKey: 1_000,
            attempt: 0,
            createdAt: 0
        )
    }

    private func message(id: String, text: String) -> ChatTranscriptItem {
        .message(ChatTranscriptMessageItem(
            messageID: ChatMessageID(rawValue: id),
            turnID: ChatTurnID(rawValue: "activity-window-turn"),
            role: .assistant,
            text: text,
            createdAt: .distantPast
        ))
    }
}

private final class StaticQueueEngineClient: QueueEngineClient, @unchecked Sendable {
    private let value: QueueSnapshot
    private let transcript: [ChatTranscriptItem]

    init(item: QueueItem, transcript: [ChatTranscriptItem]) {
        value = QueueSnapshot(recentItems: [item])
        self.transcript = transcript
    }

    var events: AsyncStream<QueueEvent> { AsyncStream { $0.finish() } }
    func enqueue(_ request: QueueItemRequest) async throws -> QueueItem.ID { QueueItemID(rawValue: "unused") }
    func cancelItem(_ id: QueueItem.ID) async {}
    func cancelAllInFlight() async -> Int { 0 }
    func retryItem(_ id: QueueItem.ID) async throws {}
    func pause(_ queue: QueueKind) async {}
    func resume(_ queue: QueueKind) async {}
    func halt(_ queue: QueueKind) async {}
    func reorderItem(id: QueueItem.ID, beforeItemID: QueueItem.ID?) async {}
    func snapshot() async -> QueueSnapshot { value }
    func hasActiveWork(for wikiID: WikiID) async -> Bool { false }
    func waitForCompletion(of id: QueueItem.ID) async -> Result<Void, Error> { .success(()) }
    func loadTranscript(for itemID: QueueItem.ID) async -> [ChatTranscriptItem] { transcript }
    func loadAllActivitySnapshots() async -> [QueueItem.ID: QueueEngine.ActivitySnapshot] { [:] }
}
#endif
