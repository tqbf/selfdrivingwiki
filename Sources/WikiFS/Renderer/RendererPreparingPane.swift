#if os(macOS)
import SwiftUI

// pattern: Value Widget

/// Transient pane shown while an installed renderer session prepares. Hosts
/// must show this instead of a load-failed fallback until preparation
/// settles: an early fallback shows a false error and — in tabbed hosts
/// whose fallback reverts the selection — cancels the very preparation it
/// reports on, leaving the renderer tab unreachable.
struct RendererPreparingPane: View {
    let rendererName: String

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Preparing \(rendererName)…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing \(rendererName)")
    }
}
#endif
