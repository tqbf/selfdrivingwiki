import Foundation
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
final class ExtractionCoordinator {
    let containerDirectory: URL
    let credentialStore: any ExtractionCredentialStore
    /// Shared HTTP fetcher for the remote/model backends (production: a generous
    /// `URLSession`; tests inject a fake).
    let fetcher: any HTTPRequestFetcher

    init(
        containerDirectory: URL,
        credentialStore: any ExtractionCredentialStore = KeychainExtractionCredentialStore(),
        fetcher: any HTTPRequestFetcher = URLSessionRequestFetcher()
    ) {
        self.containerDirectory = containerDirectory
        self.credentialStore = credentialStore
        self.fetcher = fetcher
    }

    /// The latest non-secret config off disk. Re-loaded each access so a
    /// Settings Save is picked up immediately by the next `current()` call.
    var config: ExtractionConfig {
        ExtractionConfig.load(from: containerDirectory)
    }

    /// Resolve the configured backend to a concrete extractor, pulling per-backend
    /// config + secrets fresh each call. Cheap; call once at the start of an
    /// extract (the backend won't change mid-run). The local backend has no
    /// secrets; Docling's endpoint is the raw config value (empty when unset, so
    /// its `readiness()` reports `.needsSetup`); Anthropic falls back to the
    /// public API base URL when no override is configured.
    func current() -> any MarkdownExtractor {
        let cfg = config
        switch cfg.backend {
        case .localPdf2md:
            return LocalPdf2MarkdownExtractor()
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
