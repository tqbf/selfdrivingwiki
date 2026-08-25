import Foundation
import WikiFSCore
import WikiFSLinks
import WikiFSTypes

/// Pure, side-effect-free fetch + render helpers for the lazy-expand side of
/// the Plan v2 `![[X]]` transclusion seam
/// (`plans/page-embed-v2.md` §4). The typed Markdown lowerer emits a collapsed
/// `<details>` whose body is empty. When the user opens it,
/// the `WikiReaderView` Coordinator hops OFF the main actor into
/// `WikiReadService.asyncRead`, calls `renderEmbedBody`, and injects the result
/// via the safe `sdwInjectEmbed` JS function (HTML passed as a parameter).
///
/// These helpers run the SAME pre-pass + HTML visit the top-level reader uses
/// (`ReaderMarkdown.preparedDocument` + typed `MarkdownHTMLRenderer.render`), so a nested
/// `![[…]]` inside an embedded body is itself a collapsed `<details>` and a
/// `[[…]]` cite link inside works identically.
///
/// **Threading / SQLite discipline.** Both helpers are pure given a read-only
/// store view (`GRDBWikiStore(readOnlyURL:)`, `query_only=ON`) and the
/// pure-data `WikiRenderContext` snapshot — they never touch the main actor,
/// the WebView, or `evaluateJavaScript`, and they run no transaction /
/// inference / extraction. Unit-testable against the `:memory:` fixtures
/// (`TestStoreFactory.inMemory()`, #658).
enum TransclusionEmbedder {

    /// The identity carried by a lazy transclusion fetch. The raw HTML attribute
    /// is decoded at the reader boundary into the namespace selected by the
    /// link kind, so a source cannot reach a page store API by accident.
    typealias TargetID = DocumentTransclusionTarget

    enum RenderPolicy: Hashable, Sendable {
        case nestedStatic
    }

    enum Result: Equatable, Sendable {
        case content(String)
        case empty
        case cycle
        case failed

        var contentHTML: String? {
            guard case .content(let html) = self else { return nil }
            return html
        }

        var isEmpty: Bool { self == .empty }
    }

    private static func rawValue(of target: TargetID) -> String {
        switch target {
        case .page(let id): id.rawValue
        case .source(let id): id.rawValue
        }
    }

    /// Render one embed body to an HTML fragment. Fetches the raw body via
    /// method-atomic store reads (`getPage` / `sourceEmbedBody`), runs the
    /// shared typed preparation and `MarkdownHTMLRenderer.render`
    /// pipeline, and returns the HTML the Coordinator injects via
    /// `sdwInjectEmbed` (Plan v2 §4.4 — safe parameter-based injection).
    ///
    /// Returns `.empty` when there is no body to render. This includes a missing
    /// page or a binary source without extracted Markdown. The caller renders a
    /// muted typed placeholder instead of injecting content.
    static func renderEmbedBody(
        access: borrowing WikiReadAccess,
        target: TargetID,
        context: WikiRenderContext,
        options: MarkdownRenderOptions,
        policy: RenderPolicy = .nestedStatic,
        ancestors: Set<TargetID> = []
    ) throws -> Result {
        let raw: String?
        let contentKind: ReaderMarkdown.ContentKind
        switch target {
        case .page(let id):
            let page = try access.getPage(id: id)
            raw = PageMarkdownFormat.stripped(body: page.bodyMarkdown, title: page.title)
            contentKind = .document
        case .source(let id):
            raw = try sourceEmbedBody(access: access, id: id)
            contentKind = .source
        }
        guard let raw, !raw.isEmpty else { return .empty }
        let prepared = ReaderMarkdown.preparedDocument(raw, contentKind: contentKind)
        let nestedAncestors = ancestors.union([target])
        let projection = context.documentEmbedResolver().projection(
            for: prepared,
            ancestors: nestedAncestors)
        let nestedOptions = MarkdownRenderOptions(
            codeHighlighting: options.codeHighlighting,
            rendererEmbedProjection: options.rendererEmbedProjection,
            documentIdentity: nil,
            rendererActivationAdmission: nil)
        return .content(MarkdownHTMLRenderer.render(
            prepared,
            projection: projection,
            options: nestedOptions))
    }

    /// Pure read against a read-only store: source-derived markdown HEAD if
    /// present, else raw UTF-8 bytes for native-text sources, else `nil`
    /// (binary/PDF — caller renders the "Source not yet extracted" placeholder,
    /// **no extraction is triggered** — hard read-path invariant, Plan v2 §4.2).
    ///
    /// Mirrors `WikiStoreModel.processedMarkdownHead(for:)`'s native-text
    /// fallback but **never writes** (no v1 seeding from verbatim bytes — that
    /// is a write and belongs on the main actor, not the read path).
    static func sourceEmbedBody(access: borrowing WikiReadAccess, id: SourceID) throws -> String? {
        if let head = try access.processedMarkdownHead(sourceID: id) {
            return head.content
        }
        let source = try access.getSource(id: id)
        guard MimeType.isText(source.mimeType) else { return nil }
        let data: Data
        do {
            data = try access.sourceContent(id: id)
        } catch {
            DebugLog.reader("sourceEmbedBody sourceContent failed id=\(id.rawValue): \(error)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Explicit in-memory fixture fallback. Production reads use
    /// `WikiReadAccess` through `WikiReadService`.
    static func sourceEmbedBody(testFixtureStore store: GRDBWikiStore, id: SourceID) throws -> String? {
        if let head = try store.processedMarkdownHead(sourceID: id) {
            return head.content
        }
        let source = try store.getSource(id: id)
        guard MimeType.isText(source.mimeType) else { return nil }
        do {
            return String(data: try store.sourceContent(id: id), encoding: .utf8)
        } catch {
            DebugLog.reader("sourceEmbedBody sourceContent failed id=\(id.rawValue): \(error)")
            return nil
        }
    }

    static func renderEmbedBody(
        testFixtureStore store: GRDBWikiStore,
        target: TargetID,
        context: WikiRenderContext,
        options: MarkdownRenderOptions,
        policy: RenderPolicy = .nestedStatic,
        ancestors: Set<TargetID> = []
    ) throws -> Result {
        let raw: String?
        let contentKind: ReaderMarkdown.ContentKind
        switch target {
        case .page(let id):
            let page = try store.getPage(id: id)
            raw = PageMarkdownFormat.stripped(body: page.bodyMarkdown, title: page.title)
            contentKind = .document
        case .source(let id):
            if let head = try store.processedMarkdownHead(sourceID: id) {
                raw = head.content
            } else {
                let source = try store.getSource(id: id)
                raw = MimeType.isText(source.mimeType)
                    ? String(data: try store.sourceContent(id: id), encoding: .utf8)
                    : nil
            }
            contentKind = .source
        }
        guard let raw, !raw.isEmpty else { return .empty }
        let prepared = ReaderMarkdown.preparedDocument(raw, contentKind: contentKind)
        let nestedAncestors = ancestors.union([target])
        let projection = context.documentEmbedResolver().projection(
            for: prepared,
            ancestors: nestedAncestors)
        let nestedOptions = MarkdownRenderOptions(
            codeHighlighting: options.codeHighlighting,
            rendererEmbedProjection: options.rendererEmbedProjection,
            documentIdentity: nil,
            rendererActivationAdmission: nil)
        return .content(MarkdownHTMLRenderer.render(
            prepared,
            projection: projection,
            options: nestedOptions))
    }

    /// Render the cycle-marker body HTML (`<!sdw-cycle>...</div>`-shaped) for
    /// the embed fetch handler when the target id is already in the ancestor
    /// chain (Plan v2 §8). Pure — used by the handler so the cycle path is
    /// unit-testable off the main actor without driving `evaluateJavaScript`.
    static func cycleMarkerHTML(name: String) -> String {
        let escaped = name
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<div class=\"sdw-embed-body sdw-embed-cycle\">"
             + "<span class=\"sdw-embed-placeholder\">↩ \(escaped) (cycle)</span></div>"
    }

    /// Render the muted placeholder body shown when an expand resolves the
    /// target but the source has no extractable body yet (binary, no head
    /// markdown). Includes an in-app open link so the user can navigate to
    /// the source's detail view. NO extraction is triggered (Plan v2 §7.2).
    static func placeholderBodyHTML(kind: ParsedLink.LinkType, id: String, name: String) -> String {
        let escaped = name
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let encodedID = id.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? id
        let encodedName = name.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? name
        let url = "\(WikiLinkMarkdown.scheme)://\(WikiLinkMarkdown.sourceHost)?id=\(encodedID)&title=\(encodedName)"
        return "<div class=\"sdw-embed-body sdw-embed-empty\">"
             + "<span class=\"sdw-embed-placeholder\">Source not yet extracted.</span>"
             + "<a href=\"\(url)\">Open “\(escaped)”</a>"
             + "</div>"
    }

    /// Build the `evaluateJavaScript` source for the safe `sdwInjectEmbed`
    /// setter call (Plan v2 §4.4): HTML is a **parameter** (escaped via
    /// `WikiReaderRep.jsString`), never concatenated into the JS source. Pure.
    static func injectJSCall(nodeId: String, html: String) -> String {
        let escapedNode = WikiReaderRep.jsString(nodeId)
        let escapedHTML = WikiReaderRep.jsString(html)
        return "sdwInjectEmbed(\"\(escapedNode)\", \"\(escapedHTML)\")"
    }

    /// Build the `evaluateJavaScript` source for the cycle-marker injection
    /// (re-uses `injectJSCall`'s safe-escape seam). Pure.
    static func cycleMarkerJSCall(nodeId: String, name: String) -> String {
        injectJSCall(nodeId: nodeId, html: cycleMarkerHTML(name: name))
    }

    /// Decode the tagged ancestor chain carried at the DOM boundary.
    static func ancestors(path: String) -> Set<TargetID> {
        Set(path.split(separator: " ").compactMap(TargetID.init(pathComponent:)))
    }

    /// True when the full tagged target already appears in the ancestor chain.
    static func isCycle(path: String, target: TargetID) -> Bool {
        ancestors(path: path).contains(target)
    }
}
