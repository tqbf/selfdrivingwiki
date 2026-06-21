import SwiftUI
import WikiFSCore

/// One row in the sidebar's "Files" section. Multi-select is handled natively
/// by the List (Shift+Arrow, Shift+Click, Command+Click). Right-click offers
/// Open, Remove, and "Ingest Selected" when this file is part of a selection.
///
/// The trailing status icon has two distinct in-flight labels, mirroring the two
/// phases in `AgentLauncher`: **Extracting…** while a pdf2md conversion for this
/// file is in flight (`isExtracting`, the extraction phase), and **Ingesting…**
/// once the agent run for this file has committed (`isIngesting`, the agent
/// phase). Both are always-mounted (no insert/remove transitions); the icon
/// simply swaps between spinner and the ready/ingested glyph.
struct SourceRow: View {
    let source: SourceSummary
    let hasBeenIngested: Bool
    /// True while the agent run for this source is in flight (the agent phase —
    /// set at spawn commit, not during the preceding pdf2md extraction).
    var isIngesting: Bool = false
    /// True while a pdf2md conversion for this source is in flight (the extraction
    /// phase — either the ingest-path conversion or a standalone extract).
    var isExtracting: Bool = false
    /// True when this source is part of the List's multi-selection.
    var isSelected: Bool = false
    let onOpen: () -> Void
    let onRemove: () -> Void
    /// Ingest all currently-selected sources (shown in context menu when this
    /// source is part of a multi-source selection).
    var onIngestSelected: (() -> Void)? = nil

    /// The trailing status the row shows for a source, mirroring the two phases in
    /// `AgentLauncher`. Extracted as a pure static function so the precedence
    /// (extraction phase > agent phase > ready/ingested) is unit-testable
    /// without driving launcher state. The View calls this with its row state.
    enum RowStatus: Equatable, Sendable {
        /// pdf2md conversion in flight (extraction phase).
        case extracting
        /// Agent run committed for this source (agent phase).
        case ingesting
        /// Already ingested, idle.
        case ingested
        /// Not yet ingested, idle.
        case ready
    }

    /// Pure precedence predicate for the row's trailing status: extraction phase
    /// beats agent phase beats the idle glyphs. Mirrors the two-flag split — a
    /// pure extraction never shows "Ingesting…" and vice versa.
    static func rowStatus(
        isExtracting: Bool, isIngesting: Bool, hasBeenIngested: Bool
    ) -> RowStatus {
        if isExtracting { return .extracting }
        if isIngesting { return .ingesting }
        return hasBeenIngested ? .ingested : .ready
    }

    var body: some View {
        let status = Self.rowStatus(
            isExtracting: isExtracting, isIngesting: isIngesting,
            hasBeenIngested: hasBeenIngested)
        Label {
            HStack(spacing: 8) {
                Text(source.filename.isEmpty ? "Untitled" : source.filename)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(Self.sizeFormatter.string(fromByteCount: Int64(source.byteSize)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                switch status {
                case .extracting:
                    // Extraction phase: pdf2md converting, agent not spawned yet.
                    ProgressView()
                        .controlSize(.small)
                        .help("Extracting…")
                case .ingesting:
                    // Agent phase: claude run committed for this source.
                    ProgressView()
                        .controlSize(.small)
                        .help("Ingesting…")
                case .ingested, .ready:
                    Image(systemName: status == .ingested ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.caption)
                        .foregroundStyle(status == .ingested ? .green : .secondary)
                        .help(status == .ingested
                              ? "Ingested into the wiki"
                              : "Ready to ingest into the wiki")
                }
            }
        } icon: {
            Image(systemName: Self.symbol(for: source))
        }
        .contentShape(Rectangle())
        .contextMenu {
            if isSelected, let onIngestSelected {
                Button("Ingest Selected", systemImage: "text.badge.plus", action: onIngestSelected)
                Divider()
            }
            Button("Open", systemImage: "arrow.up.forward.app", action: onOpen)
            Button("Remove", role: .destructive, action: onRemove)
        }
        .swipeActions(edge: .trailing) {
            Button("Remove", role: .destructive, action: onRemove)
        }
    }

    /// An SF Symbol chosen by MIME type: rich-text doc for PDFs, plain-text doc
    /// for text/*, generic doc otherwise.
    private static func symbol(for source: SourceSummary) -> String {
        if source.mimeType == "application/pdf" { return "doc.richtext" }
        if let mime = source.mimeType, mime.hasPrefix("text/") { return "doc.plaintext" }
        return "doc"
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
