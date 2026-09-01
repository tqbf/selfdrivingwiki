import Foundation
import WikiFSCore
import WikiFSTypes

/// Author intent before target resolution. Syntax owns whether a renderer may
/// fill inline content or a disclosure row.
enum DocumentEmbedSyntax: Hashable, Sendable {
    case markdownImage(sourceRange: MarkdownSourceRange?, source: String, altText: String)
    case wikiSourceMedia(WikiMarkdownSyntaxNode.Embed)
    case wikiTransclusion(WikiMarkdownSyntaxNode.Embed)
    case richFence(MarkdownFencedBlock)

    var requiredEmbeddingRole: RendererEmbeddingRole? {
        switch self {
        case .markdownImage, .wikiSourceMedia:
            return .inlineContent
        case .richFence:
            return .disclosureRow
        case .wikiTransclusion:
            return nil
        }
    }

}

/// Exact tagged target for lazy recursive transclusion.
enum DocumentTransclusionTarget: Hashable, Sendable {
    case page(PageID)
    case source(SourceID)

    var rawValue: String {
        switch self {
        case .page(let pageID): pageID.rawValue
        case .source(let sourceID): sourceID.rawValue
        }
    }

    var pathComponent: String {
        switch self {
        case .page(let pageID): "page:\(pageID.rawValue)"
        case .source(let sourceID): "source:\(sourceID.rawValue)"
        }
    }

    init?(pathComponent: Substring) {
        if pathComponent.hasPrefix("page:") {
            self = .page(PageID(rawValue: String(pathComponent.dropFirst("page:".count))))
        } else if pathComponent.hasPrefix("source:") {
            self = .source(SourceID(rawValue: String(pathComponent.dropFirst("source:".count))))
        } else {
            return nil
        }
    }
}

enum DocumentMediaKind: Hashable, Sendable {
    case image
    case audio
    case video
    case pdf
    case externalFrame
    case mermaidSource
}

enum DocumentInlineTarget: Hashable, Sendable {
    case source(RendererEmbeddedContent.Source)
    case blob(SourceID)
    case external(URL)
    case authored(String)
}

struct DocumentEmbedDisplayMetadata: Hashable, Sendable {
    let title: String?
    let altText: String?
}

enum DocumentEmbedFallback: Hashable, Sendable {
    case image(source: String, altText: String)
    case media(label: String, target: DocumentInlineTarget)
    case code(language: String?, source: String)
    case literal(String)
}

enum DocumentMissingTarget: Hashable, Sendable {
    case page(literal: String)
    case source(literal: String)
    case chat(literal: String)
}

/// One resolved semantic embed. HTML and action URLs are produced only after
/// this model reaches the lowerer.
enum ResolvedDocumentEmbed: Hashable, Sendable {
    case inlineMedia(
        syntax: DocumentEmbedSyntax,
        kind: DocumentMediaKind,
        display: DocumentEmbedDisplayMetadata,
        target: DocumentInlineTarget,
        fallback: DocumentEmbedFallback)
    case renderer(
        syntax: DocumentEmbedSyntax,
        role: RendererEmbeddingRole,
        plan: RendererEmbedPlan,
        fallback: DocumentEmbedFallback)
    case transclusion(
        target: DocumentTransclusionTarget,
        display: DocumentEmbedDisplayMetadata,
        fragment: String?,
        ancestors: Set<DocumentTransclusionTarget>)
    case missing(DocumentMissingTarget, fallback: DocumentEmbedFallback)
    case fallback(DocumentEmbedFallback)
}

/// Renderer-neutral source facts. This replaces presentation decisions in
/// `WikiLinkMarkdown.SourceEmbedInfo` at the typed resolver boundary.
struct DocumentSourceResolution: Sendable {
    enum Version: Hashable, Sendable {
        case source(SourceVersionID)
        case markdown(SourceMarkdownVersionID)
    }

    let sourceID: SourceID
    let version: Version?
    let displayName: String
    let mimeType: String?
    let bytes: Data?
    let externalTarget: EmbedTarget?
    let isMermaidSource: Bool
}

struct ResolvedDocumentLink: Hashable, Sendable {
    let namespace: WikiMarkdownTargetNamespace
    let title: String
    let canonicalID: String?
    let fragment: String?
    let pinnedSourceVersion: SourceMarkdownVersionID?
    let displayText: String
    let isResolved: Bool
}

enum ResolvedMarkdownImageTarget: Hashable, Sendable {
    case blob(SourceID)
    case renderer(rendererReference: RendererReference, source: RendererEmbeddedContent.Source)
}

struct ResolvedDocumentProjection: Sendable {
    private let wikiEmbeds: [MarkdownSourceRange: ResolvedDocumentEmbed]
    private let wikiLinks: [MarkdownSourceRange: ResolvedDocumentLink]
    private let markdownImages: [String: ResolvedMarkdownImageTarget]
    private let richFences: [MarkdownBlockID: ResolvedDocumentEmbed]

    init(
        wikiEmbeds: [MarkdownSourceRange: ResolvedDocumentEmbed] = [:],
        wikiLinks: [MarkdownSourceRange: ResolvedDocumentLink] = [:],
        markdownImages: [String: ResolvedMarkdownImageTarget] = [:],
        richFences: [MarkdownBlockID: ResolvedDocumentEmbed] = [:]
    ) {
        self.wikiEmbeds = wikiEmbeds
        self.wikiLinks = wikiLinks
        self.markdownImages = markdownImages
        self.richFences = richFences
    }

    func wikiEmbed(at range: MarkdownSourceRange) -> ResolvedDocumentEmbed? {
        wikiEmbeds[range]
    }

    func wikiLink(at range: MarkdownSourceRange) -> ResolvedDocumentLink? {
        wikiLinks[range]
    }

    func markdownImage(source: String) -> ResolvedMarkdownImageTarget? {
        markdownImages[source]
    }

    func richFence(blockID: MarkdownBlockID) -> ResolvedDocumentEmbed? {
        richFences[blockID]
    }
}
