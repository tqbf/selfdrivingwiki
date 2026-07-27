#if os(macOS)
import Foundation

actor AutocompleteHostedTestGate {
    static let shared = AutocompleteHostedTestGate()

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
            Task {
                await onRelease()
            }
        }

        deinit {
            release()
        }
    }
}
#endif
