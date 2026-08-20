#if os(macOS)
import Synchronization
import Testing
@testable import WikiFSEngine

@Suite("Daemon transport composition owner", .serialized, .timeLimit(.minutes(1)))
struct DaemonTransportCompositionOwnerTests {
    @Test("retries assembly failure without another app lifecycle event")
    func retriesAssemblyFailure() async {
        let attempts = AssemblyAttempts()
        let handle = RecordingTransportRuntimeHandle()
        let owner = DaemonTransportCompositionOwner(
            retryInterval: .zero
        ) {
            let attempt = await attempts.next()
            if attempt == 1 { throw FirstAssemblyAttemptError() }
            return handle
        }

        await owner.services.startAdmission()
        await owner.start()
        await owner.awaitSettled()

        #expect(await attempts.count == 2)
        #expect(await handle.admissionStartCount() == 1)
        await owner.shutdown()
        #expect(handle.disposeCount == 1)
    }
}

private actor AssemblyAttempts {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }

    var count: Int { value }
}

private struct FirstAssemblyAttemptError: Error {}

private actor AdmissionStarts {
    private var value = 0

    func increment() {
        value += 1
    }

    var count: Int { value }
}

private final class RecordingTransportRuntimeHandle: DaemonTransportRuntimeOwning, @unchecked Sendable {
    let services: DaemonTransportServices
    private let admissionCounter: AdmissionStarts
    private let disposeCounter = Mutex(0)

    init() {
        let starts = AdmissionStarts()
        self.admissionCounter = starts
        services = DaemonTransportServices(
            startAdmission: { await starts.increment() },
            acknowledge: { _ in },
            requestManualReconnect: {},
            events: { AsyncStream { $0.finish() } },
            availability: { .idle },
            stop: {})
    }

    func admissionStartCount() async -> Int { await admissionCounter.count }

    var disposeCount: Int { disposeCounter.withLock { $0 } }

    func dispose() async throws {
        disposeCounter.withLock { $0 += 1 }
    }
}
#endif
