import SwiftUI
import WikiFSCore

/// Detail pane for one tracked repository: what it is, how far the wiki has been
/// brought along, and the three things you can do about it.
///
/// Modeled on `IngestedFileDetailView` — `.largeTitle` bold name, a `.callout`
/// secondary status line, a row of actions, then an explanation panel — so the
/// two "source" detail panes read as siblings. The metadata is a `Grid` of
/// label/value pairs rather than a `Form`, keeping it consistent with the rest of
/// the app's plain-stack surfaces; commit shas are monospaced because they are
/// meant to be compared by eye.
struct RepoDetailView: View {
    let repo: TrackedRepo
    let activity: RepoTracker.Activity?
    let error: String?
    let isAgentRunning: Bool
    let onUpdate: () -> Void
    let onFetch: () -> Void
    let onToggleAuto: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: PageEditorMetrics.sectionSpacing) {
                Label {
                    Text(repo.name)
                        .font(.largeTitle)
                        .bold()
                        .lineLimit(2)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                }

                statusLine

                actions

                metadata

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: PageEditorMetrics.readableContentWidth, alignment: .leading)
            .padding(PageEditorMetrics.contentInset)

            Divider().opacity(PageEditorMetrics.dividerOpacity)

            ContentUnavailableView {
                Label("Tracked Repository", systemImage: "arrow.triangle.branch")
            } description: {
                Text("The app keeps its own clone of this repository. When new commits land, Claude reads what changed and revises the wiki pages about it — it never writes to the checkout. Ask about the code in Query.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Status

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 12) {
            if let activity {
                ProgressView().controlSize(.small)
                Text(Self.title(for: activity))
            } else if repo.headCommit == nil {
                Label("Not cloned yet", systemImage: "exclamationmark.circle")
            } else if repo.isDrifted {
                Label("New commits to read", systemImage: "circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.orange)
            } else {
                Label("Wiki is up to date", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let fetchedAt = repo.lastFetchedAt {
                // `.relative(presentation: .named)` already reads "2 minutes ago";
                // `Text(_:style:.relative)` counts without the suffix, so pairing
                // it with a literal "ago" is the usual way to get "2 minutes ago
                // ago" in a UI.
                Text("Checked \(fetchedAt.formatted(.relative(presentation: .named)))")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Update Wiki Now", systemImage: "sparkles", action: onUpdate)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isAgentRunning || activity != nil || repo.headCommit == nil)
                .help("Have Claude read what changed and revise the wiki pages for this repository")
            Button("Fetch Now", systemImage: "arrow.clockwise", action: onFetch)
                .disabled(activity != nil)
                .help("Check the remote for new commits")
            Spacer()
            // A write-through binding rather than mirrored `@State`: the flag
            // lives in SQLite, and this row is also rebuilt when an external
            // `wikictl` write lands (§3.1 — cached local copies of store state
            // are how views go stale). Reading the model directly is what keeps
            // the switch honest.
            Toggle(
                "Update automatically",
                isOn: Binding(get: { repo.autoIngest }, set: { onToggleAuto($0) })
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Let the app update the wiki on its own when this repository changes")
        }
    }

    // MARK: - Metadata

    private var metadata: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            row("Remote", repo.remoteURL, monospaced: false)
            row("Branch", repo.branch, monospaced: true)
            row("Head commit", repo.headCommit ?? "—", monospaced: true)
            row("Wiki covers", repo.lastIngestedCommit ?? "nothing yet", monospaced: true)
        }
    }

    private func row(_ label: String, _ value: String, monospaced: Bool) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private static func title(for activity: RepoTracker.Activity) -> String {
        switch activity {
        case .cloning: "Cloning…"
        case .fetching: "Checking for new commits…"
        case .queuedForIngest: "Queued — waiting for the current agent run"
        case .ingesting: "Claude is updating the wiki…"
        }
    }
}
