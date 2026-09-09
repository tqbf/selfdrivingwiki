import SwiftUI

// MARK: - Overview presentation

/// Everything `QueueJobOverviewView` renders for the selected job's summary
/// surface: the complete target inventory, the section's kind-specific
/// language, and an optional result statement. Derived by the caller before
/// list iteration — plain values only.
///
/// Kind-specific scope/result language is the caller's mapping job (plan:
/// "operation-specific scope and result language"): `sectionTitle` is
/// "Sources" for ingestion/extraction and "Scope" or "Pages" for lint;
/// `resultStatement` carries wording like "Agent run completed; page-level
/// results not reported".
///
/// Run Details no longer lives here: the facts moved to the window's optional
/// Run Details inspector panel (`QueueRunDetailsView`), opened from the
/// toolbar.
struct QueueJobOverviewPresentation {
    /// Section noun: "Sources", "Pages", "Scope".
    let sectionTitle: String
    /// Displayed count ("12") — `nil` when unknown. Never pass `0` for an
    /// unknown count; unknown renders as nothing, not as an empty result.
    let countText: String?
    /// The complete planned/observed inventory. A whole-wiki job passes exactly
    /// one scope row (`identity: nil`, title "Whole wiki") — this view never
    /// enumerates the wiki to build itself.
    let rows: [QueueTargetRowValue]
    /// Job-level result statement, e.g. "Agent run completed; page-level
    /// results not reported". Rendered under the section header; `nil` hides it.
    let resultStatement: String?
    /// Empty-inventory message ("No sources recorded for this job.").
    let emptyStateText: String

    init(
        sectionTitle: String,
        countText: String? = nil,
        rows: [QueueTargetRowValue],
        resultStatement: String? = nil,
        emptyStateText: String
    ) {
        self.sectionTitle = sectionTitle
        self.countText = countText
        self.rows = rows
        self.resultStatement = resultStatement
        self.emptyStateText = emptyStateText
    }
}

// MARK: - Overview view

/// The Overview tab of the selected job workspace: section header with count
/// and local search, an optional result statement, and the complete target
/// inventory in a native scrolling List with shared rows (plan §1 layout).
/// Run Details lives in the window's optional inspector panel, not here.
///
/// Owns only local UI state (search text); rows are not collapsible. The
/// parent keeps this view mounted while the user toggles Overview/Activity;
/// remounting resets the local state, which is acceptable — streaming data
/// and scroll identity concerns belong to the Activity surface.
struct QueueJobOverviewView: View {
    private let presentation: QueueJobOverviewPresentation

    @State private var searchText = ""
    @FocusState private var isSearchFieldFocused: Bool

    init(_ presentation: QueueJobOverviewPresentation) {
        self.presentation = presentation
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionHeader
            resultStatementRegion
            inventoryRegion
        }
    }

    // MARK: Section header

    /// "Sources (12)                      [Find in Sources]"
    private var sectionHeader: some View {
        HStack(spacing: QueueWorkspaceMetrics.Spacing.sm) {
            Text(presentation.sectionTitle)
                .font(.headline)
            if let count = presentation.countText {
                Text(count)
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(presentation.sectionTitle): \(count)")
            }
            Spacer(minLength: QueueWorkspaceMetrics.Spacing.sm)
            if showsSearch {
                searchField
            }
        }
        .padding(.horizontal, QueueWorkspaceMetrics.Spacing.md)
        .padding(.vertical, QueueWorkspaceMetrics.Spacing.xs)
    }

    /// Local inventory search, surfaced only for large batches (plan: local
    /// search for large batches). Escape clears; the field never presents
    /// itself as searching beyond this job's loaded inventory.
    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField(
                "Find in \(presentation.sectionTitle)",
                text: $searchText
            )
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .focused($isSearchFieldFocused)
            .frame(maxWidth: 220)
            .onKeyPress(.escape) {
                guard !searchText.isEmpty else { return .ignored }
                searchText = ""
                return .handled
            }
            .accessibilityLabel("Find in \(presentation.sectionTitle)")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
    }

    /// Kind-specific result statement under the header — the truthful-notice
    /// surface ("No page-level results reported" is not an empty success).
    @ViewBuilder
    private var resultStatementRegion: some View {
        if let statement = presentation.resultStatement {
            Text(statement)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, QueueWorkspaceMetrics.Spacing.md)
                .padding(.bottom, QueueWorkspaceMetrics.Spacing.xs)
                .textSelection(.enabled)
        }
    }

    // MARK: Inventory

    private var showsSearch: Bool {
        presentation.rows.count >= QueueWorkspaceMetrics.Inventory.localSearchThreshold
    }

    private var filteredRows: [QueueTargetRowValue] {
        presentation.rows.filter { $0.matches(query: searchText) }
    }

    @ViewBuilder
    private var inventoryRegion: some View {
        if presentation.rows.isEmpty {
            inventoryEdgeCase(
                title: presentation.emptyStateText,
                hint: nil,
                icon: "tray",
                showsClearAction: false)
        } else if filteredRows.isEmpty {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            inventoryEdgeCase(
                title: "No Matches",
                hint: "No targets in this job match “\(query)”.",
                icon: "magnifyingglass",
                showsClearAction: true)
        } else {
            inventoryList
        }
    }

    /// Empty / no-match inventories keep the section header and result
    /// statement; the inventory region itself is the whole content.
    private func inventoryEdgeCase(
        title: String,
        hint: String?,
        icon: String,
        showsClearAction: Bool
    ) -> some View {
        emptyState(
            title: title,
            hint: hint,
            icon: icon,
            showsClearAction: showsClearAction)
    }

    /// The complete inventory: native scrolling List, lazy rows, stable
    /// identities. Each row owns the shared `QueueTargetRow` component; the
    /// scroll region is this list's alone. The height floor keeps the list a
    /// finite, visible scroll region even in a short window or beside the
    /// open Run Details inspector.
    private var inventoryList: some View {
        List {
            ForEach(filteredRows) { row in
                QueueTargetRow(value: row)
            }
        }
        .listStyle(.plain)
        .frame(minHeight: QueueWorkspaceMetrics.Inventory.minVisibleHeight)
        .accessibilityLabel("\(presentation.sectionTitle) inventory")
    }

    /// Genuinely empty inventory or an over-filtered one. Distinct, honest,
    /// and quiet — neither is an error, and neither renders as a fake success.
    private func emptyState(
        title: String,
        hint: String?,
        icon: String,
        showsClearAction: Bool
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            if let hint {
                Text(hint)
            }
        } actions: {
            if showsClearAction {
                Button("Clear Search") {
                    searchText = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
