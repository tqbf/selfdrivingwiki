import SwiftUI
import WikiFSCore

/// A sheet to browse the user's Zotero library and ingest one or more
/// attachments (PDF and/or a converted Markdown sibling) from a chosen item —
/// the Zotero analog of `AddFromURLSheet`. Two-level: search results, then a
/// drill-down into the selected item's attachments.
///
/// `client`/`zoteroDir` are resolved ONCE at sheet creation from `ZoteroConfig`
/// + the credential store — if Settings change while the sheet is open, the
/// user reopens it to pick up the new value, matching the existing sheets'
/// "read state once, no live config reactivity" simplicity.
struct AddFromZoteroSheet: View {
    @Bindable var store: WikiStoreModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    private let client: ZoteroClient?
    private let zoteroDir: URL

    @State private var queryText = ""
    @State private var searchPhase: SearchPhase = .idle
    @State private var searchTask: Task<Void, Never>?

    @State private var selectedItem: ZoteroItem?
    @State private var attachmentRows: [AttachmentRow] = []
    @State private var attachmentsPhase: AttachmentsPhase = .idle
    @State private var selectedAttachmentKeys: Set<String> = []

    @State private var ingestPhase: IngestPhase = .idle

    private enum SearchPhase: Equatable {
        case idle
        case searching
        case results([ZoteroItem])
        case failed(String)
    }

    private enum AttachmentsPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private enum IngestPhase: Equatable {
        case idle
        case ingesting
        case failed(String)
    }

    /// One row in the attachment drill-down: the attachment plus whether it has
    /// a local copy ready to ingest right now (no network fallback in v1).
    private struct AttachmentRow: Identifiable {
        let attachment: ZoteroAttachment
        let source: ZoteroLocalStorage.AttachmentSource
        var id: String { attachment.key }
        var isAvailable: Bool {
            if case .local = source { return true }
            return false
        }
    }

    init(
        store: WikiStoreModel,
        containerDirectory: URL,
        credentialStore: any ZoteroCredentialStore = KeychainZoteroCredentialStore(),
        fetcher: any ZoteroClient.RequestFetcher = URLSessionZoteroFetcher()
    ) {
        self.store = store
        let config = ZoteroConfig.load(from: containerDirectory)
        zoteroDir = config.zoteroDirectory()
        if let libraryID = config.libraryID, !libraryID.isEmpty,
           let apiKey = credentialStore.apiKey(), !apiKey.isEmpty {
            client = ZoteroClient(config: ZoteroClient.Config(libraryID: libraryID, apiKey: apiKey), fetcher: fetcher)
        } else {
            client = nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            header
            if client == nil {
                notConfiguredState
            } else if let selectedItem {
                attachmentPicker(for: selectedItem)
            } else {
                searchResults
            }
            footer
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.width, height: Metrics.height)
        .task { if client != nil { runSearch() } }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Add from Zotero")
                .font(.headline)
            Text("Search your Zotero library and ingest a PDF or Markdown attachment.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Not configured

    private var notConfiguredState: some View {
        VStack(spacing: 10) {
            Spacer()
            Label("Zotero isn't set up yet", systemImage: "books.vertical")
                .font(.body)
            Text("Add your API key and library ID in Settings to browse your library.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings…") { openSettings() }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.contentHeight)
    }

    // MARK: - Search results

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search by title, author, or year", text: $queryText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: queryText) { runSearch() }

            switch searchPhase {
            case .idle, .searching:
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .frame(height: Metrics.contentHeight)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(height: Metrics.contentHeight, alignment: .top)
            case .results(let items):
                if items.isEmpty {
                    Text("No matching items.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(height: Metrics.contentHeight, alignment: .top)
                } else {
                    List(items) { item in
                        Button { selectItem(item) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title ?? "Untitled").font(.body)
                                if let subtitle = itemSubtitle(item) {
                                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(height: Metrics.contentHeight)
                }
            }
        }
    }

    private func itemSubtitle(_ item: ZoteroItem) -> String? {
        item.subtitle
    }

    // MARK: - Attachment picker (drill-down)

    private func attachmentPicker(for item: ZoteroItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("‹ Back to results") { deselectItem() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

            Text(item.title ?? "Untitled")
                .font(.body.weight(.medium))

            switch attachmentsPhase {
            case .idle, .loading:
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .frame(height: Metrics.contentHeight)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(height: Metrics.contentHeight, alignment: .top)
            case .loaded:
                if attachmentRows.isEmpty {
                    Text("No PDF or Markdown attachments on this item.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(height: Metrics.contentHeight, alignment: .top)
                } else {
                    List(attachmentRows) { row in
                        attachmentRowView(row)
                    }
                    .frame(height: Metrics.contentHeight)
                }
            }

            if case .failed(let message) = ingestPhase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func attachmentRowView(_ row: AttachmentRow) -> some View {
        HStack {
            Toggle(isOn: toggleBinding(for: row)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.attachment.filename ?? row.attachment.title ?? "Attachment")
                        .font(.body)
                    if !row.isAvailable {
                        Text("Not synced to this Mac yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!row.isAvailable)
        }
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

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if ingestPhase == .ingesting {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(ingestPhase == .ingesting)
            if selectedItem != nil {
                Button("Add Selected") { addSelected() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedAttachmentKeys.isEmpty || ingestPhase == .ingesting)
            }
        }
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
    /// failure (mirrors `WikiStoreModel.addFiles(_:)`) — one bad attachment
    /// shouldn't block the others. Dismisses only on full success.
    private func addSelected() {
        let toIngest = attachmentRows.filter { selectedAttachmentKeys.contains($0.id) }.map(\.attachment)
        guard !toIngest.isEmpty, let item = selectedItem else { return }
        ingestPhase = .ingesting
        Task {
            var failures: [String] = []
            for attachment in toIngest {
                do {
                    try await store.ingestFromZotero(attachment, parentItem: item, zoteroDir: zoteroDir)
                } catch {
                    let name = attachment.filename ?? attachment.title ?? attachment.key
                    failures.append("\(name): \(errorMessage(error))")
                }
            }
            if failures.isEmpty {
                dismiss()
            } else {
                ingestPhase = .failed(failures.joined(separator: "\n"))
            }
        }
    }

    private func errorMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Layout constants (§2.4 — no scattered magic numbers).
    private enum Metrics {
        static let width: CGFloat = 480
        static let height: CGFloat = 420
        static let contentHeight: CGFloat = 240
        static let padding: CGFloat = 20
        static let sectionSpacing: CGFloat = 14
    }
}
