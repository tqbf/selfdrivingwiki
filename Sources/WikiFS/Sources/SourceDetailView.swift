import SwiftUI
import WikiFSEngine
import WikiFSCore
import WikiFSEngine

/// Detail pane for one ingested source file. Shows metadata header + inline
/// content (markdown render, inline PDF, or tabbed Markdown⇄PDF when extraction
/// output exists). Cmd-E flips between reader and editor for processed markdown;
/// source bytes are never modified.
struct SourceDetailView: View {
    @Environment(QueueActivityTracker.self) private var tracker
    let file: SourceSummary
    let hasBeenIngested: Bool
    let isIngesting: Bool
    let isRunning: Bool
    /// `true` when any file (not necessarily this one) is mid-ingest — covers the
    /// PDF-conversion phase before the agent process starts, when `isRunning` is
    /// still `false`.
    let isAnySourceIngesting: Bool
    /// `true` when THIS file is mid-extraction via the ingest path (pdf2md running
    /// during an ingest of this file, before the agent spawns). Disables the
    /// standalone "Extract Markdown" button for this file only — pdf2md is safe to
    /// overlap with a claude run, so a query/ingest agent run does NOT disable it.
    let isThisFileExtracting: Bool
    /// `true` when the edit lock is held by an agent OTHER than the ingest agent
    /// (i.e., the query agent with "Allow wiki edits" checked). Disables the
    /// Ingest button so the user sees it's unavailable before clicking.
    let isEditLockedExternally: Bool
    /// The wiki this source belongs to. Used as the FP domain selector for
    /// Share / Reveal in Finder, which route through `FileProviderFacade`'s
    /// `getUserVisibleURL`. Multi-window means the shared `activeWikiID` is
    /// last-activate-wins, so passing the session's explicit `wikiID` here is
    /// required to reach the correct FP extension (issue #672).
    let wikiID: String
    let runIngest: (PageID) -> Void
    /// Shared launcher — used by the standalone `runExtraction` to take the
    /// extraction slot (so a standalone extract and an ingest-path extract serialize
    /// against each other) and to mirror this file's id into `extractingSourceIDs`
    /// so the sidebar row labels it "Extracting…".
    let launcher: AgentLauncher
    /// Resolves the selected extraction backend (local pdf2md / Claude / Docling
    /// Serve) for the standalone Extract button.
    let extractionCoordinator: ExtractionCoordinator
    let queueEngine: QueueEngine
    let extractionProvider: any QueueExtractionProvider
    let fileProvider: FileProviderFacade
    @Bindable var store: WikiStoreModel

    @AppStorage("editor.zoom") private var editorZoom = Double(ZoomScale.defaultScale)
    @AppStorage("reader.zoom") private var readerZoom = Double(ZoomScale.defaultScale)
    @AppStorage("isOutlineExpanded") private var isOutlineExpanded = false
    /// Per-view collapse state for the header. Starts collapsed; persists
    /// across same-type tab switches (SwiftUI keeps the view alive).
    @State private var isHeaderExpanded = false
    @State private var headVersion: SourceMarkdownVersion?
    @State private var origin: SourceOrigin?
    @State private var isEditing = false
    @State private var editBuffer = ""
    /// Pending scroll-to-heading for the editor (outline click while editing).
    @State private var editorScrollRequest: EditorScrollRequest?
    /// Caret position in the editor, for outline cursor tracking (issue #268).
    @State private var caretCharIndex: Int?
    @State private var isExtracting = false
    /// True while a source refresh (re-fetch via provider) is in flight.
    @State private var isRefreshing = false
    /// Set when a refresh fails — surfaced inline below the action row.
    @State private var refreshError: String?
    /// Whether THIS source can actually be refreshed — the authoritative gate
    /// from `store.isSourceRefreshable(for:)` (mirrors the refresh service's real
    /// decision, incl. the snapshot-with-images guard and podcast-helper
    /// availability). Loaded per-file alongside `origin` so `body` stays free of
    /// DB/filesystem probes.
    @State private var isRefreshable = false
    /// Tracks the active tab ID as of the last resolved update cycle — used to
    /// distinguish tab switches from in-tab file navigation.
    @State private var lastKnownActiveTabID: UUID? = nil
    /// Set when a tab switch targets a tab that was in edit mode but whose
    /// headVersion has not yet loaded. Cleared once headVersion arrives or
    /// the user navigates to a different file.
    @State private var shouldRestoreEditing = false
    /// Raised when the user taps Ingest on a document that has already been
    /// ingested — prompts before re-ingesting, since that may create duplicate
    /// pages. (Replaces the old always-on "already ingested" warning banner.)
    @State private var showReingestConfirmation = false
    @State private var selectedTab = FileContentTab.reader
    /// Quote to highlight in the PDF view, set when a `[[source:Name#"…"]]` link
    /// targets an un-extracted PDF. Consumed from `store.pendingScrollAnchor`.
    @State private var pdfQuote: String?
    /// Phase 6: the pinned extraction to render instead of HEAD, set when a
    /// `[[source:X@v3#"quote"]]` link is clicked. The quote lives in v3's
    /// extraction; rendering it (not HEAD) means the highlighter finds the quote
    /// even after the source is reprocessed (HEAD moves, v3 stays). Transient:
    /// cleared on navigation away (returns to HEAD).
    @State private var pinnedExtraction: SourceMarkdownVersion?
    /// Opens the Compare Extractions window (value-driven `WindowGroup`).
    @Environment(\.openWindow) private var openWindow

    // Find bar state. Shared via environment (see `ContentView`) so the address
    // bar's "Find on Page…" menu item and Cmd+F drive the same model (#157).
    @Environment(FindModel.self) private var findModel
    @State private var findVersion = 0

    private enum FileContentTab: String, CaseIterable {
        case reader = "Reader"
        case pdf = "PDF"
        /// The original HTML rendered in a WKWebView — the "HTML" tab for HTML
        /// sources (issue #599). Mirrors the PDF tab: the original document
        /// rendered faithfully alongside the Reader (extracted markdown) tab.
        case html = "HTML"
        /// The rendered Mermaid diagram (inline SVG). Only shown for Mermaid
        /// sources (`.mmd` or markdown containing a ```mermaid block); the raw
        /// value is the picker label.
        case rendered = "Rendered"
        /// The embedded media player pane — covers both video (YouTube/Vimeo/
        /// direct-remote `<video>`) and audio (Apple Podcasts/Spotify/
        /// SoundCloud/direct-remote `<audio>`). The picker label is dynamic
        /// ("Video"/"Audio"/"Media"); the raw value is the generic fallback.
        case media = "Media"
        case split = "Split"
    }

    // MARK: - Computed

    private var isMarkdownNative: Bool {
        if let mime = file.mimeType { return MimeType.isText(mime) }
        return false
    }

    private var isPDF: Bool { MimeType.isPDF(file.mimeType) }

    /// `true` for sources whose original bytes are HTML (issue #599). Detects
    /// the canonical HTML MIME types (text/html, application/xhtml+xml) and the
    /// `.html`/`.htm`/`.xhtml` extensions. A source whose original HTML was
    /// discarded by the pre-#599 ingest path (stored as markdown with format
    /// `.htmlConverted`) does NOT match here — it has a markdown MIME and no
    /// HTML extension — so it stays in the markdown-only path with no HTML tab,
    /// matching the "no migration needed" rule in the issue.
    private var isHTMLSource: Bool {
        if let mime = file.mimeType {
            return mime == MimeType.html || mime == MimeType.xhtml
        }
        let ext = file.ext.lowercased()
        return ext == "html" || ext == "htm" || ext == "xhtml"
    }

    /// The source's original HTML bytes, decoded as text. Used by the HTML tab
    /// (the WKWebView renders them verbatim). Returns `nil` when the source
    /// isn't HTML or the bytes couldn't be decoded.
    private var htmlSourceString: String? {
        guard isHTMLSource, let data = store.sourceBytes(id: file.id) else { return nil }
        return String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)  // lossy, never nil
    }

    private var hasMarkdown: Bool { headVersion != nil }

    /// Whether this source should expose the Mermaid diagram tabs
    /// (Reader / Rendered / Split). Detection is content-aware: a standalone
    /// `.mmd` file or a `text/mermaid` source is always a Mermaid source, and a
    /// markdown document carrying a fenced ` ```mermaid ` block becomes one once
    /// its content loads. See `MermaidSourceDetector` (pure + unit-tested).
    private var isMermaidSource: Bool {
        MermaidSourceDetector.isMermaidSource(
            mimeType: file.mimeType,
            filename: file.filename,
            content: currentMarkdownContent)
    }

    /// Mirrors `WikiStoreModel.canIngest` — the single "can this source be
    /// ingested?" rule shared with the sources outline context menu and the
    /// `enqueueIngestion` chokepoint. A source is ingestible iff it has a
    /// processed-markdown version (`hasMarkdown`) **or** raw bytes
    /// (`byteSize > 0`) the staging path hands the agent directly. Gating the
    /// Ingest button on `hasMarkdown` alone greyed it for a not-yet-extracted
    /// PDF (raw bytes present, no markdown) while the context menu stayed
    /// enabled — a state mismatch, since the row also showed "Ready to ingest".
    /// Computed from already-loaded `headVersion` (reactive) rather than a DB
    /// read in the body; `byteSize > 0` covers byteful sources on first render.
    private var canIngest: Bool {
        hasMarkdown || file.byteSize > 0
    }

    /// The byteless-embed descriptor for THIS source, built from the loaded
    /// origin + the source mime — so `ExternalEmbed` can resolve an iframe
    /// target without the full reader's embed-info precompute. `nil` when the
    /// source is not a byteless provider/direct-remote embed (or its origin
    /// hasn't loaded yet). Issue #572.
    private var embedDescriptor: SourceEmbedDescriptor? {
        guard let mime = file.mimeType, let origin else { return nil }
        return SourceEmbedDescriptor(
            id: file.id,
            mimeType: mime,
            externalIdentity: origin.externalIdentity,
            agentName: origin.agentName,
            planURL: origin.plan)
    }

    /// The resolved embed target for this source, or `nil` when it is not a
    /// renderable external embed. Drives the dedicated player section in the
    /// detail view so byteless video sources surface the player above their
    /// transcript (the transcript markdown has no embed directive, so the
    /// inline reader path never emits the iframe here).
    private var embedTarget: EmbedTarget? {
        guard let descriptor = embedDescriptor else { return nil }
        return ExternalEmbed.target(for: descriptor)
    }

    /// `true` when this source should render the embed-player + transcript
    /// layout (a byteless provider video/audio, or direct-remote media) rather
    /// than the PDF/markdown/binary branches.
    private var isBytelessEmbedWithPlayer: Bool { embedTarget != nil }

    /// The dynamic label for the media tab — "Video" / "Audio" / "Media" —
    /// derived from the embed descriptor's classification (audio vs video via
    /// MIME prefix or `agentName`, with Apple Podcasts → Audio). Falls back to
    /// "Media" before the origin loads; the picker only renders once the embed
    /// resolves (`availableTabs` gates on `isBytelessEmbedWithPlayer`), so the
    /// fallback is never user-visible in practice.
    private var mediaTabLabel: String {
        guard let descriptor = embedDescriptor,
              let label = ExternalEmbed.mediaTabLabel(for: descriptor) else {
            return FileContentTab.media.rawValue
        }
        return label
    }

    /// Per-tab label for the picker. Most tabs use their `rawValue`; the media
    /// tab's label is dynamic ("Video"/"Audio"/"Media") per the source kind.
    private func tabLabel(for tab: FileContentTab) -> String {
        tab == .media ? mediaTabLabel : tab.rawValue
    }

    /// Phase 6: consume a pending pinned-extraction id (if any) for the current
    /// source and load that extraction into `pinnedExtraction`. Called from
    /// `.onAppear` so the pinned DOM is ready before the body first evaluates.
    /// Does NOT clear on nil — the `.onChange(of: pendingScrollAnchorVersion)`
    /// handler owns the clear (so a `.task(id: file.id)` re-fire can't clobber a
    /// pin consumed synchronously by `.onChange`).
    private func consumePinnedExtraction() {
        if let pinID = store.consumePendingPinnedExtraction(for: store.selection) {
            pinnedExtraction = store.processedMarkdownVersion(for: pinID)
        }
    }

    /// The tabs applicable to this source. PDFs with extracted markdown show
    /// Reader / PDF / Split (the classic three-way). Byteless media embeds
    /// (YouTube/Vimeo/Spotify/SoundCloud/Apple Podcasts/direct-remote audio &
    /// video) show Reader (the transcript) / Media (the player) / Split (both
    /// side-by-side); a media source without a transcript drops Split (nothing
    /// to split) but keeps Reader so the "no transcript" placeholder is
    /// discoverable. Empty for a PDF with no extraction yet — that branch
    /// renders the bare PDF with no picker.
    ///
    /// Issue #599: HTML sources with extracted markdown show Reader (markdown)
    /// / HTML (rendered WKWebView) / Split (both) — mirrors the PDF three-way
    /// so HTML is treated like a PDF (original bytes preserved + extracted
    /// markdown alongside). An HTML source whose extracted markdown didn't
    /// land (e.g. a conversion failure on a fresh ingest) still shows the
    /// Reader / HTML pair via the `hasMarkdown || isHTMLSource` gate so the
    /// user can see something on each tab.
    private var availableTabs: [FileContentTab] {
        if isBytelessEmbedWithPlayer {
            var tabs: [FileContentTab] = [.reader, .media]
            if hasMarkdown { tabs.append(.split) }
            return tabs
        }
        if isPDF && hasMarkdown {
            return [.reader, .pdf, .split]
        }
        // An HTML source with extracted markdown (or at minimum HTML bytes to
        // show on the HTML tab): Reader (markdown) ⇄ HTML (rendered) ⇄ Split
        // (both). Checked after PDF so a PDF whose extracted text happens to
        // be HTML stays a PDF; checked before Mermaid so a `.mmd` source stays
        // on the Mermaid three-way.
        if isHTMLSource && (hasMarkdown || htmlSourceString != nil) {
            return hasMarkdown ? [.reader, .html, .split] : [.html]
        }
        // A Mermaid source (standalone `.mmd` / `text/mermaid`, or markdown
        // carrying a fenced ```mermaid block): Reader (raw source) ⇄ Rendered
        // (the SVG diagram) ⇄ Split (both). Checked after PDF so a PDF whose
        // extracted text happens to mention mermaid stays a PDF.
        if isMermaidSource {
            return [.reader, .rendered, .split]
        }
        return []
    }

    private var showTabs: Bool { !availableTabs.isEmpty }

    /// A PDF with no markdown derivation yet — the gate for the prominent
    /// "Extract" call-to-action. Also the exclusivity guard for the source's
    /// single "act on this source's content" affordance: an unextracted PDF
    /// shows Extract, so Refresh is suppressed until it has a derivation
    /// (one affordance per source).
    private var needsExtraction: Bool { isPDF && !hasMarkdown }

    /// `true` when this source has ≥2 extraction alternatives — the gate for the
    /// "Compare Extractions…" button (compare is meaningless with one).
    private var hasMultipleExtractions: Bool {
        store.processedMarkdownHistory(for: file.id).count >= 2
    }

    private var isMarkdownEditable: Bool {
        isMarkdownNative || hasMarkdown
    }

    /// `true` when this source is a STANDALONE Mermaid diagram (`.mmd` /
    /// `text/mermaid` / `text/x-mermaid`) — as opposed to a markdown document
    /// that merely CONTAINS a fenced ```mermaid block. The outline parses
    /// markdown headings, which a pure diagram source has none of; suppress
    /// the outline sidebar and its toggle for these sources (issue #642).
    /// Uses mime + extension (not a content scan) so it's stable before the
    /// raw bytes load.
    private var isPureMermaidSource: Bool {
        if MimeType.isMermaid(file.mimeType) { return true }
        let ext = file.ext.lowercased()
        return ext == MermaidSourceDetector.mermaidExtension || ext == "mermaid"
    }

    /// `true` when the outline sidebar is meaningful for this source: there's
    /// markdown content AND it isn't a pure Mermaid diagram. Gates both the
    /// outline pane and its toggle button so a `.mmd` source never shows a
    /// useless empty outline (and never gets stuck with the pane open and no
    /// way to close it — `isOutlineExpanded` is global `@AppStorage`, so
    /// without this guard it leaks from a previous markdown source).
    /// Issue #642.
    private var isOutlineApplicable: Bool {
        !isPureMermaidSource && isMarkdownEditable
    }

    private var displayName: String {
        let name = file.effectiveName
        return name.isEmpty ? "Untitled" : name
    }

    /// The markdown content currently shown (from processed head or native
    /// markdown source). Used as the find bar's search content.
    private var currentMarkdownContent: String? {
        if isEditing { return editBuffer }
        if let head = headVersion { return pinnedExtraction?.content ?? head.content }
        // Issue #599: HTML sources preserve the original HTML bytes as the
        // source blob — the markdown lives in a processed-markdown version
        // (headVersion, above). Don't fall through to `sourceBytes` for HTML
        // sources — the raw bytes are HTML, not markdown, and rendering them
        // as markdown would show raw `<html>` tags. The Reader tab falls back
        // to its "No Processed Markdown" placeholder until headVersion loads.
        if isHTMLSource { return nil }
        if isMarkdownNative, let data = store.sourceBytes(id: file.id) {
            return String(data: data, encoding: .utf8)
        }
        // #620: defense-in-depth — when a Mermaid-detected source arrives
        // without a text MIME (e.g. a pre-existing NULL-mime `.mmd` row from
        // before the `addSource` extension fallback, or any future ingest path
        // that bypasses it), still surface the raw diagram bytes so the Reader
        // and Rendered tabs render instead of empty states. Calls the static
        // detector with `content: nil` (mime+filename arms only) — NOT the
        // `isMermaidSource` computed property, which reads this same property
        // and would recurse. The content-scan arm is irrelevant here: this
        // branch is only reached when `isMarkdownNative` is false, and a
        // fenced-block-only source (no `.mmd`, no `text/mermaid` mime) already
        // had nowhere to read its bytes from before #620.
        if MermaidSourceDetector.isMermaidSource(
               mimeType: file.mimeType, filename: file.filename, content: nil),
           let data = store.sourceBytes(id: file.id) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private var findText: String? {
        guard findModel.isShowing,
              let content = findModel.content,
              findModel.currentMatchIndex > 0,
              findModel.currentMatchIndex <= findModel.matches.count
        else { return nil }
        let range = findModel.matches[findModel.currentMatchIndex - 1]
        return String(content[range])
    }

    /// 1-based current match index, forwarded to the reader so next/previous
    /// navigation targets distinct occurrences instead of always the first.
    private var findOccurrence: Int { findModel.currentMatchIndex }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            if showTabs, !isEditing {
                tabPicker
            }
            Divider().opacity(PageEditorMetrics.dividerOpacity)
            contentAndOutline
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            headVersion = store.processedMarkdownHead(for: file)
            origin = store.sourceOrigin(for: file.id)
            isRefreshable = store.isSourceRefreshable(for: file.id)
            lastKnownActiveTabID = store.activeTabID
            consumePinnedExtraction()
        }
        .onChange(of: file.id) {
            // Navigating between ingested files REUSES this view instance (same
            // type/position), so SwiftUI preserves `@State` across the switch.
            // Reset every per-file @State here — including `isExtracting`, which
            // otherwise leaks A's "Extracting…" flag onto B's header. The header
            // spinner is additionally driven off the per-file `isThisFileExtracting`
            // launcher flag below, so it can never survive a navigation.
            flushEditIfDirty()
            isEditing = false
            isExtracting = false
            isRefreshing = false
            refreshError = nil
            showReingestConfirmation = false
            headVersion = nil
            origin = nil
            isRefreshable = false
            selectedTab = .reader
            pdfQuote = nil
            pinnedExtraction = nil
            // Cancel any pending edit-mode restoration so it doesn't apply to
            // the new file when its headVersion loads.
            shouldRestoreEditing = false
        }
        .task(id: file.id) {
            headVersion = store.processedMarkdownHead(for: file)
            origin = store.sourceOrigin(for: file.id)
            isRefreshable = store.isSourceRefreshable(for: file.id)
        }
        .task(id: PDFTaskKey(sourceID: file.id, anchorVersion: store.pendingScrollAnchorVersion)) {
            // Only consume for un-extracted PDFs (the markdown side handles
            // extracted PDFs via WikiReaderView). Double-check at consume time
            // since `hasMarkdown` may have changed since render.
            guard isPDF, !hasMarkdown else { return }
            if let frag = store.consumePendingScrollAnchor(for: store.selection) {
                pdfQuote = frag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        // Phase 6: consume the pinned-extraction id on every navigation cycle
        // (fires for new-source navigation AND re-clicks on an already-open
        // source). Clearing on no-pin returns to HEAD; a pinned quote link sets
        // `pinnedExtraction` so the rendered DOM contains the quote.
        .onChange(of: store.pendingScrollAnchorVersion) {
            if let pinID = store.consumePendingPinnedExtraction(for: store.selection) {
                pinnedExtraction = store.processedMarkdownVersion(for: pinID)
            } else {
                pinnedExtraction = nil
            }
        }
        .onChange(of: store.selection) { flushEditIfDirty(); isEditing = false }
        .background { findShortcutButton }
        .overlay(alignment: .top) { findBarOverlay }
        .onChange(of: file.id) { findModel.dismiss() }
        .onChange(of: currentMarkdownContent) { _, newContent in
            findModel.content = newContent
            findModel.search()
        }
        .onChange(of: findModel.isShowing) { _, showing in
            if showing {
                findModel.content = currentMarkdownContent
                findModel.search()
            }
        }
        .onChange(of: findModel.currentMatchIndex) { _, _ in
            guard findModel.currentMatchIndex > 0 else { return }
            findVersion &+= 1
        }
        .onChange(of: store.activeTabID) { _, newID in
            lastKnownActiveTabID = newID
            let tab = store.tabs.first(where: { $0.id == newID })
            guard tab?.isEditing == true else {
                shouldRestoreEditing = false
                return
            }
            // Restore edit mode for the returning tab. If headVersion is already
            // loaded (same file, different tab), restore immediately; otherwise
            // defer until the async load completes.
            if let content = headVersion?.content {
                editBuffer = content
                isEditing = true
            } else {
                shouldRestoreEditing = true
            }
        }
        .onChange(of: headVersion) { _, newVersion in
            guard shouldRestoreEditing, let content = newVersion?.content else { return }
            editBuffer = content
            isEditing = true
            shouldRestoreEditing = false
        }
        .onChange(of: isEditing) { _, newValue in
            if let id = store.activeTabID {
                store.setTabEditing(tabID: id, isEditing: newValue)
            }
            if newValue { isHeaderExpanded = true } // reveal Save/Cancel
            if !newValue { shouldRestoreEditing = false; caretCharIndex = nil }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        CollapsibleDetailHeader(
            systemImage: symbol,
            title: displayName,
            placeholder: "Untitled",
            titleLineLimit: 2,
            isTitleDisabled: isEditLockedExternally,
            isExpanded: $isHeaderExpanded,
            onTitleCommit: { store.renameSource(id: file.id, to: $0) }
        ) {
            VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
                HStack(spacing: 8) {
                Text(Self.sizeFormatter.string(fromByteCount: Int64(file.byteSize)))
                metadataSeparator
                // Compact, single-line dates — "Added Jun 26, 2026 · Updated
                // Jun 28". The exact clock time was noise here (and wrapped);
                // it lives in the version menu where it's actually decided.
                Text("Added \(Self.compactDate(file.createdAt))")
                if file.updatedAt != file.createdAt {
                    Text("· Updated \(Self.compactDate(file.updatedAt))")
                }
                // For non-PDF markdown the origin is plain provenance text here;
                // for PDFs the interactive extraction chip lives on the action
                // row beside Ingest (see below), not in this metadata line.
                if let head = headVersion, !isPDF,
                   let label = Self.markdownOriginLabel(for: head.origin) {
                    metadataSeparator
                    Text("\(label) \(Self.compactDate(head.createdAt))")
                }
                // Zotero provenance sits inline on the metadata line rather than
                // in its own row — the big title already names the item, so this
                // just needs the "Zotero" origin tag + a jump-back link.
                // Two-dimensional label (#644): "Zotero / PDF", "Zotero / Markdown",
                // or just "Zotero" when the content type is unknown.
                if let key = file.zoteroItemKey, !key.isEmpty {
                    metadataSeparator
                    let zoteroLabel = SourceProvenanceLabel.combine(
                        provider: "Zotero", agentName: "zotero",
                        ext: file.ext, mimeType: file.mimeType)
                    if let url = zoteroItemURL(itemKey: key) {
                        // The "Zotero" tag itself is the link — clicking it jumps
                        // back to the item in the Zotero app (no separate button).
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label(zoteroLabel, systemImage: "books.vertical")
                        }
                        .buttonStyle(.link)
                        .help("View in Zotero")
                    } else {
                        Label(zoteroLabel, systemImage: "books.vertical")
                    }
                } else if let origin, origin.agentName != "legacy-import" {
                    // Phase 3a provider origin: website → clickable link to the
                    // origin URL; local-file → "File"; markdown-folder → "Folder".
                    metadataSeparator
                    providerOriginTag(origin)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            VStack(alignment: .leading, spacing: 8) {
                if isEditing {
                    HStack(spacing: 10) {
                        Button("Save Changes", systemImage: "checkmark.circle") {
                            DebugLog.tabs("SourceDetailView: Save Changes tapped")
                            commitEdit()
                        }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(editBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || (headVersion?.content == editBuffer))

                        Button("Cancel", systemImage: "xmark.circle") {
                            DebugLog.tabs("SourceDetailView: Cancel tapped")
                            isEditing = false
                        }
                        .keyboardShortcut(.escape, modifiers: [])

                        if isOutlineApplicable {
                            // Pin save/cancel at the leading edge and the
                            // outline toggle at the trailing edge so the row's
                            // layout is independent of the parent's proposed
                            // width (which changes when the outline pane or
                            // the header expands/collapses).
                            Spacer()
                            Button {
                                DebugLog.tabs("SourceDetailView: Toggle Outline tapped (editing)")
                                isOutlineExpanded.toggle()
                            } label: {
                                Image(systemName: "sidebar.right")
                            }
                            .help("Toggle Outline")
                        }
                    }
                } else {
                    // Row 1 — primary source actions: the extraction chip leads
                    // ("this is the derivation, and here's what you do with it"),
                    // then Ingest, then Extract Markdown when no derivation exists
                    // yet. Above the utility row so the wiki goal reads first.
                    HStack(spacing: 10) {
                        if isPDF, hasMarkdown, let head = headVersion {
                            extractionProvenanceChip(head: head)
                        }
                        if needsExtraction {
                            // No derivation yet → Extract is the call-to-action:
                            // prominent and leftmost, with Ingest stepped down to
                            // secondary until there's markdown worth ingesting.
                            Button(isExtracting ? "Extracting…" : "Extract",
                                   systemImage: "doc.plaintext") {
                                DebugLog.extraction("SourceDetailView: Extract tapped — id=\(file.id.rawValue)")
                                Task {
                                    await runExtraction()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isExtracting
                                      || isThisFileExtracting
                                      // Another file currently holds the extraction
                                      // slot — this extract would await it, so show
                                      // it as busy rather than letting the tap hang.
                                      || tracker.isSlotBusyForOtherSource(file.id))
                        }
                        ingestButton
                        // The source's content affordance is one-per-source: an
                        // unextracted PDF shows Extract (above) to gain a readable
                        // derivation, so Refresh is suppressed until it has one.
                        // Every other refreshable (live) source offers Refresh to
                        // re-fetch and append a new version.
                        if isRefreshable, !needsExtraction {
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                DebugLog.extraction("SourceDetailView: Refresh tapped — id=\(file.id.rawValue)")
                                Task { await runRefresh() }
                            }
                            .disabled(isRefreshing)
                            .help("Re-fetch this source and append a new version")
                        }
                    }
                    // Row 2 — secondary / utility actions: Edit, Show in List,
                    // Share, Reveal in Finder, Outline.
                    HStack(spacing: 10) {
                        if isMarkdownEditable {
                            Button("Edit", systemImage: "pencil") {
                                DebugLog.tabs("SourceDetailView: Edit tapped — id=\(file.id.rawValue)")
                                // Source the buffer from the resolved content so
                                // a native `.mmd` (no processed-markdown head)
                                // edits its raw diagram source, not an empty
                                // buffer. `currentMarkdownContent` falls back to
                                // the raw bytes for native text sources.
                                editBuffer = currentMarkdownContent ?? ""
                                isEditing = true
                                // #211: focus the editor even if the user had
                                // switched to the PDF, HTML, Media, or Rendered
                                // tab, where the markdown editor isn't rendered.
                                // Leave Split alone — the editor is already
                                // visible there.
                                if selectedTab == .pdf || selectedTab == .html || selectedTab == .media || selectedTab == .rendered {
                                    selectedTab = .reader
                                }
                            }
                            .keyboardShortcut("e", modifiers: .command)
                            .disabled(isRunning)
                        }
                        // Share — resolves the canonical URL from the daemon
                        // (like openSource) so the filename is human-readable
                        // and the URL is guaranteed to resolve.
                        Button("Show in List", systemImage: "sidebar.left") {
                            DebugLog.tabs("SourceDetailView: Show in List tapped — id=\(file.id.rawValue)")
                            store.requestSidebarReveal(.source(file.id))
                        }
                        .help("Reveal this source in the sidebar")
                        if fileProvider.path != nil {
                            Button("Share", systemImage: "square.and.arrow.up") {
                                DebugLog.fileprovider("SourceDetailView: Share tapped — id=\(file.id.rawValue)")
                                Task {
                                    guard let url = await fileProvider.resolveSourceByNameURL(id: file.id, wikiID: wikiID) else {
                                        DebugLog.fileprovider("Share source detail: resolveSourceByNameURL returned nil — id=\(file.id.rawValue) wikiID=\(wikiID)")
                                        return
                                    }
                                    DebugLog.fileprovider("Share source detail: \(url.lastPathComponent)")
                                    let picker = NSSharingServicePicker(items: [url])
                                    let mouseScreen = NSEvent.mouseLocation
                                    guard let window = NSApplication.shared.keyWindow,
                                          let contentView = window.contentView else { return }
                                    let windowPoint = window.convertPoint(fromScreen: mouseScreen)
                                    let viewPoint = contentView.convert(windowPoint, from: nil)
                                    picker.show(
                                        relativeTo: NSRect(origin: viewPoint,
                                                           size: NSSize(width: 1, height: 1)),
                                        of: contentView, preferredEdge: .minY)
                                }
                            }
                            .help("Share this source file")
                            Button("Reveal in Finder", systemImage: "folder") {
                                DebugLog.fileprovider("SourceDetailView: Reveal in Finder tapped — id=\(file.id.rawValue)")
                                Task { await fileProvider.revealSourceInFinder(id: file.id, wikiID: wikiID) }
                            }
                            .help("Reveal this source file in Finder")
                        }
                        if isOutlineApplicable {
                            // Pin action buttons at the leading edge and the
                            // outline toggle at the trailing edge (see the
                            // matching comment in the editing branch above).
                            Spacer()
                            Button {
                                DebugLog.tabs("SourceDetailView: Toggle Outline tapped")
                                isOutlineExpanded.toggle()
                            } label: {
                                Image(systemName: "sidebar.right")
                            }
                            .help("Toggle Outline")
                        }
                    }
                }
            }

            if isThisFileExtracting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Extracting…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if isRefreshing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Refreshing…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let refreshError {
                Text(refreshError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            }
        }
        .frame(maxWidth: PageEditorMetrics.readableContentWidth, alignment: .leading)
        .padding(PageEditorMetrics.contentInset)
    }

    // MARK: - Refresh (Phase 3b)

    /// Re-fetch the source via its provider, appending a new version. The
    /// materialization (network fetch) runs off-main inside the service; the
    /// store write + `reloadSources` happen on-main inside `refreshSource`.
    /// On success, reloads the head markdown so the reader updates.
    private func runRefresh() async {
        isRefreshing = true
        refreshError = nil
        defer { isRefreshing = false }
        do {
            _ = try await store.refreshSource(file.id)
            headVersion = store.processedMarkdownHead(for: file)
        } catch SourceRefreshService.RefreshError.notRefreshable(let agent) {
            refreshError = "This \(agent) source can't be refreshed."
        } catch SourceRefreshService.RefreshError.snapshotWithImages {
            refreshError = "This snapshot source includes images; re-snapshotting on refresh is coming soon."
        } catch {
            refreshError = "Refresh failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Zotero origin

    /// Build a `zotero://select` URI that opens the item directly in the Zotero
    /// desktop app. The `select/library/items/<key>` path targets "My Library"
    /// and needs no library ID — perfect for a personal-library workflow.
    private func zoteroItemURL(itemKey: String) -> URL? {
        guard !itemKey.isEmpty else { return nil }
        return URL(string: "zotero://select/library/items/\(itemKey)")
    }

    // MARK: - Provider origin (Phase 3a)

    /// Inline origin tag for non-Zotero providers, shown on the metadata line:
    /// website → a clickable link to the origin URL; apple-podcast → a clickable
    /// link to the episode; markdown-folder → "Folder"; local-file → "File".
    /// Mirrors the inline Zotero tag's styling.
    ///
    /// Two-dimensional labels (issue #644): the File branch becomes
    /// "File / {content type}" (e.g. "File / Mermaid", "File / PDF") since a
    /// drag-drop can carry anything. URL/media providers and markdown folders
    /// imply their content type, so their labels stay single-dimensional.
    @ViewBuilder
    private func providerOriginTag(_ origin: SourceOrigin) -> some View {
        switch origin.agentName {
        case "website":
            let urlString = origin.plan ?? origin.externalRef ?? origin.externalIdentity ?? ""
            if let url = URL(string: urlString), url.scheme != nil {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Website", systemImage: "globe")
                }
                .buttonStyle(.link)
                .help("Open original: \(urlString)")
            } else {
                Label("Website", systemImage: "globe")
            }
        case "markdown-folder":
            Label("Folder", systemImage: "folder")
        case "apple-podcast":
            // Byteless source (a transcript) — link to the episode page, like the
            // website tag. Never "File": a podcast source carries no file bytes.
            let urlString = origin.plan ?? origin.externalRef ?? origin.externalIdentity ?? ""
            if let url = URL(string: urlString), url.scheme != nil {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Apple Podcast", systemImage: "waveform")
                }
                .buttonStyle(.link)
                .help("Open episode: \(urlString)")
            } else {
                Label("Apple Podcast", systemImage: "waveform")
            }
        case "youtube", "vimeo", "spotify", "soundcloud", "remote-media":
            // Phase 4b byteless media providers. The watch/listen URL lives on
            // `origin.plan` (the pasted link, normalized); never "File" — these
            // sources carry no file bytes. (Issue #618.)
            let info = mediaProviderInfo(origin.agentName)
            let urlString = origin.plan ?? origin.externalRef ?? origin.externalIdentity ?? ""
            if let url = URL(string: urlString), url.scheme != nil {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(info.label, systemImage: info.systemImage)
                }
                .buttonStyle(.link)
                .help("\(info.helpVerb): \(urlString)")
            } else {
                Label(info.label, systemImage: info.systemImage)
            }
        default:
            // Local-file (and any unrecognized import provider). Two-dimensional
            // label (#644): "File / Mermaid", "File / PDF", "File / Markdown",
            // or just "File" when the content type is unknown. The provider
            // does not imply a single content type — a drag-drop can carry
            // anything — so the suffix is meaningful here.
            let fileLabel = SourceProvenanceLabel.combine(
                provider: "File", agentName: origin.agentName,
                ext: file.ext, mimeType: file.mimeType)
            Label(fileLabel, systemImage: "doc")
        }
    }

    /// Provider-correct display text, SF Symbol, and tooltip verb for the
    /// Phase 4b byteless media providers (`youtube`/`vimeo`/`spotify`/
    /// `soundcloud`/`remote-media`). Used by `providerOriginTag(_:)`.
    private func mediaProviderInfo(_ agentName: String) -> (label: String, systemImage: String, helpVerb: String) {
        switch agentName {
        case "youtube":      return ("YouTube", "play.rectangle", "Open video")
        case "vimeo":        return ("Vimeo", "play.rectangle", "Open video")
        case "spotify":      return ("Spotify", "music.note", "Open track")
        case "soundcloud":   return ("SoundCloud", "waveform", "Open track")
        case "remote-media": return ("Media", "music.note", "Open media")
        default:             return ("Media", "music.note", "Open media")
        }
    }

    // MARK: - Content + Outline

    /// The content area plus the optional outline sidebar. Extracted from
    /// `body` so the type-checker can resolve each subtree independently.
    ///
    /// The explicit `.frame(maxWidth: .infinity, maxHeight: .infinity,
    /// alignment: .topLeading)` on `contentArea` is load-bearing and mirrors
    /// `PageDetailView`'s `contentAndOutline` shape. Without it, the inner
    /// `WikiReaderView` (an `NSViewRepresentable` wrapping a `WKWebView`)
    /// reports no intrinsic content size and SwiftUI leaves the layout
    /// indeterminate — for pure Mermaid sources, where PR #648's
    /// `isOutlineApplicable` guard also removed the always-present
    /// `PageOutlineView` sibling that previously helped pin the `HStack`'s
    /// vertical extent, the indeterminate layout leaks into the header area.
    /// The header's Show in List / Share / Reveal in Finder buttons render
    /// above, but no longer receive their click. Issue #656.
    @ViewBuilder
    private var contentAndOutline: some View {
        HStack(spacing: 0) {
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // `isOutlineApplicable` excludes pure Mermaid sources (`.mmd` /
            // `text/mermaid`) — the outline parses markdown headings, which a
            // diagram source has none of. Without this guard the pane leaks
            // open from a previous markdown source via the global
            // `@AppStorage("isOutlineExpanded")` flag (issue #642).
            if isOutlineExpanded, isOutlineApplicable, let markdown = currentMarkdownContent {
                outlineView(markdown: markdown)
            }
        }
    }

    private func outlineView(markdown: String) -> some View {
        PageOutlineView(markdown: markdown,
                        caretCharIndex: caretCharIndex) { heading in
            if isEditing {
                editorScrollRequest = EditorScrollRequest(
                    charOffset: heading.charOffset,
                    version: (editorScrollRequest?.version ?? 0) + 1)
            } else {
                store.jumpToAnchorInCurrentSelection(heading.id)
            }
        }
    }

    // MARK: - Content area

    @ViewBuilder
    private var contentArea: some View {
        if showTabs || isBytelessEmbedWithPlayer {
            // Video sources (byteless embeds) route through the same tabbed
            // viewer as PDFs: the transcript renders in the Reader tab, the
            // player in the Video tab, and Split shows both. A video with no
            // transcript has only the Video tab and a Reader placeholder.
            tabbedContent
        } else if isPDF {
            pdfOnlyContent
        } else if isMarkdownNative {
            markdownContent
        } else {
            binaryFallback
        }
    }

    // MARK: Video player (Video tab content)

    /// The byteless embed player as a standalone tab content view. Renders in
    /// the Media tab (and as the player half of Split). Reuses
    /// `MediaEmbedPlayerView` unchanged. When the embed target can't be
    /// resolved, a calm placeholder stands in (mirrors the empty-transcript
    /// copy so the tab is never blank).
    @ViewBuilder
    private var videoPlayerContent: some View {
        if let target = embedTarget {
            MediaEmbedPlayerView(target: target)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(PageEditorMetrics.contentInset)
        } else {
            ContentUnavailableView {
                Label("Player Unavailable", systemImage: "play.slash")
            } description: {
                Text("This media source's embed couldn't be resolved.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Byteless embed placeholder reader

    /// The Reader tab content for a byteless embed with no extracted
    /// transcript. Kept so the tab picker shows a Reader row whose body is a
    /// meaningful empty state rather than a blank reader. Issue #575.
    private var embedEmptyReaderContent: some View {
        ContentUnavailableView {
            Label(embedEmptyLabel, systemImage: "waveform")
        } description: {
            Text(embedEmptyDescription)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The placeholder copy when a byteless embed has no transcript yet.
    private var embedEmptyLabel: String {
        switch origin?.agentName {
        case "youtube": return "No Transcript Available"
        default: return "No Transcript"
        }
    }

    /// The placeholder description; explains why there's no text and that the
    /// player above is the source's content.
    private var embedEmptyDescription: String {
        if origin?.agentName == "youtube" {
            return "This video has no captions, so no transcript was extracted. The player above is the source."
        }
        return "This media source has no extracted text yet. The player above is the source."
    }

    // MARK: View mode picker

    private var tabPicker: some View {
        HStack(spacing: 8) {
            ForEach(availableTabs, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tabLabel(for: tab))
                        .font(.callout)
                        .fontWeight(selectedTab == tab ? .semibold : .regular)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(selectedTab == tab
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, PageEditorMetrics.contentInset)
        .padding(.vertical, 6)
    }

    // MARK: Split Markdown ⇄ companion

    /// Split view: the markdown reader on the left, and the source's primary
    /// visual companion — the PDF for a PDF source, the rendered HTML for an
    /// HTML source (issue #599), or the media player for a byteless embed
    /// (video or audio) — on the right. Only callable when there is markdown
    /// to show on the left (gate by `hasMarkdown` before appending `.split`
    /// to `availableTabs`).
    @ViewBuilder
    private var splitContent: some View {
        HSplitView {
            if isMermaidSource {
                diagramCodeContent
            } else {
                markdownContent
            }
            if isBytelessEmbedWithPlayer {
                videoPlayerContent
            } else if isHTMLSource {
                htmlSourceView
            } else if isMermaidSource {
                renderedMermaidContent
            } else {
                pdfView
            }
        }
    }

    // MARK: Content by selected tab

    @ViewBuilder
    private var tabbedContent: some View {
        switch selectedTab {
        case .reader:
            if isBytelessEmbedWithPlayer, !hasMarkdown {
                embedEmptyReaderContent
            } else if isPureMermaidSource {
                // Diagram source files (`.mmd` / `text/mermaid`) render their
                // raw DSL as a read-only monospace code block — the markdown
                // pipeline parses `flowchart LR` as prose, producing confusing
                // output. The Rendered and Split tabs keep their existing
                // diagram-rendering behavior (issue #662). Embedded-mermaid
                // markdown (`.md` with a ```mermaid block) is gated out by
                // `isPureMermaidSource` so its prose+outline stay intact.
                // Follow-up: extend to `.excalidraw` / `.canvas` once their
                // raw bytes are loaded into `currentMarkdownContent`.
                diagramCodeContent
            } else {
                markdownContent
            }
        case .pdf:
            pdfView
        case .html:
            htmlSourceView
        case .rendered:
            renderedMermaidContent
        case .media:
            videoPlayerContent
        case .split:
            splitContent
        }
    }

    // MARK: HTML source view (issue #599)

    /// The HTML tab (and the right pane of the HTML split view): renders the
    /// source's original HTML bytes in a WKWebView with JavaScript disabled.
    /// Mirrors how the PDF tab renders the original PDF in a `PDFView` —
    /// faithful to the source, no script execution. Falls back to a calm
    /// placeholder when the bytes can't be decoded.
    @ViewBuilder
    private var htmlSourceView: some View {
        if let html = htmlSourceString {
            HTMLSourceWebView(html: html)
        } else {
            ContentUnavailableView {
                Label("Cannot Load HTML", systemImage: "globe")
            } description: {
                Text("The source bytes for this file couldn't be read or decoded as HTML.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Markdown reader / editor

    @ViewBuilder
    private var markdownContent: some View {
        if isEditing {
            ScrollableTextEditor(
                text: $editBuffer,
                font: NSFont.monospacedSystemFont(
                    ofSize: CGFloat(13 * editorZoom), weight: .regular),
                scrollRequest: editorScrollRequest,
                onCaretChange: { caretCharIndex = $0 },
                sidebarDropBuilder: { payloads in
                    SidebarDropBuilder.insertionText(for: payloads, store: store)
                },
                // Issue #680: wiki-link autocomplete in the source markdown
                // editor. Same hooks + search backend as the chat composer
                // (#684) and the page editor (also #680).
                autocomplete: SidebarDropBuilder.wikiLinkAutocompleteHooks(store: store),
                autocompletePlacement: .below
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(PageEditorMetrics.contentInset)
                .zoomShortcuts($editorZoom)
                .zoomScroll($editorZoom)
        } else if let head = headVersion {
            // The web reader is the only reader — it handles all sizes (its
            // windowed layout is faster than the native reader even on small
            // docs, so the size threshold that once gated web-vs-native is gone).
            // Phase 6: when a pinned quote link was clicked, render the pinned
            // extraction's content (where the quote lives) instead of HEAD.
            WikiReaderView(markdown: pinnedExtraction?.content ?? head.content,
                            currentSelection: store.selection,
                            store: store,
                            findText: findText, findVersion: findVersion, findOccurrence: findOccurrence)
                .zoomShortcuts($readerZoom)
                .zoomScroll($readerZoom)
        } else if let content = currentMarkdownContent {
            // A native text source with no processed-markdown head (e.g. a
            // `.mmd` Mermaid diagram) renders its raw bytes as readable text —
            // the source code for a diagram, or the body of a `.txt`. Binary
            // sources never reach here (they hit `binaryFallback`).
            WikiReaderView(markdown: content,
                            currentSelection: store.selection,
                            store: store,
                            findText: findText, findVersion: findVersion, findOccurrence: findOccurrence)
                .zoomShortcuts($readerZoom)
                .zoomScroll($readerZoom)
        } else {
            ContentUnavailableView {
                Label("No Processed Markdown", systemImage: "doc.plaintext")
            } description: {
                Text("This file has no extracted or processed markdown yet.")
            }
        }
    }

    // MARK: PDF-only (no extraction yet)

    private var pdfOnlyContent: some View {
        pdfView
    }

    private var pdfView: some View {
        Group {
            if let data = store.sourceBytes(id: file.id) {
                PDFViewWrapper(data: data, highlightQuote: pdfQuote)
            } else {
                ContentUnavailableView {
                    Label("Cannot Load PDF", systemImage: "doc.richtext")
                } description: {
                    Text("The source bytes for this file could not be read.")
                }
            }
        }
    }

    // MARK: Rendered Mermaid diagram

    /// The "Rendered" tab (and the right pane of the Mermaid split view): draws
    /// the source's Mermaid diagram as inline SVG. A standalone `.mmd` source is
    /// wrapped in a ` ```mermaid ` fence by `MermaidSourceDetector.renderableMarkdown`
    /// so the reader's existing render pipeline (Mermaid 10.9.6 in WKWebView)
    /// picks it up unchanged — no separate web view or JS wiring. Embedded
    /// mermaid markdown passes through as-is so surrounding prose stays intact.
    /// Falls back to a calm placeholder when there's nothing to draw.
    @ViewBuilder
    private var renderedMermaidContent: some View {
        if let content = currentMarkdownContent,
           let renderable = MermaidSourceDetector.renderableMarkdown(from: content) {
            WikiReaderView(markdown: renderable,
                           currentSelection: store.selection,
                           store: store)
                .zoomShortcuts($readerZoom)
                .zoomScroll($readerZoom)
        } else {
            ContentUnavailableView {
                Label("No Diagram", systemImage: "flowchart.fill")
            } description: {
                Text("This source has no Mermaid diagram to render yet.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Diagram source code view (Reader tab for diagram sources)

    /// The Reader-tab content for a STANDALONE diagram source (`.mmd` /
    /// `text/mermaid`): the raw source text rendered as a read-only monospace
    /// code block instead of through the markdown pipeline. Diagram DSLs
    /// confuse the markdown reader — mermaid `flowchart LR` becomes a flat
    /// paragraph, JSON sources flatten to text — so the Reader tab now shows
    /// them as code (matches the existing `<pre><code>` reader styling). The
    /// Edit button still switches to the editor for changes; the Rendered and
    /// Split tabs are unchanged. Issue #662.
    ///
    /// Sibling of `renderedMermaidContent`: that view hands the source to
    /// `MermaidSourceDetector.renderableMarkdown` (a ` ```mermaid ` fence) so
    /// the reader renders the diagram; this one hands it to
    /// `MermaidSourceDetector.codeBlockMarkdown` (a plain code fence) so the
    /// reader displays the source verbatim. Both use `WikiReaderView`, so the
    /// find bar, zoom, and color-scheme theming come for free.
    @ViewBuilder
    private var diagramCodeContent: some View {
        if let content = currentMarkdownContent,
           let codeBlock = MermaidSourceDetector.codeBlockMarkdown(from: content) {
            WikiReaderView(markdown: codeBlock,
                           currentSelection: store.selection,
                           store: store,
                           findText: findText, findVersion: findVersion, findOccurrence: findOccurrence)
                .zoomShortcuts($readerZoom)
                .zoomScroll($readerZoom)
        } else {
            ContentUnavailableView {
                Label("No Source", systemImage: "curlybraces")
            } description: {
                Text("This source's raw content couldn't be loaded.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Extract button


    /// Extraction progress is shown in the transcript sidebar's PDF Conversion
    /// box — the detail view keeps only a minimal Extracting… spinner in the
    /// header. The queue engine's `.progress` events drive the tracker's log.
    private func runExtraction() async {
        isExtracting = true
        defer {
            isExtracting = false
        }

        // Route extraction through the queue engine instead of the old
        // inline slot machinery. The engine handles serialization (local
        // pdf2md limit 1), readiness checks, and progress reporting.
        do {
            let request = QueueItemRequest(
                queue: .extraction, wikiID: store.eventBus?.wikiID ?? "",
                payload: QueueItemPayload(sourceIDs: [file.id]))
            let itemID = try await queueEngine.enqueue(request)
            let result = await queueEngine.waitForCompletion(of: itemID)

            switch result {
            case .success:
                // The worker persisted the markdown; refresh the head version.
                if let head = store.processedMarkdownHead(for: file) {
                    headVersion = head
                }
            case .failure:
                break  // Tracker records the error from queue events
            }
        } catch {
            // Enqueue error — tracker not updated (no queue event). No-op.
        }
    }

    // MARK: - Extraction alternatives (Phase 2)

    /// The provenance line rendered as the single home for extraction
    /// management. Its label reports how the active markdown came to exist and
    /// which backend produced it ("Converted · Claude (Anthropic) ▾"); its menu
    /// folds in what used to be three separate controls — switch the active
    /// alternative, Compare Extractions… (the track-C window), and Re-extract
    /// with another backend. Shown in place of the old inert provenance text.
    @ViewBuilder
    private func extractionProvenanceChip(head: SourceMarkdownVersion) -> some View {
        let names = store.processedMarkdownAgentNames(for: file.id)
        Menu {
            Section("Active extraction") {
                let history = store.processedMarkdownHistory(for: file.id)
                let headID = headVersion?.id.rawValue
                ForEach(history) { version in
                    let agent = names[version.id.rawValue] ?? version.origin.rawValue
                    Button {
                        store.setActiveMarkdown(for: file.id, to: version.id)
                        headVersion = store.processedMarkdownHead(for: file)
                    } label: {
                        Label {
                            Text("\(ExtractionAlternative.backendDisplayName(agentName: agent)) — \(version.createdAt, style: .date)")
                        } icon: {
                            Image(systemName: version.id.rawValue == headID
                                  ? "checkmark.circle.fill" : "doc.text")
                        }
                    }
                }
            }
            Section {
                Button("Compare Extractions…", systemImage: "arrow.left.and.right.square") {
                    openWindow(value: ExtractionCompareContext(
                        sourceID: file.id,
                        filename: file.filename,
                        wikiID: store.eventBus?.wikiID ?? ""))
                }
                .disabled(!hasMultipleExtractions)
                .help(hasMultipleExtractions
                      ? "Compare and switch between extraction alternatives"
                      : "Re-extract with another backend to enable compare")
            }
            Section("Re-extract with") {
                ForEach(ExtractionBackend.allCases, id: \.self) { backend in
                    Button(backend.displayName) {
                        Task {
                            await runReExtraction(with: backend)
                        }
                    }
                    .disabled(isThisFileExtracting
                              || tracker.isSlotBusyForOtherSource(file.id))
                }
            }
        } label: {
            // Label = the active alternative's producer ("Legacy", "Claude
            // (Anthropic)", or "Edited"), no origin verb and no manual chevron —
            // `.borderlessButton` draws its own disclosure arrow.
            Label(Self.activeAlternativeLabel(head: head, agent: names[head.id.rawValue]),
                  systemImage: "doc.on.doc")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch the active extraction, compare alternatives, or re-extract")
    }

    /// Stable, human-facing name for the active markdown alternative. A user
    /// edit reads "Edited", a revert "Reverted", and an extraction its backend
    /// display name — so the chip label describes *which alternative is live*,
    /// not the mutating origin verb.
    private static func activeAlternativeLabel(head: SourceMarkdownVersion, agent: String?) -> String {
        switch head.origin {
        case .user: return "Edited"
        case .revert: return "Reverted"
        default:
            if let agent { return ExtractionAlternative.backendDisplayName(agentName: agent) }
            return "Extraction"
        }
    }

    /// Re-extract the source with a chosen backend, appending a coexisting
    /// alternative (does not clobber the current head). Mirrors `runExtraction`
    /// but always appends via `reExtractMarkdown`.
    private func runReExtraction(with backend: ExtractionBackend) async {
        isExtracting = true
        defer {
            isExtracting = false
        }

        // Route re-extraction through the queue engine with a backend override.
        // The override is passed via stageRouting so the worker resolves the
        // chosen backend instead of the configured default.
        do {
            let request = QueueItemRequest(
                queue: .extraction, wikiID: store.eventBus?.wikiID ?? "",
                payload: QueueItemPayload(
                    sourceIDs: [file.id],
                    stageRouting: [StageRoutingKey.backend.rawValue: backend.rawValue]))
            let itemID = try await queueEngine.enqueue(request)
            let result = await queueEngine.waitForCompletion(of: itemID)

            switch result {
            case .success:
                if let head = store.processedMarkdownHead(for: file) {
                    headVersion = head
                }
            case .failure:
                break  // Tracker records the error from queue events
            }
        } catch {
            // Enqueue error — tracker not updated (no queue event). No-op.
        }
    }

    /// Resolve a concrete extractor for an arbitrary backend from the shared
    /// coordinator's config + secrets. Used by the Re-extract menu so the user
    /// can pick a backend other than the configured default.
    private func extractorFor(backend: ExtractionBackend, config: ExtractionConfig) -> any MarkdownExtractor {
        switch backend {
        case .localPdf2md:
            return extractionCoordinator.current()
        case .acp:
            return extractionCoordinator.current()
        case .anthropic:
            let base = config.anthropicBaseURLOverride.flatMap(URL.init(string:))
                ?? URL(string: ExtractionConfig.defaultAnthropicBaseURL)!
            return AnthropicExtractionClient(
                model: config.anthropicModel,
                apiKey: extractionCoordinator.credentialStore.secret(.anthropicAPIKey) ?? "",
                baseURL: base, fetcher: extractionCoordinator.fetcher)
        case .gemini:
            let base = config.geminiBaseURLOverride.flatMap(URL.init(string:))
                ?? URL(string: ExtractionConfig.defaultGeminiBaseURL)!
            return GeminiExtractionClient(
                model: config.geminiModel,
                apiKey: extractionCoordinator.credentialStore.secret(.geminiAPIKey) ?? "",
                baseURL: base, fetcher: extractionCoordinator.fetcher)
        case .doclingServe:
            return DoclingServeClient(
                endpoint: config.doclingServeEndpoint ?? "",
                apiToken: extractionCoordinator.credentialStore.secret(.doclingServeToken),
                fetcher: extractionCoordinator.fetcher)
        }
    }

    private func modelVersionFor(backend: ExtractionBackend, config: ExtractionConfig) -> String? {
        switch backend {
        case .anthropic: return config.anthropicModel
        case .gemini: return config.geminiModel
        case .acp, .localPdf2md, .doclingServe: return nil
        }
    }

    // MARK: Binary fallback

    private var binaryFallback: some View {
        ContentUnavailableView {
            Label("Raw Source", systemImage: symbol)
        } description: {
            Text("This file is stored verbatim in the wiki. Ingesting asks the agent to read it, create or update wiki pages, refresh index.md, and append log.md.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Edit helpers

    private func commitEdit() {
        let trimmed = editBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { isEditing = false; return }
        if let current = headVersion, trimmed == current.content {
            isEditing = false
            return
        }
        if let version = store.saveProcessedMarkdown(for: file.id, content: trimmed) {
            headVersion = version
        }
        isEditing = false
    }

    private func flushEditIfDirty() {
        guard isEditing else { return }
        let trimmed = editBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current = headVersion, !trimmed.isEmpty, trimmed != current.content {
            if let version = store.saveProcessedMarkdown(for: file.id, content: trimmed) {
                headVersion = version
            }
        }
        isEditing = false
    }

    // MARK: - Shared sub-views

    /// The ingest control now carries the source's ingest *state*, so status and
    /// action are one thing: a not-yet-ingested source shows a prominent
    /// call-to-action; a processed one reads as a green "Ingested" affordance
    /// (still clickable to re-ingest, behind the existing confirmation); mid-run
    /// it shows a spinner. This replaces the separate "Ready to ingest / Processed"
    /// status tag that used to sit in the metadata row.
    @ViewBuilder
    private var ingestButton: some View {
        let button = Button {
            DebugLog.ingest("SourceDetailView: Ingest tapped — id=\(file.id.rawValue)")
            if hasBeenIngested {
                showReingestConfirmation = true
            } else {
                runIngest(file.id)
            }
        } label: {
            if isIngesting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Ingesting…")
                }
            } else if hasBeenIngested {
                Label("Ingested", systemImage: "checkmark.circle.fill")
            } else {
                Label("Ingest into Wiki", systemImage: "text.badge.plus")
            }
        }
        .keyboardShortcut(.return, modifiers: .command)
        // Don't disable during an active ingestion or extraction — the queue
        // engine serializes both (ingestion maxConcurrent=1 per provider;
        // extraction limit 1 for local pdf2md). A second tap just appends to
        // the queue. `isRunning` (the ingest/lint launcher — NOT the separate
        // chat launcher) blocks only when a lint is mid-run with no ingest
        // active, to avoid a launcher preflight refusal; a chat run leaves this
        // launcher idle, so it does not block.
        .disabled((isRunning && !isAnySourceIngesting)
                  || isEditLockedExternally
                  || !canIngest)
        .confirmationDialog(
            "Ingest Again?",
            isPresented: $showReingestConfirmation,
            titleVisibility: .visible
        ) {
            Button("Ingest Again", role: .destructive) {
                runIngest(file.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This document has already been ingested. Running ingest again may create duplicate pages.")
        }

        // Ingested → a calm green "done" affordance. Otherwise prominent when
        // Ingest is a real next step; a source that can't be ingested at all
        // (byteless with no processed markdown — e.g. a video whose transcript
        // never arrived) stays secondary and is disabled above.
        if hasBeenIngested {
            button.tint(.green)
        } else if !canIngest {
            button
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    /// Matches the sidebar's Sources section icon so each source has one
    /// consistent icon everywhere in the app.
    private var symbol: String { ResourceKind.source.systemImageName }

    // MARK: - Find bar

    @ViewBuilder
    private var findBarOverlay: some View {
        if findModel.isShowing {
            VStack(spacing: 0) {
                FindBarView(model: findModel)
                Divider()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var findShortcutButton: some View {
        Button("") { findModel.toggle() }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0).allowsHitTesting(false)
    }

    /// A faint dot separating metadata items, so the row reads as one line of
    /// distinct facts rather than gap-delimited fragments.
    private var metadataSeparator: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    /// Compact, abbreviated date ("Jun 26, 2026") — no clock time, which was
    /// noise in the metadata row and caused it to wrap.
    private static func compactDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    /// Human label for a `SourceMarkdownVersion.origin` value, describing how
    /// the currently-displayed markdown version came to exist. `nil` for
    /// "source" (the as-ingested seed version of a native markdown file,
    /// which the added-date row above already covers) so the row is omitted.
    private static func markdownOriginLabel(for origin: SourceMarkdownOrigin) -> String? {
        switch origin {
        case .extraction: return "Converted"
        case .user: return "Edited"
        case .revert: return "Reverted"
        case .source: return nil
        case .transcript: return nil
        }
    }
}

/// Keys the PDF-only anchor consume task so it re-fires on repeat quote clicks
/// to the same un-extracted PDF (same file, bumped anchor version).
private struct PDFTaskKey: Hashable {
    let sourceID: PageID
    let anchorVersion: Int
}
