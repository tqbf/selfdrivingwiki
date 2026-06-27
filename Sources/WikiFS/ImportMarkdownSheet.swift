import SwiftUI
import WikiFSCore

/// A sheet for importing all Markdown files from a directory (Obsidian vault,
/// LogSeq graph, or any folder of `.md` files) as source material for the wiki.
///
/// The imported files land in `ingested_files` — exactly like drag-drop, URL
/// fetch, and Zotero. The user then runs Ingest to have the agent curate them
/// into wiki pages.
///
/// Follows `AddFromURLSheet`'s phase-enum pattern and `AddFromZoteroSheet`'s
/// progress + error-collection pattern.
///
/// macos-design + typography-designer: a clean utility sheet with `.headline`
/// title, `.subheadline` secondary, a directory picker, inline progress, and a
/// results summary. SWIFTUI-RULES: the status area is always-mounted +
/// height-animated (§1.1); state is read fresh at click time (§3.5); semantic
/// Dynamic-Type fonts (§5.1); no formatters cached in `body`.
struct ImportMarkdownSheet: View {
    @Bindable var store: WikiStoreModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var directoryURL: URL? = nil
    @State private var phase: Phase = .idle

    /// The directory picker + scan + import lifecycle.
    private enum Phase: Equatable {
        case idle
        case scanning
        case ready(fileCount: Int)
        case importing(imported: Int, errorCount: Int)
        case done(imported: Int, errors: [String])
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            header
            directoryPicker
            statusArea
            footer
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.width)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Import Folder")
                .font(.headline)
            Text("Select a folder to import as source material. All `.md` and `.pdf` files are imported recursively; frontmatter and [[wikilinks]] are preserved as-is.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Directory picker

    private var directoryPicker: some View {
        HStack(spacing: 8) {
            if let dir = directoryURL {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Text(dir.lastPathComponent)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("— \(dir.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            } else {
                Text("No folder selected")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose…") {
                chooseDirectory()
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
        }
    }

    // MARK: - Status area — always mounted, height-animated

    private var statusArea: some View {
        Group {
            switch phase {
            case .scanning:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning for files…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .ready(let count):
                Label("Found \(count) file\(count == 1 ? "" : "s").", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            case .importing(let imported, let errorCount):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Importing \(imported) file\(imported == 1 ? "" : "s")…" +
                         (errorCount > 0 ? " (\(errorCount) error\(errorCount == 1 ? "" : "s"))" : ""))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .done(let imported, let errors):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Imported \(imported) file\(imported == 1 ? "" : "s").", systemImage: "checkmark.seal.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                    if !errors.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(errors, id: \.self) { error in
                                Label(error, systemImage: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                Color.clear.frame(height: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: statusHeight, alignment: .top)
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: phase)
    }

    private var statusHeight: CGFloat {
        switch phase {
        case .idle: return 0
        case .scanning: return Metrics.statusRowHeight
        case .importing: return Metrics.statusRowHeight
        case .ready: return Metrics.statusRowHeight
        case .done(_, let errors): return errors.isEmpty ? Metrics.statusRowHeight : Metrics.doneWithErrorsHeight
        case .failed: return Metrics.errorRowHeight
        }
    }

    // MARK: - Footer

    private var isBusy: Bool {
        if case .scanning = phase { return true }
        if case .importing = phase { return true }
        return false
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            if case .idle = phase {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            } else if case .done = phase {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else if case .failed = phase {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isBusy)
            }

            if case .ready(let count) = phase {
                Button("Import \(count) File\(count == 1 ? "" : "s")") {
                    importFiles()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            } else if case .idle = phase, directoryURL != nil {
                Button("Scan Folder") {
                    scanDirectory()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Actions

    private func chooseDirectory() {
        guard let url = WikiFilePanels.chooseDirectory(
            title: "Choose Folder",
            prompt: "Select"
        ) else { return }
        directoryURL = url
        // Clear stale state when a new directory is chosen.
        scanDirectory()
    }

    private func scanDirectory() {
        guard let dir = directoryURL else { return }
        phase = .scanning
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                MarkdownFolderReader.walk(
                    directory: dir,
                    fileOps: MarkdownFolderReader.FileManagerFileOperations()
                )
            }.value
            if result.files.isEmpty, result.errors.isEmpty {
                phase = .failed("No valid files found in this folder.")
            } else if result.files.isEmpty {
                phase = .failed("No valid files found (\(result.errors.count) error\(result.errors.count == 1 ? "" : "s") reading the folder).")
            } else {
                phase = .ready(fileCount: result.files.count)
            }
        }
    }

    private func importFiles() {
        guard let dir = directoryURL else { return }
        phase = .importing(imported: 0, errorCount: 0)
        Task {
            let result = await store.importFromMarkdownFolder(directory: dir)
            if result.imported == 0, !result.errors.isEmpty {
                phase = .failed(result.errors.joined(separator: "\n"))
            } else {
                phase = .done(imported: result.imported, errors: result.errors)
            }
        }
    }

    // MARK: - Metrics

    private enum Metrics {
        static let width: CGFloat = 480
        static let padding: CGFloat = 20
        static let sectionSpacing: CGFloat = 14
        static let statusRowHeight: CGFloat = 22
        static let errorRowHeight: CGFloat = 44
        static let doneWithErrorsHeight: CGFloat = 90
    }
}
