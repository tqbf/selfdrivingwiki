import SwiftUI
import WikiFSCore

/// A dedicated sheet for ingesting a single file into the wiki — shown when
/// the user clicks "Ingest Into Wiki" on a file.  No operation picker, no
/// Query/Lint — just the source filename, extraction status, and Run.
struct IngestSheetView: View {
    @Bindable var launcher: AgentLauncher
    @Bindable var store: WikiStoreModel
    let manager: WikiManager
    let fileProvider: FileProviderSpike
    let sourceID: PageID

    @Environment(\.dismiss) private var dismiss
    @State private var extractionReady = false
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            Text("Ingest into Wiki")
                .font(.headline)

            // Source
            VStack(alignment: .leading, spacing: 6) {
                Text("Source")
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let file = store.ingestedFiles.first(where: { $0.id == sourceID }) {
                    Text(file.filename)
                        .font(.callout)
                        .foregroundStyle(.primary)
                } else {
                    Text("Selected file")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("The agent reads the source, writes summary pages, updates index.md, and logs the ingest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Extraction status
                HStack(spacing: 6) {
                    Circle()
                        .fill(extractionReady ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(extractionReady
                         ? "PDF extraction ready"
                         : "PDF extraction needs ~2 GB download (slow first run)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Activity view
            AgentActivityView(launcher: launcher, showsInternals: false)

            // Footer
            HStack(spacing: 12) {
                if launcher.isRunning || isRunning {
                    ProgressView().controlSize(.small)
                    if let kind = launcher.runningKind {
                        Text("Running \(kind.title)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run Ingest") { run() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRun)
            }
        }
        .padding(20)
        .frame(width: 540, height: 400)
        .task { extractionReady = await PdfExtractionService.checkReady() }
    }

    private var canRun: Bool {
        !isRunning && !launcher.isRunning && manager.activeWikiID != nil
    }

    private func run() {
        isRunning = true
        Task {
            defer { isRunning = false }
            await AgentOperationRunner.runIngest(
                fileID: sourceID,
                launcher: launcher,
                store: store,
                manager: manager,
                fileProvider: fileProvider)
        }
    }
}
