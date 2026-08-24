import Cordis
import Foundation

/// Stable identity for one integration capability.
public struct IntegrationCapabilityID: Hashable, RawRepresentable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String { rawValue }
}

/// A lazily constructed integration entry point. Mounting a capability only
/// registers this factory; network and subprocess work begins when a consumer
/// asks the resulting entry point to perform an operation.
public struct RegisteredIntegrationCapability: Sendable {
    public typealias Factory = @Sendable () async throws -> any Sendable

    public let id: IntegrationCapabilityID
    private let makeEntryPoint: Factory

    public init(id: IntegrationCapabilityID, makeEntryPoint: @escaping Factory) {
        self.id = id
        self.makeEntryPoint = makeEntryPoint
    }

    public func entryPoint() async throws -> any Sendable {
        try await makeEntryPoint()
    }
}

public enum IntegrationCapabilityRegistryError: Error, Equatable, Sendable {
    case duplicateCapability(IntegrationCapabilityID)
}

/// A reversible, token-owned integration registration.
public struct IntegrationCapabilityRegistration: Sendable {
    private let remove: @Sendable () async -> Void

    fileprivate init(remove: @escaping @Sendable () async -> Void) {
        self.remove = remove
    }

    public func dispose() async {
        await remove()
    }
}

/// Process-scoped registry for optional integration capabilities. Token
/// ownership prevents a stale disposer from removing a later registration.
public actor IntegrationCapabilityRegistry {
    private struct Registration: Sendable {
        let token: UUID
        let capability: RegisteredIntegrationCapability
    }

    private var registrations: [IntegrationCapabilityID: Registration] = [:]

    public init() {}

    public func register(
        _ capability: RegisteredIntegrationCapability
    ) throws -> IntegrationCapabilityRegistration {
        guard registrations[capability.id] == nil else {
            throw IntegrationCapabilityRegistryError.duplicateCapability(capability.id)
        }
        let token = UUID()
        registrations[capability.id] = Registration(token: token, capability: capability)
        return IntegrationCapabilityRegistration { [weak self] in
            await self?.remove(id: capability.id, token: token)
        }
    }

    public func resolve(_ id: IntegrationCapabilityID) -> RegisteredIntegrationCapability? {
        registrations[id]?.capability
    }

    public func capabilityIDs() -> [IntegrationCapabilityID] {
        registrations.keys.sorted { $0.rawValue < $1.rawValue }
    }

    private func remove(id: IntegrationCapabilityID, token: UUID) {
        guard registrations[id]?.token == token else { return }
        registrations.removeValue(forKey: id)
    }
}

public enum IntegrationServiceKeys {
    public static let capabilities = ServiceKey<IntegrationCapabilityRegistry>(
        label: "wiki.integrations")
}
