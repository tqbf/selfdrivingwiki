import SwiftUI
import WikiFSCore

/// The active wiki's shell: a sidebar (wiki switcher + pages + files) and a
/// detail pane that edits the selected page, the system prompt, or shows a
/// designed empty state (§7.1 ContentUnavailableView). Hosted by `RootView`,
/// which swaps it wholesale (via `.id`) when the user switches wikis.
struct ContentView: View {
    @Bindable var store: WikiStoreModel
    @Bindable var manager: WikiManager
    let fileProvider: FileProviderSpike
    @Bindable var agentLauncher: AgentLauncher
    let askLauncher: AgentLauncher
    let editLauncher: AgentLauncher
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
    }

    /// NavigationSplitView + drop / overlay / toolbar. Split out of `body` so the
    /// full modifier chain stays under the SwiftUI type-checker's complexity
    /// budget (adding the search-upgrade sheet tipped the single expression over).
    @ViewBuilder
    private var baseContent: some View {
        NavigationSplitView {
            SidebarView(store: store, manager: manager, fileProvider: fileProvider,
                        launcher: agentLauncher,
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
        // Drop a file anywhere on the window to ingest it (raw bytes → SQLite →
        // the read-only `files/` projection). The whole content is the target.
        .dropDestination(for: URL.self) { urls, _ in
            Task { await store.ingest(fileURLs: urls) }
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
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.left", action: navigateBack)
                    .disabled(!store.canNavigateBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Go back")

                Button("Forward", systemImage: "chevron.right", action: navigateForward)
                    .disabled(!store.canNavigateForward)
                    .keyboardShortcut("]", modifiers: .command)
                    .help("Go forward")
            }

            primaryToolbarItems()
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

    private func navigateBack() {
        store.navigateBack()
    }

    private func navigateForward() {
        store.navigateForward()
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
                AddressBarView(store: store, isFocused: $addressBarFocused)
                TabBarView(store: store)
                wikiDetailPane
            }

            if isTranscriptExpanded {
                Divider()
                AgentTranscriptSidebar(launcher: agentLauncher, onWikiLink: WikiReaderView.onWikiLinkHandler(for: store))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isTranscriptExpanded)
        // Hidden buttons for keyboard shortcuts.
        .background { keyboardShortcutButtons }
    }

    private var wikiDetailPane: some View {
        WikiDetailView(
            store: store,
            launcher: agentLauncher,
            askLauncher: askLauncher,
            editLauncher: editLauncher,
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
                manager: manager,
                fileProvider: fileProvider,
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
