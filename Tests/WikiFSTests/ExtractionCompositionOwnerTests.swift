#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WikiFSCore
@testable import WikiFSEngine

@Suite("Extraction composition owner", .serialized, .timeLimit(.minutes(1)))
struct ExtractionCompositionOwnerTests {
    @Test("facade is unavailable before assembly and delegates after install")
    func unavailableThenInstalled() async throws {
        let handle = RecordingExtractionRuntimeHandle()
        let owner = ExtractionCompositionOwner { handle }

        await #expect(throws: ExtractionServicesError.unavailable) {
            try await owner.services.prepare()
        }
        await owner.start()
        await owner.awaitSettled()

        let preparation = try await owner.services.prepare()
        #expect(preparation.extractor.displayName == "recording")
        await owner.shutdown()
        #expect(handle.disposeCount == 1)
        await #expect(throws: ExtractionServicesError.unavailable) {
            try await owner.services.prepare()
        }
    }

    @Test("invalidated installation cannot make the facade available")
    func invalidatedInstallationCannotInstall() async {
        let facade = MutableExtractionServices()
        let installation = MutableExtractionServices.Installation()

        await facade.invalidate(installation)
        await facade.install(RecordingExtractionServices(), for: installation)

        await #expect(throws: ExtractionServicesError.unavailable) {
            try await facade.prepare()
        }
    }

    @Test("invalidation removes an installed service")
    func invalidationRemovesInstalledService() async throws {
        let facade = MutableExtractionServices()
        let installation = MutableExtractionServices.Installation()

        await facade.install(RecordingExtractionServices(), for: installation)
        _ = try await facade.prepare()
        await facade.invalidate(installation)

        await #expect(throws: ExtractionServicesError.unavailable) {
            try await facade.prepare()
        }
    }

    @Test("shutdown is idempotent")
    func repeatedShutdownDisposesOnce() async {
        let handle = RecordingExtractionRuntimeHandle()
        let owner = ExtractionCompositionOwner { handle }
        await owner.start()
        await owner.awaitSettled()

        await owner.shutdown()
        await owner.shutdown()

        #expect(handle.disposeCount == 1)
    }

    @Test("late assembly cannot install after shutdown")
    func lateAssemblyIsDisposed() async {
        let cancellationObserved = ExtractionAssemblyGate()
        let releaseLateResult = ExtractionAssemblyGate()
        let handle = RecordingExtractionRuntimeHandle()
        let owner = ExtractionCompositionOwner {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                cancellationObserved.open()
            }
            await releaseLateResult.wait()
            return handle
        }
        await owner.start()

        let shutdownTask = Task { await owner.shutdown() }
        await cancellationObserved.wait()
        releaseLateResult.open()
        await shutdownTask.value

        #expect(handle.disposeCount == 1)
        await #expect(throws: ExtractionServicesError.unavailable) {
            try await owner.services.prepare()
        }
    }
}

private final class RecordingExtractionRuntimeHandle: ExtractionRuntimeOwning, Sendable {
    let services: any ExtractionServices = RecordingExtractionServices()
    private let count = Mutex(0)

    var disposeCount: Int { count.withLock { $0 } }

    func dispose() async throws {
        count.withLock { $0 += 1 }
    }
}

private struct RecordingExtractionServices: ExtractionServices {
    func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation {
        ExtractionPreparation(
            extractor: RecordingExtractor(),
            backend: backendOverride ?? .localPdf2md,
            modelVersion: nil)
    }

    func prepareHTML(
        backendOverride: HtmlExtractionBackend?
    ) async throws -> any HtmlMarkdownExtractor {
        TagBasedHtmlExtractor()
    }
}

private struct RecordingExtractor: MarkdownExtractor {
    var displayName: String { "recording" }
    func readiness() async -> ExtractionReadiness { .ready }
    func convert(
        pdfData: Data,
        filename: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> String { "recording" }
}

private final class ExtractionAssemblyGate: Sendable {
    private struct State {
        var isOpen = false
        var continuation: AsyncStream<Void>.Continuation?
    }
    private let state = Mutex(State())

    func wait() async {
        let pair = AsyncStream<Void>.makeStream()
        let open = state.withLock { state -> Bool in
            if state.isOpen { return true }
            state.continuation = pair.continuation
            return false
        }
        if open { pair.continuation.finish() }
        for await _ in pair.stream { break }
    }

    func open() {
        let continuation = state.withLock { state -> AsyncStream<Void>.Continuation? in
            state.isOpen = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.yield(())
        continuation?.finish()
    }
}
#endif
