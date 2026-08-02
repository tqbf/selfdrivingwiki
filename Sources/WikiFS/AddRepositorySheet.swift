import SwiftUI
import WikiFSCore

/// Track a git repository: paste a remote, hit Track, and the app clones it into
/// its own storage and starts watching it.
///
/// Deliberately the same sheet shape as `AddFromURLSheet` (the other "bring
/// something in from outside" surface): `.headline` title, `.subheadline`
/// explanation, one prominent field, an inline status row that animates a
/// DIMENSION rather than inserting/removing (§1.1), and a primary action. The one
/// addition is the resolved `owner/repo` name echoed back live, because a git
/// remote is easy to paste wrong and the parsed name is the cheapest possible
/// confirmation that we understood it.
struct AddRepositorySheet: View {
    let tracker: RepoTracker
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var remoteText = ""
    @State private var branchText = ""
    @State private var phase: Phase = .idle
    @FocusState private var fieldFocused: Bool

    /// The clone lifecycle — one value the whole view derives from (§3.1).
    private enum Phase: Equatable {
        case idle
        case cloning
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            header
            remoteField
            branchField
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
            Text("Track a Repository")
                .font(.headline)
            Text("The app clones the repository into its own storage and keeps it in sync. When new commits land, Claude updates the wiki pages about it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Fields

    private var remoteField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("https://github.com/owner/repo", text: $remoteText)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .lineLimit(1)
                .focused($fieldFocused)
                .disabled(isCloning)
                .onSubmit { if canTrack { track() } }
                .onChange(of: remoteText) {
                    if case .failed = phase { phase = .idle }
                }
            // Echo what we parsed. Reserved height so typing doesn't jog the sheet.
            Text(parsed.map { "Tracks as \($0.name)" } ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var branchField: some View {
        HStack(spacing: 8) {
            Text("Branch")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("default", text: $branchText)
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .lineLimit(1)
                .disabled(isCloning)
                .frame(width: Metrics.branchFieldWidth)
            Text("Leave empty to follow the repository's default branch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Status — always mounted, height-animated

    private var statusArea: some View {
        Group {
            switch phase {
            case .cloning:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Cloning… this can take a while for a large repository.")
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

    private var statusHeight: CGFloat {
        switch phase {
        case .idle: Metrics.idleRowHeight
        case .cloning: Metrics.statusRowHeight
        case .failed: Metrics.errorRowHeight
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isCloning)
            Button("Track") { track() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canTrack)
        }
    }

    // MARK: - Derived

    private var isCloning: Bool { phase == .cloning }
    private var parsed: GitRemoteURL? { GitRemoteURL.parse(remoteText) }
    private var canTrack: Bool { !isCloning && parsed != nil }

    // MARK: - Action

    private func track() {
        // Read the fields fresh at click time (§3.5).
        guard let remote = GitRemoteURL.parse(remoteText) else { return }
        let branch = branchText.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .cloning
        Task {
            let added = await tracker.addRepo(
                remote: remote, branch: branch.isEmpty ? nil : branch)
            // `addRepo` keeps the row on failure so the repo is visible and
            // retryable; the sheet only dismisses when the clone actually landed.
            if let added, let message = tracker.errors[added.id] {
                phase = .failed(message)
            } else if added == nil {
                phase = .failed("Could not track this repository. It may already be tracked in this wiki.")
            } else {
                dismiss()
            }
        }
    }

    /// Layout constants (§2.4 — no scattered magic numbers).
    private enum Metrics {
        static let width: CGFloat = 480
        static let padding: CGFloat = 20
        static let sectionSpacing: CGFloat = 14
        static let branchFieldWidth: CGFloat = 120
        static let idleRowHeight: CGFloat = 0
        static let statusRowHeight: CGFloat = 22
        static let errorRowHeight: CGFloat = 56
    }
}
