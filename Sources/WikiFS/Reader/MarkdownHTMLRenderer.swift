import Foundation
import Markdown
import WikiFSCodeHighlighting
import Synchronization
import WikiFSCore

/// Selects whether one Markdown conversion may use native ordinary-code
/// highlighting. Chat explicitly disables this policy to keep transcript fences
/// as inert escaped plain code.
enum MarkdownCodeHighlightingPolicy: Sendable {
    case enabled(HighlightedCodeBlockBudget)
    case disabled
}

/// Immutable inputs for one Markdown conversion. A reader document shares its
/// budget with lazily rendered transclusions. Other callers receive an explicit
/// policy instead of inheriting highlighting accidentally.
struct MarkdownRenderOptions: Sendable {
    let codeHighlighting: MarkdownCodeHighlightingPolicy
    let rendererEmbedProjection: RendererEmbedProjection?
    let documentIdentity: MarkdownDocumentIdentity?
    let rendererActivationAdmission: RendererEmbedActivationAdmission?

    init(
        codeHighlighting: MarkdownCodeHighlightingPolicy,
        rendererEmbedProjection: RendererEmbedProjection?,
        documentIdentity: MarkdownDocumentIdentity?,
        rendererActivationAdmission: RendererEmbedActivationAdmission?
    ) {
        self.codeHighlighting = codeHighlighting
        self.rendererEmbedProjection = rendererEmbedProjection
        self.documentIdentity = documentIdentity
        self.rendererActivationAdmission = rendererActivationAdmission
    }

    static var reader: Self {
        Self(
            codeHighlighting: .enabled(HighlightedCodeBlockBudget()),
            rendererEmbedProjection: nil,
            documentIdentity: nil,
            rendererActivationAdmission: nil)
    }

    /// Fail-closed policy for callers without an authoritative reader context.
    static let disabled = Self(codeHighlighting: .disabled, rendererEmbedProjection: nil, documentIdentity: nil, rendererActivationAdmission: nil)
    static let chat = Self(codeHighlighting: .disabled, rendererEmbedProjection: nil, documentIdentity: nil, rendererActivationAdmission: nil)
}

/// A document-scoped fence budget. The mutex protects only the remaining
/// count. It never contains mutable Tree-sitter parser, tree, query-cursor, or
/// result state.
final class HighlightedCodeBlockBudget: Sendable {
    private let remaining: Mutex<Int>

    init(limit: Int = CodeHighlightingPolicy.maximumHighlightedBlockCount) {
        remaining = Mutex(limit)
    }

    func claim() -> Bool {
        remaining.withLock { value in
            guard value > 0 else { return false }
            value -= 1
            return true
        }
    }
}

/// Renders Markdown → HTML for the source web reader (the `WKWebView` path).
/// Walks a swift-markdown `Document` with a `MarkupVisitor`, emitting faithful
/// HTML for the GFM constructs large sources use: headings (with GFM-slug `id`s
/// matching `AnchorBlock.makeSlug`, so `#fragment` anchors resolve the same as
/// the native reader), paragraphs, emphasis/strong/strikethrough, inline +
/// fenced code, links + images, ordered/unordered lists, blockquotes, thematic
/// breaks, and tables.
///
/// Wiki links and footnotes arrive already pre-processed into ordinary markdown
/// links by `WikiReaderView`'s pre-pass (`WikiFootnoteMarkdown` +
/// `WikiLinkMarkdown` — the same transforms the native reader uses), so they
/// need no special handling here.
///
/// Pure / thread-safe: the render runs off the main actor.
struct MarkdownHTMLRenderer: MarkupVisitor {

    /// Render `markdown` to an HTML fragment (no `<html>`/`<body>` wrapper —
    /// `WikiReaderView.documentHTML` wraps it).
    static func render(
        _ markdown: String,
        options: MarkdownRenderOptions,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) -> String {
        render(
            ReaderMarkdown.preparedDocument(markdown, documentIdentity: options.documentIdentity),
            projection: nil,
            options: options,
            isCancelled: isCancelled)
    }

    static func render(
        _ prepared: PreparedMarkdownDocument,
        projection: ResolvedDocumentProjection?,
        options: MarkdownRenderOptions,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) -> String {
        var renderer = MarkdownHTMLRenderer()
        renderer.codeHighlighting = options.codeHighlighting
        renderer.rendererEmbedProjection = options.rendererEmbedProjection
        renderer.documentIdentity = prepared.documentIdentity ?? options.documentIdentity
        renderer.rendererActivationAdmission = options.rendererActivationAdmission
        renderer.preparedDocument = prepared
        renderer.resolvedDocumentProjection = projection
        renderer.isCancelled = isCancelled
        return renderer.visit(prepared.document)
    }

    /// Per-render slug dedup counts, mirroring `AnchorBlock.makeSlug` so heading
    /// ids match the native reader's resolution list.
    private var slugCounts: [String: Int] = [:]
    private var fenceOrdinal = 0

    private var codeHighlighting: MarkdownCodeHighlightingPolicy = .disabled
    private var rendererEmbedProjection: RendererEmbedProjection?
    private var documentIdentity: MarkdownDocumentIdentity?
    private var rendererActivationAdmission: RendererEmbedActivationAdmission?
    private var preparedDocument: PreparedMarkdownDocument?
    private var resolvedDocumentProjection: ResolvedDocumentProjection?
    private var emittedWikiRanges: Set<MarkdownSourceRange> = []
    private var isCancelled: @Sendable () -> Bool = { Task.isCancelled }

    private enum RendererCardActivationState {
        case admitted(actionURL: String)
        case unavailable

        var isExpandable: Bool {
            if case .admitted = self { return true }
            return false
        }
    }

    private mutating func visitChildren(_ markup: Markup) -> String {
        guard let prepared = preparedDocument,
              prepared.wikiSyntax.isEmpty == false else {
            return markup.children.reduce(into: "") { result, child in result += visit(child) }
        }
        guard let containerRange = sourceRange(of: markup, in: prepared) else {
            // Swift Markdown's synthetic root Document has no range. Descend;
            // ranged descendants establish ownership. A range-less descendant
            // that intersects an overlay still fails closed below.
            return markup.children.reduce(into: "") { result, child in result += visit(child) }
        }

        let overlays = prepared.wikiSyntax.filter { node in
            containerRange.contains(node.sourceRange) && emittedWikiRanges.contains(node.sourceRange) == false
        }
        guard overlays.isEmpty == false else {
            return markup.children.reduce(into: "") { result, child in result += visit(child) }
        }

        var output = ""
        var overlayIndex = 0
        for child in markup.children {
            guard let childRange = sourceRange(of: child, in: prepared) else {
                // A range-less node is safe only when no remaining overlay is
                // owned by this container. Otherwise preserve the exact authored
                // container slice once instead of guessing ownership.
                if overlayIndex < overlays.count {
                    DebugLog.reader("Range-less Markdown node intersects wiki overlay; rendering authored container literally")
                    return escapedAuthoredSlice(containerRange, prepared: prepared)
                }
                output += visit(child)
                continue
            }

            while overlayIndex < overlays.count,
                  overlays[overlayIndex].sourceRange.upperBound <= childRange.lowerBound {
                let node = overlays[overlayIndex]
                if emittedWikiRanges.contains(node.sourceRange) == false {
                    output += renderWikiNode(node)
                }
                overlayIndex += 1
            }
            if overlayIndex < overlays.count {
                let overlayRange = overlays[overlayIndex].sourceRange
                if overlayRange.contains(childRange) {
                    if emittedWikiRanges.insert(overlayRange).inserted {
                        output += renderWikiNode(overlays[overlayIndex])
                    }
                    if childRange.upperBound == overlayRange.upperBound { overlayIndex += 1 }
                    continue
                }
                if childRange.contains(overlayRange) {
                    if child.childCount == 0 {
                        output += renderTextRange(childRange, overlays: overlays, overlayIndex: &overlayIndex, prepared: prepared)
                    } else {
                        output += visit(child)
                        while overlayIndex < overlays.count,
                              overlays[overlayIndex].sourceRange.upperBound <= childRange.upperBound,
                              emittedWikiRanges.contains(overlays[overlayIndex].sourceRange) {
                            overlayIndex += 1
                        }
                    }
                    continue
                }
                if childRange.intersects(overlayRange) {
                    // Leaf nodes may contain ordinary text around an overlay.
                    // Split them from the exact authored UTF-8 slice.
                    if child.childCount == 0 {
                        output += renderTextRange(childRange, overlays: overlays, overlayIndex: &overlayIndex, prepared: prepared)
                        continue
                    }
                    DebugLog.reader("Crossing Markdown AST and wiki overlay ranges; rendering authored child literally")
                    output += escapedAuthoredSlice(childRange, prepared: prepared)
                    while overlayIndex < overlays.count,
                          overlays[overlayIndex].sourceRange.upperBound <= childRange.upperBound {
                        emittedWikiRanges.insert(overlays[overlayIndex].sourceRange)
                        overlayIndex += 1
                    }
                    continue
                }
            }
            output += visit(child)
        }
        while overlayIndex < overlays.count {
            let node = overlays[overlayIndex]
            if emittedWikiRanges.contains(node.sourceRange) == false {
                output += renderWikiNode(node)
            }
            overlayIndex += 1
        }
        return output
    }

    private func sourceRange(of markup: Markup, in prepared: PreparedMarkdownDocument) -> MarkdownSourceRange? {
        guard let range = markup.range else { return nil }
        return prepared.lineTable.range(
            startLine: range.lowerBound.line,
            startUTF8Column: range.lowerBound.column,
            endLine: range.upperBound.line,
            endUTF8Column: range.upperBound.column)
    }

    private func authoredSlice(_ range: MarkdownSourceRange, prepared: PreparedMarkdownDocument) -> String? {
        guard range.upperBound <= prepared.sourceMarkdown.utf8.count,
              let lowerUTF8 = prepared.sourceMarkdown.utf8.index(
                  prepared.sourceMarkdown.utf8.startIndex,
                  offsetBy: range.lowerBound,
                  limitedBy: prepared.sourceMarkdown.utf8.endIndex),
              let upperUTF8 = prepared.sourceMarkdown.utf8.index(
                  prepared.sourceMarkdown.utf8.startIndex,
                  offsetBy: range.upperBound,
                  limitedBy: prepared.sourceMarkdown.utf8.endIndex),
              let lower = String.Index(lowerUTF8, within: prepared.sourceMarkdown),
              let upper = String.Index(upperUTF8, within: prepared.sourceMarkdown) else {
            return nil
        }
        return String(prepared.sourceMarkdown[lower..<upper])
    }

    private func escapedAuthoredSlice(_ range: MarkdownSourceRange, prepared: PreparedMarkdownDocument) -> String {
        guard let literal = authoredSlice(range, prepared: prepared) else {
            DebugLog.reader("UTF-8 source range conversion failed during Markdown lowering")
            return ""
        }
        return escape(literal)
    }

    private mutating func renderTextRange(
        _ textRange: MarkdownSourceRange,
        overlays: [WikiMarkdownSyntaxNode],
        overlayIndex: inout Int,
        prepared: PreparedMarkdownDocument
    ) -> String {
        var output = ""
        var cursor = textRange.lowerBound
        while overlayIndex < overlays.count {
            let node = overlays[overlayIndex]
            let range = node.sourceRange
            guard range.lowerBound < textRange.upperBound else { break }
            guard range.lowerBound >= cursor, range.upperBound <= textRange.upperBound else {
                DebugLog.reader("Invalid text and wiki overlay crossing; rendering authored text literally")
                return escapedAuthoredSlice(textRange, prepared: prepared)
            }
            if cursor < range.lowerBound {
                do {
                    let gap = try MarkdownSourceRange(
                        lowerBound: cursor,
                        upperBound: range.lowerBound)
                    output += escapedAuthoredSlice(gap, prepared: prepared)
                } catch {
                    DebugLog.reader("Invalid wiki overlay text gap: \(error)")
                    return escapedAuthoredSlice(textRange, prepared: prepared)
                }
            }
            output += renderWikiNode(node)
            emittedWikiRanges.insert(range)
            cursor = range.upperBound
            overlayIndex += 1
        }
        if cursor < textRange.upperBound {
            do {
                let tail = try MarkdownSourceRange(
                    lowerBound: cursor,
                    upperBound: textRange.upperBound)
                output += escapedAuthoredSlice(tail, prepared: prepared)
            } catch {
                DebugLog.reader("Invalid wiki overlay text tail: \(error)")
                return escapedAuthoredSlice(textRange, prepared: prepared)
            }
        }
        return output
    }

    private mutating func renderWikiNode(_ node: WikiMarkdownSyntaxNode) -> String {
        emittedWikiRanges.insert(node.sourceRange)
        switch node {
        case .link(let link):
            return wikiLinkHTML(link)
        case .embed(let embed):
            guard let resolved = resolvedDocumentProjection?.wikiEmbed(at: embed.sourceRange) else {
                return escape(embed.authoredLiteral)
            }
            return lowerResolvedEmbed(resolved)
        }
    }

    private func wikiLinkHTML(_ link: WikiMarkdownSyntaxNode.Link) -> String {
        guard let resolved = resolvedDocumentProjection?.wikiLink(at: link.sourceRange) else {
            return escape(link.authoredLiteral)
        }
        let host: String
        if !resolved.isResolved {
            host = WikiLinkMarkdown.unresolvedHost
        } else {
            switch resolved.namespace {
            case .page: host = WikiLinkMarkdown.resolvedHost
            case .source: host = WikiLinkMarkdown.sourceHost
            case .chat: host = WikiLinkMarkdown.chatHost
            }
        }
        var components = URLComponents()
        components.scheme = WikiLinkMarkdown.scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "title", value: resolved.title)]
        if let canonicalID = resolved.canonicalID {
            components.queryItems?.append(URLQueryItem(name: "id", value: canonicalID))
        }
        if let pinnedVersion = resolved.pinnedSourceVersion {
            components.queryItems?.append(URLQueryItem(name: "pin", value: pinnedVersion.rawValue))
        }
        components.fragment = resolved.fragment
        let destination = components.url?.absoluteString ?? ""
        return "<a href=\"\(escapeAttribute(destination))\">\(escape(resolved.displayText))</a>"
    }

    private mutating func lowerResolvedEmbed(_ embed: ResolvedDocumentEmbed) -> String {
        switch embed {
        case .inlineMedia(let syntax, let kind, let display, let target, let fallback):
            return inlineMediaHTML(
                syntax: syntax,
                kind: kind,
                display: display,
                target: target,
                fallback: fallback)
        case .renderer(let syntax, let role, let plan, let fallback):
            guard role == plan.embeddingRole else { return fallbackHTML(fallback) }
            if syntax.requiresDOMOwnership {
                return rendererDOMFallbackHTML(fallbackHTML(fallback), plan: plan)
            }
            if role == .inlineContent {
                return inlineRendererHTML(plan: plan, fallback: fallbackHTML(fallback))
            }
            return rendererCardHTML(plan: plan, fallbackHTML: fallbackHTML(fallback), readableFallbackHTML: fallbackHTML(fallback))
        case .rendererDOM(_, let role, let plan, let output, let fallback):
            guard role == .inlineContent,
                  role == plan.embeddingRole,
                  DocumentRendererDOMProjector.project(plan) == output
            else { return fallbackHTML(fallback) }
            return rendererDOMOutputHTML(output, plan: plan)
        case .rendererDOMFallback(_, let role, let plan, let fallback):
            guard role == .inlineContent, role == plan.embeddingRole else { return fallbackHTML(fallback) }
            return rendererDOMFallbackHTML(fallbackHTML(fallback), plan: plan)
        case .transclusion(let target, let display, let fragment, let ancestors):
            return transclusionHTML(target: target, display: display, fragment: fragment, ancestors: ancestors)
        case .missing(_, let fallback), .fallback(let fallback):
            return fallbackHTML(fallback)
        }
    }

    private func inlineMediaHTML(
        syntax: DocumentEmbedSyntax,
        kind: DocumentMediaKind,
        display: DocumentEmbedDisplayMetadata,
        target: DocumentInlineTarget,
        fallback: DocumentEmbedFallback
    ) -> String {
        let source = inlineTargetURL(target)
        let alt = display.altText ?? display.title ?? ""
        let isWikiSource: Bool = if case .wikiSourceMedia = syntax { true } else { false }
        switch kind {
        case .image:
            if isWikiSource {
                return "<img src=\"\(escapeAttribute(source))\" alt=\"\(escape(alt))\" class=\"wiki-embed\">"
            }
            return ordinaryImageHTML(src: source, altText: alt)
        case .audio:
            return "<audio controls preload=\"metadata\" src=\"\(escapeAttribute(source))\" class=\"wiki-embed\">\(fallbackHTML(fallback))</audio>"
        case .video:
            return "<video controls preload=\"metadata\" src=\"\(escapeAttribute(source))\" class=\"wiki-embed\">\(fallbackHTML(fallback))</video>"
        case .pdf:
            return "<iframe class=\"wiki-embed-pdf\" src=\"\(escapeAttribute(source))\" title=\"\(escapeAttribute(alt))\" loading=\"lazy\"></iframe>"
        case .externalFrame:
            return "<iframe class=\"wiki-embed\" src=\"\(escapeAttribute(source))\" title=\"\(escapeAttribute(alt))\" loading=\"lazy\"></iframe>"
        case .mermaidSource:
            let sourceText: String
            if case .authored(let value) = target { sourceText = value } else { return fallbackHTML(fallback) }
            return "<div class=\"mermaid sdw-inline-mermaid\">\(escape(sourceText))</div><pre class=\"sdw-inline-mermaid__fallback\"><code class=\"language-mermaid\">\(escape(sourceText))</code></pre>"
        }
    }

    private func rendererDOMOutputHTML(_ output: DocumentRendererDOMOutput, plan: RendererEmbedPlan) -> String {
        switch output {
        case .vectorScene(let scene):
            return vectorSceneHTML(scene, plan: plan)
        }
    }

    private func vectorSceneHTML(_ scene: DocumentVectorScene, plan: RendererEmbedPlan) -> String {
        let bounds = scene.bounds
        let viewBox = [bounds.minimumX, bounds.minimumY, bounds.width, bounds.height]
            .map(Self.svgNumber).joined(separator: " ")
        let background: String = scene.backgroundColor.map { color in
            #"<rect x="\#(Self.svgNumber(bounds.minimumX))" y="\#(Self.svgNumber(bounds.minimumY))" width="\#(Self.svgNumber(bounds.width))" height="\#(Self.svgNumber(bounds.height))" fill="\#(color)"/>"#
        } ?? ""
        let markerID = "sdw-arrow-\(plan.placeholderID)"
        let elements = scene.elements.map { vectorElementHTML($0, markerID: markerID) }.joined()
        let title = escapeAttribute(plan.displayTitle ?? scene.accessibilityLabel)
        let content = """
        <svg class="sdw-inline-renderer__svg" viewBox="\(viewBox)" role="img" aria-label="\(title)" preserveAspectRatio="xMidYMid meet">
          <defs><marker id="\(escapeAttribute(markerID))" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L8,4 L0,8 z" fill="context-stroke"/></marker></defs>
          \(background)\(elements)
        </svg>
        """
        return rendererDOMContainerHTML(content: content, plan: plan)
    }

    private func rendererDOMFallbackHTML(_ fallback: String, plan: RendererEmbedPlan) -> String {
        rendererDOMContainerHTML(
            content: "<span class=\"sdw-inline-renderer__fallback\">\(fallback)</span>",
            plan: plan)
    }

    private func rendererDOMContainerHTML(content: String, plan: RendererEmbedPlan) -> String {
        """
        <figure class="sdw-inline-renderer sdw-inline-renderer--dom" data-renderer-role="inlineContent">
          \(content)
          \(rendererActionHTML(for: plan))
        </figure>
        """
    }

    private func rendererActionHTML(for plan: RendererEmbedPlan) -> String {
        guard let actionURL = rendererActionURL(for: plan) else { return "" }
        return #"<a class="sdw-inline-renderer__action" data-renderer-action="open-window" href="\#(escapeAttribute(actionURL))">Open interactive renderer</a>"#
    }

    private func vectorElementHTML(_ element: DocumentVectorScene.Element, markerID: String) -> String {
        switch element {
        case .rectangle(let x, let y, let width, let height, let cornerRadius, let style):
            return #"<rect x="\#(Self.svgNumber(x))" y="\#(Self.svgNumber(y))" width="\#(Self.svgNumber(width))" height="\#(Self.svgNumber(height))" rx="\#(Self.svgNumber(cornerRadius))" \#(vectorStyleAttributes(style))/>"#
        case .ellipse(let x, let y, let width, let height, let style):
            return #"<ellipse cx="\#(Self.svgNumber(x + width / 2))" cy="\#(Self.svgNumber(y + height / 2))" rx="\#(Self.svgNumber(width / 2))" ry="\#(Self.svgNumber(height / 2))" \#(vectorStyleAttributes(style))/>"#
        case .diamond(let x, let y, let width, let height, let style):
            let points = "\(Self.svgNumber(x + width / 2)),\(Self.svgNumber(y)) \(Self.svgNumber(x + width)),\(Self.svgNumber(y + height / 2)) \(Self.svgNumber(x + width / 2)),\(Self.svgNumber(y + height)) \(Self.svgNumber(x)),\(Self.svgNumber(y + height / 2))"
            return #"<polygon points="\#(points)" \#(vectorStyleAttributes(style))/>"#
        case .text(let x, let y, let text, let fontSize, let style):
            return #"<text x="\#(Self.svgNumber(x))" y="\#(Self.svgNumber(y + fontSize))" font-size="\#(Self.svgNumber(fontSize))" font-family="-apple-system, BlinkMacSystemFont, sans-serif" fill="\#(style.strokeColor)" opacity="\#(Self.svgNumber(style.opacity))">\#(escape(text))</text>"#
        case .polyline(let x, let y, let points, let arrowhead, let style):
            let values = points.map { "\(Self.svgNumber(x + $0.x)),\(Self.svgNumber(y + $0.y))" }.joined(separator: " ")
            let marker = arrowhead ? #" marker-end="url(#\#(escapeAttribute(markerID)))""# : ""
            return #"<polyline points="\#(values)" fill="none" \#(vectorStyleAttributes(style))\#(marker)/>"#
        }
    }

    private func vectorStyleAttributes(_ style: DocumentVectorScene.Style) -> String {
        let fill = style.fillColor ?? "none"
        return #"stroke="\#(style.strokeColor)" fill="\#(fill)" stroke-width="\#(Self.svgNumber(style.strokeWidth))" opacity="\#(Self.svgNumber(style.opacity))" vector-effect="non-scaling-stroke""#
    }

    private static func svgNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    private func rendererActionURL(for plan: RendererEmbedPlan) -> String? {
        guard let context = registerActivationContext(for: plan),
              let mimeType = plan.input.map({ input -> String in
                  switch input {
                  case .inlineArtifact(let artifact): artifact.mimeType.rawValue
                  case .source(let source): source.mimeType.rawValue
                  }
              }) else { return nil }
        let inputJSON: String
        do {
            inputJSON = String(decoding: try JSONEncoder().encode(context.input), as: UTF8.self)
        } catch {
            DebugLog.reader("inline DOM renderer action encoding failed: \(error.localizedDescription)")
            return nil
        }
        return Self.rendererActionURL(
            packageID: context.rendererReference.packageID.rawValue,
            version: context.rendererReference.version.rawValue,
            registrationID: context.rendererReference.registrationID.rawValue,
            inputJSON: inputJSON,
            capability: context.capability.rawValue,
            generation: context.generation,
            pageID: context.pageID.rawValue,
            pageVersionID: context.pageVersionID.rawValue,
            identity: context.identity,
            embeddingRole: context.embeddingRole,
            mimeType: mimeType)
    }

    private func inlineRendererHTML(plan: RendererEmbedPlan, fallback: String) -> String {
        guard plan.embeddingRole == .inlineContent else { return fallback }
        let id = escapeAttribute(plan.placeholderID)
        let reference = plan.rendererReference
        let referenceValue = "\(reference.packageID.rawValue)/\(reference.version.rawValue)/\(reference.registrationID.rawValue)"
        let context = registerActivationContext(for: plan)
        let admissionAttribute = context == nil ? "" : " data-renderer-admitted=\"true\""
        return "<span class=\"sdw-inline-renderer\" id=\"\(id)\" data-renderer-role=\"inlineContent\" data-renderer-reference=\"\(escapeAttribute(referenceValue))\"\(admissionAttribute)><span class=\"sdw-inline-renderer__fallback\">\(fallback)</span></span>"
    }

    private func transclusionHTML(
        target: DocumentTransclusionTarget,
        display: DocumentEmbedDisplayMetadata,
        fragment: String?,
        ancestors: Set<DocumentTransclusionTarget>
    ) -> String {
        let kind: String
        let id: String
        switch target {
        case .page(let pageID): kind = "page"; id = pageID.rawValue
        case .source(let sourceID): kind = "source"; id = sourceID.rawValue
        }
        let ancestorValue = ancestors.map(\.pathComponent).sorted().joined(separator: " ")
        let title = display.title ?? id
        let encodedFragment = fragment?.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""
        let nodeID = "embed-\(UUID().uuidString)"
        return """
        <details class="sdw-transclusion" data-sdw-embed-kind="\(kind)" data-sdw-embed-id="\(escapeAttribute(id))" data-sdw-embed-target="" data-sdw-embed-fragment="\(escapeAttribute(encodedFragment))" data-sdw-embed-name="\(escapeAttribute(title))" data-sdw-embed-path="\(escapeAttribute(ancestorValue))" data-sdw-node="\(escapeAttribute(nodeID))" data-sdw-state="empty"><summary><span class="sdw-embed-title">\(escape(title))</span></summary><div class="sdw-embed-body"><span class="sdw-embed-placeholder">Loading…</span></div></details>
        """
    }

    private func inlineTargetURL(_ target: DocumentInlineTarget) -> String {
        switch target {
        case .source(let source): return "wiki-blob://source/\(source.sourceID.rawValue)"
        case .blob(let sourceID): return "wiki-blob://source/\(sourceID.rawValue)"
        case .external(let url): return url.absoluteString
        case .authored(let value): return value
        }
    }

    private func fallbackHTML(_ fallback: DocumentEmbedFallback) -> String {
        switch fallback {
        case .image(let source, let altText): return ordinaryImageHTML(src: source, altText: altText)
        case .media(let label, let target): return "<a href=\"\(escapeAttribute(inlineTargetURL(target)))\">\(escape(label))</a>"
        case .code(let language, let source):
            let cls = language.map { " class=\"language-\(escapeAttribute($0))\"" } ?? ""
            return plainCodeBlockHTML(source, cls: cls)
        case .literal(let literal): return escape(literal)
        }
    }

    /// Fallback for nodes we don't specialize (Document, BlockDirective, …):
    /// descend into children.
    mutating func defaultVisit(_ markup: Markup) -> String { visitChildren(markup) }

    // MARK: Block

    mutating func visitHeading(_ heading: Heading) -> String {
        let level = max(1, min(6, heading.level))
        let slug = AnchorBlock.makeSlug(plainText(heading), counts: &slugCounts)
        return "<h\(level) id=\"\(escapeAttribute(slug))\">\(visitChildren(heading))</h\(level)>"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        "<p>\(visitChildren(paragraph))</p>"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote>\(visitChildren(blockQuote))</blockquote>"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let parserOrdinal = fenceOrdinal
        fenceOrdinal += 1
        let fenced: MarkdownFencedBlock
        do {
            fenced = try MarkdownFencedBlock(
                documentIdentity: documentIdentity,
                parserOrdinal: parserOrdinal,
                rawInfoString: codeBlock.language,
                bytes: Data(codeBlock.code.utf8))
        } catch {
            let cls = (codeBlock.language ?? "").isEmpty
                ? ""
                : " class=\"language-\(escapeAttribute(codeBlock.language ?? ""))\""
            return plainCodeBlockHTML(codeBlock.code, cls: cls)
        }
        let languageClass = fenced.fenceInfo?.alias.rawValue ?? codeBlock.language ?? ""
        let cls = languageClass.isEmpty
            ? ""
            : " class=\"language-\(escapeAttribute(languageClass))\""
        switch fenced.presentationPolicy {
        case .hostApprovedRichRequest(.mermaid):
            return mermaidRendererCardHTML(block: fenced, fallbackHTML: plainCodeBlockHTML(codeBlock.code, cls: cls))
        case .hostApprovedRichRequest(.jsoncanvas):
            return rendererCardHTML(
                plan: rendererEmbedPlan(for: fenced, alias: .jsoncanvas),
                fallbackHTML: plainCodeBlockHTML(codeBlock.code, cls: cls))
        case .hostApprovedRichRequest(.excalidraw):
            return rendererCardHTML(
                plan: rendererEmbedPlan(for: fenced, alias: .excalidraw),
                fallbackHTML: plainCodeBlockHTML(codeBlock.code, cls: cls))
        case .typedRawCodeFallback, .ordinaryCode:
            break
        }
        let highlighted: String?
        if case .enabled(let budget) = codeHighlighting,
           let language = CodeLanguage.fromFenceInfo(codeBlock.language),
           CodeSyntaxHighlighter.isEligibleSource(
               codeBlock.code,
               language: language,
               isCancelled: isCancelled),
           budget.claim() {
            highlighted = CodeSyntaxHighlighter.highlightedHTML(
                source: codeBlock.code,
                language: language,
                isCancelled: isCancelled)
        } else {
            highlighted = nil
        }
        return "<pre><code\(cls)>\(highlighted ?? escape(codeBlock.code))</code></pre>"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String { "<hr>" }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String { html.rawHTML }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        "<ul>\(visitChildren(unorderedList))</ul>"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        let start = orderedList.startIndex
        let attr = start <= 1 ? "" : " start=\"\(start)\""
        return "<ol\(attr)>\(visitChildren(orderedList))</ol>"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        // Tight-list heuristic: a single-paragraph item renders without the <p>
        // wrapper (how readers render tight lists). Multi-block items (loose
        // lists, nested lists, blockquotes) keep their block structure.
        let kids = Array(listItem.children)
        if kids.count == 1, let only = kids.first as? Paragraph {
            return "<li>\(visitChildren(only))</li>"
        }
        return "<li>\(visitChildren(listItem))</li>"
    }

    // MARK: Inline

    mutating func visitText(_ text: Text) -> String { escape(text.string) }
    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String { "<code>\(escape(inlineCode.code))</code>" }
    mutating func visitEmphasis(_ emphasis: Emphasis) -> String { "<em>\(visitChildren(emphasis))</em>" }
    mutating func visitStrong(_ strong: Strong) -> String { "<strong>\(visitChildren(strong))</strong>" }
    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String { "<del>\(visitChildren(strikethrough))</del>" }
    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String { " " }
    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String { "<br>" }
    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String { inlineHTML.rawHTML }

    mutating func visitLink(_ link: Link) -> String {
        let dest = link.destination ?? ""
        var tooltip = dest
        if let url = URL(string: dest), url.scheme == WikiLinkMarkdown.scheme {
            if url.host == WikiLinkMarkdown.anchorHost {
                if let frag = WikiLinkMarkdown.fragment(from: url) {
                    tooltip = "#\(frag)"
                }
            } else if let title = WikiLinkMarkdown.target(from: url) {
                let prefix: String
                switch url.host {
                case WikiLinkMarkdown.sourceHost: prefix = ParsedLink.LinkType.source.linkPrefix
                case WikiLinkMarkdown.chatHost:   prefix = ParsedLink.LinkType.chat.linkPrefix
                default:                          prefix = ""
                }
                let frag = WikiLinkMarkdown.fragment(from: url)
                let fragSuffix = frag.map { "#\($0)" } ?? ""
                tooltip = "[[\(prefix)\(title)\(fragSuffix)]]"
            }
        }
        return "<a href=\"\(escapeAttribute(dest))\" title=\"\(escapeAttribute(tooltip))\">\(visitChildren(link))</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        let source = image.source ?? ""
        let resolved = DocumentEmbedResolver(inputs: .init()).resolveMarkdownImage(
            source: source,
            altText: plainText(image),
            target: resolvedDocumentProjection?.markdownImage(source: source))
        return lowerResolvedEmbed(resolved)
    }

    // MARK: Tables

    mutating func visitTable(_ table: Table) -> String { "<table>\(visitChildren(table))</table>" }
    // swift-markdown models Table.Head as containing cells directly (no Row), so
    // the head needs its own <tr>; body rows come through visitTableRow.
    mutating func visitTableHead(_ tableHead: Table.Head) -> String {
        "<thead><tr>\(visitChildren(tableHead))</tr></thead>"
    }
    mutating func visitTableBody(_ tableBody: Table.Body) -> String { "<tbody>\(visitChildren(tableBody))</tbody>" }
    mutating func visitTableRow(_ tableRow: Table.Row) -> String { "<tr>\(visitChildren(tableRow))</tr>" }
    mutating func visitTableCell(_ tableCell: Table.Cell) -> String {
        let tag = (tableCell.parent is Table.Head) ? "th" : "td"
        return "<\(tag)>\(visitChildren(tableCell))</\(tag)>"
    }

    // MARK: Helpers

    /// Plain text of a subtree — for heading slugs and image alt. Recurses into
    /// links/images to capture display / alt text.
    private func plainText(_ markup: Markup) -> String {
        var s = ""
        for child in markup.children {
            if let t = child as? Text { s += t.string }
            else if child is SoftBreak || child is LineBreak { s += " " }
            else { s += plainText(child) }
        }
        return s
    }

    private func escape(_ s: String) -> String {
        HTMLEntities.escapeHTML(s)
    }

    private func escapeAttribute(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func plainCodeBlockHTML(_ code: String, cls: String) -> String {
        "<pre><code\(cls)>\(escape(code))</code></pre>"
    }

    private func ordinaryImageHTML(src: String, altText: String) -> String {
        "<img src=\"\(escapeAttribute(src))\" alt=\"\(escape(altText))\">"
    }

    private func mermaidRendererCardHTML(block: MarkdownFencedBlock, fallbackHTML: String) -> String {
        guard let plan = rendererEmbedPlan(for: block, alias: .mermaid),
              plan.fallbackReason != .oversizedInput else { return fallbackHTML }
        let reference = plan.rendererReference
        let rendererName = Self.rendererDisplayName(for: reference)
        let title = plan.displayTitle ?? rendererName
        let label = title == rendererName ? "\(rendererName) renderer" : "\(rendererName) renderer: \(title)"
        let placeholderID = Self.placeholderID(for: block)
        let expansionID = "\(placeholderID)-expansion"
        let refValue = "\(reference.packageID.rawValue)/\(reference.version.rawValue)/\(reference.registrationID.rawValue)"
        var actionHTML = ""
        if let input = plan.input,
           let admission = rendererActivationAdmission,
           case .inlineArtifact(let artifact) = input,
           plan.activationMetadata != nil,
           admission.pageID == artifact.pageID,
           admission.pageVersionID == artifact.pageVersionID {
            let context = RendererEmbedActivationContext(
                pageID: artifact.pageID, pageVersionID: artifact.pageVersionID,
                blockID: artifact.blockID, embeddingRole: plan.embeddingRole,
                rendererReference: reference,
                input: .inlineArtifact(artifact), capability: admission.capability,
                generation: admission.generation, displayTitle: title)
            let placeholder = RendererAttachmentPlaceholderID.validatedOrNil(placeholderID)
            admission.register(context: context, attachmentPlaceholderID: placeholder)
            do {
                let encoded = try String(decoding: JSONEncoder().encode(input), as: UTF8.self)
                let url = Self.rendererActionURL(
                    packageID: reference.packageID.rawValue, version: reference.version.rawValue,
                    registrationID: reference.registrationID.rawValue, inputJSON: encoded,
                    capability: context.capability.rawValue, generation: context.generation,
                    pageID: context.pageID.rawValue, pageVersionID: context.pageVersionID.rawValue,
                    identity: .block(artifact.blockID), embeddingRole: context.embeddingRole,
                    mimeType: artifact.mimeType.rawValue)
                actionHTML = "<a class=\"sdw-renderer-card__action\" data-renderer-action=\"open-window\" href=\"\(escapeAttribute(url))\" aria-label=\"Open \(escapeAttribute(label)) in Window\" style=\"flex:0 0 auto\">Open in Window</a>"
            } catch {
                DebugLog.reader("Mermaid renderer action encoding failed: \(error.localizedDescription)")
            }
        }
        let raw = escape(block.rawText)
        return """
        <section class="sdw-renderer-card" id="\(escapeAttribute(placeholderID))" role="group" aria-label="\(escapeAttribute(label))" data-renderer-kind="mermaid" data-renderer-expanded="false" data-renderer-reference="\(escapeAttribute(refValue))">
          <div class="sdw-renderer-card__row" style="display:flex;align-items:center;min-width:0">
            <button class="sdw-renderer-card__disclosure" data-mermaid-disclosure="true" type="button" aria-expanded="false" aria-controls="\(escapeAttribute(expansionID))" aria-label="Expand \(escapeAttribute(label))"><span aria-hidden="true">▸</span></button>
            <span class="sdw-renderer-card__title sdw-renderer-card__title--truncated" title="\(escapeAttribute(title))" style="min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1 1 auto">\(escape(title))</span>
            \(actionHTML)
          </div>
          <div class="sdw-renderer-card__expansion sdw-mermaid-row__expansion" id="\(escapeAttribute(expansionID))" role="region" aria-label="\(escapeAttribute(label)) details" hidden aria-hidden="true">
            <div class="mermaid sdw-mermaid-row__diagram"></div>
            <pre><code class="language-mermaid">\(raw)</code></pre>
          </div>
        </section>
        """
    }

    private func registerActivationContext(
        for plan: RendererEmbedPlan
    ) -> RendererEmbedActivationContext? {
        guard plan.activationMetadata != nil,
              let input = plan.input,
              let admission = rendererActivationAdmission,
              let placeholder = RendererAttachmentPlaceholderID.validatedOrNil(plan.placeholderID)
        else { return nil }

        let context: RendererEmbedActivationContext
        switch input {
        case .inlineArtifact(let artifact):
            guard artifact.pageID == admission.pageID,
                  artifact.pageVersionID == admission.pageVersionID else { return nil }
            context = RendererEmbedActivationContext(
                pageID: artifact.pageID,
                pageVersionID: artifact.pageVersionID,
                blockID: artifact.blockID,
                embeddingRole: plan.embeddingRole,
                rendererReference: plan.rendererReference,
                input: .inlineArtifact(artifact),
                capability: admission.capability,
                generation: admission.generation,
                displayTitle: plan.displayTitle)
        case .source(let source):
            guard let identity = documentIdentity,
                  identity.pageID == admission.pageID,
                  identity.pageVersionID == admission.pageVersionID else { return nil }
            let bridgeInput: RendererBridgeInput
            if let sourceVersionID = source.sourceVersionID {
                bridgeInput = .source(versionID: sourceVersionID)
            } else if let sourceMarkdownVersionID = source.sourceMarkdownVersionID {
                bridgeInput = .markdown(versionID: sourceMarkdownVersionID)
            } else {
                return nil
            }
            context = RendererEmbedActivationContext(
                pageID: identity.pageID,
                pageVersionID: identity.pageVersionID,
                identity: .source(source),
                embeddingRole: plan.embeddingRole,
                rendererReference: plan.rendererReference,
                input: bridgeInput,
                capability: admission.capability,
                generation: admission.generation,
                displayTitle: plan.displayTitle)
        }
        admission.register(context: context, attachmentPlaceholderID: placeholder)
        return context
    }

    private func rendererCardHTML(
        plan: RendererEmbedPlan?,
        fallbackHTML: String,
        readableFallbackHTML: String? = nil
    ) -> String {
        guard let plan else { return fallbackHTML }
        if plan.fallbackReason == .oversizedInput {
            return fallbackHTML
        }
        let ref = plan.rendererReference
        let refValue = "\(ref.packageID.rawValue)/\(ref.version.rawValue)/\(ref.registrationID.rawValue)"
        let rendererName = Self.rendererDisplayName(for: plan.rendererReference)
        let title = plan.displayTitle ?? rendererName
        let accessibilityLabel = title == rendererName
            ? "\(rendererName) renderer"
            : "\(rendererName) renderer: \(title)"
        let placeholderID = escapeAttribute(plan.placeholderID)
        let expansionID = escapeAttribute("\(plan.placeholderID)-expansion")
        let titleText = escape(title)
        let titleAttribute = escapeAttribute(title)
        let accessibilityLabelAttribute = escapeAttribute(accessibilityLabel)
        let summary = escape(plan.semanticContent)
        let fallbackNoticeHTML: String = {
            guard let reason = plan.fallbackReason else { return "" }
            return #"<p class="sdw-renderer-card__fallback">\#(escape(Self.fallbackNotice(for: reason)))</p>"#
        }()
        let mimeType: String? = {
            switch plan.input {
            case .inlineArtifact(let artifact): return artifact.mimeType.rawValue
            case .source(let source): return source.mimeType.rawValue
            case nil: return nil
            }
        }()
        let activationContext = registerActivationContext(for: plan)
        let inputAttribute: String
        let inputJSON: String?
        if let activationContext {
            do {
                let encoded = try String(decoding: JSONEncoder().encode(activationContext.input), as: UTF8.self)
                inputJSON = encoded
                inputAttribute = #" data-renderer-input="\#(escapeAttribute(encoded))""#
            } catch {
                inputJSON = nil
                inputAttribute = ""
            }
        } else {
            inputJSON = nil
            inputAttribute = ""
        }
        let activationState: RendererCardActivationState
        if plan.activationMetadata != nil, let activationContext, let inputJSON, let mimeType {
            let actionURL = Self.rendererActionURL(
                packageID: ref.packageID.rawValue,
                version: ref.version.rawValue,
                registrationID: ref.registrationID.rawValue,
                inputJSON: inputJSON,
                capability: activationContext.capability.rawValue,
                generation: activationContext.generation,
                pageID: activationContext.pageID.rawValue,
                pageVersionID: activationContext.pageVersionID.rawValue,
                identity: activationContext.identity,
                embeddingRole: activationContext.embeddingRole,
                mimeType: mimeType
            )
            activationState = .admitted(actionURL: actionURL)
        } else {
            activationState = .unavailable
        }
        let isExpandable = activationState.isExpandable
        let isExpanded = isExpandable == false
        let actionHTML: String
        let disclosureActionAttribute: String
        let disclosureAccessibilityLabel: String
        if case .admitted(let actionURL) = activationState {
            actionHTML = #"<a class="sdw-renderer-card__action" data-renderer-action="open-window" href="\#(escapeAttribute(actionURL))" aria-label="Open \#(accessibilityLabelAttribute) in Window" style="flex:0 0 auto">Open in Window</a>"#
            disclosureActionAttribute = #" data-renderer-action="expand""#
            disclosureAccessibilityLabel = "Expand \(accessibilityLabel)"
        } else {
            actionHTML = ""
            disclosureActionAttribute = ""
            disclosureAccessibilityLabel = "\(accessibilityLabel) fallback shown"
        }
        let disabledAttribute = isExpandable ? "" : #" disabled aria-disabled="true""#
        let expansionVisibilityAttributes = isExpandable
            ? #" hidden aria-hidden="true""#
            : #" aria-hidden="false""#
        return """
        <section class="sdw-renderer-card" id="\(placeholderID)" role="group" aria-label="\(accessibilityLabelAttribute)" data-renderer-expanded="\(isExpanded)" data-renderer-reference="\(escapeAttribute(refValue))"\(inputAttribute)>
          <div class="sdw-renderer-card__row" style="display:flex;align-items:center;min-width:0">
            <button class="sdw-renderer-card__disclosure"\(disclosureActionAttribute) type="button" aria-expanded="\(isExpanded)" aria-controls="\(expansionID)" aria-label="\(escapeAttribute(disclosureAccessibilityLabel))"\(disabledAttribute)><span aria-hidden="true">▸</span></button>
            <span class="sdw-renderer-card__title sdw-renderer-card__title--truncated" title="\(titleAttribute)" style="min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1 1 auto">\(titleText)</span>
            \(actionHTML)
          </div>
          <div class="sdw-renderer-card__expansion" id="\(expansionID)" role="region" aria-label="\(accessibilityLabelAttribute) details"\(expansionVisibilityAttributes)>
            <p class="sdw-renderer-card__summary">\(summary)</p>
            \(fallbackNoticeHTML)
            \(readableFallbackHTML ?? "")
          </div>
        </section>
        """
    }

    /// A reader-facing sentence for a fence the renderer would not take.
    /// `.oversizedInput` returns the original fenced code instead of a card and
    /// never reaches this.
    private static func fallbackNotice(for reason: MarkdownFenceFallbackReason) -> String {
        switch reason {
        case .emptyInfoString:
            return "This block does not name a renderer."
        case .malformedInfoString:
            return "This block's renderer name could not be read."
        case .unsupportedAlias:
            return "No approved renderer draws this kind of block."
        case .packageAliasDisallowed:
            return "The renderer for this block is not available here."
        case .missingDocumentIdentity:
            return "This block is not tied to a saved version yet, so it cannot open."
        case .oversizedInput:
            return "This block is too large to draw."
        }
    }

    private func rendererEmbedPlan(for block: MarkdownFencedBlock, alias: MarkdownRichFenceAlias) -> RendererEmbedPlan? {
        guard rendererEmbedProjection?.allowsRichFence(alias) == true else { return nil }
        let reference = Self.rendererReference(for: alias)
        let placeholderID = Self.placeholderID(for: block)
        let summary = Self.semanticSummary(for: alias)
        let displayTitle = block.fenceInfo?.displayTitle
        guard block.bytes.count <= WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount else {
            return RendererEmbedPlan(
                placeholderID: placeholderID,
                rendererReference: reference,
                semanticContent: summary,
                displayTitle: displayTitle,
                fallbackReason: .oversizedInput,
                activationMetadata: nil)
        }
        guard let mime = Self.inlineArtifactMIME(for: alias) else {
            return RendererEmbedPlan(
                placeholderID: placeholderID,
                rendererReference: reference,
                semanticContent: summary,
                displayTitle: displayTitle,
                fallbackReason: .missingDocumentIdentity,
                activationMetadata: nil)
        }
        guard let identity = documentIdentity,
              let blockID = block.blockID else {
            return RendererEmbedPlan(
                placeholderID: placeholderID,
                rendererReference: reference,
                semanticContent: summary,
                displayTitle: displayTitle,
                fallbackReason: nil,
                activationMetadata: nil)
        }
        let artifact: RendererEmbeddedContent.InlineArtifact
        do {
            artifact = try RendererEmbeddedContent.InlineArtifact(
                pageID: identity.pageID,
                pageVersionID: identity.pageVersionID,
                blockID: blockID,
                fenceKind: alias,
                mimeType: mime,
                bytes: block.bytes)
        } catch {
            return RendererEmbedPlan(
                placeholderID: placeholderID,
                rendererReference: reference,
                semanticContent: summary,
                displayTitle: displayTitle,
                fallbackReason: .missingDocumentIdentity,
                activationMetadata: nil)
        }
        guard let admission = rendererActivationAdmission,
              admission.pageID == identity.pageID,
              admission.pageVersionID == identity.pageVersionID else {
            return RendererEmbedPlan(
                placeholderID: placeholderID,
                rendererReference: reference,
                input: .inlineArtifact(artifact),
                semanticContent: summary,
                displayTitle: displayTitle,
                fallbackReason: nil,
                activationMetadata: nil)
        }
        return RendererEmbedPlan(
            placeholderID: placeholderID,
            rendererReference: reference,
            input: .inlineArtifact(artifact),
            semanticContent: summary,
            displayTitle: displayTitle,
            fallbackReason: nil,
            activationMetadata: Self.activationMetadata(for: alias))
    }

    private static func placeholderID(for block: MarkdownFencedBlock) -> String {
        "sdw-renderer-\(block.digest.hex.prefix(16))-\(block.parserOrdinal)"
    }

    private static func semanticSummary(for alias: MarkdownRichFenceAlias) -> String {
        switch alias {
        case .mermaid:
            return "Mermaid diagram fence"
        case .jsoncanvas:
            return "JSON Canvas document fence"
        case .excalidraw:
            return "Excalidraw document fence"
        }
    }

    /// User-facing renderer names are centralized so untitled rows remain
    /// readable without coupling presentation to raw registration identifiers.
    private static func rendererDisplayName(for reference: RendererReference) -> String {
        switch reference.registrationID.rawValue {
        case "json-canvas": return "JSON Canvas"
        case "excalidraw": return "Excalidraw"
        case "mermaid": return "Mermaid"
        default: return reference.registrationID.rawValue
        }
    }

    private static func activationMetadata(for alias: MarkdownRichFenceAlias) -> RendererEmbedActivationMetadata {
        switch alias {
        case .mermaid:
            return RendererEmbedActivationMetadata(
                controlLabel: "Open",
                accessibilityLabel: "Open mermaid renderer",
                summary: "Preview diagram code in the renderer pane.")
        case .jsoncanvas:
            return RendererEmbedActivationMetadata(
                controlLabel: "Open",
                accessibilityLabel: "Open JSON Canvas renderer",
                summary: "Open the static canvas in the renderer pane.")
        case .excalidraw:
            return RendererEmbedActivationMetadata(
                controlLabel: "Interact",
                accessibilityLabel: "Open Excalidraw renderer",
                summary: "Open the static Excalidraw card in the renderer pane.")
        }
    }

    private static func inlineArtifactMIME(for alias: MarkdownRichFenceAlias) -> RendererMIMEType? {
        switch alias {
        case .mermaid:
            return RendererMIMEType(rawValue: "text/mermaid")
        case .jsoncanvas, .excalidraw:
            return RendererMIMEType(rawValue: "application/json")
        }
    }

    private static func rendererReference(for alias: MarkdownRichFenceAlias) -> RendererReference {
        switch alias {
        case .mermaid:
            guard let packageID = RendererPackageID(rawValue: "org.selfdrivingwiki.builtin"),
                  let version = RendererPackageVersion(rawValue: "1.0.0"),
                  let registrationID = RendererRegistrationID(rawValue: "mermaid")
            else { preconditionFailure("approved mermaid renderer reference must remain valid") }
            return RendererReference(packageID: packageID, version: version, registrationID: registrationID)
        case .jsoncanvas:
            guard let packageID = RendererPackageID(rawValue: "org.selfdrivingwiki.builtin"),
                  let version = RendererPackageVersion(rawValue: "1.0.0"),
                  let registrationID = RendererRegistrationID(rawValue: "json-canvas")
            else { preconditionFailure("approved jsoncanvas renderer reference must remain valid") }
            return RendererReference(packageID: packageID, version: version, registrationID: registrationID)
        case .excalidraw:
            // Read from the bundled-package constants rather than repeating the
            // literals: a card whose version drifts from the installed package
            // resolves to no descriptor and presents nothing.
            return RendererReference(
                packageID: BundledRendererPackages.excalidrawPackageID,
                version: BundledRendererPackages.excalidrawVersion,
                registrationID: BundledRendererPackages.excalidrawRegistrationID)
        }
    }

    private static func rendererActionURL(
        packageID: String,
        version: String,
        registrationID: String,
        inputJSON: String,
        capability: String,
        generation: Int,
        pageID: String,
        pageVersionID: String,
        identity: RendererEmbedActivationContext.Identity,
        embeddingRole: RendererEmbeddingRole,
        mimeType: String
    ) -> String {
        var components = URLComponents()
        components.scheme = "renderer-action"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "package", value: packageID),
            URLQueryItem(name: "version", value: version),
            URLQueryItem(name: "registration", value: registrationID),
            URLQueryItem(name: "input", value: inputJSON),
            URLQueryItem(name: "capability", value: capability),
            URLQueryItem(name: "generation", value: String(generation)),
            URLQueryItem(name: "page", value: pageID),
            URLQueryItem(name: "pageVersion", value: pageVersionID),
            URLQueryItem(name: "embeddingRole", value: embeddingRole.rawValue),
            URLQueryItem(name: "mime", value: mimeType)
        ]
        switch identity {
        case .block(let blockID):
            components.queryItems?.append(contentsOf: [
                URLQueryItem(name: "block", value: blockID.digest.hex),
                URLQueryItem(name: "blockPage", value: blockID.pageID.rawValue),
                URLQueryItem(name: "blockPageVersion", value: blockID.pageVersionID.rawValue),
                URLQueryItem(name: "blockOrdinal", value: String(blockID.parserOrdinal))
            ])
        case .source(let source):
            components.queryItems?.append(contentsOf: [
                URLQueryItem(name: "sourceID", value: source.sourceID.rawValue),
                URLQueryItem(name: "sourceDigest", value: source.digest.hex),
                URLQueryItem(name: "sourceVersion", value: source.sourceVersionID?.rawValue),
                URLQueryItem(name: "sourceMarkdownVersion", value: source.sourceMarkdownVersionID?.rawValue)
            ])
        }
        return components.url?.absoluteString ?? "renderer-action://open"
    }
}
