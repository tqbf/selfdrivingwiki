import SwiftUI
import WikiFSCore

/// Non-dismissible sheet shown while ``WikiStoreModel.upgradeSearchIndex()`` runs.
///
/// Blocks ALL window interaction while presented: the upgrade is the sole owner
/// of the store, so SQLite is never touched off-main (the invariant that kills
/// the launch `EXC_BREAKPOINT` from two threads racing one cached statement).
/// The sheet dismisses itself when the model sets `searchUpgrade = nil` on
/// completion. It is a one-time, usually-instant operation (no sheet at all on a
/// warm DB) — only first run, an NLEmbedding→MiniLM cutover, or `wikictl`-written
/// content produces missing work.
struct SearchUpgradeView: View {
    @Bindable var store: WikiStoreModel

    var body: some View {
        let progress = store.searchUpgrade
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Upgrading Search Index")
                .font(.headline)
            if let progress {
                Text("\(progress.done) of \(progress.total)")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(progress.done),
                             total: Double(max(progress.total, 1)))
                    .frame(maxWidth: 240)
                Text(progress.phase == .pages ? "Embedding pages…" : "Embedding sources…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("The wiki is read-only while this runs — a one-time search upgrade.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(minWidth: 340)
    }
}
