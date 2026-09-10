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
/// `resultStatement` carries the producer's recorded summary (design change
/// 10, 2026-09-10: only `.available` reports render one — a `.notReported`
/// report renders no statement line).
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
    /// Job-level result statement (the producer's recorded summary).
    /// Rendered under the section header; `nil` hides it — including a
    /// `.notReported` report, which renders NO statement line.
    let resultStatement: String?
    /// Empty-inventory message ("No sources recorded for this job.").
    let emptyStateText: String
    /// Ingestion-only recorded-outputs section, appended under the input
    /// inventory in the SAME list (one scroll region). `nil` for every other
    /// operation — lint and extraction keep their single unchanged section.
    let outputs: QueueOutputsSectionValue?

    init(
        sectionTitle: String,
        countText: String? = nil,
        rows: [QueueTargetRowValue],
        resultStatement: String? = nil,
        emptyStateText: String,
        outputs: QueueOutputsSectionValue? = nil
    ) {
        self.sectionTitle = sectionTitle
        self.countText = countText
        self.rows = rows
        self.resultStatement = resultStatement
        self.emptyStateText = emptyStateText
        self.outputs = outputs
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
        if presentation.outputs != nil {
            // The recorded-outputs section rides in the SAME list, so the
            // list must keep rendering whenever outputs exist — an empty or
            // fully-filtered inputs inventory renders its honest edge case
            // INSIDE the list (`inputsRows`) instead of replacing the whole
            // region, which would suppress the Outputs section with it.
            inventoryList
        } else if presentation.rows.isEmpty {
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
    /// statement; the inventory region itself is the whole content. Only
    /// reached when there is no Outputs section — with outputs present the
    /// same edge cases stay inside the list instead (`inputsRows`).
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
    ///
    /// Ingestion additionally appends the recorded-outputs SECTION in the
    /// same list (one scroll region for both sections; the input rows above
    /// keep their exact behavior, including the local search above, which
    /// filters inputs only).
    private var inventoryList: some View {
        List {
            inputsRows
            if let outputs = presentation.outputs {
                outputsSection(outputs)
            }
        }
        .listStyle(.plain)
        .frame(minHeight: QueueWorkspaceMetrics.Inventory.minVisibleHeight)
        .accessibilityLabel(Self.inventoryAccessibilityLabel(
            sectionTitle: presentation.sectionTitle,
            hasOutputs: presentation.outputs != nil))
    }

    /// The container accessibility label for the inventory List: with a
    /// recorded-outputs section present the region is the combined
    /// inputs-and-outputs inventory; otherwise the section noun alone
    /// ("Sources inventory"). `nonisolated` — a pure function over its
    /// inputs, callable from any isolation context (value-level tests).
    nonisolated static func inventoryAccessibilityLabel(sectionTitle: String, hasOutputs: Bool) -> String {
        hasOutputs ? "Inputs and Outputs inventory" : "\(sectionTitle) inventory"
    }

    /// The inputs side of the shared list. When outputs exist, the empty /
    /// no-match edge cases render HERE — inside the list, as the inputs
    /// area's own honest content — instead of replacing the whole inventory
    /// region, so the inputs message and the Outputs section both survive.
    @ViewBuilder
    private var inputsRows: some View {
        if presentation.rows.isEmpty {
            emptyState(
                title: presentation.emptyStateText,
                hint: nil,
                icon: "tray",
                showsClearAction: false)
        } else if filteredRows.isEmpty {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            emptyState(
                title: "No Matches",
                hint: "No targets in this job match “\(query)”.",
                icon: "magnifyingglass",
                showsClearAction: true)
        } else {
            ForEach(filteredRows) { row in
                QueueTargetRow(value: row)
            }
        }
    }

    /// The recorded-outputs section: the header styled exactly like the
    /// Overview's outer section header (headline noun + secondary
    /// monospaced-digit count), rows through the shared `QueueTargetRow`,
    /// and a quiet honest line while loading / empty / failed — the region
    /// never fabricates an outcome it doesn't have.
    @ViewBuilder
    private func outputsSection(_ outputs: QueueOutputsSectionValue) -> some View {
        Section {
            ForEach(outputs.rows) { row in
                QueueTargetRow(value: row)
            }
            if outputs.rows.isEmpty {
                Text(outputs.emptyStateText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, QueueWorkspaceMetrics.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(outputs.emptyStateText)
            }
        } header: {
            HStack(spacing: QueueWorkspaceMetrics.Spacing.sm) {
                Text(QueueWorkspaceMapper.outputsSectionTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let count = outputs.countText {
                    Text(count)
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(QueueWorkspaceMapper.outputsSectionTitle): \(count)")
                }
                Spacer(minLength: QueueWorkspaceMetrics.Spacing.sm)
            }
            // Same geometry as the outer section header; zero row insets so
            // the header's own padding is the only inset.
            .listRowInsets(EdgeInsets())
            .padding(.horizontal, QueueWorkspaceMetrics.Spacing.md)
            .padding(.top, QueueWorkspaceMetrics.Spacing.sm)
            .padding(.bottom, QueueWorkspaceMetrics.Spacing.xs)
            .textCase(nil)
        }
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
