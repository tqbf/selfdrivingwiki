import SwiftUI
import WikiFSCore

/// A small, native sheet to ingest a resource by URL: paste a URL, hit Fetch, and
/// on success the new file appears under Files (live, via the existing rebuild).
///
/// macos-design + typography-designer: a clean utility sheet — `.headline` title,
/// `.subheadline` secondary, one prominent URL field, a primary Fetch button, an
/// inline progress spinner while fetching, and an inline error row on failure.
/// SWIFTUI-RULES applied: the progress/error rows animate a DIMENSION via an
/// always-mounted height (§1.1, no insert/remove transition); state is read at the
/// click handler, not captured early (§3.5); semantic Dynamic-Type fonts (§5.1);
/// no formatters cached in `body`.
struct AddFromURLSheet: View {
    @Bindable var store: WikiStoreModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var urlText = ""
    @State private var phase: Phase = .idle
    @FocusState private var fieldFocused: Bool

    /// The fetch lifecycle. A small closed enum so the view derives every piece of
    /// UI from one value (§3.1) rather than juggling several bools.
    private enum Phase: Equatable {
        case idle
        case fetching
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            header
            urlField
            statusArea
            footer
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.width)
        .onAppear { fieldFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Add from URL")
                .font(.headline)
            Text("Fetch a web page or PDF and ingest it. HTML is converted to Markdown; PDFs and other files are stored as-is.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - URL field

    private var urlField: some View {
        TextField("https://example.com/article", text: $urlText)
            .textFieldStyle(.roundedBorder)
            .font(.body)
            .lineLimit(1)
            .focused($fieldFocused)
            .disabled(isFetching)
            .onSubmit { if canFetch { fetch() } }
            .onChange(of: urlText) {
                // Clear a stale error as soon as the user edits the URL.
                if case .failed = phase { phase = .idle }
            }
    }

    // MARK: - Status (progress / error) — always mounted, height-animated

    private var statusArea: some View {
        Group {
            switch phase {
            case .fetching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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

    /// Reserve room for the status row only when there's something to show — a
    /// dimension change (§1.1), never an insert/remove transition.
    private var statusHeight: CGFloat {
        switch phase {
        case .idle: return 0
        case .fetching: return Metrics.statusRowHeight
        case .failed: return Metrics.errorRowHeight
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isFetching)
            Button("Fetch") { fetch() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canFetch)
        }
    }

    // MARK: - Derived

    private var isFetching: Bool { phase == .fetching }

    private var canFetch: Bool {
        !isFetching && URLIngestService.normalizeURL(urlText) != nil
    }

    // MARK: - Action

    private func fetch() {
        // Read the field fresh at click time (§3.5), not a captured-early copy.
        let input = urlText
        guard URLIngestService.normalizeURL(input) != nil else { return }
        phase = .fetching
        Task {
            do {
                _ = try await store.ingestURL(input)
                dismiss()  // success: the new file is already in store.sources
            } catch {
                let message = (error as? URLIngestService.IngestError)?.errorDescription
                    ?? error.localizedDescription
                phase = .failed(message)
            }
        }
    }

    /// Layout constants (§2.4 — no scattered magic numbers).
    private enum Metrics {
        static let width: CGFloat = 460
        static let padding: CGFloat = 20
        static let sectionSpacing: CGFloat = 14
        static let statusRowHeight: CGFloat = 22
        static let errorRowHeight: CGFloat = 44
    }
}
