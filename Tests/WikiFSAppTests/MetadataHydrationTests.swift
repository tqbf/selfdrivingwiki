import Foundation
import Testing
@testable import WikiFS
@testable import WikiFSCore

@MainActor
struct MetadataHydrationTests {
    @Test func subjectChangeCancelsPriorHydration() async {
        let gate = HydrationGate()
        var states: [MetadataHydrationState] = []
        let task = Task { @MainActor in
            await MetadataHydrator.hydrate(subject: .page(PageID(rawValue: "old")), operation: {
                await gate.wait()
                return model(subject: .page(PageID(rawValue: "old")))
            }, publish: { states.append($0) })
        }
        await gate.waitUntilWaiting()
        task.cancel()
        await gate.resume()
        await task.value
        #expect(states == [.loading(subject: .page(PageID(rawValue: "old")))])
    }

    @Test func cancelledHydrationCannotPublish() async {
        var states: [MetadataHydrationState] = []
        let task = Task { @MainActor in
            await MetadataHydrator.hydrate(subject: .source(SourceID(rawValue: "source")), operation: {
                try Task.checkCancellation()
                return model(subject: .source(SourceID(rawValue: "source")))
            }, publish: { states.append($0) })
        }
        task.cancel()
        await task.value
        #expect(states.isEmpty)
    }

    @Test func failedHydrationPublishesTypedFailure() async {
        var states: [MetadataHydrationState] = []
        await MetadataHydrator.hydrate(subject: .chat(ChatID(rawValue: "chat")), operation: {
            throw MetadataProjectionError.missingSource(SourceID(rawValue: "source"))
        }, publish: { states.append($0) })
        #expect(states.count == 2)
        guard case .failed(subject: .chat(let id), let message) = states.last else {
            Issue.record("expected typed failure state")
            return
        }
        #expect(id == ChatID(rawValue: "chat"))
        #expect(message.contains("source"))
    }

    @Test func inMemoryHydrationUsesStoreFallback() {
        #expect(MetadataHydrationReadPath.resolve(readServiceAvailable: false) == .inMemoryStoreFallback)
    }

    @Test func fileHydrationUsesReadService() {
        #expect(MetadataHydrationReadPath.resolve(readServiceAvailable: true) == .readService)
    }

    private func model(subject: MetadataSubject) -> MetadataPanelModel {
        .init(subject: subject, sections: [], emptyState: .none)
    }
}

private actor HydrationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilWaiting() async {
        guard !didStart else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
