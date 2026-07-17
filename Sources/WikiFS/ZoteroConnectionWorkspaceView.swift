import SwiftUI
import WikiFSCore

/// The Zotero connection's **workspace**: the native search-as-you-type picker
/// re-homed from the modal `AddFromZoteroSheet` into a connection *tab*. Same
/// two-level flow (search results → an item's PDF/Markdown attachments → "Add
/// Selected"), same seam (`store.ingestFromZotero` → `ZoteroMaterializer` →
/// `storeMaterialized`) — only the presentation changed from a sheet to a tab,
/// and the client is resolved from a `Connection` instead of app-wide
/// `ZoteroConfig`.
struct ZoteroConnectionWorkspaceView: View {
    @Bindable var store: WikiStoreModel
    let client: ZoteroClient?
    let zoteroDir: URL

    @State private var queryText = ""
    @State private var searchPhase: SearchPhase = .idle
    @State private var searchTask: Task<Void, Never>?

    @State private var selectedItem: ZoteroItem?
    @State private var attachmentRows: [AttachmentRow] = []
    @State private var attachmentsPhase: AttachmentsPhase = .idle
    @State private var selectedAttachmentKeys: Set<String> = []
    @State private var ingestPhase: IngestPhase = .idle
    @State private var lastAddedCount = 0

    private enum SearchPhase: Equatable {
        case idle, searching
        case results([ZoteroItem])
        case failed(String)
    }
    private enum AttachmentsPhase: Equatable {
        case idle, loading, loaded
        case failed(String)
    }
    private enum IngestPhase: Equatable {
        case idle, ingesting
        case failed(String)
    }

    private struct AttachmentRow: Identifiable {
        let attachment: ZoteroAttachment
        let source: ZoteroLocalStorage.AttachmentSource
        var id: String { attachment.key }
        var isAvailable: Bool {
            if case .local = source { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selectedItem {
                attachmentPicker(for: selectedItem)
            } else {
                searchResults
            }
            footer
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { runSearch() }
    }

    // MARK: - Search

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search by title, author, or year", text: $queryText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: queryText) { runSearch() }

            switch searchPhase {
            case .idle, .searching:
                centeredProgress
            case .failed(let message):
                errorLabel(message)
            case .results(let items):
                if items.isEmpty {
                    Text("No matching items.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    List(items) { item in
                        Button { selectItem(item) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title ?? "Untitled").font(.body)
                                if let subtitle = item.subtitle {
                                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }

    // MARK: - Attachment drill-down

    private func attachmentPicker(for item: ZoteroItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("‹ Back to results") { deselectItem() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

            Text(item.title ?? "Untitled").font(.body.weight(.medium))

            switch attachmentsPhase {
            case .idle, .loading:
                centeredProgress
            case .failed(let message):
                errorLabel(message)
            case .loaded:
                if attachmentRows.isEmpty {
                    Text("No PDF or Markdown attachments on this item.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    List(attachmentRows) { row in
                        Toggle(isOn: toggleBinding(for: row)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.attachment.filename ?? row.attachment.title ?? "Attachment")
                                    .font(.body)
                                if !row.isAvailable {
                                    Text("Not synced to this Mac yet")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!row.isAvailable)
                    }
                    .frame(maxHeight: .infinity)
                }
            }

            if case .failed(let message) = ingestPhase {
                errorLabel(message)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if ingestPhase == .ingesting {
                ProgressView().controlSize(.small)
            } else if lastAddedCount > 0 {
                Label("Added \(lastAddedCount) source\(lastAddedCount == 1 ? "" : "s")",
                      systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            }
            Spacer()
            if selectedItem != nil {
                Button("Add Selected") { addSelected() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedAttachmentKeys.isEmpty || ingestPhase == .ingesting)
            }
        }
    }

    // MARK: - Shared bits

    private var centeredProgress: some View {
        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func toggleBinding(for row: AttachmentRow) -> Binding<Bool> {
        Binding(
            get: { selectedAttachmentKeys.contains(row.id) },
            set: { isOn in
                if isOn { selectedAttachmentKeys.insert(row.id) }
                else { selectedAttachmentKeys.remove(row.id) }
            }
        )
    }

    // MARK: - Actions

    private func runSearch() {
        searchTask?.cancel()
        guard let client else { return }
        let query = queryText
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            searchPhase = .searching
            do {
                let items = try await client.searchItems(query: query)
                guard !Task.isCancelled else { return }
                searchPhase = .results(items)
            } catch {
                guard !Task.isCancelled else { return }
                searchPhase = .failed(errorMessage(error))
            }
        }
    }

    private func selectItem(_ item: ZoteroItem) {
        selectedItem = item
        selectedAttachmentKeys = []
        attachmentRows = []
        attachmentsPhase = .loading
        lastAddedCount = 0
        guard let client else { return }
        Task {
            do {
                let attachments = try await client.childAttachments(ofItemKey: item.key)
                attachmentRows = attachments
                    .filter(\.isIngestable)
                    .map { attachment in
                        AttachmentRow(
                            attachment: attachment,
                            source: ZoteroLocalStorage.resolve(attachment, zoteroDir: zoteroDir))
                    }
                attachmentsPhase = .loaded
            } catch {
                attachmentsPhase = .failed(errorMessage(error))
            }
        }
    }

    private func deselectItem() {
        selectedItem = nil
        attachmentRows = []
        attachmentsPhase = .idle
        selectedAttachmentKeys = []
        ingestPhase = .idle
    }

    /// Ingest every selected attachment, collect-and-continue on a per-item
    /// failure (mirrors `AddFromZoteroSheet.addSelected`). Stays on the item so
    /// the user can add more; a success count shows in the footer.
    private func addSelected() {
        let toIngest = attachmentRows
            .filter { selectedAttachmentKeys.contains($0.id) }
            .map(\.attachment)
        guard !toIngest.isEmpty, let item = selectedItem else { return }
        ingestPhase = .ingesting
        lastAddedCount = 0
        Task {
            var failures: [String] = []
            var added = 0
            for attachment in toIngest {
                do {
                    try await store.ingestFromZotero(attachment, parentItem: item, zoteroDir: zoteroDir)
                    added += 1
                } catch {
                    let name = attachment.filename ?? attachment.title ?? attachment.key
                    failures.append("\(name): \(errorMessage(error))")
                }
            }
            lastAddedCount = added
            selectedAttachmentKeys = []
            if failures.isEmpty {
                ingestPhase = .idle
            } else {
                ingestPhase = .failed(failures.joined(separator: "\n"))
            }
        }
    }

    private func errorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
