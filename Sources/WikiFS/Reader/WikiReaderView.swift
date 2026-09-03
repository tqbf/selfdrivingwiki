import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import WikiFSCore

// pattern: Mixed (unavoidable)

internal struct RendererEmbedActivationContext: Hashable, Sendable {
    enum Identity: Hashable, Sendable {
        case block(MarkdownBlockID)
        case source(RendererEmbeddedContent.Source)
    }

    let pageID: PageID
    let pageVersionID: PageVersionID
    let identity: Identity
    let embeddingRole: RendererEmbeddingRole
    let rendererReference: RendererReference
    let input: RendererBridgeInput
    let capability: RendererSessionCapability
    let generation: Int
    /// Presentation metadata only. It does not participate in authorization,
    /// equality, hashing, renderer input, or stable content identity.
    let displayTitle: String?

    /// Compatibility accessor for inline-artifact callers. Source identities are
    /// deliberately not coerced into a fake block.
    var blockID: MarkdownBlockID? {
        if case .block(let blockID) = identity { return blockID }
        return nil
    }

    init(pageID: PageID, pageVersionID: PageVersionID, blockID: MarkdownBlockID,
         embeddingRole: RendererEmbeddingRole = .disclosureRow,
         rendererReference: RendererReference, input: RendererBridgeInput,
         capability: RendererSessionCapability, generation: Int,
         displayTitle: String? = nil) {
        self.init(pageID: pageID, pageVersionID: pageVersionID, identity: .block(blockID),
                  embeddingRole: embeddingRole, rendererReference: rendererReference, input: input,
                  capability: capability, generation: generation, displayTitle: displayTitle)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pageID == rhs.pageID && lhs.pageVersionID == rhs.pageVersionID && lhs.identity == rhs.identity &&
        lhs.embeddingRole == rhs.embeddingRole && lhs.rendererReference == rhs.rendererReference && lhs.input == rhs.input &&
        lhs.capability == rhs.capability && lhs.generation == rhs.generation
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pageID); hasher.combine(pageVersionID); hasher.combine(identity)
        hasher.combine(embeddingRole); hasher.combine(rendererReference); hasher.combine(capability); hasher.combine(generation)
        switch input {
        case .source(let versionID):
            hasher.combine(0); hasher.combine(versionID)
        case .markdown(let versionID):
            hasher.combine(1); hasher.combine(versionID)
        case .inlineArtifact(let artifact):
            hasher.combine(2); hasher.combine(artifact)
        }
    }

    init(pageID: PageID, pageVersionID: PageVersionID, identity: Identity,
         embeddingRole: RendererEmbeddingRole = .disclosureRow,
         rendererReference: RendererReference, input: RendererBridgeInput,
         capability: RendererSessionCapability, generation: Int,
         displayTitle: String? = nil) {
        self.pageID = pageID
        self.pageVersionID = pageVersionID
        self.identity = identity
        self.embeddingRole = embeddingRole
        self.rendererReference = rendererReference
        self.input = input
        self.capability = capability
        self.generation = generation
        self.displayTitle = displayTitle
    }
}

// registeredContexts is the only mutable state, and every access is protected by lock.
// swiftlint:disable:next unchecked_sendable
internal final class RendererEmbedActivationAdmission: @unchecked Sendable {
    let pageID: PageID
    let pageVersionID: PageVersionID
    let capability: RendererSessionCapability
    let generation: Int
    private let lock = NSLock()
    private var registeredContexts: Set<RendererEmbedActivationContext> = []
    private var attachmentContexts: [RendererAttachmentPlaceholderID: RendererEmbedActivationContext] = [:]

    init(
        pageID: PageID,
        pageVersionID: PageVersionID,
        capability: RendererSessionCapability,
        generation: Int
    ) {
        self.pageID = pageID
        self.pageVersionID = pageVersionID
        self.capability = capability
        self.generation = generation
    }

    func register(
        context: RendererEmbedActivationContext,
        attachmentPlaceholderID: RendererAttachmentPlaceholderID? = nil
    ) {
        guard context.pageID == pageID,
              context.pageVersionID == pageVersionID,
              context.capability == capability,
              context.generation == generation
        else { return }
        lock.lock()
        registeredContexts.insert(context)
        if let attachmentPlaceholderID {
            attachmentContexts[attachmentPlaceholderID] = context
        }
        lock.unlock()
    }

    func authorizes(context: RendererEmbedActivationContext) -> Bool {
        guard context.pageID == pageID,
              context.pageVersionID == pageVersionID,
              context.capability == capability,
              context.generation == generation
        else { return false }
        lock.lock()
        defer { lock.unlock() }
        return registeredContexts.contains(context)
    }

    func attachmentContext(for placeholderID: RendererAttachmentPlaceholderID) -> RendererEmbedActivationContext? {
        lock.lock()
        defer { lock.unlock() }
        guard let context = attachmentContexts[placeholderID], registeredContexts.contains(context) else {
            return nil
        }
        return context
    }

    func sourceContext(
        sourceID: SourceID,
        digest: RendererSHA256Digest,
        mimeType: RendererMIMEType,
        input: RendererBridgeInput
    ) -> RendererEmbedActivationContext? {
        lock.lock()
        defer { lock.unlock() }
        return registeredContexts.first { context in
            guard case .source(let source) = context.identity else { return false }
            return source.sourceID == sourceID && source.digest == digest && source.mimeType == mimeType
                && context.input == input
        }
    }
}

// MARK: - WikiReaderView

/// Renders markdown in a `WKWebView` via `MarkdownHTMLRenderer` — the single
/// reader for every markdown surface in the app (pages, sources, system prompt,
/// changelog). It replaces the vendored Textual reader (`MarkdownPreview`): the
/// browser's windowed layout sidesteps the whole-document layout freeze on large
/// docs, and WKWebView ships whole-link selection + a native context menu for
/// free (the fork Textual carried solely to get those).
///
/// Loads **asynchronously**: the page chrome appears immediately with a spinner,
/// and the footnote/link pre-pass + swift-markdown render run off the main actor.
/// Ghost-link resolution needs the store, which is `@MainActor`, so existence
/// sets are computed on the main actor before the convert task and passed in —
/// letting a missing `[[Ghost]]` render red via a single CSS rule.
///
/// **Anchors + quote highlight:** a `[[source:Name#Section]]` /
/// `[[Page#"quote"]]` link (set via `selectPage(anchor:)` /
/// `selectSource(anchor:)`) is consumed from the store's pending-anchor path,
/// resolved with the shared `AnchorBlock.parse` + `resolveAnchor`, then applied
/// after the page paints — scroll to the heading's slug `id` for a section
/// anchor, or `window.find` + `<mark>` for a quote highlight (with a
/// whitespace-tolerant TreeWalker fallback).
struct WikiReaderView: View {
    let markdown: String
    var currentSelection: WikiSelection? = nil
    let store: WikiStoreModel
    /// Optional typed page identity for rendered page-version content.
    /// Page surfaces pass this so load-time identity stays pinned to the
    /// version already owned by the host instead of re-querying HEAD.
    var documentIdentity: MarkdownDocumentIdentity? = nil
    /// The File Provider spike, for "Copy File Path" on wiki links. Only page
    /// readers (which own a spike) pass it; `nil` elsewhere omits that item.
    var fileProvider: FileProviderFacade? = nil
    /// Opens the "Add from URL" sheet pre-filled with a URL — injected via the
    /// `\.addURLHandler` environment value, feeding the http(s) "Add as Source"
    /// context-menu item through `WikiLinkMenuNSItems`.
    @Environment(\.addURLHandler) private var addURLHandler
    @Environment(\.addBookmarkHandler) private var addBookmarkHandler
    /// Hosts that own the full renderer pane can route a typed activation here.
    /// Readers without that pane leave this nil and the card stays inert.
    var onRendererActivation: (@MainActor (RendererReference, RendererBridgeInput) -> Void)? = nil
    /// Renderer-owned inline attachment construction. The reader owns the
    /// admitted placeholder lifecycle but does not know renderer formats.
    var inlineAttachmentResolver: RendererInlineAttachmentResolver = RendererInlineAttachmentResolverFactory.defaultResolver
    /// Validated installed descriptor snapshot supplied by the reader host.
    /// It is data-only; constructing renderer sessions remains downstream.
    var inlineRendererDescriptors: [RendererDescriptor] = []
    /// Per-descriptor validated package resource providers, used to serve
    /// `renderer-package:` assets to in-page expansion iframes. Hosts owning a
    /// full renderer pane pass the live snapshot; default is no packages.
    var rendererPackageInputs: RendererPackageEmbedInputs? = nil
    @AppStorage("reader.zoom") private var readerZoom = Double(ZoomScale.defaultScale)
    @State private var isLoading = true

    /// Find bar: when set, the matched text is passed to the web view for
    /// `window.find()` highlighting and scrolling.
    var findText: String? = nil
    var findVersion: Int = 0
    /// 1-based index of the current match (`FindModel.currentMatchIndex`).
    /// `applyFind` advances `window.find()` this many times so next/previous
    /// navigation lands on distinct matches instead of always the first.
    var findOccurrence: Int = 1

    var body: some View {
        ZStack {
            WikiReaderRep(markdown: markdown,
                          store: store,
                          fileProvider: fileProvider,
                          readerZoom: readerZoom,
                          currentSelection: currentSelection,
                          documentIdentity: documentIdentity,
                          anchorVersion: store.pendingScrollAnchorVersion,
                          isLoading: $isLoading,
                          addURLHandler: addURLHandler,
                          addBookmarkHandler: addBookmarkHandler,
                          onRendererActivation: onRendererActivation,
                          inlineAttachmentResolver: inlineAttachmentResolver,
                          inlineRendererDescriptors: inlineRendererDescriptors,
                          rendererPackageInputs: rendererPackageInputs,
                          findText: findText, findVersion: findVersion, findOccurrence: findOccurrence)
            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
            }
        }
    }

    nonisolated static func rendererActivationRoute(
        for url: URL,
        admission: RendererEmbedActivationAdmission?,
        isMainFrame: Bool
    ) -> (reference: RendererReference, input: RendererBridgeInput)? {
        guard isMainFrame,
              let admission,
              url.scheme == "renderer-action",
              url.host == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let items = (components.queryItems ?? []).reduce(into: [String: String]()) { result, item in
            if let value = item.value { result[item.name] = value }
        }
        let pageID = PageID(rawValue: items["page"] ?? "")
        let pageVersionID = PageVersionID(rawValue: items["pageVersion"] ?? "")
        guard let packageID = RendererPackageID(rawValue: items["package"] ?? ""),
              let version = RendererPackageVersion(rawValue: items["version"] ?? ""),
              let registrationID = RendererRegistrationID(rawValue: items["registration"] ?? ""),
              let embeddingRole = RendererEmbeddingRole(rawValue: items["embeddingRole"] ?? ""),
              let capability = items["capability"],
              let generation = Int(items["generation"] ?? ""),
              capability == admission.capability.rawValue,
              generation == admission.generation,
              pageID == admission.pageID,
              pageVersionID == admission.pageVersionID,
              let inputJSON = items["input"]
        else { return nil }
        let input: RendererBridgeInput
        do {
            input = try JSONDecoder().decode(RendererBridgeInput.self, from: Data(inputJSON.utf8))
        } catch {
            return nil
        }
        guard let mimeType = items["mime"] else { return nil }
        switch input {
        case .inlineArtifact(let artifact):
            let blockPageID = PageID(rawValue: items["blockPage"] ?? "")
            let blockPageVersionID = PageVersionID(rawValue: items["blockPageVersion"] ?? "")
            guard let blockDigest = items["block"],
                  let blockOrdinal = Int(items["blockOrdinal"] ?? ""),
                  blockPageID == admission.pageID,
                  blockPageVersionID == admission.pageVersionID,
                  artifact.pageID == admission.pageID,
                  artifact.pageVersionID == admission.pageVersionID,
                  artifact.blockID.pageID == admission.pageID,
                  artifact.blockID.pageVersionID == admission.pageVersionID,
                  artifact.blockID.parserOrdinal == blockOrdinal,
                  artifact.blockID.digest.hex == blockDigest,
                  artifact.digest.hex == blockDigest,
                  artifact.mimeType.rawValue == mimeType else { return nil }
            let reference = RendererReference(packageID: packageID, version: version, registrationID: registrationID)
            let context = RendererEmbedActivationContext(pageID: admission.pageID, pageVersionID: admission.pageVersionID,
                                                         blockID: artifact.blockID, embeddingRole: embeddingRole,
                                                         rendererReference: reference,
                                                         input: input, capability: admission.capability, generation: admission.generation)
            guard admission.authorizes(context: context) else { return nil }
            return (reference: reference, input: .inlineArtifact(artifact))
        case .source, .markdown:
            let sourceID = SourceID(rawValue: items["sourceID"] ?? "")
            guard let digestHex = items["sourceDigest"] else { return nil }
            let digest: RendererSHA256Digest
            do { digest = try RendererSHA256Digest(hex: digestHex) } catch { return nil }
            guard let sourceMIME = RendererMIMEType(rawValue: mimeType),
                  let context = admission.sourceContext(
                      sourceID: sourceID, digest: digest, mimeType: sourceMIME, input: input),
                  context.embeddingRole == embeddingRole,
                  case .source(let admittedSource) = context.identity,
                  admittedSource.bytes.count <= WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount,
                  RendererSHA256.digest(admittedSource.bytes) == admittedSource.digest,
                  admittedSource.mimeType.rawValue == mimeType
            else { return nil }
            switch input {
            case .source(let versionID):
                guard admittedSource.sourceVersionID == versionID,
                      items["sourceVersion"] == versionID.rawValue,
                      items["sourceMarkdownVersion"] == nil else { return nil }
            case .markdown(let versionID):
                guard admittedSource.sourceMarkdownVersionID == versionID,
                      items["sourceMarkdownVersion"] == versionID.rawValue,
                      items["sourceVersion"] == nil else { return nil }
            case .inlineArtifact:
                return nil
            }
            let reference = RendererReference(packageID: packageID, version: version, registrationID: registrationID)
            guard context.rendererReference == reference,
                  admission.authorizes(context: context) else { return nil }
            return (reference: reference, input: input)
        }
    }

    nonisolated static func rendererActionNavigationPolicy(for url: URL) -> WKNavigationActionPolicy {
        url.scheme == "renderer-action" ? .cancel : .allow
    }

    /// Resolve a consumed anchor fragment to a scroll target: a section anchor
    /// scrolls to the heading's slug id; anything else (a `[[…#"quote"]]` or an
    /// unresolved fragment) becomes a quote highlight. Mirrors the reader's
    /// heading-vs-quote split. Pure — unit-tested.
    ///
    /// `nonisolated`: it touches no actor state, but `WikiReaderView` is a `View`
    /// (its members inherit main-actor isolation). Without this the unit tests
    /// — which run off the main actor — trip a `dispatch_assert_queue_fail`.
    nonisolated static func resolveScrollTarget(_ fragment: String, blocks: [AnchorBlock]) -> PendingScroll? {
        if let id = resolveAnchor(fragment, in: blocks),
           blocks.contains(where: { $0.id == id && $0.kind == .heading }) {
            return .heading(slug: id)
        }
        let quote = fragment.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return quote.isEmpty ? nil : .quote(quote)
    }

    /// Classify a clicked `wiki://` (or same-page anchor) URL into a routing
    /// action, using the proven query-based helpers from `WikiLinkMarkdown`
    /// (`target`/`fragment`/`resolvedKind`/`isSamePageAnchor`). Pure — unit-tested.
    ///
    /// This replaces the old `comps.path` extraction, which read `""` for the
    /// query-encoded `wiki://page?title=…` URLs `WikiLinkMarkdown` emits (no path
    /// component), silently no-op'ing every wiki-link click.
    nonisolated static func linkRoute(for url: URL) -> WikiLinkRoute {
        if WikiLinkMarkdown.isSamePageAnchor(url) {
            return .samePageAnchor(fragment: WikiLinkMarkdown.fragment(from: url))
        }
        guard let title = WikiLinkMarkdown.target(from: url) else { return .inert }
        let frag = WikiLinkMarkdown.fragment(from: url)
        // Phase 5: prefer the canonical `?id=<ULID>` when present; `title` is the
        // transition fallback for legacy/`title=`-only URLs.
        switch WikiLinkMarkdown.resolvedKind(from: url) {
        case .page:
            return .page(title: title, id: WikiLinkMarkdown.id(from: url), fragment: frag)
        case .source:
            return .source(title: title, id: WikiLinkMarkdown.sourceID(from: url),
                           fragment: frag, pin: WikiLinkMarkdown.pin(from: url))
        case .chat:
            return .chat(
                title: title,
                id: WikiLinkMarkdown.id(from: url).map { ChatID(rawValue: $0.rawValue) },
                fragment: frag)
        case nil:     return .inert
        }
    }

    /// Build an `onWikiLink` closure that routes a clicked `wiki://` link to the
    /// store — navigate to the page/source, carrying any `#fragment`. Same-page
    /// anchors are inert here: this powers the agent transcript (a chat feed,
    /// not a single document), so `[[#anchor]]` has no document to scroll within.
    ///
    /// Built where the store lives (and the navigation detail column is wired)
    /// and forwarded unchanged down through the intermediate views to
    /// `ChatWebView`. Pass `nil` where navigation is impossible.
    @MainActor
    static func onWikiLinkHandler(for store: WikiStoreModel) -> (URL, Bool) -> Void {
        { url, openInNewTab in
            switch WikiReaderView.linkRoute(for: url) {
            case .page(let title, let id, let frag):
                if let id, store.selectPage(byID: id, anchor: frag, openInNewTab: openInNewTab) { }
                else { store.selectPage(byTitle: title, anchor: frag, openInNewTab: openInNewTab) }
            case .source(let title, let id, let frag, let pin):
                if let id, store.selectSource(byID: id, anchor: frag, openInNewTab: openInNewTab, pinnedExtractionID: pin) { }
                else { store.selectSource(byDisplayName: title, anchor: frag, openInNewTab: openInNewTab) }
            case .chat(let title, let id, let frag):
                if let id, store.selectChat(byID: id, anchor: frag, openInNewTab: openInNewTab) { }
                else { store.selectChat(byTitle: title, anchor: frag, openInNewTab: openInNewTab) }
            case .samePageAnchor, .inert:      break
            }
        }
    }

    /// Full HTML document string built around `body` (the converted markdown).
    /// Pure / callable off the main actor. The theme mirrors the native reader's
    /// geometry (760pt column, 12pt inset from `PageEditorMetrics`) and uses CSS
    /// variables + `color-scheme` so light/dark match the app appearance. A CSS
    /// rule colors unresolved `wiki://missing` links red (ghost links). Rich
    /// fences render through package sessions mounted by the attachment
    /// coordinator; this document carries no diagram engine of its own.
    nonisolated static func documentHTML(
        _ body: String
    ) -> String {
        let width = Int(PageEditorMetrics.readableContentWidth)
        let inset = Int(PageEditorMetrics.contentInset)
        return """
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>
          :root {
            --text: #1c1c1e;
            --muted: rgba(60, 60, 67, 0.6);
            --code-bg: rgba(0, 0, 0, 0.06);
            --border: rgba(0, 0, 0, 0.12);
            --code-keyword: #8b3a65;
            --code-string: #0b6e4f;
            --code-comment: #6e6e73;
            --code-type: #0a5f9e;
            --code-function: #7a4d00;
            --code-property: #6d3c91;
            --code-number: #9a3d00;
            --code-operator: #505050;
            --code-punctuation: #505050;
            --code-constant: #7a4d00;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --text: #e6e6e6;
              --muted: rgba(235, 235, 245, 0.6);
              --code-bg: rgba(255, 255, 255, 0.08);
              --border: rgba(255, 255, 255, 0.16);
              --code-keyword: #ff7ab2;
              --code-string: #8bd5a8;
              --code-comment: #a1a1a6;
              --code-type: #7dcfff;
              --code-function: #ffd580;
              --code-property: #c6a0f6;
              --code-number: #f5a97f;
              --code-operator: #d0d0d5;
              --code-punctuation: #d0d0d5;
              --code-constant: #ffd580;
            }
          }
          /* color-scheme above drives the page canvas (light/dark background). */
          body {
            font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
            font-size: 15px; line-height: 1.55;
            color: var(--text);
            max-width: \(width)px; margin: 24px 0 72px; padding: 0 \(inset)px;
            -webkit-text-size-adjust: 100%;
            -webkit-font-smoothing: antialiased;
          }
          h1, h2, h3, h4, h5, h6 { line-height: 1.25; font-weight: 600; margin: 1.4em 0 0.5em; }
          h1 { font-size: 1.7em; } h2 { font-size: 1.4em; } h3 { font-size: 1.15em; } h4 { font-size: 1em; }
          p { margin: 0 0 1em; }
          strong { font-weight: 600; }
          a { color: -webkit-link; }
          /* Ghost links: a wiki link whose target doesn't resolve is emitted as
             wiki://missing?… by the linkifier — color it red so dangling
             references are obvious at a glance. */
          a[href^="wiki://missing"] { color: #ff453a; }
          /* Plan v2 transclusion: a `<details class="sdw-transclusion">` is the
             collapsed page / non-media-source embed. The disclosure is
             collapsed-by-default per the HTML spec (no `open` attribute). The
             broken state reuses the same red as ghost links (the
             `a[href^="wiki://missing"]` selector above is an `<a>` attribute
             selector and does NOT style a `<details>`, so this is its own
             rule — Plan v2 §7.1). */
          details.sdw-transclusion {
            margin: 0.6em 0; padding: 0.4em 0.8em; border-radius: 8px;
            background: var(--code-bg); border: 1px solid var(--border);
          }
          details.sdw-transclusion > summary {
            cursor: pointer; list-style: none; font-weight: 500;
            color: var(--text);
          }
          details.sdw-transclusion > summary::-webkit-details-marker { display: none; }
          details.sdw-transclusion > summary::before {
            content: "▸"; display: inline-block; width: 1em; color: var(--muted);
            transition: transform 0.15s ease;
          }
          details.sdw-transclusion[open] > summary::before { transform: rotate(90deg); }
          details.sdw-transclusion .sdw-embed-body { margin-top: 0.5em; }
          details.sdw-transclusion .sdw-embed-placeholder {
            color: var(--muted); font-style: italic;
          }
          details.sdw-transclusion[data-sdw-state="missing"] .sdw-embed-title { color: #ff453a; }
          details.sdw-transclusion .sdw-embed-cycle .sdw-embed-placeholder { color: var(--muted); }
          /* External links: append a small ↗ glyph so it's visually clear the
             link will open in an external browser, unlike internal wiki://
             links which navigate in-app. */
          a[href^="http"]::after {
            content: "↗";
            font-size: 0.75em;
            margin-left: 0.15em;
            opacity: 0.6;
          }
          ul, ol { padding-left: 1.6em; margin: 0 0 1em; }
          li { margin: 0.15em 0; }
          blockquote {
            margin: 0 0 1em; padding: 0.1em 0 0.1em 1em;
            border-left: 3px solid var(--border); color: var(--muted);
          }
          code {
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            font-size: 0.9em; background: var(--code-bg);
            padding: 0.1em 0.35em; border-radius: 4px;
          }
          pre {
            margin: 0 0 1em; padding: 12px 14px;
            background: var(--code-bg); border-radius: 8px; overflow: auto;
            font-size: 13px; line-height: 1.45;
          }
          pre code { background: none; padding: 0; font-size: inherit; }
          .sdw-code-keyword { color: var(--code-keyword); }
          .sdw-code-string { color: var(--code-string); }
          .sdw-code-comment { color: var(--code-comment); }
          .sdw-code-type { color: var(--code-type); }
          .sdw-code-function { color: var(--code-function); }
          .sdw-code-property { color: var(--code-property); }
          .sdw-code-number { color: var(--code-number); }
          .sdw-code-operator { color: var(--code-operator); }
          .sdw-code-punctuation { color: var(--code-punctuation); }
          .sdw-code-constant { color: var(--code-constant); }
          /* Renderer rows stay in normal document flow. The expanded native
             renderer projects onto the matching expansion rectangle. */
          section.sdw-renderer-card {
            margin: 0.35em 0; padding: 0.2em 0; border-bottom: 1px solid var(--border);
            background: transparent;
          }
          .sdw-renderer-card__row { gap: 0.35em; min-height: 2em; cursor: pointer; }
          .sdw-renderer-card__title {
            color: var(--text); font-size: 0.95em; font-weight: 400; line-height: 1.3;
          }
          .sdw-renderer-card__disclosure {
            inline-size: 2em; block-size: 2em; padding: 0; border: 0;
            border-radius: 5px; background: transparent; color: var(--muted);
            font: inherit; cursor: pointer;
          }
          .sdw-renderer-card__disclosure[aria-expanded="true"] span { display:inline-block; transform:rotate(90deg); }
          .sdw-renderer-card__summary {
            margin: 0.35em 0 0; font-size: 0.9em; color: var(--muted);
          }
          .sdw-renderer-card__fallback, .sdw-renderer-card__status {
            margin: 0.25em 0 0; font-size: 0.85em; color: var(--muted);
          }
          .sdw-renderer-card__expansion { margin-top: 0.4em; }
          .sdw-renderer-card__action {
            display: inline-block; margin: 0; padding: 0.3em 0.65em;
            border: 1px solid var(--border); border-radius: 6px;
            background: transparent; color: -webkit-link; font: inherit; font-size: 0.9em;
            line-height: 1.25; text-decoration: none; cursor: pointer;
          }
          .sdw-renderer-card__disclosure:focus-visible,
          .sdw-renderer-card__action:focus-visible {
            outline: 2px solid -webkit-focus-ring-color; outline-offset: 2px;
          }
          hr { border: none; border-top: 1px solid var(--border); margin: 1.5em 0; }
          table { border-collapse: collapse; margin: 0 0 1em; }
          th, td { border: 1px solid var(--border); padding: 6px 10px; text-align: left; vertical-align: top; }
          th { font-weight: 600; }
          img { max-width: 100%; height: auto; }
          .wiki-embed { max-width: 100%; height: auto; border-radius: 8px; }
          .wiki-embed-pdf { width: 100%; height: 600px; border: 1px solid var(--border); border-radius: 8px; }
          iframe.wiki-embed-video { width: 100%; aspect-ratio: 16/9; height: auto; border: none; border-radius: 8px; }
          iframe.wiki-embed-audio { width: 100%; height: 152px; border: none; border-radius: 8px; }
          audio.wiki-embed { width: 100%; }
          .sdw-inline-renderer { display: block; position: relative; width: 100%; }
          .sdw-inline-renderer[data-renderer-admitted="true"] {
            min-height: \(Int(RendererAttachmentHostPolicy.dynamicInlineRendererReservedHeight))px;
            margin: 0 0 1em; overflow: hidden; border-radius: 8px;
          }
          .sdw-inline-renderer__action { display: inline-block; margin-top: 0.45em; font-size: 0.9em; }
          mark.sdwhl { background: rgba(255, 213, 79, 0.8); border-radius: 2px; }
          @media (prefers-reduced-motion: reduce) {
            .sdw-renderer-card__disclosure span { transition:none; }
          }
        </style></head>
        <body><article>\(body)</article></body></html>
        """
    }
}

/// What a clicked `wiki://` link should do. The pure classifier
/// `WikiReaderView.linkRoute(for:)` returns one of these; the Coordinator and
/// the agent transcript's `onWikiLink` closure map each case onto a store call.
enum WikiLinkRoute: Equatable, Sendable {
    /// Same-page `[[#Section]]` — scroll within the current document.
    case samePageAnchor(fragment: String?)
    /// Resolved page link — navigate + carry the optional `#fragment`. `id` is
    /// the canonical ULID when the URL carried `?id=` (Phase 5); nil for legacy
    /// `?title=`-only links, which resolve by `title` as the transition fallback.
    case page(title: String, id: PageID?, fragment: String?)
    /// Resolved source link — navigate + carry the optional `#fragment`. `id` is
    /// the canonical ULID when present; nil for legacy `?title=`-only links.
    /// `pin` is the pinned-extraction smv id when the URL carried `&pin=` (Phase 6:
    /// a pinned quote link); nil otherwise (opens HEAD).
    case source(title: String, id: SourceID?, fragment: String?, pin: SourceMarkdownVersionID?)
    /// Resolved chat link — navigate to a persisted chat. `id` is the
    /// canonical ULID when the URL carried `?id=`; nil for legacy `?title=`-only
    /// links, which resolve by `title` as the transition fallback. `fragment`
    /// carries a `#"quote"` passage (issue #281): the destination `ChatDetailView`
    /// resolves it to a message and highlights the passage.
    case chat(title: String, id: ChatID?, fragment: String?)
    /// Unresolved (`wiki://missing`) or un-classifiable — inert.
    case inert
}

/// A resolved pending anchor to apply once the page has painted.
enum PendingScroll: Equatable {
    case heading(slug: String)
    case quote(String)
}

// MARK: - WKWebView bridge

/// A `WKWebView` subclass that augments the macOS context menu with the custom
/// wiki-link items (Suggest / Find Similar / Copy as Wiki Link / Copy File Path
/// for wiki links, Add as Source for http(s)) on top of WKWebView's native
/// Copy / Copy Link / Look Up / Share.
///
/// WKWebView has **no** public macOS API for customizing its context menu (the
/// `WKUIDelegate` `contextMenuConfigurationForElement:` family is iOS/
/// visionOS-only), so we override `NSView.willOpenMenu(_:with:)`. WebKit's menu
/// items don't carry the link URL, and there's no synchronous way to query the
/// DOM, so the hovered `<a>` href is tracked continuously via a `mouseover`
/// listener that posts to a `WKScriptMessageHandler`; by the time the user
/// right-clicks, the hovered href is current. `willOpenMenu` then builds the
/// items for that href via `WikiLinkMenuNSItems` and prepends them (plus a
/// separator) to WebKit's defaults.
@MainActor
final class WikiReaderWebView: WKWebView {
    /// Existence/navigation state for the custom menu items, set by
    /// `WikiReaderRep` from the view's store / fileProvider / addURLHandler.
    var store: WikiStoreModel?
    var fileProvider: FileProviderFacade?
    var currentSelection: WikiSelection?
    var addURLHandler: (@MainActor @Sendable (String) -> Void)?
    var addBookmarkHandler: (@MainActor @Sendable (BookmarkTargetPickerContext) -> Void)?
    var onRendererActivation: (@MainActor (RendererReference, RendererBridgeInput) -> Void)?
    var rendererActivationAdmission: RendererEmbedActivationAdmission?
    /// The href under the cursor, kept current by the injected `mouseover`
    /// listener. Read synchronously in `willOpenMenu`. `fileprivate(set)` so the
    /// in-file message-handler proxy can write it without exposing a public setter.
    fileprivate(set) var hoveredLinkHref: String?

    /// How "Print Page…" prints (issue #933). Production runs WebKit's own
    /// `printOperation(with:)` against *this* view, so the job is whatever the
    /// reader is currently showing. It is a stored seam purely so tests can
    /// observe that the menu item targets the right web view without a real
    /// print panel appearing; nothing in the app reassigns it.
    var printRenderedPage: @MainActor (WKWebView) -> Void = ReaderPrinting.run(for:)

    /// The Coordinator that owns this view's load lifecycle + the Plan v2
    /// embed-fetch handler. Set by `WikiReaderRep.makeNSView` so the
    /// `EmbedFetchMessageHandler` proxy can forward `WKScriptMessage` bodies
    /// without holding a strong reference (the view holds the Coordinator
    /// indirectly via the representable's context).
    weak var coordinator: WikiReaderRep.Coordinator?

    /// Serves `wiki-blob://source/<id>` blob bytes from SQLite to the WKWebView.
    /// Created in `init()` (must be registered before the view loads). Its
    /// `store` is set by the representable alongside the view's own `store`.
    let blobHandler = BlobSchemeHandler(store: nil)

    /// Frame-origin tokens for admitted renderer references, set by
    /// `WikiReaderRep.installRendererPackages`. The Coordinator reads a
    /// token to build the iframe `src` during activation.
    var rendererPackageFrameTokens: [RendererReference: RendererFrameOriginToken] = [:]

    /// Entry paths for admitted renderer references, set alongside the
    /// frame tokens. Both maps share lifecycles (replacement revokes both).
    var rendererPackageFrameEntryPaths: [RendererReference: String] = [:]

    /// Routes `renderer-package://<frame-token>/…` requests from in-page
    /// expansion iframes to per-frame validated package providers. Admitted
    /// or revoked by `WikiReaderRep` as package snapshots change.
    let rendererPackageRouter = ReaderRendererPackageRouter()

    /// The canonical package scheme handler wrapping the frame router, so
    /// CSP, MIME, no-sniff, response ordering, and cancellation stay
    /// single-sourced. Created in `init` before `super.init` so it can be
    /// registered on the configuration.
    private(set) var rendererPackageSchemeHandler: RendererPackageSchemeHandler?

    /// Test/diagnostic observation: every URL the package scheme handler was
    /// asked to start. Empty in production use; only tests read it.
    var diagnosticStartedPackageRequests: [URL] {
        rendererPackageRouter.diagnosticStartedRequests
    }

    init() {
        let config = WKWebViewConfiguration()
        let cc = WKUserContentController()
        // The content controller retains the handler; the handler weakly
        // references this view, so there's no retain cycle. The proxy is created
        // with a nil target and wired to `self` after super.init (the view
        // doesn't exist until then).
        let proxy = LinkHoverMessageHandler(target: nil)
        cc.add(proxy, name: Self.linkHoverName)
        // Plan v2 transclusion: a second message handler fires when a
        // `<details class="sdw-transclusion">` is first opened. The Coordinator
        // resolves + fetches + renders the body off-main and injects via the
        // safe `sdwInjectEmbed` setter (HTML is a parameter, never concatenated
        // — Plan v2 §4.4). The proxy is retained by the controller; weakly
        // references this view, same pattern as the hover handler.
        let embedProxy = EmbedFetchMessageHandler(target: nil)
        cc.add(embedProxy, name: Self.embedFetchName)
        let attachmentProxy = RendererAttachmentGeometryMessageHandler(target: nil)
        cc.add(attachmentProxy, name: "rendererAttachmentGeometry")
        let attachmentActionProxy = RendererAttachmentActionMessageHandler(target: nil)
        cc.add(attachmentActionProxy, name: "rendererAttachmentAction")
        cc.addUserScript(WKUserScript(
            source: Self.hoverListenerJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        cc.addUserScript(WKUserScript(
            source: Self.embedBootstrapJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        cc.addUserScript(WKUserScript(
            source: Self.rendererAttachmentGeometryJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        config.userContentController = cc
        // Register the blob scheme handler BEFORE super.init so it's available
        // for the first page load. The store is injected later by the
        // representable (same as the view's own `store` property).
        config.setURLSchemeHandler(blobHandler, forURLScheme: BlobSchemeHandler.scheme)
        // Register the reader document scheme so the custom-scheme baseURL is
        // honored: without a registered handler, WebKit silently falls back to
        // about:blank for loadHTMLString(baseURL:) (proven in hosted probes).
        config.setURLSchemeHandler(
            WikiReaderDocumentSchemeHandler.shared, forURLScheme: WikiReaderDocumentOrigin.scheme)
        // Same for renderer-package assets served to in-page expansion iframes,
        // through the canonical handler wrapping the frame router (CSP, MIME,
        // no-sniff, response ordering, and cancellation stay single-sourced).
        // The handler is created locally because `self` is not available
        // before `super.init`; it references the same router instance.
        let packageHandler = RendererPackageSchemeHandler(resourceProvider: rendererPackageRouter)
        config.setURLSchemeHandler(
            packageHandler, forURLScheme: RendererPackageScheme.name)
        super.init(frame: .zero, configuration: config)
        rendererPackageSchemeHandler = packageHandler
        proxy.target = self
        embedProxy.target = self
        attachmentProxy.target = self
        attachmentActionProxy.target = self
    }

    nonisolated static let rendererAttachmentGeometryJS = """
    (function(){
      var known={};var visible={};var margin=600;
      var observer=new IntersectionObserver(function(entries){entries.forEach(function(entry){visible[entry.target.id]=entry.isIntersecting;});window.__sdwRendererAttachmentRevision=(window.__sdwRendererAttachmentRevision||0)+1;report();},{root:null,rootMargin:margin+'px 0px '+margin+'px 0px',threshold:0});
      function role(e){return e.classList.contains('sdw-inline-renderer')?'inlineContent':'disclosureRow';}
      function nodes(){return document.querySelectorAll('.sdw-renderer-card[id],.sdw-inline-renderer[id][data-renderer-admitted="true"]');}
      function report(){var g=window.__sdwRendererAttachmentGeneration;if(typeof g!=='number')return;var current={};
        nodes().forEach(function(e){current[e.id]=true;if(!known[e.id])observer.observe(e);var expansion=e.querySelector('.sdw-renderer-card__expansion');var target=role(e)==='disclosureRow'&&e.dataset.rendererExpanded==='true'&&expansion?expansion:e;var r=target.getBoundingClientRect();var retained=visible[e.id]===true;
          window.webkit.messageHandlers.rendererAttachmentGeometry.postMessage({generation:g,placeholderID:e.id,embeddingRole:role(e),x:r.x,y:r.y,width:r.width,height:r.height,visible:retained,revision:(window.__sdwRendererAttachmentRevision||0)});});
        Object.keys(known).forEach(function(id){if(!current[id]){observer.unobserve(known[id]);delete visible[id];window.webkit.messageHandlers.rendererAttachmentGeometry.postMessage({kind:'removed',generation:g,placeholderID:id});}});known={};nodes().forEach(function(e){known[e.id]=e;});}
      window.__sdwRendererAttachmentReport=function(g){window.__sdwRendererAttachmentGeneration=g;window.__sdwRendererAttachmentRevision=(window.__sdwRendererAttachmentRevision||0)+1;report();};
      window.__sdwRendererAttachmentReserve=function(id,height){var card=document.getElementById(id);if(!card||!Number.isFinite(height))return;var target=card.classList.contains('sdw-inline-renderer')?card:card.querySelector('.sdw-renderer-card__expansion');if(!target)return;target.style.minHeight=height+'px';window.__sdwRendererAttachmentRevision=(window.__sdwRendererAttachmentRevision||0)+1;report();};
      window.__sdwRendererAttachmentState=function(id,expanded,status){var card=document.getElementById(id);if(!card)return;card.dataset.rendererExpanded=expanded?'true':'false';var disclosure=card.querySelector('.sdw-renderer-card__disclosure');if(disclosure)disclosure.setAttribute('aria-expanded',expanded?'true':'false');var expansion=card.querySelector('.sdw-renderer-card__expansion');if(expansion){expansion.hidden=!expanded;expansion.setAttribute('aria-hidden',expanded?'false':'true');}var prior=card.querySelector('.sdw-renderer-card__status');if(prior)prior.remove();if(status&&expansion){var node=document.createElement('p');node.className='sdw-renderer-card__status';node.setAttribute('role','status');node.textContent=status;expansion.appendChild(node);}window.__sdwRendererAttachmentRevision=(window.__sdwRendererAttachmentRevision||0)+1;report();};
      document.addEventListener('click',function(event){if(event.target.closest('[data-renderer-action="open-window"]'))return;var rowHeader=event.target.closest('.sdw-renderer-card__row');if(!rowHeader)return;var card=rowHeader.closest('.sdw-renderer-card[id]');if(!card)return;event.preventDefault();window.webkit.messageHandlers.rendererAttachmentAction.postMessage({action:card.dataset.rendererExpanded==='true'?'collapse':'activate',placeholderID:card.id});});
      addEventListener('scroll',report,{passive:true});addEventListener('resize',report);new MutationObserver(function(){window.__sdwRendererAttachmentRevision=(window.__sdwRendererAttachmentRevision||0)+1;report();}).observe(document.documentElement,{childList:true,subtree:true,attributes:true});
    })();
    """

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Handle sidebar drag-and-drop directly on the WKWebView. SwiftUI's
    /// `.dropDestination` overlay covers the SwiftUI chrome (header, banners) and
    /// the welcome screen, but it does NOT cover the AppKit WKWebView's own frame
    /// — so drops on the rendered markdown body never reach the SwiftUI target
    /// (#133). The WKWebView subclass is the drop target for its own body:
    /// register ONLY the sidebar-item type, and AppKit routes a sidebar drag over
    /// the body here (WebKit's internal subviews still register their own broad
    /// types for web-content drag/drop, but a sidebar payload doesn't conform to
    /// those, so they don't match and the drag bubbles up to this view).
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        super.registerForDraggedTypes([NSPasteboard.PasteboardType(UTType.wikiSidebarItem.identifier)])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sidebarPayloads(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sidebarPayloads(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let payloads = sidebarPayloads(from: sender.draggingPasteboard)
        guard !payloads.isEmpty else { return false }
        for payload in payloads {
            DebugLog.tabs("[drop] wikiReader body action fired: kind=\(payload.kind) id=\(payload.id)")
            store?.openTab(payload.selection)
        }
        return true
    }

    /// Reads every dragged pasteboard item (not just the first — a multi-row
    /// selection or a bookmark folder both put more than one item on the
    /// pasteboard) and flattens each item's resolved target list.
    private func sidebarPayloads(from pb: NSPasteboard) -> [SidebarDragPayload] {
        let type = NSPasteboard.PasteboardType(UTType.wikiSidebarItem.identifier)
        guard let items = pb.pasteboardItems else { return [] }
        return items.compactMap { item -> SidebarDragPayloadList? in
            guard let data = item.data(forType: type) else { return nil }
            return DebugLog.trying("decode drag payload", operation: { try JSONDecoder().decode(SidebarDragPayloadList.self, from: data) })
        }.flatMap(\.items)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        // Dump WebKit's menu items so we can see what identifiers / titles WKWebView
        // actually ships on this macOS version — useful diagnostic until the menu is
        // shipping reliably across macOS releases.  Logged public so Console shows it.
        let itemDescs = menu.items.map { "id=\($0.identifier?.rawValue ?? "nil") title=\"\($0.title)\"" }.joined(separator: ", ")
        DebugLog.reader("willOpenMenu \(menu.items.count) items: [\(itemDescs)]")

        // Remove WebKit built-ins that don't work for this app: opening in a new
        // window is unsupported (we use tabs), and "Download Linked File" no-ops
        // for our custom schemes. Remove them before building custom items so the
        // menu stays clean regardless of which URL type triggered it.
        let removeIDs: Set<String> = [
            "WKMenuItemIdentifierOpenLinkInNewWindow",
            "WKMenuItemIdentifierDownloadLinkedFile",
            "WKMenuItemIdentifierCopyLink",
        ]
        menu.items.removeAll { removeIDs.contains($0.identifier?.rawValue ?? "") }
        // Collapse any double separators or leading/trailing separators left
        // behind by the removal above.
        collapseMenuSeparators(menu)

        // We removed Copy Link; Open Link is the only remaining WebKit link
        // item we rely on to prove we're on a link.  Also accept a wiki://
        // hoveredLinkHref for custom-scheme links.
        let hasLinkItem = menu.items.contains {
            $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink"
        }
        let hasWikiHref = hoveredLinkHref?.hasPrefix("wiki://") ?? false

        guard let store else {
            DebugLog.reader("willOpenMenu: store is nil → bailing")
            return
        }

        // Non-link right-click: this is the *page* menu (issue #933) — Back /
        // Forward above WebKit's Reload, then Print Page… and Share… in the
        // document group below it.
        guard hasLinkItem || hasWikiHref else {
            addPageItems(to: menu, store: store, event: event)
            DebugLog.reader("willOpenMenu: no link → added page items, bailing")
            return
        }

        guard let href = hoveredLinkHref, !href.isEmpty else {
            DebugLog.reader("willOpenMenu: hoveredLinkHref is nil/empty → bailing. href=\(hoveredLinkHref ?? "nil")")
            return
        }

        guard let url = URL(string: href) else {
            DebugLog.reader("willOpenMenu: URL(string:) failed for href=\"\(href)\" → bailing")
            return
        }

        DebugLog.reader("willOpenMenu: building custom items for url=\(url.absoluteString)")

        let custom = WikiLinkMenuNSItems.items(for: url, store: store, fileProvider: fileProvider, addURL: addURLHandler, addBookmark: addBookmarkHandler)

        // Insert "Open in Background" right after WebKit's "Open Link"
        // for resolved wiki links, so it's the second item in the menu.
        if let openLinkIdx = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink" }),
           WikiLinkMarkdown.resolvedKind(from: url) != nil {
            let target = WikiLinkMarkdown.target(from: url) ?? ""
            let bgItem = NSMenuItem.wikiItem("Open in Background") {
                switch WikiLinkMarkdown.resolvedKind(from: url) {
                case .page:
                    if let id = store.pageID(forTitle: target) { store.openTabInBackground(.page(id)) }
                case .source:
                    if let id = store.sourceID(forDisplayName: target) { store.openTabInBackground(.source(id)) }
                case .chat:
                    if let id = store.chatID(forTitle: target) { store.openTabInBackground(.chat(id)) }
                case nil: break
                }
            }
            bgItem.image = NSImage(systemSymbolName: "dock.arrow.down.rectangle",
                                   accessibilityDescription: "Open in Background")
            menu.insertItem(bgItem, at: openLinkIdx + 1)
            menu.insertItem(NSMenuItem.separator(), at: openLinkIdx + 2)
        }

        // Prepend remaining custom items (addAsSource, openInBrowser,
        // suggest for missing links) at the top.
        if !custom.isEmpty {
            DebugLog.reader("willOpenMenu: prepending \(custom.count) custom items")
            menu.insertItem(NSMenuItem.separator(), at: 0)
            for item in custom.reversed() { menu.insertItem(item, at: 0) }
        }

        // Find the insertion point for Share + bottom items: right after
        // "Open in Background" if present, otherwise after "Open Link".
        let bgIdx = menu.items.firstIndex(where: { $0.title == "Open in Background" })
        let openLinkIdx = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink" })
        let insertIdx = bgIdx.map { $0 + 1 } ?? openLinkIdx.map { $0 + 1 } ?? menu.items.count

        // Remove WebKit's Share (we replace it with our own) if present.
        let shareID = "WKMenuItemIdentifierShareMenu"
        if let webKitShareIdx = menu.items.firstIndex(where: { $0.identifier?.rawValue == shareID }) {
            menu.removeItem(at: webKitShareIdx)
        }

        // Build Share + bottom items for wiki links.
        if url.scheme == WikiLinkMarkdown.scheme, let fp = fileProvider {
            let shareWebView = self
            let viewPoint = convert(event.locationInWindow, from: nil)

            let shareURLTask: Task<URL?, Never>?
            switch WikiLinkMarkdown.resolvedKind(from: url) {
            case .page?:
                let target = WikiLinkMarkdown.target(from: url) ?? ""
                if let id = store.pageID(forTitle: target) {
                    shareURLTask = Task { await fp.resolvePageByTitleURL(id: id) }
                } else { shareURLTask = nil }
            case .source?:
                let target = WikiLinkMarkdown.target(from: url) ?? ""
                if let id = store.sourceID(forDisplayName: target) {
                    shareURLTask = Task { await fp.resolveSourceByNameURL(id: id) }
                } else { shareURLTask = nil }
            case .chat?:
                // Chat sharing via File Provider URL is not yet wired — no-op.
                shareURLTask = nil
            case nil:
                shareURLTask = nil
            }

            let customShare = NSMenuItem.wikiItem("Share…") {
                Task { @MainActor in
                    guard let fileURL = await shareURLTask?.value as? URL else { return }
                    let picker = NSSharingServicePicker(items: [fileURL])
                    let rect = NSRect(x: viewPoint.x, y: viewPoint.y, width: 1, height: 1)
                    picker.show(relativeTo: rect, of: shareWebView, preferredEdge: .minY)
                }
            }
            customShare.image = NSImage(systemSymbolName: "square.and.arrow.up",
                                        accessibilityDescription: "Share")

            let bottomActions = WikiLinkMenuBuilder.bottomActions(for: url)
            let bottomItems = WikiLinkMenuNSItems.items(
                for: url, actions: bottomActions, store: store, fileProvider: fileProvider,
                addURL: addURLHandler, addBookmark: addBookmarkHandler)

            // Insert at insertIdx in reverse so they appear in order.
            for item in bottomItems.reversed() { menu.insertItem(item, at: insertIdx) }
            if !bottomItems.isEmpty { menu.insertItem(NSMenuItem.separator(), at: insertIdx) }
            menu.insertItem(customShare, at: insertIdx)
            collapseMenuSeparators(menu)
        } else {
            // External link: Share the URL directly.
            let shareWebView = self
            let extViewPoint = convert(event.locationInWindow, from: nil)
            let customShare = NSMenuItem.wikiItem("Share…") {
                let picker = NSSharingServicePicker(items: [url])
                let rect = NSRect(x: extViewPoint.x, y: extViewPoint.y, width: 1, height: 1)
                picker.show(relativeTo: rect, of: shareWebView, preferredEdge: .minY)
            }
            customShare.image = NSImage(systemSymbolName: "square.and.arrow.up",
                                        accessibilityDescription: "Share")
            menu.insertItem(customShare, at: insertIdx)
            collapseMenuSeparators(menu)
        }
    }

    // MARK: - Menu cleanup helpers

    /// Remove leading, trailing, and consecutive separators from `menu` so that
    /// removing individual items never leaves an orphaned divider.
    private func collapseMenuSeparators(_ menu: NSMenu) {
        var lastWasSeparator = true // treat start-of-menu as "after separator"
        var i = 0
        while i < menu.items.count {
            let item = menu.items[i]
            if item.isSeparatorItem {
                if lastWasSeparator {
                    menu.removeItem(at: i)
                    continue
                }
                lastWasSeparator = true
            } else {
                lastWasSeparator = false
            }
            i += 1
        }
        // Remove trailing separator if any.
        if menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
    }

    /// Build the page (non-link) context menu: the ``PageContextMenuNSItems``
    /// group — Back / Forward at the top and Print Page… below WebKit's Reload —
    /// plus the inline Share item, which joins Print in the document group.
    ///
    /// Everything here is synchronous, because AppKit assembles a context menu in
    /// one turn: Back / Forward read the store's history stacks directly, Print
    /// hands the closure straight to ``printRenderedPage``, and Share kicks off
    /// its File Provider resolution as a detached task whose result is only
    /// needed if the user actually chooses it.
    ///
    /// `store` is *this* reader's store — set by `WikiReaderRep` from the window's
    /// session — so with several windows open each menu navigates and prints its
    /// own wiki.
    func addPageItems(to menu: NSMenu, store: WikiStoreModel, event: NSEvent) {
        let inserted = PageContextMenuNSItems.insert(into: menu, store: store) { [weak self] in
            guard let self else { return }
            self.printRenderedPage(self)
        }
        // Share sits with Print in the document group. Anchor off the Print item
        // itself rather than recomputing a WebKit index, so the two can't drift.
        let afterPrint = inserted.last.map { menu.index(of: $0) + 1 } ?? menu.items.count
        if let selection = currentSelection,
           let share = inlineShareItem(for: selection, event: event) {
            menu.insertItem(share, at: afterPrint)
            menu.insertItem(.separator(), at: afterPrint + 1)
        } else {
            menu.insertItem(.separator(), at: afterPrint)
        }
        collapseMenuSeparators(menu)
    }

    /// A Share item for the document being read. Resolves the canonical URL from
    /// the daemon so the share sheet gets a human-readable filename. `nil` for
    /// selections with no shareable File Provider URL (chats, the system prompt),
    /// which is how the item omits itself rather than sharing nothing.
    private func inlineShareItem(for selection: WikiSelection, event: NSEvent) -> NSMenuItem? {
        let shareWebView = self
        let viewPoint = convert(event.locationInWindow, from: nil)

        let shareTask: Task<URL?, Never>
        switch selection {
        case .page(let id):
            shareTask = Task { [weak fileProvider] in
                await fileProvider?.resolvePageByTitleURL(id: id)
            }
        case .source(let id):
            shareTask = Task { [weak fileProvider] in
                await fileProvider?.resolveSourceByNameURL(id: id)
            }
        default:
            return nil
        }

        let item = NSMenuItem.wikiItem("Share…") {
            Task { @MainActor in
                guard let fileURL = await shareTask.value else { return }
                let picker = NSSharingServicePicker(items: [fileURL])
                let rect = NSRect(x: viewPoint.x, y: viewPoint.y, width: 1, height: 1)
                picker.show(relativeTo: rect, of: shareWebView, preferredEdge: .minY)
            }
        }
        item.image = NSImage(systemSymbolName: "square.and.arrow.up",
                             accessibilityDescription: "Share")
        return item
    }

    // MARK: - Pure, testable hit-test helpers

    /// Flip an AppKit (bottom-left origin) view point to the CSS (top-left
    /// origin) viewport coordinates `document.elementFromPoint` expects, clamped
    /// to the bounds. Pure — unit-tested.
    nonisolated static func cssHitTestPoint(_ point: NSPoint, in bounds: CGRect) -> (x: CGFloat, y: CGFloat) {
        let x = min(max(0, point.x), bounds.width)
        let y = min(max(0, bounds.height - point.y), bounds.height)
        return (x, y)
    }

    /// JS that returns the `href` of the anchor under `(x, y)`, or `""` if there
    /// is none / it isn't http(s). Coordinates are embedded as POSIX-formatted
    /// numbers (no locale-dependent separators). Pure — unit-tested.
    nonisolated static func linkHrefAtJS(x: CGFloat, y: CGFloat) -> String {
        """
        (function(x,y){
          var el=document.elementFromPoint(x,y);
          while(el && el.tagName!=="A"){ el=el.parentElement; }
          if(!el){ return ""; }
          return (el.protocol==="http:"||el.protocol==="https:") ? el.href : "";
        })(\(posix(x)),\(posix(y)))
        """
    }

    /// Format a coordinate with a POSIX decimal point so it's valid JS anywhere.
    nonisolated private static func posix(_ v: CGFloat) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(v))
    }

    // MARK: - Hover tracking (injected script + message handler)

    nonisolated static let linkHoverName = "linkHover"

    /// Tracks the `<a>` href under the cursor by listening for `mouseover` on the
    /// document (capture phase) AND per-link `mouseenter`/`mouseleave`.  Both paths
    /// post to the same `linkHover` message handler.  A `lastHref` guard suppresses
    /// duplicate posts so we don't flood WebKit's IPC queue (which can throttle or
    /// drop messages when the mouse moves rapidly over dense inline content).
    ///
    /// `mouseenter` fires only when the pointer enters an `<a>` element (far fewer
    /// events than `mouseover`), so it acts as a reliable fallback even when the
    /// capture-phase path is noisy.
    nonisolated static let hoverListenerJS = """
    (function(){
      var lastHref="";
      function post(href){
        if(href!==lastHref){
          lastHref=href;
          try{window.webkit.messageHandlers.\(linkHoverName).postMessage(href);}catch(e){}
        }
      }
      // capture-phase mouseover — catches every element entered
      document.addEventListener('mouseover',function(e){
        var el=e.target;
        while(el&&el.tagName!=="A"){el=el.parentElement;}
        post(el&&el.tagName==="A"?el.href:"");
      },true);
      // per-link mouseenter/leave — reliable for links, tiny event count
      function bindLinks(){
        var links=document.querySelectorAll("a:not([data-sdw-hover])");
        for(var i=0;i<links.length;i++){(function(a){
          a.setAttribute("data-sdw-hover","1");
          a.addEventListener("mouseenter",function(){post(a.href);});
          a.addEventListener("mouseleave",function(){post("");});
        })(links[i]);}
      }
      // bind once the DOM is settled; re-bind on DOM mutation as a safety net
      bindLinks();
      new MutationObserver(bindLinks).observe(document.body||document.documentElement,{childList:true,subtree:true});
    })();
    """

    // MARK: - Plan v2 transclusion (injected script + message handler)

    nonisolated static let embedFetchName = "embedFetch"

    /// Bootstrap that defines `sdwInjectEmbed` (the safe HTML-injection setter
    /// — Plan v2 §4.4) and binds a one-shot `toggle` listener to every
    /// `<details class="sdw-transclusion">`. On first open it reads the
    /// element's `data-sdw-*` attributes and posts them to the Swift
    /// `embedFetch` handler; the Coordinator fetches + renders the body off-main
    /// and calls `sdwInjectEmbed` back with the HTML as a **parameter** (never
    /// concatenated into JS source — `jsString` escapes it into a JS double-
    /// quoted literal). After injection it stamps `data-sdw-state="loaded"` and
    /// propagates the ancestor path to any nested `<details>` the body contains
    /// (parent path + parent id) so the cycle check fires on re-expand
    /// (`TransclusionEmbedder.isCycle`, Plan v2 §8).
    nonisolated static let embedBootstrapJS = """
    (function(){
      // Safe HTML setter: param-based injection (no string-concat of html).
      // Defined on `window` so the Coordinator's evaluateJavaScript can call it
      // by name with the (nodeId, html) tuple escaped through jsString.
      window.sdwInjectEmbed = function(embedId, html){
        var sel = '[\(WikiLinkMarkdown.TransclusionAttr.node)="' + embedId + '"]';
        var host = document.querySelector(sel);
        if(!host){ return; }
        var body = host.querySelector('.sdw-embed-body');
        if(!body){ return; }
        body.innerHTML = html;
        body.setAttribute('\(WikiLinkMarkdown.TransclusionAttr.state)', 'loaded');
        host.setAttribute('\(WikiLinkMarkdown.TransclusionAttr.state)', 'loaded');
        // Propagate the ancestor path: parent path + this embed's id, so a
        // nested `<details>` opened next carries the chain (cycle check).
        var parentId = host.getAttribute('\(WikiLinkMarkdown.TransclusionAttr.id)') || '';
        var parentKind = host.getAttribute('\(WikiLinkMarkdown.TransclusionAttr.kind)') || '';
        var parentToken = parentId && parentKind ? parentKind + ':' + parentId : '';
        var parentPath = host.getAttribute('\(WikiLinkMarkdown.TransclusionAttr.path)') || '';
        var childPath = parentToken ? (parentPath ? parentPath + ' ' + parentToken : parentToken) : parentPath;
        var nested = host.querySelectorAll('details.\(WikiLinkMarkdown.TransclusionAttr.className)');
        for(var i=0;i<nested.length;i++){
          nested[i].setAttribute('\(WikiLinkMarkdown.TransclusionAttr.path)', childPath);
        }
      };
      // DOM-embed injection for renderer frames/media (DOM era): builds the
      // element with DOM APIs from parameters, never from concatenated HTML.
      // The native side passes only validated values (frame-scoped URL,
      // accessible title, bounded height); no input bytes or capabilities
      // cross this boundary. `sandboxAttrs` is a JSON array of strings.
      // Load/error observers: the native side polls this map after injection
      // to confirm the frame actually loaded (embed load diagnostics).
      window.__sdwRendererEmbedLoads = window.__sdwRendererEmbedLoads || {};
      window.sdwInjectRendererEmbed = function(placeholderID, expansionID, kind, src, title, height, sandboxJSON){
        var card = document.getElementById(placeholderID);
        if(!card){ return 'no-card'; }
        var expansion = card.querySelector('.sdw-renderer-card__expansion');
        if(!expansion){ return 'no-expansion'; }
        // Remove only this placeholder's prior surface (scoped collapse).
        var prior = expansion.querySelector('.sdw-renderer-embed');
        if(prior){ prior.remove(); }
        var element;
        if(kind === 'audio'){
          element = document.createElement('audio');
          element.controls = true;
          element.preload = 'metadata';
        } else if(kind === 'video'){
          element = document.createElement('video');
          element.controls = true;
          element.preload = 'metadata';
        } else {
          element = document.createElement('iframe');
          if(sandboxJSON){
            try {
              var flags = JSON.parse(sandboxJSON);
              if(flags.length > 0){ element.setAttribute('sandbox', flags.join(' ')); }
            } catch (_) { return 'bad-sandbox'; }
          }
          if(height > 0){
            element.style.height = height + 'px';
            element.style.width = '100%';
          }
          element.loading = 'lazy';
        }
        element.addEventListener('load', function(){
          window.__sdwRendererEmbedLoads[placeholderID] = 'loaded:' + (element.contentWindow && element.contentWindow.location ? element.contentWindow.location.href : 'no-window');
        });
        element.addEventListener('error', function(){
          window.__sdwRendererEmbedLoads[placeholderID] = 'error-event';
        });
        element.src = src;
        element.title = title;
        element.className = 'sdw-renderer-embed';
        element.id = expansionID + '-embed';
        element.setAttribute('aria-label', title);
        expansion.appendChild(element);
        window.__sdwRendererEmbedLoads[placeholderID] = 'appended';
        return 'injected';
      };

      // Scoped removal: only this placeholder's embed surface.
      window.sdwRemoveRendererEmbed = function(placeholderID){
        var card = document.getElementById(placeholderID);
        if(!card){ return 'no-card'; }
        var expansion = card.querySelector('.sdw-renderer-card__expansion');
        if(!expansion){ return 'no-expansion'; }
        var prior = expansion.querySelector('.sdw-renderer-embed');
        if(prior){ prior.remove(); return 'removed'; }
        return 'none';
      };

      function postEmbed(details){
        var nodeId = details.getAttribute('\(WikiLinkMarkdown.TransclusionAttr.node)') || '';
        var state  = details.getAttribute('\(WikiLinkMarkdown.TransclusionAttr.state)') || '';
        if(!nodeId){ return; }
        // Only first-open fires a fetch (state == 'empty'); later toggles are
        // pure show/hide. Cycle/missing/loaded states are inert here.
        if(state !== 'empty'){ return; }
        var kind   = details.getAttribute('\(WikiLinkMarkdown.TransclusionAttr.kind)') || '';
        var id     = details.getAttribute('\(WikiLinkMarkdown.TransclusionAttr.id)') || '';
        var target = details.getAttribute('\(WikiLinkMarkdown.TransclusionAttr.target)') || '';
        var path   = details.getAttribute('\(WikiLinkMarkdown.TransclusionAttr.path)') || '';
        var name   = details.getAttribute('\(WikiLinkMarkdown.TransclusionAttr.name)') || '';
        try{
          window.webkit.messageHandlers.\(embedFetchName).postMessage({
            nodeId: nodeId, kind: kind, id: id, target: target, path: path, name: name
          });
        }catch(e){}
      }
      function bindEmbeds(){
        var nodes = document.querySelectorAll('details.\(WikiLinkMarkdown.TransclusionAttr.className):not([data-sdw-embed-bound])');
        for(var i=0;i<nodes.length;i++){(function(d){
          d.setAttribute('data-sdw-embed-bound','1');
          d.addEventListener('toggle', function(){
            if(d.open){ postEmbed(d); }
          });
        })(nodes[i]);}
      }
      bindEmbeds();
      new MutationObserver(bindEmbeds).observe(document.body||document.documentElement,{childList:true,subtree:true});
    })();
    """
}

/// Forwards the `mouseover`-posted href to the owning web view. Retained by the
/// `WKUserContentController`; holds a weak reference to the view so there's no
/// cycle.
@MainActor
private final class LinkHoverMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WikiReaderWebView?
    init(target: WikiReaderWebView?) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.hoveredLinkHref = message.body as? String
    }
}

/// Forwards the `embedFetch`-posted payload (`{nodeId, kind, id, target, path,
/// name}`) from a first-opened `<details class="sdw-transclusion">` to the
/// owning web view's Coordinator, which resolves + fetches + renders the body
/// off-main and injects via `sdwInjectEmbed` (Plan v2 §4.3). Retained by the
/// `WKUserContentController`; weakly references the view so there's no cycle.
///
/// `internal` (not `private`) so ``coerceBody(_:)`` is exercisable from
/// `TransclusionEmbedTests` — the bridge cast that shipped #725 was untested
/// because the handler was unreachable from the test module.
@MainActor
internal final class EmbedFetchMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WikiReaderWebView?
    init(target: WikiReaderWebView?) { self.target = target }

    /// Coerces the JS-bridge payload into the `[String: String]` shape
    /// ``WikiReaderRep.Coordinator/handleEmbedFetch(body:)`` expects.
    ///
    /// WKWebView bridges a JS object literal (`postMessage({ … })`) to an
    /// `NSDictionary` whose values are boxed as `Any` (e.g. `NSString`), **not**
    /// `String`. A direct `message.body as? [String: String]` cast therefore
    /// ALWAYS fails and silently drops the message → embed stuck on "Loading…"
    /// (#725). Cast to `[String: Any]` first, then extract each value as
    /// `String`, defaulting to `""` to match `processEmbedFetch`'s `?? ""`
    /// reads. Returns `nil` only when the body isn't a dictionary at all (the
    /// "unparseable" log path).
    ///
    /// Keys verified against `processEmbedFetch(body:)` and the JS `postMessage`
    /// payload: `nodeId`, `kind`, `id`, `target`, `path`, `name`.
    static func coerceBody(_ raw: Any) -> [String: String]? {
        guard let dict = raw as? [String: Any] else { return nil }
        return ["nodeId", "kind", "id", "target", "path", "name"]
            .reduce(into: [String: String]()) { result, key in
                result[key] = (dict[key] as? String) ?? ""
            }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let view = target else { return }
        guard let body = Self.coerceBody(message.body) else {
            DebugLog.reader("embedFetch dropped: unparseable body")
            return
        }
        view.coordinator?.handleEmbedFetch(body: body)
    }
}

@MainActor
private final class RendererAttachmentGeometryMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WikiReaderWebView?
    init(target: WikiReaderWebView?) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "rendererAttachmentGeometry", let body = message.body as? [String: Any] else { return }
        if body["kind"] as? String == "removed", let generation = body["generation"] as? Int,
           let rawID = body["placeholderID"] as? String,
           let id = RendererAttachmentPlaceholderID.validatedOrNil(rawID) {
            target?.coordinator?.handleAttachmentRemoval(id, generation: generation); return
        }
        guard let geometry = RendererAttachmentGeometryMessage(body: body) else { return }
        target?.coordinator?.handleAttachmentGeometry(geometry)
    }
}

@MainActor
private final class RendererAttachmentActionMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WikiReaderWebView?
    init(target: WikiReaderWebView?) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String,
              let rawID = body["placeholderID"] as? String,
              let placeholderID = RendererAttachmentPlaceholderID.validatedOrNil(rawID)
        else { return }
        switch action {
        case "activate": _ = target?.coordinator?.activateAttachment(placeholderID)
        case "collapse": target?.coordinator?.collapseAttachment(placeholderID)
        default: break
        }
    }
}

internal struct WikiReaderRep: NSViewRepresentable {
    let markdown: String
    let store: WikiStoreModel
    let fileProvider: FileProviderFacade?
    let readerZoom: Double
    /// The selection this reader renders — used to match a pending scroll anchor.
    let currentSelection: WikiSelection?
    let documentIdentity: MarkdownDocumentIdentity?
    /// Mirrors `store.pendingScrollAnchorVersion`; passed in so a bump causes an
    /// `updateNSView` (the Coordinator consumes + applies it once the page loads).
    let anchorVersion: Int
    @Binding var isLoading: Bool
    let addURLHandler: (@MainActor @Sendable (String) -> Void)?
    let addBookmarkHandler: (@MainActor @Sendable (BookmarkTargetPickerContext) -> Void)?
    let onRendererActivation: (@MainActor (RendererReference, RendererBridgeInput) -> Void)?
    let inlineAttachmentResolver: RendererInlineAttachmentResolver
    let inlineRendererDescriptors: [RendererDescriptor]
    let rendererPackageInputs: RendererPackageEmbedInputs?
    let findText: String?
    let findVersion: Int
    let findOccurrence: Int

    func makeNSView(context: Context) -> WikiReaderContainerView {
        let webView = WikiReaderWebView()
        let container = WikiReaderContainerView(webView: webView)
        webView.pageZoom = readerZoom
        webView.store = store
        webView.blobHandler.store = store
        webView.fileProvider = fileProvider
        webView.currentSelection = currentSelection
        webView.addURLHandler = addURLHandler
        webView.addBookmarkHandler = addBookmarkHandler
        webView.onRendererActivation = onRendererActivation
        Self.installRendererPackages(rendererPackageInputs, into: webView)
        context.coordinator.inlineAttachmentResolver = inlineAttachmentResolver
        context.coordinator.inlineRendererDescriptors = inlineRendererDescriptors
        context.coordinator.rendererPackageInputs = rendererPackageInputs
        webView.navigationDelegate = context.coordinator
        webView.coordinator = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.attachmentContainer = container
        context.coordinator.store = store
        context.coordinator.currentSelection = currentSelection
        context.coordinator.startLoad(
            markdown: markdown,
            documentIdentity: documentIdentity,
            isLoading: $isLoading)
        return container
    }

    func updateNSView(_ container: WikiReaderContainerView, context: Context) {
        let webView = container.webView
        context.coordinator.applyReaderZoom(readerZoom, to: webView, container: container)
        webView.store = store
        webView.blobHandler.store = store
        webView.fileProvider = fileProvider
        webView.currentSelection = currentSelection
        webView.addURLHandler = addURLHandler
        webView.addBookmarkHandler = addBookmarkHandler
        webView.onRendererActivation = onRendererActivation
        Self.installRendererPackages(rendererPackageInputs, into: webView)
        context.coordinator.inlineAttachmentResolver = inlineAttachmentResolver
        context.coordinator.inlineRendererDescriptors = inlineRendererDescriptors
        context.coordinator.rendererPackageInputs = rendererPackageInputs
        context.coordinator.store = store
        context.coordinator.currentSelection = currentSelection
        if context.coordinator.loadedMarkdown != markdown ||
            context.coordinator.loadedDocumentIdentity != documentIdentity {
            context.coordinator.startLoad(
                markdown: markdown,
                documentIdentity: documentIdentity,
                isLoading: $isLoading)
        }
        // Consume + apply any pending scroll anchor (handles re-clicks on an
        // already-loaded doc; a fresh load is handled in `didFinish`). Reads the
        // store's version directly so it's robust to the view being re-created
        // mid-navigation (the store outlives the view's @State).
        context.coordinator.consumeAndApplyPendingAnchor(in: webView)
        // Find: apply to the loaded page.
        if context.coordinator.appliedFindVersion != findVersion {
            context.coordinator.appliedFindVersion = findVersion
            if let text = findText, !text.isEmpty {
                context.coordinator.applyFind(text, occurrence: findOccurrence, in: webView)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Replaces the frame router's routes with the host's current validated
    /// package snapshot. Each admitted renderer reference gets a fresh,
    /// unguessable frame-origin token; replacing the snapshot revokes every
    /// prior route (a stale frame's requests then fail closed).
    @MainActor
    private static func installRendererPackages(
        _ inputs: RendererPackageEmbedInputs?,
        into webView: WikiReaderWebView
    ) {
        let router = webView.rendererPackageRouter
        router.revokeAll()
        webView.rendererPackageFrameTokens.removeAll()
        webView.rendererPackageFrameEntryPaths.removeAll()
        for entry in inputs?.entries ?? [] {
            // Package assets are hash-pinned and declared in the manifest, so
            // any declared path may be requested under the frame origin; the
            // entry document is what the iframe initially loads.
            guard let entryPath = RendererRelativePath(rawValue: entry.entryPath) else { continue }
            let token = RendererFrameOriginToken.generate()
            let reservation = RendererPackageReservation(
                packageID: entry.reference.packageID,
                version: entry.reference.version)
            webView.rendererPackageFrameTokens[entry.reference] = token
            webView.rendererPackageFrameEntryPaths[entry.reference] = entry.entryPath
            _ = router.admit(
                token: token,
                reservation: reservation,
                entryPath: entryPath,
                provider: entry.provider)
        }
    }

    static func dismantleNSView(_ container: WikiReaderContainerView, coordinator: Coordinator) {
        coordinator.teardown()
        container.teardown()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WikiReaderWebView?
        weak var attachmentContainer: WikiReaderContainerView?
        private var attachmentCoordinator: RendererAttachmentCoordinator?
        /// Frame-scoped bridge registry for admitted package iframes (DOM era).
        /// Admitted on expansion; closed on collapse, removal, reload, and
        /// dismantle.
        var frameBridgeRegistry: ReaderRendererFrameBridgeRegistry = ReaderRendererFrameBridgeRegistry()
        var inlineAttachmentResolver: RendererInlineAttachmentResolver = RendererInlineAttachmentResolverFactory.defaultResolver
        var inlineRendererDescriptors: [RendererDescriptor] = []
        var rendererPackageInputs: RendererPackageEmbedInputs? = nil
        var store: WikiStoreModel?
        var currentSelection: WikiSelection?
        var loadedMarkdown: String?
        var loadedDocumentIdentity: MarkdownDocumentIdentity?
        var pageLoaded = false
        /// The last `store.pendingScrollAnchorVersion` this coordinator applied.
        /// Drives `consumeAndApplyPendingAnchor` off the STORE's version (which
        /// outlives view re-creation) rather than the view's @State.
        var appliedAnchorVersion = 0
        var appliedFindVersion = 0
        private var convertTask: Task<Void, Never>?
        private var transclusionTasks: [UUID: Task<Void, Never>] = [:]
        private var inlineRetentionTasks: [RendererAttachmentPlaceholderID: Task<Void, Never>] = [:]
        private var loadStart: DispatchTime?
        private var loadGeneration = 0
        private var transclusionGeneration = 0
        private var appliedReaderZoom: CGFloat?
        private var isDismantled = false
        /// Timestamp captured right before `loadHTMLString`, to split
        /// `appear-to-painted` into the async hop (startLoad→loadHTMLString) vs.
        /// the pure WKWebView parse/layout (loadHTMLString→didFinish).
        private var htmlLoadStart: DispatchTime?
        private var isLoadingBinding: Binding<Bool>?
        private var renderOptions: MarkdownRenderOptions?

        func startLoad(
            markdown: String,
            documentIdentity: MarkdownDocumentIdentity?,
            isLoading: Binding<Bool>
        ) {
            convertTask?.cancel()  // drop any in-flight conversion for stale markdown
            cancelTransclusionTasks()
            cancelInlineRetentionTasks()
            loadGeneration += 1
            transclusionGeneration += 1
            let generation = loadGeneration
            attachmentCoordinator?.closeAll()
            frameBridgeRegistry.closeAll()
            attachmentCoordinator = RendererAttachmentCoordinator(generation: generation)
            loadedMarkdown = markdown
            loadedDocumentIdentity = documentIdentity
            pageLoaded = false
            isLoadingBinding = isLoading
            // Never write this binding synchronously: `startLoad` is called from
            // `makeNSView` / `updateNSView`, i.e. from inside SwiftUI's update
            // pass, and a direct write there is "Modifying state during view
            // update". Skip entirely when already loading (the common case on
            // first mount, where `isLoading` starts `true`) and otherwise hop to
            // the next main-actor turn. Mirrors
            // `ComposerTextView.Coordinator.recomputeHeight` (#436).
            if !isLoading.wrappedValue {
                Task { @MainActor in isLoading.wrappedValue = true }
            }
            loadStart = DispatchTime.now()
            // Measure the synchronous click→startLoad window: openTab →
            // loadDrafts (getPage + stripped) → SwiftUI re-render → this
            // updateNSView→startLoad dispatch. This is the gap NOT covered by
            // "webview.convert" / "webview.appear-to-painted".
            if let click = store?.clickStartedAt {
                ReaderTiming.point("click.to-startLoad", ms: Self.elapsedMs(since: click))
            }

            // Phase A.1: the full render precompute (existence/display/loose
            // sets, embedMap incl. external EmbedTargets, sourceDerivedChain,
            // siblingMaps) now lives in `WikiRenderContext` — built once on the
            // main actor and memoized on the store (`store.renderContext()`),
            // invalidated by WikiEventBus-driven reloads. The detached convert
            // task consumes the context's pure closures — no store access
            // off-main, the same compute-once/capture-pure-data discipline as
            // before, just lifted to a shared seam (so chat transcripts can
            // render through it too in Phase A.2).
            let context: WikiRenderContext? = store.map { $0.renderContext() }
            // Sources use their exact sibling map. Pages resolve only authored
            // File Provider by-ID, by-name, and bookmark paths to typed sources.
            let renderedSourceMap = Self.markdownImageSourceMap(
                markdown: markdown,
                currentSelection: currentSelection,
                context: context,
                sources: store?.sources ?? [],
                bookmarkNodes: store?.bookmarkNodes ?? [])
            let contentKind: ReaderMarkdown.ContentKind = if case .source = currentSelection {
                .source
            } else {
                .document
            }
            let rendererActivationAdmission: RendererEmbedActivationAdmission? = {
                guard webView?.onRendererActivation != nil,
                      let documentIdentity
                else { return nil }
                return RendererEmbedActivationAdmission(
                    pageID: documentIdentity.pageID,
                    pageVersionID: documentIdentity.pageVersionID,
                    capability: RendererSessionCapability(rawValue: UUID().uuidString),
                    generation: generation)
            }()
            let sourceRendererCandidates = Self.sourceRendererCandidates(
                markdown: markdown,
                context: context,
                store: store?.internalStore,
                installedDescriptors: inlineRendererDescriptors)
            let markdownImageTargets = Self.markdownImageTargets(
                siblingSourceMap: renderedSourceMap,
                store: store?.internalStore,
                sourceExtensions: context?.sourceIDToExtension ?? [:],
                installedDescriptors: inlineRendererDescriptors)
            let documentRenderOptions = MarkdownRenderOptions(
                codeHighlighting: .enabled(HighlightedCodeBlockBudget()),
                rendererEmbedProjection: context?.rendererEmbedProjection,
                documentIdentity: documentIdentity,
                rendererActivationAdmission: rendererActivationAdmission)
            self.renderOptions = documentRenderOptions
            webView?.rendererActivationAdmission = rendererActivationAdmission

            let loadStartVal = loadStart
            convertTask = Task.detached(priority: .userInitiated) { [weak self] in
                let t0 = DispatchTime.now()
                // How long did Task.detached take to start after startLoad?
                if let ls = loadStartVal {
                    ReaderTiming.point("webview.task-start", ms: Self.elapsedMs(since: ls))
                }
                guard Task.isCancelled == false else { return }
                // Shared pre-pass (footnotes + wiki links) + swift-markdown HTML
                // render, both off the main actor. The context's closures resolve
                // against the precomputed existence sets so missing links style as
                // ghosts; embedInfo resolves `![[source:…]]` embeds to
                // (id, mimeType) for inline HTML rendering. When `context` is nil
                // (no store — unreachable in practice: the coordinator's store is
                // set in updateNSView before startLoad runs), fall back to EMPTY
                // resolution: all links ghost, no embeds — matching the
                // pre-refactor `store == nil` behavior (empty existence sets, NOT
                // constant-true). The transcript's nil-context=constant-true
                // contract (Phase A.2) is a separate concern, handled at the
                // ChatWebView layer, not here.
                let prepared = ReaderMarkdown.preparedDocument(
                    markdown,
                    contentKind: contentKind,
                    documentIdentity: documentIdentity)
                let projection = context?.documentEmbedResolver(
                    sourceRendererCandidates: sourceRendererCandidates,
                    markdownImageTargets: markdownImageTargets).projection(for: prepared)
                    ?? ResolvedDocumentProjection(markdownImages: markdownImageTargets)
                guard Task.isCancelled == false else { return }
                let body = MarkdownHTMLRenderer.render(
                    prepared,
                    projection: projection,
                    options: documentRenderOptions)
                guard Task.isCancelled == false else { return }
                let html = WikiReaderView.documentHTML(body)
                let convertMs = Self.elapsedMs(since: t0)
                let convertDone = DispatchTime.now()
                await MainActor.run { [weak self] in
                    guard let self, let webView = self.webView,
                          self.loadedMarkdown == markdown,
                          self.loadGeneration == generation,
                          self.isDismantled == false,
                          Task.isCancelled == false else { return }
                    // How long did MainActor.run wait to get back on the main
                    // actor? Large value ⇒ main thread is busy (SwiftUI layout).
                    ReaderTiming.point("webview.main-hop", ms: Self.elapsedMs(since: convertDone))
                    ReaderTiming.point("webview.convert", ms: convertMs)
                    self.htmlLoadStart = DispatchTime.now()
                    // Load under the dedicated custom-scheme reader origin so
                    // the parent document can frame custom-scheme children
                    // (`renderer-package:` iframes, `wiki-blob:` PDF/HTML
                    // frames). WebKit's custom-scheme CORS enforcement blocks
                    // framed custom-scheme loads from an https parent (proven
                    // in Phase 1 hosted probes), which is why the retired
                    // synthetic https origin no longer works. All in-document
                    // links/images use absolute schemes (wiki://,
                    // wiki-blob://, http[s]://), so base-relative resolution
                    // is unaffected. Provider-hosted media is never embedded
                    // inline, so no external player validates this origin
                    // (operator decision of 2026-09-03; see
                    // `WikiReaderDocumentOrigin`).
                    webView.loadHTMLString(html, baseURL: WikiReaderDocumentOrigin.url)
                }
            }
        }

        static func sourceRendererCandidates(
            markdown: String,
            context: WikiRenderContext?,
            store: WikiStore?,
            installedDescriptors: [RendererDescriptor]
        ) -> [SourceID: RendererEmbedPlan] {
            guard let context, let store,
                  let registry = rendererRegistry(installedDescriptors: installedDescriptors)
            else { return [:] }
            let inlineReferences = inlineCapableReferences(installedDescriptors: installedDescriptors)
            let sourceIDs = sourceRendererCandidateIDs(
                markdown: markdown,
                context: context,
                registry: registry,
                inlineCapableReferences: inlineReferences)
            guard sourceIDs.isEmpty == false else { return [:] }

            var sources: [SourceID: RendererEmbeddedContent.Source] = [:]
            for sourceID in sourceIDs {
                do {
                    guard let version = try store.activeContentVersion(sourceID: sourceID),
                          let source = try pinnedImageSource(
                              sourceID: sourceID,
                              version: version,
                              fileExtension: context.sourceIDToExtension[sourceID],
                              inputByteCount: { input in try store.rendererInputByteCount(input) },
                              readBytes: { versionID in try store.sourceContent(versionID: versionID) })
                    else { continue }
                    sources[sourceID] = source
                } catch {
                    DebugLog.reader("Source renderer projection could not pin an embedded source; keeping transclusion fallback.")
                }
            }
            do {
                return try DocumentSourceRendererProjection.build(
                    sources: sources,
                    displayNames: context.sourceIDToName,
                    registry: registry,
                    inlineCapableReferences: inlineReferences)
            } catch {
                DebugLog.reader("Source renderer projection could not validate embedded source facts; keeping transclusion fallback.")
                return [:]
            }
        }

        static func sourceRendererCandidateIDs(
            markdown: String,
            context: WikiRenderContext,
            registry: RendererRegistrySnapshot,
            inlineCapableReferences: Set<RendererReference>
        ) -> Set<SourceID> {
            Set(WikiLinkParser.syntaxNodes(in: markdown).compactMap { node -> SourceID? in
                guard case .embed(let embed) = node else { return nil }
                let lookupName: String
                switch embed.target.namespace {
                case .source:
                    lookupName = embed.target.canonicalID ?? embed.target.literal
                case .page:
                    if let canonicalID = embed.target.canonicalID,
                       context.pageIDToName[PageID(rawValue: canonicalID)] != nil {
                        return nil
                    }
                    if embed.target.canonicalID == nil,
                       context.pageTitles.contains(embed.target.literal.lowercased()) {
                        return nil
                    }
                    lookupName = embed.target.canonicalID ?? embed.target.literal
                case .chat:
                    return nil
                }
                guard let info = context.embedInfo(lookupName),
                      info.target == nil,
                      DocumentSourceRendererProjection.hasEligibleRenderer(
                          mimeType: info.mimeType,
                          fileExtension: context.sourceIDToExtension[info.id],
                          registry: registry,
                          inlineCapableReferences: inlineCapableReferences)
                else { return nil }
                return info.id
            })
        }

        static func markdownImageSourceMap(
            markdown: String,
            currentSelection: WikiSelection?,
            context: WikiRenderContext?,
            sources: [SourceSummary],
            bookmarkNodes: [BookmarkNode]
        ) -> [String: SourceID]? {
            if case .source(let sourceID) = currentSelection {
                return context?.siblingMaps[sourceID]
            }
            let resolved = MarkdownImageSourcePathResolver.resolve(
                markdown: markdown,
                sources: sources,
                bookmarkNodes: bookmarkNodes)
            return resolved.isEmpty ? nil : resolved
        }

        static func markdownImageTargets(
            siblingSourceMap: [String: SourceID]?,
            store: WikiStore?,
            sourceExtensions: [SourceID: String] = [:],
            installedDescriptors: [RendererDescriptor]
        ) -> [String: ResolvedMarkdownImageTarget] {
            guard let siblingSourceMap, siblingSourceMap.isEmpty == false else { return [:] }
            guard let store else {
                return siblingSourceMap.reduce(into: [:]) { targets, entry in
                    targets[entry.key] = .blob(entry.value)
                }
            }
            guard let registry = rendererRegistry(installedDescriptors: installedDescriptors) else {
                return siblingSourceMap.reduce(into: [:]) { targets, entry in
                    targets[entry.key] = .blob(entry.value)
                }
            }
            var sources = [String: RendererEmbeddedContent.Source]()
            for (target, sourceID) in siblingSourceMap {
                do {
                    guard let version = try store.activeContentVersion(sourceID: sourceID),
                          let source = try Self.pinnedImageSource(
                              sourceID: sourceID,
                              version: version,
                              fileExtension: sourceExtensions[sourceID],
                              inputByteCount: { input in try store.rendererInputByteCount(input) },
                              readBytes: { versionID in try store.sourceContent(versionID: versionID) })
                    else { continue }
                    sources[target] = source
                } catch {
                    DebugLog.reader("Image renderer projection could not pin a sibling source; keeping the ordinary image.")
                }
            }
            do {
                return try MarkdownImageTargetProjection.build(
                    siblingSources: sources,
                    siblingSourceIDs: siblingSourceMap,
                    registry: registry,
                    inlineCapableReferences: inlineCapableReferences(installedDescriptors: installedDescriptors))
            } catch {
                DebugLog.reader("Image renderer projection could not validate sibling facts; keeping ordinary images.")
                return siblingSourceMap.reduce(into: [:]) { targets, entry in
                    targets[entry.key] = .blob(entry.value)
                }
            }
        }

        private static func rendererRegistry(
            installedDescriptors: [RendererDescriptor]
        ) -> RendererRegistrySnapshot? {
            do {
                return try RendererRegistrySnapshot(
                    builtInDescriptors: BuiltInRendererDescriptors.all,
                    enabledInstalledDescriptors: installedDescriptors)
            } catch {
                DebugLog.reader("Document renderer projection rejected an invalid descriptor snapshot.")
                return nil
            }
        }

        private static func inlineCapableReferences(
            installedDescriptors: [RendererDescriptor]
        ) -> Set<RendererReference> {
            Set(installedDescriptors.compactMap { descriptor in
                if case .webPackage = descriptor.implementation { return descriptor.reference }
                return nil
            })
        }

        /// Verifies metadata for one exact source version before requesting its
        /// payload. A missing or oversized metadata count intentionally keeps
        /// the Markdown image ordinary without materializing blob bytes.
        static func pinnedImageSource(
            sourceID: SourceID,
            version: SourceVersion,
            fileExtension: String? = nil,
            inputByteCount: (RendererBridgeInput) throws -> Int?,
            readBytes: (SourceVersionID) throws -> Data
        ) throws -> RendererEmbeddedContent.Source? {
            guard version.sourceID == sourceID,
                  let mimeType = version.mimeType,
                  let blobHash = version.blobHash,
                  blobHash.isEmpty == false
            else { return nil }
            let input = RendererBridgeInput.source(versionID: version.id)
            guard let byteCount = try inputByteCount(input),
                  byteCount >= 0,
                  byteCount <= WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount
            else { return nil }
            let bytes = try readBytes(version.id)
            guard bytes.count == byteCount,
                  bytes.count <= WikiAppWebViewPolicy.maximumBridgeInputPayloadByteCount
            else { return nil }
            return try RendererEmbeddedContent.Source(
                sourceID: sourceID,
                sourceVersionID: version.id,
                mimeType: try RendererMIMEType(validating: mimeType),
                fileExtension: fileExtension,
                bytes: bytes)
        }

        func teardown() {
            isDismantled = true
            loadGeneration += 1
            transclusionGeneration += 1
            // DOM-era teardown: close every frame bridge session before the
            // webview goes away.
            frameBridgeRegistry.closeAll()
            convertTask?.cancel()
            convertTask = nil
            cancelTransclusionTasks()
            cancelInlineRetentionTasks()
            webView?.addURLHandler = nil
            webView?.addBookmarkHandler = nil
            webView?.onRendererActivation = nil
            webView?.rendererActivationAdmission = nil
            isLoadingBinding = nil
            renderOptions = nil
            attachmentCoordinator?.closeAll()
            frameBridgeRegistry.closeAll()
            attachmentCoordinator = nil
            attachmentContainer = nil
            webView = nil
            store = nil
            currentSelection = nil
            loadedMarkdown = nil
            loadedDocumentIdentity = nil
        }

        // MARK: - Pending-anchor / quote-highlight flow
        //
        // How a clicked `[[source:Name#"quote"]]` (or `[[Page#Section]]`) link
        // reaches a highlight/scroll in this reader:
        //
        //   1. The link is rendered as `<a href="wiki://source?title=…#%22quote%22">`.
        //   2. A click fires the WKWebView navigation delegate → `route(_:)` →
        //      `linkRoute(for:)` classifies it → `store.selectSource(byDisplayName:
        //      anchor:)` (or `selectPage`).
        //   3. `selectSource` stashes the fragment in `store.pendingScrollAnchor`
        //      (tagged with the destination selection) and bumps
        //      `store.pendingScrollAnchorVersion`, then opens the tab.
        //   4. This reader's `Coordinator` — here — consumes that anchor once the
        //      page has painted and applies it (`apply(_:)` → scroll to a heading
        //      slug, or `highlightJS` for a quote).
        //
        // WHY the Coordinator consumes (not the view's `.task` + `@State`): the
        // reader can be re-created mid-navigation (e.g. its container swaps
        // `headVersion`), and a `.task` that consumed the anchor into `@State` was
        // discarded before `updateNSView` could propagate it — so nothing applied.
        // By reading the STORE's version directly and tracking our own
        // `appliedAnchorVersion`, the coordinator that actually reaches a painted
        // page always gets to consume + apply, regardless of how many times the
        // view above is torn down and rebuilt. The store outlives the view.
        //
        // The version gate also makes a re-click to an already-open doc re-fire
        // (a new `selectSource` bumps the version past `appliedAnchorVersion`),
        // and `consumePendingScrollAnchor` clearing the anchor only here (after
        // `pageLoaded`) means a discarded-before-paint view never steals it.

        /// Consume + apply the pending scroll anchor for `currentSelection` once
        /// the page has painted and the store has a newer anchor version than we
        /// last applied. Called from `updateNSView` (re-click on a loaded doc) and
        /// `didFinish` (fresh load). See the flow note above.
        func consumeAndApplyPendingAnchor(in webView: WKWebView) {
            guard let store, pageLoaded,
                  store.pendingScrollAnchorVersion != appliedAnchorVersion else { return }
            appliedAnchorVersion = store.pendingScrollAnchorVersion
            guard let fragment = store.consumePendingScrollAnchor(for: currentSelection) else { return }
            
            // First, try scrolling assuming fragment is an exact element ID (like a heading slug).
            // This guarantees that outline clicks work even if AnchorBlock.parse fails or slugs mismatch slightly.
            let s = WikiReaderRep.jsString(fragment)
            webView.evaluateJavaScript(
                #"var e=document.getElementById("\#(s)"); if(e){e.scrollIntoView({block:"start"});}"#
            ) { [weak self] _, _ in
                // We don't check for success here because we still want to apply quotes if it wasn't a heading ID.
                guard let md = self?.loadedMarkdown,
                      let target = WikiReaderView.resolveScrollTarget(fragment, blocks: AnchorBlock.parse(md))
                else { return }
                
                // If it resolved to a quote, apply it. If it resolved to a heading, applying it again is harmless.
                if case .quote = target {
                    WikiReaderRep.apply(target, in: webView)
                }
            }
        }

        /// Highlight and scroll to the find match using `window.find()`.
        /// `occurrence` is 1-based: the selection is reset to the document start
        /// and `window.find()` is advanced that many times, so repeated next/prev
        /// clicks step through distinct matches instead of re-finding the first.
        func applyFind(_ text: String, occurrence: Int, in webView: WKWebView) {
            guard pageLoaded else { return }
            let q = WikiReaderRep.jsString(text)
            let n = max(1, occurrence)
            webView.evaluateJavaScript("""
            (function(q, n){
              // Clear any previous highlight, collapsing the selection.
              document.querySelectorAll("mark.sdwhl").forEach(function(m){
                var p=m.parentNode; while(m.firstChild) p.insertBefore(m.firstChild,m);
                p.removeChild(m); p.normalize();
              });
              // Reset the selection to the start of the body so window.find()
              // walks matches in order from the top — making occurrence N
              // deterministic instead of resuming from the previous highlight.
              var sel=window.getSelection();
              sel.removeAllRanges();
              var body=document.body;
              if(body){
                 var r0=document.createRange();
                 r0.setStart(body,0);
                 r0.collapse(true);
                 sel.addRange(r0);
              }
              // Advance forward N times to land on the requested occurrence.
              for(var i=0;i<n;i++){ window.find(q,false,false,false,false); }
              if(sel.rangeCount>0 && !sel.isCollapsed){
                 var r=sel.getRangeAt(0); var mark=document.createElement("mark");
                 mark.className="sdwhl";
                 try{ r.surroundContents(mark); }catch(e){
                   // surroundContents fails across element boundaries; fall back
                   // to a plain node at the selection start and scroll to it.
                   mark.appendChild(document.createTextNode(q));
                   r.insertNode(mark);
                 }
                 var mk=document.querySelector("mark.sdwhl");
                 if(mk){ mk.scrollIntoView({block:"center"}); }
              }
            })("\(q)", \(n));
            """)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let start = loadStart {
                ReaderTiming.point("webview.appear-to-painted", ms: Self.elapsedMs(since: start))
            }
            // Split the WKWebView cost: async hop (startLoad→loadHTMLString) vs.
            // pure WKWebView parse/layout (loadHTMLString→didFinish). Tells us
            // whether a navigation-free innerHTML swap would actually help.
            if let html = htmlLoadStart {
                ReaderTiming.point("webview.html-load", ms: Self.elapsedMs(since: html))
            }
            // Full click→painted latency (user perception): click → convert →
            // WKWebView parse/layout → didFinish. Splits vs. the startLoad window
            // above ("click.to-startLoad") so we know if the stall is in the
            // synchronous SwiftUI path or in the WKWebView load itself.
            if let click = store?.clickStartedAt {
                ReaderTiming.point("click.to-painted", ms: Self.elapsedMs(since: click))
            }
            pageLoaded = true
            isLoadingBinding?.wrappedValue = false
            webView.evaluateJavaScript("window.__sdwRendererAttachmentReport && window.__sdwRendererAttachmentReport(\(loadGeneration));")
            consumeAndApplyPendingAnchor(in: webView)
        }

        // WebKit's delegate protocol requires an implicitly unwrapped navigation argument.
        // swiftlint:disable:next implicitly_unwrapped_optional
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            // WebKit now replaces the DOM for the current load generation.
            // Invalidate lazy DOM work and release frame sessions from the
            // old document (the DOM itself is replaced by the navigation).
            // The coordinator is recreated for the new generation so stale
            // geometry and activation callbacks from the old document fail
            // closed; the fresh document's geometry then re-registers rows.
            transclusionGeneration += 1
            cancelTransclusionTasks()
            cancelInlineRetentionTasks()
            frameBridgeRegistry.closeAll()
            attachmentCoordinator?.closeAll()
            attachmentCoordinator = RendererAttachmentCoordinator(generation: loadGeneration)
        }

        func handleAttachmentGeometry(_ message: RendererAttachmentGeometryMessage) {
            guard let attachmentCoordinator else { return }
            let isFirstGeometry = attachmentCoordinator.state(for: message.placeholderID) == .unresolved
            let isFirstRowGeometry = message.embeddingRole == .disclosureRow && isFirstGeometry
            let isFirstInlineGeometry = message.embeddingRole == .inlineContent && isFirstGeometry
            guard attachmentCoordinator.ingest(message),
                  let webView, let attachmentContainer else { return }
            if isFirstRowGeometry || isFirstInlineGeometry {
                let renderer = webView.rendererActivationAdmission?
                    .attachmentContext(for: message.placeholderID)?
                    .rendererReference
                let reservedHeight = attachmentCoordinator.reserveHeight(
                    RendererAttachmentHostPolicy.preferredReservedHeight(
                        for: renderer,
                        role: message.embeddingRole),
                    for: message.placeholderID)
                let identifier = WikiReaderRep.jsString(message.placeholderID.rawValue)
                webView.evaluateJavaScript("window.__sdwRendererAttachmentReserve && window.__sdwRendererAttachmentReserve(\"\(identifier)\", \(reservedHeight));")
            }
            updateAttachmentViewport(for: message.placeholderID, in: webView, container: attachmentContainer)
            guard message.embeddingRole == .inlineContent else { return }
            if message.visible {
                inlineRetentionTasks.removeValue(forKey: message.placeholderID)?.cancel()
                mountInlineContentIfEligible(message.placeholderID)
            } else if attachmentCoordinator.inlineState(for: message.placeholderID) == .mounted {
                scheduleInlineRetentionRelease(message.placeholderID, generation: message.generation)
            }
        }

        func handleAttachmentRemoval(_ placeholderID: RendererAttachmentPlaceholderID, generation: Int) {
            guard let attachmentCoordinator, attachmentCoordinator.generation == generation else { return }
            inlineRetentionTasks.removeValue(forKey: placeholderID)?.cancel()
            let role = attachmentCoordinator.role(for: placeholderID)
            // DOM era: remove the embed surface and its bridge session.
            frameBridgeRegistry.remove(placeholderID: placeholderID)
            webView?.evaluateJavaScript(RendererDOMEmbedInjection.removalScript(for: placeholderID))
            if role == .inlineContent {
                attachmentCoordinator.removeInline(placeholderID)
            } else {
                attachmentCoordinator.close(placeholderID)
            }
            if role == .disclosureRow { setRowExpansion(false, for: placeholderID) }
        }

        /// DOM era: inline content mounts inside the document (media elements,
        /// iframes) — there is no native inline child to project.
        private func mountInlineContentIfEligible(_ placeholderID: RendererAttachmentPlaceholderID) {
            guard let attachmentCoordinator,
                  attachmentCoordinator.role(for: placeholderID) == .inlineContent,
                  attachmentCoordinator.inlineState(for: placeholderID) != .mounted,
                  let context = webView?.rendererActivationAdmission?.attachmentContext(for: placeholderID),
                  context.embeddingRole == .inlineContent else { return }
            guard attachmentCoordinator.admitInline(placeholderID) == .activate else { return }

            // Built-in source embeds mount their typed DOM plan; native
            // inline renderers have no host child anymore and fail to the
            // readable fallback.
            if case .source = context.identity,
               case .source = context.input,
               let plan = RendererDOMEmbedPlanner.builtInPlan(context: context) {
                _ = mountDOMEmbed(plan: plan, named: placeholderID, context: context)
                return
            }
            switch inlineAttachmentResolver(
                context,
                placeholderID,
                inlineSessionFailureHandler(for: placeholderID, generation: context.generation)
            ) {
            case .content:
                // Native inline child mounting was removed with the overlay;
                // unsupported native inline renderers fail to the fallback.
                attachmentCoordinator.failInline(placeholderID)
            case .unsupported:
                attachmentCoordinator.failInline(placeholderID)
            case .failed:
                attachmentCoordinator.failInline(placeholderID)
            }
        }

        private func scheduleInlineRetentionRelease(
            _ placeholderID: RendererAttachmentPlaceholderID,
            generation: Int
        ) {
            guard inlineRetentionTasks[placeholderID] == nil else { return }
            inlineRetentionTasks[placeholderID] = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: RendererAttachmentHostPolicy.inlineOffscreenRetentionDuration)
                } catch {
                    return
                }
                guard let self,
                      let attachmentCoordinator = self.attachmentCoordinator,
                      attachmentCoordinator.generation == generation,
                      attachmentCoordinator.geometry(for: placeholderID)?.visible == false
                else { return }
                attachmentCoordinator.releaseInline(placeholderID)
                self.inlineRetentionTasks.removeValue(forKey: placeholderID)
                self.retryWaitingInlineContent()
            }
        }

        private func retryWaitingInlineContent() {
            guard let attachmentCoordinator else { return }
            for placeholderID in attachmentCoordinator.placeholderIDs
            where attachmentCoordinator.inlineState(for: placeholderID) == .waitingForResources
                && attachmentCoordinator.geometry(for: placeholderID)?.visible == true {
                mountInlineContentIfEligible(placeholderID)
            }
        }

        private func cancelTransclusionTasks() {
            for task in transclusionTasks.values { task.cancel() }
            transclusionTasks.removeAll()
        }

        private func cancelInlineRetentionTasks() {
            for task in inlineRetentionTasks.values { task.cancel() }
            inlineRetentionTasks.removeAll()
        }

        /// Activate the card's explicit control. The injected resolver owns the
        /// renderer-specific inline view; unsupported renderers retain the full
        /// renderer route.
        func activateAttachment(_ placeholderID: RendererAttachmentPlaceholderID) -> RendererAttachmentActivationResult {
            guard let attachmentCoordinator, let attachmentContainer else { return .rejected }
            // No registered context means there is nothing authorized to show —
            // neither natively nor in the full renderer.
            guard let context = webView?.rendererActivationAdmission?.attachmentContext(for: placeholderID) else {
                failAttachment(placeholderID)
                return .rejected
            }
            if attachmentCoordinator.state(for: placeholderID) == .active {
                // DOM era: the embed is part of the document; focus returns to
                // the webview (the row's disclosure button is a DOM focus target).
                webView?.window?.makeFirstResponder(webView)
                return .activate
            }
            let admission = attachmentCoordinator.activate(placeholderID)
            guard admission == .activate else {
                if case let .refused(reason) = admission { surfaceRefusal(reason, for: placeholderID) }
                return admission
            }
            // DOM era: an admitted package renderer with a frame route mounts
            // its iframe in the document flow. Built-in source embeds (PDF,
            // inert HTML, byte-backed media, byteless fallback) mount their
            // typed DOM plan. Open in Window remains a separate explicit
            // action and is never implied by expansion.
            if case .disclosureRow = context.embeddingRole, let webView {
                if let frameToken = webView.rendererPackageFrameTokens[context.rendererReference],
                   let entry = webView.rendererPackageFrameEntryPaths[context.rendererReference],
                   let plan = RendererDOMEmbedPlanner.packagePlan(
                       context: context,
                       frameToken: frameToken,
                       entryPath: entry) {
                    clearRowStatus(placeholderID)
                    return mountDOMEmbed(plan: plan, named: placeholderID, context: context)
                }
                // Built-in presentations for source-backed embeds (no
                // installed package reference).
                if case .source = context.identity,
                   case .source = context.input,
                   let plan = RendererDOMEmbedPlanner.builtInPlan(context: context) {
                    clearRowStatus(placeholderID)
                    return mountDOMEmbed(plan: plan, named: placeholderID, context: context)
                }
            }
            switch inlineAttachmentResolver(
                context,
                placeholderID,
                inlineSessionFailureHandler(for: placeholderID, generation: context.generation)
            ) {
            case .failed:
                attachmentCoordinator.collapse(placeholderID)
                failAttachment(placeholderID)
                return .rejected
            case .unsupported:
                // Expansion and Open in Window are separate user actions. Keep
                // this row collapsed when no inline factory accepts its input.
                attachmentCoordinator.collapse(placeholderID)
                setRowExpansion(
                    false,
                    for: placeholderID,
                    status: "This renderer is not available inline. Use Open in Window.")
                return .rejected
            case .content(let content):
                let result = mountInlineAttachment(
                    content,
                    named: placeholderID,
                    in: attachmentContainer,
                    takesFocus: true,
                    context: context)
                return result
            }
        }

        /// Hand the exact authorized reference + input to the app-layer renderer
        /// presentation. Returns `.rejected` when no presenter is wired (the
        /// agent-transcript and preview readers pass none).
        private func presentInFullRenderer(_ context: RendererEmbedActivationContext) -> RendererAttachmentActivationResult {
            guard let present = webView?.onRendererActivation else { return .rejected }
            present(context.rendererReference, context.input)
            return .showInFullRenderer
        }

        private func mountInlineAttachment(
            _ content: AnyView,
            named placeholderID: RendererAttachmentPlaceholderID,
            in attachmentContainer: WikiReaderContainerView,
            takesFocus: Bool,
            context: RendererEmbedActivationContext
        ) -> RendererAttachmentActivationResult {
            // DOM era: native inline children are removed. The remaining
            // caller (native inline renderers) fails to the readable fallback.
            _ = content
            _ = placeholderID
            _ = takesFocus
            _ = context
            return .rejected
        }

        /// Clears a placeholder's status/fallback message after a successful
        /// activation (the row was previously refused or failed).
        func clearRowStatus(_ placeholderID: RendererAttachmentPlaceholderID) {
            guard let webView else { return }
            webView.evaluateJavaScript(
                "window.__sdwRendererAttachmentState && window.__sdwRendererAttachmentState(\"\(WikiReaderRep.jsString(placeholderID.rawValue))\", true, \"\");")
        }

        /// DOM-era mounting: injects the embed surface (package iframe, pinned
        /// blob frame, or media element) into the placeholder's expansion region
        /// through the named JS function, and admits its frame-scoped bridge
        /// session. Returns `.activate` on success; the caller collapses on
        /// any failure so the row keeps a readable fallback.
        private func mountDOMEmbed(
            plan: RendererDOMEmbedPlan,
            named placeholderID: RendererAttachmentPlaceholderID,
            context: RendererEmbedActivationContext
        ) -> RendererAttachmentActivationResult {
            guard let webView, let attachmentCoordinator else { return .rejected }
            guard attachmentCoordinator.state(for: placeholderID) == .active else { return .rejected }

            // Package frames need an admitted bridge session before their
            // document can ask for input. Admit first: a budget rejection
            // below collapses the row without a frame in the DOM.
            var frameToken: RendererFrameOriginToken?
            if case .packageFrame(let framePlan) = plan {
                frameToken = framePlan.frameToken
                guard let webViewObject = webView as NSView? else { return .rejected }
                // The exact authorized input reader for this context. No
                // registered store (preview readers) means no bridge: the
                // row collapses to a readable fallback instead.
                guard let store else { return .rejected }
                let inputReader = RendererAuthorizedInputReader(
                    store: store.internalStore,
                    authorizedInput: context.input)
                var originComponents = URLComponents()
                originComponents.scheme = RendererPackageScheme.name
                originComponents.host = framePlan.frameToken.rawValue
                guard let expectedOrigin = originComponents.url else {
                    // A scheme+host component pair always yields a URL; a nil
                    // here would mean an invalid token slipped through.
                    DebugLog.reader("frame origin URL construction failed for \(placeholderID.rawValue)")
                    return .rejected
                }
                let broker = RendererContentWorldBroker(
                    sessionID: .init(rawValue: UUID()),
                    capability: context.capability,
                    inputReader: inputReader,
                    expectedOrigin: expectedOrigin)
                broker.bind(to: webView)
                let admitted = frameBridgeRegistry.admit(
                    placeholderID: placeholderID,
                    frameToken: framePlan.frameToken,
                    rendererReference: context.rendererReference,
                    generation: context.generation,
                    broker: broker,
                    expectedWebViewID: ObjectIdentifier(webViewObject))
                guard admitted else {
                    attachmentCoordinator.refuse(placeholderID, reason: .resourcePressure)
                    surfaceRefusal(.resourcePressure, for: placeholderID)
                    return .refused(.resourcePressure)
                }
            }

            let expansionID = "\(placeholderID.rawValue)-expansion"
            guard let script = RendererDOMEmbedInjection.injectionScript(
                plan: plan,
                placeholderID: placeholderID,
                expansionID: expansionID)
            else {
                // Readable-fallback plans render status text, not a surface.
                if case .readableFallback(let fallback) = plan {
                    DebugLog.reader("embed[\(placeholderID.rawValue)]: readable fallback (\(fallback.explanation))")
                    setRowExpansion(true, for: placeholderID, status: fallback.explanation)
                    return .activate
                }
                DebugLog.reader("embed[\(placeholderID.rawValue)]: no injection script for \(plan)")
                return .rejected
            }
            webView.evaluateJavaScript(script) { [weak self] result, error in
                guard let self else { return }
                if let error {
                    DebugLog.reader("embed[\(placeholderID.rawValue)]: injection JS error \(error.localizedDescription)")
                    self.frameBridgeRegistry.close(placeholderID: placeholderID)
                    return
                }
                // Any? from the JS bridge is not Sendable; stringify in place.
                let resultDescription = result.map { "\($0)" } ?? "nil"
                DebugLog.reader("embed[\(placeholderID.rawValue)]: injection result \(resultDescription)")
                if case .packageFrame = plan {
                    // The frame's own load completion is not directly
                    // observable; the injection acknowledgement plus the
                    // registry timeout bound a hung frame.
                    if let token = frameToken {
                        self.frameBridgeRegistry.frameDidLoad(token: token)
                    }
                    // Poll the document's load-state map once, late enough for
                    // a local-resource frame to have finished (diagnostics only).
                    let poll = "String(window.__sdwRendererEmbedLoads && window.__sdwRendererEmbedLoads[\"\(WikiReaderRep.jsString(placeholderID.rawValue))\"] || 'no-entry')"
                    webView.evaluateJavaScript(poll) { state, _ in
                        DebugLog.reader("embed[\(placeholderID.rawValue)]: load state \(state ?? "poll-error")")
                    }
                }
            }
            return .activate
        }

        private func inlineSessionFailureHandler(
            for placeholderID: RendererAttachmentPlaceholderID,
            generation: Int
        ) -> @MainActor (RendererSessionFailure) -> Void {
            { [weak self] failure in
                guard let self,
                      let attachmentCoordinator = self.attachmentCoordinator,
                      attachmentCoordinator.generation == generation
                else { return }
                let role = attachmentCoordinator.role(for: placeholderID)
                let state = attachmentCoordinator.state(for: placeholderID)
                guard state != .closed else { return }
                DebugLog.reader("inline renderer session failed for \(placeholderID.rawValue): \(failure.kind)")
                if role == .inlineContent {
                    // DOM era: the embed surface lives in the document; a
                    // failed session closes its bridge and the row keeps its
                    // readable fallback.
                    self.frameBridgeRegistry.close(placeholderID: placeholderID)
                    webView?.evaluateJavaScript(RendererDOMEmbedInjection.removalScript(for: placeholderID))
                    if failure.kind == .concurrencyLimitReached {
                        attachmentCoordinator.waitForInlineResources(placeholderID)
                    } else {
                        attachmentCoordinator.failInline(placeholderID)
                    }
                    return
                }
                guard state != .unresolved else { return }
                if failure.kind == .concurrencyLimitReached {
                    attachmentCoordinator.refuse(placeholderID, reason: .resourcePressure)
                    self.frameBridgeRegistry.close(placeholderID: placeholderID)
                    webView?.evaluateJavaScript(RendererDOMEmbedInjection.removalScript(for: placeholderID))
                    self.surfaceRefusal(.resourcePressure, for: placeholderID)
                    return
                }
                self.failAttachment(placeholderID)
            }
        }

        // DOM era: viewport projection was overlay machinery; embedded content
        // moves and scales with the page because it is part of the page.
        private func updateAttachmentViewport(
            for placeholderID: RendererAttachmentPlaceholderID,
            in webView: WikiReaderWebView,
            container: WikiReaderContainerView
        ) {}

        func applyReaderZoom(
            _ readerZoom: Double,
            to webView: WikiReaderWebView,
            container: WikiReaderContainerView
        ) {
            let zoom = CGFloat(readerZoom)
            guard appliedReaderZoom != zoom else { return }
            appliedReaderZoom = zoom
            webView.pageZoom = zoom
            // Reader pageZoom is the single outer zoom; package canvas zoom
            // stays renderer-owned. Embedded DOM content scales with the page.
            webView.evaluateJavaScript("window.__sdwRendererAttachmentReport && window.__sdwRendererAttachmentReport(\(loadGeneration));")
        }

        private func setRowExpansion(_ expanded: Bool, for placeholderID: RendererAttachmentPlaceholderID, status: String? = nil) {
            guard let webView else { return }
            let identifier = WikiReaderRep.jsString(placeholderID.rawValue)
            let message = status.map(WikiReaderRep.jsString) ?? ""
            webView.evaluateJavaScript("window.__sdwRendererAttachmentState && window.__sdwRendererAttachmentState(\"\(identifier)\", \(expanded), \"\(message)\");")
        }

        private func surfaceRefusal(_ refusal: RendererAttachmentActivationRefusal, for placeholderID: RendererAttachmentPlaceholderID) {
            let message = switch refusal {
            case .rowBudget: "Four renderer rows are already expanded. Collapse one to expand this row."
            case .resourcePressure: "Renderer resources are busy. Try expanding this row again."
            }
            setRowExpansion(false, for: placeholderID, status: message)
        }

        func attachmentState(for placeholderID: RendererAttachmentPlaceholderID) -> RendererAttachmentState {
            attachmentCoordinator?.state(for: placeholderID) ?? .unresolved
        }

        func inlineAttachmentState(
            for placeholderID: RendererAttachmentPlaceholderID
        ) -> InlineRendererAttachmentState {
            attachmentCoordinator?.inlineState(for: placeholderID) ?? .fallback
        }

        var attachmentGeneration: Int? { attachmentCoordinator?.generation }
        var currentTransclusionGeneration: Int { transclusionGeneration }

        func collapseAttachment(_ placeholderID: RendererAttachmentPlaceholderID) {
            guard let attachmentCoordinator,
                  attachmentCoordinator.state(for: placeholderID) == .active
            else { return }
            attachmentCoordinator.collapse(placeholderID)
            // DOM-era collapse: remove the embed surface and its bridge
            // session, scoped to this row.
            teardownDOMEmbed(placeholderID)
            setRowExpansion(false, for: placeholderID)
        }

        /// Scoped DOM-embed teardown: removes the embed surface from this
        /// placeholder's expansion region and closes its bridge session. Other
        /// rows are untouched.
        func teardownDOMEmbed(_ placeholderID: RendererAttachmentPlaceholderID) {
            frameBridgeRegistry.close(placeholderID: placeholderID)
            guard let webView else { return }
            webView.evaluateJavaScript(RendererDOMEmbedInjection.removalScript(for: placeholderID))
        }

        func failAttachment(_ placeholderID: RendererAttachmentPlaceholderID) {
            attachmentCoordinator?.fail(placeholderID)
            setRowExpansion(false, for: placeholderID)
            teardownDOMEmbed(placeholderID)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                if url.scheme == "wiki" {
                    // macOS browser convention: plain click navigates the current
                    // tab in place; ⌘-click opens the target in a new tab.
                    let openInNewTab = navigationAction.modifierFlags.contains(.command)
                    route(url, openInNewTab: openInNewTab)
                    decisionHandler(.cancel)
                    return
                }
                if let activation = WikiReaderView.rendererActivationRoute(
                    for: url,
                    admission: (webView as? WikiReaderWebView)?.rendererActivationAdmission,
                    isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false
                ) {
                    (webView as? WikiReaderWebView)?.onRendererActivation?(activation.reference, activation.input)
                    decisionHandler(.cancel)
                    return
                }
                if WikiReaderView.rendererActionNavigationPolicy(for: url) == .cancel {
                    decisionHandler(.cancel)
                    return
                }
                // A fragment-only link resolves against the reader document
                // origin. Allow it so WKWebView scrolls to the target within
                // this document.
                if WikiReaderDocumentOrigin.isSameDocumentFragment(url) {
                    decisionHandler(.allow)
                    return
                }
                // Relative links in source markdown (e.g. `[Back to README](../README.md)`)
                // are not `[[wikilinks]]`, so `RelativeLinkRewriter` leaves them as raw
                // `<a href>`. WKWebView resolves them against the reader document origin
                // (`WikiReaderDocumentOrigin` → `wiki-reader://reader/document.html`). Try to
                // navigate to a matching source by filename/display-name; if none found, cancel
                // silently — never open the bogus reader URL in the system browser.
                if url.scheme == WikiReaderDocumentOrigin.scheme,
                   url.host == WikiReaderDocumentOrigin.host {
                    let targetName = url.lastPathComponent
                    let openInNewTab = navigationAction.modifierFlags.contains(.command)
                    if let store,
                       let id = store.sourceID(forDisplayName: targetName)
                               ?? store.sourceID(forDisplayName: (targetName as NSString).deletingPathExtension) {
                        store.selectSource(byID: id, anchor: url.fragment, openInNewTab: openInNewTab)
                    }
                    decisionHandler(.cancel)
                    return
                }
                // External links open in the system browser, not in the reader.
                // Footnote references are same-page fragment links (`#wiki-fn-…`),
                // so they fall through to `.allow` and WKWebView scrolls natively.
                if url.scheme == "http" || url.scheme == "https" {
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        /// Dispatch a clicked `wiki://` link to navigation/scroll. Step 2 of the
        /// pending-anchor flow (see `consumeAndApplyPendingAnchor`): the resulting
        /// `selectPage`/`selectSource` stash the `#fragment` as a pending anchor
        /// that the *destination* reader's Coordinator later consumes + applies.
        /// `openInNewTab` mirrors the click's modifier (⌘-click → new tab).
        private func route(_ url: URL, openInNewTab: Bool = false) {
            switch WikiReaderView.linkRoute(for: url) {
            case .samePageAnchor(let frag):
                if let webView, let frag {
                    let s = WikiReaderRep.jsString(frag)
                    webView.evaluateJavaScript(
                        #"var e=document.getElementById("\#(s)"); if(e){e.scrollIntoView({block:"start"});}""#)
                }
            case .page(let title, let id, let frag):
                if let id, store?.selectPage(byID: id, anchor: frag, openInNewTab: openInNewTab) == true { }
                else { store?.selectPage(byTitle: title, anchor: frag, openInNewTab: openInNewTab) }
            case .source(let title, let id, let frag, let pin):
                if let id, store?.selectSource(byID: id, anchor: frag, openInNewTab: openInNewTab, pinnedExtractionID: pin) == true { }
                else { store?.selectSource(byDisplayName: title, anchor: frag, openInNewTab: openInNewTab) }
            case .chat(let title, let id, let frag):
                if let id, store?.selectChat(byID: id, anchor: frag, openInNewTab: openInNewTab) == true { }
                else { store?.selectChat(byTitle: title, anchor: frag, openInNewTab: openInNewTab) }
            case .inert:
                break
            }
        }

        // MARK: - Plan v2 transclusion — embed fetch + render

        /// Closure that delivers the JS source to the web view. Defaults to
        /// `webView?.evaluateJavaScript(js)`; tests replace it with a recorder
        /// to assert the exact JS string (in particular, that the HTML is a
        /// **parameter** to `sdwInjectEmbed`, never concatenated into source —
        /// Plan v2 §4.4 safe-injection mandate).
        var deliverJS: (@MainActor (String) -> Void)?

        /// Emit `js` to the web view (or to the test recorder if set).
        @MainActor
        private func emit(_ js: String) {
            if let deliverJS { deliverJS(js) }
            else { webView?.evaluateJavaScript(js) }
        }

        /// Handle the `embedFetch` message posted from a first-opened
        /// `<details class="sdw-transclusion">`. Resolves the id (name-based
        /// page embeds resolved here on the main actor via `pageID(forTitle:)`),
        /// gets a **fresh** `WikiRenderContext`, hops off-main into
        /// `readPool.asyncRead` to fetch + render the body through the shared
        /// pipeline, then injects via the safe `sdwInjectEmbed` setter
        /// (`TransclusionEmbedder.injectJSCall`). Cycle + missing paths short-
        /// circuit the fetch entirely (Plan v2 §4.3, §8).
        ///
        /// `body` is the `{nodeId, kind, id, target, path, name}` dict the JS
        /// bootstrap posted. Each value is a `String` (empty when absent).
        ///
        /// This is the synchronous entry point the `WKScriptMessageHandler`
        /// proxy calls; it kicks off the fetch via a `Task` (fire-and-forget).
        /// Tests use ``processEmbedFetch(body:)`` (async) to await completion
        /// rather than sleep.
        func handleEmbedFetch(body: [String: String]) {
            let taskID = UUID()
            let generation = transclusionGeneration
            let task = Task { [weak self] in
                await self?.processEmbedFetch(body: body, generation: generation)
                self?.transclusionTasks.removeValue(forKey: taskID)
            }
            transclusionTasks[taskID] = task
        }

        /// Async, awaitable form of ``handleEmbedFetch(body:)``. Does the
        /// cycle check, resolution, fetch, and injection in one async flow so
        /// a test can `await` it instead of polling on a Task. Production
        /// callers go through `handleEmbedFetch` (fire-and-forget); tests go
        /// through this directly.
        func processEmbedFetch(body: [String: String]) async {
            await processEmbedFetch(body: body, generation: transclusionGeneration)
        }

        func processEmbedFetch(body: [String: String], generation: Int) async {
            guard generation == transclusionGeneration,
                  isDismantled == false,
                  Task.isCancelled == false else { return }
            let nodeId = body["nodeId"] ?? ""
            let kindStr = body["kind"] ?? ""
            let idStr = body["id"] ?? ""
            let targetStr = body["target"] ?? ""
            let pathStr = body["path"] ?? ""
            let nameStr = body["name"] ?? ""

            guard !nodeId.isEmpty else { return }
            let kind: ParsedLink.LinkType = kindStr == WikiLinkMarkdown.pageEmbedKind
                ? .page
                : (kindStr == ParsedLink.LinkType.source.rawValue ? .source : .page)

            let ancestors = TransclusionEmbedder.ancestors(path: pathStr)

            // 1. Resolve the typed target. Canonical ULID embeds carry their id directly;
            //    name-based page embeds resolve here on the main actor.
            let resolvedTarget: TransclusionEmbedder.TargetID?
            if !idStr.isEmpty {
                resolvedTarget = kind == .source
                    ? .source(SourceID(rawValue: idStr))
                    : .page(PageID(rawValue: idStr))
            } else if kind == .page, !targetStr.isEmpty,
                      let decoded = targetStr.removingPercentEncoding,
                      let id = store?.pageID(forTitle: decoded) {
                resolvedTarget = .page(id)
            } else {
                resolvedTarget = nil
            }

            // 2. Missing target → render the "not found" body inline (no fetch).
            guard let target = resolvedTarget, let store else {
                let html = "<div class=\"sdw-embed-body sdw-embed-empty\">"
                         + "<span class=\"sdw-embed-placeholder\">"
                         + (kind == .page ? "Page not found" : "Source not found")
                         + "</span></div>"
                emit(TransclusionEmbedder.injectJSCall(nodeId: nodeId, html: html))
                DebugLog.reader("embed-fetch unresolved kind=\(kindStr) target=\(targetStr) name=\(nameStr)")
                return
            }

            // 3. Stop a cycle only when the full tagged target matches.
            //    Page and source IDs remain separate namespaces.
            if ancestors.contains(target) {
                let js = TransclusionEmbedder.cycleMarkerJSCall(nodeId: nodeId, name: nameStr)
                emit(js)
                DebugLog.reader("embed-fetch cycle kind=\(kindStr) id=\(idStr) name=\(nameStr)")
                return
            }

            // 4. Fresh render context (memoized, event-bus-invalidated).
            let context = store.renderContext()
            let renderOptions: MarkdownRenderOptions
            if let configuredOptions = self.renderOptions {
                renderOptions = configuredOptions
            } else {
                // A lazy embed without the root document's policy must never
                // acquire reader highlighting implicitly.
                DebugLog.reader("embed-fetch missing document render policy; using disabled highlighting")
                renderOptions = .disabled
            }

            // 5. Off-main fetch + render. `readPool` is `nil` for in-memory
            //    stores (a separate `:memory:` connection sees a different,
            //    empty DB); fall back to the main-actor store in that case.
            //    No transaction, no extraction — the read path invariant.
            let loadStart = DispatchTime.now()
            do {
                let result: TransclusionEmbedder.Result
                if let readService = store.readService {
                    result = try await readService.asyncRead { access in
                        try TransclusionEmbedder.renderEmbedBody(
                            access: access,
                            target: target,
                            context: context,
                            options: renderOptions,
                            ancestors: ancestors)
                    }
                } else if let grdb = store.internalStore as? GRDBWikiStore {
                    // Main-actor fallback (in-memory tests; rare in prod).
                    result = try TransclusionEmbedder.renderEmbedBody(
                        testFixtureStore: grdb,
                        target: target,
                        context: context,
                        options: renderOptions,
                        ancestors: ancestors)
                } else {
                    result = .empty
                }
                guard generation == transclusionGeneration,
                      isDismantled == false,
                      Task.isCancelled == false else { return }
                DebugLog.reader("embed-fetch ok kind=\(kindStr) id=\(target.rawValue) "
                              + "name=\(nameStr) ms=\(Self.elapsedMs(since: loadStart))")
                let html: String
                switch result {
                case .content(let content):
                    html = content
                case .empty:
                    // Source has no extractable body (binary, no head
                    // markdown) — render the muted placeholder + open
                    // link. NO extraction is triggered.
                    html = TransclusionEmbedder.placeholderBodyHTML(
                        kind: kind, id: target.rawValue, name: nameStr)
                case .cycle:
                    html = TransclusionEmbedder.cycleMarkerHTML(name: nameStr)
                case .failed:
                    html = "<div class=\"sdw-embed-body sdw-embed-empty\"><span class=\"sdw-embed-placeholder\">Failed to load.</span></div>"
                }
                emit(TransclusionEmbedder.injectJSCall(nodeId: nodeId, html: html))
            } catch {
                guard generation == transclusionGeneration,
                      isDismantled == false,
                      Task.isCancelled == false else { return }
                DebugLog.reader("embed-fetch failed kind=\(kindStr) id=\(target.rawValue) "
                              + "error=\(error)")
                let html = "<div class=\"sdw-embed-body sdw-embed-empty\">"
                         + "<span class=\"sdw-embed-placeholder\">Failed to load.</span></div>"
                emit(TransclusionEmbedder.injectJSCall(nodeId: nodeId, html: html))
            }
        }

        nonisolated private static func elapsedMs(since start: DispatchTime) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        }
    }

    // MARK: Apply (JS)

    /// Apply a resolved scroll/highlight target to the loaded web view.
    @MainActor
    static func apply(_ target: PendingScroll, in webView: WKWebView) {
        switch target {
        case .heading(let slug):
            let s = jsString(slug)
            webView.evaluateJavaScript(
                #"var e=document.getElementById("\#(s)"); if(e){e.scrollIntoView({block:"start"});}""#)
        case .quote(let quote):
            webView.evaluateJavaScript(Self.highlightJS(quote: quote))
        }
    }

    /// Highlight + scroll to a quoted passage. Emits a pure JS string —
    /// `nonisolated` so unit tests can assert against it off the main actor
    /// (this replaces the retired `quoteRange` logic).
    ///
    /// Walks **every** text node under the body, building a whitespace-collapsed,
    /// lowercased view with an index map back to `(node, charOffset)`. The quote
    /// is searched in that whole-document view, then the matched range is wrapped
    /// one text segment at a time — so a quote that spans an inline element (a
    /// link, bold) is found and highlighted even though it lives in several text
    /// nodes. (The previous single-node search + `window.find` missed these, and
    /// `window.find` is deprecated/unreliable in WKWebView.)
    nonisolated static func highlightJS(quote: String) -> String {
        let q = jsString(quote)
        return """
        (function(q){
          document.querySelectorAll("mark.sdwhl").forEach(function(m){
            var p=m.parentNode; while(m.firstChild) p.insertBefore(m.firstChild,m);
            p.removeChild(m); p.normalize();
          });
          // Source extraction can convert citation text into editorial
          // typography. Normalize only the comparison view. A character may
          // expand (for example, `…` → `...`), so every normalized character
          // retains the original DOM node + offset in `map`.
          function normalizeTypography(s){
            return s.replace(/[“”]/g,'"').replace(/[‘’]/g,"'")
              .replace(/[‐‑‒–—―−]/g,"-").replace(/…/g,"...")
              .replace(/ﬀ/g,"ff").replace(/ﬁ/g,"fi").replace(/ﬂ/g,"fl")
              .replace(/ﬃ/g,"ffi").replace(/ﬄ/g,"ffl").replace(/[ﬅﬆ]/g,"st");
          }
          var nq=normalizeTypography(q).replace(/\\s+/g," ").trim().toLowerCase();
          if(!nq){ return; }
          var chars=[], map=[];
          var tw=document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          while(tw.nextNode()){
            var v=tw.currentNode.nodeValue;
            for(var i=0;i<v.length;i++){
              var c=v[i];
              if(/\\s/.test(c)){
                if(chars.length===0||chars[chars.length-1]!==" "){ chars.push(" "); map.push({n:tw.currentNode,o:i}); }
              } else {
                var normalized=normalizeTypography(c).toLowerCase();
                for(var j=0;j<normalized.length;j++){
                  chars.push(normalized[j]); map.push({n:tw.currentNode,o:i});
                }
              }
            }
          }
          var lo=0, hi=chars.length;
          while(lo<hi&&chars[lo]===" "){ lo++; }
          while(hi>lo&&chars[hi-1]===" "){ hi--; }
          var hay=chars.slice(lo,hi).join("");
          var at=hay.indexOf(nq), mlen=nq.length;
          if(at<0){
            // The quote may not appear contiguously: PDF extraction can splice
            // a footer/marginal block (or a hard-hyphenated word) into the
            // middle of a sentence. Fall back to the LONGEST contiguous run of
            // >=4 quote-words that IS present, so we still highlight + scroll to
            // the passage instead of giving up.
            var words=nq.split(" ");
            for(var L=words.length-1; L>=4 && at<0; L--){
              for(var st=0; st+L<=words.length; st++){
                var cand=words.slice(st,st+L).join(" ");
                var p=hay.indexOf(cand);
                if(p>=0){ at=p; mlen=cand.length; break; }
              }
            }
            if(at<0){ return; }
          }
          var s=lo+at, e=lo+at+mlen-1;
          var range=document.createRange();
          range.setStart(map[s].n, map[s].o);
          range.setEnd(map[e].n, map[e].o+1);
          // Wrap each text segment intersecting the range, preserving inline
          // elements (e.g. the link inside the quote). Reverse so splitText
          // offsets of earlier nodes stay valid.
          var segs=[];
          var root=range.commonAncestorContainer;
          var rw=document.createTreeWalker(root.nodeType===3?root.parentNode:root, NodeFilter.SHOW_TEXT);
          while(rw.nextNode()){
            var nd=rw.currentNode;
            if(range.intersectsNode(nd)){
              var ss=(nd===range.startContainer)?range.startOffset:0;
              var ee=(nd===range.endContainer)?range.endOffset:nd.nodeValue.length;
              if(ss<ee){ segs.push({n:nd,s:ss,e:ee}); }
            }
          }
          for(var i=segs.length-1;i>=0;i--){
            var g=segs[i];
            var tail=g.n.splitText(g.s);
            if(g.e-g.s<tail.nodeValue.length){ tail.splitText(g.e-g.s); }
            var mark=document.createElement("mark"); mark.className="sdwhl";
            tail.parentNode.insertBefore(mark,tail); mark.appendChild(tail);
          }
          var mk=document.querySelector("mark.sdwhl");
          if(mk){ mk.scrollIntoView({block:"center"}); }
        })("\(q)");
        """
    }

    /// Escape a string for a JS double-quoted literal.
    nonisolated static func jsString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
    }
}
