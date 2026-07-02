import SwiftUI
import WikiFSCore

/// A browser-style address bar at the top of the detail pane. Serves two roles
/// depending on focus state — no explicit mode switch required:
///
/// 1. **Idle (not focused):** displays the active page's wikilink
///    (`[[Page Title]]`), read-only — the "where am I" indicator, like a
///    browser URL bar.
/// 2. **Focused / typing:** becomes a semantic search field. Typing debounces
///    into `store.searchSimilar(query:)` and shows a ranked dropdown of matching
///    pages. Selecting a result (or pressing Enter) navigates to it.
///
/// No agent query in v1 — pure location display + fast ranked search.
struct AddressBarView: View {
    @Bindable var store: WikiStoreModel
    @Binding var isFocused: Bool

    @State private var queryText = ""
    @State private var results: [WikiPageSummary] = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        bar
            .overlay(alignment: .top) {
                if fieldFocused && !results.isEmpty {
                    resultsDropdown
                        .padding(.top, AddressBarMetrics.height)
                }
            }
            // Cmd-L drives `isFocused` from the parent; sync it into the real
            // `@FocusState`. Only the parent→field direction — the field→parent
            // direction is handled in the `fieldFocused` observer below.
            .onChange(of: isFocused) { _, focused in
                if focused { fieldFocused = true }
            }
            .onChange(of: fieldFocused) { _, focused in
                if focused {
                    // Clear on focus so typing starts a fresh search (the
                    // wikilink display was just for the idle state).
                    queryText = ""
                    results = []
                } else {
                    isFocused = false
                    queryText = ""
                    results = []
                }
            }
    }

    // MARK: - Bar

    @ViewBuilder
    private var bar: some View {
        ZStack {
            // Idle: read-only wikilink label.
            if !fieldFocused {
                idleLabel
            }
            // Editable field — always present so focus can be driven externally.
            TextField("Search pages…", text: $queryText)
            .textFieldStyle(.plain)
            .font(.system(.callout, design: .monospaced))
            .focused($fieldFocused)
            .opacity(fieldFocused ? 1 : 0)
            .onSubmit { submitTopResult() }
            .onChange(of: queryText) { _, _ in runSearch() }
            .onKeyPress(.escape) {
                cancel()
                return .handled
            }
        }
        .padding(.horizontal, AddressBarMetrics.horizontalPadding)
        .frame(height: AddressBarMetrics.height)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .contentShape(Rectangle())
        .onTapGesture {
            fieldFocused = true
        }
        .overlay(alignment: .bottom) {
            Divider().opacity(PageEditorMetrics.dividerOpacity)
        }
    }

    /// The read-only wikilink display shown when the bar is not focused.
    @ViewBuilder
    private var idleLabel: some View {
        HStack(spacing: 0) {
            if addressString.isEmpty {
                Text("Search pages…")
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "link")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
                Text(addressString)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Results dropdown

    private var resultsDropdown: some View {
        VStack(spacing: 0) {
            ForEach(results) { result in
                resultRow(result)
                if result.id != results.last?.id {
                    Divider()
                        .padding(.horizontal, 8)
                        .opacity(0.3)
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.secondary.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(.horizontal, 4)
        .zIndex(1)
    }

    @ViewBuilder
    private func resultRow(_ result: WikiPageSummary) -> some View {
        Button {
            navigate(to: result)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(result.title)
                    .lineLimit(1)
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func runSearch() {
        searchTask?.cancel()
        let trimmed = queryText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
            results = store.searchSimilar(query: trimmed, limit: 8)
        }
    }

    private func submitTopResult() {
        guard let first = results.first else { return }
        navigate(to: first)
    }

    private func navigate(to result: WikiPageSummary) {
        store.selectPage(byTitle: result.title)
        fieldFocused = false
    }

    private func cancel() {
        fieldFocused = false
    }

    // MARK: - Address string

    /// Resolves the active selection to its wikilink notation. Non-page
    /// selections show a best-effort pseudo-wikilink so the bar is never blank
    /// when something is open.
    private var addressString: String {
        guard let selection = store.activeTab?.selection else { return "" }
        switch selection {
        case .page(let id):
            let title = store.summaries.first { $0.id == id }?.title ?? ""
            return title.isEmpty ? "" : "[[\(title)]]"
        case .source(let id):
            let name = store.sources.first { $0.id == id }?.effectiveName ?? ""
            return name.isEmpty ? "" : "[[source:\(name)]]"
        case .systemPrompt:
            return "[[system-prompt]]"
        case .changeLog:
            return "[[log]]"
        case .ask:
            return "[[ask]]"
        case .edit:
            return "[[edit]]"
        case .lint:
            return "[[lint]]"
        case .bookmark:
            return ""
        }
    }
}

// MARK: - Metrics

enum AddressBarMetrics {
    /// Matches the tab bar height for visual rhythm.
    static let height: CGFloat = 30
    /// Horizontal padding inside the bar.
    static let horizontalPadding: CGFloat = 10
}
