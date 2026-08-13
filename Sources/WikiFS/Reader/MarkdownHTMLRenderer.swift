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
    ///
    /// When `imageResolver` is provided, relative image srcs (those that are not
    /// `http(s)`, `data:`, or already `wiki-blob:`/`wiki:`) are passed to it; a
    /// non-nil return rewrites the `<img src>`. Absolute/protocol/data srcs and
    /// unresolved relatives are left verbatim. Phase 4 sibling resolution.
    static func render(
        _ markdown: String,
        imageResolver: ((String) -> String?)? = nil,
        options: MarkdownRenderOptions,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) -> String {
        var renderer = MarkdownHTMLRenderer()
        renderer.imageResolver = imageResolver
        renderer.codeHighlighting = options.codeHighlighting
        renderer.rendererEmbedProjection = options.rendererEmbedProjection
        renderer.documentIdentity = options.documentIdentity
        renderer.rendererActivationAdmission = options.rendererActivationAdmission
        renderer.isCancelled = isCancelled
        return renderer.visit(Document(parsing: markdown))
    }

    /// Per-render slug dedup counts, mirroring `AnchorBlock.makeSlug` so heading
    /// ids match the native reader's resolution list.
    private var slugCounts: [String: Int] = [:]
    private var fenceOrdinal = 0

    /// Phase 4: optional resolver that rewrites a relative image src to a
    /// `wiki-blob://source/<id>` URL. Set by the static `render` before visiting.
    private var imageResolver: ((String) -> String?)?
    private var codeHighlighting: MarkdownCodeHighlightingPolicy = .disabled
    private var rendererEmbedProjection: RendererEmbedProjection?
    private var documentIdentity: MarkdownDocumentIdentity?
    private var rendererActivationAdmission: RendererEmbedActivationAdmission?
    private var isCancelled: @Sendable () -> Bool = { Task.isCancelled }

    private mutating func visitChildren(_ markup: Markup) -> String {
        var s = ""
        for child in markup.children { s += visit(child) }
        return s
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
        let cls = (codeBlock.language ?? "").isEmpty
            ? ""
            : " class=\"language-\(escapeAttribute(codeBlock.language ?? ""))\""
        switch fenced.presentationPolicy {
        case .hostApprovedRichRequest(.mermaid):
            return plainCodeBlockHTML(codeBlock.code, cls: cls)
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
        let rawSrc = image.source ?? ""
        let src = resolvedImageSrc(rawSrc)
        return "<img src=\"\(escapeAttribute(src))\" alt=\"\(escape(plainText(image)))\">"
    }

    /// Phase 4: resolve a relative image src through the `imageResolver` (when
    /// present). Only relative srcs are candidates — absolute (`http`/`https`),
    /// `data:`, and already-rewritten (`wiki-blob:`/`wiki:`) srcs pass through
    /// verbatim. An unresolved relative is left verbatim (no crash).
    private func resolvedImageSrc(_ src: String) -> String {
        guard let resolver = imageResolver, !src.isEmpty else { return src }
        let lower = src.lowercased()
        if lower.hasPrefix("http") || lower.hasPrefix("data:")
            || lower.hasPrefix("wiki-blob:") || lower.hasPrefix("wiki:") {
            return src
        }
        return resolver(src) ?? src
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

    private func rendererCardHTML(plan: RendererEmbedPlan?, fallbackHTML: String) -> String {
        guard let plan else { return fallbackHTML }
        if plan.fallbackReason == .oversizedInput {
            return fallbackHTML
        }
        let ref = plan.rendererReference
        let refValue = "\(ref.packageID.rawValue)/\(ref.version.rawValue)/\(ref.registrationID.rawValue)"
        let title: String = {
            switch plan.rendererReference.registrationID.rawValue {
            case "json-canvas": return "JSON Canvas"
            case "excalidraw": return "Excalidraw"
            default: return plan.rendererReference.registrationID.rawValue
            }
        }()
        let placeholderID = escapeAttribute(plan.placeholderID)
        let summary = escape(plan.semanticContent)
        let fallback = escape(plan.fallbackReason?.rawValue ?? "static preview")
        let control = escape(plan.activationMetadata?.controlLabel ?? "Open")
        let aria = escapeAttribute(plan.activationMetadata?.accessibilityLabel ?? "renderer preview")
        let mimeType: String? = {
            guard case .inlineArtifact(let artifact) = plan.input else { return nil }
            return artifact.mimeType.rawValue
        }()
        let activationContext: RendererEmbedActivationContext? = {
            guard let input = plan.input,
                  let admission = rendererActivationAdmission,
                  case .inlineArtifact(let artifact) = input
            else { return nil }
            let context = RendererEmbedActivationContext(
                pageID: artifact.pageID,
                pageVersionID: artifact.pageVersionID,
                blockID: artifact.blockID,
                rendererReference: ref,
                input: .inlineArtifact(artifact),
                capability: admission.capability,
                generation: admission.generation)
            admission.register(context: context)
            return context
        }()
        let inputAttribute: String
        let inputJSON: String?
        if let input = plan.input, activationContext != nil {
            do {
                let encoded = try String(decoding: JSONEncoder().encode(input), as: UTF8.self)
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
        let actionHTML: String
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
                blockID: activationContext.blockID.digest.hex,
                blockPageID: activationContext.blockID.pageID.rawValue,
                blockPageVersionID: activationContext.blockID.pageVersionID.rawValue,
                blockParserOrdinal: activationContext.blockID.parserOrdinal,
                mimeType: mimeType
            )
            actionHTML = #"<a class="sdw-renderer-card__action" href="\#(escapeAttribute(actionURL))">\#(control)</a>"#
        } else {
            actionHTML = ""
        }
        return """
        <section class="sdw-renderer-card" id="\(placeholderID)" role="group" aria-label="\(aria)" data-renderer-reference="\(escapeAttribute(refValue))"\(inputAttribute)>
          <header class="sdw-renderer-card__header">\(title)</header>
          <p class="sdw-renderer-card__summary">\(summary)</p>
          <p class="sdw-renderer-card__fallback">\(fallback)</p>
          \(actionHTML)
        </section>
        """
    }

    private func rendererEmbedPlan(for block: MarkdownFencedBlock, alias: MarkdownRichFenceAlias) -> RendererEmbedPlan? {
        guard rendererEmbedProjection?.allowsRichFence(alias) == true else { return nil }
        let reference = Self.rendererReference(for: alias)
        let placeholderID = Self.placeholderID(for: block)
        let summary = Self.semanticSummary(for: alias)
        guard block.bytes.count <= WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount else {
            return RendererEmbedPlan(
                placeholderID: placeholderID,
                rendererReference: reference,
                semanticContent: summary,
                fallbackReason: .oversizedInput,
                activationMetadata: nil)
        }
        guard let mime = Self.inlineArtifactMIME(for: alias) else {
            return RendererEmbedPlan(
                placeholderID: placeholderID,
                rendererReference: reference,
                semanticContent: summary,
                fallbackReason: .missingDocumentIdentity,
                activationMetadata: nil)
        }
        guard let identity = documentIdentity,
              let blockID = block.blockID else {
            return RendererEmbedPlan(
                placeholderID: placeholderID,
                rendererReference: reference,
                semanticContent: summary,
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
                fallbackReason: nil,
                activationMetadata: nil)
        }
        return RendererEmbedPlan(
            placeholderID: placeholderID,
            rendererReference: reference,
            input: .inlineArtifact(artifact),
            semanticContent: summary,
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
            guard let packageID = RendererPackageID(rawValue: "org.selfdrivingwiki.excalidraw-readonly"),
                  let version = RendererPackageVersion(rawValue: "1.0.0"),
                  let registrationID = RendererRegistrationID(rawValue: "excalidraw")
            else { preconditionFailure("approved excalidraw renderer reference must remain valid") }
            return RendererReference(packageID: packageID, version: version, registrationID: registrationID)
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
        blockID: String,
        blockPageID: String,
        blockPageVersionID: String,
        blockParserOrdinal: Int,
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
            URLQueryItem(name: "block", value: blockID),
            URLQueryItem(name: "blockPage", value: blockPageID),
            URLQueryItem(name: "blockPageVersion", value: blockPageVersionID),
            URLQueryItem(name: "blockOrdinal", value: String(blockParserOrdinal)),
            URLQueryItem(name: "mime", value: mimeType)
        ]
        return components.url?.absoluteString ?? "renderer-action://open"
    }
}
