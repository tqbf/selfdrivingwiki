import SwiftUI
import WikiFSCore

/// Detail pane for one raw source file. The "Ingest into Wiki" button kicks off
/// the agent run directly — no intermediate confirmation sheet. Progress streams
/// into the transcript sidebar.
struct IngestedFileDetailView: View {
    let file: IngestedFileSummary
    let hasBeenIngested: Bool
    /// True while THIS file's ingest is in flight (local conversion + agent run).
    let isIngesting: Bool
    let isRunning: Bool
    let fileProvider: FileProviderSpike
    let onOpen: () -> Void
    /// Launch the ingest directly. Called with the source file's PageID.
    let runIngest: (PageID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
                Label {
                    Text(displayName)
                        .font(.largeTitle)
                        .bold()
                        .lineLimit(2)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    statusLabel
                    Text(Self.sizeFormatter.string(fromByteCount: Int64(file.byteSize)))
                    Text(file.createdAt, style: .date)
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                if alreadyIngested {
                    Label(
                        "This document has already been ingested. Running ingest again may create duplicate pages.",
                        systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .padding(10)
                        .background(.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                }

                HStack(spacing: 10) {
                    Button(isIngesting ? "Ingesting…" : "Ingest into Wiki",
                           systemImage: "text.badge.plus") {
                        DebugLog.ingest("IngestedFileDetailView: Ingest tapped — id=\(file.id.rawValue)")
                        runIngest(file.id)
                    }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(isRunning || isIngesting)
                    Button("Open File", systemImage: "arrow.up.forward.app") {
                        DebugLog.agent("IngestedFileDetailView: Open File tapped — id=\(file.id.rawValue)")
                        onOpen()
                    }
                }

                if !fileProvider.status.isEmpty, fileProvider.status != "Not registered" {
                    Label(fileProvider.status, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: PageEditorMetrics.readableContentWidth, alignment: .leading)
            .padding(PageEditorMetrics.contentInset)

            Divider().opacity(PageEditorMetrics.dividerOpacity)

            ContentUnavailableView {
                Label("Raw Source", systemImage: symbol)
            } description: {
                Text("This file is stored verbatim in the wiki. Ingesting asks the agent to read it, create or update wiki pages, refresh index.md, and append log.md.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var displayName: String {
        file.filename.isEmpty ? "Untitled" : file.filename
    }

    private var alreadyIngested: Bool { hasBeenIngested }

    @ViewBuilder
    private var statusLabel: some View {
        if isIngesting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Ingesting…")
            }
            .foregroundStyle(.orange)
        } else {
            Label(
                hasBeenIngested ? "Ingested" : "Ready to ingest",
                systemImage: hasBeenIngested ? "checkmark.circle.fill" : "circle.dashed"
            )
            .foregroundStyle(hasBeenIngested ? .green : .secondary)
        }
    }

    private var symbol: String {
        switch file.ext {
        case "pdf": "doc.richtext"
        case "txt", "md", "markdown": "doc.plaintext"
        default: "doc"
        }
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
