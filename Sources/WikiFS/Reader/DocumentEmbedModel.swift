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

    var requiresDOMOwnership: Bool {
        switch self {
        case .markdownImage, .wikiSourceMedia: true
        case .wikiTransclusion, .richFence: false
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

enum DocumentRendererDOMOutput: Hashable, Sendable {
    case vectorScene(DocumentVectorScene)
}

struct DocumentVectorScene: Hashable, Sendable {
    struct Bounds: Hashable, Sendable {
        let minimumX: Double
        let minimumY: Double
        let width: Double
        let height: Double
    }

    enum Element: Hashable, Sendable {
        case rectangle(x: Double, y: Double, width: Double, height: Double, cornerRadius: Double, style: Style)
        case ellipse(x: Double, y: Double, width: Double, height: Double, style: Style)
        case diamond(x: Double, y: Double, width: Double, height: Double, style: Style)
        case text(x: Double, y: Double, text: String, fontSize: Double, style: Style)
        case polyline(x: Double, y: Double, points: [Point], arrowhead: Bool, style: Style)
    }

    struct Point: Hashable, Sendable {
        let x: Double
        let y: Double
    }

    struct Style: Hashable, Sendable {
        let strokeColor: String
        let fillColor: String?
        let strokeWidth: Double
        let opacity: Double
    }

    let bounds: Bounds
    let backgroundColor: String?
    let accessibilityLabel: String
    let elements: [Element]
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
    case rendererDOM(
        syntax: DocumentEmbedSyntax,
        role: RendererEmbeddingRole,
        plan: RendererEmbedPlan,
        output: DocumentRendererDOMOutput,
        fallback: DocumentEmbedFallback)
    case rendererDOMFallback(
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

/// Converts exact, trusted renderer input into inert document output. This
/// projector emits typed values only. The HTML lowerer remains the sole markup
/// boundary.
enum DocumentRendererDOMProjector {
    private enum Limits {
        static let maximumElementCount = 2_048
        static let maximumPointCount = 8_192
        static let maximumCoordinateMagnitude = 1_000_000.0
        static let maximumTextLength = 10_000
        static let maximumTotalTextLength = 100_000
        static let maximumStrokeWidth = 64.0
        static let scenePadding = 24.0
    }

    static func usesTrustedDOMProjection(_ plan: RendererEmbedPlan) -> Bool {
        plan.embeddingRole == .inlineContent
            && plan.rendererReference.packageID == BundledRendererPackages.excalidrawPackageID
            && plan.rendererReference.version == BundledRendererPackages.excalidrawVersion
            && plan.rendererReference.registrationID == BundledRendererPackages.excalidrawRegistrationID
    }

    static func project(_ plan: RendererEmbedPlan) -> DocumentRendererDOMOutput? {
        guard usesTrustedDOMProjection(plan),
              case .source(let source) = plan.input,
              source.bytes.count <= WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount,
              source.digest == RendererSHA256.digest(source.bytes)
        else { return nil }
        return projectExcalidraw(source.bytes).map(DocumentRendererDOMOutput.vectorScene)
    }

    private static func projectExcalidraw(_ data: Data) -> DocumentVectorScene? {
        let document: ExcalidrawDocument
        do { document = try JSONDecoder().decode(ExcalidrawDocument.self, from: data) }
        catch { return nil }
        guard document.type == "excalidraw", document.version == 2,
              document.elements.count <= Limits.maximumElementCount else { return nil }

        var pointCount = 0
        var textLength = 0
        var output: [DocumentVectorScene.Element] = []
        var bounds: SceneBounds?
        for element in document.elements where element.isDeleted != true {
            guard let projected = project(
                element,
                pointCount: &pointCount,
                textLength: &textLength)
            else { return nil }
            output.append(projected.element)
            bounds = bounds.map { $0.union(projected.bounds) } ?? projected.bounds
        }
        guard let bounds, output.isEmpty == false,
              let paddedMinimumX = boundedSum(bounds.minimumX, -Limits.scenePadding),
              let paddedMinimumY = boundedSum(bounds.minimumY, -Limits.scenePadding),
              let paddedMaximumX = boundedSum(bounds.maximumX, Limits.scenePadding),
              let paddedMaximumY = boundedSum(bounds.maximumY, Limits.scenePadding)
        else { return nil }
        return DocumentVectorScene(
            bounds: .init(
                minimumX: paddedMinimumX,
                minimumY: paddedMinimumY,
                width: max(1, paddedMaximumX - paddedMinimumX),
                height: max(1, paddedMaximumY - paddedMinimumY)),
            backgroundColor: validatedColor(document.appState?.viewBackgroundColor),
            accessibilityLabel: "Read-only Excalidraw drawing",
            elements: output)
    }

    private static func project(
        _ element: ExcalidrawElement,
        pointCount: inout Int,
        textLength: inout Int
    ) -> (element: DocumentVectorScene.Element, bounds: SceneBounds)? {
        guard validCoordinate(element.x), validCoordinate(element.y),
              validDimension(element.width), validDimension(element.height),
              element.angle == nil || element.angle == 0,
              let style = style(for: element)
        else { return nil }
        guard let maximumX = boundedSum(element.x, element.width),
              let maximumY = boundedSum(element.y, element.height)
        else { return nil }
        let box = SceneBounds(
            minimumX: element.x,
            minimumY: element.y,
            maximumX: maximumX,
            maximumY: maximumY)
        switch element.type {
        case "rectangle":
            return (.rectangle(
                x: element.x, y: element.y, width: element.width, height: element.height,
                cornerRadius: element.roundness == nil ? 0 : min(8, element.width / 2, element.height / 2),
                style: style), box)
        case "ellipse":
            return (.ellipse(x: element.x, y: element.y, width: element.width, height: element.height, style: style), box)
        case "diamond":
            return (.diamond(x: element.x, y: element.y, width: element.width, height: element.height, style: style), box)
        case "text":
            guard let text = element.text, text.count <= Limits.maximumTextLength,
                  textLength + text.count <= Limits.maximumTotalTextLength,
                  let fontSize = element.fontSize, validDimension(fontSize), fontSize > 0 else { return nil }
            textLength += text.count
            return (.text(x: element.x, y: element.y, text: text, fontSize: fontSize, style: style), box)
        case "line", "arrow", "freedraw":
            guard let rawPoints = element.points, rawPoints.isEmpty == false,
                  pointCount + rawPoints.count <= Limits.maximumPointCount else { return nil }
            let points = rawPoints.compactMap { values -> DocumentVectorScene.Point? in
                guard values.count == 2, validCoordinate(values[0]), validCoordinate(values[1]) else { return nil }
                return .init(x: values[0], y: values[1])
            }
            guard points.count == rawPoints.count else { return nil }
            pointCount += points.count
            guard let pointBounds = SceneBounds(points: points, offsetX: element.x, offsetY: element.y) else {
                return nil
            }
            return (.polyline(
                x: element.x, y: element.y, points: points,
                arrowhead: element.type == "arrow" && element.endArrowhead != nil,
                style: style), pointBounds)
        default:
            return nil
        }
    }

    private static func style(for element: ExcalidrawElement) -> DocumentVectorScene.Style? {
        guard let stroke = validatedColor(element.strokeColor),
              let strokeWidth = element.strokeWidth,
              strokeWidth.isFinite, strokeWidth >= 0, strokeWidth <= Limits.maximumStrokeWidth else { return nil }
        let opacity = min(100, max(0, element.opacity ?? 100)) / 100
        return .init(
            strokeColor: stroke,
            fillColor: validatedColor(element.backgroundColor),
            strokeWidth: strokeWidth,
            opacity: opacity)
    }

    private static func validatedColor(_ value: String?) -> String? {
        guard let value else { return nil }
        if value == "transparent" { return nil }
        guard value.count == 4 || value.count == 7, value.first == "#",
              value.dropFirst().allSatisfy({ $0.isHexDigit }) else { return nil }
        return value.lowercased()
    }

    private static func validCoordinate(_ value: Double) -> Bool {
        value.isFinite && abs(value) <= Limits.maximumCoordinateMagnitude
    }

    private static func validDimension(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= Limits.maximumCoordinateMagnitude
    }

    private static func boundedSum(_ lhs: Double, _ rhs: Double) -> Double? {
        let result = lhs + rhs
        return validCoordinate(result) ? result : nil
    }

    private struct SceneBounds {
        let minimumX: Double
        let minimumY: Double
        let maximumX: Double
        let maximumY: Double

        var width: Double { maximumX - minimumX }
        var height: Double { maximumY - minimumY }

        init(minimumX: Double, minimumY: Double, maximumX: Double, maximumY: Double) {
            self.minimumX = minimumX
            self.minimumY = minimumY
            self.maximumX = maximumX
            self.maximumY = maximumY
        }

        init?(points: [DocumentVectorScene.Point], offsetX: Double, offsetY: Double) {
            guard let minimumX = DocumentRendererDOMProjector.boundedSum(offsetX, points.map(\.x).min() ?? 0),
                  let minimumY = DocumentRendererDOMProjector.boundedSum(offsetY, points.map(\.y).min() ?? 0),
                  let maximumX = DocumentRendererDOMProjector.boundedSum(offsetX, points.map(\.x).max() ?? 0),
                  let maximumY = DocumentRendererDOMProjector.boundedSum(offsetY, points.map(\.y).max() ?? 0)
            else { return nil }
            self.minimumX = minimumX
            self.minimumY = minimumY
            self.maximumX = maximumX
            self.maximumY = maximumY
        }

        func union(_ other: Self) -> Self {
            .init(
                minimumX: min(minimumX, other.minimumX),
                minimumY: min(minimumY, other.minimumY),
                maximumX: max(maximumX, other.maximumX),
                maximumY: max(maximumY, other.maximumY))
        }
    }

    private struct ExcalidrawDocument: Decodable {
        let type: String
        let version: Int
        let elements: [ExcalidrawElement]
        let appState: AppState?
    }

    private struct AppState: Decodable {
        let viewBackgroundColor: String?
    }

    private struct Roundness: Decodable {}

    private struct ExcalidrawElement: Decodable {
        let type: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let angle: Double?
        let strokeColor: String?
        let backgroundColor: String?
        let strokeWidth: Double?
        let opacity: Double?
        let roundness: Roundness?
        let isDeleted: Bool?
        let text: String?
        let fontSize: Double?
        let points: [[Double]]?
        let endArrowhead: String?
    }
}
