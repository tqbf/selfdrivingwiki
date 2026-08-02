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
    /// Owns this wiki's repo clones, the fetch loop, and the update queue.
    /// Created here (not in `RootView`) because `ContentView` is already rebuilt
    /// per wiki via `.id(manager.activeWikiID)` — so the tracker's identity, and
    /// its in-flight state, are correctly scoped to one wiki.
    @State private var tracker: RepoTracker
    @State private var showingPathPopover = false
    @State private var showingAgentSheet = false
    @State private var operationInitialSourceID: PageID?
    @State private var isTranscriptExpanded = false
    /// Driven by `.dropDestination`'s `isTargeted` callback to fade in a subtle
    /// accent border while a drag hovers the window (set via the closure param —
    /// no `Binding(get:set:)`).
    @State private var isDropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        store: WikiStoreModel,
        manager: WikiManager,
        fileProvider: FileProviderSpike,
        agentLauncher: AgentLauncher
    ) {
        self.store = store
        self.manager = manager
        self.fileProvider = fileProvider
        self.agentLauncher = agentLauncher
        _tracker = State(
            initialValue: RepoTracker(
                store: store, manager: manager,
                launcher: agentLauncher, fileProvider: fileProvider))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                store: store, manager: manager,
                fileProvider: fileProvider, tracker: tracker)
        } detail: {
            HStack(spacing: 0) {
                WikiDetailView(
                    store: store,
                    launcher: agentLauncher,
                    manager: manager,
                    fileProvider: fileProvider,
                    tracker: tracker,
                    onIngestFile: runIngest
                )

                if isTranscriptExpanded && !isQuerySelected {
                    Divider()
                    AgentTranscriptSidebar(
                        launcher: agentLauncher,
                        onCollapse: collapseTranscript
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isTranscriptExpanded)
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

            ToolbarItem(placement: .primaryAction) {
                Button("Toggle Transcript", systemImage: "sidebar.trailing") {
                    toggleTranscript()
                }
                .disabled(!canShowTranscript)
                .help(isTranscriptExpanded ? "Hide agent transcript" : "Show agent transcript")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Maintain Wiki", systemImage: "sparkles") {
                    operationInitialSourceID = nil
                    showingAgentSheet = true
                }
                .help("Run an agent: Ingest a source, Query the wiki, or Lint it")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Copy Unix Path", systemImage: "terminal") {
                    showingPathPopover = true
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .help("Copy the Terminal path of the read-only filesystem view")
                .popover(isPresented: $showingPathPopover, arrowEdge: .bottom) {
                    VerificationPopover(fileProvider: fileProvider)
                }
            }
        }
        .sheet(isPresented: $showingAgentSheet) {
            OperationsView(
                launcher: agentLauncher,
                store: store,
                manager: manager,
                fileProvider: fileProvider,
                tracker: tracker,
                initialSourceID: operationInitialSourceID
            )
        }
        // The repo poll loop lives for as long as this wiki is on screen.
        .task {
            tracker.start()
        }
        // List(selection:) writes store.selection directly; observe it here so
        // the model flushes the outgoing page and loads the incoming one
        // (§3.5). The view, not the binding, is the right place for this.
        .onChange(of: store.selection) { _, newValue in
            store.handleSelectionChange(to: newValue)
            if newValue == .query {
                isTranscriptExpanded = false
            }
        }
        .onChange(of: agentLauncher.isRunning) { _, isRunning in
            if isRunning && !isQuerySelected {
                isTranscriptExpanded = true
            }
            // A finished run is the tracker's cue that the single agent slot is
            // free again, so a queued repo can start.
            if !isRunning {
                tracker.agentRunDidFinish()
            }
        }
    }

    private var canShowTranscript: Bool {
        !isQuerySelected
            && (agentLauncher.isRunning
                || !agentLauncher.events.isEmpty
                || agentLauncher.preflightError != nil
                || !agentLauncher.stderr.isEmpty)
    }

    private var isQuerySelected: Bool {
        store.selection == .query
    }

    private func toggleTranscript() {
        isTranscriptExpanded.toggle()
    }

    private func collapseTranscript() {
        isTranscriptExpanded = false
    }

    private func navigateBack() {
        store.navigateBack()
    }

    private func navigateForward() {
        store.navigateForward()
    }

    private func runIngest(fileID: PageID) {
        operationInitialSourceID = fileID
        showingAgentSheet = true
    }
}
