#if os(macOS)
import Foundation

/// Shared lifecycle harness for tests that mount live AppKit or WebKit views
/// inside the single `swift test` host process. These suites are correct in
/// production under user-driven interaction, but the CLI host's single
/// AppKit/WebKit environment can wedge when multiple window-owning suites
/// overlap under Swift Testing's default suite-level parallelism.
///
/// Keep this gate in `Tests/` so the serialization policy is explicit test
/// infrastructure rather than production behavior.
actor HostedAppKitTestGate {
    static let shared = HostedAppKitTestGate()

    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async -> Lease {
        if held {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        held = true
        return Lease { [weak self] in
            await self?.release()
        }
    }

    private func release() {
        if waiters.isEmpty {
            held = false
            return
        }
        let waiter = waiters.removeFirst()
        waiter.resume()
    }

    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var isReleased = false
        private let onRelease: @Sendable () async -> Void

        init(onRelease: @escaping @Sendable () async -> Void) {
            self.onRelease = onRelease
        }

        func release() {
            lock.lock()
            guard !isReleased else {
                lock.unlock()
                return
            }
            isReleased = true
            lock.unlock()
            Task.detached { [onRelease = self.onRelease] in
                await onRelease()
            }
        }

        deinit {
            release()
        }
    }
}

typealias AutocompleteHostedTestGate = HostedAppKitTestGate
#endif
