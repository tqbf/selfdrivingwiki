import Foundation
import Synchronization
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

@Suite("Cordis queue runtime assembly", .serialized, .timeLimit(.minutes(1)))
struct QueueRuntimeAssemblyTests {
    @Test("shuffled registration builds one ready runtime")
    func shuffledRegistrationBuildsOneRuntime() async throws {
        let directory = makeQueueRuntimeTempDirectory()
        let assembly = makeAssembly(
            databaseURL: directory.appendingPathComponent("queue.sqlite"))

        let handle = try await assembly.assemble(
            registrationOrder: QueueRuntimeAssembly.Component.allCases.shuffled())

        #expect(await handle.engine.lifecycle == .running)
        #expect(try await handle.dispose() == .shutDown)
    }

    @Test("startup has no output callback gap")
    func startupHasNoOutputCallbackGap() async throws {
        let directory = makeQueueRuntimeTempDirectory()
        let subscriptionReady = QueueRuntimeSignal()
        let handle = try await makeAssembly(
            databaseURL: directory.appendingPathComponent("queue.sqlite"))
            .assemble()

        let stream = handle.engine.outputChannel.events {
            subscriptionReady.signal()
        }
        let eventTask = Task { () -> QueueEvent? in
            for await event in stream { return event }
            return nil
        }
        await subscriptionReady.wait()

        let itemID = QueueItem.ID(rawValue: "callback-ready-item")
        handle.engine.outputChannel.emitProgress(itemID: itemID, line: "ready")
        let event = await eventTask.value
        guard case .progress(let receivedID, let line) = event else {
            Issue.record("Expected a progress event from the ready output channel")
            _ = try await handle.dispose()
            return
        }
        #expect(receivedID == itemID)
        #expect(line == "ready")
        #expect(try await handle.dispose() == .shutDown)
    }

    @Test("assembly failure disposes partial components and closes the store")
    func assemblyFailureDisposesPartialComponents() async throws {
        let directory = makeQueueRuntimeTempDirectory()
        let storeBox = QueueRuntimeStoreBox()
        let expectedFailure = QueueRuntimeTestFailure.injected
        let assembly = QueueRuntimeAssembly(
            databaseURL: directory.appendingPathComponent("queue.sqlite"),
            extractionProvider: QueueRuntimeExtractionProvider(),
            makeIngestionProvider: { store in
                storeBox.store = store
                throw expectedFailure
            })

        do {
            _ = try await assembly.assemble()
            Issue.record("Expected queue runtime assembly to fail")
        } catch {
            guard case .activationFailed(let component, let failure) = error as? QueueRuntimeAssemblyError else {
                Issue.record("Expected a typed queue runtime activation failure, got \(error)")
                return
            }
            #expect(component == QueueRuntimeAssembly.Component.ingestionProvider.rawValue)
            #expect(failure.message == String(describing: expectedFailure))
        }

        let store = try #require(storeBox.store)
        #expect(throws: (any Error).self) {
            _ = try store.loadActive()
        }
    }

    @Test("disposal closes the store after engine shutdown")
    func disposalClosesStoreAfterEngineShutdown() async throws {
        let directory = makeQueueRuntimeTempDirectory()
        let handle = try await makeAssembly(
            databaseURL: directory.appendingPathComponent("queue.sqlite"))
            .assemble()

        #expect(try await handle.dispose() == .shutDown)
        #expect(await handle.engine.lifecycle == .shutDown)
        #expect(throws: (any Error).self) {
            _ = try handle.store.loadActive()
        }
        #expect(try await handle.dispose() == .shutDown)
    }

    @Test("assembly registers only approved headless Sendable boundaries")
    func assemblyRegistersOnlyApprovedBoundaries() async throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/WikiFSEngine/QueueRuntimeAssembly.swift"),
            encoding: .utf8)
        let requiredServices = [
            "queue.store",
            "queue.extraction-provider",
            "queue.ingestion-provider",
            "queue.output-channel",
            "queue.extraction-factory",
            "queue.ingestion-factory",
            "queue.composite-factory",
            "queue.engine",
        ]
        let forbiddenBoundaries = [
            "WikiStoreModel",
            "SessionManager",
            "NSXPCConnection",
            "QueueEngineHotSwap",
            "SwiftUI",
        ]

        for service in requiredServices {
            #expect(source.contains("label: \"\(service)\""))
        }
        for boundary in forbiddenBoundaries {
            #expect(!source.contains(boundary))
        }
    }

    private func makeAssembly(databaseURL: URL) -> QueueRuntimeAssembly {
        QueueRuntimeAssembly(
            databaseURL: databaseURL,
            extractionProvider: QueueRuntimeExtractionProvider(),
            makeIngestionProvider: { _ in QueueRuntimeIngestionProvider() })
    }
}

private enum QueueRuntimeTestFailure: Error, Equatable, Sendable {
    case injected
}

private final class QueueRuntimeStoreBox: Sendable {
    private let storage = Mutex<QueueStore?>(nil)

    var store: QueueStore? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

private struct QueueRuntimeExtractionProvider: QueueExtractionProvider {
    func resolveExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        backendOverride: ExtractionBackend?
    ) async throws -> ExtractionResolution? {
        nil
    }

    func persistExtraction(
        wikiID: WikiID,
        sourceID: SourceID,
        markdown: String,
        backend: ExtractionBackend,
        modelVersion: String?,
        technique: String?
    ) async throws {}
}

private struct QueueRuntimeIngestionProvider: QueueIngestionProvider {
    func runIngestion(
        wikiID: WikiID,
        sourceIDs: [SourceID],
        queueItemID: QueueItem.ID,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onLogPaths: (@Sendable (URL?, URL?) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?
    ) async throws {}

    func runLint(
        wikiID: WikiID,
        queueItemID: QueueItem.ID,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onLogPaths: (@Sendable (URL?, URL?) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?
    ) async throws {}

    func runLintPages(
        wikiID: WikiID,
        pageIDs: [PageID],
        queueItemID: QueueItem.ID,
        onProgress: @escaping @Sendable (String) -> Void,
        onTranscript: (@Sendable (AgentEvent) -> Void)?,
        onUsage: (@Sendable (SessionUsage?) -> Void)?,
        onLiveUsage: (@Sendable (SessionUsage) -> Void)?,
        onLogPaths: (@Sendable (URL?, URL?) -> Void)?,
        onPendingPermission: (@Sendable (PendingPermission?) -> Void)?
    ) async throws {}

    func readiness() async -> String? { nil }
}

private final class QueueRuntimeSignal: Sendable {
    private struct State: Sendable {
        var signaled = false
        var continuation: AsyncStream<Void>.Continuation?
    }

    private let state = Mutex(State())

    func signal() {
        let continuation = state.withLock { state -> AsyncStream<Void>.Continuation? in
            guard !state.signaled else { return nil }
            state.signaled = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.yield(())
        continuation?.finish()
    }

    func wait() async {
        let pair = AsyncStream<Void>.makeStream()
        let completeNow = state.withLock { state -> Bool in
            if state.signaled { return true }
            state.continuation = pair.continuation
            return false
        }
        if completeNow { pair.continuation.finish() }
        for await _ in pair.stream { break }
    }
}

private func makeQueueRuntimeTempDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("queue-runtime-assembly-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    return directory
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
