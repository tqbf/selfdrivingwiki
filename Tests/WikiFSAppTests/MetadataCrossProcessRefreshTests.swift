import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WikiFS
@testable import WikiFSEngine
@testable import WikiFSCore

@MainActor
struct MetadataCrossProcessRefreshTests {
    private static let app: NSApplication = {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return app
    }()

    @Test func eventBusChangeAdvancesHydrationKeyAndRehydratesSelectedChat() async throws {
        let store = try TestStoreFactory.inMemory()
        let chat = try store.createChat(kind: .edit, title: "Refresh")
        store.eventBus = WikiEventBus(wikiID: WikiID(rawValue: "metadata-refresh"))
        let model = WikiStoreModel(store: store)
        let recorder = HydrationRecorder()
        let hosted = try await host(
            SelectedChatMetadataHydrationTask(chatID: chat.id, store: model, recorder: recorder))
        defer {
            hosted.window.orderOut(nil)
            hosted.lease.release()
        }

        try await recorder.waitForCount(1)
        let initialGeneration = model.messageVersion
        let initialKey = MetadataHydrationKey.chat(chat.id, initialGeneration)
        #expect(await recorder.keys == [initialKey])

        _ = try store.appendChatMessages(chatID: chat.id, events: [.userText("durable update")])
        try await waitUntil("WikiEventBus reload increments messageVersion") {
            model.messageVersion > initialGeneration
        }
        try await recorder.waitForCount(2)

        let refreshedKey = MetadataHydrationKey.chat(chat.id, model.messageVersion)
        let keys = await recorder.keys
        #expect(refreshedKey != initialKey)
        #expect(keys == [initialKey, refreshedKey])
    }

    @Test func daemonSyncRefreshesLiveChatWithoutStoreRead() {
        let persisted = ChatTurnUsage(
            turnID: .init(rawValue: "turn"), providerID: nil, modelID: nil,
            startedAt: nil, finishedAt: nil, state: .providerSubmitted,
            inputTokens: 2, outputTokens: 3, thoughtTokens: nil,
            cacheReadTokens: nil, cacheWriteTokens: nil, cost: nil, currency: nil)
        let live = ChatMetadataLiveSnapshot(
            turnID: .init(rawValue: "turn"), state: .responding,
            providerID: nil, modelID: nil,
            usage: .init(inputTokens: 7, outputTokens: 11, totalTokens: 18,
                         cachedReadTokens: nil, thoughtTokens: nil, cost: nil,
                         currency: nil, contextUsed: 0, contextSize: 0))

        let merged = ChatMetadataProjection.mergedUsage(persisted: persisted, live: live)
        #expect(merged?.turnID == ChatTurnID(rawValue: "turn"))
        #expect(merged?.inputTokens == 7)
        #expect(merged?.outputTokens == 11)
    }

    private func host<V: View>(_ view: V) async throws -> HostedView<V> {
        let lease = await HostedAppKitTestGate.shared.acquire()
        _ = Self.app
        let host = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = host
        window.orderFront(nil)
        host.view.layoutSubtreeIfNeeded()
        return .init(lease: lease, window: window)
    }

    private func waitUntil(_ description: String, condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else {
                throw RefreshWaitError.timedOut(description)
            }
            await Task.yield()
        }
    }

    private struct HostedView<V: View> {
        let lease: HostedAppKitTestGate.Lease
        let window: NSWindow
    }

    private struct SelectedChatMetadataHydrationTask: View {
        let chatID: ChatID
        let store: WikiStoreModel
        let recorder: HydrationRecorder

        var body: some View {
            let key = MetadataHydrationKey.chat(chatID, store.messageVersion)
            Color.clear
                .task(id: key) {
                    await recorder.record(key)
                }
        }
    }

    private actor HydrationRecorder {
        private var recordedKeys: [MetadataHydrationKey] = []

        var keys: [MetadataHydrationKey] { recordedKeys }

        func record(_ key: MetadataHydrationKey) {
            recordedKeys.append(key)
        }

        func waitForCount(_ expected: Int) async throws {
            let deadline = Date().addingTimeInterval(2)
            while recordedKeys.count < expected {
                guard Date() < deadline else {
                    throw RefreshWaitError.timedOut("hydration task count \(expected)")
                }
                await Task.yield()
            }
        }
    }

    private enum RefreshWaitError: Error, LocalizedError {
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .timedOut(let description): "Timed out waiting for \(description)."
            }
        }
    }
}
