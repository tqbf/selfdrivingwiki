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
    @State private var isTranscriptExpanded = false
    /// Driven by `.dropDestination`'s `isTargeted` callback to fade in a subtle
    /// accent border while a drag hovers the window (set via the closure param —
    /// no `Binding(get:set:)`).
    @State private var isDropTargeted = false
    @State private var showingAddFromURL = false
    @State private var showingImportMarkdown = false
    @State private var showingAddFromZotero = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, manager: manager, fileProvider: fileProvider,
                        onBatchIngest: batchIngest,
                        ingestingSourceIDs: agentLauncher.ingestingSourceIDs,
                        extractingSourceIDs: agentLauncher.extractingSourceIDs)
        } detail: {
            VStack(spacing: 0) {
                TabBarView(store: store)

                HStack(spacing: 0) {
                    WikiDetailView(
                        store: store,
                        launcher: agentLauncher,
                        manager: manager,
                        fileProvider: fileProvider,
                        runIngest: runIngest,
                        showingAddFromURL: $showingAddFromURL,
                        showingImportMarkdown: $showingImportMarkdown,
                        showingAddFromZotero: $showingAddFromZotero,
                        isZoteroConfigured: isZoteroConfigured
                    )
                    .frame(maxWidth: .infinity)

                    if isTranscriptExpanded {
                        Divider()
                        AgentTranscriptSidebar(launcher: agentLauncher)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isTranscriptExpanded)
            }
            // Hidden buttons for keyboard shortcuts.
            .background { keyboardShortcutButtons }
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
        .sheet(isPresented: $showingAddFromURL) { AddFromURLSheet(store: store) }
        .sheet(isPresented: $showingImportMarkdown) { ImportMarkdownSheet(store: store) }
        .sheet(isPresented: $showingAddFromZotero) {
            AddFromZoteroSheet(store: store, containerDirectory: zoteroContainerDirectory)
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
    }

    /// The agent is doing work — running, or in a local pdf2md extraction / an
    /// agent-phase ingest (the extraction phase precedes the agent process).
    /// Drives the toolbar glow. Both phase flags are included so the glow stays
    /// on during a pure extraction; the cross-file Ingest greyout is NOT driven
    /// here (that is `isAnySourceIngesting` = `!ingestingSourceIDs.isEmpty` only).
    private var agentBusy: Bool {
        agentLauncher.isRunning
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

    private func runIngest(sourceID: PageID) {
        DebugLog.ingest("ContentView.runIngest: user pressed Ingest (sourceID=\(sourceID.rawValue))")
        let task = Task {
            defer { agentLauncher.ingestTask = nil }
            await AgentOperationRunner.runIngest(
                sourceID: sourceID,
                launcher: agentLauncher,
                store: store,
                manager: manager,
                fileProvider: fileProvider)
        }
        agentLauncher.ingestTask = task
    }

    private func batchIngest(sourceIDs: [PageID]) {
        DebugLog.ingest("ContentView.batchIngest: user pressed Ingest \(sourceIDs.count) sources")
        let task = Task {
            defer { agentLauncher.ingestTask = nil }
            await AgentOperationRunner.runMultiIngest(
                sourceIDs: sourceIDs,
                launcher: agentLauncher,
                store: store,
                manager: manager,
                fileProvider: fileProvider)
        }
        agentLauncher.ingestTask = task
    }

    // MARK: - Keyboard shortcuts

    /// Hidden buttons that provide Cmd+W, Cmd+Shift+T, and Cmd+1–9 shortcuts.
    /// Placed in the detail background so they're always in the responder chain.
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
        ingestToolbarItems()
        navigationToolbarItems()
        transcriptToolbarItem()
    }

    @ToolbarContentBuilder
    private func ingestToolbarItems() -> some ToolbarContent {
        if isZoteroConfigured {
            ToolbarItem(placement: .primaryAction) {
                Button("Add from Zotero…", systemImage: "books.vertical") {
                    showingAddFromZotero = true
                }.help("Browse your Zotero library and ingest a PDF or Markdown attachment")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Add from URL…", systemImage: "link.badge.plus") {
                showingAddFromURL = true
            }.help("Fetch a web page or PDF by URL and ingest it into this wiki")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Import Markdown Folder…", systemImage: "doc.badge.plus") {
                showingImportMarkdown = true
            }.help("Import all .md files from a folder as source material")
        }
    }

    @ToolbarContentBuilder
    private func navigationToolbarItems() -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("New Page", systemImage: "plus") { store.newPageInNewTab() }
                .keyboardShortcut("n", modifiers: .command)
                .help("Create a new page")
        }
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
