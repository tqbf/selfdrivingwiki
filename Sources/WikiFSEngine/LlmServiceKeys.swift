import Cordis
import Foundation

/// Stable identity for one model-adapter route.
public struct LlmRoute: Hashable, RawRepresentable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String { rawValue }
}

/// Stable identity for one model-adapter registration.
public struct LlmAdapterID: Hashable, RawRepresentable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String { rawValue }
}

/// One resolved model adapter. The ACP adapter delegates to the existing
/// provider facade, which owns provider selection and prepared backend creation.
public struct LlmAdapter: Sendable {
    public let id: LlmAdapterID
    public let services: any AgentProviderServices

    public init(id: LlmAdapterID, services: any AgentProviderServices) {
        self.id = id
        self.services = services
    }
}

public enum LlmRuntimeError: Error, Equatable, Sendable {
    case duplicateRoute(LlmRoute)
}

/// A reversible registration returned by `LlmRuntime.register`.
public struct LlmAdapterRegistration: Sendable {
    private let remove: @Sendable () async -> Void

    fileprivate init(remove: @escaping @Sendable () async -> Void) {
        self.remove = remove
    }

    public func dispose() async {
        await remove()
    }
}

/// Process-scoped model-adapter registry. Registrations are token-owned so a
/// stale component cannot remove a replacement registered for the same route.
public actor LlmRuntime {
    private struct Registration: Sendable {
        let token: UUID
        let adapter: LlmAdapter
    }

    private var registrations: [LlmRoute: Registration] = [:]

    public init() {}

    public func register(
        route: LlmRoute,
        adapter: LlmAdapter
    ) throws -> LlmAdapterRegistration {
        guard registrations[route] == nil else {
            throw LlmRuntimeError.duplicateRoute(route)
        }
        let token = UUID()
        registrations[route] = Registration(token: token, adapter: adapter)
        return LlmAdapterRegistration { [weak self] in
            await self?.remove(route: route, token: token)
        }
    }

    public func resolve(_ route: LlmRoute) -> LlmAdapter? {
        registrations[route]?.adapter
    }

    private func remove(route: LlmRoute, token: UUID) {
        guard registrations[route]?.token == token else { return }
        registrations.removeValue(forKey: route)
    }
}

/// Stable Cordis identity for the model-adapter runtime seam.
public enum LlmServiceKeys {
    public static let llm = ServiceKey<LlmRuntime>(label: "wiki.llm")
}
