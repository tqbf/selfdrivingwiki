import Foundation

/// Stable identity for one logical event key.
public struct EventIdentity: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// The dispatch contract of one event. The mode is a compile-time property
/// of the key, not a runtime option: each mode is one of these marker types.
public protocol EventDispatchMode: Sendable {
    static var kind: EventModeKind { get }
}

public enum EventModeKind: Hashable, Sendable {
    /// Sequential dispatch; listener errors are ignored by contract.
    case emit
    /// Sequential dispatch; listener errors propagate.
    case serial
    /// Concurrent dispatch; all listeners must finish; first error propagates.
    case parallel
    /// Concurrent dispatch; first settled listener decides the outcome.
    case bail
    /// Sequential pass-through dispatch; listeners may transform or short-circuit.
    case waterfall
}

public struct EmitMode: EventDispatchMode {
    public init() {}
    public static var kind: EventModeKind { .emit }
}

public struct SerialMode: EventDispatchMode {
    public init() {}
    public static var kind: EventModeKind { .serial }
}

public struct ParallelMode: EventDispatchMode {
    public init() {}
    public static var kind: EventModeKind { .parallel }
}

public struct BailMode: EventDispatchMode {
    public init() {}
    public static var kind: EventModeKind { .bail }
}

public struct WaterfallMode: EventDispatchMode {
    public init() {}
    public static var kind: EventModeKind { .waterfall }
}

/// A typed key for one event. `Mode` fixes the dispatch contract at compile
/// time: a waterfall key cannot be dispatched as an emit key.
public struct EventKey<Payload: Sendable, Mode: EventDispatchMode>: Hashable, Sendable {
    public let identity: EventIdentity
    public let label: String

    private let payloadTypeIdentity: ObjectIdentifier

    public init(
        identity: EventIdentity = EventIdentity(),
        label: String
    ) {
        self.identity = identity
        self.label = label
        self.payloadTypeIdentity = ObjectIdentifier(Payload.self)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity
            && lhs.payloadTypeIdentity == rhs.payloadTypeIdentity
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
        hasher.combine(payloadTypeIdentity)
    }

    internal var erased: AnyEventKey {
        AnyEventKey(
            identity: identity,
            label: label,
            payloadTypeIdentity: payloadTypeIdentity,
            payloadTypeName: String(reflecting: Payload.self),
            modeKind: Mode.kind)
    }
}

/// A public, value-only description used in diagnostics and typed errors.
public struct EventDescriptor: Hashable, Sendable {
    public let identity: EventIdentity
    public let label: String
    public let payloadTypeName: String
    public let modeKind: EventModeKind

    internal init(_ key: AnyEventKey) {
        identity = key.identity
        label = key.label
        payloadTypeName = key.payloadTypeName
        modeKind = key.modeKind
    }
}

/// One registered reversible event listener.
public struct ListenerID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

internal struct AnyEventKey: Hashable, Sendable {
    let identity: EventIdentity
    let label: String
    let payloadTypeIdentity: ObjectIdentifier
    let payloadTypeName: String
    let modeKind: EventModeKind

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity
            && lhs.payloadTypeIdentity == rhs.payloadTypeIdentity
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
        hasher.combine(payloadTypeIdentity)
    }
}

/// The erased simple listener shape shared by emit, serial, parallel, and bail
/// dispatch. The wrapper performs the payload cast; a mismatch is a contract
/// violation and throws.
internal typealias AnySimpleListener = @Sendable (any Sendable) async throws -> Void

/// The erased waterfall listener shape. `next` receives and returns the
/// erased payload; omitting the call short-circuits the remaining chain.
internal typealias AnyWaterfallListener = @Sendable (
    any Sendable,
    @Sendable (any Sendable) async throws -> any Sendable
) async throws -> any Sendable
