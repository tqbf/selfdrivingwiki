#if os(macOS)
import ACPModel
import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore
@testable import WikiFSEngine
@testable import wikid

struct LauncherChatAgentRuntimeTests {
    @Test @MainActor
    func preparedColdStartReadsOnceAndPreflightRetryDoesNotReuseReleasedToken() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prepared-chat-start-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = AgentProvider(
            id: ProviderID(rawValue: "prepared-provider"),
            label: "Prepared",
            command: ["/usr/bin/true"],
            enabled: true,
            isDefault: true)
        let configuration = AgentProvidersConfig(
            providers: [provider],
            selectedModelIds: [provider.id.rawValue: ModelID(rawValue: "prepared-model")])
        let reads = LockedInt()
        let backend = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(shouldFailOnStart: true),
            FakeSessionBehavior(),
        ])
        let services = AgentProviderRuntime(
            readConfiguration: {
                reads.increment()
                return configuration
            },
            resolveCommand: { providers in
                Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
                    provider.command.map { (provider.id, $0) }
                })
            },
            readCredential: { _ in nil },
            resolvePermissionPolicy: { _ in .bypass },
            makeBackend: { _, _, _ in backend })
        let store = try GRDBWikiStore(databaseURL: directory.appendingPathComponent("wiki.sqlite"))
        let chat = try store.createChat(kind: .edit, title: "Prepared start")
        let coordinator = ExtractionCoordinator(
            containerDirectory: directory,
            localExtractorFactory: { UnavailablePdf2MarkdownExtractor() })
        let gate = GenerationGate(laneLimits: [.ingest: 1, .interactive: 1])
        let runtime = LauncherChatAgentRuntime(
            chatID: chat.id,
            wikiID: WikiID(rawValue: "prepared-wiki"),
            store: store,
            extractionCoordinator: coordinator,
            generationGate: gate,
            pushEvent: { _ in },
            onSessionID: { _ in },
            onStateUpdate: { _ in },
            onLiveEvents: { _ in },
            providerServices: services,
            onMessageSummary: { _ in },
            launcherConfigurator: { launcher in launcher.containerDirectory = directory })
        let input = ChatRuntimeStartInput(
            request: ChatRuntimeStartRequest(
                chatID: chat.id,
                generation: ChatSessionGenerationID(rawValue: "prepared-generation"),
                systemPrompt: "",
                providerID: nil,
                modelID: nil,
                existingProviderSessionID: nil),
            configuredThinkingOptionID: nil,
            priorEffectiveThinkingOptionID: nil)

        let prepared = try await runtime.prepareStart(input)
        #expect(reads.value == 1)
        let handle = try await runtime.start(prepared)
        let first = ChatTurnSubmission(
            commandID: ChatCommandID(rawValue: "prepared-command-1"),
            turnID: ChatTurnID(rawValue: "prepared-turn-1"),
            userText: "first",
            contextReferences: [],
            submittedAt: Date())
        await #expect(throws: LauncherChatAgentRuntime.RuntimeError.self) {
            try await runtime.submitTurn(first, in: handle)
        }
        let second = ChatTurnSubmission(
            commandID: ChatCommandID(rawValue: "prepared-command-2"),
            turnID: ChatTurnID(rawValue: "prepared-turn-2"),
            userText: "second",
            contextReferences: [],
            submittedAt: Date())
        try await runtime.submitTurn(second, in: handle)

        #expect(reads.value == 2)
        #expect(await backend.startCount == 2)
        await runtime.close(handle)
    }

    @Test func permissionTranslationPreservesToolCallIDAndTypedOptions() {
        let request = LauncherChatAgentRuntime.permissionRequest(
            from: PendingPermission(
                toolCallId: ToolCallID(rawValue: "tool-call-1"),
                title: "Edit file",
                toolName: "Edit",
                inputSummary: "/tmp/file.md",
                options: [
                    PermissionOption(kind: "allow_once", name: "Allow once", optionId: "allow-once"),
                    PermissionOption(kind: "reject_once", name: "Reject", optionId: "reject-once"),
                    PermissionOption(kind: "cancel", name: "Cancel", optionId: "cancel"),
                ]
            ),
            turnID: ChatTurnID(rawValue: "turn-1")
        )

        #expect(request.requestID == PermissionRequestID(rawValue: "permission-tool-call-1"))
        #expect(request.turnID == ChatTurnID(rawValue: "turn-1"))
        #expect(request.toolCallID == ToolCallID(rawValue: "tool-call-1"))
        #expect(request.options.map(\.id) == [
            PermissionOptionID(rawValue: "allow-once"),
            PermissionOptionID(rawValue: "reject-once"),
            PermissionOptionID(rawValue: "cancel"),
        ])
        #expect(request.options.map(\.behavior) == [.allow, .deny, .cancel])
        #expect(request.options.map(\.visualIntent) == [.accent, .destructive, .destructive])
        #expect(request.options.map(\.isDefault) == [true, false, false])
    }

    @Test(arguments: [
        ("```console\n<command-output>\n```", "&lt;command-output&gt;"),
        ("```json\n{\"ok\": true}\n```", "{\"ok\": true}"),
        ("build completed", "build completed"),
    ])
    @MainActor
    func acpToolOutputKeepsTheDescriptorAndRendersRawOutputSafely(
        _ output: String,
        escapedOutput: String
    ) {
        let command = "wikictl page add --title Fence"
        let translator = ACPEventTranslator()
        let events = translator.translate(.toolCall(ToolCallUpdate(
            toolCallId: "tool-fence",
            status: .pending,
            kind: .execute,
            rawInput: AnyCodable(["command": command])
        ))) + translator.translate(.toolCallUpdate(ToolCallUpdateDetails(
            toolCallId: "tool-fence",
            status: .completed,
            content: [.content(.text(TextContent(text: output)))]
        )))

        var transcriptTranslator = AgentEventTranscriptTranslator()
        let deltas = transcriptTranslator.translate(
            events,
            turnID: ChatTurnID(rawValue: "turn-fence")
        )
        let items = ChatTranscriptReducer.reducing(items: [], with: deltas)
        let toolCall = items.compactMap { item -> ChatTranscriptToolCallItem? in
            guard case .toolCall(let toolCall) = item else { return nil }
            return toolCall
        }.last

        guard let toolCall else {
            Issue.record("expected an ACP tool-call transcript row")
            return
        }
        #expect(toolCall.status == .completed)
        #expect(toolCall.detail == command)
        #expect(toolCall.output == output)

        let row = ChatDisplayProjection.project(items: items, activeContentBlock: nil).transcript.rows.last
        guard let row else {
            Issue.record("expected a display row")
            return
        }
        let html = ChatWebView.Coordinator.chatDisplayRowHTML(row)
        #expect(html.contains("Completed — \(command)"))
        #expect(html.contains("Completed — ```") == false)
        #expect(html.contains("<pre class=\"chat-tool-detail\">\(escapedOutput)</pre>"))
        #expect(html.contains("<command-output>") == false)
    }

    @Test func launcherRuntimeUsesSharedTranslator() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot.appendingPathComponent("Sources/wikid/LauncherChatAgentRuntime.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("[ChatTurnID: AgentEventTranscriptTranslator]"))
        #expect(source.contains("translator.translate([event], turnID: turnID)"))
        #expect(source.contains("translator.activeContentBlock"))
        #expect(source.contains("TranscriptTranslationState") == false)
        #expect(source.contains("transcriptDeltasForTesting") == false)
    }

    /// The launcher callback is synchronous, but the runtime must not start a
    /// separate re-entrant actor operation for every callback. A blocked live
    /// sink makes the old implementation copy the same translator state for a
    /// burst of deltas; the last resumed operation then overwrites the other
    /// chunks. The fixture deliberately includes the malformed Markdown that
    /// made `![[source:Name]]` render as an embed in the reported chat.
    @Test(.timeLimit(.minutes(1)))
    func rapidOnEventBurstPreservesOrderedTextAcrossSuspendingLiveSink() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-runtime-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                // The temporary directory is disposable; the test already
                // reports the behavior under test, so cleanup is best effort.
            }
        }

        let provider = AgentProvider(
            id: ProviderID(rawValue: "fake"),
            label: "Fake",
            command: ["/usr/bin/true"],
            enabled: true,
            isDefault: true
        )
        let providerConfig = AgentProvidersConfig(
            providers: [provider],
            selectedModelIds: ["fake": ModelID(rawValue: "fake-model")]
        )
        try providerConfig.save(to: directory)

        let chunks = [
            "Available embedded/renderers include:\n\n",
            "- Mermaid diagrams ``, `sequenceDiagram`, `classDiagram`, `stateDiagram-v2`, `erDiagram`, `gantt`, `pie`, `gitGraph`, `mindmap`,",
            " and `timeline blocks, as demonstrated in [[SVG]].\n\n",
            "- Source embeds for images, video, audio, and PDFs using ",
            "`![[source:Name]]`.\n",
            "- External media embeds for YouTube, Vimeo, Spotify, SoundCloud, and direct URLs.\n",
        ]
        let expectedText = chunks.joined()
        let backend = FakeAgentBackend(behaviors: [
            FakeSessionBehavior(events: chunks.map(AgentEvent.assistantTextDelta) + [.messageStop])
        ])
        let liveSink = SuspendingLiveEventSink()

        let store = try GRDBWikiStore(databaseURL: directory.appendingPathComponent("wiki.sqlite"))
        let chat = try store.createChat(kind: .edit, title: "Runtime race")
        let coordinator = await MainActor.run {
            ExtractionCoordinator(
                containerDirectory: directory,
                localExtractorFactory: { UnavailablePdf2MarkdownExtractor() }
            )
        }
        let gate = await MainActor.run {
            GenerationGate(laneLimits: [.ingest: 1, .interactive: 1])
        }
        let runtime = LauncherChatAgentRuntime(
            chatID: chat.id,
            wikiID: WikiID(rawValue: "race-wiki"),
            store: store,
            extractionCoordinator: coordinator,
            generationGate: gate,
            pushEvent: { _ in },
            onSessionID: { _ in },
            onStateUpdate: { _ in },
            onLiveEvents: { events in
                await liveSink.receive(events)
            },
            providerServices: UnavailableAgentProviderServices(),
            onMessageSummary: { _ in },
            launcherConfigurator: { launcher in
                launcher.resolveBackend = { _, _, _ in backend }
                launcher.resolveProvidersContainerDirectory = { directory }
                launcher.containerDirectory = directory
                launcher.acpCredentialStore = InMemoryACPCredentialStore()
            }
        )

        let request = ChatRuntimeStartRequest(
            chatID: chat.id,
            generation: ChatSessionGenerationID(rawValue: "generation-race"),
            systemPrompt: "",
            providerID: provider.id,
            modelID: ModelID(rawValue: "fake-model"),
            existingProviderSessionID: nil
        )
        let handle = try await runtime.start(request)
        let stream = try await runtime.eventStream(for: handle)
        let envelopesTask = Task { () -> [ChatAgentRuntimeEventEnvelope] in
            var envelopes: [ChatAgentRuntimeEventEnvelope] = []
            for await envelope in stream {
                envelopes.append(envelope)
                if case .turnCompleted(let turnID) = envelope.event,
                   turnID == ChatTurnID(rawValue: "turn-race") {
                    break
                }
            }
            return envelopes
        }

        let submission = ChatTurnSubmission(
            commandID: ChatCommandID(rawValue: "command-race"),
            turnID: ChatTurnID(rawValue: "turn-race"),
            userText: "render this response",
            contextReferences: [],
            submittedAt: Date(timeIntervalSince1970: 1)
        )
        try await runtime.submitTurn(submission, in: handle)

        // This waits on the actual callback entry, not elapsed time. Every
        // callback is held until release, so old per-event Tasks all resume
        // from the same stale translator snapshot.
        await liveSink.waitForFirstEntry()
        await liveSink.releaseAll()

        let envelopes = await envelopesTask.value
        let callbackEvents = await liveSink.events
        let callbackText = callbackEvents.compactMap { event -> String? in
            guard case .assistantTextDelta(let text) = event else { return nil }
            return text
        }.joined()
        #expect(callbackText == expectedText)

        var transcriptItems: [ChatTranscriptItem] = []
        for envelope in envelopes {
            guard case .transcript(let deltas) = envelope.event else { continue }
            transcriptItems = ChatTranscriptReducer.reducing(items: transcriptItems, with: deltas)
        }
        let assistantMessages = transcriptItems.compactMap { item -> ChatTranscriptMessageItem? in
            guard case .message(let message) = item,
                  message.role == .assistant else { return nil }
            return message
        }
        #expect(assistantMessages.count == 1)
        #expect(assistantMessages.first?.text == expectedText)

        await runtime.close(handle)
    }
}

private actor SuspendingLiveEventSink {
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let enteredStream: AsyncStream<Void>
    private var releaseContinuations: [AsyncStream<Void>.Continuation] = []
    private var isReleased = false
    private var recordedEvents: [AgentEvent] = []

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        enteredStream = stream
        enteredContinuation = continuation
    }

    func receive(_ events: [AgentEvent]) async {
        recordedEvents.append(contentsOf: events)
        enteredContinuation.yield(())
        guard isReleased == false else { return }

        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        releaseContinuations.append(continuation)
        for await _ in stream {
            break
        }
    }

    func waitForFirstEntry() async {
        var iterator = enteredStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func releaseAll() {
        isReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.yield(())
            continuation.finish()
        }
    }

    var events: [AgentEvent] { recordedEvents }
}
private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.withLock { storedValue }
    }

    func increment() {
        lock.withLock { storedValue += 1 }
    }
}
#endif
