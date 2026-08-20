import SwiftUI
import WikiFSEngine
import WikiFSCore

// pattern: Mixed (unavoidable)

/// The active wiki's shell: a sidebar (wiki switcher + pages + files) and a
/// detail pane that edits the selected page, the system prompt, or shows a
/// designed empty state (§7.1 ContentUnavailableView). Hosted by `RootView`,
/// which swaps it wholesale (via `.id`) when the user switches wikis.
struct ContentView: View {
    @Environment(QueueActivityTracker.self) private var tracker
    @Bindable var store: WikiStoreModel
    /// The per-active-wiki session (store + launchers + gate + descriptor).
    var session: WikiSession
    /// App-scoped registry: wiki list + active id + create/select/delete.
    @Bindable var registry: WikiRegistryClient
    let fileProvider: FileProviderFacade
    @Bindable var agentLauncher: AgentLauncher
    let extractionCoordinator: ExtractionCoordinator
    let queueEngine: any QueueEngineClient
    let extractionProvider: any QueueExtractionProvider
    let installedRendererHost: InstalledRendererHost
    /// Optional typed renderer activation sink for page detail routes.
    let onRendererActivation: (@MainActor (RendererReference, RendererBridgeInput) -> Void)?
    @State private var pendingAddURL: PendingAddURL?
    /// Driven by `.dropDestination`'s `isTargeted` callback to fade in a subtle
    /// accent border while a drag hovers the window (set via the closure param —
    /// no `Binding(get:set:)`).
    @State private var isDropTargeted = false
    /// Drives the "Add from URL" sheet. Non-`nil` while presented; the wrapped
    /// URL pre-fills the field — empty for the toolbar / empty-state buttons,
    /// the absolute URL for the right-click "Add as Source" item (set via the
    /// `\.addURLHandler` environment value).
    @State private var showingImportMarkdown = false
    @State private var showingAddFromZotero = false
    @State private var showCloseTabAlert = false
    /// Drives address-bar focus from the Cmd-L shortcut. The bar observes this
    /// via a `@Binding` and mirrors it into its own `@FocusState`.
    @State private var addressBarFocused = false
    /// Tracks the sidebar's visibility so the omnibox can shrink to leave room
    /// for the back/forward buttons when the sidebar is open (otherwise the wide
    /// omnibox pushes Forward into the toolbar overflow).
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// Width of the detail column, measured by a `GeometryReader` on it. Drives the
    /// toolbar omnibox width: the region the toolbar spans, so it shrinks with the
    /// left sidebar and is unaffected by the right transcript panel. Measuring this
    /// (never in toolbar overflow) instead of the omnibox field's own leading edge
    /// is what keeps the width from getting stranded. See `OmniboxLayout`.
    @State private var detailWidth: CGFloat = 0
    /// Drives the `BookmarkTargetPickerSheet` from the omnibox "+". The sheet
    /// lives here (not on `AddressBarView`) because toolbar items can't reliably
    /// present SwiftUI sheets.
    @State private var omniboxBookmarkContext: BookmarkTargetPickerContext?
    /// Shared find-bar model. Hoisted here (out of per-view `@State`) so both the
    /// toolbar's "Find on Page…" menu item (`AddressBarView`) and the active
    /// detail view's Cmd+F drive the same `FindBarView` overlay (issue #157).
    @State private var findModel = FindModel()
    @State private var rightInspector = WindowRightInspectorController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        store: WikiStoreModel,
        session: WikiSession,
        registry: WikiRegistryClient,
        fileProvider: FileProviderFacade,
        agentLauncher: AgentLauncher,
        extractionCoordinator: ExtractionCoordinator,
        queueEngine: any QueueEngineClient,
        extractionProvider: any QueueExtractionProvider,
        installedRendererHost: InstalledRendererHost,
        onRendererActivation: (@MainActor (RendererReference, RendererBridgeInput) -> Void)? = nil
    ) {
        self._store = Bindable(wrappedValue: store)
        self.session = session
        self._registry = Bindable(wrappedValue: registry)
        self.fileProvider = fileProvider
        self._agentLauncher = Bindable(wrappedValue: agentLauncher)
        self.extractionCoordinator = extractionCoordinator
        self.queueEngine = queueEngine
        self.extractionProvider = extractionProvider
        self.installedRendererHost = installedRendererHost
        self.onRendererActivation = onRendererActivation
    }

    var body: some View {
        baseContent
        .sheet(item: $pendingAddURL) { pending in
            AddFromURLSheet(store: store, initialURL: pending.url)
        }
        // Expose the "present Add from URL (pre-filled)" action to the whole
        // subtree so the reader views' right-click "Add as Source" item (and the
        // empty-state button in `WikiDetailView`) can trigger it without a
        // per-view binding. Mirrors `WikiReaderView`'s `\.openURL` override.
        .environment(\.addURLHandler) { url in
            pendingAddURL = PendingAddURL(url: url)
        }
        .sheet(isPresented: $showingImportMarkdown) { ImportMarkdownSheet(store: store) }
        .sheet(isPresented: $showingAddFromZotero) {
            AddFromZoteroSheet(store: store, containerDirectory: zoteroContainerDirectory)
        }
        // Non-dismissible while the search-index upgrade runs — the upgrade is the
        // sole owner of the store during it, so SQLite is never touched off-main.
        // The binding's setter is a no-op: only the model nils `searchUpgrade` on
        // completion (the user cannot dismiss; `interactiveDismissDisabled` blocks
        // the gesture and the no-op setter blocks a programmatic clear).
        .sheet(isPresented: Binding(get: { store.searchUpgrade != nil }, set: { _ in })) {
            SearchUpgradeView(store: store).interactiveDismissDisabled()
        }
        // List(selection:) writes store.selection directly; observe it here so
        // the model flushes the outgoing page and loads the incoming one
        // (§3.5). The view, not the binding, is the right place for this.
        .onChange(of: store.selection, initial: false) { _, newValue in
            store.handleSelectionChange(to: newValue)
            switch newValue {
            case .page, .source, .chat:
                break
            case .none, .newChat, .changeLog, .bookmark:
                rightInspector.updateRegistration(nil)
            }
        }
        // "Show In List" reveal (issue #183): a detail-view button requested the
        // sidebar reveal a page/source. Un-collapse the sidebar so the target list
        // is actually mounted (SidebarView only mounts the active section).
        .onChange(of: store.pendingSidebarRevealVersion) { _, _ in
            handleSidebarRevealVersionChange()
        }
        // Close-while-editing guard: fires for any tab with isEditing set.
        .onChange(of: store.pendingCloseTabID) { _, id in
            showCloseTabAlert = id != nil
        }
        .onChange(of: showCloseTabAlert) { _, showing in
            if !showing { store.cancelCloseTab() }
        }
        .alert("Close Tab?", isPresented: $showCloseTabAlert) {
            Button("Close & Discard", role: .destructive) { store.confirmCloseTab() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("You're in edit mode. Unsaved changes will be discarded.")
        }
        .sheet(isPresented: Binding(get: { store.storeError != nil },
                                    set: { if !$0 { store.dismissStoreError() } })) {
            if let error = store.storeError {
                StoreErrorSheet(error: error) { store.dismissStoreError() }
            }
        }
        .sheet(item: $omniboxBookmarkContext) { ctx in
            BookmarkTargetPickerSheet(
                store: store,
                targets: ctx.targets,
                onConfirm: { parentID in
                    switch ctx.targets {
                    case .pages(let ids):
                        for id in ids { store.addPageRef(parentID: parentID, pageID: id) }
                    case .sources(let ids):
                        for id in ids { store.addSourceRef(parentID: parentID, sourceID: id) }
                    case .chats(let ids):
                        for id in ids { store.addChatRef(parentID: parentID, chatID: id) }
                    }
                }
            )
        }
        // Inject the shared find model so the toolbar's "Find on Page…" menu item
        // (`AddressBarView`, in a `ToolbarItem`) and the detail views' Cmd+F both
        // reach the same `FindModel` instance (#157).
        .environment(findModel)
        .environment(rightInspector)
    }

    /// NavigationSplitView + drop / overlay / toolbar. Split out of `body` so the
    /// full modifier chain stays under the SwiftUI type-checker's complexity
    /// budget (adding the search-upgrade sheet tipped the single expression over).
    @ViewBuilder
    private var baseContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(store: store, registry: registry, session: session, fileProvider: fileProvider,
                        launcher: agentLauncher,
                        ingestingSourceIDs: tracker.ingestingSourceIDs,
                        showingAddFromZotero: $showingAddFromZotero,
                        showingImportMarkdown: $showingImportMarkdown,
                        onAddFromURL: { pendingAddURL = PendingAddURL(url: "") },
                        onNewPage: { store.newPageInNewTab() },
                        isZoteroConfigured: isZoteroConfigured)
        } detail: {
            detailColumn
        }
        // Drop a file or link anywhere on the window. Remote links (an http(s)
        // URL dragged from a browser, or a `.webloc` resolved to one) route
        // through the "Add from URL" fetch path; local files ingest as raw
        // bytes. The whole content is the target. (#163)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await store.addDroppedURLs(urls) }
            return true
        } isTargeted: { targeted in
            // Fade, not bounce; skip the animation entirely under Reduce Motion.
            if reduceMotion {
                isDropTargeted = targeted
            } else {
                withAnimation(.easeInOut(duration: 0.15)) { isDropTargeted = targeted }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(isDropTargeted ? 1 : 0)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
        // Right-click "Add Bookmark…" on a resolved internal wiki link: the
        // menu item (WikiLinkMenuNSItems) already resolved the page/source id,
        // so we just hand the context to the existing bookmark-picker sheet.
        // Attached on `baseContent` (not `body`) so the `body` modifier chain
        // stays under the SwiftUI type-checker's complexity budget. Issue #188.
        .environment(\.addBookmarkHandler) { ctx in
            omniboxBookmarkContext = ctx
        }
    }

    /// The agent is doing work — running, or in a local pdf2md extraction / an
    /// agent-phase ingest (the extraction phase precedes the agent process).
    /// Drives the toolbar glow. Both phase flags are included so the glow stays
    private var zoteroContainerDirectory: URL {
        (DebugLog.trying("resolve app group container", operation: { try DatabaseLocation.appGroupContainerDirectory() })) ?? FileManager.default.temporaryDirectory
    }

    private var isZoteroConfigured: Bool {
        ZoteroConfig.load(from: zoteroContainerDirectory).isConfigured
            && KeychainZoteroCredentialStore().apiKey() != nil
    }

    /// The active wiki's configured home page, if any (issue #280). `nil` hides
    /// the omnibox home button. Verifies the page still exists so a stale
    /// `homePageID` (e.g. the page was deleted) hides the button instead of
    /// leaving a dead Home button that silently does nothing.
    private var activeHomePageID: PageID? {
        guard let id = session.descriptor.homePageID,
              store.summaries.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// The selected-document/source detail pane, extracted so the `HStack`'s
    /// view builder stays under the type-checker's complexity budget.
    // MARK: - Detail column (extracted so `body` stays type-checkable; the
    // NavigationSplitView + its full modifier chain is otherwise too large for
    // the SwiftUI type-checker once the search-upgrade sheet was added).
    @ViewBuilder
    private var detailColumn: some View {
        HStack(spacing: 0) {
            // Main column: tab bar + content. The transcript lives INSIDE the
            // detail column (not a separate inspector layer) so opening it
            // compresses the content INWARDS — matching how the leading
            // navigation sidebar subdivides the window — instead of growing the
            // window. It shares the detail column's full height, so it sits at
            // the same height as the leading sidebar rather than under the tab bar.
            VStack(spacing: 0) {
                // Safari-style: the tab strip is only shown when there are 2+
                // tabs. With 0 or 1 tabs there's nothing to switch, so the strip
                // is removed (the detail pane reclaims the vertical space). New
                // tabs are still created from the sidebar / shortcuts, which
                // crosses the 1→2 threshold and re-shows the strip.
                if store.tabs.count > 1 {
                    TabBarView(store: store)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                wikiDetailPane
            }

            // Trailing change-log sidebar (hidden by default; toggled from the
            // toolbar). Same in-column pattern as the transcript above: the
            // content compresses inwards rather than the window growing.
            if store.isChangeLogSidebarVisible {
                Divider()
                ChangeLogDetailView(store: store, compact: true)
                    .frame(width: 340)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if rightInspector.isPresented, let registration = rightInspector.registration {
                Divider()
                RightSidebarHostView(registration: registration)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: store.tabs.count > 1)
        .animation(.easeInOut(duration: 0.18), value: store.isChangeLogSidebarVisible)
        .animation(.easeInOut(duration: 0.18), value: rightInspector.isPresented)
        // Measure the detail column's width — the span the toolbar covers — and
        // feed it to the omnibox. Measuring here is reliable in every state the
        // field's own leading edge is not: this view never lands in toolbar
        // overflow, so the omnibox width can't get stranded (see
        // `AddressBarView`/`OmniboxLayout`).
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { detailWidth = $0 }
        // Hidden buttons for keyboard shortcuts.
        .background { keyboardShortcutButtons }
        // The toolbar is declared on the DETAIL column (not the split-view root)
        // on purpose: a centered `.principal` item then centers within the detail
        // region rather than across the whole split-view window.
        .toolbar {
            // Centered layout: Back/Forward/Home stays flush-left, the omnibox is
            // a smaller `.principal` item, and the right controls stay together
            // after a flexible spacer.
            ToolbarItem(placement: .navigation) {
                OmniboxNavButtons(store: store, homePageID: activeHomePageID)
            }
            ToolbarItem(placement: .principal) {
                AddressBarView(store: store, isFocused: $addressBarFocused,
                               detailWidth: detailWidth,
                               sidebarVisible: columnVisibility != .detailOnly,
                               onAddToBookmarks: { omniboxBookmarkContext = $0 })
            }
            ToolbarSpacer(.flexible)
            ToolbarItemGroup(placement: .automatic) {
                WikiSwitcher(registry: registry, currentWikiID: session.wikiID)
                Button {
                    rightInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .disabled(!rightInspector.isAvailable)
                .help(rightInspectorHelp)
            }
        }
        // Suppress the window title so the omnibox owns the toolbar. `.navigationTitle("")`
        // alone only empties the *text* — the toolbar still reserves ~160pt for the
        // title item, dead space between the omnibox and the switcher that (with a long
        // wiki name) shoves the whole omnibox group into the `»` overflow. `.toolbar(
        // removing: .title)` drops the title item itself, reclaiming that width — the
        // supported API for this, unlike the fragile `titleVisibility = .hidden` hack
        // (which doesn't reclaim the slot here and can't be applied once the omnibox is
        // in the overflow panel anyway).
        .navigationTitle("")
        .toolbar(removing: .title)
    }

    private var wikiDetailPane: some View {
        WikiDetailView(
            store: store,
            launcher: agentLauncher,
            session: session,
            fileProvider: fileProvider,
            extractionCoordinator: extractionCoordinator,
            queueEngine: queueEngine,
            extractionProvider: extractionProvider,
            installedRendererHost: installedRendererHost,
            onRendererActivation: onRendererActivation,
            runIngest: { id in runIngest(sourceID: id) },
            showingImportMarkdown: $showingImportMarkdown,
            showingAddFromZotero: $showingAddFromZotero,
            isZoteroConfigured: isZoteroConfigured
        )
        .frame(maxWidth: .infinity)
        .swipeNavigation(store: store)
    }

    private var rightInspectorHelp: String {
        guard rightInspector.isAvailable else { return "No Inspector Available" }
        return rightInspector.isPresented ? "Hide Inspector" : "Show Inspector"
    }

    private func runIngest(sourceID: SourceID) {
        DebugLog.ingest("ContentView.runIngest: user pressed Ingest (sourceID=\(sourceID.rawValue))")
        Task {
            store.flushPendingSaves()
            await enqueueIngestion(
                sourceIDs: [sourceID],
                store: store,
                wikiID: session.wikiID,
                queueEngine: queueEngine)
        }
    }

    private func handleSidebarRevealVersionChange() {
        if columnVisibility == .detailOnly {
            columnVisibility = .all
        }
    }

    // MARK: - Keyboard shortcuts

    /// Hidden buttons that provide Cmd+W, Cmd+Shift+T, Cmd+1–9, Cmd+L, and the
    /// five global "Add" shortcuts (Cmd+Shift+P/U/F/D/C). Placed in the detail
    /// background so they're always in the responder chain.
    @ViewBuilder
    private var keyboardShortcutButtons: some View {
        // Cmd+W: Close active tab
        Button("") { if let id = store.activeTabID { store.closeTab(id: id) } }
            .keyboardShortcut("w", modifiers: .command)
            .opacity(0).allowsHitTesting(false)
            .disabled(store.tabs.isEmpty)

        // Cmd+Shift+T: Reopen last closed tab
        Button("") { store.reopenLastClosedTab() }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .opacity(0).allowsHitTesting(false)
            .disabled(store.recentlyClosedTabs.isEmpty)

        // Cmd+L: Focus the address bar (always focus, never toggle — browser
        // convention: repeated Cmd-L keeps focus).
        Button("") {
            if !addressBarFocused { addressBarFocused = true }
        }
        .keyboardShortcut("l", modifiers: .command)
        .opacity(0).allowsHitTesting(false)

        // Cmd+Shift+P: Add Page (same handler as the sidebar + / welcome addPage).
        Button("") { store.newPageInNewTab() }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .opacity(0).allowsHitTesting(false)

        // Cmd+Shift+U: Add from URL (present the sheet with an empty field,
        // same as the sidebar onAddFromURL / welcome addURLHandler?("")).
        Button("") { pendingAddURL = PendingAddURL(url: "") }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .opacity(0).allowsHitTesting(false)

        // Cmd+Shift+F: Add File (open panel → store.addFiles; mirrors
        // WikiDetailView.addFile exactly).
        Button("") {
            if let url = WikiFilePanels.chooseFile(title: "Add File", prompt: "Add File") {
                Task { await store.addFiles([url]) }
            }
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .opacity(0).allowsHitTesting(false)

        // Cmd+Shift+D: Add Folder (present ImportMarkdownSheet, same as the
        // sidebar / welcome showingImportMarkdown toggle).
        Button("") { showingImportMarkdown = true }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .opacity(0).allowsHitTesting(false)

        // Cmd+Shift+C: Add Chat (same handler as the chats sidebar + / the
        // address-bar "new chat" button — store.openTab(.newChat)).
        Button("") { store.openTab(.newChat) }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .opacity(0).allowsHitTesting(false)

        // Cmd+1 through Cmd+9: Switch to tab by position (first 9 tabs only)
        ForEach(Array(store.tabs.prefix(9).enumerated()), id: \.element.id) { i, tab in
            Button("") { store.selectTab(id: tab.id) }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                .opacity(0).allowsHitTesting(false)
        }
    }

}

/// The window key for one activated renderer. `WindowGroup(for:)` dedups by
/// `==`, so activating the same content twice focuses the open window instead
/// of stacking a second one.
///
/// `id` covers the renderer and the exact bytes but not the block that carried
/// them, so the same drawing embedded on two pages deliberately shares one
/// window: the windows would be identical.
struct RendererActivationPresentation: Identifiable, Codable, Hashable {
    let reference: RendererReference
    let input: RendererBridgeInput
    let wikiID: WikiID
    let id: String

    init(reference: RendererReference, input: RendererBridgeInput, wikiID: WikiID) {
        self.reference = reference
        self.input = input
        self.wikiID = wikiID
        let encodedInput: String
        switch input {
        case .inlineArtifact(let artifact):
            encodedInput = artifact.bytes.base64EncodedString()
        case .source(let versionID):
            encodedInput = "source:\(versionID.rawValue)"
        case .markdown(let versionID):
            encodedInput = "markdown:\(versionID.rawValue)"
        }
        id = [
            reference.packageID.rawValue,
            reference.version.rawValue,
            reference.registrationID.rawValue,
            encodedInput
        ].joined(separator: "|")
    }

    /// `RendererBridgeInput` is `Equatable` but not `Hashable`, and widening a
    /// Core contract to key a window would be the wrong trade — `id` already
    /// encodes the renderer and its exact bytes.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.wikiID == rhs.wikiID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(wikiID)
    }
}

/// Resolves the activating wiki's store for the renderer window through the
/// shared `SessionManager`, mirroring `PageVersionCompareWindow`. A restored
/// window whose wiki is not open lands on the unavailable state rather than
/// holding a stale store.
struct RendererActivationWindow: View {
    let sessionManager: SessionManager
    let installedRendererHost: InstalledRendererHost
    let context: RendererActivationPresentation?

    var body: some View {
        if let context, let session = sessionManager.sessions[context.wikiID] {
            RendererActivationView(
                store: session.store,
                installedRendererHost: installedRendererHost,
                request: context)
        } else {
            ContentUnavailableView {
                Label("Renderer Unavailable", systemImage: "rectangle.slash")
            } description: {
                Text("Open the wiki that holds this content, then activate the renderer again.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One activated renderer, hosted as the content of a value-driven
/// `WindowGroup` — a real, resizable, non-modal window (see `WikiFSApp`). The
/// window's own traffic lights close it, so there is no in-content Close
/// control; Escape closes it too, the habit a reader brings from Quick Look.
struct RendererActivationView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: WikiStoreModel
    let installedRendererHost: InstalledRendererHost
    let request: RendererActivationPresentation

    var body: some View {
        rendererContent
            .frame(minWidth: 520, minHeight: 420)
            .navigationTitle(title)
            .onExitCommand { dismiss() }
    }

    @ViewBuilder
    private var rendererContent: some View {
        if let descriptor = rendererDescriptor {
            if let builtInView = BuiltInRendererFactoryMap.makeView(
                for: descriptor,
                inputs: builtInInputs) {
                builtInView
            } else if let packageView = packageRendererView(for: descriptor) {
                packageView
            } else {
                unavailableView(reason: "The renderer could not be presented.")
            }
        } else {
            unavailableView(reason: "The selected renderer is unavailable.")
        }
    }

    private var title: String {
        switch request.reference.registrationID.rawValue {
        case "json-canvas": return "JSON Canvas"
        case "excalidraw": return "Excalidraw"
        default: return request.reference.registrationID.rawValue
        }
    }

    private var rendererDescriptor: RendererDescriptor? {
        BuiltInRendererDescriptors.all.first(where: { $0.reference == request.reference })
        ?? installedRendererHost.inputs.enabledDescriptors.first(where: { $0.reference == request.reference })
    }

    private var builtInInputs: BuiltInRendererFactoryInputs {
        let inputBytes: Data?
        let mermaidMarkdown: String?
        switch request.input {
        case .inlineArtifact(let artifact):
            inputBytes = artifact.bytes
            let rawMarkdown = String(decoding: artifact.bytes, as: UTF8.self)
            mermaidMarkdown = MermaidSourceDetector.renderableMarkdown(from: rawMarkdown)
        case .source:
            inputBytes = nil
            mermaidMarkdown = nil
        case .markdown:
            inputBytes = nil
            mermaidMarkdown = nil
        }
        return BuiltInRendererFactoryInputs(
            sourceBytes: inputBytes,
            pdfQuote: nil,
            htmlSource: nil,
            mermaidMarkdown: mermaidMarkdown,
            mediaTarget: nil,
            selection: store.selection,
            store: store,
            readerZoom: .constant(Double(ZoomScale.defaultScale)))
    }

    private func packageRendererView(for descriptor: RendererDescriptor) -> AnyView? {
        guard case .inlineArtifact = request.input else {
            return nil
        }
        let inputReader = RendererAuthorizedInputReader(
            store: store.internalStore,
            authorizedInput: request.input)
        return installedRendererHost.factory.makeView(
            for: descriptor,
            inputs: installedRendererHost.inputs,
            inputReader: inputReader,
            onFailure: { failure in
                DebugLog.reader("Installed renderer presentation failed: \(failure.kind)")
            })
    }

    @ViewBuilder
    private func unavailableView(reason: String) -> some View {
        ContentUnavailableView {
            Label("Renderer Unavailable", systemImage: "rectangle.slash")
        } description: {
            Text(reason)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RightSidebarHostView: View {
    let registration: RightSidebarRegistration

    var body: some View {
        DetailInspectorView(
            inspectorTab: registration.inspectorTab,
            outlineWidth: registration.outlineWidth,
            availableTabs: registration.availableTabs,
            metadataState: registration.metadataState,
            origin: registration.origin,
            history: registration.history,
            onOpenChat: registration.onOpenChat,
            onCompareVersions: registration.onCompareVersions,
            performMetadataAction: { target in
                do { try registration.metadataRouter.route(action: target) }
                catch { DebugLog.tabs("Metadata action failed: \(error.localizedDescription)") }
            },
            openMetadataLink: { target in
                do { try registration.metadataRouter.route(link: target) }
                catch { DebugLog.tabs("Metadata link failed: \(error.localizedDescription)") }
            }
        ) {
            registration.outline()
        }
    }
}

/// The "Add from URL" sheet's presentation payload: the URL to pre-fill the
/// field with (empty when launched from the toolbar / empty-state buttons).
/// Identifiable so `.sheet(item:)` can present + auto-clear it on dismiss.
private struct PendingAddURL: Identifiable {
    let id = UUID()
    let url: String
}
