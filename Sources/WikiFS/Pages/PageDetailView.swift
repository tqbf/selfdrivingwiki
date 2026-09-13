import SwiftUI
import WikiFSEngine
import WikiFSCore

// pattern: Mixed (unavoidable)

/// Unified page surface. The header (title, date, action buttons) stays fixed
/// regardless of mode. The content area below the divider swaps between rendered
/// markdown and the monospaced source editor. Save/Cancel appear inline in the
/// header — same position as the Edit / Copy Path buttons they replace.
struct PageDetailView: View {
    @Bindable var store: WikiStoreModel
    @Bindable var launcher: AgentLauncher
    /// The per-active-wiki session (store + launchers + descriptor).
    var session: any WikiSessionProtocol
    let fileProvider: FileProviderFacade
    /// Optional typed renderer admission sink. When absent, rich cards stay
    /// static and do not expose activation metadata.
    let onRendererActivation: (@MainActor (RendererReference, RendererBridgeInput) -> Void)?
    let installedRendererFactory: InstalledRendererFactory
    let installedRendererFactoryInputs: InstalledRendererFactory.Inputs
    private var routedInstalledRendererFactoryInputs: InstalledRendererFactory.Inputs {
        installedRendererFactoryInputs.withHostNavigationRouting(.store(store))
    }

    @State private var isEditing = false
    /// Pending scroll-to-heading for the editor (outline click while editing).
    @State private var editorScrollRequest: EditorScrollRequest?
    /// Caret position in the editor, for outline cursor tracking (issue #268).
    @State private var caretCharIndex: Int?
    /// Tracks the active tab ID at the end of the last resolved update cycle.
    /// Used to distinguish tab switches (activeTabID changes) from in-tab
    /// navigation (activeTabID stays, selection changes) when deciding whether
    /// to reset or restore edit mode.
    @State private var lastKnownActiveTabID: UUID? = nil
    @AppStorage("editor.zoom") private var editorZoom = Double(ZoomScale.defaultScale)
    @AppStorage("reader.zoom") private var readerZoom = Double(ZoomScale.defaultScale)
    @AppStorage("pageInspectorTab") private var inspectorTab: InspectorTab = .metadata
    @AppStorage("pageOutlineWidth") private var outlineWidth: Double = 260
    /// Per-view collapse state for the header. Starts collapsed; persists
    /// across same-type tab switches (SwiftUI keeps the view alive).
    @State private var isHeaderExpanded = false
    /// Legacy provenance payload retained for compatibility with the shared
    /// inspector. Current page registrations expose Metadata and Outline.
    @State private var provenanceOrigin: PageOrigin?
    @State private var provenanceHistory: [PageOrigin] = []
    @State private var metadataState: MetadataHydrationState = .idle

    // Find bar state. The model is shared (hoisted to `ContentView` and injected
    // via environment) so the address bar's "Find on Page…" menu item can drive
    // the same find bar that Cmd+F toggles here (issue #157).
    @Environment(FindModel.self) private var findModel
    @Environment(WindowRightInspectorController.self) private var rightInspector
    @State private var findVersion = 0

    /// The app-wide queue activity tracker — used to reflect an in-flight lint
    /// on this page's "Lint" button (icon + label + navigation when running).
    @Environment(QueueActivityTracker.self) private var activityTracker
    /// Opens the Activity (queue) window — injected from the environment
    /// (#745). Used by the Lint button to navigate to the running lint job
    /// when a lint is already in flight for this page (#837).
    @Environment(\.openActivityWindow) private var openActivityWindow
    /// Opens the value-driven Versions `WindowGroup` (#817). Captured from the
    /// environment (only available inside a `WindowGroup`'s view hierarchy).
    @Environment(\.openWindow) private var openWindow

    init(
        store: WikiStoreModel,
        launcher: AgentLauncher,
        session: any WikiSessionProtocol,
        fileProvider: FileProviderFacade,
        installedRendererFactory: InstalledRendererFactory = .unavailable,
        installedRendererFactoryInputs: InstalledRendererFactory.Inputs = .unavailable,
        onRendererActivation: (@MainActor (RendererReference, RendererBridgeInput) -> Void)? = nil
    ) {
        self._store = Bindable(wrappedValue: store)
        self._launcher = Bindable(wrappedValue: launcher)
        self.session = session
        self.fileProvider = fileProvider
        self.installedRendererFactory = installedRendererFactory
        self.installedRendererFactoryInputs = installedRendererFactoryInputs
        self.onRendererActivation = onRendererActivation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — title always visible; date + provenance expandable.
            //
            // The action toolbar (Save/Cancel/Edit/Lint/Show in List/Share/
            // Reveal in Finder + outline toggle) is rendered as a SIBLING of
            // CollapsibleDetailHeader — NOT inside its content closure (which
            // constrains expanded content to readableContentWidth). The
            // sibling row spans the full view width so the trailing
            // Spacer/outline toggle reach the view's right edge instead of
            // the readable-column edge. This mirrors the ChatView reference
            // pattern (Sources/WikiFS/Chats/ChatView.swift:670-710); both
            // rows are gated on `isHeaderExpanded` for collapse behavior.
            VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
                CollapsibleDetailHeader(
                    systemImage: ResourceKind.page.systemImageName,
                    title: store.draftTitle,
                    isExpanded: $isHeaderExpanded,
                    onTitleCommit: renameCurrentPage
                ) {
                    VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
                        HStack(spacing: 12) {
                            if let date = pageUpdatedAt {
                                Text(date, style: .date)
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }

                if isHeaderExpanded {
                    pageActionBar
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, PageEditorMetrics.contentInset)
            .padding(.top, PageEditorMetrics.contentInset)
            .padding(.bottom, PageEditorMetrics.sectionSpacing)

            Divider().opacity(PageEditorMetrics.dividerOpacity)

            // Non-blocking hints: a saved draft with a broken claimed fence
            // and/or cosmetic markdown issues. Surfaced on save; clear once the
            // issues are fixed and re-saved. Combined into a single banner when
            // both are present to avoid stacked notification noise.
            saveWarningBanner

            contentAndOutline
        }
        .background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: PageEditorMetrics.detailMinWidth)
        .onAppear {
            lastKnownActiveTabID = store.activeTabID
            updateRightSidebarRegistration()
            // Seed edit mode from the active tab on first mount. `.onChange(of:
            // store.activeTabID)` below only fires on *subsequent* tab switches,
            // so without this a freshly-created "start in editor" tab would
            // render the preview branch on first paint. Safe for navigation:
            // navigation-opened tabs default to `isEditing == false`.
            let editing = store.activeTab?.isEditing ?? false
            isEditing = editing
            // Ensure the header is expanded in the *first* paint when seeding
            // edit mode — `.onChange(of: isEditing)` may not fire synchronously
            // for a write made during `.onAppear`, and the editor branch needs
            // the Save/Cancel row visible immediately (defense in depth).
            if editing { isHeaderExpanded = true }
        }
        .onChange(of: store.selection) {
            // In-tab navigation (wiki-link click, sidebar navigation within the
            // same tab): exit edit mode. Tab switches are detected below via
            // activeTabID and restore per-tab state instead of always resetting.
            if store.activeTabID == lastKnownActiveTabID {
                isEditing = false
            }
            updateRightSidebarRegistration()
        }
        .onChange(of: store.activeTabID) { _, newID in
            lastKnownActiveTabID = newID
            let tab = store.tabs.first(where: { $0.id == newID })
            isEditing = tab?.isEditing ?? false
        }
        .onChange(of: isEditing) { _, newValue in
            if let id = store.activeTabID {
                store.setTabEditing(tabID: id, isEditing: newValue)
            }
            if newValue { isHeaderExpanded = true } // reveal Save/Cancel
            if !newValue { caretCharIndex = nil }
        }
        .background { findShortcutButton }
        .overlay(alignment: .top) { findBarOverlay }
        .onChange(of: store.selection) { findModel.dismiss() }
        .onChange(of: store.draftBody) { _, newMarkdown in
            findModel.content = newMarkdown
            findModel.search()
        }
        .onChange(of: findModel.isShowing) { _, showing in
            if showing {
                findModel.content = store.draftBody
                findModel.search()
            }
        }
        .onChange(of: findModel.currentMatchIndex) { _, _ in
            guard findModel.currentMatchIndex > 0 else { return }
            findVersion &+= 1
        }
        // Draft edits and caret moves re-register through the payload observer
        // below, not a direct onChange: the payload only changes when the rows
        // or the highlight bucket change, so equal-payload keystrokes publish
        // nothing. Provenance and metadata changes still re-register directly
        // — they live in the registration but not in the payload.
        .modifier(SidebarRegistrationRefresh(
            outlinePayload: outlinePayload,
            onRefresh: { updateRightSidebarRegistration() }
        ))
        .onChange(of: provenanceOrigin) { _, _ in
            updateRightSidebarRegistration()
        }
        .onChange(of: provenanceHistory) { _, _ in
            updateRightSidebarRegistration()
        }
        .task(id: currentPageID) {
            guard let pageID = currentPageID else {
                provenanceOrigin = nil
                provenanceHistory = []
                return
            }
            provenanceOrigin = store.pageOrigin(for: pageID)
            provenanceHistory = store.pageEditHistory(for: pageID)
            updateRightSidebarRegistration()
        }
        .task(id: currentPageID.map { MetadataHydrationKey.page($0, store.messageVersion) }) {
            guard let pageID = currentPageID else {
                metadataState = .idle
                return
            }
            await hydrateMetadata(pageID: pageID)
        }
        .task(id: currentPageID) {
            guard currentPageID != nil else { return }
            let normalized = InspectorTab.normalize(selection: inspectorTab, availableTabs: InspectorTab.pageAvailableTabs)
            guard normalized != inspectorTab else { return }
            inspectorTab = normalized
            updateRightSidebarRegistration()
        }
        .alert(
            "Title Already Exists",
            isPresented: Binding(
                get: { store.renameConflictingTitle != nil },
                set: { if !$0 { store.clearRenameConflict() } }
            )
        ) {
            Button("OK", role: .cancel) { store.clearRenameConflict() }
        } message: {
            if let title = store.renameConflictingTitle {
                Text("A page with the title “\(title)” already exists. Please choose a different name.")
            }
        }
    }

    // MARK: - Header action bar (full-width toolbar row)

    /// The page detail action toolbar row. Rendered as a sibling of
    /// `CollapsibleDetailHeader` — NOT inside its expanded content — so this
    /// HStack spans the FULL view width. The trailing
    /// `Spacer(minLength: 0)`/`Spacer` therefore pushes the outline toggle
    /// all the way to the view's right edge (mirrors `ChatView.chatActionBar`).
    @ViewBuilder
    private var pageActionBar: some View {
        HStack(spacing: 10) {
            if isEditing {
                Button("Save Changes", systemImage: "checkmark.circle") {
                    DebugLog.tabs("PageDetailView: Save Changes tapped")
                    commitEdit()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(store.draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Cancel", systemImage: "xmark.circle") {
                    DebugLog.tabs("PageDetailView: Cancel tapped")
                    cancelEdit()
                }
                .keyboardShortcut(.escape, modifiers: [])

                // Pin action buttons at the leading edge and the
                // outline toggle at the trailing edge so the row's
                // layout is independent of the parent's proposed width
                // (which changes when the outline pane or the header
                // expands/collapses — keeps "Show in List" and friends
                // in a fixed position).
                Spacer()
            } else {
                Button("Edit",
                       systemImage: "pencil") {
                    DebugLog.tabs("PageDetailView: Edit tapped")
                    isEditing = true
                }
                    .help("Edit this page manually")
                if case .page = store.selection {
                    lintButton
                }
                if case .page(let pageID) = store.selection {
                    Button("Show in List", systemImage: "sidebar.left") {
                        DebugLog.tabs("PageDetailView: Show in List tapped — id=\(pageID.rawValue)")
                        store.requestSidebarReveal(.page(pageID))
                    }
                    .help("Reveal this page in the sidebar")
                }
                if fileProvider.path != nil, case .page(let pageID) = store.selection {
                    Button("Share", systemImage: "square.and.arrow.up") {
                        DebugLog.fileprovider("PageDetailView: Share tapped — id=\(pageID.rawValue)")
                        Task {
                            guard let url = await fileProvider.resolvePageByTitleURL(id: pageID, wikiID: session.wikiID) else {
                                DebugLog.fileprovider("Share page detail: resolvePageByTitleURL returned nil — id=\(pageID.rawValue) wikiID=\(session.wikiID)")
                                return
                            }
                            DebugLog.fileprovider("Share page detail: \(url.lastPathComponent)")
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
                    .help("Share this page")
                    Button("Reveal in Finder", systemImage: "folder") {
                        DebugLog.fileprovider("PageDetailView: Reveal in Finder tapped — id=\(pageID.rawValue)")
                        Task { await fileProvider.revealPageInFinder(id: pageID, wikiID: session.wikiID) }
                    }
                    .help("Reveal this page file in Finder")
                }
                // Pin action buttons at the leading edge and the outline
                // toggle at the trailing edge (see the matching comment
                // in the editing branch above).
                Spacer()
            }
            }
            .frame(maxWidth: .infinity)
    }

    // MARK: - Lint button

    /// The page-level "Lint" action button. Reflects an in-flight lint on this
    /// page: when a lint (whole-wiki or page-level) is running, the button swaps
    /// to a filled "View Lint" state and taps navigate to that specific lint job
    /// in the Activity window (#837). When no lint is running, tapping enqueues
    /// a new page-level lint.
    @ViewBuilder
    private var lintButton: some View {
        if case .page(let id) = store.selection {
            let pageIsLinting = activityTracker.isLinting(
                pageID: id, wikiID: session.wikiID)
            Button(pageIsLinting ? "View Lint" : "Lint",
                   systemImage: pageIsLinting
                   ? "checkmark.seal.fill"
                   : "checkmark.seal") {
                if pageIsLinting {
                    // A lint is already active for this page (whole-wiki or
                    // page-level) — navigate to the job in the Activity window
                    // instead of enqueuing a duplicate (#837).
                    if let itemID = activityTracker.lintItemID(
                        for: id, wikiID: session.wikiID) {
                        activityTracker.pendingSelectionItemID = itemID
                        openActivityWindow?(.ingestion)
                        DebugLog.ingest("Lint button: navigating to lint job \(itemID) for page \(id) in wiki \(session.wikiID.rawValue.prefix(8))")
                    } else {
                        // isLinting returned true but we couldn't resolve the
                        // specific item (race: item just finished). Fall back to
                        // opening the Activity window without a selection.
                        openActivityWindow?(.ingestion)
                        DebugLog.ingest("Lint button: lint in flight for page \(id) but item not found; opening Activity window")
                    }
                } else {
                    Task {
                        // Closed-wiki name resolution: record the page title
                        // already in hand so the Activity window keeps a
                        // readable input row after this wiki's window closes.
                        let title = store.summaries.first { $0.id == id }?.title
                        let payload = QueueItemPayload(
                            sourceIDs: [],
                            lintPageIDs: [id],
                            recordedNames: title.map { [id.rawValue: $0] })
                        await DebugLog.trying("enqueue lint request", operation: { try await session.queueEngine.enqueue(QueueItemRequest(
                            queue: .ingestion,
                            wikiID: session.wikiID,
                            payload: payload
                        )) })
                    }
                }
            }
            .help(pageIsLinting
                  ? "View the running lint job in the Activity window"
                  : "Fix [[wiki-link]] syntax and run LLM lint on this page")
        }
    }

    // MARK: - Content + Outline

    /// The main content area (reader or editor) plus the optional outline
    /// sidebar. Extracted from `body` so the type-checker can resolve each
    /// subtree independently.
    @ViewBuilder
    private var contentAndOutline: some View {
        Group {
            if isEditing {
                editorContent
            } else {
                readerContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The outline payload for the current page, derived in the body so caret
    /// moves and draft edits re-derive it; `SidebarRegistrationRefresh`
    /// observes it and re-registers on change. When no page is active the
    /// payload is empty and never reaches the controller — registration is
    /// gated on `currentPageID`.
    private var outlinePayload: InspectorOutlinePayload {
        let headings = OutlineParser.headings(in: store.draftBody)
        return InspectorOutlinePayload(
            subject: currentPageID.map(WikiSelection.page) ?? .changeLog,
            content: .headings(headings),
            highlightedItemID: OutlineParser.activeHeadingID(
                caretUTF16Offset: caretCharIndex ?? -1, headings: headings))
    }

    private func updateRightSidebarRegistration() {
        guard let pageID = currentPageID else { return }
        rightInspector.updateRegistration(
            RightSidebarRegistration(
                subject: .page(pageID),
                inspectorTab: $inspectorTab,
                outlineWidth: $outlineWidth,
                availableTabs: InspectorTab.pageAvailableTabs,
                metadataState: metadataState,
                origin: provenanceOrigin?.provenanceEntry,
                history: provenanceHistory.map(\.provenanceEntry),
                onOpenChat: { id in store.openTab(.chat(id)) },
                onCompareVersions: openVersionsWindow,
                metadataRouter: MetadataActionRouter(
                    openPage: { id in store.openTab(.page(id)); return true },
                    openSource: { id in store.openTab(.source(id)); return true },
                    openChat: { id in store.openTab(.chat(id)); return true },
                    selectActivity: { _ in false },
                    comparePageVersions: { id in openVersionsWindow(for: id) },
                    compareSourceExtractions: { _ in false },
                    copy: MetadataActionRouter.systemClipboardCopy,
                    openURL: { NSWorkspace.shared.open($0) }),
                outline: outlinePayload,
                onOutlineSelect: { selection in
                    guard case .heading(let heading) = selection else { return }
                    if isEditing {
                        editorScrollRequest = EditorScrollRequest(
                            charOffset: heading.charOffset,
                            version: (editorScrollRequest?.version ?? 0) + 1)
                    } else {
                        store.jumpToAnchorInCurrentSelection(heading.id)
                    }
                }
            ),
            activeSelection: store.selection
        )
    }

    private func hydrateMetadata(pageID: PageID) async {
        await MetadataHydrator.hydrate(subject: .page(pageID), operation: {
            if MetadataHydrationReadPath.resolve(readServiceAvailable: store.readService != nil) == .readService,
               let readService = store.readService {
                return try await readService.asyncRead { database in
                    try Self.pageMetadataModel(pageID: pageID, store: database)
                }
            } else {
                return try Self.pageMetadataModel(pageID: pageID, store: store.internalStore)
            }
        }, publish: { state in
            metadataState = state
            updateRightSidebarRegistration()
        })
    }

    nonisolated private static func pageMetadataModel(
        pageID: PageID,
        store: borrowing WikiReadAccess
    ) throws -> MetadataPanelModel {
        let page = try store.getPage(id: pageID)
        let sourceSummaries = try store.listSources()
        let sources = try store.pageHeadSources(pageID: pageID).map { relation in
            guard let source = sourceSummaries.first(where: { $0.id == relation.sourceID }) else {
                throw MetadataProjectionError.missingSource(relation.sourceID)
            }
            return MetadataPageSource(sourceID: source.id, displayName: source.effectiveName, role: relation.role)
        }
        let history = try store.pageVersionHistory(pageID: pageID)
        let headID = try store.pageHeadVersionID(pageID: pageID)
        let okfMetadata = try headID.flatMap {
            try store.pageOKFMetadata(versionID: $0, includeCorrected: false)?.metadata
        } ?? OKFConceptMetadata()
        return PageMetadataProjection.make(input: .init(
            page: page,
            currentVersion: history.first { $0.id == headID },
            origin: try store.pageOrigin(pageID: pageID),
            sources: sources,
            okfMetadata: okfMetadata))
    }

    nonisolated private static func pageMetadataModel(pageID: PageID, store: WikiStore) throws -> MetadataPanelModel {
        let page = try store.getPage(id: pageID)
        let sourceSummaries = try store.listSources()
        let sources = try store.pageHeadSources(pageID: pageID).map { relation in
            guard let source = sourceSummaries.first(where: { $0.id == relation.sourceID }) else {
                throw MetadataProjectionError.missingSource(relation.sourceID)
            }
            return MetadataPageSource(sourceID: source.id, displayName: source.effectiveName, role: relation.role)
        }
        let history = try store.pageVersionHistory(pageID: pageID)
        let headID = try store.pageHeadVersionID(pageID: pageID)
        let okfMetadata = try headID.flatMap {
            try store.pageOKFMetadata(versionID: $0, includeCorrected: false)?.metadata
        } ?? OKFConceptMetadata()
        return PageMetadataProjection.make(input: .init(
            page: page,
            currentVersion: history.first { $0.id == headID },
            origin: try store.pageOrigin(pageID: pageID),
            sources: sources,
            okfMetadata: okfMetadata))
    }


    private var editorContent: some View {
        ScrollableTextEditor(
            text: $store.draftBody,
            font: NSFont.monospacedSystemFont(
                ofSize: CGFloat(13 * editorZoom), weight: .regular),
            displayText: WikiLinkEditorProjection.displayed,
            scrollRequest: editorScrollRequest,
            onCaretChange: { caretCharIndex = $0 },
            sidebarDropBuilder: { payloads in
                SidebarDropBuilder.insertionText(for: payloads, store: store)
            },
            // Issue #680: wiki-link autocomplete in the editor. Same hooks +
            // search backend as the chat composer (#684), re-pointed at the
            // editor's `ScrollableTextEditor`. Built from `store.searchServices`
            // so a wiki without one (no Tantivy service yet attached) gets
            // `nil` and the editor behaves as before.
            autocomplete: SidebarDropBuilder.wikiLinkAutocompleteHooks(store: store),
            autocompletePlacement: .below  // editor convention: tall NSTextView has more room below the caret
        )
        .padding(.horizontal, PageEditorMetrics.contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: PageEditorMetrics.editorMinHeight)
        .onChange(of: store.draftBody) { store.bodyChanged() }
        .zoomShortcuts($editorZoom)
        .zoomScroll($editorZoom)
    }

    private var readerContent: some View {
        WikiReaderView(markdown: store.draftBody,
                        currentSelection: store.selection,
                        store: store,
                        documentIdentity: currentPageDocumentIdentity,
                        fileProvider: fileProvider,
                        onRendererActivation: onRendererActivation,
                        inlineAttachmentResolver: RendererInlineAttachmentResolverFactory.make(
                            store: store.internalStore,
                            installedRendererFactory: installedRendererFactory,
                            installedRendererFactoryInputs: routedInstalledRendererFactoryInputs),
                        inlineRendererDescriptors: installedRendererFactoryInputs.availableDescriptors,
                        rendererPackageInputs: RendererPackageEmbedInputs.make(from: installedRendererFactoryInputs),
                        findText: findText, findVersion: findVersion,
                        findOccurrence: findOccurrence)
            .frame(maxWidth: .infinity)
            .frame(minHeight: PageEditorMetrics.previewMinHeight)
            .zoomShortcuts($readerZoom)
            .zoomScroll($readerZoom)
    }

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

    // MARK: - Computed

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

    private var displayTitle: String {
        store.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled" : store.draftTitle
    }

    private var pageUpdatedAt: Date? {
        guard let selection = store.selection,
              case .page(let id) = selection else { return nil }
        return store.summaries.first(where: { $0.id == id })?.updatedAt
    }

    // MARK: - Inspector support

    /// The id of the page currently shown in this detail view — the key the
    /// `DetailInspectorView` uses to load provenance via
    /// `WikiStoreModel.pageOrigin(for:)` / `pageEditHistory(for:)`.
    private var currentPageID: PageID? {
        guard case .page(let id) = store.selection else { return nil }
        return id
    }

    private var currentPageDocumentIdentity: MarkdownDocumentIdentity? {
        guard let pageID = currentPageID,
              let pageVersionID = store.loadedPageHeadVersionID(for: pageID)
        else { return nil }
        return MarkdownDocumentIdentity(pageID: pageID, pageVersionID: pageVersionID)
    }

    /// Open the Versions window for the current page (#817). The callback is
    /// retained for legacy history-compatible inspector registrations. The
    /// `WindowGroup(for: PageVersionCompareContext.self)` dedups by pageID +
    /// wikiID, so re-opening focuses the existing window.
    private func openVersionsWindow() {
        guard let pageID = currentPageID else { return }
        _ = openVersionsWindow(for: pageID)
    }

    /// The router carries a typed page target. Rejecting any target other than
    /// the currently hosted page prevents stale inspector actions from opening
    /// a comparison window for the wrong subject.
    private func openVersionsWindow(for pageID: PageID) -> Bool {
        guard currentPageID == pageID else { return false }
        let title = store.summaries.first { $0.id == pageID }?.title ?? ""
        openWindow(value: PageVersionCompareContext(
            pageID: pageID,
            title: title,
            wikiID: store.eventBus?.wikiID ?? WikiID(rawValue: "")))
        return true
    }

    // MARK: - Subviews

    @ViewBuilder private var saveWarningBanner: some View {
        let hasFrontmatter = store.draftBody.hasPrefix("---")
        if store.fenceSaveWarning != nil || store.markdownSaveWarning != nil || hasFrontmatter {
            VStack(alignment: .leading, spacing: 6) {
                if hasFrontmatter {
                    Text("Frontmatter (---) is generated automatically and will be stripped from this field on next load. Set the title using the field above.")
                        .foregroundStyle(.orange)
                }
                if let fence = store.fenceSaveWarning {
                    Text(fence)
                        .foregroundStyle(.orange)
                }
                if let md = store.markdownSaveWarning {
                    markdownSection(md)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, PageEditorMetrics.contentInset)
            .padding(.top, 8)
        }
    }

    @ViewBuilder private func markdownSection(_ md: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Markdown formatting (informational — page saved as-is):\n\(md)")
                .foregroundStyle(.orange.opacity(0.8))
            Spacer(minLength: 4)
            // The button only appears when markdownSaveWarning is non-nil, which
            // only happens when the linter IS loaded — so fixMarkdownInDraft()
            // will always have a linter to call. No separate nil guard needed.
            Button("Fix", systemImage: "wand.and.stars") {
                store.fixMarkdownInDraft()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Auto-fix cosmetic markdown issues (trailing whitespace, blank-line spacing, etc.)")
        }
    }

    // MARK: - Actions

    private func commitEdit() {
        store.flushPendingSave()
        isEditing = false
    }

    private func cancelEdit() {
        if let id = store.activeTabID {
            store.discardPendingDraft(tabID: id)
        }
        isEditing = false
    }

    /// Rename the currently-selected page. `store.rename` flushes pending edits
    /// first, then updates the title (and the slug, open tabs, and `draftTitle`).
    private func renameCurrentPage(to newTitle: String) {
        guard case .page(let id)? = store.selection else { return }
        store.rename(id, to: newTitle)
    }

}
