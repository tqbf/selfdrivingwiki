#if os(macOS)
import Foundation
import WikiFSCore
import WikiFSTypes

// pattern: Functional Core

/// Pure adapter from SourceDetailView's current source facts into renderer
/// registry input. It intentionally does not choose the Source fallback; callers
/// keep Source outside renderer matching.
struct SourceRendererPresentationPlanner: Sendable {
    struct EmptyMediaPresentation: Sendable, Equatable {
        let label: String
        let description: String
    }
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

    func preferredDescriptor(
        preference: RendererPreferenceReference?,
        for source: SourceSummary,
        boundedBytes: Data?,
        currentMarkdown: String?,
        origin: SourceOrigin?
    ) throws -> RendererDescriptor? {
        try registry.preferred(
            preference: preference,
            input: input(
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
            sniffedBytesAreComplete: source.byteSize == sniffedBytes.count,
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

    /// Decodes original HTML only for descriptors that match the HTML contract.
    nonisolated static func htmlSourceString(for source: SourceSummary, bytes: Data?) -> String? {
        guard isHTMLSource(source), let bytes else { return nil }
        return String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// HTML classification is source metadata, independent of whether this
    /// pane's bounded byte snapshot has loaded yet.
    nonisolated static func isHTMLSource(_ source: SourceSummary) -> Bool {
        htmlSource(source)
    }

    /// DOCX classification is source metadata, mirroring `isHTMLSource`. A
    /// docx source dispatches the Extract button to the inline package-only
    /// `prepareDOCX` path (the queue engine is PDF-coupled).
    nonisolated static func isDOCXSource(_ source: SourceSummary) -> Bool {
        if let mime = source.mimeType { return MimeType.isDOCX(mime) }
        return source.ext.lowercased() == "docx"
    }

    /// Returns strict UTF-8 source text only when the canonical bounded detector
    /// agrees that the complete byte body is textual. Binary signatures and NUL
    /// bytes therefore fail closed even when metadata claims a text type.
    nonisolated static func sourceText(for source: SourceSummary, bytes: Data?) -> String? {
        guard let bytes, !bytes.isEmpty, !bytes.contains(0),
              let text = String(data: bytes, encoding: .utf8) else { return nil }
        let detection = ContentTypeDetector.detect(.init(
            data: bytes,
            hints: .init(
                declaredMIME: source.mimeType.map { .init($0, origin: .trustedGenerated) },
                filenameExtension: source.ext.isEmpty ? nil : source.ext)))
        guard !detection.evidence.contains(where: { $0.origin == .binarySignature }),
              detection.evidence.contains(where: {
                  $0.origin == .utf8Text || $0.origin == .structuredBytes
              }) else { return nil }
        return text
    }

    /// Makes raw source bytes inert in the Markdown reader while preserving
    /// whitespace and punctuation. Native Markdown remains a rendered document.
    /// The wrap is format-neutral: non-Markdown text always renders as a code
    /// block in the Source tab, whatever renderer package may claim it.
    nonisolated static func sourceMarkdown(for source: SourceSummary, content: String) -> String {
        guard !MimeType.isMarkdown(source.mimeType) else { return content }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return content }
        // A 4-backtick fence keeps any 3-backtick runs inside the content
        // from terminating the wrapper early.
        return "````\n\(trimmed)\n````"
    }

    nonisolated static func hasPresentableSource(
        for source: SourceSummary,
        boundedBytes: Data? = nil,
        currentMarkdown: String?
    ) -> Bool {
        usesMarkdownSourcePresentation(
            for: source, boundedBytes: boundedBytes, currentMarkdown: currentMarkdown)
    }

    /// Whether Source should use the Markdown/reader path instead of the raw
    /// binary fallback. Standalone diagram sources retain this path even when
    /// their MIME type is not text-presentable or is NULL.
    nonisolated static func usesMarkdownSourcePresentation(
        for source: SourceSummary,
        boundedBytes: Data? = nil,
        currentMarkdown: String?
    ) -> Bool {
        currentMarkdown != nil || sourceText(for: source, bytes: boundedBytes) != nil
    }

    nonisolated static func mediaTarget(for source: SourceSummary, origin: SourceOrigin?) -> EmbedTarget? {
        guard let mime = source.mimeType, let origin else { return nil }
        return ExternalEmbed.target(for: SourceEmbedDescriptor(
            id: source.id,
            mimeType: mime,
            externalIdentity: origin.externalIdentity,
            agentName: origin.agentName,
            planURL: origin.plan))
    }

    nonisolated static func emptyMediaPresentation(for source: SourceSummary, currentMarkdown: String?, origin: SourceOrigin?) -> EmptyMediaPresentation? {
        guard currentMarkdown == nil, mediaTarget(for: source, origin: origin) != nil else { return nil }
        let label = mediaLabel(for: source, origin: origin)
        let description = origin?.provider == .youtube
            ? "This video has no captions, so no transcript was extracted. The player is the source."
            : "This media source has no extracted text yet. The player is the source."
        return EmptyMediaPresentation(label: "No \(label) Transcript", description: description)
    }

    nonisolated static func showsMarkdownOriginMetadata(for source: SourceSummary) -> Bool {
        let extractionPath = ContentKind.resolve(
            mimeType: source.mimeType,
            provider: nil,
            ext: source.ext).capabilities.extractionPath
        return extractionPath != .pdfBackend
    }

    nonisolated static func standaloneDiagramSource(_ source: SourceSummary) -> Bool {
        // Diagram text formats (.mmd, .canvas JSON, and other JSON diagram
        // formats) present like any renderer-package text source. The
        // reader-projected tab is not a renderer decision.
        false
    }

    private enum MediaMIMECandidate: Sendable, Equatable {
        case notMediaOrigin
        case rejected
        case renderable(String)
    }

    private static func normalizedMIME(for source: SourceSummary, origin: SourceOrigin?) throws -> RendererMIMEType? {
        switch mediaMIMECandidate(for: source, origin: origin) {
        case .renderable(let mediaMime):
            return try RendererMIMEType(validating: mediaMime)
        case .rejected:
            return nil
        case .notMediaOrigin:
            break
        }
        if let mime = ContentTypeDetector.normalizeMIMEType(source.mimeType) {
            return RendererMIMEType(rawValue: mime)
        }
        return nil
    }

    private static func htmlSource(_ source: SourceSummary) -> Bool {
        if let mime = source.mimeType { return mime == MimeType.html || mime == MimeType.xhtml }
        return ["html", "htm", "xhtml"].contains(source.ext.lowercased())
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
        if renderableMediaMIME(for: source, origin: origin) != nil { return .source }
        if let mime = source.mimeType?.lowercased(), mime.hasPrefix("image/") { return .image }
        if source.byteSize > 0 { return .binary }
        return nil
    }

    private static func renderableMediaMIME(for source: SourceSummary, origin: SourceOrigin?) -> String? {
        guard case .renderable(let mime) = mediaMIMECandidate(for: source, origin: origin) else { return nil }
        return mime
    }

    private static func mediaMIMECandidate(for source: SourceSummary, origin: SourceOrigin?) -> MediaMIMECandidate {
        guard let origin,
              let mime = mediaMIME(for: source, provider: origin.provider) else {
            return .notMediaOrigin
        }
        let descriptor = SourceEmbedDescriptor(
            id: source.id,
            mimeType: mime,
            externalIdentity: origin.externalIdentity,
            agentName: origin.agentName,
            planURL: origin.plan)
        guard ExternalEmbed.target(for: descriptor) != nil else { return .rejected }
        return .renderable(mime)
    }

    private static func mediaLabel(for source: SourceSummary, origin: SourceOrigin?) -> String {
        guard let mime = source.mimeType, let origin else { return "Media" }
        let descriptor = SourceEmbedDescriptor(id: source.id, mimeType: mime, externalIdentity: origin.externalIdentity, agentName: origin.agentName, planURL: origin.plan)
        return ExternalEmbed.mediaTabLabel(for: descriptor) ?? "Media"
    }

    private static func mediaMIME(for source: SourceSummary, provider: SourceProvider?) -> String? {
        switch provider {
        case .youtube?: BuiltInRendererMIME.youtube
        case .vimeo?: BuiltInRendererMIME.vimeo
        case .applePodcast?: BuiltInRendererMIME.applePodcast
        case .spotify?: BuiltInRendererMIME.spotify
        case .soundcloud?: BuiltInRendererMIME.soundCloud
        case .remoteMedia?: source.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        case .localFile?, .website?, .zotero?, .markdownFolder?, .podcast?, .legacyImport?, .none:
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
        let hasMediaPlayer = mediaPlayerAvailable(source: source, origin: origin)

        let tabs: [Presentation]
        if hasMediaPlayer {
            tabs = [.reader, .media]
        } else if isPDF && hasProcessedMarkdown {
            tabs = [.reader, .pdf]
        } else if isHTMLSource && (hasProcessedMarkdown || htmlString != nil) {
            tabs = hasProcessedMarkdown ? [.reader, .html] : [.html]
        } else if SourceRendererPresentationPlanner.standaloneDiagramSource(source) {
            // Legacy native built-ins no longer add a reader tab; a .mmd or
            // .canvas JSON source presents like any renderer-package text
            // source — Source tab plus the package renderer pane.
            tabs = []
        } else {
            tabs = []
        }

        let contentArea: ContentArea
        if !tabs.isEmpty || hasMediaPlayer {
            contentArea = .tabbed
        } else if isPDF {
            contentArea = .pdfOnly
        } else if MimeType.isSourceTextPresentable(source.mimeType) {
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
