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
        } else {
            Label("Resolving mount…", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    /// Run is enabled only when the active wiki's mount is resolved and the
    /// operation's required input is present.
    private var canRun: Bool {
        guard manager.activeWikiID != nil, fileProvider.path != nil else { return false }
        switch selectedKind {
        case .ingest: return selectedSourceID != nil
        case .query: return !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .lint: return true
        }
    }

    // MARK: - Run

    private func run() {
        guard let wikiID = manager.activeWikiID else { return }

        Task {
            // Refresh the mount + resolve WIKI_ROOT at click time (never hardcoded),
            // so the agent sees current content before it reads.
            await fileProvider.signalChange()
            guard let root = fileProvider.path else { return }

            // Gather the live wiki state HERE, at click time (§3.5), and render it as
            // the WIKI_STATE.md the launcher stages — so the agent reads the CURRENT
            // titles / index.md / log tail from local disk and skips orientation.
            let stateMarkdown = store.currentStateSnapshot().renderStateFile()
            guard let request = makeRequest(stateMarkdown: stateMarkdown) else { return }

            let systemPrompt = store.currentSystemPromptBody()

            launcher.run(
                request: request,
                wikiID: wikiID,
                wikiRoot: root,
                systemPrompt: systemPrompt,
                wikictlDirectory: HelpersLocation.wikictlDirectory,
                onLock: { store.beginAgentRun() },
                onUnlock: { store.endAgentRun() }
            )
        }
    }

    /// Build the `OperationRequest` from the current selection + input. For Ingest,
    /// reads the source bytes from SQLite (not the mount) so the launcher can stage
    /// them; the Ingest mode (single Opus pass vs Opus curator + Sonnet digesters) is
    /// decided from the staged source size at stage time.
    private func makeRequest(stateMarkdown: String) -> OperationRequest? {
        switch selectedKind {
        case .ingest:
            guard let id = selectedSourceID,
                  let file = store.ingestedFiles.first(where: { $0.id == id }),
                  let bytes = store.ingestedSourceBytes(id: id)
            else { return nil }
            return .ingest(
                sourceBytes: bytes,
                ext: file.ext,
                sourcePath: ingestSourcePath(for: file),
                stateMarkdown: stateMarkdown)
        case .query:
            let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .query(question: trimmed, stateMarkdown: stateMarkdown)
        case .lint:
            return .lint(stateMarkdown: stateMarkdown)
        }
    }

    /// The mount-relative path of an ingested file's `files/by-id` projection, so
    /// the agent can Read it directly. Uses the SAME `FilenameEscaping` helper the
    /// projection uses for the leaf filename, so it can't drift.
    private func ingestSourcePath(for file: IngestedFileSummary) -> String {
        let leaf = FilenameEscaping.byIDIngestedFilename(fileID: file.id.rawValue, ext: file.ext)
        return "files/by-id/\(leaf)"
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
