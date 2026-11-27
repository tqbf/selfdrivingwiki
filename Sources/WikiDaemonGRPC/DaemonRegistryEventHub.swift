#if os(macOS)
import Foundation
import WikiDaemonContract
import WikiDaemonGRPCContract

/// In-process fan-out of registry events to gRPC subscribers.
///
/// Producers: the daemon's `wikis.json` mutations publish through
/// ``publish(kind:wikiID:displayName:)`` at the same call site that feeds the
/// XPC firehose — one source of truth, two transports.
///
/// Ordering + overflow contract (plans/app-daemon-wire-contract.md):
/// - The daemon-wide `sequence` stamp is monotonic within this hub (per
///   daemon process; informational for the self-validating registry family).
/// - The subscriber's BOUNDED buffer is the service provider's forwarding
///   loop (``AppDaemonServiceProvider/outstandingEventBound``): it counts
///   received-minus-forwarded events and fails the stream with the typed
///   RESYNC_REQUIRED failure when the bound is exceeded. The bound lives
///   where consumption is observable; this hub never blocks a producer and
///   never silently drops an event.
/// - Registry events are self-validating (no replay ring): a subscriber
///   establishes its baseline with ListWikis, not by replay. On resync the
///   client re-lists and resubscribes.
// `subscribers` and `sequence` are covered by `lock`.
// swiftlint:disable:next unchecked_sendable
public final class DaemonRegistryEventHub: @unchecked Sendable {

    public init() {}

    // The continuation is immutable after init.
    // swiftlint:disable:next unchecked_sendable
    private final class Subscriber: @unchecked Sendable {
        let id = UUID()
        let continuation: AsyncStream<AppDaemonDaemonEvent?>.Continuation
        init(continuation: AsyncStream<AppDaemonDaemonEvent?>.Continuation) {
            self.continuation = continuation
        }
    }
    private let lock = NSLock()
    private var subscribers: [UUID: Subscriber] = [:]
    private var sequence: UInt64 = 0

    /// Live subscriber count. The interop fixtures use it to publish only
    /// once a subscription is actually established (the stream carries no
    /// replay; ordering contract lives in the type doc).
    public var subscriptionCount: Int {
        lock.withLock { subscribers.count }
    }

    /// Subscribe. Returns the stream plus the subscription's id — the id
    /// the caller must present to ``close(subscriptionID:)`` (session
    /// revocation routes through it). A `nil` stream element is the
    /// termination sentinel (revocation, shutdown, or a later hub close).
    /// The caller MUST consume; the bounded buffer plus ``publish``'s
    /// yield-result check enforce the overflow contract (a buffer-full
    /// subscriber's stream ENDS without the sentinel, which the provider
    /// maps to the typed resync failure).
    public func subscribe() -> (id: UUID, stream: AsyncStream<AppDaemonDaemonEvent?>) {
        let (stream, continuation) = AsyncStream<AppDaemonDaemonEvent?>.makeStream(
            // .bufferingOldest is the observable-overflow policy: when the
            // buffer is full, `yield` returns .dropped (the NEW event is
            // not silently accepted), which publish() maps to ending the
            // subscriber's stream — typed resync at the provider.
            bufferingPolicy: .bufferingOldest(Self.perSubscriberBufferBound))
        let subscriber = Subscriber(continuation: continuation)
        lock.lock()
        subscribers[subscriber.id] = subscriber
        let id = subscriber.id
        lock.unlock()

        // Capture the ID, not the subscriber: termination must not keep
        // the subscriber (and its continuation) alive.
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.subscribers.removeValue(forKey: id)
            self.lock.unlock()
        }
        return (id: id, stream: stream)
    }

    /// Per-subscriber buffer bound, enforced by the continuation's own
    /// bounded policy — ``publish`` observes the yield result and ends a
    /// buffer-full subscriber's stream WITHOUT the revocation sentinel,
    /// which is how the provider distinguishes overflow (typed resync
    /// failure) from revocation (plain end).
    static let perSubscriberBufferBound = 256

    /// Publish one registry mutation. Stamps the daemon-wide sequence and
    /// delivers to every subscriber. The stamp+yield pair runs under the
    /// lock so concurrent publishers cannot deliver sequence N+1 before
    /// N (yield is non-blocking and never re-enters this lock). A yield
    /// into a FULL bounded buffer ends that subscriber's stream — the
    /// provider loop sees the termination sentinel and fails the RPC
    /// typed (RESYNC_REQUIRED); no event is silently dropped.
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

        lock.lock()
        sequence += 1
        var stamped = event
        stamped.sequence = sequence
        let targets = Array(subscribers.values)
        for subscriber in targets {
            let result = subscriber.continuation.yield(stamped)
            if case .terminated = result {
                // The consumer already went away; onTermination removed it.
                continue
            }
            if case .dropped = result {
                // The bounded buffer is full: end this subscriber's stream
                // WITHOUT the revocation sentinel — the provider maps a
                // sentinel-free end to the typed resync failure.
                subscriber.continuation.finish()
                subscribers.removeValue(forKey: subscriber.id)
            }
        }
        lock.unlock()
    }

    /// End every subscriber stream (daemon shutdown / listener stop). Plain
    /// end: the client resyncs from authoritative state on reconnect.
    public func closeAll() {
        lock.lock()
        let targets = Array(subscribers.values)
        subscribers.removeAll()
        lock.unlock()
        for subscriber in targets {
            subscriber.continuation.yield(nil)
            subscriber.continuation.finish()
        }
    }

    /// Terminate ONE subscriber's stream without ending others (session
    /// revocation routes here through the stream handle).
    func close(subscriptionID: UUID) {
        lock.lock()
        let subscriber = subscribers.removeValue(forKey: subscriptionID)
        lock.unlock()
        subscriber?.continuation.yield(nil)
        subscriber?.continuation.finish()
    }
}

/// Mapping from the XPC-side registry event kind (the daemon's existing
/// vocabulary) to the proto enum. Exhaustive: an unrecognized kind is a
/// coding bug in the daemon, surfaced as `.unspecified` — which every
/// receiver must treat as "drop after logging" per the semantic rules.
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
