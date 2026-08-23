import Cordis
import Foundation
import WikiFSCore
import WikiFSSearch

public enum SearchProviderKind: String, Codable, Hashable, Sendable {
    case lexical
    case embeddings
}

public struct SearchProviderKey: Hashable, Sendable, CustomStringConvertible {
    public let kind: SearchProviderKind
    public let providerID: String

    public init(kind: SearchProviderKind, providerID: String) {
        self.kind = kind
        self.providerID = providerID
    }

    public var description: String { "\(kind.rawValue)/\(providerID)" }
}

#if os(macOS)
/// Lazy factory for the existing per-wiki Tantivy runtime composition.
public struct TantivySearchProvider: Sendable {
    public typealias Factory = @Sendable (
        SearchRuntimeIdentity,
        any TantivyContentSource,
        any SearchChangeStreamFactory
    ) -> SearchRuntimeAssembly

    private let makeAssembly: Factory

    public init(makeAssembly: @escaping Factory) {
        self.makeAssembly = makeAssembly
    }

    public func assembly(
        identity: SearchRuntimeIdentity,
        contentSource: any TantivyContentSource,
        changeStreamFactory: any SearchChangeStreamFactory
    ) -> SearchRuntimeAssembly {
        makeAssembly(identity, contentSource, changeStreamFactory)
    }
}
#endif

/// Lazy access to the existing process-wide embedding composition.
public struct EmbeddingsSearchProvider: Sendable {
    public typealias Configure = @Sendable () async -> Void
    public typealias SelectedIdentifier = @Sendable () -> String
    public typealias Availability = @Sendable () -> Bool

    private let configureOperation: Configure
    private let selectedIdentifierOperation: SelectedIdentifier
    private let availabilityOperation: Availability

    public init(
        configure: @escaping Configure,
        selectedIdentifier: @escaping SelectedIdentifier,
        isAvailable: @escaping Availability
    ) {
        self.configureOperation = configure
        self.selectedIdentifierOperation = selectedIdentifier
        self.availabilityOperation = isAvailable
    }

    public func configure() async {
        await configureOperation()
    }

    public func selectedIdentifier() -> String {
        selectedIdentifierOperation()
    }

    public var isAvailable: Bool {
        availabilityOperation()
    }
}

public enum SearchProviderAdapter: Sendable {
    #if os(macOS)
    case tantivy(TantivySearchProvider)
    #endif
    case embeddings(EmbeddingsSearchProvider)
}

public struct RegisteredSearchProvider: Sendable {
    public let key: SearchProviderKey
    public let adapter: SearchProviderAdapter

    public init(key: SearchProviderKey, adapter: SearchProviderAdapter) {
        self.key = key
        self.adapter = adapter
    }
}

public enum SearchProviderRegistryError: Error, Equatable, Sendable {
    case duplicateProvider(SearchProviderKey)
}

public struct SearchProviderRegistration: Sendable {
    private let remove: @Sendable () async -> Void

    fileprivate init(remove: @escaping @Sendable () async -> Void) {
        self.remove = remove
    }

    public func dispose() async {
        await remove()
    }
}

/// Process-scoped search provider registry. Token ownership prevents an old
/// disposer from removing a later provider registered under the same key.
public actor SearchProviderRegistry {
    private struct Registration: Sendable {
        let token: UUID
        let provider: RegisteredSearchProvider
    }

    private var registrations: [SearchProviderKey: Registration] = [:]

    public init() {}

    public func register(
        _ provider: RegisteredSearchProvider
    ) throws -> SearchProviderRegistration {
        guard registrations[provider.key] == nil else {
            throw SearchProviderRegistryError.duplicateProvider(provider.key)
        }
        let token = UUID()
        registrations[provider.key] = Registration(token: token, provider: provider)
        return SearchProviderRegistration { [weak self] in
            await self?.remove(key: provider.key, token: token)
        }
    }

    public func resolve(_ key: SearchProviderKey) -> RegisteredSearchProvider? {
        registrations[key]?.provider
    }

    public func keys() -> [SearchProviderKey] {
        registrations.keys.sorted { $0.description < $1.description }
    }

    private func remove(key: SearchProviderKey, token: UUID) {
        guard registrations[key]?.token == token else { return }
        registrations.removeValue(forKey: key)
    }
}

public enum SearchServiceKeys {
    public static let providers = ServiceKey<SearchProviderRegistry>(label: "wiki.search")
}
