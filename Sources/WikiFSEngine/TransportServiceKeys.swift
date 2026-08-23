import Cordis
import Foundation

public struct TransportProviderID: Hashable, RawRepresentable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String { rawValue }
}

#if os(macOS)
public struct RegisteredTransportProvider: Sendable {
    public typealias Factory = @Sendable () async throws -> DaemonTransportServices

    public let id: TransportProviderID
    private let makeServices: Factory

    public init(id: TransportProviderID, makeServices: @escaping Factory) {
        self.id = id
        self.makeServices = makeServices
    }

    public func services() async throws -> DaemonTransportServices {
        try await makeServices()
    }
}

public enum TransportProviderRegistryError: Error, Equatable, Sendable {
    case duplicateProvider(TransportProviderID)
}

public struct TransportProviderRegistration: Sendable {
    private let remove: @Sendable () async -> Void

    fileprivate init(remove: @escaping @Sendable () async -> Void) {
        self.remove = remove
    }

    public func dispose() async {
        await remove()
    }
}

public actor TransportProviderRegistry {
    private struct Registration: Sendable {
        let token: UUID
        let provider: RegisteredTransportProvider
    }

    private var registrations: [TransportProviderID: Registration] = [:]

    public init() {}

    public func register(
        _ provider: RegisteredTransportProvider
    ) throws -> TransportProviderRegistration {
        guard registrations[provider.id] == nil else {
            throw TransportProviderRegistryError.duplicateProvider(provider.id)
        }
        let token = UUID()
        registrations[provider.id] = Registration(token: token, provider: provider)
        return TransportProviderRegistration { [weak self] in
            await self?.remove(id: provider.id, token: token)
        }
    }

    public func resolve(_ id: TransportProviderID) -> RegisteredTransportProvider? {
        registrations[id]?.provider
    }

    public func providerIDs() -> [TransportProviderID] {
        registrations.keys.sorted { $0.rawValue < $1.rawValue }
    }

    private func remove(id: TransportProviderID, token: UUID) {
        guard registrations[id]?.token == token else { return }
        registrations.removeValue(forKey: id)
    }
}

public enum TransportServiceKeys {
    public static let transport = ServiceKey<TransportProviderRegistry>(label: "wiki.transport")
}
#endif
