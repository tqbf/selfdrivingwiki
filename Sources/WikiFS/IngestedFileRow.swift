import SwiftUI
import WikiFSCore

/// One row in the sidebar's "Files" section: an ingested file's name + size.
/// Double-clicking (or the "Open" menu item) opens the file in its default app
/// (e.g. Preview for a PDF); remove is available via context menu and swipe.
/// The row carries NO `.tag(...)`, so it never participates in the
/// page-`List(selection:)` binding — clicking it can't load a phantom page.
struct IngestedFileRow: View {
    let file: IngestedFileSummary
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
            }
        } icon: {
            Image(systemName: Self.symbol(forExtension: file.ext))
        }
        // Whole row is the hit target; a double-click opens the file. Use a
        // simultaneous gesture so it doesn't swallow the context-menu / swipe.
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
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
