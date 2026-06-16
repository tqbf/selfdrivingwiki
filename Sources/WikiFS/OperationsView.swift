import AppKit
import SwiftUI
import WikiFSCore

/// The Ingest / Query / Lint sheet (`plans/llm-wiki.md` Phase C). Generalizes the
/// v0 "Run Agent" sheet into the three discrete operations, each a one-shot
/// `claude -p` scoped to the active wiki: an Ingest source picker, a Query input,
/// a Lint button, the streaming output panel, and the PATH-preflight error.
///
/// Type scale matches the rest of the app's utility surfaces (`.headline` title,
/// `.subheadline` secondary, monospaced code), per typography-designer +
/// macos-design — a clean, native, simple presentation.
struct OperationsView: View {
    @Bindable var launcher: AgentLauncher
    @Bindable var store: WikiStoreModel
    @Bindable var manager: WikiManager
    let fileProvider: FileProviderSpike
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKind: WikiOperation.Kind = .ingest
    @State private var selectedSourceID: PageID?
    @State private var queryText = ""

    init(
        launcher: AgentLauncher,
        store: WikiStoreModel,
        manager: WikiManager,
        fileProvider: FileProviderSpike,
        initialSourceID: PageID? = nil
    ) {
        self.launcher = launcher
        self.store = store
        self.manager = manager
        self.fileProvider = fileProvider
        _selectedSourceID = State(initialValue: initialSourceID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OperationMetrics.sectionSpacing) {
            header
            operationPicker
            inputSection
            controls
            AgentActivityView(launcher: launcher)
            footer
        }
        .padding(OperationMetrics.padding)
        .frame(width: OperationMetrics.sheetWidth, height: OperationMetrics.sheetHeight)
        .onAppear(perform: reconcileSelectedSource)
        .onChange(of: store.ingestedFiles.map(\.id)) { _, _ in
            reconcileSelectedSource()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Maintain Wiki")
                .font(.headline)
            Text("Run an agent against ‘\(activeWikiName)’. It reads the mount and writes via wikictl.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var operationPicker: some View {
        Picker("Operation", selection: $selectedKind) {
            ForEach(WikiOperation.Kind.allCases, id: \.self) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(launcher.isRunning)
    }

    // MARK: - Per-operation input

    @ViewBuilder
    private var inputSection: some View {
        switch selectedKind {
        case .ingest: ingestInput
        case .query: queryInput
        case .lint: lintInput
        }
    }

    private var ingestInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source")
                .font(.subheadline)
                .fontWeight(.medium)
            if store.ingestedFiles.isEmpty {
                Text("No ingested files yet. Drag a file onto the window, or use ‘Add from URL…’ in the sidebar, to ingest one first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker("Source file", selection: $selectedSourceID) {
                    Text("Choose a file…").tag(PageID?.none)
                    ForEach(store.ingestedFiles) { file in
                        Text(file.filename).tag(PageID?.some(file.id))
                    }
                }
                .labelsHidden()
                .disabled(launcher.isRunning)
            }
            Text("The agent reads the source, writes summary pages, updates index.md, and logs the ingest.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var queryInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Question")
                .font(.subheadline)
                .fontWeight(.medium)
            TextEditor(text: $queryText)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: OperationMetrics.inputHeight)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if queryText.isEmpty {
                        Text("Ask a question about the wiki…")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(launcher.isRunning)
        }
    }

    private var lintInput: some View {
        Text("Lint health-checks the wiki for contradictions, stale claims, orphan pages, and missing cross-references, then reports findings below.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            if launcher.isRunning {
                Button("Stop", systemImage: "stop.fill") { launcher.stop() }
                    .tint(.red)
                ProgressView().controlSize(.small)
                if let kind = launcher.runningKind {
                    Text("Running \(kind.title)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Run \(selectedKind.title)", systemImage: "play.fill") { run() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canRun)
            }
            Spacer()
            wikiRootLabel
        }
    }

    @ViewBuilder
    private var wikiRootLabel: some View {
        if let root = fileProvider.path {
            Label(root, systemImage: "folder")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
                .lineLimit(1)
                .help("WIKI_ROOT — the live read-only File Provider mount")
        } else if selectedKind == .ingest {
            Label("Ingest can run without the mount", systemImage: "doc.badge.plus")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(fileProvider.status)
        } else if fileProvider.isResolvingPath {
            Label("Resolving mount…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label(fileProvider.status, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help(fileProvider.status)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            statusLabel
            Spacer()
            revealLogButton
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    /// "Reveal log" surfaces the per-run `run.jsonl` backend log (raw stream-json)
    /// in Finder for after-the-fact debugging. Shown once a run has produced a log.
    @ViewBuilder
    private var revealLogButton: some View {
        if let logURL = launcher.logFileURL {
            Button("Reveal Log", systemImage: "doc.text.magnifyingglass") {
                NSWorkspace.shared.activateFileViewerSelecting([logURL])
            }
            .help("Show this run's raw stream-json log (run.jsonl) in Finder")
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let status = launcher.exitStatus {
            Label(
                status == 0 ? "Finished" : "Exited \(status)",
                systemImage: status == 0 ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(status == 0 ? .green : .red)
        } else if launcher.isRunning {
            Text("The editor is locked while the agent works.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Derived

    private var activeWikiName: String {
        guard let id = manager.activeWikiID,
              let descriptor = manager.wikis.first(where: { $0.id == id })
        else { return "this wiki" }
        return descriptor.displayName
    }

    /// Run is enabled when the operation's required input is present. Ingest can
    /// run from staged SQLite bytes without a mount; Query/Lint still need one.
    private var canRun: Bool {
        guard manager.activeWikiID != nil else { return false }
        switch selectedKind {
        case .ingest:
            return selectedSourceID != nil
        case .query:
            return fileProvider.path != nil
                && !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .lint:
            return fileProvider.path != nil
        }
    }

    // MARK: - Run

    private func run() {
        Task {
            switch selectedKind {
            case .ingest:
                guard let selectedSourceID else { return }
                await AgentOperationRunner.runIngest(
                    fileID: selectedSourceID,
                    launcher: launcher,
                    store: store,
                    manager: manager,
                    fileProvider: fileProvider)
            case .query:
                await AgentOperationRunner.runQuery(
                    question: queryText,
                    launcher: launcher,
                    store: store,
                    manager: manager,
                    fileProvider: fileProvider)
            case .lint:
                await AgentOperationRunner.runLint(
                    launcher: launcher,
                    store: store,
                    manager: manager,
                    fileProvider: fileProvider)
            }
        }
    }

    private func reconcileSelectedSource() {
        guard selectedKind == .ingest else { return }
        if let selectedSourceID,
           store.ingestedFiles.contains(where: { $0.id == selectedSourceID }) {
            return
        }
        selectedSourceID = store.ingestedFiles.first?.id
    }
}

/// Layout constants for the operations sheet (§2.4 — no scattered magic numbers).
private enum OperationMetrics {
    static let sheetWidth: CGFloat = 660
    static let sheetHeight: CGFloat = 560
    static let padding: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let inputHeight: CGFloat = 72
}
