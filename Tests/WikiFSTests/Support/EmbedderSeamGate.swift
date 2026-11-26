import Foundation

/// Cross-suite claim gate for `EmbeddingService`'s PROCESS-GLOBAL test
/// embedder seam (`installTestEmbedder` / `resetTestEmbedder`).
///
/// The embedder is a process singleton, so the suites that install their own
/// deterministic embedder collide under `swift test`'s default parallelism:
/// one suite's `resetTestEmbedder()` teardown removes another suite's
/// embedder mid-run, and the daemon/store cosine leg silently degrades.
/// Every test that touches the seam — installing, resetting, or depending on
/// the slot being nil — CLAIMS this gate for its claim→last-use window and
/// releases it when done. The gate is an actor: claiming suspends the
/// test task without parking a cooperative-pool thread (`swift test`-safe).
///
/// Releases are OWNERSHIP-CHECKED. `acquire()` mints a one-time token, and
/// `release(_:)` frees the baton only when the token matches the current
/// holder. Teardown must enqueue `Task { release(token) }` (an actor hop);
/// under load that task can be delayed past a later claimant's acquire, and
/// an unattributed release would then free a baton the new holder owns,
/// admitting a third suite mid-window. A stale token is ignored instead.
///
/// Usage (suite tests, all within one `.serialized` suite):
///
///     let seam = await EmbedderSeamGate.shared.acquire()
///     EmbeddingService.installTestEmbedder(MyEmbedder())
///     defer {
///         EmbeddingService.resetTestEmbedder()   // reset FIRST, while holding…
///         Task { await EmbedderSeamGate.shared.release(seam) }   // …then hand off.
///     }
actor EmbedderSeamGate {
    static let shared = EmbedderSeamGate()

    /// Opaque claim handle minted by ``acquire()``. Only the gate creates
    /// tokens, and ``release(_:)`` compares the token against the current
    /// holder — a delayed teardown task cannot free a baton a later
    /// claimant holds.
    struct Token: Sendable, Equatable {
        fileprivate let value: UInt64
    }

    private var holder: UInt64?
    private var nextToken: UInt64 = 0
    private var waiters: [(token: UInt64, continuation: CheckedContinuation<Void, Never>)] = []

    /// Suspend until no other suite holds the seam, then hold it.
    func acquire() async -> Token {
        let token = nextToken
        nextToken += 1
        if holder == nil {
            holder = token
            return Token(value: token)
        }
        await withCheckedContinuation { waiters.append((token, $0)) }
        return Token(value: token)
    }

    /// Hand the seam to the next claimant (or free it). A token that does
    /// not match the current holder is a stale teardown and is ignored.
    func release(_ token: Token) {
        guard holder == token.value else { return }
        if let next = waiters.first {
            waiters.removeFirst()
            holder = next.token
            next.continuation.resume()
        } else {
            holder = nil
        }
    }
}
