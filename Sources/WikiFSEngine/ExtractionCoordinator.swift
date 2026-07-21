#if os(macOS)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import WikiFSCore

/// Resolves the user's selected PDF→Markdown backend (`MarkdownExtractor`) from
/// the persisted `ExtractionConfig` + Keychain secrets. The two extraction call
/// sites (`AgentOperationRunner.runMultiIngest` and `SourceDetailView.
/// runExtraction`) ask it for the current extractor and then drive it through
/// `readiness()` / `convert()`, so they stay backend-agnostic.
///
/// App-wide (one instance, `@State` in `WikiFSApp`, threaded like `AgentLauncher`):
/// an extraction preference belongs to the person, not to any one wiki. The
/// selected backend — like every other extraction preference — lives in
/// `ExtractionConfig` JSON (sibling of `zotero-config.json`), the same single
/// source of truth `ExtractionSettingsView`'s draft+Save edits. `current()`
/// re-reads config off disk each call so a Settings Save is picked up
/// immediately by the next extract.
@MainActor
@Observable
public final class ExtractionCoordinator {
    public let containerDirectory: URL
    public let credentialStore: any ExtractionCredentialStore
    /// The ACP credential store — used by the `.acp` backend to read the
    /// provider's API key from Keychain (the SAME key the chat/ingest path
    /// uses — no second secret). Defaults to the Keychain-backed store.
    public let acpCredentialStore: any ACPCredentialStore
    /// Shared HTTP fetcher for the remote/model backends (production: a generous
    /// `URLSession`; tests inject a fake).
    public let fetcher: any HTTPRequestFetcher

    /// Factory for the local pdf2md extractor (`LocalPdf2MarkdownExtractor`).
    /// Injected because that type lives in the app target (it delegates to the
    /// AppKit-coupled `PdfExtractionService`). The app passes a concrete closure
    /// at wiring time; `current()` calls it when the configured backend is
    /// `.localPdf2md`.
    private let localExtractorFactory: @MainActor () -> any MarkdownExtractor

    public init(
        containerDirectory: URL,
        credentialStore: any ExtractionCredentialStore = KeychainExtractionCredentialStore(),
        acpCredentialStore: any ACPCredentialStore = KeychainACPCredentialStore(),
        fetcher: any HTTPRequestFetcher = URLSessionRequestFetcher(),
        localExtractorFactory: @escaping @MainActor () -> any MarkdownExtractor
    ) {
        self.containerDirectory = containerDirectory
        self.credentialStore = credentialStore
        self.acpCredentialStore = acpCredentialStore
        self.fetcher = fetcher
        self.localExtractorFactory = localExtractorFactory
    }

    /// The latest non-secret config off disk. Re-loaded each access so a
    /// Settings Save is picked up immediately by the next `current()` call.
    public var config: ExtractionConfig {
        ExtractionConfig.load(from: containerDirectory)
    }

    /// Resolve the configured backend to a concrete extractor, pulling per-backend
    /// config + secrets fresh each call. Cheap; call once at the start of an
    /// extract (the backend won't change mid-run). The local backend has no
    /// secrets; Docling's endpoint is the raw config value (empty when unset, so
    /// its `readiness()` reports `.needsSetup`); Anthropic falls back to the
    /// public API base URL when no override is configured.
    public func current() -> any MarkdownExtractor {
        let cfg = config
        switch cfg.backend {
        case .localPdf2md:
            return localExtractorFactory()
        case .acp:
            if let client = ACPExtractionClient.resolveProvider(
                containerDirectory: containerDirectory,
                acpProviderId: cfg.acpProviderId,
                acpCredentialStore: acpCredentialStore) {
                return client
            }
            // Fall back to the local extractor if no ACP provider is configured
            // — better than crashing. The readiness probe on the ACP client
            // would surface the real issue, but here we couldn't even build one.
            DebugLog.config("ExtractionCoordinator: .acp backend but no provider resolvable — falling back to local pdf2md")
            return localExtractorFactory()
        case .anthropic:
            let base = cfg.anthropicBaseURLOverride.flatMap(URL.init(string:))
                ?? URL(string: ExtractionConfig.defaultAnthropicBaseURL)!
            return AnthropicExtractionClient(
                model: cfg.anthropicModel,
                apiKey: credentialStore.secret(.anthropicAPIKey) ?? "",
                baseURL: base,
                fetcher: fetcher)
        case .gemini:
            let base = cfg.geminiBaseURLOverride.flatMap(URL.init(string:))
                ?? URL(string: ExtractionConfig.defaultGeminiBaseURL)!
            return GeminiExtractionClient(
                model: cfg.geminiModel,
                apiKey: credentialStore.secret(.geminiAPIKey) ?? "",
                baseURL: base,
                fetcher: fetcher)
        case .doclingServe:
            return DoclingServeClient(
                endpoint: cfg.doclingServeEndpoint ?? "",
                apiToken: credentialStore.secret(.doclingServeToken),
                fetcher: fetcher)
        }
    }
}
#endif
