import SwiftUI
import WikiFSCore
import WikiFSEngine

/// Identifies which source to compare extractions for. Value-driven
/// `WindowGroup(for:)` identity: `Hashable`/`==` are based on `sourceID` alone,
/// so opening Compare for a source that already has a window focuses it rather
/// than spawning a duplicate. `Codable` is required by the value-driven scene.
struct ExtractionCompareContext: Codable, Hashable {
    let sourceID: PageID
    let filename: String

    static func == (lhs: ExtractionCompareContext, rhs: ExtractionCompareContext) -> Bool {
        lhs.sourceID == rhs.sourceID
    }
    func hash(into hasher: inout Hasher) { hasher.combine(sourceID) }
}

/// Resolves the active wiki's store for the compare window. `session` is the
/// same `@State` instance the main window uses, so the window shares the live
/// `WikiStoreModel` — a "Set Active" nominate here propagates to the detail
/// view immediately (both read the same `@Observable` model).
struct ExtractionCompareWindow: View {
    let session: WikiSession?
    let context: ExtractionCompareContext?

    var body: some View {
        if let store = session?.store, let ctx = context {
            ExtractionCompareSheet(store: store, sourceID: ctx.sourceID, filename: ctx.filename)
        } else {
            ContentUnavailableView {
                Label("No Source to Compare", systemImage: "doc.questionmark")
            } description: {
                Text("Open a wiki and source, then choose Compare Extractions.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Compare/nominate surface for a source's extraction alternatives (graph-model
/// Phase 2, track C). Rendered as the content of a value-driven `WindowGroup`
/// (a real, resizable, non-modal window — see `WikiFSApp`). Renders any two
/// alternatives side-by-side in the real reader (`WikiReaderView`), with a
/// toolbar toggle to a synchronized two-column line-diff (`SplitDiffView`).
/// Each alternative's provenance (backend, model, date, size) lives in the
/// sidebar; "Set Active" nominates the `source-derived` ref via
/// `WikiStoreModel.setActiveMarkdown` and the Active badge updates live.
///
/// No new markdown-rendering code: both rendered panes reuse `WikiReaderView`.
struct ExtractionCompareSheet: View {
    @Bindable var store: WikiStoreModel
    let sourceID: PageID
    let filename: String

    @Environment(\.dismiss) private var dismiss

    @State private var alternatives: [ExtractionAlternative] = []
    @State private var leftID: PageID?
    @State private var rightID: PageID?
    @State private var showDiff = false

    init(store: WikiStoreModel, sourceID: PageID, filename: String, startInDiff: Bool = false) {
        self._store = Bindable(wrappedValue: store)
        self.sourceID = sourceID
        self.filename = filename
        self._showDiff = State(initialValue: startInDiff)
    }

    private enum CompareMode: String, CaseIterable {
        case rendered = "Rendered"
        case diff = "Diff"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            if alternatives.count < 2 {
                emptyState
            } else {
                contentSplit
            }
        }
        .frame(minWidth: 900, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { refresh(assignDefaults: true) }
    }

    // MARK: - Header / toolbar

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Compare Extractions").font(.headline)
                Text(filename).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $showDiff) {
                Text(CompareMode.rendered.rawValue).tag(false)
                Text(CompareMode.diff.rawValue).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            .disabled(alternatives.count < 2)

            paneMenu(title: "Base", tint: .red, selection: $leftID, current: leftVersion)
            paneMenu(title: "Compare", tint: .green, selection: $rightID, current: rightVersion)

            Spacer()

            if let l = leftVersion, let r = rightVersion {
                Text("\(l.charCount, format: .number) ↔ \(r.charCount, format: .number) chars")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// A `Base ▾` / `Compare ▾` picker. Replaces the old per-row A/B circles with
    /// the more discoverable header-dropdown idiom; the colored dot ties the pane
    /// to its diff side (base = red/removed, compare = green/added).
    private func paneMenu(title: String, tint: Color,
                          selection: Binding<PageID?>,
                          current: ExtractionAlternative?) -> some View {
        Menu {
            ForEach(alternatives) { alt in
                Button {
                    selection.wrappedValue = alt.id
                } label: {
                    HStack {
                        Text(alt.backendDisplayName)
                        if alt.id == current?.id { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                (Text("\(title): ").foregroundStyle(.secondary)
                    + Text(current?.backendDisplayName ?? "—").fontWeight(.medium))
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(.callout)
            .frame(maxWidth: 220, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Content

    private var contentSplit: some View {
        HSplitView {
            alternativesList
                .frame(minWidth: 240, idealWidth: 268, maxWidth: 340)
            Group {
                if showDiff {
                    SplitDiffView(
                        leftLabel: leftVersion?.backendDisplayName ?? "—",
                        rightLabel: rightVersion?.backendDisplayName ?? "—",
                        left: leftVersion?.version.content ?? "",
                        right: rightVersion?.version.content ?? "")
                } else {
                    renderedSplit
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing to Compare", systemImage: "arrow.left.and.right.square")
        } description: {
            Text("Re-extract with another backend to create a second alternative.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Alternatives list

    private var alternativesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(alternatives) { alt in
                    alternativeRow(alt)
                    Divider().opacity(0.4)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func alternativeRow(_ alt: ExtractionAlternative) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(alt.backendDisplayName)
                    .font(.callout)
                    .fontWeight(alt.isActive ? .semibold : .regular)
                if alt.isActive {
                    Text("Active")
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 4)
                assignmentTag(alt)
            }
            (Text(alt.version.createdAt, style: .date)
                + Text("  ·  \(alt.charCount, format: .number) chars"))
                .font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
            if let model = alt.modelVersion {
                Text(model).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if !alt.isActive {
                Button("Set Active") { setActive(to: alt.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Nominate this extraction as the active HEAD")
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    /// Small read-only badge marking a row assigned to the Base / Compare pane —
    /// mirrors the toolbar dropdown colors so the two controls read as one system.
    @ViewBuilder
    private func assignmentTag(_ alt: ExtractionAlternative) -> some View {
        if leftVersion?.id == alt.id {
            paneBadge("Base", tint: .red)
        } else if rightVersion?.id == alt.id {
            paneBadge("Compare", tint: .green)
        }
    }

    private func paneBadge(_ text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.caption2).fontWeight(.medium)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
    }

    // MARK: - Rendered panes

    private var renderedSplit: some View {
        HSplitView {
            renderedPane(version: leftVersion, tag: "Base", tint: .red)
            renderedPane(version: rightVersion, tag: "Compare", tint: .green)
        }
    }

    @ViewBuilder
    private func renderedPane(version: ExtractionAlternative?, tag: String, tint: Color) -> some View {
        VStack(spacing: 0) {
            paneHeader(tag: tag, tint: tint, alternative: version)
            Divider()
            if let alt = version {
                WikiReaderView(markdown: alt.version.content, store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Pick an alternative for \(tag)",
                                       systemImage: "circle.dashed")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func paneHeader(tag: String, tint: Color, alternative: ExtractionAlternative?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(tag).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            }
            if let alt = alternative {
                Text(alt.backendDisplayName).font(.callout).fontWeight(.medium)
                    .lineLimit(1).truncationMode(.tail)
                if let model = alt.modelVersion {
                    Text(model).font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
            } else {
                Text("—").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Derived

    private var leftVersion: ExtractionAlternative? {
        guard let id = leftID else { return alternatives.first }
        return alternatives.first { $0.id == id } ?? alternatives.first
    }

    private var rightVersion: ExtractionAlternative? {
        guard let id = rightID else {
            return alternatives.first { $0.id != leftVersion?.id } ?? alternatives.first
        }
        return alternatives.first { $0.id == id }
    }

    // MARK: - Actions

    private func setActive(to versionID: PageID) {
        store.setActiveMarkdown(for: sourceID, to: versionID)
        refresh(assignDefaults: false)
    }

    /// Reload alternatives from the store and (on first load) assign sensible
    /// defaults: base = active HEAD, compare = the most recent other alternative.
    private func refresh(assignDefaults: Bool) {
        let fresh = store.processedMarkdownAlternatives(for: sourceID)
        alternatives = fresh
        if assignDefaults {
            let active = fresh.first { $0.isActive } ?? fresh.first
            leftID = active?.id
            rightID = fresh.first { $0.id != active?.id }?.id ?? active?.id
        }
    }
}

// MARK: - Synchronized two-column line-diff

/// Renders a synchronized **side-by-side** line-diff of two markdown bodies.
/// Both columns live in a single `ScrollView` (so scroll is synced by
/// construction), each row carries per-side line numbers and a change gutter,
/// long unchanged runs collapse into expandable bands, and the toolbar offers
/// prev/next change navigation (⌥↑ / ⌥↓).
///
/// The LCS diff + split alignment is expensive on 100k-char bodies, so it is
/// computed **once** off the main thread into `@State` (with a spinner) and only
/// recomputed when the left/right content changes — never on scroll or hover.
struct SplitDiffView: View {
    let leftLabel: String
    let rightLabel: String
    let left: String
    let right: String

    @State private var elements: [SplitDiffElement] = []
    @State private var anchors: [Int] = []
    @State private var added = 0
    @State private var removed = 0
    @State private var expanded: Set<Int> = []
    @State private var currentHunk = 0
    @State private var isComputing = false

    private let gutterWidth: CGFloat = 46
    private let markerWidth: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
            Divider()
            content
        }
        .task(id: left + "\u{0}" + right) { await recompute() }
    }

    // MARK: Header

    private var columnHeader: some View {
        HStack(spacing: 0) {
            headerCell(leftLabel, tint: .red, systemImage: "minus.circle.fill", count: removed)
            Divider().frame(height: 22)
            headerCell(rightLabel, tint: .green, systemImage: "plus.circle.fill", count: added)
        }
        // Pin to intrinsic height: an unbounded vertical `Divider` in an HStack is
        // greedy and would otherwise split the flexible height with the ScrollView
        // below, floating the labels to mid-pane. This is the dead-space fix.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) { changeNav.padding(.trailing, 10) }
    }

    private func headerCell(_ text: String, tint: Color, systemImage: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(tint).font(.caption)
            Text(text).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Text("\(count)").font(.caption2).monospacedDigit().foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var changeNav: some View {
        if !anchors.isEmpty {
            HStack(spacing: 2) {
                Text("\(min(currentHunk + 1, anchors.count))/\(anchors.count)")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.trailing, 4)
                Button { step(-1) } label: { Image(systemName: "chevron.up") }
                    .keyboardShortcut(.upArrow, modifiers: .option)
                Button { step(1) } label: { Image(systemName: "chevron.down") }
                    .keyboardShortcut(.downArrow, modifiers: .option)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        if isComputing {
            ProgressView().controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if left.isEmpty && right.isEmpty {
            ContentUnavailableView("Pick alternatives to diff", systemImage: "circle.dashed")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(elements) { element in
                            switch element {
                            case .row(let r): rowView(r)
                            case .collapsed(let rows): collapsedBand(rows, id: element.id)
                            }
                        }
                    }
                }
                .onChange(of: currentHunk) { _, new in
                    guard anchors.indices.contains(new) else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(anchors[new], anchor: .center)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func rowView(_ r: SplitRow) -> some View {
        HStack(spacing: 0) {
            cell(r.left)
            Divider()
            cell(r.right)
        }
        .id(r.index)
    }

    @ViewBuilder
    private func cell(_ cell: SplitCell?) -> some View {
        if let cell {
            HStack(alignment: .top, spacing: 0) {
                Text("\(cell.number)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: gutterWidth, alignment: .trailing)
                    .padding(.trailing, 6)
                Text(marker(cell.kind))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(tint(cell.kind))
                    .frame(width: markerWidth)
                Text(cell.text.isEmpty ? " " : cell.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(cell.kind == .equal ? .primary : tint(cell.kind))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.trailing, 8)
            }
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background(cell.kind))
        } else {
            // Filler for an unpaired addition/removal on the opposite side.
            Color.primary.opacity(0.03)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.quaternary).frame(width: 1).padding(.leading, gutterWidth + markerWidth + 6)
                }
        }
    }

    private func collapsedBand(_ rows: [SplitRow], id: Int) -> some View {
        Group {
            if expanded.contains(id) {
                ForEach(rows) { rowView($0) }
            } else {
                Button {
                    expanded.insert(id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down.circle").font(.caption)
                        Text("Show \(rows.count) unchanged lines").font(.caption)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.10))
                    .overlay(alignment: .top) { Divider() }
                    .overlay(alignment: .bottom) { Divider() }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Styling

    private func marker(_ kind: DiffLineKind) -> String {
        switch kind { case .equal: " "; case .added: "+"; case .removed: "−" }
    }
    private func tint(_ kind: DiffLineKind) -> Color {
        switch kind { case .equal: .secondary; case .added: .green; case .removed: .red }
    }
    private func background(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .equal: .clear
        case .added: .green.opacity(0.11)
        case .removed: .red.opacity(0.11)
        }
    }

    // MARK: Actions

    private func step(_ delta: Int) {
        guard !anchors.isEmpty else { return }
        currentHunk = (currentHunk + delta + anchors.count) % anchors.count
    }

    private func recompute() async {
        isComputing = true
        let l = left, r = right
        let result = await Task.detached(priority: .userInitiated) { () -> ([SplitDiffElement], [Int], Int, Int) in
            let lines = MarkdownDiff.lineDiff(l, r)
            let rows = SplitDiff.rows(from: lines)
            let elements = SplitDiff.elements(from: rows)
            let anchors = SplitDiff.hunkAnchors(from: rows)
            let added = rows.reduce(0) { $0 + ((($1.right?.kind ?? .equal) == .added) ? 1 : 0) }
            let removed = rows.reduce(0) { $0 + ((($1.left?.kind ?? .equal) == .removed) ? 1 : 0) }
            return (elements, anchors, added, removed)
        }.value
        elements = result.0
        anchors = result.1
        added = result.2
        removed = result.3
        expanded = []
        currentHunk = 0
        isComputing = false
    }
}
