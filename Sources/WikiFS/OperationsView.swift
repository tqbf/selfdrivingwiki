import AppKit
import SwiftUI
import WikiFSCore

/// The Query / Lint sheet, opened from the toolbar "Maintain Wiki" button.
/// No Ingest — that has its own dedicated sheet (`IngestSheetView`).
struct OperationsView: View {
    @Bindable var launcher: AgentLauncher
    @Bindable var store: WikiStoreModel
    @Bindable var manager: WikiManager
    let fileProvider: FileProviderSpike
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKind: WikiOperation.Kind = .query
    @State private var queryText = ""
    @State private var showsInternals = false
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: OperationMetrics.sectionSpacing) {
            header
            operationPicker
            inputSection
            controls
            AgentActivityView(launcher: launcher, showsInternals: showsInternals)
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

    private var activeWikiName: String {
        guard let id = manager.activeWikiID,
              let descriptor = manager.wikis.first(where: { $0.id == id })
        else { return "this wiki" }
        return descriptor.displayName
    }

    // MARK: - Operation picker

    private var operationPicker: some View {
        Picker("Operation", selection: $selectedKind) {
            ForEach(WikiOperation.Kind.allCases.filter { $0 != .ingest }, id: \.self) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(launcher.isRunning)
    }

    // MARK: - Input

    @ViewBuilder
    private var inputSection: some View {
        switch selectedKind {
        case .query: queryInput
        case .lint: lintInput
        case .ingest: EmptyView()  // not reachable — Ingest has its own sheet
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
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary, lineWidth: 1)
                )
            Text("Ask a question about the wiki. The agent reads the mount, references pages, and writes findings back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lintInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lint")
                .font(.subheadline)
                .fontWeight(.medium)
            Text("The agent reviews the wiki for stale content, broken links, and inconsistencies, then writes findings back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            if launcher.isRunning || isRunning {
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
            Toggle("Show internals", isOn: $showsInternals)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(.secondary)
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
            wikiStatusLabel
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var wikiStatusLabel: some View {
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        let now = fmt.string(from: Date())
        return Text("Wiki state as of \(now)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Run

    private var canRun: Bool {
        guard !isRunning, manager.activeWikiID != nil else { return false }
        switch selectedKind {
        case .query:
            return fileProvider.path != nil
                && !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .lint:
            return fileProvider.path != nil
        case .ingest:
            return false
        }
    }

    private func run() {
        isRunning = true
        Task {
            defer { isRunning = false }
            switch selectedKind {
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
            case .ingest:
                break
            }
        }
    }
}

/// Layout constants (§2.4 — no scattered magic numbers).
private enum OperationMetrics {
    static let sheetWidth: CGFloat = 540
    static let sheetHeight: CGFloat = 420
    static let padding: CGFloat = 20
    static let sectionSpacing: CGFloat = 14
    static let inputHeight: CGFloat = 80
}
