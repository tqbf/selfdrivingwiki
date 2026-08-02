import SwiftUI
import WikiFSCore

/// One row in the sidebar's "Repositories" section: a tracked repo's name and its
/// sync state. Selecting the row opens the repo detail pane; the context menu
/// keeps the two direct actions (fetch, stop tracking) close at hand.
///
/// Modeled on `IngestedFileRow` so the sidebar reads as one list: `Label` with a
/// leading symbol, `.body` name, `.caption` trailing status in secondary. The
/// status deliberately says only what the app actually KNOWS — "Changes", not "12
/// behind": the tracker stores the head and the watermark, not a commit count,
/// and inventing a number the row can't stand behind is worse than a plain word.
struct RepoRow: View {
    let repo: TrackedRepo
    let activity: RepoTracker.Activity?
    let onFetch: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Label {
            HStack(spacing: 8) {
                Text(repo.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                status
            }
        } icon: {
            Image(systemName: "arrow.triangle.branch")
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Fetch Now", systemImage: "arrow.clockwise", action: onFetch)
            Button("Stop Tracking", role: .destructive, action: onRemove)
        }
        .swipeActions(edge: .trailing) {
            Button("Stop Tracking", role: .destructive, action: onRemove)
        }
    }

    /// In-flight work wins over drift: while the tracker is doing something to
    /// this repo, saying so is more useful than restating a state that is about
    /// to change.
    @ViewBuilder
    private var status: some View {
        if let activity {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text(Self.title(for: activity))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if repo.headCommit == nil {
            Text("Not cloned")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if repo.isDrifted {
            Label("Changes", systemImage: "circle.fill")
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .imageScale(.small)
                .foregroundStyle(.orange)
                .help("New commits the wiki hasn't been told about yet")
        } else {
            // Icon-only, so it carries its own VoiceOver label — `help` is a
            // pointer affordance and says nothing to a screen reader.
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .help("The wiki is up to date with this repository")
                .accessibilityLabel("Wiki is up to date with this repository")
        }
    }

    private static func title(for activity: RepoTracker.Activity) -> String {
        switch activity {
        case .cloning: "Cloning…"
        case .fetching: "Checking…"
        case .queuedForIngest: "Queued"
        case .ingesting: "Updating…"
        }
    }
}
