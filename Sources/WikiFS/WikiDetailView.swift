import SwiftUI
import WikiFSCore

/// The main content pane for the current selection. Kept separate from
/// `ContentView` so the app shell owns layout/chrome while this view owns the
/// selected document/source surface.
struct WikiDetailView: View {
    @Bindable var store: WikiStoreModel
    @Bindable var launcher: AgentLauncher       // ingest/lint launcher
    @Bindable var askLauncher: AgentLauncher    // ask (read-only) conversation launcher
    @Bindable var editLauncher: AgentLauncher   // edit conversation launcher
    @Bindable var manager: WikiManager
    let fileProvider: FileProviderSpike
    let extractionCoordinator: ExtractionCoordinator
    let runIngest: (PageID) -> Void
    @Binding var showingImportMarkdown: Bool
    @Binding var showingAddFromZotero: Bool
    let isZoteroConfigured: Bool
    @Environment(\.addURLHandler) private var addURLHandler

    var body: some View {
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
                        introRow(title: "Pages", description: "Create and edit markdown notes with deep wiki-linking.", systemImage: "doc.text")
                        introRow(title: "Sources", description: "Manage and ingest raw material from URLs, folders, or Zotero.", systemImage: "tray.full")
                        introRow(title: "Bookmarks", description: "Organize pages and sources into a custom folder tree for quick access.", systemImage: "bookmark")
                        introRow(title: "Agent", description: "Query the agent, check wiki health, and view system logs.", systemImage: "sparkles")
                    }
                    .frame(maxWidth: 400)

                    VStack(spacing: 12) {
                        Text("Get Started")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        FlowLayout(spacing: 12) {
                            Button {
                                addURLHandler?("")
                            } label: {
                                Label("Add from URL", systemImage: "link.badge.plus")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            Button {
                                if let url = WikiFilePanels.chooseFile(title: "Add File", prompt: "Add File") {
                                    Task {
                                        await store.ingest(fileURLs: [url])
                                    }
                                }
                            } label: {
                                Label("Add File", systemImage: "doc.badge.plus")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            Button {
                                showingImportMarkdown = true
                            } label: {
                                Label("Add Folder", systemImage: "doc.badge.plus")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            if isZoteroConfigured {
                                Button {
                                    showingAddFromZotero = true
                                } label: {
                                    Label("Add from Zotero", systemImage: "books.vertical")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                            }
                        }
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 60)
                }
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity)
            }
        case .ask:
            QueryConversationView(
                mode: .ask,
                launcher: askLauncher,
                store: store,
                manager: manager,
                fileProvider: fileProvider
            )
        case .edit:
            QueryConversationView(
                mode: .edit,
                launcher: editLauncher,
                store: store,
                manager: manager,
                fileProvider: fileProvider
            )
        case .systemPrompt:
            SystemPromptDetailView(store: store)
        case .changeLog:
            ChangeLogDetailView(store: store)
        case .lint:
            LintView(
                launcher: launcher,
                store: store,
                manager: manager,
                fileProvider: fileProvider)
        case .page:
            PageDetailView(
                store: store,
                launcher: launcher,
                manager: manager,
                fileProvider: fileProvider)
        case .source(let id):
            if let file = store.sources.first(where: { $0.id == id }) {
                SourceDetailView(
                    file: file,
                    hasBeenIngested: store.isSourceIngested(file),
                    isIngesting: launcher.ingestingSourceIDs.contains(file.id),
                    isRunning: launcher.isRunning,
                    isAnySourceIngesting: !launcher.ingestingSourceIDs.isEmpty,
                    // This file is mid-extraction via EITHER path (the ingest-path
                    // pdf2md step or the standalone runExtraction) — both insert
                    // into `extractingSourceIDs`, so this is now extraction-phase
                    // driven rather than the old `isExtracting &&
                    // ingestingSourceIDs.contains` overload.
                    isThisFileExtracting: launcher.extractingSourceIDs.contains(file.id),
                    // True when the edit lock is held but NO ingest is in flight —
                    // the query agent is in Edit mode and owns the lock.
                    isEditLockedExternally: store.isAgentRunning && launcher.ingestingSourceIDs.isEmpty,
                    runIngest: runIngest,
                    launcher: launcher,
                    extractionCoordinator: extractionCoordinator,
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
                Label("Bookmarks", systemImage: "bookmark")
            } description: {
                Text("Bookmark folders are managed in the sidebar.")
            }
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
