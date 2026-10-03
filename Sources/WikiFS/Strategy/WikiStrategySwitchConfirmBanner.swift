import SwiftUI
import WikiFSCore

/// The window-level wiki-switch guard: a native banner presented by
/// `RootScene` above the whole session view whenever an in-place wiki switch
/// was deferred because THIS window's strategy draft has unsaved changes.
///
/// Production wiring (see `RootScene`): every in-place swap path — the
/// switcher's option-click, another window's `registry.select` while this
/// window is frontmost, create/import/delete cascades — funnels through
/// `RootScene`'s active-wiki observation. That boundary defers the swap via
/// ``WikiStoreModel/deferInPlaceWikiSwitchIfNeeded(to:)`` and this banner
/// asks the one question that matters: discard the draft and switch, or keep
/// editing this wiki. Opening a wiki in a NEW window never destroys this
/// session, so it never shows this banner.
///
/// "Discard Changes & Switch" calls `onPerformSwitch`, which the scene
/// implements by applying the pending switch (dropping the draft) and then
/// performing the actual session swap — the registry's active id has already
/// changed by the time the guard defers, so the confirmation itself must
/// drive the swap.
struct WikiStrategySwitchConfirmBanner: View {
    @Bindable var store: WikiStoreModel
    /// The incoming wiki's display name, resolved by the scene from the
    /// registry for the pending target.
    let targetDisplayName: String
    /// Performs the deferred switch (drop the draft, swap the session).
    let onPerformSwitch: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Switch to “\(targetDisplayName)”?")
                    .font(.callout.weight(.semibold))
                Text("The strategy draft for this wiki has unsaved changes. Switching wikis now discards them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Discard Changes & Switch", role: .destructive, action: onPerformSwitch)
                        .keyboardShortcut(.defaultAction)
                    Button("Keep Editing", role: .cancel) {
                        store.cancelPendingStrategyWikiSwitch()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(WikiStrategyEditorMetrics.calloutPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Unsaved strategy changes")
    }
}
