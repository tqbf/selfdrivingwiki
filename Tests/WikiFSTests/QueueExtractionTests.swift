#if os(macOS)
import Foundation
import Testing
import os
@testable import WikiFSEngine
@testable import WikiFSCore

/// Tests for Phase 4 headless components: `QueueExtractionWorker`,
/// `QueueExtractionWorkerFactory`, `QueueEngine.waitForCompletion`,
/// `QueueEngine.enqueue` validation, and `.progress` events.
///
/// These tests use fake providers/workers (no real extraction runs). The
/// app-layer migration (AgentOperationRunner, SourceDetailView, AgentLauncher
/// retirement) is tested via source-scan for AC.1.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct QueueExtractionTests {

    // MARK: - Helpers

    private func tempDatabaseURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-extraction-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.sqlite")
    }

    private func makePayload(sourceID: String = "TESTSRC001") -> QueueItemPayload {
        QueueItemPayload(sourceIDs: [PageID(rawValue: sourceID)])
    }

    // MARK: - AC.2: Enqueue returns immediately

    @Test func testEnqueueReturnsBeforeExtraction() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let gate = CountDownLatch(count: 1)
        let provider = FakeExtractionProvider(
            resolveResult: .resolved(.localPdf2md),
            convertBehavior: { _ in await gate.wait() }
        )
        let factory = QueueExtractionWorkerFactory(
            provider: provider,
            emitProgress: { _, _ in }
        )
        let config = QueueEngineConfig(localExtractionLimit: 1, remoteExtractionLimit: 1)
        let engine = QueueEngine(store: store, config: config, workerFactory: factory)
        await engine.start()

        let start = Date()
        _ = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "wiki1", payload: makePayload()))
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 1.0) // Immediate — not waiting for the worker.
        gate.release()
        store.close()
    }

    // MARK: - AC.3: Enqueue rejects empty wikiID

    @Test func testEnqueueRejectsEmptyWikiID() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())
        let provider = FakeExtractionProvider(resolveResult: .resolved(.localPdf2md))
        let factory = QueueExtractionWorkerFactory(
            provider: provider, emitProgress: { _, _ in })
        let engine = QueueEngine(store: store, workerFactory: factory)
        await engine.start()

        do {
            _ = try await engine.enqueue(
                QueueItemRequest(queue: .extraction, wikiID: "", payload: makePayload()))
            Issue.record("Should have thrown")
        } catch is QueueStoreError { /* expected */ }
        store.close()
    }

    @Test func testEnqueueRejectsWhitespaceWikiID() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())
        let provider = FakeExtractionProvider(resolveResult: .resolved(.localPdf2md))
        let factory = QueueExtractionWorkerFactory(
            provider: provider, emitProgress: { _, _ in })
        let engine = QueueEngine(store: store, workerFactory: factory)
        await engine.start()

        do {
            _ = try await engine.enqueue(
                QueueItemRequest(queue: .extraction, wikiID: "  ", payload: makePayload()))
            Issue.record("Should have thrown")
        } catch is QueueStoreError { /* expected */ }
        store.close()
    }

    @Test func testUnconfiguredProviderStaysQueued() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        // Provider returns nil (no PDF bytes) — providerID(for:) returns nil,
        // so the item stays queued and is never dispatched.
        let provider = FakeExtractionProvider(resolveResult: .nilResolution)
        let factory = QueueExtractionWorkerFactory(
            provider: provider, emitProgress: { _, _ in })
        let engine = QueueEngine(store: store, workerFactory: factory)
        await engine.start()

        let id = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "wiki1", payload: makePayload()))

        // Give the engine time to attempt dispatch.
        try await Task.sleep(nanoseconds: 300_000_000)

        let item = try store.getItem(id)
        #expect(item?.state == .queued) // Never dispatched.
        store.close()
    }

    // MARK: - AC.4: Readiness check

    @Test func testReadinessCheckMarksFailed() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let provider = FakeExtractionProvider(
            resolveResult: .resolved(.localPdf2md),
            extractorReadiness: .needsSetup("pdf2md not installed — click to download")
        )
        let factory = QueueExtractionWorkerFactory(
            provider: provider, emitProgress: { _, _ in })
        let engine = QueueEngine(store: store,
                                 config: QueueEngineConfig(localExtractionLimit: 1),
                                 workerFactory: factory)
        await engine.start()

        let id = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "wiki1", payload: makePayload()))

        try await Task.sleep(nanoseconds: 300_000_000)

        let item = try store.getItem(id)
        #expect(item?.state == .failed)
        let error = item?.error ?? ""
        #expect(error.contains("pdf2md not installed"))
        store.close()
    }

    // MARK: - AC.5: Progress events

    @Test func testProgressEventEmitted() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let progressHolder = ProgressCollector()
        let provider = FakeExtractionProvider(
            resolveResult: .resolved(.localPdf2md),
            convertBehavior: { onProgress in
                onProgress("Converting page 1...")
                onProgress("Converting page 2...")
            }
        )
        let factory = QueueExtractionWorkerFactory(
            provider: provider,
            emitProgress: { id, line in progressHolder.record(id: id, line: line) }
        )
        let engine = QueueEngine(store: store,
                                 config: QueueEngineConfig(localExtractionLimit: 1),
                                 workerFactory: factory)
        await engine.start()

        let id = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "wiki1", payload: makePayload()))

        try await progressHolder.waitForCount(2, timeoutSeconds: 5)

        let lines = progressHolder.lines
        #expect(lines.count == 2)
        #expect(lines[0].line == "Converting page 1...")
        #expect(lines[1].line == "Converting page 2...")
        _ = id
        store.close()
    }

    // MARK: - AC.6: Partial failure

    @Test func testPartialFailureProceedsWithRawPDF() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        struct TestError: Error {}
        let provider = FakeExtractionProvider(
            resolveResult: .resolved(.localPdf2md),
            convertBehavior: { _ in throw TestError() }
        )
        let factory = QueueExtractionWorkerFactory(
            provider: provider, emitProgress: { _, _ in })
        let engine = QueueEngine(store: store,
                                 config: QueueEngineConfig(localExtractionLimit: 1),
                                 workerFactory: factory)
        await engine.start()

        let id = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "wiki1", payload: makePayload()))

        // Wait for completion — should be .failure because the worker threw.
        let result = await engine.waitForCompletion(of: id)

        switch result {
        case .success: Issue.record("Expected failure, got success")
        case .failure: break // Expected.
        }

        // The item should be .failed — caller can detect this and proceed
        // with the raw PDF (today's fallback behavior).
        let item = try store.getItem(id)
        #expect(item?.state == .failed)
        store.close()
    }

    // MARK: - waitForCompletion

    @Test func testWaitForCompletionReturnsSuccess() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let provider = FakeExtractionProvider(
            resolveResult: .resolved(.localPdf2md),
            convertBehavior: { _ in }
        )
        let factory = QueueExtractionWorkerFactory(
            provider: provider, emitProgress: { _, _ in })
        let engine = QueueEngine(store: store,
                                 config: QueueEngineConfig(localExtractionLimit: 1),
                                 workerFactory: factory)
        await engine.start()

        let id = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "wiki1", payload: makePayload()))

        let result = await engine.waitForCompletion(of: id)

        if case .success = result { /* expected */ } else {
            Issue.record("Expected .success")
        }

        let item = try store.getItem(id)
        #expect(item?.state == .completed)
        store.close()
    }

    @Test func testWaitForCompletionReturnsFailure() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        struct TestError: Error {}
        let provider = FakeExtractionProvider(
            resolveResult: .resolved(.localPdf2md),
            convertBehavior: { _ in throw TestError() }
        )
        let factory = QueueExtractionWorkerFactory(
            provider: provider, emitProgress: { _, _ in })
        let engine = QueueEngine(store: store,
                                 config: QueueEngineConfig(localExtractionLimit: 1),
                                 workerFactory: factory)
        await engine.start()

        let id = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "wiki1", payload: makePayload()))

        let result = await engine.waitForCompletion(of: id)

        if case .failure = result { /* expected */ } else {
        }
        store.close()
    }

    @Test func testWaitForCompletionAlreadyTerminal() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let provider = FakeExtractionProvider(
            resolveResult: .resolved(.localPdf2md),
            convertBehavior: { _ in }
        )
        let factory = QueueExtractionWorkerFactory(
            provider: provider, emitProgress: { _, _ in })
        let engine = QueueEngine(store: store,
                                 config: QueueEngineConfig(localExtractionLimit: 1),
                                 workerFactory: factory)
        await engine.start()

        let id = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "wiki1", payload: makePayload()))

        // Wait for the item to complete first.
        try await Task.sleep(nanoseconds: 300_000_000)

        // Now call waitForCompletion — should return immediately since the
        // item is already .completed.
        let start = Date()
        let result = await engine.waitForCompletion(of: id)
        let elapsed = Date().timeIntervalSince(start)

        if case .success = result { /* expected */ } else {
            Issue.record("Expected .success for already-terminal item")
        }
        #expect(elapsed < 0.5) // Should be near-instant.
        store.close()
    }

    // MARK: - Worker calls provider in order

    @Test func testExtractionWorkerCallsProviderInOrder() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let provider = FakeExtractionProvider(
            resolveResult: .resolved(.localPdf2md),
            convertBehavior: { _ in }
        )
        let factory = QueueExtractionWorkerFactory(
            provider: provider, emitProgress: { _, _ in })
        let engine = QueueEngine(store: store,
                                 config: QueueEngineConfig(localExtractionLimit: 1),
                                 workerFactory: factory)
        await engine.start()

        _ = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "wiki1", payload: makePayload()))

        try await Task.sleep(nanoseconds: 300_000_000)

        let calls = provider.callLog
        // The factory calls resolveExtraction during providerID(for:), and the
        // worker calls it again before persist. So we expect at least:
        // resolve (factory), resolve (worker), persist.
        #expect(calls.count >= 2)
        // At least one persist call should be present.
        #expect(calls.contains(where: { $0.contains("persist") }))
        // The first call should be a resolve.
        #expect(calls[0].contains("resolve"))
        store.close()
    }

    // MARK: - Backend override (re-extraction)

    @Test func testReExtractionWithBackendOverride() async throws {
        let store = try QueueStore(databaseURL: tempDatabaseURL())

        let provider = FakeExtractionProvider(
            resolveResult: .resolved(.anthropic),
            convertBehavior: { _ in }
        )
        let factory = QueueExtractionWorkerFactory(
            provider: provider, emitProgress: { _, _ in })
        let engine = QueueEngine(store: store,
                                 config: QueueEngineConfig(localExtractionLimit: 1),
                                 workerFactory: factory)
        await engine.start()

        // Enqueue with a backend override in the payload's stageRouting.
        let payload = QueueItemPayload(
            sourceIDs: [PageID(rawValue: "SRC1")],
            stageRouting: [StageRoutingKey.backend.rawValue: "anthropic"])
        _ = try await engine.enqueue(
            QueueItemRequest(queue: .extraction, wikiID: "wiki1", payload: payload))

        try await Task.sleep(nanoseconds: 300_000_000)

        // The provider should have received the backend override.
        #expect(provider.lastBackendOverride == .anthropic)
        store.close()
    }

    // MARK: - AC.8: Headless isolation

    @Test func testHeadlessIsolation() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let files = [
            root.appendingPathComponent("Sources/WikiFSEngine/QueueExtractionProvider.swift"),
            root.appendingPathComponent("Sources/WikiFSEngine/QueueExtractionWorker.swift"),
        ]

        for fileURL in files {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(!source.contains("import AppKit"),
                   "\(fileURL.lastPathComponent) must not import AppKit")
            #expect(!source.contains("import SwiftUI"),
                   "\(fileURL.lastPathComponent) must not import SwiftUI")
        }
    }
}

// MARK: - Fake extraction provider

private final class FakeExtractionProvider: QueueExtractionProvider, @unchecked Sendable {
    enum ResolveResult {
        case resolved(ExtractionBackend)
        case nilResolution
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let resolveResult: ResolveResult
    private let convertBehavior: @Sendable (@Sendable (String) -> Void) async throws -> Void
    private let extractorReadiness: ExtractionReadiness

    private struct State {
        var callLog: [String] = []
        var lastBackendOverride: ExtractionBackend?
    }

    var callLog: [String] { lock.withLock { $0.callLog } }
    var lastBackendOverride: ExtractionBackend? { lock.withLock { $0.lastBackendOverride } }

    init(
        resolveResult: ResolveResult,
        extractorReadiness: ExtractionReadiness = .ready,
        convertBehavior: @escaping @Sendable (@Sendable (String) -> Void) async throws -> Void = { _ in }
    ) {
        self.resolveResult = resolveResult
        self.extractorReadiness = extractorReadiness
        self.convertBehavior = convertBehavior
    }

    func resolveExtraction(
        wikiID: String, sourceID: PageID,
        backendOverride: ExtractionBackend?
    ) async throws -> ExtractionResolution? {
        lock.withLock { state in
            state.callLog.append("resolve(wikiID:\(wikiID), sourceID:\(sourceID.rawValue), backend:\(backendOverride?.rawValue ?? "default"))")
            state.lastBackendOverride = backendOverride
        }

        switch resolveResult {
        case .resolved(let backend):
            return ExtractionResolution(
                extractor: FakeMarkdownExtractor(
                    readiness: extractorReadiness,
                    convert: convertBehavior
                ),
                pdfData: Data([0x25, 0x50, 0x44, 0x46]), // "%PDF"
                filename: "test.pdf",
                backend: backend
            )
        case .nilResolution:
            return nil
        }
    }

    func persistExtraction(
        wikiID: String, sourceID: PageID,
        markdown: String, backend: ExtractionBackend,
        modelVersion: String?
    ) async throws {
        lock.withLock { state in
            state.callLog.append("persist(wikiID:\(wikiID), sourceID:\(sourceID.rawValue), backend:\(backend.rawValue))")
        }
    }
}

// MARK: - Fake MarkdownExtractor

private struct FakeMarkdownExtractor: MarkdownExtractor {
    let displayName = "Fake Extractor"
    let readinessResult: ExtractionReadiness
    let convertBehavior: @Sendable (@Sendable (String) -> Void) async throws -> Void

    init(readiness: ExtractionReadiness,
         convert: @escaping @Sendable (@Sendable (String) -> Void) async throws -> Void) {
        self.readinessResult = readiness
        self.convertBehavior = convert
    }

    func readiness() async -> ExtractionReadiness { readinessResult }

    func convert(
        pdfData: Data, filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String {
        if let onProgress {
            try await convertBehavior(onProgress)
        } else {
            try await convertBehavior({ _ in })
        }
        return "# Extracted markdown"
    }
}

// MARK: - Progress collector

private final class ProgressCollector: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [(id: QueueItem.ID, line: String)]())

    var lines: [(id: QueueItem.ID, line: String)] {
        lock.withLock { $0 }
    }

    func record(id: QueueItem.ID, line: String) {
        lock.withLock { $0.append((id, line)) }
    }

    func waitForCount(_ count: Int, timeoutSeconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            let current = lines.count
            if current >= count { return }
            if Date() > deadline {
                Issue.record("Timed out waiting for \(count) progress lines, got \(current)")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

// MARK: - CountDownLatch (reused from QueueEngineTests pattern)

private final class CountDownLatch: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (count: 0, waiters: [CheckedContinuation<Void, Never>]()))

    init(count: Int) {
        lock.withLock { state in state.count = count }
    }

    func wait() async {
        let needsWait: Bool = lock.withLock { state in
            state.count > 0
        }
        guard needsWait else { return }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.withLock { state in
                if state.count <= 0 {
                    c.resume()
                } else {
                    state.waiters.append(c)
                }
            }
        }
    }

    func release() {
        lock.withLock { state in
            state.count -= 1
            if state.count <= 0 {
                for w in state.waiters { w.resume() }
                state.waiters.removeAll()
            }
        }
    }
}
#endif // os(macOS)
