#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiDaemonGRPCContract

/// In-process fan-out of registry events to gRPC subscribers.
///
/// Producers: the daemon's `wikis.json` mutations publish through
/// ``publish(kind:wikiIDRawValue:displayName:)`` at the same call site that
/// feeds the XPC firehose — one source of truth, two transports.
///
/// Ordering + overflow contract (plans/app-daemon-wire-contract.md):
/// - The daemon-wide `sequence` stamp is monotonic within this hub (per
///   daemon process; informational for the self-validating registry
///   family). Stamp+yield are serialized under the hub lock, so concurrent
///   publishers cannot deliver sequence N+1 before N.
/// - Each subscriber's buffer is bounded; a buffer-full publish ENDS that
///   subscriber's stream and records ``TerminalReason/overflow``. The
///   provider reads the reason when the stream ends and fails the RPC
///   typed (RESYNC_REQUIRED). Revocation records ``TerminalReason/revoked``
///   and cancels the RPC out-of-band — a subscriber stalled in transport
///   flow control is interrupted rather than waited on.
/// - Registry events are self-validating (no replay ring): a subscriber
///   establishes its baseline with ListWikis, not by replay. On resync the
///   client re-lists and resubscribes.
// `subscribers`, `sequence`, and `endedReasons` are covered by `lock`.
// swiftlint:disable:next unchecked_sendable
public final class DaemonRegistryEventHub: @unchecked Sendable {

    public init() {}

    // `subscribers` and `sequence` are covered by `lock`.
    // swiftlint:disable:next unchecked_sendable
    private final class Subscriber {
        let id = UUID()
        let continuation: AsyncStream<AppDaemonDaemonEvent?>.Continuation
        /// Set when this subscriber hit its buffer bound. Read by
        /// ``terminalReason`` AFTER the stream ends; the overflow path
        /// finishes the stream WITHOUT the revocation sentinel, and this
        /// flag tells the two endings apart.
        var overflowed = false

        init(continuation: AsyncStream<AppDaemonDaemonEvent?>.Continuation) {
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var subscribers: [UUID: Subscriber] = [:]
    private var sequence: UInt64 = 0
    /// Terminal reasons for subscriptions whose stream has ended. The
    /// provider consults it via ``terminalReason(subscriptionID:)`` when
    /// its forwarding loop completes. Bounded: entries live until read.
    private var endedReasons: [UUID: TerminalReason] = [:]

    /// Why a subscription's stream ended. `.none` is only possible for a
    /// client-initiated cancellation (the RPC framework cancels the
    /// handler; the loop never completes on its own).
    public enum TerminalReason: Sendable, Equatable {
        case overflow
        case revoked
        case shutdown
    }

    /// Live subscriber count. The interop fixtures use it to publish only
    /// once a subscription is actually established (the stream carries no
    /// replay; ordering contract lives in the type doc).
    public var subscriptionCount: Int {
        lock.withLock { subscribers.count }
    }

    /// Subscribe. Returns the stream plus the subscription's id — the id
    /// the caller must present to ``close(subscriptionID:)`` and
    /// ``terminalReason(subscriptionID:)``. A `nil` stream element is the
    /// termination sentinel (revocation or shutdown); a sentinel-free end
    /// is the overflow path. The caller MUST consume.
    public func subscribe() -> (id: UUID, stream: AsyncStream<AppDaemonDaemonEvent?>) {
        let (stream, continuation) = AsyncStream<AppDaemonDaemonEvent?>.makeStream(
            // .bufferingOldest is the observable-overflow policy: when the
            // buffer is full, `yield` returns .dropped (the NEW event is
            // not accepted), which publish() maps to ending the
            // subscriber's stream with TerminalReason.overflow.
            bufferingPolicy: .bufferingOldest(Self.perSubscriberBufferBound))
        let subscriber = Subscriber(continuation: continuation)
        lock.lock()
        subscribers[subscriber.id] = subscriber
        let id = subscriber.id
        lock.unlock()

        // Capture the ID, not the subscriber: termination must not keep
        // the subscriber (and its continuation) alive. Runs OUTSIDE the
        // hub lock (AsyncStream may invoke this synchronously).
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.subscribers.removeValue(forKey: id)
            self.lock.unlock()
        }
        return (id: id, stream: stream)
    }

    /// The per-subscriber buffer bound. Overflow is OBSERVED (yield result)
    /// and surfaced typed, never silent.
    static let perSubscriberBufferBound = 256

    /// Publish one registry mutation. The stamp+yield pair runs under the
    /// hub lock so concurrent publishers cannot deliver sequence N+1
    /// before N. A buffer-full subscriber is DETACHED under the lock and
    /// finalized OUTSIDE it — AsyncStream may invoke onTermination
    /// synchronously from finish(), and that callback takes this same
    /// lock: finalizing inside would deadlock the hub.
    public func publish(kind: DaemonRegistryEventKind, wikiIDRawValue: String, displayName: String?) {
        let event = AppDaemonDaemonEvent.with {
            $0.registry = AppDaemonRegistryEvent.with {
                $0.kind = AppDaemonRegistryEvent.Kind(kind)
                $0.wikiID = .with { $0.value = wikiIDRawValue }
                if let displayName {
                    $0.displayName = displayName
                }
            }
        }

        var overflowing: Subscriber?
        lock.lock()
        sequence += 1
        var stamped = event
        stamped.sequence = sequence
        let targets = Array(subscribers.values)
        for subscriber in targets {
            let result = subscriber.continuation.yield(stamped)
            if case .dropped = result {
                // Buffer full: end this subscriber's stream WITHOUT the
                // revocation sentinel, recorded as TerminalReason.overflow.
                subscriber.overflowed = true
                endedReasons[subscriber.id] = .overflow
                subscribers.removeValue(forKey: subscriber.id)
                overflowing = subscriber
            }
        }
        lock.unlock()

        // Finalize the overflowed subscriber OUTSIDE the lock: finish()
        // may invoke onTermination synchronously, which needs the lock.
        overflowing?.continuation.finish()
    }

    /// End every subscriber stream with the shutdown reason (daemon
    /// shutdown / listener stop). Removal happens under the lock; the
    /// sentinel + finish run outside it.
    public func closeAll() {
        lock.lock()
        let targets = Array(subscribers.values)
        subscribers.removeAll()
        for subscriber in targets {
            endedReasons[subscriber.id] = .shutdown
        }
        lock.unlock()
        for subscriber in targets {
            subscriber.continuation.yield(nil)
            subscriber.continuation.finish()
        }
    }

    /// Terminate ONE subscriber's stream with the REVOKED reason (session
    /// revocation routes here through the stream handle). Detached under
    /// the lock, finalized outside it — same deadlock discipline as
    /// ``publish``.
    func close(subscriptionID: UUID) {
        var subscriber: Subscriber?
        lock.lock()
        if let removed = subscribers.removeValue(forKey: subscriptionID) {
            endedReasons[subscriptionID] = .revoked
            subscriber = removed
        }
        lock.unlock()
        guard let subscriber else { return }
        subscriber.continuation.yield(nil)
        subscriber.continuation.finish()
    }

    /// Why the given subscription's stream ended. `.none` means the
    /// consumer cancelled (client-initiated); the provider's loop cannot
    /// complete on its own without one of the recorded reasons.
    public func terminalReason(subscriptionID: UUID) -> TerminalReason? {
        lock.withLock { endedReasons[subscriptionID] }
    }
}

/// Mapping from the XPC-side registry event kind (the daemon's existing
/// vocabulary) to the proto enum. Exhaustive: an unrecognized kind is a
/// coding bug in the daemon, surfaced as `.unspecified` — which every
/// receiver must treat as a typed failure per the semantic rules.
extension AppDaemonRegistryEvent.Kind {
    init(_ kind: DaemonRegistryEventKind) {
        switch kind {
        case .created: self = .created
        case .renamed: self = .renamed
        case .deleted: self = .deleted
        }
    }
}
#endif
