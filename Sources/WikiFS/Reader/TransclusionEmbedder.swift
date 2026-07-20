import Foundation
import WikiFSCore
import WikiFSLinks
import WikiFSTypes

/// Pure, side-effect-free fetch + render helpers for the lazy-expand side of
/// the Plan v2 `![[X]]` transclusion seam
/// (`plans/page-embed-v2.md` §4). The linkify layer in `WikiLinkMarkdown`
/// emits a collapsed `<details>` whose body is empty; when the user opens it,
/// the `WikiReaderView` Coordinator hops OFF the main actor into
/// `WikiReadPool.asyncRead`, calls `renderEmbedBody`, and injects the result
/// via the safe `sdwInjectEmbed` JS function (HTML passed as a parameter).
///
/// These helpers run the SAME pre-pass + HTML visit the top-level reader uses
/// (`ReaderMarkdown.prepared` + `MarkdownHTMLRenderer.render`), so a nested
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

    /// Render one embed body to an HTML fragment. Fetches the raw body via
    /// method-atomic store reads (`getPage` / `sourceEmbedBody`), runs the
    /// shared `ReaderMarkdown.prepared` + `MarkdownHTMLRenderer.render`
    /// pipeline, and returns the HTML the Coordinator injects via
    /// `sdwInjectEmbed` (Plan v2 §4.4 — safe parameter-based injection).
    ///
    /// Returns the string `"<!sdw-empty>"` sentinel when there is no body to
    /// render (page missing, source binary with no extraction yet). The caller
    /// detects the sentinel and renders the muted placeholder
    /// (`sdw-embed-empty` / `sdw-embed-cycle`) instead of injecting.
    static func renderEmbedBody(
        store: GRDBWikiStore,
        id: PageID,
        kind: ParsedLink.LinkType,
        context: WikiRenderContext
    ) throws -> String {
        let raw: String?
        switch kind {
        case .page:
            let page = try store.getPage(id: id)
            raw = PageMarkdownFormat.stripped(body: page.bodyMarkdown, title: page.title)
        case .source:
            raw = try sourceEmbedBody(store: store, id: id)
        case .chat:
            raw = nil
        }
        guard let raw, !raw.isEmpty else { return emptySentinel }
        let prepared = ReaderMarkdown.prepared(
            raw,
            isResolved: context.isResolved,
            embedInfo: context.embedInfo,
            displayName: context.displayName,
            pinnedExtractionID: context.pinnedExtractionID)
        return MarkdownHTMLRenderer.render(prepared)
    }

    /// Pure read against a read-only store: source-derived markdown HEAD if
    /// present, else raw UTF-8 bytes for native-text sources, else `nil`
    /// (binary/PDF — caller renders the "Source not yet extracted" placeholder,
    /// **no extraction is triggered** — hard read-path invariant, Plan v2 §4.2).
    ///
    /// Mirrors `WikiStoreModel.processedMarkdownHead(for:)`'s native-text
    /// fallback but **never writes** (no v1 seeding from verbatim bytes — that
    /// is a write and belongs on the main actor, not the read path).
    static func sourceEmbedBody(store: GRDBWikiStore, id: PageID) throws -> String? {
        // 1. Preferred: extracted markdown HEAD (already in the DB).
        if let head = try store.processedMarkdownHead(sourceID: id) {
            return head.content
        }
        // 2. Native-text source: raw UTF-8 bytes are readable text. Do NOT
        //    decode raw bytes for HTML/PDF/binary — Plan v2 §4.2. Surface
        //    failures via `DebugLog` (house rule, #475) — a silent `try?` here
        //    would hide a store read failure.
        let src = try store.getSource(id: id)
        guard MimeType.isText(src.mimeType) else { return nil }
        let data: Data
        do {
            data = try store.sourceContent(id: id)
        } catch {
            DebugLog.reader("sourceEmbedBody sourceContent failed id=\(id.rawValue): \(error)")
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Sentinel returned by `renderEmbedBody` when there is no body to render
    /// (page missing, source binary with no extraction). The caller detects it
    /// and renders the muted placeholder instead. A sentinel (rather than `nil`)
    /// keeps the function signature single-return-value simple and lets the
    /// caller's `evaluateJavaScript` path always pass a String.
    static let emptySentinel = "<!sdw-empty>"

    /// True when `html` is the empty sentinel (no body to render).
    static func isEmpty(_ html: String) -> Bool { html == emptySentinel }

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
    static func placeholderBodyHTML(kind: ParsedLink.LinkType, id: PageID, name: String) -> String {
        let escaped = name
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let encodedID = id.rawValue.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? id.rawValue
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

    /// True when `id` already appears in the space-separated ancestor chain
    /// `path` (the `data-sdw-embed-path` attribute). Pure — drives the
    /// cycle-marker branch in the Coordinator handler so it is unit-testable
    /// off the main actor. Keyed on the raw id string (Plan v2 §8: page and
    /// source ULIDs are disjoint sets — a false positive across them is not
    /// possible because a ULID names one row in one table).
    static func isCycle(path: String, id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return path.split(separator: " ").contains { $0 == id }
    }
}
