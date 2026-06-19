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
    @State private var showingPathPopover = false
    @State private var showingMaintainSheet = false
    @State private var isTranscriptExpanded = false
    /// Driven by `.dropDestination`'s `isTargeted` callback to fade in a subtle
    /// accent border while a drag hovers the window (set via the closure param —
    /// no `Binding(get:set:)`).
    @State private var isDropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, manager: manager, fileProvider: fileProvider)
        } detail: {
            HStack(spacing: 0) {
                WikiDetailView(
                    store: store,
                    launcher: agentLauncher,
                    manager: manager,
                    fileProvider: fileProvider,
                    runIngest: runIngest
                )

                if isTranscriptExpanded && !isQuerySelected {
                    Divider()
                    AgentTranscriptSidebar(launcher: agentLauncher)
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
                // Light up (tint + pulse) while the agent is busy — including the
                // PDF-conversion phase, before the agent process itself starts — so
                // the user can tell something is running and open the transcript.
                .foregroundStyle(agentBusy ? Color.orange : Color.primary)
                .symbolEffect(.pulse, isActive: agentBusy)
                .help(isTranscriptExpanded ? "Hide agent transcript" : "Show agent transcript")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Maintain Wiki", systemImage: "sparkles") {
                    showingMaintainSheet = true
                }
                .help("Query the wiki or lint it")
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
        .sheet(isPresented: $showingMaintainSheet) {
            OperationsView(
                launcher: agentLauncher,
                store: store,
                manager: manager,
                fileProvider: fileProvider
            )
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
        }
        // Auto-open the transcript the moment an ingest starts — even during the
        // PDF-conversion phase, before the agent process spawns — so the
        // conversion box is visible.
        .onChange(of: agentLauncher.ingestingFileID) { _, newValue in
            if newValue != nil && !isQuerySelected {
                isTranscriptExpanded = true
            }
        }
    }

    /// The agent is doing work — running, or in the local PDF-conversion phase of
    /// an ingest (which precedes the agent process). Drives the toolbar glow.
    private var agentBusy: Bool {
        agentLauncher.isRunning || agentLauncher.ingestingFileID != nil
    }

    private var canShowTranscript: Bool {
        !isQuerySelected
            && (agentLauncher.isRunning
                || agentLauncher.ingestingFileID != nil
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

    private func navigateBack() {
        store.navigateBack()
    }

    private func navigateForward() {
        store.navigateForward()
    }

    private func runIngest(fileID: PageID) {
        DebugLog.ingest("ContentView.runIngest: user pressed Ingest (fileID=\(fileID.rawValue))")
        let task = Task {
            defer { agentLauncher.ingestTask = nil }
            await AgentOperationRunner.runIngest(
                fileID: fileID,
                launcher: agentLauncher,
                store: store,
                manager: manager,
                fileProvider: fileProvider)
        }
        agentLauncher.ingestTask = task
    }
}
