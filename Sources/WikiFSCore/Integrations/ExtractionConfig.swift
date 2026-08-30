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

    /// Typed Docling Serve request timeout (#1159). Compatibility default:
    /// 600 seconds — the value the shared extraction HTTP fetcher always
    /// applied before the field existed, so old config files (which lack the
    /// key) keep their exact previous behavior.
    public var doclingServeTimeoutMilliseconds: Int?

    /// The effective timeout: the configured value, or the 600-second
    /// compatibility default when absent.
    public var effectiveDoclingServeTimeoutMilliseconds: Int {
        guard let doclingServeTimeoutMilliseconds,
              doclingServeTimeoutMilliseconds > 0,
              doclingServeTimeoutMilliseconds <= 1_800_000
        else { return 600_000 }
        return doclingServeTimeoutMilliseconds
    }

    /// The podcast→transcript backend to use when the user explicitly
    /// transcribes a podcast source (issue #799 PR4 — framework only here;
    /// the Transcribe trigger and `#if PODCAST_TRANSCRIPTS` gating land in
    /// PR4). `nil` = no default chosen. Currently only `appleTranscript`, with
    /// Whisper/Rev.ai backends as future follow-ups.
    public var podcastBackend: PodcastTranscriptionBackend?

    /// Route-indexed selections, one record per typed extraction route
    /// (`ExtractorRouteID` = kind + normalized MIME). A record for a canonical
    /// route is the SOLE persisted extractor selection — the generic reference
    /// names a host adapter or an installed package lineage, and the route
    /// supplies the input format. The decoder migrates the retired
    /// `backend` / `htmlBackend` / `pdfExtractor` / `htmlExtractor` keys into
    /// these records; encode never writes them again. Mutation flows only
    /// through `setExtractorSelection(_:for:)` (and the normalizing
    /// initializer/decoder), keeping the array sorted and duplicate-free at
    /// all times. Persisted as a deterministically sorted array (never a
    /// string-keyed dictionary); a missing key decodes to an empty list.
    public private(set) var routeExtractors: [ExtractorRouteSelectionRecord]

    /// The config's JSON filename inside the App Group container.
    public static let fileName = "extraction-config.json"

    public init(
        acpProviderId: String? = nil,
        anthropicModel: String = ExtractionConfig.defaultAnthropicModel,
        anthropicBaseURLOverride: String? = nil,
        geminiModel: String = ExtractionConfig.defaultGeminiModel,
        geminiBaseURLOverride: String? = nil,
        doclingServeEndpoint: String? = nil,
        doclingServeTimeoutMilliseconds: Int? = nil,
        podcastBackend: PodcastTranscriptionBackend? = nil,
        routeExtractors: [ExtractorRouteSelectionRecord] = []
    ) {
        self.acpProviderId = acpProviderId
        self.anthropicModel = anthropicModel
        self.anthropicBaseURLOverride = anthropicBaseURLOverride
        self.geminiModel = geminiModel
        self.geminiBaseURLOverride = geminiBaseURLOverride
        self.doclingServeEndpoint = doclingServeEndpoint
        self.doclingServeTimeoutMilliseconds = doclingServeTimeoutMilliseconds
        self.podcastBackend = podcastBackend
        self.routeExtractors = routeExtractors.normalizedForPersistence().records
    }

    /// The default model id used everywhere a model isn't explicitly set, so the
    /// literal lives in one place.
    public static let defaultAnthropicModel = "claude-sonnet-4-6"

    /// Decode-resilience bound: how many consecutive malformed route records a
    /// decode tolerates before assuming the coder is not advancing the array
    /// index and truncating (see `decodedRouteRecords`).
    static let maximumConsecutiveRouteDecodeFailures = 8

    public static let defaultGeminiModel = "gemini-3.5-flash"

    public static let defaultDoclingServeEndpoint = "http://localhost:5001"

    public static let defaultAnthropicBaseURL = "https://api.anthropic.com"

    public static let defaultGeminiBaseURL = "https://generativelanguage.googleapis.com"

    // MARK: - Resilient Codable

    /// Decode each field with `decodeIfPresent` + a default fallback so a missing
    /// key (forward-compat: a new field added later) or an unknown raw value
    /// degrades to the default instead of throwing — same philosophy as
    /// `load`'s corrupt-file handling.
    private enum CodingKeys: String, CodingKey {
        case backend, acpProviderId
        case anthropicModel, anthropicBaseURLOverride
        case geminiModel, geminiBaseURLOverride
        case doclingServeEndpoint
        case doclingServeTimeoutMilliseconds
        case htmlBackend, podcastBackend
        case pdfExtractor, htmlExtractor
        case routeExtractors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.acpProviderId = try c.decodeIfPresent(String.self, forKey: .acpProviderId)
        self.anthropicModel = try c.decodeIfPresent(String.self, forKey: .anthropicModel)
            ?? ExtractionConfig.defaultAnthropicModel
        self.anthropicBaseURLOverride = try c.decodeIfPresent(String.self, forKey: .anthropicBaseURLOverride)
        self.geminiModel = try c.decodeIfPresent(String.self, forKey: .geminiModel)
            ?? ExtractionConfig.defaultGeminiModel
        self.geminiBaseURLOverride = try c.decodeIfPresent(String.self, forKey: .geminiBaseURLOverride)
        self.doclingServeEndpoint = try c.decodeIfPresent(String.self, forKey: .doclingServeEndpoint)
        // #1159: absent key = the 600-second compatibility default via
        // `effectiveDoclingServeTimeoutMilliseconds`.
        self.doclingServeTimeoutMilliseconds = try c.decodeIfPresent(Int.self, forKey: .doclingServeTimeoutMilliseconds)
        // The retired `backend` / `htmlBackend` keys are decode-only migration
        // inputs consumed as locals below (#1178): each value migrates into a
        // route record at most once and never becomes stored state. A missing
        // key OR an unknown raw value (a future/typo'd backend) degrades
        // gracefully — the same resilient decode philosophy as every other
        // field.
        let legacyBackend = DebugLog.trying("init(from:) decode backend") {
            try c.decode(ExtractionBackend.self, forKey: .backend)
        } ?? .localPdf2md
        // Forward-compat for issue #799 PR1: a config file written before
        // this field shipped (no `htmlBackend`/`podcastBackend` key) decodes
        // to nil — the user picks a backend on first extraction. `try?`
        // decoding means a typo silently picks "prompt me" instead of a
        // wrong backend.
        let legacyHTMLBackend = DebugLog.trying("init(from:) decode htmlBackend") {
            try c.decode(HtmlExtractionBackend.self, forKey: .htmlBackend)
        }
        self.podcastBackend = DebugLog.trying("init(from:) decode podcastBackend") { try c.decode(PodcastTranscriptionBackend.self, forKey: .podcastBackend) }
        var routes = Self.decodedRouteRecords(from: c)
        // One-time migration: every retired format-specific selection key is a
        // decode-only input. Each canonical route adopts its legacy value only
        // when no route record already claims the route, so a file written by
        // any earlier build resolves to the same selection it always had.
        let legacyPDF = DebugLog.trying("init(from:) decode legacy pdfExtractor") {
            try c.decode(ExtractionBackendReference.self, forKey: .pdfExtractor)
        }
        let legacyHTML = DebugLog.trying("init(from:) decode legacy htmlExtractor") {
            try c.decode(ExtractionBackendReference.self, forKey: .htmlExtractor)
        }
        if routes.contains(where: { $0.route == .canonicalPDF }) == false {
            if let legacyPDF {
                routes.append(.init(route: .canonicalPDF, extractor: legacyPDF))
            } else if let migrated = Self.migratedSelection(fromPDFBackend: legacyBackend) {
                routes.append(.init(route: .canonicalPDF, extractor: migrated))
            }
        }
        if routes.contains(where: { $0.route == .canonicalHTML }) == false {
            if let legacyHTML {
                routes.append(.init(route: .canonicalHTML, extractor: legacyHTML))
            } else if let legacyHTMLBackend,
                      let migrated = Self.migratedSelection(fromHTMLBackend: legacyHTMLBackend) {
                routes.append(.init(route: .canonicalHTML, extractor: migrated))
            }
        }
        self.routeExtractors = routes.normalizedForPersistence().records
    }

    /// Legacy `backend` values map onto generic host references. `.localPdf2md`
    /// was the shipped default, so it leaves the record absent and the bundled
    /// default-route policy supplies the reviewed pdf2md lineage instead.
    private static func migratedSelection(
        fromPDFBackend backend: ExtractionBackend
    ) -> ExtractionBackendReference? {
        guard backend != .localPdf2md,
              let adapterID = HostExtractorID(rawValue: backend.rawValue) else { return nil }
        return .host(HostExtractorReference(adapterID: adapterID))
    }

    /// Legacy `htmlBackend` values map onto generic host references.
    private static func migratedSelection(
        fromHTMLBackend backend: HtmlExtractionBackend
    ) -> ExtractionBackendReference? {
        guard let adapterID = HostExtractorID(rawValue: backend.rawValue) else { return nil }
        return .host(HostExtractorReference(adapterID: adapterID))
    }

    public func encode(to encoder: any Encoder) throws {
        // Explicit encode so the persisted byte shape stays identical to the
        // synthesized form (encodeIfPresent for optionals) while route records
        // are always written in deterministic route order. The retired
        // `backend` / `htmlBackend` / `pdfExtractor` / `htmlExtractor` keys are
        // decode-only migration inputs and never re-enter the file — the route
        // records are the sole persisted extractor selection.
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(acpProviderId, forKey: .acpProviderId)
        try c.encode(anthropicModel, forKey: .anthropicModel)
        try c.encodeIfPresent(anthropicBaseURLOverride, forKey: .anthropicBaseURLOverride)
        try c.encode(geminiModel, forKey: .geminiModel)
        try c.encodeIfPresent(geminiBaseURLOverride, forKey: .geminiBaseURLOverride)
        try c.encodeIfPresent(doclingServeEndpoint, forKey: .doclingServeEndpoint)
        try c.encodeIfPresent(doclingServeTimeoutMilliseconds, forKey: .doclingServeTimeoutMilliseconds)
        try c.encodeIfPresent(podcastBackend, forKey: .podcastBackend)
        try c.encode(routeExtractors.sorted(), forKey: .routeExtractors)
    }

    // MARK: - Route selections

    /// The configured version-free selection for one route. The decoder
    /// migrates old format-specific extractor keys into this generic table.
    public func extractorSelection(for route: ExtractorRouteID) -> ExtractionBackendReference? {
        routeExtractors.first(where: { $0.route == route })?.extractor
    }

    /// Insert, replace, or remove (`nil`) the selection for one route.
    /// Unrelated route records are preserved. No format-specific selection
    /// field is written.
    public mutating func setExtractorSelection(_ extractor: ExtractionBackendReference?, for route: ExtractorRouteID) {
        routeExtractors.removeAll { $0.route == route }
        if let extractor {
            routeExtractors.append(ExtractorRouteSelectionRecord(route: route, extractor: extractor))
            routeExtractors.sort()
        }
    }

    /// Resilient route-record decode, matching the config's degrade-don't-throw
    /// philosophy: a missing key decodes to an empty list, a wholly malformed
    /// array degrades to empty through the logged decode seam, a malformed
    /// single record is skipped so later valid records still decode, and
    /// duplicate route records are resolved deterministically
    /// (canonically-greatest record wins, independent of file order) with one
    /// bounded diagnostic.
    private static func decodedRouteRecords(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> [ExtractorRouteSelectionRecord] {
        guard container.contains(.routeExtractors) else { return [] }
        guard var array = DebugLog.trying("init(from:) decode routeExtractors", operation: { try container.nestedUnkeyedContainer(forKey: .routeExtractors) }) else {
            return []
        }
        var records: [ExtractorRouteSelectionRecord] = []
        // A decoder is not required to advance an unkeyed container when a
        // decode throws — Foundation's JSONDecoder leaves the index in place —
        // so each failed record is explicitly consumed before continuing.
        // Bound consecutive failures anyway: a coder that cannot even consume
        // an arbitrary JSON value must degrade to a truncated decode, never hang.
        var consecutiveFailures = 0
        while array.isAtEnd == false {
            let countBefore = records.count
            if let record = DebugLog.trying("init(from:) decode routeExtractors record", operation: { try array.decode(ExtractorRouteSelectionRecord.self) }) {
                records.append(record)
            } else if DebugLog.trying("init(from:) consume malformed routeExtractors record", operation: { try array.decode(AnyJSONValue.self) }) != nil {
                consecutiveFailures = 0
                continue
            }
            if records.count == countBefore {
                consecutiveFailures += 1
                if consecutiveFailures > Self.maximumConsecutiveRouteDecodeFailures {
                    DebugLog.config("ExtractionConfig: routeExtractors decode stalled after \(consecutiveFailures) malformed records; truncating the remainder")
                    break
                }
            } else {
                consecutiveFailures = 0
            }
        }
        let normalized = records.normalizedForPersistence()
        if normalized.droppedDuplicates > 0 {
            DebugLog.config("ExtractionConfig: resolved \(normalized.droppedDuplicates) duplicate route selection record(s); kept the canonically-greatest record per route")
        }
        return normalized.records
    }

    // MARK: - Persistence (via `JSONSidecarConfig`)

    /// Load from `extraction-config.json` in `directory`. A missing or corrupt
    /// file degrades to an empty (default) config rather than throwing — same
    /// fresh-install behavior as `ZoteroConfig.load`. Delegates the file read +
    /// decode to `JSONSidecarConfig.load(from:)` and supplies the default config.
    ///
    /// The loaded config is NOT baked with the bundled default-route policy:
    /// the file holds only explicit user choices, and defaults participate at
    /// read time through `selectionOrDefault(for:)`. Baking them in at load
    /// would pin this build's policy into the user's file on the next save.
    public static func load(from directory: URL) -> ExtractionConfig {
        load(from: directory) ?? ExtractionConfig()
    }
}

/// A `Decodable` that accepts any JSON value. Used only to consume a malformed
/// array element so decoding can continue past it — a failed decode does not
/// advance an unkeyed container's index. Each `try?` here is one attempt of
/// the type ladder, not error swallowing: the final fallback rethrows.
private struct AnyJSONValue: Decodable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        // The type ladder below intentionally ignores each failed attempt: an
        // unmatched type is expected while probing for the value's shape, and
        // the final fallback rethrows. Ignoring here is genuinely correct.
        // swiftlint:disable:next silent_try_optional
        if (try? container.decode([AnyJSONValue].self)) != nil { return }
        // swiftlint:disable:next silent_try_optional
        if (try? container.decode([String: AnyJSONValue].self)) != nil { return }
        // swiftlint:disable:next silent_try_optional
        if (try? container.decode(String.self)) != nil { return }
        // swiftlint:disable:next silent_try_optional
        if (try? container.decode(Double.self)) != nil { return }
        // swiftlint:disable:next silent_try_optional
        if (try? container.decode(Bool.self)) != nil { return }
        throw DecodingError.dataCorrupted(.init(
            codingPath: container.codingPath,
            debugDescription: "unsupported JSON value"))
    }
}
