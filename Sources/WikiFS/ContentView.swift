import SwiftUI
import WikiFSEngine
import WikiFSCore
import WikiFSEngine

/// The active wiki's shell: a sidebar (wiki switcher + pages + files) and a
/// detail pane that edits the selected page, the system prompt, or shows a
/// designed empty state (§7.1 ContentUnavailableView). Hosted by `RootView`,
/// which swaps it wholesale (via `.id`) when the user switches wikis.
struct ContentView: View {
    @Bindable var store: WikiStoreModel
    @Bindable var manager: WikiManager
    let fileProvider: FileProviderSpike
    @Bindable var agentLauncher: AgentLauncher
    let chatLauncher: AgentLauncher
    let extractionCoordinator: ExtractionCoordinator
    @State private var isTranscriptExpanded = false
    /// Driven by `.dropDestination`'s `isTargeted` callback to fade in a subtle
    /// accent border while a drag hovers the window (set via the closure param —
    /// no `Binding(get:set:)`).
    @State private var isDropTargeted = false
    /// Drives the "Add from URL" sheet. Non-`nil` while presented; the wrapped
    /// URL pre-fills the field — empty for the toolbar / empty-state buttons,
    /// the absolute URL for the right-click "Add as Source" item (set via the
    /// `\.addURLHandler` environment value).
    @State private var pendingAddURL: PendingAddURL?
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .onChange(of: store.selection) { _, newValue in
            store.handleSelectionChange(to: newValue)
        }
        // "Show In List" reveal (issue #183): a detail-view button requested the
        // sidebar reveal a page/source. Un-collapse the sidebar so the target list
        // is actually mounted (SidebarView only mounts the active section).
        .onChange(of: store.pendingSidebarRevealVersion) { _, _ in
            if columnVisibility == .detailOnly {
                columnVisibility = .all
            }
        }
        .onChange(of: agentLauncher.isRunning) { _, isRunning in
            if isRunning {
                isTranscriptExpanded = true
            }
        }
        // Auto-open the transcript the moment an ingest starts — even during the
        // PDF-conversion phase, before the agent process spawns — so the
        // conversion box is visible. The extraction phase now lives in
        // `extractingSourceIDs` (distinct from the agent-phase `ingestingSourceIDs`),
        // so observe both: a pure extraction should also surface the transcript.
        .onChange(of: agentLauncher.ingestingSourceIDs) { _, newValue in
            if !newValue.isEmpty { isTranscriptExpanded = true }
        }
        .onChange(of: agentLauncher.extractingSourceIDs) { _, newValue in
            if !newValue.isEmpty { isTranscriptExpanded = true }
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
                kind: ctx.kind,
                ids: ctx.ids,
                onConfirm: { parentID in
                    for id in ctx.ids {
                        switch ctx.kind {
                        case .pages: store.addPageRef(parentID: parentID, pageID: id)
                        case .sources: store.addSourceRef(parentID: parentID, sourceID: id)
                        case .chats: store.addChatRef(parentID: parentID, chatID: id)
                        }
                    }
                }
            )
        }
        // Inject the shared find model so the toolbar's "Find on Page…" menu item
        // (`AddressBarView`, in a `ToolbarItem`) and the detail views' Cmd+F both
        // reach the same `FindModel` instance (#157).
        .environment(findModel)
    }

    /// NavigationSplitView + drop / overlay / toolbar. Split out of `body` so the
    /// full modifier chain stays under the SwiftUI type-checker's complexity
    /// budget (adding the search-upgrade sheet tipped the single expression over).
    @ViewBuilder
    private var baseContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(store: store, manager: manager, fileProvider: fileProvider,
                        launcher: agentLauncher,
                        chatLauncher: chatLauncher,
                        ingestingSourceIDs: agentLauncher.ingestingSourceIDs,
                        extractingSourceIDs: agentLauncher.extractingSourceIDs,
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
    /// on during a pure extraction; the cross-file Ingest greyout is NOT driven
    /// here (that is `isAnySourceIngesting` = `!ingestingSourceIDs.isEmpty` only).
    private var agentBusy: Bool {
        agentLauncher.isGenerating
            || !agentLauncher.ingestingSourceIDs.isEmpty
            || !agentLauncher.extractingSourceIDs.isEmpty
    }

    private var zoteroContainerDirectory: URL {
        (try? DatabaseLocation.appGroupContainerDirectory()) ?? FileManager.default.temporaryDirectory
    }

    private var isZoteroConfigured: Bool {
        ZoteroConfig.load(from: zoteroContainerDirectory).isConfigured
            && KeychainZoteroCredentialStore().apiKey() != nil
    }

    private var canShowTranscript: Bool {
        agentLauncher.isRunning
            || !agentLauncher.ingestingSourceIDs.isEmpty
            || !agentLauncher.extractingSourceIDs.isEmpty
            || !agentLauncher.events.isEmpty
            || agentLauncher.preflightError != nil
            || !agentLauncher.stderr.isEmpty
    }

    private func toggleTranscript() {
        isTranscriptExpanded.toggle()
    }

    /// The active wiki's display name (as shown in the toolbar's `WikiSwitcher`),
    /// passed to the omnibox so it can reserve room for a long switcher and shrink
    /// instead of pushing the switcher into overflow. Mirrors `WikiSwitcher`'s
    /// `activeDescriptor`.
    private var activeWikiName: String {
        guard let id = manager.activeWikiID,
              let wiki = manager.wikis.first(where: { $0.id == id }) else { return "No Wiki" }
        return wiki.displayName
    }

    /// The active wiki's configured home page, if any (issue #280). `nil` hides
    /// the omnibox home button.
    private var activeHomePageID: PageID? {
        guard let id = manager.activeWikiID,
              let wiki = manager.wikis.first(where: { $0.id == id }) else { return nil }
        return wiki.homePageID
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
            .animation(.easeInOut(duration: 0.18), value: store.tabs.count > 1)

            if isTranscriptExpanded {
                Divider()
                AgentActivitySidebar(launcher: agentLauncher, onWikiLink: WikiReaderView.onWikiLinkHandler(for: store))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isTranscriptExpanded)
        // Measure the detail column's width — the span the toolbar covers — and
        // feed it to the omnibox. Measuring here is reliable in every state the
        // field's own leading edge is not: this view never lands in toolbar
        // overflow, so the omnibox width can't get stranded (see
        // `AddressBarView`/`OmniboxLayout`).
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { detailWidth = $0 }
        // Hidden buttons for keyboard shortcuts.
        .background { keyboardShortcutButtons }
        // The toolbar is declared on the DETAIL column (not the split-view root)
        // on purpose: a `.principal` item on the root centers across the whole
        // window and overlaps the open sidebar, which makes NSToolbar dump the
        // whole group into the `»` overflow. Declared here it centers within the
        // detail region, so it survives the sidebar opening.
        .toolbar {
            // The omnibox group (Back / Forward + search field) is placed
            // `.navigation` so it flows flush-left from the leading edge of the
            // detail region (no centering gap). `AddressBarView` sizes the group
            // to an explicit width that fills up to the trailing wiki switcher —
            // the empty title space that would otherwise sit between them is
            // reclaimed by hiding the window title (see `OmniboxSearchField`'s
            // `viewDidMoveToWindow`). Declared on the detail column so it survives
            // the sidebar opening.
            ToolbarItem(placement: .navigation) {
                AddressBarView(store: store, isFocused: $addressBarFocused,
                               wikiName: activeWikiName,
                               detailWidth: detailWidth,
                               sidebarVisible: columnVisibility != .detailOnly,
                               homePageID: activeHomePageID,
                               onAddToBookmarks: { omniboxBookmarkContext = $0 })
            }

            // The wiki switcher moves out of the sidebar header into the toolbar,
            // trailing the omnibox (like a browser account / profile control).
            ToolbarItem(placement: .primaryAction) {
                WikiSwitcher(manager: manager)
            }

            primaryToolbarItems()
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
            chatLauncher: chatLauncher,
            manager: manager,
            fileProvider: fileProvider,
            extractionCoordinator: extractionCoordinator,
            runIngest: runIngest,
            showingImportMarkdown: $showingImportMarkdown,
            showingAddFromZotero: $showingAddFromZotero,
            isZoteroConfigured: isZoteroConfigured
        )
        .frame(maxWidth: .infinity)
    }

    private func runIngest(sourceID: PageID) {
        DebugLog.ingest("ContentView.runIngest: user pressed Ingest (sourceID=\(sourceID.rawValue))")
        let task = Task {
            defer { agentLauncher.ingestTask = nil }
            await AgentOperationRunner.runIngest(
                sourceID: sourceID,
                launcher: agentLauncher,
                store: store,
                wikiID: manager.activeWikiID ?? "",
                changeSignaler: fileProvider,
                wikictlDirectory: HelpersLocation.wikictlDirectory,
                extractionCoordinator: extractionCoordinator)
        }
        agentLauncher.ingestTask = task
    }

    // MARK: - Keyboard shortcuts

    /// Hidden buttons that provide Cmd+W, Cmd+Shift+T, Cmd+1–9, and Cmd+L
    /// shortcuts. Placed in the detail background so they're always in the
    /// responder chain.
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

        // Cmd+1 through Cmd+9: Switch to tab by position (first 9 tabs only)
        ForEach(Array(store.tabs.prefix(9).enumerated()), id: \.element.id) { i, tab in
            Button("") { store.selectTab(id: tab.id) }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                .opacity(0).allowsHitTesting(false)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func primaryToolbarItems() -> some ToolbarContent {
        transcriptToolbarItem()
    }

    @ToolbarContentBuilder
    private func transcriptToolbarItem() -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Toggle Transcript", systemImage: "sidebar.trailing") {
                toggleTranscript()
            }
            // The panel can ALWAYS be closed when it's open — `canShowTranscript`
            // only gates OPENING it when closed. Without this, a panel that
            // auto-expanded during a now-finished extract (no run, no events, no
            // stderr left) leaves `canShowTranscript == false`, disabling the only
            // close affordance and stranding the sidebar open.
            .disabled(!isTranscriptExpanded && !canShowTranscript)
            .foregroundStyle(agentBusy ? Color.orange : Color.primary)
            .symbolEffect(.pulse, isActive: agentBusy)
            .help(isTranscriptExpanded ? "Hide agent transcript" : "Show agent transcript")
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
