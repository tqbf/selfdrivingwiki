#if os(macOS)
import Foundation
import Testing
@testable import WikiFS

struct ChatPresentationAPIManifestTests {
    @Test func presentationContractCannotRegressToEventsOrTimestampArrays() throws {
        let presentation = try source(named: "ChatDetailPresentation.swift")
        let sync = try source(named: "ChatClientSync.swift", directory: "Sources/WikiFSEngine")
        let remoteSession = try source(named: "RemoteChatSession.swift")

        #expect(presentation.contains("AgentEvent") == false)
        #expect(presentation.contains("displayEvents") == false)
        #expect(presentation.contains("eventTimestamps") == false)
        #expect(sync.contains("displayEvents") == false)
        #expect(sync.contains("displayEventTimestamps") == false)
        #expect(remoteSession.contains("var events:") == false)
        #expect(remoteSession.contains("var eventTimestamps:") == false)
        #expect(remoteSession.contains("var isRunning:") == false)
        #expect(remoteSession.contains("var isGenerating:") == false)
        #expect(remoteSession.contains("var isAwaitingGenerationSlot:") == false)
        #expect(remoteSession.contains("var isInteractiveSession:") == false)
        #expect(remoteSession.contains("var activeChatID:") == false)
    }

    @Test func typedChatRendererDoesNotReintroduceAgentEventRows() throws {
        let displaySources = [
            try source(named: "ChatDetailPresentation.swift"),
            try source(named: "ChatDetailView.swift"),
            try source(named: "ChatDisplayProjection.swift"),
            try source(named: "ChatTranscriptPaneView.swift"),
        ]
        let rendererAdapter = try source(named: "ChatTranscriptView.swift")
        let remoteSession = try source(named: "RemoteChatSession.swift")

        #expect(displaySources.allSatisfy { $0.contains("AgentEvent") == false })
        #expect(rendererAdapter.contains("struct ChatTranscriptRenderingInput"))
        #expect(rendererAdapter.contains("AgentEvent") == false)
        #expect(rendererAdapter.contains("ChatDisplayRow"))
        #expect(remoteSession.contains("activityFeedEvents") == false)
        #expect(remoteSession.contains("AgentEvent") == false)
        #expect(remoteSession.contains("ChatTranscriptProjection") == false)
    }

    @Test func chatWebViewKeepsEventCompatibilityAtTheActivityFeedBoundary() throws {
        let renderer = try source(named: "ChatWebView.swift")

        #expect(renderer.contains("feedRowHTML") == true)
        #expect(renderer.contains("chatDisplayRowHTML") == true)
        #expect(renderer.contains("VisualStyle") == false)
        #expect(renderer.contains("chatRowHTML") == false)
        #expect(renderer.contains("assistantBubbleHTML") == false)
        #expect(renderer.contains("timestamps: [Date?]") == false)
    }

    @Test func legacyProjectionRemainsCoreOnlyPersistenceCompatibility() throws {
        let appSession = try source(named: "RemoteChatSession.swift")
        let appPresentation = try source(named: "ChatDetailPresentation.swift")
        let adapter = try source(
            named: "LegacyChatTranscriptPersistenceProjection.swift",
            directory: "Sources/WikiFSCore/Core"
        )
        let store = try source(named: "GRDBWikiStore.swift", directory: "Sources/WikiFSCore/Store")

        #expect(adapter.contains("LegacyChatTranscriptPersistenceProjection"))
        #expect(adapter.contains("projected_event_json"))
        #expect(adapter.contains("projected_text"))
        #expect(store.contains("LegacyChatTranscriptPersistenceProjection.project"))
        #expect(store.contains("projected_event_json"))
        #expect(store.contains("projected_text"))
        #expect(appSession.contains("LegacyChatTranscriptPersistenceProjection") == false)
        #expect(appPresentation.contains("LegacyChatTranscriptPersistenceProjection") == false)
    }

    @Test func chatPresentationSourcesCannotReintroduceEventArrayContracts() throws {
        let chatSources = [
            try source(named: "ChatDetailPresentation.swift"),
            try source(named: "ChatDetailView.swift"),
            try source(named: "ChatDisplayProjection.swift"),
            try source(named: "ChatTranscriptPaneView.swift"),
            try source(named: "ChatTranscriptView.swift"),
            try source(named: "RemoteChatSession.swift"),
            try source(named: "AgentQueueView.swift", directory: "Sources/WikiFS/Queue"),
        ]

        for source in chatSources {
            #expect(source.contains("AgentEvent") == false)
            #expect(source.contains("ChatTranscriptProjection") == false)
            #expect(source.contains("eventTimestamps") == false)
            #expect(source.contains("events.count") == false)
            #expect(source.contains("renderedCount") == false)
            #expect(source.contains("replaceLastRow") == false)
        }
    }

    @Test func appAgentEventImportsStayAtActivityFeedBoundaries() throws {
        let legacyEventSources = try appSwiftSources()
            .filter { $0.contents.contains("AgentEvent") }
            .map(\.path)
        let allowedActivityFeedSources: Set<String> = [
            "Chats/ChatWebView.swift",
            "Queue/AppQueueIngestionProvider.swift",
            "Queue/QueueTranscriptEmitBox.swift",
        ]

        #expect(Set(legacyEventSources) == allowedActivityFeedSources)
        #expect(legacyEventSources.contains("Chats/RemoteChatSession.swift") == false)
    }

    @Test func activityPresentationDoesNotImportAgentEvent() throws {
        let activity = try source(named: "ActivityWindowView.swift", directory: "Sources/WikiFS/Queue")
        let tracker = try source(named: "QueueActivityTracker.swift", directory: "Sources/WikiFS/Queue")

        #expect(activity.contains("AgentEvent") == false)
        #expect(tracker.contains("AgentEvent") == false)
    }

    @Test func activityPresentationUsesTypedTranscriptView() throws {
        let activity = try source(named: "ActivityWindowView.swift", directory: "Sources/WikiFS/Queue")

        #expect(activity.contains("ChatTranscriptView") == true)
        #expect(activity.contains("ChatDisplayProjection.project") == true)
        #expect(activity.contains("QueueTranscriptCanonicalMerge.merging") == true)
        #expect(activity.contains("TranscriptID.queueItem") == true)
    }

    @Test func legacyQueueEventStoreMethodsAreAbsent() throws {
        let store = try source(named: "QueueStore.swift", directory: "Sources/WikiFSCore/Core")

        #expect(store.contains("appendItemEvent") == false)
        #expect(store.contains("loadItemEvents") == false)
        #expect(store.contains("deleteItemEvents") == false)
    }

    @Test func projectionAndPermissionBoundaryUseTypedIDsAndIntent() throws {
        let projection = try source(named: "ChatDisplayProjection.swift")
        let pane = try source(named: "ChatTranscriptPaneView.swift")

        #expect(projection.contains("enum ChatDisplayRowID") == true)
        #expect(projection.contains("case message(ChatMessageID)") == true)
        #expect(projection.contains("case toolCall(ToolCallID)") == true)
        #expect(projection.contains("case notice(ChatTranscriptNoticeID)") == true)
        #expect(projection.contains("case failure(ChatTranscriptFailureID)") == true)
        #expect(projection.contains("enum ChatPermissionResolutionIntent") == true)
        #expect(pane.contains("(String, Bool)") == false)
    }

    private func source(named file: String, directory: String = "Sources/WikiFS/Chats") throws -> String {
        try String(
            contentsOf: repositoryRoot.appending(path: directory).appending(path: file),
            encoding: .utf8
        )
    }

    private func appSwiftSources() throws -> [(path: String, contents: String)] {
        let appRoot = repositoryRoot.appending(path: "Sources/WikiFS")
        guard let enumerator = FileManager.default.enumerator(
            at: appRoot,
            includingPropertiesForKeys: nil
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }

        return try enumerator.compactMap { element in
            guard let url = element as? URL, url.pathExtension == "swift" else {
                return nil
            }
            let path = url.path.replacingOccurrences(of: appRoot.path + "/", with: "")
            return (path, try String(contentsOf: url, encoding: .utf8))
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
#endif
