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

    @Test func onlyAllowlistedCompatibilityAdaptersMayExposeAgentEventRows() throws {
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
        #expect(rendererAdapter.contains("AgentEvent"))
        // The queue/activity surface intentionally adapts legacy agent rows;
        // it is not part of the display transcript API.
        #expect(remoteSession.contains("activityFeedEvents"))
        #expect(remoteSession.contains("AgentEvent"))
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
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appending(path: directory).appending(path: file),
            encoding: .utf8
        )
    }
}
#endif
