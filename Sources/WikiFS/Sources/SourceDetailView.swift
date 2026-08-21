// pattern: Mixed (unavoidable)
// Reason: this SwiftUI detail surface combines view state, user actions, and
// store-backed presentation data at the app boundary.

import SwiftUI
import WikiFSEngine
import WikiFSCore

/// Detail pane for one ingested source file. Shows metadata header + inline
/// content (markdown render, inline PDF, or tabbed Markdown⇄PDF when extraction
/// output exists). Cmd-E flips between reader and editor for processed markdown;
/// source bytes are never modified.
struct SourceDetailView: View {
    @Environment(QueueActivityTracker.self) private var tracker
    @Environment(WindowRightInspectorController.self) private var rightInspector
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
    let wikiID: WikiID
    let runIngest: (SourceID) -> Void
    /// Shared launcher — used by the standalone `runExtraction` to take the
    /// extraction slot (so a standalone extract and an ingest-path extract serialize
    /// against each other) and to mirror this file's id into `extractingSourceIDs`
    /// so the sidebar row labels it "Extracting…".
    let launcher: AgentLauncher
    /// Resolves the selected extraction backend (local pdf2md / Claude / Docling
    /// Serve) for the standalone Extract button.
    let extractionCoordinator: ExtractionCoordinator
    let queueEngine: any QueueEngineClient
    let extractionProvider: any QueueExtractionProvider
    let fileProvider: FileProviderFacade
    @Bindable var store: WikiStoreModel
    /// The app composition root will supply the validated installed-renderer
    /// snapshot. The default has no packages, which keeps Source available when
    /// the machine index is not ready yet.
    let installedRendererFactory: InstalledRendererFactory
    let installedRendererFactoryInputs: InstalledRendererFactory.Inputs

    @AppStorage("editor.zoom") private var editorZoom = Double(ZoomScale.defaultScale)
    @AppStorage("reader.zoom") private var readerZoom = Double(ZoomScale.defaultScale)
    @AppStorage("sourceInspectorTab") private var inspectorTab: InspectorTab = .metadata
    @AppStorage("sourceOutlineWidth") private var outlineWidth: Double = 260
    /// Per-view collapse state for the header. Starts collapsed; persists
    /// across same-type tab switches (SwiftUI keeps the view alive).
    @State private var isHeaderExpanded = false
    @State private var headVersion: SourceMarkdownVersion?
    @State private var origin: SourceOrigin?
    /// Provenance edit history for the inspector's History tab. Loaded via
    /// `.task(id:)` keyed on `file.id`.
    @State private var editHistory: [SourceOrigin] = []
    @State private var metadataState: MetadataHydrationState = .idle
    @State private var isEditing = false
    @State private var editBuffer = ""
    /// Pending scroll-to-heading for the editor (outline click while editing).
    @State private var editorScrollRequest: EditorScrollRequest?
    /// Caret position in the editor, for outline cursor tracking (issue #268).
    @State private var caretCharIndex: Int?
    @State private var isExtracting = false
    /// True while a podcast transcription (re-fetch via the signing-helper
    /// pipeline) is in flight (issue #799 PR4). Sibling of `isExtracting`
    /// (PDF/HTML Extract) and `isRefreshing` (Refresh) — the three gates
    /// stay mutually exclusive in the View-level button rendering (each
    /// button dispatches to exactly one of `runExtraction` /
    /// `runHtmlExtraction` / `runRefresh` / `runTranscription`).
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
    @State private var rendererPresentationLifecycle = RendererPresentationLifecycle(sourceID: SourceID(rawValue: ""))
    /// An installed renderer's terminal session failure is transient. The host
    /// falls back to Source without changing the persisted renderer preference.
    @State private var failedInstalledRendererReference: RendererReference?
    /// Cached once per source lifecycle so body evaluation and editor changes do
    /// not repeatedly synchronously fetch the complete SQLite blob.
    @State private var sourceBytesSnapshot: Data?
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

    /// Opens the Activity (queue) window for a specific queue kind — injected
    /// from the environment (#745, #842 PR2). Used by the Transcribe button to
    /// navigate to the running transcription job when one is in flight for
    /// this source (#842 PR2 C5).
    @Environment(\.openActivityWindow) private var openActivityWindow

    // Find bar state. Shared via environment (see `ContentView`) so the address
    // bar's "Find on Page…" menu item and Cmd+F drive the same model (#157).
    @Environment(FindModel.self) private var findModel
    @State private var findVersion = 0

    // MARK: - Computed

    private var isMarkdownNative: Bool {
        if let mime = file.mimeType { return MimeType.isText(mime) }
        return false
    }

    /// A PDF quote anchor is consumed only before a markdown extraction exists.
    private var requiresPDFQuoteAnchor: Bool { MimeType.isPDF(file.mimeType) }

    /// The source's resolved `ContentKind` — the registry classification for
    /// this source's MIME + provider + extension. PR2 (§5.4): the Extract /
    /// Transcribe button gating switches on this kind's `capabilities` rather
    /// than re-deriving the PDF/HTML/transcript decision ad-hoc. Kept `private`
    /// to the view; tests exercise the same `resolve(mimeType:provider:ext:)`
    /// call via the `internal static` seam (`SourceDetailView.extractionDecision`,
    /// below).
    private var contentKind: ContentKind {
        ContentKind.resolve(
            mimeType: file.mimeType,
            provider: origin?.provider,
            ext: file.ext)
    }

    private var hasMarkdown: Bool { headVersion != nil }

    private var rendererDescriptors: [RendererDescriptor] {
        do {
            let planner = try rendererPlanner()
            return try planner.matchingDescriptors(
                for: file,
                boundedBytes: sourceBytesSnapshot,
                currentMarkdown: currentMarkdownContent,
                origin: origin)
        } catch {
            DebugLog.tabs("SourceDetailView: renderer planning failed (source=\(file.id.rawValue)): \(error)")
            return []
        }
    }

    private var rendererPresentationBinding: Binding<RendererPresentationState> {
        Binding(
            get: { rendererPresentationLifecycle.state },
            set: { rendererPresentationLifecycle.replaceState($0) })
    }

    private var rendererFactoryInputs: BuiltInRendererFactoryInputs {
        let bytes = sourceBytesSnapshot
        return BuiltInRendererFactoryInputs(
            sourceBytes: bytes,
            pdfQuote: pdfQuote,
            htmlSource: SourceRendererPresentationPlanner.htmlSourceString(for: file, bytes: bytes),
            mermaidMarkdown: SourceRendererPresentationPlanner.renderableMermaidMarkdown(currentMarkdownContent),
            mediaTarget: SourceRendererPresentationPlanner.mediaTarget(for: file, origin: origin),
            selection: store.selection,
            store: store,
            readerZoom: $readerZoom)
    }

    private var rendererAuthorizedInputResolver: any RendererAuthorizedInputResolving { store }

    private var showsSourceOutlineTab: Bool {
        isOutlineApplicable && currentMarkdownContent != nil
    }

    private var sourceInspectorTabs: [InspectorTab] {
        InspectorTab.sourceAvailableTabs(hasOutline: showsSourceOutlineTab)
    }

    /// `true` for byteless Apple Podcasts embed sources (issue #799 PR4).
    /// Detects via the loaded `origin`'s provider — the byteless-source
    /// synthetic MIME (`audio/apple-podcast`) is also a tell, but
    /// `origin.provider` is the single source of truth (matches how
    /// `isSourceRefreshable` gates the existing Refresh button). Returns
    /// `false` until `origin` loads, so the predicate is re-evaluated when
    /// `.task(id: file.id)` finishes loading origin — same shape as
    /// `isRefreshable`.
    private var isPodcastEmbed: Bool { origin?.provider == .applePodcast }

    /// `true` for byteless YouTube embed sources (issue #799 PR5). Mirrors
    /// `isPodcastEmbed` — `origin.provider` is the single source of truth.
    /// Returns `false` until `origin` loads, same shape as `isRefreshable`.
    private var isYouTubeEmbed: Bool { origin?.provider == .youtube }

    /// True while a transcription queue job is running for this source (C5:
    /// replaces the old `@State isTranscribing` with a computed property
    /// derived from the activity tracker's `transcribingSourceIDs`). Drives
    /// the Transcribe button's disabled state + "Transcribing…" label, so
    /// re-clicks are prevented while a job is in flight (#842).
    private var isTranscribing: Bool { tracker.isTranscribing(sourceID: file.id) }

    /// `true` when this source can be transcribed right now — the single
    /// source of truth for the Transcribe button's enable state (issue #799
    /// PR4 AC.16, generalized to YouTube in PR5). The registry half of the
    /// gate (PR2 §5.4) consults `contentKind.capabilities.hasTranscriptBackend`
    /// (true only for `.podcastTranscript` / `.youtubeTranscript`), then
    /// runtime guards layer on top: the podcast runtime guard (bundled
    /// signing helper present AND this build compiles podcast support via
    /// `#if PODCAST_TRANSCRIPTS`) delegates to
    /// `store.isSourceRefreshable(for:)` so the predicate is identical to
    /// the Refresh button's guard for podcasts. YouTube and generic RSS need
    /// no signing helper, so they're always "available" once the provider
    /// matches (the model throws `.missingPlan` when the ID is missing,
    /// surfaced by `runTranscription`).
    private var isTranscribable: Bool {
        guard contentKind.capabilities.hasTranscriptBackend else { return false }
        switch origin?.provider {
        case .applePodcast:
            // Mirror the Refresh button's runtime guard (helper present +
            // build compiles podcast support). The predicate returns `false`
            // for `.applePodcast` outside `#if PODCAST_TRANSCRIPTS` or when
            // `ApplePodcastTranscriptService.bundled()` is nil.
            return store.isSourceRefreshable(for: file.id)
        case .podcast:
            // Generic RSS-feed podcast: always transcribable on every build —
            // the `podcast-transcript` script needs only `uv` (no signing
            // helper). Mirrors YouTube's "no runtime guard" shape.
            return true
        case .youtube:
            // No signing helper needed — YouTube's pure-Swift scrape is always
            // available on every build. The model throws `.missingPlan` if
            // `origin.externalIdentity` is missing (a data-integrity edge case
            // surfaced by `runTranscription`, not gated here).
            return true
        // Unreachable when `hasTranscriptBackend == true` (the registry
        // resolves `.applePodcast` / `.podcast` / `.youtube` providers to
        // transcript kinds and every other provider to a non-transcript
        // kind). The switch stays exhaustive so a future transcript-capable
        // provider is automatically flagged by the compiler.
        case .vimeo, .spotify, .soundcloud, .remoteMedia,
             .localFile, .website, .zotero, .markdownFolder, .legacyImport, .none:
            return false
        }
    }

    /// A transcribable source with no transcript yet — the gate for the
    /// prominent "Transcribe" call-to-action (issue #799 PR4, generalized to
    /// YouTube in PR5). Analog of `needsExtraction` for PDF/HTML sources.
    /// Exclusivity guarded: a podcast/YouTube source with no transcript shows
    /// Transcribe (NOT Refresh — there's nothing to refresh yet); once a
    /// transcript exists, the provenance chip + Re-transcribe menu take over
    /// (and Refresh is offered when `isRefreshable && !needsExtraction` — the
    /// existing gate).
    private var needsTranscription: Bool { isTranscribable && !hasMarkdown }

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

    /// `true` when this source's content type has a file-extraction backend
    /// — the gate for the Extract button and the Re-extract menu. PR2 §5.4:
    /// migrated from ad-hoc format checks (which already encoded the same
    /// intent ad-hoc) onto the registry's `hasFileExtractionBackend`
    /// (`extractionPath == .pdfBackend || .htmlToMarkdown`). Stays PDF/HTML
    /// only — podcast / YouTube transcript kinds have
    /// `canExtractToMarkdown == true` too, but their affordance is the
    /// Transcribe button (`isTranscribable`, gated on
    /// `hasTranscriptBackend`). The two are mutually exclusive per kind, so
    /// `needsExtraction` and `needsTranscription` never both become `true`
    /// for the same source — the UI shows one prominent button per source.
    ///
    /// Text/binary/byteless sources skip extraction entirely (their
    /// `extractionPath == nil`). PDF and HTML byte sources both resolve to a kind with a
    /// file-extraction backend via `ContentKind.resolve` — the registry's
    /// MIME + ext path matches the same MIME/extension checks the old
    /// predicate did.
    private var isExtractable: Bool {
        contentKind.capabilities.hasFileExtractionBackend
    }

    /// `true` when this source's content type has a provenance chip — the gate
    /// for `extractionProvenanceChip(head:)` rendering above the action row
    /// (issue #799 PR2). Widened in PR4 to include transcribable podcast
    /// sources (a podcast source WITH a transcript shows the chip so the
    /// Re-transcribe with menu is reachable). Mirrors `isExtractable` for
    /// HTML/PDF; adds `isTranscribable` for podcasts.
    private var hasExtractionChip: Bool {
        (isExtractable || isTranscribable) && hasMarkdown
    }

    /// An extractable source with no markdown derivation yet — the gate for
    /// the prominent "Extract" call-to-action. Also the exclusivity guard for
    /// the source's single "act on this source's content" affordance: an
    /// unextracted PDF or HTML source shows Extract, so Refresh is suppressed
    /// until it has a derivation (one affordance per source). PR2: relies on
    /// `isExtractable`'s registry-backed gate (no shape change to this
    /// predicate).
    private var needsExtraction: Bool { isExtractable && !hasMarkdown }

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

    /// JSON Canvas exposes its own spatial outline inside the native renderer.
    /// Do not show an empty Markdown-heading outline beside it.
    private var isPureJSONCanvasSource: Bool {
        file.ext.lowercased() == "canvas"
    }

    /// `true` when the outline sidebar is meaningful for this source: there's
    /// markdown content AND it isn't a pure Mermaid diagram. Gates both the
    /// outline pane and its toggle button so a `.mmd` source never shows a
    /// useless empty outline (and never gets stuck with the pane open and no
    /// way to close it — `isOutlineExpanded` is persisted `@AppStorage`, so
    /// without this guard it leaks from a previous markdown source).
    /// Issue #642.
    private var isOutlineApplicable: Bool {
        !isPureMermaidSource && !isPureJSONCanvasSource && isMarkdownEditable
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
        if SourceRendererPresentationPlanner.isHTMLSource(file) {
            return nil
        }
        if isMarkdownNative, let data = sourceBytesSnapshot {
            return String(data: data, encoding: .utf8)
        }
        if SourceRendererPresentationPlanner.standaloneDiagramSource(file),
           let data = sourceBytesSnapshot {
            return String(data: data, encoding: .utf8)
        }
        // #620: defense-in-depth — when a Mermaid-detected source arrives
        // without a text MIME (e.g. a pre-existing NULL-mime `.mmd` row from
        // before the `addSource` extension fallback, or any future ingest path
        // that bypasses it), still surface the raw diagram bytes so the Reader
        // and Rendered tabs render instead of empty states. Calls the static
        // detector with `content: nil` (mime+filename arms only) — NOT the
        // renderer matcher, which reads this same property and would recurse.
        // The content-scan arm is irrelevant here: this
        // branch is only reached when `isMarkdownNative` is false, and a
        // fenced-block-only source (no `.mmd`, no `text/mermaid` mime) already
        // had nowhere to read its bytes from before #620.
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
            Divider().opacity(PageEditorMetrics.dividerOpacity)
            contentAndOutline
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        // Keep the reader column from collapsing when the window-owned trailing
        // inspector claims its persisted width. Matches PageDetailView and
        // ChatDetailView's minimum detail-column contract.
        .frame(minWidth: PageEditorMetrics.detailMinWidth)
        .onAppear {
            refreshSourceBytesSnapshot()
            headVersion = store.processedMarkdownHead(for: file)
            origin = store.sourceOrigin(for: file.id)
            editHistory = store.sourceEditHistory(for: file.id)
            isRefreshable = store.isSourceRefreshable(for: file.id)
            lastKnownActiveTabID = store.activeTabID
            resolveRendererPresentation()
            consumePinnedExtraction()
            updateRightSidebarRegistration()
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
            editHistory = []
            isRefreshable = false
            sourceBytesSnapshot = nil
            beginRendererPresentationLoading()
            pdfQuote = nil
            pinnedExtraction = nil
            // Cancel any pending edit-mode restoration so it doesn't apply to
            // the new file when its headVersion loads.
            shouldRestoreEditing = false
        }
        .task(id: file.id) {
            refreshSourceBytesSnapshot()
            headVersion = store.processedMarkdownHead(for: file)
            origin = store.sourceOrigin(for: file.id)
            editHistory = store.sourceEditHistory(for: file.id)
            isRefreshable = store.isSourceRefreshable(for: file.id)
            resolveRendererPresentation()
            updateRightSidebarRegistration()
        }
        .task(id: MetadataHydrationKey.source(file.id, store.messageVersion)) {
            await hydrateMetadata(sourceID: file.id)
        }
        .task(id: "\(file.id.rawValue)-\(showsSourceOutlineTab)") {
            let normalized = InspectorTab.normalize(selection: inspectorTab, availableTabs: sourceInspectorTabs)
            guard normalized != inspectorTab else { return }
            inspectorTab = normalized
            updateRightSidebarRegistration()
        }
        .task(id: PDFTaskKey(sourceID: file.id, anchorVersion: store.pendingScrollAnchorVersion)) {
            // Only consume for un-extracted PDFs (the markdown side handles
            // extracted PDFs via WikiReaderView). Double-check at consume time
            // since `hasMarkdown` may have changed since render.
            guard requiresPDFQuoteAnchor, !hasMarkdown else { return }
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
        .onChange(of: store.selection) {
            flushEditIfDirty()
            isEditing = false
            updateRightSidebarRegistration()
        }
        .onChange(of: sourceInspectorTabs) { _, _ in
            updateRightSidebarRegistration()
        }
        .onChange(of: showsSourceOutlineTab) { _, _ in updateRightSidebarRegistration() }
        // #842 PR2 C6: refresh the transcript head when the store's source list
        // changes. `appendProcessedMarkdown` routes through `mutate()` → emits
        // a `ResourceChangeEvent(.source, .updated)` → the model's bus
        // subscriber calls `reloadFromStore()` → `reloadSources()` bumps
        // `store.sources`. This onChange picks up that bump and re-reads
        // `processedMarkdownHead` so the reader shows the new transcript
        // immediately after the queue worker persists it — without relying
        // solely on `runTranscription`'s post-completion refresh (which only
        // fires for the view that initiated the job; another wiki window
        // viewing the same source would see the stale head without this).
        .onChange(of: store.sources) { _, _ in
            if !isEditing {
                headVersion = store.processedMarkdownHead(for: file)
                refreshRendererPresentation()
            }
            updateRightSidebarRegistration()
        }
        .background { findShortcutButton }
        .overlay(alignment: .top) { findBarOverlay }
        .onChange(of: file.id) { findModel.dismiss() }
        .onChange(of: currentMarkdownContent) { _, newContent in
            findModel.content = newContent
            findModel.search()
            updateRightSidebarRegistration()
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
            updateRightSidebarRegistration()
        }
        .onChange(of: isEditing) { _, newValue in
            if let id = store.activeTabID {
                store.setTabEditing(tabID: id, isEditing: newValue)
            }
            if newValue { isHeaderExpanded = true } // reveal Save/Cancel
            if !newValue { shouldRestoreEditing = false; caretCharIndex = nil }
            updateRightSidebarRegistration()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
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
                    if let head = headVersion, SourceRendererPresentationPlanner.showsMarkdownOriginMetadata(for: file),
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
                            provider: "Zotero",
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
                    } else if let origin, origin.provider != .legacyImport {
                        // Phase 3a provider origin: website → clickable link to the
                        // origin URL; local-file → "File"; markdown-folder → "Folder".
                        // `provider != .legacyImport` filters the shared
                        // `legacy-import` agent (the pre-v39 degraded fallback —
                        // nil satisfies it too, since `SourceProvider(rawValue:nil)`
                        // is nil).
                        metadataSeparator
                        providerOriginTag(origin)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

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

            if isHeaderExpanded {
                sourceActionBar
                    // Anchor leading: without an alignment the default is
                    // `.center`, which offsets the whole bar when there's no
                    // trailing `Spacer` to force full width (e.g. a source
                    // with no markdown → `isOutlineApplicable` false).
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(PageEditorMetrics.contentInset)
    }

    // MARK: - Header action bar (full-width toolbar row)

    /// The source detail action toolbar row. Rendered as a sibling of
    /// `CollapsibleDetailHeader` — NOT inside its expanded content — so
    /// the trailing `Spacer` + outline toggle reach the view's right edge
    /// instead of the readable-column edge (mirrors
    /// `ChatView.chatActionBar` and `PageDetailView.pageActionBar`).
    @ViewBuilder
    private var sourceActionBar: some View {
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

                    Spacer()
                }
            } else {
                // Row 1 — primary source actions: the extraction chip leads
                // ("this is the derivation, and here's what you do with it"),
                // then Ingest, then Extract Markdown when no derivation exists
                // yet. Above the utility row so the wiki goal reads first.
                HStack(spacing: 10) {
                    if hasExtractionChip, let head = headVersion {
                        extractionProvenanceChip(head: head)
                    }
                    if needsExtraction {
                        // No derivation yet → Extract is the call-to-action:
                        // prominent and leftmost, with Ingest stepped down to
                        // secondary until there's markdown worth ingesting.
                        // Issue #799 PR2: HTML sources dispatch to the inline
                        // `runHtmlExtraction` path (queue engine is PDF-coupled
                        // via `ExtractionResolution.pdfData` /
                        // `convert(pdfData:)` / `seedPdfMarkdown`); PDF sources
                        // go through the queue as before.
                        Button(isExtracting ? "Extracting…" : "Extract",
                               systemImage: "doc.plaintext") {
                            DebugLog.extraction("SourceDetailView: Extract tapped — id=\(file.id.rawValue), html=\(SourceRendererPresentationPlanner.isHTMLSource(file))")
                            Task {
                                if SourceRendererPresentationPlanner.isHTMLSource(file) {
                                    await runHtmlExtraction()
                                } else {
                                    await runExtraction()
                                }
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
                    if needsTranscription {
                        // Issue #799 PR4 (podcasts) + PR5 (YouTube): a
                        // transcribable source with no transcript yet. The
                        // Transcribe button is the analog of the Extract
                        // button for PDF/HTML, but its underlying mechanism is
                        // a network fetch (signed bearer → AMP → TTML → parse
                        // for podcasts; watch-page scrape → caption track →
                        // parse for YouTube), NOT a bytes→markdown transform —
                        // so it dispatches to the queue engine (`runTranscription`).
                        // Disabled for podcasts when the signing helper binary
                        // is unavailable (`isTranscribable` mirrors
                        // `isSourceRefreshable`'s `.applePodcast` runtime guard);
                        // YouTube needs no signing helper, so it's always
                        // enabled when the provider matches.
                        //
                        // #842 PR2 C5: when a transcription is already in flight
                        // for this source, the button swaps to "View
                        // Transcription" (stays enabled) and navigates to the
                        // running job in the Activity window — mirroring
                        // PageDetailView's "View Lint" pattern (#837). Reuses
                        // the existing `pendingSelectionItemID` seam (set it,
                        // set `pendingSelectionQueue = .extraction`, then
                        // call `openActivityWindow?(.extraction)`).
                        Button(isTranscribing ? "View Transcription" : "Transcribe",
                               systemImage: isTranscribing
                               ? "checkmark.seal.fill"
                               : "waveform") {
                            if isTranscribing {
                                if let itemID = tracker.transcriptionItemID(for: file.id) {
                                    tracker.pendingSelectionItemID = itemID
                                    tracker.pendingSelectionQueue = .extraction
                                    openActivityWindow?(.extraction)
                                    DebugLog.extraction("Transcribe button: navigating to transcription job \(itemID) for source \(file.id.rawValue)")
                                } else {
                                    openActivityWindow?(.extraction)
                                    DebugLog.extraction("Transcribe button: transcription in flight for source \(file.id.rawValue) but item not found; opening Activity window")
                                }
                            } else {
                                DebugLog.extraction("SourceDetailView: Transcribe tapped — id=\(file.id.rawValue)")
                                Task { await runTranscription() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isTranscribing
                                  && (isThisFileExtracting
                                      || tracker.isSlotBusyForOtherSource(file.id)))
                        .help(isTranscribing
                              ? "View the running transcription job in the Activity window"
                              : (isYouTubeEmbed
                                 ? "Fetch this video's transcript via YouTube captions"
                                 : "Fetch this episode's transcript via Apple Podcasts"))
                    }
                    ingestButton
                    // The source's content affordance is one-per-source: an
                    // unextracted PDF or HTML source shows Extract (above) to
                    // gain a readable derivation, so Refresh is suppressed
                    // until it has one. Every other refreshable (live) source
                    // offers Refresh to re-fetch and append a new version.
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
                            // visible there. Rendered-only mode needs Source
                            // so editing keeps its editor input visible.
                            if rendererPresentationLifecycle.state.selection == .rendered {
                                var lifecycle = rendererPresentationLifecycle
                                lifecycle.selectSource()
                                rendererPresentationLifecycle = lifecycle
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
                    Spacer()
                }
            }
        }
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
    ///
    /// The per-provider label/icon/helpVerb are sourced from
    /// `SourceProvider.displayLabel` / `.systemImage` / `.helpVerb` so the
    /// DetailView and `SourceOrigin.displayLabel` can't drift (#source-
    /// provider-enum). `mediaProviderInfo`'s former switch table is now
    /// enum-carried and lives on `SourceProvider` itself.
    @ViewBuilder
    private func providerOriginTag(_ origin: SourceOrigin) -> some View {
        switch origin.provider {
        case .website, .applePodcast, .podcast, .youtube, .vimeo, .spotify, .soundcloud, .remoteMedia:
            // URL providers (web pages, podcasts, byteless media embeds) — all
            // open in the default browser via NSWorkspace.shared.open. They share
            // one action shape; only the label / icon / help text differ, and
            // those come from the enum. Force-unwrap is safe — this arm only
            // matched when `origin.provider` is `.some(…)` (non-nil).
            let provider = origin.provider!
            let providerLabel = SourceProvenanceLabel.combine(
                provider: provider.displayLabel, ext: file.ext, mimeType: file.mimeType)
            let urlString = origin.plan ?? origin.externalRef ?? origin.externalIdentity ?? ""
            if let url = URL(string: urlString), url.scheme != nil {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(providerLabel, systemImage: provider.systemImage)
                }
                .buttonStyle(.link)
                .help("\(provider.helpVerb): \(urlString)")
            } else {
                Label(providerLabel, systemImage: provider.systemImage)
            }
        case .localFile, .markdownFolder, .zotero, .legacyImport, nil:
            // Local-path reveal (Finder). `.localFile` shows "File" + "doc";
            // `.markdownFolder` shows "Folder" + "folder" — both via their
            // own enum values. `.legacyImport` is filtered out at the caller
            // (the `origin.provider != .legacyImport` gate above), and
            // `nil` covers any future/unknown provider; both fall back to
            // `SourceProvider.localFile`'s values ("File" / "doc" /
            // "Reveal original file"), matching the pre-enum default arm.
            //
            // `.zotero` is also handled inline ABOVE the caller's gate (a
            // dedicated `zotero://select?itemKey=…` button row); reaching
            // providerOriginTag with a zotero origin is unreachable in
            // practice but listed here so the switch is exhaustive. The
            // pre-enum `default:` arm rendered it as "File" — preserved here
            // via the `.localFile` fallback below.
            //
            // Single ternary expression (not a conditional statement) so the
            // surrounding @ViewBuilder doesn't try to fold this into a view.
            let effective: SourceProvider = (origin.provider == .localFile || origin.provider == .markdownFolder)
                ? origin.provider!
                : .localFile
            let providerLabel = SourceProvenanceLabel.combine(
                provider: effective.displayLabel, ext: file.ext, mimeType: file.mimeType)
            let path = origin.plan ?? origin.externalRef ?? origin.externalIdentity ?? ""
            if !path.isEmpty {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: path)])
                } label: {
                    Label(providerLabel, systemImage: effective.systemImage)
                }
                .buttonStyle(.link)
                .help("\(effective.helpVerb): \(path)")
            } else {
                Label(providerLabel, systemImage: effective.systemImage)
            }
        }
    }

    // MARK: - Content + Outline

    /// The content area plus the optional outline sidebar. Extracted from
    /// `body` so the type-checker can resolve each subtree independently.
    ///
    /// Uses the shared `DetailInspectorView` (same as `PageDetailView`) so
    /// sources get the same tabbed inspector. The outline tab renders the
    /// source's `PageOutlineView`.
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
        contentArea
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func updateRightSidebarRegistration() {
        rightInspector.updateRegistration(
            RightSidebarRegistration(
                inspectorTab: $inspectorTab,
                outlineWidth: $outlineWidth,
                availableTabs: sourceInspectorTabs,
                metadataState: metadataState,
                origin: origin?.provenanceEntry,
                history: editHistory.map(\.provenanceEntry),
                onOpenChat: { id in store.openTab(.chat(id)) },
                onCompareVersions: nil,
                metadataRouter: MetadataActionRouter(
                    openPage: { id in store.openTab(.page(id)); return true },
                    openSource: { id in store.openTab(.source(id)); return true },
                    openChat: { id in store.openTab(.chat(id)); return true },
                    selectActivity: { _ in false },
                    comparePageVersions: { _ in false },
                    compareSourceExtractions: { id in
                        guard id == file.id else { return false }
                        openWindow(value: ExtractionCompareContext(
                            sourceID: id,
                            filename: file.filename,
                            wikiID: store.eventBus?.wikiID ?? WikiID(rawValue: "")))
                        return true
                    },
                    copy: MetadataActionRouter.systemClipboardCopy,
                    openURL: { NSWorkspace.shared.open($0) }),
                outline: {
                    AnyView(sourceSidebarOutlineView())
                }
            )
        )
    }

    private func hydrateMetadata(sourceID: SourceID) async {
        await MetadataHydrator.hydrate(subject: .source(sourceID), operation: {
            if MetadataHydrationReadPath.resolve(readPoolAvailable: store.readPool != nil) == .readPool,
               let readPool = store.readPool {
                return try await readPool.asyncRead { database in
                    try Self.sourceMetadataModel(sourceID: sourceID, store: database)
                }
            } else {
                return try Self.sourceMetadataModel(sourceID: sourceID, store: store.internalStore)
            }
        }, publish: { state in
            metadataState = state
            updateRightSidebarRegistration()
        })
    }

    nonisolated private static func sourceMetadataModel(sourceID: SourceID, store: WikiStore) throws -> MetadataPanelModel {
        guard let source = try store.listSources().first(where: { $0.id == sourceID }) else {
            throw MetadataProjectionError.missingSource(sourceID)
        }
        let history = try store.processedMarkdownHistory(sourceID: sourceID)
        return SourceMetadataProjection.make(input: .init(
            source: source,
            markdown: try store.processedMarkdownHead(sourceID: sourceID),
            extraction: try store.activeExtractionProvenance(sourceID: sourceID),
            alternativeCount: history.count))
    }


    @ViewBuilder
    private func sourceSidebarOutlineView() -> some View {
        if let markdown = currentMarkdownContent, showsSourceOutlineTab {
            outlineView(markdown: markdown)
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
        RendererHostView(
            state: rendererPresentationBinding,
            descriptors: rendererDescriptors,
            showsControls: !isEditing,
            source: { sourcePresentationContent },
            rendered: { descriptor in renderedContent(for: descriptor) },
            onRendererSelected: persistRendererPreference,
            onPresentationSelected: persistRendererPresentationSelection,
            onFallback: handleRendererFallback)
    }

    @ViewBuilder
    private var sourcePresentationContent: some View {
        if let emptyMedia = SourceRendererPresentationPlanner.emptyMediaPresentation(
            for: file,
            currentMarkdown: currentMarkdownContent,
            origin: origin
        ) {
            ContentUnavailableView {
                Label(emptyMedia.label, systemImage: "waveform")
            } description: {
                Text(emptyMedia.description)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if SourceRendererPresentationPlanner.usesMarkdownSourcePresentation(
            for: file,
            currentMarkdown: currentMarkdownContent
        ) {
            markdownContent
        } else {
            binaryFallback
        }
    }

    private func renderedContent(for descriptor: RendererDescriptor) -> AnyView? {
        if let builtIn = BuiltInRendererFactoryMap.makeView(for: descriptor, inputs: rendererFactoryInputs) {
            return builtIn
        }
        guard failedInstalledRendererReference != descriptor.reference else { return nil }
        return installedRendererFactory.makeView(
            for: descriptor,
            inputs: installedRendererFactoryInputs,
            inputReader: rendererAuthorizedInputResolver.rendererAuthorizedInputReader(for: file.id)) { _ in
                // The representable already deferred this callback out of its
                // AppKit/WebKit stack. Keep the detail-state mutation deferred
                // as well because the rendered closure can run in an update pass.
                Task { @MainActor in
                    failedInstalledRendererReference = descriptor.reference
                }
            }
    }

    private func persistRendererPreference(_ reference: RendererReference) {
        // A deliberate retry gets a new session. The failure marker only keeps
        // the existing failed session from being recreated during fallback.
        failedInstalledRendererReference = nil
        store.setRendererSourcePreference(sourceID: file.id, preference: .exact(reference))
    }

    @MainActor
    private func activateRendererPane(reference: RendererReference, input: RendererBridgeInput) {
        guard headVersion != nil else {
            return
        }
        // The exact typed input is carried by the markdown card and routed to
        // the current source's renderer pane. The renderer state itself only
        // needs the exact renderer reference to open the pane.
        persistRendererPreference(reference)
        var lifecycle = rendererPresentationLifecycle
        lifecycle.selectRendered(reference)
        rendererPresentationLifecycle = lifecycle
        store.setRendererSourcePresentation(sourceID: file.id, presentation: .rendered)
    }

    private func rendererPlanner() throws -> SourceRendererPresentationPlanner {
        try SourceRendererPresentationPlanner(
            installedDescriptors: installedRendererFactoryInputs.enabledDescriptors)
    }

    private func persistRendererPresentationSelection(_ selection: RendererPresentationState.Selection) {
        store.setRendererSourcePresentation(sourceID: file.id, presentation: selection)
    }

    /// Resolve the persisted logical or exact renderer once per source. The
    /// resulting exact reference remains pinned while this pane stays open.
    private func beginRendererPresentationLoading() {
        var lifecycle = rendererPresentationLifecycle
        lifecycle.beginLoading(sourceID: file.id)
        rendererPresentationLifecycle = lifecycle
    }

    /// Resolve only after this view has loaded bytes, markdown, and origin for
    /// the current source. The persisted selection records an explicit user
    /// choice. Without it, a new presentable source returns to Source.
    private func resolveRendererPresentation() {
        do {
            let planner = try rendererPlanner()
            let preference = store.rendererSourcePreference(for: file.id)
            let descriptor: RendererDescriptor?
            if let preference {
                descriptor = try planner.preferredDescriptor(
                    preference: preference,
                    for: file,
                    boundedBytes: sourceBytesSnapshot,
                    currentMarkdown: currentMarkdownContent,
                    origin: origin)
            } else {
                descriptor = try planner.matchingDescriptors(
                    for: file,
                    boundedBytes: sourceBytesSnapshot,
                    currentMarkdown: currentMarkdownContent,
                    origin: origin).first
            }
            var lifecycle = rendererPresentationLifecycle
            if lifecycle.state.sourceID != file.id {
                lifecycle.beginLoading(sourceID: file.id)
            }
            lifecycle.resolveLoadedSource(
                source: file,
                matchingRenderer: descriptor?.reference,
                boundedBytes: sourceBytesSnapshot,
                currentMarkdown: currentMarkdownContent,
                origin: origin,
                persistedSelection: store.rendererSourcePresentation(for: file.id))
            rendererPresentationLifecycle = lifecycle
        } catch {
            DebugLog.tabs("SourceDetailView: renderer preference resolution failed (source=\(file.id.rawValue)): \(error)")
            var lifecycle = rendererPresentationLifecycle
            lifecycle.beginLoading(sourceID: file.id)
            rendererPresentationLifecycle = lifecycle
        }
    }

    /// Refreshes using the already-loaded source facts. A source-list change is
    /// not itself permission to rebuild the pane's exact renderer pin.
    private func refreshRendererPresentation() {
        do {
            let planner = try rendererPlanner()
            let descriptors = try planner.matchingDescriptors(
                for: file,
                boundedBytes: sourceBytesSnapshot,
                currentMarkdown: currentMarkdownContent,
                origin: origin)
            let preference = store.rendererSourcePreference(for: file.id)
            let matching = try preference.flatMap { preference in
                try planner.preferredDescriptor(
                    preference: preference,
                    for: file,
                    boundedBytes: sourceBytesSnapshot,
                    currentMarkdown: currentMarkdownContent,
                    origin: origin)
            } ?? descriptors.first
            var lifecycle = rendererPresentationLifecycle
            lifecycle.refreshLoadedSource(
                source: file,
                availableRenderers: descriptors.map(\.reference),
                matchingRenderer: matching?.reference,
                boundedBytes: sourceBytesSnapshot,
                currentMarkdown: currentMarkdownContent,
                origin: origin,
                persistedSelection: store.rendererSourcePresentation(for: file.id),
                isEditing: isEditing)
            rendererPresentationLifecycle = lifecycle
        } catch {
            DebugLog.tabs("SourceDetailView: renderer refresh failed (source=\(file.id.rawValue)): \(error)")
        }
    }

    private func refreshSourceBytesSnapshot() {
        sourceBytesSnapshot = store.sourceBytes(id: file.id)
    }

    private func handleRendererFallback(_ reason: String) {
        DebugLog.tabs("SourceDetailView: renderer fallback (source=\(file.id.rawValue), reason=\(reason))")
        // The host owns the live Source fallback. Do not persist it: an
        // explicit Rendered or Split selection and its renderer preference
        // remain available for a later refresh or reopen retry.
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
                            onRendererActivation: activateRendererPane(reference:input:),
                            inlineAttachmentResolver: RendererInlineAttachmentResolverFactory.make(
                                store: store.internalStore,
                                installedRendererFactory: installedRendererFactory,
                                installedRendererFactoryInputs: installedRendererFactoryInputs,
                                onJSONCanvasHostAction: JSONCanvasHostActionRouter.handler(for: store)),
                            findText: findText, findVersion: findVersion, findOccurrence: findOccurrence)
                .zoomShortcuts($readerZoom)
                .zoomScroll($readerZoom)
        } else if let content = currentMarkdownContent {
            // A native text source with no processed-markdown head (e.g. a
            // `.mmd` Mermaid diagram) renders its raw bytes as readable text —
            // the source code for a diagram, or the body of a `.txt`. Binary
            // sources never reach here (they hit `binaryFallback`).
            let sourceMarkdown = SourceRendererPresentationPlanner.standaloneDiagramSource(file)
                ? MermaidSourceDetector.codeBlockMarkdown(from: content) ?? content
                : content
            WikiReaderView(markdown: sourceMarkdown,
                            currentSelection: store.selection,
                            store: store,
                            onRendererActivation: headVersion == nil ? nil : activateRendererPane(reference:input:),
                            inlineAttachmentResolver: RendererInlineAttachmentResolverFactory.make(
                                store: store.internalStore,
                                installedRendererFactory: installedRendererFactory,
                                installedRendererFactoryInputs: installedRendererFactoryInputs,
                                onJSONCanvasHostAction: JSONCanvasHostActionRouter.handler(for: store)),
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
                queue: .extraction, wikiID: store.eventBus?.wikiID ?? WikiID(rawValue: ""),
                payload: QueueItemPayload(sourceIDs: [file.id]))
            let itemID = try await queueEngine.enqueue(request)
            let result = try await queueEngine.waitForCompletion(of: itemID)

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

    /// HTML extraction trigger (issue #799 PR2). Inline — does NOT route
    /// through the queue engine (which is PDF-coupled via
    /// `ExtractionResolution.pdfData` / `convert(pdfData:)` /
    /// `seedPdfMarkdown` — generalizing the queue is a deferred sub-project
    /// per the parent plan's "Out of scope" section). Dispatches to
    /// `WikiStoreModel.extractHtml(for:backend:)`, which reads the source's
    /// HTML bytes, runs the chosen extractor (defuddle or
    /// `TagBasedHtmlExtractor`), and writes the result via
    /// `appendProcessedMarkdown` (same write path as `enrichWithDefuddle`).
    /// Uses the configured `store.htmlBackend` if set; otherwise defaults to
    /// `.defuddle` (which degrades to tag-based when the binary is missing).
    private func runHtmlExtraction() async {
        isExtracting = true
        defer {
            isExtracting = false
        }
        let backend = store.htmlBackend ?? .defuddle
        if let head = await store.extractHtml(for: file.id, backend: backend) {
            headVersion = head
        }
    }

    /// HTML re-extraction trigger (issue #799 PR2). Called by the
    /// "Re-extract with" menu's HTML branch when the user picks a backend
    /// from `HtmlExtractionBackend.allCases`. Mirrors `runReExtraction(with:)`
    /// but routes through the inline `extractHtml` path (same module-level
    /// decision as `runHtmlExtraction`). `appendProcessedMarkdown` always
    /// appends — first version is HEAD by the default-active rule, later
    /// versions ride as coexisting alternatives (no clobber), so re-extract
    /// naturally creates an alternative the provenance chip surfaces.
    private func runHtmlReExtraction(with backend: HtmlExtractionBackend) async {
        isExtracting = true
        defer {
            isExtracting = false
        }
        if let head = await store.extractHtml(for: file.id, backend: backend) {
            headVersion = head
        }
    }

    /// Transcription trigger (issue #799 PR4 for podcasts; generalized to
    /// YouTube in PR5). Inline — does NOT route through the queue engine
    /// (the queue is PDF-coupled via `ExtractionResolution.pdfData` /
    /// `convert(pdfData:)` / `seedPdfMarkdown`; transcript "extraction" is a
    /// NETWORK FETCH with a different input shape — signed bearer → AMP →
    /// TTML → parse for podcasts; watch-page scrape → caption track → parse
    /// for YouTube). Mirrors `runHtmlExtraction` (PR2) but calls
    /// `WikiStoreModel.transcribe(sourceID:podcastFetcher:youtubeFetcher:)`
    /// (the PR5 unified dispatch that routes per provider — the per-provider
    /// helpers stay private on the model). Uses the configured
    /// `store.podcastBackend` when set; otherwise falls back to
    /// `.appleTranscript` (only backend today) for podcasts. YouTube has no
    /// backend choice today (only the captions-scrape path).
    /// On a build without `PODCAST_TRANSCRIPTS`, the predicate
    /// `needsTranscription` returns `false` for `.applePodcast` (its
    /// underlying `isTranscribable` returns `false` via
    /// `isSourceRefreshable`'s phase-out arm), so the podcast path is
    /// unreachable in production; the YouTube path stays available.
    /// Run transcription through the queue engine instead of calling
    /// `store.transcribe(sourceID:)` inline (#842). Enqueues a durable
    /// `.extraction` queue job (transcription merged into extraction — the
    /// provider resolves transcript sources to a `transcriptFetch` closure),
    /// waits for completion, and refreshes the head version on success —
    /// mirroring `runExtraction()`. Errors land on the queue item's `error`
    /// field + Activity window (not inline `transcribeError`, which was
    /// removed). The de-dupe / reveal-job navigation is PR2 (shared with #837).
    private func runTranscription() async {
        do {
            let request = QueueItemRequest(
                queue: .extraction, wikiID: store.eventBus?.wikiID ?? WikiID(rawValue: ""),
                payload: QueueItemPayload(sourceIDs: [file.id]))
            let itemID = try await queueEngine.enqueue(request)
            let result = try await queueEngine.waitForCompletion(of: itemID)

            switch result {
            case .success:
                if let head = store.processedMarkdownHead(for: file) {
                    headVersion = head
                }
            case .failure:
                break  // Tracker records the error from queue events
            }
        } catch {
            DebugLog.extraction("SourceDetailView: transcribe enqueue failed (\(file.id.rawValue)): \(error)")
        }
    }

    /// Re-transcription trigger (issue #799 PR4). Now enqueues through the
    /// queue engine too (#842) — the `backend` parameter rides in
    /// `payload.stageRouting` (placeholder for future backends; only
    /// `.appleTranscript` exists today).
    private func runTranscription(with backend: PodcastTranscriptionBackend) async {
        DebugLog.extraction("SourceDetailView: Re-transcribe tapped — id=\(file.id.rawValue), backend=\(backend.rawValue)")
        do {
            let request = QueueItemRequest(
                queue: .extraction, wikiID: store.eventBus?.wikiID ?? WikiID(rawValue: ""),
                payload: QueueItemPayload(sourceIDs: [file.id]))
            let itemID = try await queueEngine.enqueue(request)
            let result = try await queueEngine.waitForCompletion(of: itemID)

            switch result {
            case .success:
                if let head = store.processedMarkdownHead(for: file) {
                    headVersion = head
                }
            case .failure:
                break
            }
        } catch {
            DebugLog.extraction("SourceDetailView: re-transcribe enqueue failed (\(file.id.rawValue)): \(error)")
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
                    let agent = names[version.id] ?? version.origin.rawValue
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
                        wikiID: store.eventBus?.wikiID ?? WikiID(rawValue: "")))
                }
                .disabled(!hasMultipleExtractions)
                .help(hasMultipleExtractions
                      ? "Compare and switch between extraction alternatives"
                      : "Re-extract with another backend to enable compare")
            }
            Section("Re-extract with") {
                // Content-type-aware: HTML sources list `HtmlExtractionBackend`
                // (defuddle, tag-based), PDF sources list `ExtractionBackend`
                // (local pdf2md, ACP, Anthropic, Gemini, Docling Serve),
                // podcast sources list `PodcastTranscriptionBackend`
                // (currently just `appleTranscript`; issue #799 PR4) and
                // route to `runTranscription(with:)`. YouTube sources (PR5,
                // issue #799 PR5) have a single entry today (the captions
                // scrape — no `YouTubeTranscriptionBackend` enum added yet;
                // revisit when the Python-subprocess backend lands, #584)
                // and route to the parameterless `runTranscription()`. A
                // source is HTML xor PDF xor podcast xor YouTube xor other —
                // the four branches are mutually exclusive. The HTML, podcast,
                // and YouTube branches route through the inline `extractHtml` /
                // `transcribe` paths (issues #799 PR2 + PR4 + PR5 — the queue
                // engine is PDF-coupled; generalizing it is a deferred
                // sub-project per the parent plan's "Out of scope" section).
                if SourceRendererPresentationPlanner.isHTMLSource(file) {
                    ForEach(HtmlExtractionBackend.allCases, id: \.self) { backend in
                        Button(backend.displayName) {
                            Task {
                                await runHtmlReExtraction(with: backend)
                            }
                        }
                        .disabled(isThisFileExtracting
                                  || tracker.isSlotBusyForOtherSource(file.id))
                    }
                } else if isPodcastEmbed {
                    ForEach(PodcastTranscriptionBackend.allCases, id: \.self) { backend in
                        Button(backend.displayName) {
                            Task {
                                await runTranscription(with: backend)
                            }
                        }
                        .disabled(isTranscribing
                                  || isThisFileExtracting
                                  || tracker.isSlotBusyForOtherSource(file.id))
                    }
                } else if isYouTubeEmbed {
                    // Issue #799 PR5: YouTube has a single transcript backend
                    // today (the pure-Swift watch-page → caption-scrape path in
                    // `YouTubeTranscriptService`). The menu entry dispatches
                    // through the parameterless `runTranscription()` (which
                    // calls `WikiStoreModel.transcribe(sourceID:)`, routing by
                    // provider → `transcribeYouTube`). When a future backend
                    // (e.g. a Python `youtube-transcript-api` subprocess, #584)
                    // lands and we add a `YouTubeTranscriptionBackend` enum,
                    // this branch mirrors the podcast arm: a `ForEach` over
                    // `YouTubeTranscriptionBackend.allCases` calling
                    // `runTranscription(with:)`.
                    Button("YouTube captions") {
                        Task { await runTranscription() }
                    }
                    .disabled(isTranscribing
                              || isThisFileExtracting
                              || tracker.isSlotBusyForOtherSource(file.id))
                } else {
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
            }
        } label: {
            // Label = the active alternative's producer ("Legacy", "Claude
            // (Anthropic)", or "Edited"), no origin verb and no manual chevron —
            // `.borderlessButton` draws its own disclosure arrow.
            Label(Self.activeAlternativeLabel(head: head, agent: names[head.id]),
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
                queue: .extraction, wikiID: store.eventBus?.wikiID ?? WikiID(rawValue: ""),
                payload: QueueItemPayload(
                    sourceIDs: [file.id],
                    stageRouting: [StageRoutingKey.backend.rawValue: backend.rawValue]))
            let itemID = try await queueEngine.enqueue(request)
            let result = try await queueEngine.waitForCompletion(of: itemID)

            switch result {
            case .success:
                if let head = store.processedMarkdownHead(for: file) {
                    headVersion = head
                }
            case .failure:
                break  // Tracker records the error from queue events
            }
        } catch {
            // Enqueue or transport error. The queue UI reports the unavailable state.
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
        // the queue, and `enqueueIngestion` dedupes a source already active.
        //
        // #867: before the Phase C4 flip this ALSO gated on
        // `launcher.isRunning` to avoid a preflight refusal when a lint was
        // mid-run in-process. After C4, ingest AND lint are enqueued to the
        // daemon queue — the local `agentLauncher` is no longer on either
        // path, so its `isRunning` flag is disconnected from ingest/lint state
        // and must NOT gate the button (a stale/stuck flag permanently wedged
        // it). The predicate lives in the pure, tested
        // `ingestButtonDisabled(...)` seam so the regression is pinned.
        .disabled(Self.ingestButtonDisabled(
            isEditLockedExternally: isEditLockedExternally,
            canIngest: canIngest))
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
    let sourceID: SourceID
    let anchorVersion: Int
}

// MARK: - PR2 testable seam — Extract / Transcribe affordance (§5.4)

extension SourceDetailView {

    /// The single-affordance decision for a source's content type, computed
    /// from the registry BEFORE any runtime guard (signing helper present /
    /// `#if PODCAST_TRANSCRIPTS`). Used by the UI to gate the Extract /
    /// Transcribe buttons (`isExtractable` / `isTranscribable`) and by tests
    /// to pin the registry-driven gating without hosting the SwiftUI view.
    ///
    /// Mutually exclusive by construction: a `ContentKind.extractionPath` is
    /// one of four cases or `nil`, so `extract` and `transcribe` never both
    /// fire for the same (mime, provider, ext) triple. The runtime guard
    /// (`store.isSourceRefreshable(for:)` for `.applePodcast`) is layered on
    /// top in `SourceDetailView.isTranscribable`.
    enum ExtractionAffordance: Sendable, Equatable {
        /// PDF / HTML — the Extract Markdown button (`runExtraction` /
        /// `runHtmlExtraction`). `extractionPath == .pdfBackend` or
        /// `.htmlToMarkdown`.
        case extract
        /// Podcast / YouTube — the Transcribe button (`runTranscription`).
        /// `extractionPath == .podcastTranscript` or `.youtubeTranscript`.
        case transcribe
        /// Native markdown / text / image / binary / vimeo / unknown — no
        /// extraction button; the content either is already markdown or has
        /// no path to it (the auto-ingest gate also excludes these).
        case none
    }

    /// Pure registry-driven decision for the Extract-vs-Transcribe-vs-Neither
    /// affordance. `internal static` so `@testable import WikiFS` tests can
    /// reach it without instantiating a `SourceDetailView` (which needs a
    /// `WikiStoreModel`, `AgentLauncher`, `ExtractionCoordinator`, etc.).
    /// Mirrors the PR1 `BackgroundIngestCoordinator.ingestionDecision` seam.
    ///
    /// `nonisolated` because it's pure (a single `ContentKind.resolve(...)`
    /// call with no actor dependencies) despite the enclosing SwiftUI `View`
    /// struct getting implicit `@MainActor` isolation. Tests would otherwise
    /// need `@MainActor` annotations on the suite, and the in-view call site
    /// is already on the main actor.
    ///
    /// See `plans/content-type-registry.md` §5.4 (PR2).
    nonisolated static func extractionAffordance(
        mimeType: String?,
        provider: SourceProvider?,
        ext: String?
    ) -> ExtractionAffordance {
        let kind = ContentKind.resolve(mimeType: mimeType, provider: provider, ext: ext)
        switch kind.capabilities.extractionPath {
        case .pdfBackend, .htmlToMarkdown:             return .extract
        case .podcastTranscript, .youtubeTranscript:   return .transcribe
        case nil:                                       return .none
        }
    }

    /// The Ingest button's disabled predicate, extracted as a pure,
    /// `internal static` seam (mirrors `extractionAffordance`) so the
    /// regression suite can pin it without instantiating a `SourceDetailView`.
    ///
    /// #867 (Phase C4): ingest and lint are enqueued to the daemon queue, not
    /// run through the in-process `agentLauncher`. The button therefore MUST
    /// NOT consult `launcher.isRunning` — that flag is disconnected from
    /// ingest/lint state (and a stale/stuck value permanently wedged the
    /// button). The queue engine serializes ingestion/extraction and
    /// `enqueueIngestion` dedupes a source already active in the queue, so a
    /// re-tap is safe and requires no launcher-level gating. The only real
    /// gates left are "another agent holds the edit lock" and "this source has
    /// no ingestible content".
    nonisolated static func ingestButtonDisabled(
        isEditLockedExternally: Bool,
        canIngest: Bool
    ) -> Bool {
        isEditLockedExternally || !canIngest
    }
}
