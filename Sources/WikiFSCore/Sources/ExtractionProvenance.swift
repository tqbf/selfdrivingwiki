import Foundation
import WikiFSTypes

/// A closed local extraction tool. Provider-backed backends remain represented
/// by `ExtractionBackend` so a tool version can never be presented as a model.
public enum ExtractionTool: String, Codable, CaseIterable, Sendable {
    case docling
    case pdf2md
    case html = "html-to-markdown"
    case appleTTML = "apple-ttml"
    case youtubeCaptions = "youtube-captions"
    case rssPodcastTranscript = "rss-podcast-transcript"
    case vimeoTranscript = "vimeo-transcript"
    case materializerSidecar = "materializer-sidecar"
    case bytelessOEmbedSynthetic = "byteless-oembed-synthetic"
    case transcript
}

/// Exact identity of one installed extractor package revision, as persisted in
/// an extraction activity plan.
///
/// Exact package identity and protocol metadata for one extraction.
///
/// The payload uses the validated identity types at the persistence boundary.
/// JSON still contains their stable scalar representations through their
/// `Codable` implementations. A package version is never presented as a model
/// version.
public typealias ExtractionInstalledPackageProducer = ExtractorPackageExecutionProvenance

/// Exact identity of one HOST-produced on-device speech transcription. The
/// speech floor runs in the host process — no installed package produced the
/// transcript — so this producer names the engine that ran, the locale it ran
/// with, and the exact fetcher revision that acquired the audio, as separate
/// fields. The technique is the fixed `on-device-speech` marker.
public struct ExtractionHostSpeechProducer: Equatable, Sendable, Codable {
    /// The closed technique tag for host speech. One value, spelled once.
    public static let technique = "on-device-speech"

    /// The speech engine identifier (e.g. `speechanalyzer`). Bounded,
    /// control-character-free — a review fact, never free text.
    public let engine: String
    /// The BCP 47 locale identifier the transcription ran with.
    public let localeID: String
    /// The exact acquisition fetcher identity (revision, registration,
    /// protocol revision) that downloaded the analyzed audio.
    public let acquisitionFetcher: ExtractionInstalledPackageProducer

    static let maximumFieldCharacterCount = 256

    public init(engine: String, localeID: String, acquisitionFetcher: ExtractionInstalledPackageProducer) throws {
        let fields = [engine, localeID]
        for value in fields {
            guard value.isEmpty == false,
                  value.utf8.count <= Self.maximumFieldCharacterCount,
                  value.contains("\0") == false else {
                throw AppendDerivedMarkdownError.invalidHostSpeechProducer
            }
        }
        self.engine = engine
        self.localeID = localeID
        self.acquisitionFetcher = acquisitionFetcher
    }
}

/// Cross-target provenance exposed by a process-backed HTML extractor without
/// importing the engine module into the core store target.
public protocol ProcessPackageProvenanceProviding: Sendable {
    var packageProvenance: ExtractorPackageExecutionProvenance { get }
}

/// The producer recovered from immutable markdown-version provenance.
public enum ExtractionProducer: Equatable, Sendable {
    case backend(ExtractionBackend)
    case tool(ExtractionTool)
    case legacy(rawTechnique: String?)
    case installedPackage(ExtractionInstalledPackageProducer)
    /// Host-produced on-device speech: never marked `.installedPackage`,
    /// never claimed for agent cleanup.
    case hostSpeech(ExtractionHostSpeechProducer)
}

/// Typed read projection over a source markdown version and its existing PROV
/// activity/agent records. No writer is introduced in Phase 1.
public struct ExtractionProvenance: Equatable, Sendable {
    public let markdownVersionID: SourceMarkdownVersionID
    public let sourceID: SourceID
    public let origin: SourceMarkdownOrigin
    /// `nil` means legacy data supplied neither an activity nor a technique.
    /// It is distinct from `.legacy(rawTechnique: nil)`, which carries a joined
    /// legacy activity whose producer could not be classified.
    public let producer: ExtractionProducer?
    public let providerID: ProviderID?
    public let modelID: ModelID?
    public let toolVersion: String?
    public let createdAt: Date
    public let sourceVersionID: SourceVersionID?

    public init(
        markdownVersionID: SourceMarkdownVersionID,
        sourceID: SourceID,
        origin: SourceMarkdownOrigin,
        producer: ExtractionProducer?,
        providerID: ProviderID?,
        modelID: ModelID?,
        toolVersion: String?,
        createdAt: Date,
        sourceVersionID: SourceVersionID?
    ) {
        self.markdownVersionID = markdownVersionID
        self.sourceID = sourceID
        self.origin = origin
        self.producer = producer
        self.providerID = providerID
        self.modelID = modelID
        self.toolVersion = toolVersion
        self.createdAt = createdAt
        self.sourceVersionID = sourceVersionID
    }
}

/// Validation failures for a typed derived-markdown append. These errors are
/// raised before the store writes any row, so callers can safely retry after
/// correcting the request.
public enum AppendDerivedMarkdownError: Error, Equatable, Sendable {
    case nonDerivedOrigin(SourceMarkdownOrigin)
    case modelRequiresProviderBackedProducer
    case providerFieldsUnsupportedForLocalTool
    case toolVersionUnsupportedForBackend
    case invalidInstalledPackageProducer
    case invalidHostSpeechProducer
    case foreignSourceVersion(SourceVersionID)
    case missingSource(SourceID)
    /// A package transcript was requested without the source's immutable
    /// initial version. The write is refused before any row is written.
    case missingInitialSourceVersion(SourceID)
}
