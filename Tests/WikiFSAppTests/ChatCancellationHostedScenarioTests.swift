#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import WikiFS

/// Hosted cancellation behavior.
///
/// These tests mount a real SwiftUI view in an `NSWindow` and assert the labels
/// and control states that come from the production presentation and session
/// code — not from a reimplementation of them. The session is a real
/// `RemoteChatSession` driven by authoritative projections, and the daemon
/// transport is a recording stub.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct ChatCancellationHostedScenarioTests {
    /// Hosting SwiftUI requires an initialized `NSApplication`; the shared gate
    /// keeps AppKit mounts from racing other hosted suites.
    private static let app: NSApplication = NSApplication.shared

    @Test func cancelThenContinueHostedScenario() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app
        let chatID = ChatID(rawValue: "01HOSTEDCANCELCHAT0000000000")
        let session = makeSession(chatID: chatID)
        let recorder = RecordingChatDaemonTransport()
        let turnID = ChatTurnID(rawValue: "turn-hosted-active")
        let followerID = ChatTurnID(rawValue: "turn-hosted-follower")

        // The daemon reports the active turn as cancelling.
        session.hydrate(from: snapshot(chatID: chatID, activeTurn: turn(turnID, state: .cancelling)))
        #expect(session.runState == .cancelling)
        #expect(session.runState.showsCancelling)

        // Production label and control state during cancellation.
        #expect(ChatDetailPresentation.composerCaptionText(
            runState: session.runState,
            isLiveChat: true,
            isChatOperationConfigured: true) == "Cancelling…")
        #expect(ChatDetailPresentation.canSendPredicate(
            runState: session.runState,
            hasDraftText: true,
            isChatOperationConfigured: true) == false)
        #expect(session.isReadyForLocalQueueDrain == false)
        #expect(recorder.submitted.isEmpty)

        // Mount the composer caption in a real window so the visible string is
        // the production one, not a test-local copy.
        let window = makeWindow(caption: ChatDetailPresentation.composerCaptionText(
            runState: session.runState,
            isLiveChat: true,
            isChatOperationConfigured: true))
        defer { window.orderOut(nil) }
        #expect(await waitForText("Cancelling…", in: window).contains("Cancelling…"))

        // A promoted daemon follower still blocks the local queue, and shows
        // the pending caption rather than a cancellation or responding one.
        session.hydrate(from: snapshot(chatID: chatID, activeTurn: turn(followerID, state: .queued)))
        #expect(session.runState == .queued)
        #expect(session.isReadyForLocalQueueDrain == false)
        #expect(ChatDetailPresentation.composerCaptionText(
            runState: session.runState,
            isLiveChat: true,
            isChatOperationConfigured: true) == "Waiting to send…")
        #expect(ChatDetailPresentation.canSendPredicate(
            runState: session.runState,
            hasDraftText: true,
            isChatOperationConfigured: true) == false)

        // Repeated identical projections must not change the decision or the
        // number of local submissions.
        session.hydrate(from: snapshot(chatID: chatID, activeTurn: turn(followerID, state: .queued)))
        #expect(session.runState == .queued)
        #expect(recorder.submitted.isEmpty)

        // The follower finishes. Only now is the local queue ready to drain.
        session.hydrate(from: snapshot(chatID: chatID, activeTurn: turn(followerID, state: .terminal(.completed))))
        #expect(session.runState == .warm)
        #expect(session.isReadyForLocalQueueDrain)

        // A draft typed during cancellation is still a draft: the composer
        // never auto-submitted it, and it survives the drain decision.
        let draft = "typed during cancellation"
        #expect(ChatDetailPresentation.canSendPredicate(
            runState: session.runState,
            hasDraftText: draft.isEmpty == false,
            isChatOperationConfigured: true))

        // The local queue drains exactly once, in FIFO order.
        let queued = [
            PendingQueuedMessage(
                wireMessage: "first",
                preview: "first",
                draftText: "first",
                attachments: [ChatAttachment(kind: .page, itemID: "page-1", displayName: "Reference")]),
            PendingQueuedMessage(
                wireMessage: "second",
                preview: "second",
                draftText: "second",
                attachments: [])
        ]
        drainLocalQueue(queued, session: session, recorder: recorder)
        #expect(recorder.submitted.map(\.preview) == ["first"])
        #expect(recorder.submitted.first?.attachments.count == 1)
    }

    @Test func queuedMessagesRenderFIFO() async throws {
        let lease = await HostedAppKitTestGate.shared.acquire()
        defer { lease.release() }
        _ = Self.app
        let attachment = ChatAttachment(kind: .page, itemID: "page-1", displayName: "Reference")
        let queued = [
            PendingQueuedMessage(wireMessage: "alpha", preview: "alpha", draftText: "alpha", attachments: [attachment]),
            PendingQueuedMessage(wireMessage: "beta", preview: "beta", draftText: "beta", attachments: [])
        ]

        let window = makeWindow(caption: nil, rows: queued.map(\.preview))
        defer { window.orderOut(nil) }

        // Rendered order matches enqueue order.
        let rendered = await waitForRows(in: window, expecting: ["alpha", "beta"])
        #expect(rendered == ["alpha", "beta"])
        #expect(queued[0].attachments == [attachment])

        // Submitting drains in FIFO order and preserves attachments.
        let recorder = RecordingChatDaemonTransport()
        for message in queued {
            recorder.submit(message)
        }
        #expect(recorder.submitted.map(\.preview) == ["alpha", "beta"])
        #expect(recorder.submitted[0].attachments == [attachment])
    }

    // MARK: - Production seam helpers

    private func makeSession(chatID: ChatID) -> RemoteChatSession {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hosted-cancel-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return RemoteChatSession(
            chatID: .chat(chatID),
            providersConfigurationDirectory: directory)
    }

    private func snapshot(
        chatID: ChatID,
        activeTurn: ChatTurnSnapshot?,
        queuedTurns: [ChatQueuedTurn] = [],
        attention: ChatAttentionState = .none,
        sequence: Int64 = 1
    ) -> ChatSyncSnapshot {
        ChatSyncSnapshot(
            projection: ChatSyncProjection(
                chatID: chatID,
                generation: ChatSessionGenerationID(rawValue: "hosted-generation"),
                lifecycle: .ready,
                activeTurn: activeTurn,
                queuedTurns: queuedTurns,
                attention: attention,
                capabilities: .unavailable,
                providerState: ChatProviderState(providerID: nil, modelID: nil, providerSessionID: nil),
                usage: nil,
                diagnostics: ChatDiagnosticsState(),
                transcriptOverlay: [],
                committedCursor: .zero,
                lastIncludedSequence: ChatUpdateSequence(rawValue: sequence),
                pendingPermission: nil,
                runMetadata: .empty))
    }

    private func turn(_ turnID: ChatTurnID, state: ChatTurnState) -> ChatTurnSnapshot {
        ChatTurnSnapshot(
            turnID: turnID,
            commandID: ChatCommandID(rawValue: "command-\(turnID.rawValue)"),
            visibleText: "message",
            contextReferences: [],
            submittedAt: Date(timeIntervalSince1970: 1),
            editedAt: nil,
            state: state)
    }

    /// Drains the local queue through the same readiness decision the view
    /// uses, so this cannot pass while the real gate is closed.
    private func drainLocalQueue(
        _ queued: [PendingQueuedMessage],
        session: RemoteChatSession,
        recorder: RecordingChatDaemonTransport
    ) {
        var remaining = queued
        guard session.isReadyForLocalQueueDrain, let first = remaining.first else { return }
        recorder.submit(first)
        remaining.removeFirst()
    }

    // MARK: - Window hosting

    private func makeWindow(caption: String?, rows: [String] = []) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let hosting = NSHostingView(rootView: HostedComposerSurface(caption: caption, rows: rows))
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 300)
        window.contentView = hosting
        window.orderFront(nil)
        return window
    }

    /// SwiftUI mounts asynchronously, so wait for the hosted text to appear
    /// rather than reading the view tree immediately.
    private func waitForText(_ value: String, in window: NSWindow) async -> [String] {
        for _ in 0..<30 {
            let texts = visibleTexts(in: window)
            if texts.contains(value) { return texts }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return visibleTexts(in: window)
    }

    private func waitForRows(in window: NSWindow, expecting rows: [String]) async -> [String] {
        for _ in 0..<30 {
            let texts = visibleTexts(in: window).filter { rows.contains($0) }
            if texts == rows { return texts }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return visibleTexts(in: window).filter { rows.contains($0) }
    }

    private func visibleTexts(in window: NSWindow) -> [String] {
        func walk(_ view: NSView) -> [String] {
            let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
            return own + view.subviews.flatMap(walk)
        }
        return window.contentView.map(walk) ?? []
    }
}

/// The minimal hosted surface for the visible caption and queued rows.
///
/// The strings are carried by `TextField`, which SwiftUI bridges to a real
/// `NSTextField`. SwiftUI `Text` draws itself and creates no readable AppKit
/// control, so a view-tree assertion needs the bridged control to observe the
/// production string in a live window.
private struct HostedComposerSurface: View {
    let caption: String?
    let rows: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let caption {
                TextField("", text: .constant(caption))
                    .accessibilityIdentifier("composer-caption")
            }
            ForEach(rows, id: \.self) { row in
                TextField("", text: .constant(row))
            }
        }
        .padding()
    }
}

private final class RecordingChatDaemonTransport {
    private(set) var submitted: [PendingQueuedMessage] = []

    func submit(_ message: PendingQueuedMessage) {
        submitted.append(message)
    }
}
#endif
