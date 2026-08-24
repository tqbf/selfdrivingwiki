import Cordis
import Foundation
import WikiFSCore

/// Creates URL fetchers from a process-scoped, substitutable dependency.
public struct URLFetchProvider: Sendable {
    public typealias Factory = @Sendable () async throws -> any URLFetchService.URLResourceFetcher

    private let makeFetcher: Factory

    public init(makeFetcher: @escaping Factory) {
        self.makeFetcher = makeFetcher
    }

    public func fetcher() async throws -> any URLFetchService.URLResourceFetcher {
        try await makeFetcher()
    }
}

/// Creates a Zotero client from one configuration and credential snapshot.
public struct ZoteroClientProvider: Sendable {
    public typealias ReadConfiguration = @Sendable () -> ZoteroConfig
    public typealias ReadCredential = @Sendable () -> String?
    public typealias MakeFetcher = @Sendable () -> any ZoteroClient.RequestFetcher

    private let readConfiguration: ReadConfiguration
    private let readCredential: ReadCredential
    private let makeFetcher: MakeFetcher

    public init(
        readConfiguration: @escaping ReadConfiguration,
        readCredential: @escaping ReadCredential,
        makeFetcher: @escaping MakeFetcher
    ) {
        self.readConfiguration = readConfiguration
        self.readCredential = readCredential
        self.makeFetcher = makeFetcher
    }

    public func client(apiBaseURL: URL) throws -> ZoteroClient {
        let configuration = readConfiguration()
        guard let libraryID = configuration.libraryID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !libraryID.isEmpty,
              let apiKey = readCredential()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            throw ZoteroClient.ZoteroError.notConfigured
        }
        return ZoteroClient(
            config: ZoteroClient.Config(libraryID: libraryID, apiKey: apiKey),
            fetcher: makeFetcher(),
            baseURL: apiBaseURL)
    }
}

/// A typed lazy integration result. Add a case only when a consumer has a
/// stable capability contract for that integration.
public enum IntegrationEntryPoint: Sendable {
    case urlFetch(any URLFetchService.URLResourceFetcher)
    case zotero(ZoteroClient)
}

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
    public typealias Factory = @Sendable () async throws -> IntegrationEntryPoint

    public let id: IntegrationCapabilityID
    private let makeEntryPoint: Factory

    public init(id: IntegrationCapabilityID, makeEntryPoint: @escaping Factory) {
        self.id = id
        self.makeEntryPoint = makeEntryPoint
    }

    public func entryPoint() async throws -> IntegrationEntryPoint {
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
