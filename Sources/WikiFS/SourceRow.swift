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
    /// Open all currently-selected sources (batch). Replaces single Open
    /// with "Open N Sources" when batch-selected.
    var onOpenSelected: (() -> Void)? = nil
    /// Open all selected sources in background tabs (batch).
    var onOpenInBackgroundSelected: (() -> Void)? = nil
    var openSelectedCount: Int = 0
    let onRemove: () -> Void
    /// Delete all currently-selected sources (shown when batch-selected,
    /// replaces single Delete with "Delete N Sources").
    var onRemoveSelected: (() -> Void)? = nil
    var deleteSelectedCount: Int = 0
    /// Begin renaming this source's display name (shown in the context menu).
    var onRename: (() -> Void)? = nil
    /// Ingest this single source. Shown for single-select; replaced by
    /// `onIngestSelected` (with count) for multi-select.
    var onIngest: (() -> Void)? = nil
    /// Ingest all currently-selected sources (shown in context menu when this
    /// source is part of a multi-source selection, replacing the single Ingest).
    var onIngestSelected: (() -> Void)? = nil
    var ingestSelectedCount: Int = 0
    /// When set, a Share item appears in the context menu. The caller passes
    /// the File Provider mount-path URL to NSSharingServicePicker.
    var onShare: (() -> Void)? = nil
    /// Open this source's detail view in a background tab.
    var onOpenInBackground: (() -> Void)? = nil
    /// Share ALL currently-selected sources (shown in context menu when this
    /// source is part of a multi-source selection, replacing the single Share).
    /// The count is used for the menu item label ("Share N Sources").
    var onShareSelected: (() -> Void)? = nil
    var shareSelectedCount: Int = 0
    /// Extract markdown from this PDF source. Shown only for PDFs that
    /// haven't been extracted yet.
    var onExtract: (() -> Void)? = nil
    /// Batch-extract all selected PDF sources.
    var onExtractSelected: (() -> Void)? = nil
    var extractCount: Int = 0
    var canExtract: Bool = false
    /// Reveal this source file in a Finder window. Shown only for single selection.
    var onRevealInFinder: (() -> Void)? = nil

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
                Text(source.displayName ?? (source.filename.isEmpty ? "Untitled" : source.filename))
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
            let isMulti = isSelected && openSelectedCount > 1
            if isMulti, let onOpenSelected {
                Button("Open \(openSelectedCount) Sources",
                       systemImage: "arrow.up.forward.app", action: onOpenSelected)
            } else {
                Button("Open", systemImage: "arrow.up.forward.app", action: onOpen)
            }
            if isMulti, let onOpenInBackgroundSelected {
                Button("Open \(openSelectedCount) in Background",
                       systemImage: "dock.arrow.down.rectangle",
                       action: onOpenInBackgroundSelected)
            } else if let onOpenInBackground {
                Button("Open in Background", systemImage: "dock.arrow.down.rectangle",
                       action: onOpenInBackground)
            }
            if isMulti, let onShareSelected {
                Button("Share \(shareSelectedCount) Sources",
                       systemImage: "square.and.arrow.up",
                       action: onShareSelected)
            } else if let onShare {
                Button("Share", systemImage: "square.and.arrow.up", action: onShare)
            }
            if !isMulti, let onRevealInFinder {
                Button("Reveal in Finder", systemImage: "folder", action: onRevealInFinder)
            }
            if isMulti, let onIngestSelected {
                Divider()
                Button("Ingest \(ingestSelectedCount) Sources",
                       systemImage: "text.badge.plus", action: onIngestSelected)
            } else if let onIngest {
                Divider()
                Button("Ingest", systemImage: "text.badge.plus", action: onIngest)
            }
            if isMulti, let onExtractSelected, canExtract {
                Divider()
                Button("Extract \(extractCount) Sources",
                       systemImage: "doc.plaintext", action: onExtractSelected)
            } else if let onExtract, canExtract {
                Divider()
                Button("Extract Markdown", systemImage: "doc.plaintext", action: onExtract)
            }
            Divider()
            if !isMulti, let onRename {
                Button("Rename", systemImage: "pencil", action: onRename)
            }
            if isMulti, let onRemoveSelected {
                Button("Delete \(deleteSelectedCount) Sources",
                       systemImage: "trash", role: .destructive, action: onRemoveSelected)
            } else {
                Button("Delete", systemImage: "trash", role: .destructive, action: onRemove)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive, action: onRemove)
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
