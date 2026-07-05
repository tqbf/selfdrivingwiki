import SwiftUI
import WikiFSCore

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

/// Resolves the active wiki's store for the compare window. `manager` is the
/// same `@State` instance the main window uses, so the window shares the live
/// `WikiStoreModel` — a "Set Active" nominate here propagates to the detail
/// view immediately (both read the same `@Observable` model).
struct ExtractionCompareWindow: View {
    let manager: WikiManager
    let context: ExtractionCompareContext?

    var body: some View {
        if let store = manager.activeStore, let ctx = context {
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
/// toolbar toggle to a unified line-diff (`MarkdownDiff`). Each alternative's
/// provenance (backend, model, date, size) is shown; "Set Active" nominates the
/// `source-derived` ref via `WikiStoreModel.setActiveMarkdown` and the Active
/// badge updates live.
///
/// No new markdown-rendering code: both panes reuse `WikiReaderView`.
struct ExtractionCompareSheet: View {
    @Bindable var store: WikiStoreModel
    let sourceID: PageID
    let filename: String

    @Environment(\.dismiss) private var dismiss

    @State private var alternatives: [ExtractionAlternative] = []
    @State private var leftID: PageID?
    @State private var rightID: PageID?
    @State private var showDiff = false

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
        .frame(minWidth: 880, minHeight: 560)
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
            .frame(width: 180)
            .disabled(alternatives.count < 2)
            if showDiff, let l = leftVersion, let r = rightVersion {
                DiffLegend(left: l, right: r)
            }
            Spacer()
            if let l = leftVersion, let r = rightVersion {
                Text("\(l.charCount, format: .number) ↔ \(r.charCount, format: .number) chars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    private var contentSplit: some View {
        HSplitView {
            alternativesList
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 340)
            if showDiff {
                diffPane
            } else {
                renderedSplit
            }
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
        let isLeft = leftID == alt.id
        let isRight = rightID == alt.id
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(alt.backendDisplayName)
                        .font(.callout)
                        .fontWeight(alt.isActive ? .semibold : .regular)
                    if alt.isActive {
                        Text("Active")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.tint, in: Capsule())
                    }
                }
                Text(alt.version.createdAt, style: .date)
                    + Text("  ·  \(alt.charCount, format: .number) chars").foregroundStyle(.secondary)
                if let model = alt.modelVersion {
                    Text(model).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            VStack(spacing: 6) {
                assignButton("A", label: "left pane", assigned: isLeft) { leftID = alt.id }
                assignButton("B", label: "right pane", assigned: isRight) { rightID = alt.id }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func assignButton(_ title: String, label: String, assigned: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .frame(width: 22, height: 22)
                .background(assigned ? Color.accentColor : Color.clear,
                            in: Circle())
                .foregroundStyle(assigned ? Color.white : Color.secondary)
                .overlay(Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Set as \(label)")
    }

    // MARK: - Rendered panes

    private var renderedSplit: some View {
        HSplitView {
            renderedPane(version: leftVersion, tag: "A")
            renderedPane(version: rightVersion, tag: "B")
        }
    }

    @ViewBuilder
    private func renderedPane(version: ExtractionAlternative?, tag: String) -> some View {
        VStack(spacing: 0) {
            paneHeader(tag: tag, alternative: version)
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
    private func paneHeader(tag: String, alternative: ExtractionAlternative?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(tag).font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            if let alt = alternative {
                VStack(alignment: .leading, spacing: 1) {
                    Text(alt.backendDisplayName).font(.callout).fontWeight(.medium)
                        .lineLimit(1).truncationMode(.tail)
                    if let model = alt.modelVersion {
                        Text(model).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
            } else {
                Text("—").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let alt = alternative {
                Button("Set Active") { setActive(to: alt.id) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(alt.isActive)
                    .help("Nominate this extraction as the active HEAD")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Diff pane

    private var diffPane: some View {
        MarkdownDiffView(
            leftLabel: leftVersion?.backendDisplayName ?? "—",
            rightLabel: rightVersion?.backendDisplayName ?? "—",
            left: leftVersion?.version.content ?? "",
            right: rightVersion?.version.content ?? "")
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
    /// defaults: left = active HEAD, right = the most recent other alternative.
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

// MARK: - Diff legend

private struct DiffLegend: View {
    let left: ExtractionAlternative
    let right: ExtractionAlternative

    var body: some View {
        let lines = MarkdownDiff.lineDiff(left.version.content, right.version.content)
        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        HStack(spacing: 10) {
            Label("\(added)", systemImage: "plus")
                .foregroundStyle(.green).font(.caption)
            Label("\(removed)", systemImage: "minus")
                .foregroundStyle(.red).font(.caption)
        }
    }
}

// MARK: - Unified line-diff view

/// Renders a unified, scrollable line-diff of two markdown bodies: unchanged
/// lines plain, additions in green, removals in red, each prefixed with a
/// marker glyph. Monospaced so column alignment across backends is legible.
struct MarkdownDiffView: View {
    let leftLabel: String
    let rightLabel: String
    let left: String
    let right: String

    private var lines: [DiffLine] { MarkdownDiff.lineDiff(left, right) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                paneLabel(leftLabel, tint: .red)
                Divider()
                paneLabel(rightLabel, tint: .green)
            }
            Divider()
            if left.isEmpty && right.isEmpty {
                ContentUnavailableView("Pick alternatives to diff",
                                       systemImage: "circle.dashed")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            diffRow(line)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func paneLabel(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption).fontWeight(.medium)
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    @ViewBuilder
    private func diffRow(_ line: DiffLine) -> some View {
        let (marker, tint, bg): (String, Color, Color) = {
            switch line.kind {
            case .equal:  return (" ", .secondary, Color.clear)
            case .added:  return ("+", .green, Color.green.opacity(0.10))
            case .removed:return ("−", .red, Color.red.opacity(0.10))
            }
        }()
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(marker)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(line.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .equal ? Color.primary : tint)
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
        .textSelection(.enabled)
    }
}

private extension DiffLine {
    var isEmpty: Bool { text.isEmpty }
}
