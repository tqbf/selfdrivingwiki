import Foundation

/// Cross-suite claim gate for `EmbeddingService`'s PROCESS-GLOBAL test
/// embedder seam (`installTestEmbedder` / `resetTestEmbedder`).
///
/// The embedder is a process singleton, so the suites that install their own
/// deterministic embedder collide under `swift test`'s default parallelism:
/// one suite's `resetTestEmbedder()` teardown removes another suite's
/// embedder mid-run, and the daemon/store cosine leg silently degrades.
/// Suites that use the seam CLAIM this gate for the install→last-use window
/// and release it when done. The gate is an actor: claiming suspends the
/// test task without parking a cooperative-pool thread (`swift test`
/// -safe).
///
/// Usage (suite tests, all within one `.serialized` suite):
///
///     await EmbedderSeamGate.shared.acquire()
///     defer { Task { await EmbedderSeamGate.shared.release() } }
///     EmbeddingService.installTestEmbedder(MyEmbedder())
///     defer { EmbeddingService.resetTestEmbedder() }
actor EmbedderSeamGate {
    static let shared = EmbedderSeamGate()

    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Suspend until no other suite holds the seam, then hold it.
    func acquire() async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hand the seam to the next claimant (or free it).
    func release() {
        guard held else { return }
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            held = false
        }
    }
}
