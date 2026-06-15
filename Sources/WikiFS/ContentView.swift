import SwiftUI
import WikiFSCore

/// Phase 1 shell: a sidebar of pages and a detail pane that either edits the
/// selected page or shows a designed empty state (§7.1 ContentUnavailableView).
/// The Phase 0 spike (WelcomeView / FileProviderSpike) is no longer hosted here
/// but still compiles in this target for Phase 2.
struct ContentView: View {
    @Bindable var store: WikiStoreModel
    let fileProvider: FileProviderSpike
    @Bindable var agentLauncher: AgentLauncher
    @State private var showingPathPopover = false
    @State private var showingAgentSheet = false
    /// Driven by `.dropDestination`'s `isTargeted` callback to fade in a subtle
    /// accent border while a drag hovers the window (set via the closure param —
    /// no `Binding(get:set:)`).
    @State private var isDropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store, fileProvider: fileProvider)
        } detail: {
            if store.selection == nil {
                ContentUnavailableView {
                    Label("No Page Selected", systemImage: "doc.text")
                } description: {
                    Text("Select a page from the sidebar, or create a new one.")
                } actions: {
                    Button("New Page", systemImage: "plus") { store.newPage() }
                }
            } else {
                PageDetailView(store: store)
            }
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
                Button("Run Agent", systemImage: "play.circle") {
                    showingAgentSheet = true
                }
                .help("Run a command with WIKI_ROOT set to the read-only mount")
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
            AgentLauncherView(launcher: agentLauncher, fileProvider: fileProvider)
        }
        // List(selection:) writes store.selection directly; observe it here so
        // the model flushes the outgoing page and loads the incoming one
        // (§3.5). The view, not the binding, is the right place for this.
        .onChange(of: store.selection) { _, newValue in
            store.handleSelectionChange(to: newValue)
        }
    }
}
