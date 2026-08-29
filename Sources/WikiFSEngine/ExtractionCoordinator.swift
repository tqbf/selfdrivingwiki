#if os(macOS)
import Foundation
import WikiFSCore

/// The immutable extraction inputs and public provenance for one operation.
/// Secrets and endpoint construction inputs remain private to the runtime.
public struct ExtractionPreparation: Sendable {
    public let extractor: any MarkdownExtractor
    public let backend: ExtractionBackend
    public let modelVersion: String?
    public let technique: String?
    /// Exact package provenance for an installed process-backed extractor.
    /// Built-in and transcript preparations leave this nil.
    public let packageProvenance: ExtractionInstalledPackageProducer?

    public init(
        extractor: any MarkdownExtractor,
        backend: ExtractionBackend,
        modelVersion: String?,
        technique: String? = nil,
        packageProvenance: ExtractionInstalledPackageProducer? = nil
    ) {
        self.extractor = extractor
        self.backend = backend
        self.modelVersion = modelVersion
        self.technique = technique
        self.packageProvenance = packageProvenance
    }
}

public enum ExtractionServicesError: Error, Equatable, Sendable, LocalizedError {
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Extraction services are unavailable."
        }
    }
}

/// Public operation-scoped extraction resolution. Each call returns a fresh
/// extractor built from one frozen configuration and credential snapshot.
public protocol ExtractionServices: Sendable {
    func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation
    func prepareHTML(
        backendOverride: HtmlExtractionBackend?
    ) async throws -> any HtmlMarkdownExtractor
}

public extension ExtractionServices {
    func prepare() async throws -> ExtractionPreparation {
        try await prepare(backendOverride: nil)
    }

    func prepareHTML() async throws -> any HtmlMarkdownExtractor {
        try await prepareHTML(backendOverride: nil)
    }

    func prepareHTML(
        backendOverride: HtmlExtractionBackend?
    ) async throws -> any HtmlMarkdownExtractor {
        throw ExtractionServicesError.unavailable
    }
}

public struct UnavailableExtractionServices: ExtractionServices {
    public init() {}

    public func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation {
        throw ExtractionServicesError.unavailable
    }

    public func prepareHTML(
        backendOverride: HtmlExtractionBackend?
    ) async throws -> any HtmlMarkdownExtractor {
        throw ExtractionServicesError.unavailable
    }
}

/// A stable process facade that can exist before asynchronous Cordis assembly.
public actor MutableExtractionServices: ExtractionServices {
    public struct Installation: Hashable, Sendable {
        fileprivate let id = UUID()

        public init() {}
    }

    private var installed: any ExtractionServices
    private var activeInstallation: Installation?
    private var invalidatedInstallations: Set<Installation> = []

    public init(initial: any ExtractionServices = UnavailableExtractionServices()) {
        installed = initial
    }

    public func install(
        _ services: any ExtractionServices,
        for installation: Installation
    ) {
        guard !invalidatedInstallations.contains(installation) else { return }
        installed = services
        activeInstallation = installation
    }

    public func invalidate(_ installation: Installation) {
        invalidatedInstallations.insert(installation)
        guard activeInstallation == installation else { return }
        installed = UnavailableExtractionServices()
        activeInstallation = nil
    }

    public func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation {
        try await installed.prepare(backendOverride: backendOverride)
    }
}

/// Operation resolver owned by the extraction Cordis context.
public actor ExtractionRuntime: ExtractionServices {
    public typealias ConfigurationReader = @Sendable () throws -> ExtractionConfig
    public typealias BackendResolver = @Sendable (
        _ configuration: ExtractionConfig,
        _ effectiveBackend: ExtractionBackend
    ) async throws -> ExtractionPreparation

    private let readConfiguration: ConfigurationReader
    private let resolveBackend: BackendResolver
    private var disposed = false

    public init(
        readConfiguration: @escaping ConfigurationReader,
        resolveBackend: @escaping BackendResolver
    ) {
        self.readConfiguration = readConfiguration
        self.resolveBackend = resolveBackend
    }

    public func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation {
        guard !disposed else { throw ExtractionServicesError.unavailable }
        let configuration = try readConfiguration()
        let effectiveBackend = backendOverride ?? configuration.backend
        let preparation = try await resolveBackend(configuration, effectiveBackend)
        guard !disposed else { throw ExtractionServicesError.unavailable }
        return preparation
    }

    public func prepareHTML(
        backendOverride: HtmlExtractionBackend?
    ) async throws -> any HtmlMarkdownExtractor {
        throw ExtractionServicesError.unavailable
    }

    public func dispose() {
        disposed = true
    }
}

enum ExtractionDefaultURL {
    static let anthropic = required(ExtractionConfig.defaultAnthropicBaseURL)
    static let gemini = required(ExtractionConfig.defaultGeminiBaseURL)

    private static func required(_ value: String) -> URL {
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid built-in extraction base URL: \(value)")
        }
        return url
    }
}

@MainActor
private final class LegacyExtractionServices: ExtractionServices {
    private let containerDirectory: URL
    private let credentialStore: any ExtractionCredentialStore
    private let acpCredentialStore: any ACPCredentialStore
    private let fetcher: any HTTPRequestFetcher
    private let localExtractorFactory: @MainActor () -> any MarkdownExtractor

    init(
        containerDirectory: URL,
        credentialStore: any ExtractionCredentialStore,
        acpCredentialStore: any ACPCredentialStore,
        fetcher: any HTTPRequestFetcher,
        localExtractorFactory: @escaping @MainActor () -> any MarkdownExtractor
    ) {
        self.containerDirectory = containerDirectory
        self.credentialStore = credentialStore
        self.acpCredentialStore = acpCredentialStore
        self.fetcher = fetcher
        self.localExtractorFactory = localExtractorFactory
    }

    func prepare(backendOverride: ExtractionBackend?) async throws -> ExtractionPreparation {
        let configuration = ExtractionConfig.load(from: containerDirectory)
        let backend = backendOverride ?? configuration.backend
        let extractor: any MarkdownExtractor
        switch backend {
        case .localPdf2md:
            extractor = localExtractorFactory()
        case .acp:
            extractor = ACPExtractionClient.resolveProvider(
                containerDirectory: containerDirectory,
                acpProviderId: configuration.acpProviderId,
                acpCredentialStore: acpCredentialStore) ?? localExtractorFactory()
        case .anthropic:
            extractor = AnthropicExtractionClient(
                model: configuration.anthropicModel,
                apiKey: credentialStore.secret(.anthropicAPIKey) ?? "",
                baseURL: configuration.anthropicBaseURLOverride.flatMap(URL.init(string:))
                    ?? ExtractionDefaultURL.anthropic,
                fetcher: fetcher)
        case .gemini:
            extractor = GeminiExtractionClient(
                model: configuration.geminiModel,
                apiKey: credentialStore.secret(.geminiAPIKey) ?? "",
                baseURL: configuration.geminiBaseURLOverride.flatMap(URL.init(string:))
                    ?? ExtractionDefaultURL.gemini,
                fetcher: fetcher)
        case .doclingServe:
            // #1159 (PR 4 review HIGH-2): the legacy extraction coordinator
            // must not keep a direct Docling execution path — Docling runs
            // through the reviewed revision 2 package, whose lineage receives
            // the token only after explicit authorization. This legacy seam
            // fails closed instead.
            throw ExtractionServicesError.unavailable
        }
        let modelVersion: String? = switch backend {
        case .anthropic: configuration.anthropicModel
        case .gemini: configuration.geminiModel
        case .localPdf2md, .acp, .doclingServe: nil
        }
        return ExtractionPreparation(
            extractor: extractor,
            backend: backend,
            modelVersion: modelVersion)
    }
}

/// Main-actor adapter retained at existing UI seams. It owns no configuration,
/// credentials, HTTP client, or backend construction state.
@MainActor
@Observable
public final class ExtractionCoordinator {
    private let services: any ExtractionServices

    public init(services: any ExtractionServices) {
        self.services = services
    }

    /// Test compatibility seam. Production composition must inject the process
    /// service facade and must not construct extraction dependencies here.
    public convenience init(
        containerDirectory: URL,
        credentialStore: any ExtractionCredentialStore = KeychainExtractionCredentialStore(),
        acpCredentialStore: any ACPCredentialStore = KeychainACPCredentialStore(),
        fetcher: any HTTPRequestFetcher = URLSessionRequestFetcher(),
        localExtractorFactory: @escaping @MainActor () -> any MarkdownExtractor
    ) {
        let services = LegacyExtractionServices(
            containerDirectory: containerDirectory,
            credentialStore: credentialStore,
            acpCredentialStore: acpCredentialStore,
            fetcher: fetcher,
            localExtractorFactory: localExtractorFactory)
        self.init(services: services)
    }

    public func prepare(
        backendOverride: ExtractionBackend? = nil
    ) async throws -> ExtractionPreparation {
        try await services.prepare(backendOverride: backendOverride)
    }

    public func prepareHTML(
        backendOverride: HtmlExtractionBackend? = nil
    ) async throws -> any HtmlMarkdownExtractor {
        try await services.prepareHTML(backendOverride: backendOverride)
    }
}
#endif
