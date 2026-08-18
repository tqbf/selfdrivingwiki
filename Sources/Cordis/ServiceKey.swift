import Foundation

/// A typed namespace for service keys.
public enum ServiceRealm: Hashable, Sendable {
    /// The ordinary realm for a context tree.
    case standard
    /// An explicitly isolated realm.
    case isolated(ID)

    public struct ID: Hashable, Sendable {
        public let rawValue: UUID

        public init(rawValue: UUID = UUID()) {
            self.rawValue = rawValue
        }
    }

    public static func isolated(id: ID = ID()) -> ServiceRealm {
        .isolated(id)
    }
}

/// Stable identity for one logical service key.
public struct ServiceIdentity: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// A typed key for one `Sendable` service value.
public struct ServiceKey<Value: Sendable>: Hashable, Sendable {
    public let identity: ServiceIdentity
    public let realm: ServiceRealm
    public let label: String

    private let valueTypeIdentity: ObjectIdentifier

    public init(
        identity: ServiceIdentity = ServiceIdentity(),
        realm: ServiceRealm = .standard,
        label: String
    ) {
        self.identity = identity
        self.realm = realm
        self.label = label
        self.valueTypeIdentity = ObjectIdentifier(Value.self)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity
            && lhs.realm == rhs.realm
            && lhs.valueTypeIdentity == rhs.valueTypeIdentity
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
        hasher.combine(realm)
        hasher.combine(valueTypeIdentity)
    }

    internal var erased: AnyServiceKey {
        AnyServiceKey(
            identity: identity,
            realm: realm,
            valueTypeIdentity: valueTypeIdentity,
            valueTypeName: String(reflecting: Value.self),
            label: label)
    }
}

/// A public, value-only description used in diagnostics and typed errors.
public struct ServiceDescriptor: Hashable, Sendable {
    public let identity: ServiceIdentity
    public let realm: ServiceRealm
    public let valueTypeName: String
    public let label: String

    internal init(_ key: AnyServiceKey) {
        identity = key.identity
        realm = key.realm
        valueTypeName = key.valueTypeName
        label = key.label
    }
}

internal struct AnyServiceKey: Hashable, Sendable {
    let identity: ServiceIdentity
    let realm: ServiceRealm
    let valueTypeIdentity: ObjectIdentifier
    let valueTypeName: String
    let label: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity
            && lhs.realm == rhs.realm
            && lhs.valueTypeIdentity == rhs.valueTypeIdentity
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
        hasher.combine(realm)
        hasher.combine(valueTypeIdentity)
    }
}
