import Foundation

/// Non-secret extraction settings — which backend to use and the per-backend
/// configuration (model ids, optional base-URL overrides, Docling Serve endpoint).
/// Secrets (the Anthropic + Gemini API keys, a Docling bearer token) are NOT here:
/// they go in Keychain via `ExtractionCredentialStore`, never in a plaintext JSON file.
///
/// App-wide, not per-wiki: an extraction preference is a property of the person
/// using the app, not of any one wiki. Persisted once at the App Group container
/// root as a sibling of `zotero-config.json`. Follows `ZoteroConfig`'s load/save
/// pattern exactly (pure value type, explicit injected directory, atomic write),
/// and `WikiRegistry`'s degrade-to-empty-on-corrupt rule.
public struct ExtractionConfig: JSONSidecarConfig {
    /// Which backend `ExtractionCoordinator.current()` resolves to.
    public var backend: ExtractionBackend

    /// For the `.acp` backend: the provider id (from `AgentProvidersConfig`)
    /// to use for extraction. nil = use the app's default provider. Ignored by
    /// other backends. Forward-compatible: a missing key decodes to nil.
    public var acpProviderId: String?

    /// The Claude model id for the Anthropic backend. Default `claude-sonnet-4-6`
    /// — extraction is a transcription task, so Sonnet's fidelity/cost balance
    /// beats Opus; user-editable to Haiku 4.5 (cheapest) or Opus (hardest layouts).
    public var anthropicModel: String

    /// Optional override of `https://api.anthropic.com` (for a proxy or a
    /// Bedrock/Vertex-compatible gateway). `nil` = the public Anthropic API.
    public var anthropicBaseURLOverride: String?

    /// The Gemini model id for the Gemini backend. Default `gemini-3.5-flash`
    /// — the stable mainline Flash model (cheap, fast, native PDF vision);
    /// user-editable to Flash-Lite (cheapest) or Pro (hardest layouts).
    public var geminiModel: String

    /// Optional override of `https://generativelanguage.googleapis.com`. `nil` =
    /// the public Gemini API (Google AI Studio / API-key surface).
    public var geminiBaseURLOverride: String?

    /// The Docling Serve base URL for the Docling backend, e.g.
    /// `http://localhost:5001`. `nil` until configured.
    public var doclingServeEndpoint: String?

    /// The config's JSON filename inside the App Group container.
    public static let fileName = "extraction-config.json"

    public init(
        backend: ExtractionBackend = .localPdf2md,
        acpProviderId: String? = nil,
        anthropicModel: String = ExtractionConfig.defaultAnthropicModel,
        anthropicBaseURLOverride: String? = nil,
        geminiModel: String = ExtractionConfig.defaultGeminiModel,
        geminiBaseURLOverride: String? = nil,
        doclingServeEndpoint: String? = nil
    ) {
        self.backend = backend
        self.acpProviderId = acpProviderId
        self.anthropicModel = anthropicModel
        self.anthropicBaseURLOverride = anthropicBaseURLOverride
        self.geminiModel = geminiModel
        self.geminiBaseURLOverride = geminiBaseURLOverride
        self.doclingServeEndpoint = doclingServeEndpoint
    }

    /// The default model id used everywhere a model isn't explicitly set, so the
    /// literal lives in one place.
    public static let defaultAnthropicModel = "claude-sonnet-4-6"

    public static let defaultGeminiModel = "gemini-3.5-flash"

    public static let defaultDoclingServeEndpoint = "http://localhost:5001"

    public static let defaultAnthropicBaseURL = "https://api.anthropic.com"

    public static let defaultGeminiBaseURL = "https://generativelanguage.googleapis.com"

    /// The configured model id for the current backend, where applicable (used to
    /// stamp the extraction agent's `version`). nil for backends without a model.
    public var currentModelVersion: String? {
        switch backend {
        case .anthropic: return anthropicModel
        case .gemini: return geminiModel
        case .acp, .localPdf2md, .doclingServe: return nil
        }
    }

    // MARK: - Resilient Codable

    /// Decode each field with `decodeIfPresent` + a default fallback so a missing
    /// key (forward-compat: a new field added later) or an unknown backend raw
    /// value degrades to the default instead of throwing — same philosophy as
    /// `load`'s corrupt-file handling.
    private enum CodingKeys: String, CodingKey {
        case backend, acpProviderId
        case anthropicModel, anthropicBaseURLOverride
        case geminiModel, geminiBaseURLOverride
        case doclingServeEndpoint
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.backend = (try? c.decode(ExtractionBackend.self, forKey: .backend)) ?? .localPdf2md
        self.acpProviderId = try c.decodeIfPresent(String.self, forKey: .acpProviderId)
        self.anthropicModel = try c.decodeIfPresent(String.self, forKey: .anthropicModel)
            ?? ExtractionConfig.defaultAnthropicModel
        self.anthropicBaseURLOverride = try c.decodeIfPresent(String.self, forKey: .anthropicBaseURLOverride)
        self.geminiModel = try c.decodeIfPresent(String.self, forKey: .geminiModel)
            ?? ExtractionConfig.defaultGeminiModel
        self.geminiBaseURLOverride = try c.decodeIfPresent(String.self, forKey: .geminiBaseURLOverride)
        self.doclingServeEndpoint = try c.decodeIfPresent(String.self, forKey: .doclingServeEndpoint)
    }

    // MARK: - Persistence (via `JSONSidecarConfig`)

    /// Load from `extraction-config.json` in `directory`. A missing or corrupt
    /// file degrades to an empty (default) config rather than throwing — same
    /// fresh-install behavior as `ZoteroConfig.load`. Delegates the file read +
    /// decode to `JSONSidecarConfig.load(from:)` and supplies the default config.
    public static func load(from directory: URL) -> ExtractionConfig {
        load(from: directory) ?? ExtractionConfig()
    }
}
