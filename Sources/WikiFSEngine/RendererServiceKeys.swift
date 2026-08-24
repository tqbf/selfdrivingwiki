import Cordis
import Foundation

public struct RendererProviderID: Hashable, RawRepresentable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String { rawValue }
}

public struct RegisteredRendererProvider: Sendable {
    public let id: RendererProviderID
    public let services: any RendererServices

    public init(id: RendererProviderID, services: any RendererServices) {
        self.id = id
        self.services = services
    }
}

public enum RendererProviderRegistryError: Error, Equatable, Sendable {
    case duplicateProvider(RendererProviderID)
}

public struct RendererProviderRegistration: Sendable {
    private let remove: @Sendable () async -> Void

    fileprivate init(remove: @escaping @Sendable () async -> Void) {
        self.remove = remove
    }

    public func dispose() async {
        await remove()
    }
}

public actor RendererProviderRegistry {
    private struct Registration: Sendable {
        let token: UUID
        let provider: RegisteredRendererProvider
    }

    private var registrations: [RendererProviderID: Registration] = [:]

    public init() {}

    public func register(
        _ provider: RegisteredRendererProvider
    ) throws -> RendererProviderRegistration {
        guard registrations[provider.id] == nil else {
            throw RendererProviderRegistryError.duplicateProvider(provider.id)
        }
        let token = UUID()
        registrations[provider.id] = Registration(token: token, provider: provider)
        return RendererProviderRegistration { [weak self] in
            await self?.remove(id: provider.id, token: token)
        }
    }

    public func resolve(_ id: RendererProviderID) -> RegisteredRendererProvider? {
        registrations[id]?.provider
    }

    public func providerIDs() -> [RendererProviderID] {
        registrations.keys.sorted { $0.rawValue < $1.rawValue }
    }

    private func remove(id: RendererProviderID, token: UUID) {
        guard registrations[id]?.token == token else { return }
        registrations.removeValue(forKey: id)
    }
}

public enum RendererServiceKeys {
    public static let renderers = ServiceKey<RendererProviderRegistry>(label: "wiki.renderers")
}
