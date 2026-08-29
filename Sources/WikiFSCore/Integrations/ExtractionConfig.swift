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
    /// Which backend the next extraction service preparation resolves to.
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

    /// The HTML→Markdown backend to use when the user explicitly extracts an
    /// HTML source (issue #799 PR1: scaffolding only — extraction still
    /// auto-runs at ingest with the current method; the trigger wiring lands in
    /// PR2, the auto-extraction removal in PR3). `nil` = no default chosen:
    /// the user is prompted to pick a backend before the first extraction.
    /// Mirrors the typed-backend pattern of `backend` but optional, since HTML
    /// has no always-available fallback (defuddle binary may be missing).
    public var htmlBackend: HtmlExtractionBackend?

    /// The podcast→transcript backend to use when the user explicitly
    /// transcribes a podcast source (issue #799 PR4 — framework only here;
    /// the Transcribe trigger and `#if PODCAST_TRANSCRIPTS` gating land in
    /// PR4). `nil` = no default chosen. Currently only `appleTranscript`, with
    /// Whisper/Rev.ai backends as future follow-ups.
    public var podcastBackend: PodcastTranscriptionBackend?

    /// Optional version-free PDF extractor selection. When absent, `backend`
    /// keeps its existing meaning and precedence.
    public var pdfExtractor: ExtractionBackendReference?

    /// Optional version-free HTML extractor selection. When absent,
    /// `htmlBackend` keeps its existing meaning and precedence.
    public var htmlExtractor: ExtractionBackendReference?

    /// Route-indexed selections, one record per typed extraction route
    /// (`ExtractorRouteID` = kind + normalized MIME). A record for a canonical
    /// route takes precedence over the matching legacy `pdfExtractor` /
    /// `htmlExtractor` field; legacy fields remain the fallback when the record
    /// is absent, so pre-route config files resolve exactly as before.
    /// Mutation flows only through `setExtractorSelection(_:for:)` (and the
    /// normalizing initializer/decoder), keeping the array sorted and
    /// duplicate-free at all times. Persisted as a deterministically sorted
    /// array (never a string-keyed dictionary); a missing key decodes to an
    /// empty list.
    public private(set) var routeExtractors: [ExtractorRouteSelectionRecord]

    /// The config's JSON filename inside the App Group container.
    public static let fileName = "extraction-config.json"

    public init(
        backend: ExtractionBackend = .localPdf2md,
        acpProviderId: String? = nil,
        anthropicModel: String = ExtractionConfig.defaultAnthropicModel,
        anthropicBaseURLOverride: String? = nil,
        geminiModel: String = ExtractionConfig.defaultGeminiModel,
        geminiBaseURLOverride: String? = nil,
        doclingServeEndpoint: String? = nil,
        doclingServeTimeoutMilliseconds: Int? = nil,
        htmlBackend: HtmlExtractionBackend? = nil,
        podcastBackend: PodcastTranscriptionBackend? = nil,
        pdfExtractor: ExtractionBackendReference? = nil,
        htmlExtractor: ExtractionBackendReference? = nil,
        routeExtractors: [ExtractorRouteSelectionRecord] = []
    ) {
        self.backend = backend
        self.acpProviderId = acpProviderId
        self.anthropicModel = anthropicModel
        self.anthropicBaseURLOverride = anthropicBaseURLOverride
        self.geminiModel = geminiModel
        self.geminiBaseURLOverride = geminiBaseURLOverride
        self.doclingServeEndpoint = doclingServeEndpoint
        self.doclingServeTimeoutMilliseconds = doclingServeTimeoutMilliseconds
        self.htmlBackend = htmlBackend
        self.podcastBackend = podcastBackend
        self.pdfExtractor = pdfExtractor
        self.htmlExtractor = htmlExtractor
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
        case doclingServeTimeoutMilliseconds
        case htmlBackend, podcastBackend
        case pdfExtractor, htmlExtractor
        case routeExtractors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.backend = DebugLog.trying("init(from:) decode backend") { try c.decode(ExtractionBackend.self, forKey: .backend) } ?? .localPdf2md
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
        // Forward-compat for issue #799 PR1: a config file written before
        // this field shipped (no `htmlBackend`/`podcastBackend` key) decodes
        // to nil — the user picks a backend on first extraction. Mirrors the
        // exact pattern `backend` uses below: `try? c.decode(...)` so a missing
        // key OR an unknown raw value (a future/typo'd backend) degrades
        // gracefully rather than rejecting the whole file. The "default" for
        // these optional fields is `nil` (vs `backend`'s `.localPdf2md`), so a
        // typo silently picks "prompt me" instead of "PDF" — same resilient
        // decode philosophy as `unknownBackendValueDegradesToLocalPdf2md`.
        self.htmlBackend = DebugLog.trying("init(from:) decode htmlBackend") { try c.decode(HtmlExtractionBackend.self, forKey: .htmlBackend) }
        self.podcastBackend = DebugLog.trying("init(from:) decode podcastBackend") { try c.decode(PodcastTranscriptionBackend.self, forKey: .podcastBackend) }
        self.pdfExtractor = DebugLog.trying("init(from:) decode pdfExtractor") { try c.decode(ExtractionBackendReference.self, forKey: .pdfExtractor) }
        self.htmlExtractor = DebugLog.trying("init(from:) decode htmlExtractor") { try c.decode(ExtractionBackendReference.self, forKey: .htmlExtractor) }
        self.routeExtractors = Self.decodedRouteRecords(from: c)
    }

    public func encode(to encoder: any Encoder) throws {
        // Explicit encode so the persisted byte shape stays identical to the
        // synthesized form (encodeIfPresent for optionals) while route records
        // are always written in deterministic route order.
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(backend, forKey: .backend)
        try c.encodeIfPresent(acpProviderId, forKey: .acpProviderId)
        try c.encode(anthropicModel, forKey: .anthropicModel)
        try c.encodeIfPresent(anthropicBaseURLOverride, forKey: .anthropicBaseURLOverride)
        try c.encode(geminiModel, forKey: .geminiModel)
        try c.encodeIfPresent(geminiBaseURLOverride, forKey: .geminiBaseURLOverride)
        try c.encodeIfPresent(doclingServeEndpoint, forKey: .doclingServeEndpoint)
        try c.encodeIfPresent(doclingServeTimeoutMilliseconds, forKey: .doclingServeTimeoutMilliseconds)
        try c.encodeIfPresent(htmlBackend, forKey: .htmlBackend)
        try c.encodeIfPresent(podcastBackend, forKey: .podcastBackend)
        try c.encodeIfPresent(pdfExtractor, forKey: .pdfExtractor)
        try c.encodeIfPresent(htmlExtractor, forKey: .htmlExtractor)
        try c.encode(routeExtractors.sorted(), forKey: .routeExtractors)
    }

    // MARK: - Route selections

    /// The effective version-free selection for one route, applying the
    /// persistence precedence: an exact `routeExtractors` record first, then the
    /// matching legacy reference field for a canonical route (`pdfExtractor` /
    /// `htmlExtractor`), then no selection. The older `backend` / `htmlBackend`
    /// fields are the layer below this one — the resolver falls through to them
    /// exactly as it did before route records existed.
    public func extractorSelection(for route: ExtractorRouteID) -> ExtractionBackendReference? {
        if let record = routeExtractors.first(where: { $0.route == route }) { return record.extractor }
        if route == .canonicalPDF { return pdfExtractor }
        if route == .canonicalHTML { return htmlExtractor }
        return nil
    }

    /// Insert, replace, or remove (`nil`) the selection for one route.
    ///
    /// Dual-write compatibility: a canonical-route write also updates the
    /// matching legacy reference field (`pdfExtractor` / `htmlExtractor`) so old
    /// builds reading those fields resolve the same selection. The older
    /// `backend` / `htmlBackend` fields stay owned by the Settings mapping
    /// (`writePDF` / `writeHTML`), which keeps them truthful when a selection is
    /// expressed through them. Unrelated route records are preserved; removal
    /// drops only this route's record and clears the legacy reference, letting
    /// the legacy fallback layer apply again.
    public mutating func setExtractorSelection(_ extractor: ExtractionBackendReference?, for route: ExtractorRouteID) {
        routeExtractors.removeAll { $0.route == route }
        if let extractor {
            routeExtractors.append(ExtractorRouteSelectionRecord(route: route, extractor: extractor))
            routeExtractors.sort()
        }
        if route == .canonicalPDF {
            pdfExtractor = extractor
        } else if route == .canonicalHTML {
            htmlExtractor = extractor
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
