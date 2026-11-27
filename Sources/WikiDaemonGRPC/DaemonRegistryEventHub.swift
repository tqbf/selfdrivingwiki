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

    /// Subscribe. Yields stamped events; a `nil` element is the termination
    /// sentinel (revocation, shutdown, or a later hub close). The caller MUST
    /// consume; the provider's forwarding-loop bound is what detects a stuck
    /// consumer and fails the stream typed.
    public func subscribe() -> AsyncStream<AppDaemonDaemonEvent?> {
        let (stream, continuation) = AsyncStream<AppDaemonDaemonEvent?>.makeStream(
            bufferingPolicy: .unbounded)
        let subscriber = Subscriber(continuation: continuation)
        lock.lock()
        subscribers[subscriber.id] = subscriber
        lock.unlock()

        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.subscribers.removeValue(forKey: subscriber.id)
            self.lock.unlock()
        }
        return stream
    }

    /// Publish one registry mutation. Stamps the daemon-wide sequence and
    /// delivers to every subscriber. The wiki id is the raw ULID string (the
    /// hub stays domain-free; callers adapt their typed ids at the edge).
    public func publish(kind: DaemonRegistryEventKind, wikiIDRawValue: String, displayName: String?) {
        lock.lock()
        sequence += 1
        let stamped = sequence
        lock.unlock()

        let event = AppDaemonDaemonEvent.with {
            $0.sequence = stamped
            $0.registry = AppDaemonRegistryEvent.with {
                $0.kind = AppDaemonRegistryEvent.Kind(kind)
                $0.wikiID = .with { $0.value = wikiIDRawValue }
                if let displayName {
                    $0.displayName = displayName
                }
            }
        }

        lock.lock()
        let targets = Array(subscribers.values)
        lock.unlock()
        for subscriber in targets {
            subscriber.continuation.yield(event)
        }
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
