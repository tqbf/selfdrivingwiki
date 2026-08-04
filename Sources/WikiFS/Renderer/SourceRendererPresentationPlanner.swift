#if os(macOS)
import Foundation
import WikiFSCore
import WikiFSTypes

// pattern: Functional Core

/// Pure adapter from SourceDetailView's current source facts into renderer
/// registry input. It intentionally does not choose the Source fallback; callers
/// keep Source outside renderer matching.
struct SourceRendererPresentationPlanner: Sendable {
    let registry: RendererRegistrySnapshot

    init(installedDescriptors: [RendererDescriptor] = []) throws {
        registry = try RendererRegistrySnapshot(
            builtInDescriptors: BuiltInRendererDescriptors.all,
            enabledInstalledDescriptors: installedDescriptors)
    }

    init(registry: RendererRegistrySnapshot) {
        self.registry = registry
    }

    func input(
        for source: SourceSummary,
        boundedBytes: Data?,
        currentMarkdown: String?,
        origin: SourceOrigin?
    ) throws -> RendererMatchInput {
        try Self.registryInput(
            for: source,
            boundedBytes: boundedBytes,
            currentMarkdown: currentMarkdown,
            origin: origin)
    }

    func matchingDescriptors(
        for source: SourceSummary,
        boundedBytes: Data?,
        currentMarkdown: String?,
        origin: SourceOrigin?
    ) throws -> [RendererDescriptor] {
        try registry.matching(input(
            for: source,
            boundedBytes: boundedBytes,
            currentMarkdown: currentMarkdown,
            origin: origin))
    }

    nonisolated static func registryInput(
        for source: SourceSummary,
        boundedBytes: Data?,
        currentMarkdown: String?,
        origin: SourceOrigin?
    ) throws -> RendererMatchInput {
        let sniffedBytes = Data((boundedBytes ?? Data()).prefix(RendererMatchingLimits.maximumSniffByteCount))
        let mimeType = try normalizedMIME(for: source, origin: origin)
        let extensionFallback = try normalizedExtension(source.ext)
        let artifactKind = artifactKind(for: source, currentMarkdown: currentMarkdown, origin: origin)
        return try RendererMatchInput(
            mimeType: mimeType,
            fileExtension: extensionFallback,
            sniffedBytes: sniffedBytes,
            artifactKind: artifactKind)
    }

    nonisolated static func plannedBuiltInRenderer(
        for source: SourceSummary,
        boundedBytes: Data?,
        currentMarkdown: String?,
        origin: SourceOrigin?
    ) throws -> BuiltInRendererID? {
        let snapshot = try RendererRegistrySnapshot(builtInDescriptors: BuiltInRendererDescriptors.all)
        let input = try registryInput(
            for: source,
            boundedBytes: boundedBytes,
            currentMarkdown: currentMarkdown,
            origin: origin)
        guard case let .builtIn(id)? = snapshot.matching(input).first?.implementation else { return nil }
        return id
    }

    private static func normalizedMIME(for source: SourceSummary, origin: SourceOrigin?) throws -> RendererMIMEType? {
        if let providerMime = syntheticMediaMIME(for: origin?.provider) {
            return try RendererMIMEType(validating: providerMime)
        }
        if let mime = source.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !mime.isEmpty {
            return RendererMIMEType(rawValue: mime)
        }
        return nil
    }

    private static func normalizedExtension(_ value: String) throws -> RendererFileExtension? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return RendererFileExtension(rawValue: normalized)
    }

    private static func artifactKind(
        for source: SourceSummary,
        currentMarkdown: String?,
        origin: SourceOrigin?
    ) -> RendererArtifactKind? {
        if origin?.provider != nil, syntheticMediaMIME(for: origin?.provider) != nil { return .source }
        if MermaidSourceDetector.isMermaidSource(
            mimeType: source.mimeType,
            filename: source.filename,
            content: currentMarkdown) {
            return .markdown
        }
        if let mime = source.mimeType?.lowercased(), mime.hasPrefix("image/") { return .image }
        if source.byteSize > 0 { return .binary }
        return nil
    }

    private static func syntheticMediaMIME(for provider: SourceProvider?) -> String? {
        switch provider {
        case .youtube?: BuiltInRendererMIME.youtube
        case .vimeo?: BuiltInRendererMIME.vimeo
        case .applePodcast?: BuiltInRendererMIME.applePodcast
        case .spotify?: BuiltInRendererMIME.spotify
        case .soundcloud?: BuiltInRendererMIME.soundCloud
        case .remoteMedia?, .localFile?, .website?, .zotero?, .markdownFolder?, .podcast?, .legacyImport?, .none:
            nil
        }
    }
}

/// Testable golden model for the legacy SourceDetailView presentation branches.
/// PR 2 uses it to characterize behavior before PR 4 replaces routing.
enum SourceDetailPresentationCharacterization {
    enum Presentation: String, Sendable, Equatable {
        case reader = "Reader"
        case pdf = "PDF"
        case html = "HTML"
        case rendered = "Rendered"
        case media = "Media"
        case split = "Split"
    }

    struct Result: Sendable, Equatable {
        let contentArea: ContentArea
        let tabs: [Presentation]
    }

    enum ContentArea: Sendable, Equatable {
        case tabbed
        case pdfOnly
        case markdown
        case binaryFallback
    }

    nonisolated static func characterize(
        source: SourceSummary,
        boundedBytes: Data?,
        currentMarkdown: String?,
        hasProcessedMarkdown: Bool,
        origin: SourceOrigin?
    ) -> Result {
        let isPDF = MimeType.isPDF(source.mimeType)
        let isHTMLSource = htmlSource(source)
        let htmlString = htmlSourceString(isHTMLSource: isHTMLSource, boundedBytes: boundedBytes)
        let mermaidSource = MermaidSourceDetector.isMermaidSource(
            mimeType: source.mimeType,
            filename: source.filename,
            content: currentMarkdown)
        let hasMediaPlayer = mediaPlayerAvailable(source: source, origin: origin)

        let tabs: [Presentation]
        if hasMediaPlayer {
            tabs = hasProcessedMarkdown ? [.reader, .media, .split] : [.reader, .media]
        } else if isPDF && hasProcessedMarkdown {
            tabs = [.reader, .pdf, .split]
        } else if isHTMLSource && (hasProcessedMarkdown || htmlString != nil) {
            tabs = hasProcessedMarkdown ? [.reader, .html, .split] : [.html]
        } else if mermaidSource {
            tabs = [.reader, .rendered, .split]
        } else {
            tabs = []
        }

        let contentArea: ContentArea
        if !tabs.isEmpty || hasMediaPlayer {
            contentArea = .tabbed
        } else if isPDF {
            contentArea = .pdfOnly
        } else if source.mimeType.map(MimeType.isText) == true {
            contentArea = .markdown
        } else {
            contentArea = .binaryFallback
        }
        return Result(contentArea: contentArea, tabs: tabs)
    }

    private static func htmlSource(_ source: SourceSummary) -> Bool {
        if let mime = source.mimeType {
            return mime == MimeType.html || mime == MimeType.xhtml
        }
        let ext = source.ext.lowercased()
        return ext == "html" || ext == "htm" || ext == "xhtml"
    }

    private static func htmlSourceString(isHTMLSource: Bool, boundedBytes: Data?) -> String? {
        guard isHTMLSource, let boundedBytes else { return nil }
        return String(data: boundedBytes, encoding: .utf8) ?? String(decoding: boundedBytes, as: UTF8.self)
    }

    private static func mediaPlayerAvailable(source: SourceSummary, origin: SourceOrigin?) -> Bool {
        guard let descriptor = embedDescriptor(source: source, origin: origin) else { return false }
        return ExternalEmbed.target(for: descriptor) != nil
    }

    private static func embedDescriptor(source: SourceSummary, origin: SourceOrigin?) -> SourceEmbedDescriptor? {
        guard let mime = source.mimeType, let origin else { return nil }
        return SourceEmbedDescriptor(
            id: source.id,
            mimeType: mime,
            externalIdentity: origin.externalIdentity,
            agentName: origin.agentName,
            planURL: origin.plan)
    }
}
#endif
