import Foundation

/// A closed local extraction tool. Provider-backed backends remain represented
/// by `ExtractionBackend` so a tool version can never be presented as a model.
public enum ExtractionTool: String, Codable, CaseIterable, Sendable {
    case docling
    case pdf2md
    case html
    case appleTTML
    case youtubeCaptions
    case rssPodcastTranscript
    case materializerSidecar
    case transcript
}

/// The producer recovered from immutable markdown-version provenance.
public enum ExtractionProducer: Equatable, Sendable {
    case backend(ExtractionBackend)
    case tool(ExtractionTool)
    case legacy(rawTechnique: String?)
}

/// Typed read projection over a source markdown version and its existing PROV
/// activity/agent records. No writer is introduced in Phase 1.
public struct ExtractionProvenance: Equatable, Sendable {
    public let markdownVersionID: SourceMarkdownVersionID
    public let sourceID: SourceID
    public let origin: SourceMarkdownOrigin
    public let producer: ExtractionProducer
    public let providerID: ProviderID?
    public let modelID: ModelID?
    public let toolVersion: String?
    public let createdAt: Date
    public let sourceVersionID: SourceVersionID?

    public init(
        markdownVersionID: SourceMarkdownVersionID,
        sourceID: SourceID,
        origin: SourceMarkdownOrigin,
        producer: ExtractionProducer,
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
