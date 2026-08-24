import Cordis
import Foundation
import WikiFSCore

/// The input domain handled by an extraction backend. The case tag keeps PDF,
/// HTML, and transcript backend identifiers in separate namespaces.
public enum ExtractionBackendKind: String, Codable, Hashable, Sendable {
    case pdf
    case html
    case youtubeTranscript
    case rssPodcastTranscript
    case applePodcastTranscript
}

/// Stable registry identity for one extraction adapter.
public struct ExtractionBackendKey: Hashable, Sendable, CustomStringConvertible {
    public let kind: ExtractionBackendKind
    public let backendID: String

    public init(kind: ExtractionBackendKind, backendID: String) {
        self.kind = kind
        self.backendID = backendID
    }

    public var description: String { "\(kind.rawValue)/\(backendID)" }
}

/// A lazily constructed adapter behind the shared extraction seam.
public enum ExtractionBackendAdapter: Sendable {
    case pdf(ExtractionPreparation)
    case html(any HtmlMarkdownExtractor)
    case youtubeTranscript(any YouTubeTranscriptFetching)
    case rssPodcastTranscript(any RSSFeedTranscriptFetching)
    case applePodcastTranscript(any PodcastTranscriptFetching)
}

public struct RegisteredExtractionBackend: Sendable {
    public typealias Factory = @Sendable () async -> ExtractionBackendAdapter

    public let key: ExtractionBackendKey
    private let makeAdapter: Factory

    public init(key: ExtractionBackendKey, makeAdapter: @escaping Factory) {
        self.key = key
        self.makeAdapter = makeAdapter
    }

    public func make() async -> ExtractionBackendAdapter {
        await makeAdapter()
    }
}

public enum ExtractionBackendRegistryError: Error, Equatable, Sendable {
    case duplicateBackend(ExtractionBackendKey)
}

public struct ExtractionBackendRegistration: Sendable {
    private let remove: @Sendable () async -> Void

    fileprivate init(remove: @escaping @Sendable () async -> Void) {
        self.remove = remove
    }

    public func dispose() async {
        await remove()
    }
}

/// Process-scoped extraction adapter registry. Registration is reversible and
/// token-owned, so an old disposer cannot remove a later adapter with the same key.
public actor ExtractionBackendRegistry {
    private struct Registration: Sendable {
        let token: UUID
        let backend: RegisteredExtractionBackend
    }

    private var registrations: [ExtractionBackendKey: Registration] = [:]

    public init() {}

    public func register(
        _ backend: RegisteredExtractionBackend
    ) throws -> ExtractionBackendRegistration {
        guard registrations[backend.key] == nil else {
            throw ExtractionBackendRegistryError.duplicateBackend(backend.key)
        }
        let token = UUID()
        registrations[backend.key] = Registration(token: token, backend: backend)
        return ExtractionBackendRegistration { [weak self] in
            await self?.remove(key: backend.key, token: token)
        }
    }

    public func resolve(_ key: ExtractionBackendKey) -> RegisteredExtractionBackend? {
        registrations[key]?.backend
    }

    public func keys() -> [ExtractionBackendKey] {
        registrations.keys.sorted { $0.description < $1.description }
    }

    private func remove(key: ExtractionBackendKey, token: UUID) {
        guard registrations[key]?.token == token else { return }
        registrations.removeValue(forKey: key)
    }
}

public enum ExtractionServiceKeys {
    public static let backends = ServiceKey<ExtractionBackendRegistry>(label: "wiki.extraction")
}
