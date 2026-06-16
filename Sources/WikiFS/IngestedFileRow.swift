import SwiftUI
import WikiFSCore

/// One row in the sidebar's "Files" section: an ingested file's name + size.
/// Selecting the row opens a file detail pane with the agent-ingest affordance;
/// the context menu keeps direct file actions close at hand.
struct IngestedFileRow: View {
    let file: IngestedFileSummary
    let hasBeenIngested: Bool
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Label {
            HStack(spacing: 8) {
                Text(file.filename.isEmpty ? "Untitled" : file.filename)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(Self.sizeFormatter.string(fromByteCount: Int64(file.byteSize)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: hasBeenIngested ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(hasBeenIngested ? .green : .secondary)
                    .help(hasBeenIngested ? "Ingested into the wiki" : "Ready to ingest into the wiki")
            }
        } icon: {
            Image(systemName: Self.symbol(forExtension: file.ext))
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.app", action: onOpen)
            Button("Remove", role: .destructive, action: onRemove)
        }
        .swipeActions(edge: .trailing) {
            Button("Remove", role: .destructive, action: onRemove)
        }
    }

    /// An SF Symbol chosen by extension: rich-text doc for PDFs, plain-text doc
    /// for txt/markdown, generic doc otherwise.
    private static func symbol(forExtension ext: String) -> String {
        switch ext {
        case "pdf": return "doc.richtext"
        case "txt", "md", "markdown": return "doc.plaintext"
        default: return "doc"
        }
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
