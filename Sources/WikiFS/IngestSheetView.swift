import SwiftUI
import WikiFSCore

/// A small confirmation sheet for ingesting a single file into the wiki — shown
/// when the user clicks "Ingest Into Wiki" on a file. Running the ingest closes
/// the sheet immediately; all progress (PDF conversion + agent activity) lives in
/// the transcript sidebar.
struct IngestSheetView: View {
    @Bindable var launcher: AgentLauncher
    @Bindable var store: WikiStoreModel
    let manager: WikiManager
    let fileProvider: FileProviderSpike
    let sourceID: PageID

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ingest into Wiki")
                .font(.headline)

            if alreadyIngested {
                alreadyIngestedBanner
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Source")
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let file = sourceFile {
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
            }

            HStack {
                Spacer()
                Button("Ingest") { runAndClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRun)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { launcher.resetActivityIfIdle() }
    }

    private var sourceFile: IngestedFileSummary? {
        store.ingestedFiles.first(where: { $0.id == sourceID })
    }

    private var alreadyIngested: Bool {
        sourceFile.map(store.hasIngestedFile) ?? false
    }

    private var alreadyIngestedBanner: some View {
        Label(
            "This document has already been ingested. Running ingest again may create duplicate pages.",
            systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
    }

    private var canRun: Bool {
        !launcher.isRunning && launcher.ingestingFileID == nil && manager.activeWikiID != nil
    }

    /// Kick off the ingest and close the sheet — progress shows in the sidebar.
    private func runAndClose() {
        DebugLog.ingest("IngestSheetView.run: user pressed Run Ingest (sourceID=\(sourceID.rawValue))")
        let task = Task {
            defer { launcher.ingestTask = nil }
            await AgentOperationRunner.runIngest(
                fileID: sourceID,
                launcher: launcher,
                store: store,
                manager: manager,
                fileProvider: fileProvider)
        }
        // Publish the task so the sidebar's Stop button can cancel the conversion
        // phase (not just the agent process).
        launcher.ingestTask = task
        dismiss()
    }
}
