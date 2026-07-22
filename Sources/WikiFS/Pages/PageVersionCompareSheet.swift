import SwiftUI
import WikiFSCore
import WikiFSEngine

// MARK: - Window context

/// Identifies which page to browse versions for. Value-driven
/// `WindowGroup(for:)` identity: `Hashable`/`==` are based on `pageID` +
/// `wikiID` together (mirrors `ExtractionCompareContext`), so opening Versions
/// for a page in wiki A and a page with the same ID in wiki B creates distinct
/// windows, while re-opening for the same page in the same wiki focuses the
/// existing window. `Codable` is required by the value-driven scene.
struct PageVersionCompareContext: Codable, Hashable {
    let pageID: PageID
    let title: String
    let wikiID: String

    static func == (lhs: PageVersionCompareContext, rhs: PageVersionCompareContext) -> Bool {
        lhs.pageID == rhs.pageID && lhs.wikiID == rhs.wikiID
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(pageID)
        hasher.combine(wikiID)
    }
}

/// Resolves the correct wiki's store for the Versions window via the shared
/// `SessionManager` (mirrors `ExtractionCompareWindow`). If the session is no
/// longer alive (all windows for that wiki closed), shows an empty state.
struct PageVersionCompareWindow: View {
    let sessionManager: SessionManager
    let context: PageVersionCompareContext?

    var body: some View {
        if let ctx = context,
           let session = sessionManager.sessions[ctx.wikiID] {
            PageVersionCompareSheet(
                store: session.store,
                pageID: ctx.pageID,
                title: ctx.title)
        } else {
            ContentUnavailableView {
                Label("No Page to Compare", systemImage: "doc.questionmark")
            } description: {
                Text("Open a wiki and page, then choose Compare Versions.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Sheet

/// Browse / diff / restore page versions (#817). Rendered as the content of a
/// value-driven `WindowGroup` (a real, resizable, non-modal window — see
/// `WikiFSApp`). The left sidebar lists every `page_versions` row (newest-first)
/// with its provenance (date + writer + current-marker); the right pane toggles
/// between a **Rendered** preview (two `WikiReaderView`s side-by-side —
/// read-only time-travel) and a synchronized two-column line-**Diff**
/// (`SplitDiffView`, reused as-is). A "Restore this version" action on each
/// non-current row appends a new version node via
/// `WikiStoreModel.restorePage` (append-only — history is never mutated; the
/// restore itself appears as a new `'restore'`-badged node; see
/// `plans/history-versions.md` R1).
///
/// No new markdown-rendering or diff code: the rendered panes reuse
/// `WikiReaderView` bound to the **live** store (R8 — wiki/ghost links resolve
/// against current state; the historical version is just the markdown string),
/// and the diff pane reuses `SplitDiffView` verbatim.
struct PageVersionCompareSheet: View {
    @Bindable var store: WikiStoreModel
    let pageID: PageID
    let title: String

    @Environment(\.dismiss) private var dismiss

    /// The version chain with provenance, newest-first (`pageEditHistory` is
    /// `ORDER BY id DESC`). Each row carries `versionID`/`title`/agent/savedAt.
    @State private var history: [PageOrigin] = []
    /// The active HEAD version id — drives the "Current" marker. Reloaded after
    /// a restore so the marker moves to the restored version.
    @State private var headID: String?
    /// Lazily-loaded bodies keyed by version id (`pageVersionBody` reads). A
    /// version's body is fetched on first assign to Base/Compare and cached.
    @State private var bodies: [String: String] = [:]
    @State private var leftID: String?
    @State private var rightID: String?
    @State private var showDiff = false
    /// The version id pending a restore confirmation (non-nil → alert shown).
    @State private var restoreTarget: String?

    private enum CompareMode: String, CaseIterable {
        case rendered = "Rendered"
        case diff = "Diff"
    }

    init(store: WikiStoreModel, pageID: PageID, title: String, startInDiff: Bool = false) {
        self._store = Bindable(wrappedValue: store)
        self.pageID = pageID
        self.title = title
        self._showDiff = State(initialValue: startInDiff)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            if history.count < 2 {
                emptyState
            } else {
                contentSplit
            }
        }
        .frame(minWidth: 900, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { refresh(assignDefaults: true) }
        .task(id: neededBodyKey) { ensureNeededBodies() }
        .alert(
            "Restore this version?",
            isPresented: Binding(
                get: { restoreTarget != nil },
                set: { if !$0 { restoreTarget = nil } }
            )
        ) {
            Button("Restore", role: .destructive) {
                if let target = restoreTarget { confirmRestore(target) }
            }
            Button("Cancel", role: .cancel) { restoreTarget = nil }
        } message: {
            if let target = restoreTarget, let origin = history.first(where: { $0.versionID == target }) {
                Text("The page will be restored to its state from \(origin.savedAt.formatted(.dateTime.month().day().year().hour().minute())). This becomes the current version; the edit history is preserved.")
            }
        }
    }

    // MARK: - Header / toolbar

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Compare Versions").font(.headline)
                Text(title).font(.subheadline).foregroundStyle(.secondary)
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
            .disabled(history.count < 2)

            paneMenu(title: "Base", tint: .red, selection: $leftID, current: leftVersion)
            paneMenu(title: "Compare", tint: .green, selection: $rightID, current: rightVersion)

            Spacer()

            if let l = leftVersion, let r = rightVersion {
                Text("\(body(for: l.versionID).count, format: .number) ↔ \(body(for: r.versionID).count, format: .number) chars")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// A `Base ▾` / `Compare ▾` picker (mirrors `ExtractionCompareSheet`'s
    /// `paneMenu`). The colored dot ties the pane to its diff side.
    private func paneMenu(title: String, tint: Color,
                          selection: Binding<String?>,
                          current: PageOrigin?) -> some View {
        Menu {
            ForEach(history, id: \.versionID) { origin in
                Button {
                    selection.wrappedValue = origin.versionID
                } label: {
                    HStack {
                        Text(versionLabel(origin))
                        if origin.versionID == current?.versionID { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                (Text("\(title): ").foregroundStyle(.secondary)
                    + Text(current.map(versionLabel) ?? "—").fontWeight(.medium))
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
            versionsList
                .frame(minWidth: 240, idealWidth: 268, maxWidth: 340)
            Group {
                if showDiff {
                    SplitDiffView(
                        leftLabel: leftVersion.map(versionLabel) ?? "—",
                        rightLabel: rightVersion.map(versionLabel) ?? "—",
                        left: body(for: leftID),
                        right: body(for: rightID))
                } else {
                    renderedSplit
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Only One Version", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("This page has only its initial version. Edit the page to create more history to compare.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Versions list

    private var versionsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(history, id: \.versionID) { origin in
                    versionRow(origin)
                    Divider().opacity(0.4)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func versionRow(_ origin: PageOrigin) -> some View {
        let isCurrent = origin.versionID == headID
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(writerLabel(origin))
                    .font(.callout)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1).truncationMode(.tail)
                if isCurrent {
                    Text("Current")
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 4)
                assignmentTag(origin)
            }
            Text(origin.savedAt, format: .dateTime.month().day().year().hour().minute())
                .font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
            if origin.title != title {
                Text(origin.title).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if !isCurrent {
                Button("Restore this version") { restoreTarget = origin.versionID }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Restore the page to this version (history is preserved)")
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    /// Small read-only badge marking a row assigned to Base / Compare — mirrors
    /// the toolbar dropdown colors so the two controls read as one system.
    @ViewBuilder
    private func assignmentTag(_ origin: PageOrigin) -> some View {
        if leftVersion?.versionID == origin.versionID {
            paneBadge("Base", tint: .red)
        } else if rightVersion?.versionID == origin.versionID {
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
            renderedPane(version: leftVersion, body: body(for: leftID), tag: "Base", tint: .red)
            renderedPane(version: rightVersion, body: body(for: rightID), tag: "Compare", tint: .green)
        }
    }

    @ViewBuilder
    private func renderedPane(version: PageOrigin?, body: String, tag: String, tint: Color) -> some View {
        VStack(spacing: 0) {
            paneHeader(tag: tag, tint: tint, version: version)
            Divider()
            if !body.isEmpty {
                // R8: pass the LIVE store so wiki/ghost links resolve against
                // current state. The historical version is just the markdown.
                WikiReaderView(markdown: body, store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Pick a version for \(tag)",
                                       systemImage: "circle.dashed")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func paneHeader(tag: String, tint: Color, version: PageOrigin?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(tag).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            }
            if let origin = version {
                Text(versionLabel(origin)).font(.callout).fontWeight(.medium)
                    .lineLimit(1).truncationMode(.tail)
            } else {
                Text("—").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Derived

    private var leftVersion: PageOrigin? {
        guard let id = leftID else { return history.first }
        return history.first { $0.versionID == id } ?? history.first
    }

    private var rightVersion: PageOrigin? {
        guard let id = rightID else {
            return history.first { $0.versionID != leftVersion?.versionID } ?? history.first
        }
        return history.first { $0.versionID == id }
    }

    /// Resolve the cached body for a version id (empty string when not loaded).
    private func body(for versionID: String?) -> String {
        guard let id = versionID else { return "" }
        return bodies[id] ?? ""
    }

    /// A stable key for the pair of currently-needed bodies, so `.task(id:)`
    /// re-fires exactly when Base/Compare changes (not on every render).
    private var neededBodyKey: String {
        "\(leftID ?? "")\u{0}\(rightID ?? "")"
    }

    // MARK: - Labels

    /// A one-line label for a version: the writer (chat title or agent), then
    /// the saved date. Used in the pane menus + headers.
    private func versionLabel(_ origin: PageOrigin) -> String {
        let when = origin.savedAt.formatted(.dateTime.month().day().hour().minute())
        return "\(writerLabel(origin)) — \(when)"
    }

    /// Resolve a human-readable writer name: a chat's display title when the
    /// agent is `chat:<id>` (carried in `runTitle`), otherwise the agent name
    /// cleaned up. Mirrors the `ProvenancePanel` writer logic.
    private func writerLabel(_ origin: PageOrigin) -> String {
        if let runTitle = origin.runTitle, !runTitle.isEmpty { return runTitle }
        switch PageAuthor(rawValue: origin.agentName) {
        case .chat: return "Chat"
        case .agent(let kind): return kind.capitalized + " run"
        case .user: return "You"
        case .legacyImport: return "Import"
        case .other: return origin.agentName
        }
    }

    // MARK: - Actions

    /// Reload history + HEAD from the store; on first load assign sensible
    /// defaults (Base = HEAD, Compare = the previous version).
    private func refresh(assignDefaults: Bool) {
        let fresh = store.pageEditHistory(for: pageID) // newest-first
        history = fresh
        // The active HEAD's version id (the "Current" marker). `pageOrigin`
        // returns exactly the HEAD's origin (ref → version, else MAX(id)).
        headID = store.pageOrigin(for: pageID)?.versionID
        if assignDefaults {
            let head = fresh.first { $0.versionID == headID } ?? fresh.first
            leftID = head?.versionID
            rightID = fresh.first { $0.versionID != head?.versionID }?.versionID ?? head?.versionID
        }
    }

    /// Fetch any not-yet-cached bodies for the current Base/Compare selections.
    /// Runs off the `.task(id:)` so a body read never blocks the main render
    /// pass (the read itself is `dbWriter.read`-backed — method-atomic).
    private func ensureNeededBodies() {
        for id in [leftID, rightID] {
            guard let id, bodies[id] == nil else { continue }
            if let fetched = store.pageVersionBody(for: id) {
                bodies[id] = fetched
            }
        }
    }

    private func confirmRestore(_ versionID: String) {
        store.restorePage(for: pageID, to: versionID)
        // Reload so the new restore node appears at the top of the list with the
        // "Current" marker, and the head-derived Base default updates. Bodies
        // stay cached (blob-dedup means the restored body already exists in the
        // cache if its source version was viewed).
        refresh(assignDefaults: false)
    }
}
