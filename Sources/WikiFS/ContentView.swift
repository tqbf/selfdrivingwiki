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
    @State private var showingAgentSheet = false
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
                    onIngestFile: runIngest
                )

                Divider()
                    .opacity(isTranscriptExpanded ? 1 : 0)

                AgentTranscriptSidebar(
                    launcher: agentLauncher,
                    isExpanded: isTranscriptExpanded,
                    onCollapse: collapseTranscript
                )
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
            ToolbarItem(placement: .primaryAction) {
                Button("Toggle Transcript", systemImage: "sidebar.trailing") {
                    toggleTranscript()
                }
                .disabled(!canShowTranscript)
                .help(isTranscriptExpanded ? "Hide agent transcript" : "Show agent transcript")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Maintain Wiki", systemImage: "sparkles") {
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
                fileProvider: fileProvider
            )
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
    }

    private var canShowTranscript: Bool {
        agentLauncher.isRunning
            || !agentLauncher.events.isEmpty
            || agentLauncher.preflightError != nil
            || !agentLauncher.stderr.isEmpty
    }

    private func toggleTranscript() {
        isTranscriptExpanded.toggle()
    }

    private func collapseTranscript() {
        isTranscriptExpanded = false
    }

    private func runIngest(fileID: PageID) {
        Task {
            await AgentOperationRunner.runIngest(
                fileID: fileID,
                launcher: agentLauncher,
                store: store,
                manager: manager,
                fileProvider: fileProvider)
        }
    }
}
