import SwiftUI
import WikiFSEngine
import WikiFSCore

/// The main content pane for the current selection. Kept separate from
/// `ContentView` so the app shell owns layout/chrome while this view owns the
/// selected document/source surface.
struct WikiDetailView: View {
    @Bindable var store: WikiStoreModel
    @Bindable var launcher: AgentLauncher       // ingest/lint + chat launcher
    @Bindable var chatLauncher: AgentLauncher   // chat launcher (write-capable)
    /// The per-active-wiki session (store + launchers + descriptor).
    var session: WikiSession
    let fileProvider: FileProviderFacade
    let extractionCoordinator: ExtractionCoordinator
    @Environment(QueueActivityTracker.self) private var tracker
    let queueEngine: QueueEngine
    let extractionProvider: any QueueExtractionProvider
    let runIngest: (PageID) -> Void
    @Binding var showingImportMarkdown: Bool
    @Binding var showingAddFromZotero: Bool
    let isZoteroConfigured: Bool
    @Environment(\.addURLHandler) private var addURLHandler

    /// Highlights the welcome screen as a drop target while an internal
    /// sidebar row (page/source/bookmark) is dragged over it.
    @State private var isSidebarDropTargeted = false

    var body: some View {
        detailContent
            // Accept an internal sidebar drag anywhere in the detail column —
            // dropping a page/source/bookmark onto the welcome screen OR onto any
            // open detail tab opens it as a tab and focuses it (openTab reuses an
            // existing tab if one is already open). Innermost drop target, so
            // URL/file drops still fall through to the window-level ingest
            // destination in ContentView.
            .dropDestination(for: SidebarDragPayloadList.self) { lists, _ in
                let payloads = lists.flatMap(\.items)
                guard !payloads.isEmpty else {
                    DebugLog.tabs("[drop] detail action fired with NO payload")
                    return false
                }
                for payload in payloads {
                    DebugLog.tabs("[drop] detail action fired: kind=\(payload.kind) id=\(payload.id)")
                    store.openTab(payload.selection)
                }
                return true
            } isTargeted: { targeted in
                isSidebarDropTargeted = targeted
            }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch store.selection {
        case .none:
            ScrollView {
                VStack(spacing: 32) {
                    VStack(spacing: 12) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 80, height: 80)
                        Text("Welcome to Self Driving Wiki")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        Text("An AI-powered knowledge base for your personal research.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 60)

                    VStack(alignment: .leading, spacing: 20) {
                        introRow(title: "Pages", description: "Create and edit markdown notes with deep wiki-linking.", systemImage: ResourceKind.page.systemImageName)
                        introRow(title: "Sources", description: "Manage and ingest raw material from URLs, folders, or Zotero.", systemImage: ResourceKind.source.systemImageName)
                        introRow(title: "Bookmarks", description: "Organize pages and sources into a custom folder tree for quick access.", systemImage: ResourceKind.bookmark.systemImageName)
                        introRow(title: "Chats", description: "Ask questions and edit your wiki through chat.", systemImage: ResourceKind.chat.systemImageName)
                    }
                    .frame(maxWidth: 400)

                    VStack(spacing: 12) {
                        Text("Get Started")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        // Three primary entry points, 1:1 with the intro rows
                        // above (Pages / Sources / Chats). The four ingestion
                        // actions collapse under a single "Add Source" menu.
                        FlowLayout(spacing: 12) {
                            Button("Add Page", systemImage: "doc.badge.plus", action: addPage)
                                .buttonStyle(.bordered)
                                .controlSize(.large)

                            Menu {
                                Button("Add from URL", systemImage: "link.badge.plus") {
                                    addURLHandler?("")
                                }
                                Button("Add File", systemImage: "doc", action: addFile)
                                Button("Add Folder", systemImage: "folder") {
                                    showingImportMarkdown = true
                                }
                                if isZoteroConfigured {
                                    Button("Add from Zotero", systemImage: "books.vertical") {
                                        showingAddFromZotero = true
                                    }
                                }
                            } label: {
                                Label("Add Source", systemImage: "tray.and.arrow.down")
                            }
                            .menuStyle(.button)
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            Button("Add Chat", systemImage: "plus.bubble", action: addChat)
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                        }
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 60)
                }
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity)
            }
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(isSidebarDropTargeted ? 0.08 : 0))
            }
        case .newChat:
            // D2: draft state — empty composer until the first send retargets the
            // tab to .chat(id). chatID == nil signals the draft state.
            ChatView(
                chatID: nil,
                store: store,
                launcher: chatLauncher,
                session: session,
                fileProvider: fileProvider
            )
        case .systemPrompt:
            SystemPromptDetailView(store: store)
        case .changeLog:
            ChangeLogDetailView(store: store)
        case .page:
            PageDetailView(
                store: store,
                launcher: launcher,
                session: session,
                fileProvider: fileProvider)
        case .source(let id):
            if let file = store.sources.first(where: { $0.id == id }) {
                SourceDetailView(
                    file: file,
                    hasBeenIngested: store.isSourceIngested(file),
                    isIngesting: tracker.ingestingSourceIDs.contains(file.id),
                    isRunning: launcher.isRunning,
                    isAnySourceIngesting: !tracker.ingestingSourceIDs.isEmpty,
                    // This file is mid-extraction via EITHER path (the ingest-path
                    // pdf2md step or the standalone runExtraction) — both insert
                    // into `extractingSourceIDs`, so this is now extraction-phase
                    // driven rather than the old `isExtracting &&
                    // ingestingSourceIDs.contains` overload.
                    isThisFileExtracting: tracker.extractingSourceIDs.contains(file.id),
                    // No edit lock — CAS prevents data races. Only extraction locks editing.
                    isEditLockedExternally: false,
                    runIngest: runIngest,
                    launcher: launcher,
                    extractionCoordinator: extractionCoordinator,
                    queueEngine: queueEngine,
                    extractionProvider: extractionProvider,
                    fileProvider: fileProvider,
                    store: store
                )
            } else {
                ContentUnavailableView {
                    Label("File Missing", systemImage: "doc.badge.questionmark")
                } description: {
                    Text("This ingested file is no longer available.")
                }
            }
        case .bookmark:
            ContentUnavailableView {
                Label("Bookmarks", systemImage: ResourceKind.bookmark.systemImageName)
            } description: {
                Text("Bookmark folders are managed in the sidebar.")
            }
        case .chat(let id):
            // D2: unified surface. Chats are always write-capable, so the single
            // chat launcher is bound directly.
            ChatView(
                chatID: id,
                store: store,
                launcher: chatLauncher,
                session: session,
                fileProvider: fileProvider
            )
        }
    }

    private func introRow(title: String, description: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Get Started actions

    /// Create an untitled page and open it in a new tab (mirrors the Pages
    /// sidebar `+` and the window toolbar's New Page).
    private func addPage() {
        store.newPageInNewTab()
    }

    /// Start a new chat in the draft state (mirrors the Chats sidebar `+`).
    private func addChat() {
        store.openTab(.newChat)
    }

    /// Pick a single file via the open panel and ingest it.
    private func addFile() {
        if let url = WikiFilePanels.chooseFile(title: "Add File", prompt: "Add File") {
            Task {
                await store.addFiles([url])
            }
        }
    }
}

/// A simple flow layout that wraps its subviews to the next line when they overflow the width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        _ = layout(proposal: proposal, subviews: subviews, bounds: bounds, place: true)
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews, bounds: CGRect = .zero, place: Bool = false) -> (size: CGSize, rows: Int) {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var rows = 1

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.minX + maxWidth && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += rowHeight + spacing
                rowHeight = 0
                rows += 1
            }

            if place {
                subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            }

            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, currentX - bounds.minX)
        }

        return (CGSize(width: totalWidth, height: currentY + rowHeight - bounds.minY), rows)
    }
}
